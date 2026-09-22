#Requires -Version 7.0
<#
.SYNOPSIS
Offline completion, workspace and paid-probe authorization regression tests.
.DESCRIPTION
Every remote/native operation is injected. No Azure/GitHub writes, credentials,
model calls, package installation, commits or branch changes are performed.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts\github\Environment.psm1') -Force
Import-Module (Join-Path $root 'scripts\github\Completion.psm1') -Force
$script:passed = 0
$script:failed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern = '*') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected rejection.'
    Assert-True ($caught.Exception.Message -like $Pattern) "Unexpected rejection (expected $Pattern)."
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] $Name -- $($_.Exception.Message)" }
}
function New-Fixture {
    $profile = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
    $resolution = Resolve-EnvironmentProfile $profile -AllowSynthetic
    $scope = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)"
    $settings = @(
        @{ name = 'AZURE_TENANT_ID'; value = $profile.azure.tenantId }
        @{ name = 'AZURE_CLIENT_ID'; value = $profile.identities.workload.clientId }
        @{ name = 'INFERENCE_ACCESS_MODE'; value = 'gateway' }
        @{ name = 'INFERENCE_GATEWAY_ENDPOINT'; value = "https://synthetic-gateway.azure-api.net/inference/$($profile.gateway.workloadKey)/v1/responses" }
        @{ name = 'INFERENCE_GATEWAY_AUDIENCE'; value = $profile.gateway.audience }
        @{ name = 'SMOKE_API_AUDIENCE'; value = $profile.application.audience }
        @{ name = 'SMOKE_ALLOWED_OBJECT_IDS'; value = (ConvertTo-Json -InputObject $profile.identities.developerObjectIds -Compress) }
        @{ name = 'SMOKE_ALLOWED_GROUP_IDS'; value = (ConvertTo-Json -InputObject $profile.identities.developerGroupObjectIds -Compress) }
        @{ name = 'SMOKE_MODEL_DEPLOYMENT'; value = $profile.application.modelDeployment }
        @{ name = 'SMOKE_MAX_OUTPUT_TOKENS'; value = [string]$profile.application.maxOutputTokens }
        @{ name = 'CUSTOM_OPTIONAL_COSMOS_SETTING'; value = 'preserve-all-supplied-settings' }
        @{ name = 'APPLICATIONINSIGHTS_CONNECTION_STRING'; value = ''; sourceResourceId = "$scope/providers/Microsoft.Insights/components/synthetic-insights"; sourceProperty = 'ConnectionString' }
    )
    foreach ($setting in $settings) {
        $setting.label = 'synthetic-label'
        $setting.contentType = 'text/plain'
        if (-not $setting.Contains('sourceResourceId')) { $setting.sourceResourceId = ''; $setting.sourceProperty = '' }
    }
    $output = @{
        schemaVersion = 1; environment = 'dev'; tenantId = $profile.azure.tenantId
        subscriptionId = $profile.azure.subscriptionId; resourceGroup = $profile.azure.resourceGroup; release = $profile.release
        appConfiguration = @{ endpoint = 'https://synthetic-config.azconfig.io'; resourceId = "$scope/providers/Microsoft.AppConfiguration/configurationStores/synthetic-config"; settings = $settings }
        applications = @(@{
            name = $profile.application.name
            resourceId = "$scope/providers/Microsoft.App/containerApps/$($profile.application.name)"
            fqdn = 'synthetic-app.internal.synthetic.eastus2.azurecontainerapps.io'
            image = "syntheticneverdeployacr.azurecr.io/$($profile.application.imageRepository)@$($profile.release.imageDigest)"
            principalId = $profile.identities.workload.principalId; identityResourceId = $profile.identities.workload.resourceId
        })
        gateway = @{
            accessMode = 'gateway'; endpoint = "https://synthetic-gateway.azure-api.net/inference/$($profile.gateway.workloadKey)/v1/responses"
            resourceId = "$scope/providers/Microsoft.ApiManagement/service/synthetic-gateway"; audience = $profile.gateway.audience
            privateEndpointResourceId = "$scope/providers/Microsoft.Network/privateEndpoints/synthetic-gateway-inbound"
            backendResourceId = "$scope/providers/Microsoft.CognitiveServices/accounts/synthetic-backend"
            backendEndpoint = 'https://synthetic-backend.openai.azure.com/'
        }
        workspace = @{ repository = $profile.application.workspaceRepository; ref = $profile.application.workspaceRef }
        registryResourceId = $profile.application.registryResourceId
        vnetResourceId = "$scope/providers/Microsoft.Network/virtualNetworks/synthetic-spoke"
    }
    $app = $output.applications[0]
    $environment = @($settings | Where-Object { $_.name -cmatch '^(SMOKE_|INFERENCE_|AZURE_)' } | ForEach-Object { @{ name = $_.name; value = $_.value } })
    $environment += @{ name = 'APP_CONFIG_ENDPOINT'; value = $output.appConfiguration.endpoint }
    $template = @{ containers = @(@{ name = $app.name; image = $app.image; env = $environment }) }
    $state = @{
        calls = [Collections.Generic.List[object]]::new()
        entries = @{}
        failures = [Collections.Generic.Queue[int]]::new()
        addresses = @('10.220.2.5')
        healthVersion = $profile.release.sourceSha
        publicConfig = $false
        dirty = $false
        workspaceHead = $profile.application.workspaceRef
        workspaceOrigin = $profile.application.workspaceRepository
        missingTool = ''
        system = $false
        nativeFailure = $false
        gatewayReady = $true
        template = $template
        ssoType = 'user'
        unauthorizedStatus = 401
        inferStatus = 200
        directStatus = 403
        outputText = 'READY'
    }
    $arm = {
        param($id, $apiVersion)
        $state.calls.Add(@{ kind = 'arm'; id = $id; apiVersion = $apiVersion })
        if ($id -eq $output.appConfiguration.resourceId) {
            return @{ id = $id; properties = @{ endpoint = $output.appConfiguration.endpoint; publicNetworkAccess = $(if ($state.publicConfig) { 'Enabled' } else { 'Disabled' }); privateEndpointConnections = @(@{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved' } } }) } }
        }
        if ($id -eq $output.vnetResourceId) { return @{ id = $id; properties = @{ addressSpace = @{ addressPrefixes = @('10.220.0.0/16') } } } }
        if ($id -eq $output.registryResourceId) { return @{ id = $id; properties = @{ loginServer = 'syntheticneverdeployacr.azurecr.io' } } }
        if ($id -eq $output.gateway.backendResourceId) { return @{ id = $id; properties = @{ publicNetworkAccess = 'Disabled'; disableLocalAuth = $true } } }
        if ($id -like '*/Microsoft.Insights/components/*') { return @{ id = $id; properties = @{ ConnectionString = 'PRIVATE-OBSERVABILITY-VALUE' } } }
        if ($id -eq $app.resourceId) {
            return @{
                id = $id
                identity = @{ userAssignedIdentities = @{ $app.identityResourceId = @{ clientId = $profile.identities.workload.clientId; principalId = $profile.identities.workload.principalId } } }
                properties = @{
                    latestRevisionName = "$($app.name)--synthetic"; latestReadyRevisionName = "$($app.name)--synthetic"
                    template = $state.template
                    configuration = @{ ingress = @{ fqdn = $app.fqdn; external = $false; traffic = @(@{ latestRevision = $true; weight = 100 }) } }
                }
            }
        }
        if ($id -eq "$($app.resourceId)/revisions") {
            return @{ value = @(@{ name = "$($app.name)--synthetic"; properties = @{ active = $true; healthState = 'Healthy'; runningState = 'Running'; template = $state.template } }) }
        }
        throw "Unexpected fake management read: $id"
    }.GetNewClosure()
    $http = {
        param($method, $uri, $headers, $body, $addresses)
        $state.calls.Add(@{ kind = 'http'; method = $method; uri = [string]$uri; headers = $headers; body = $body; addresses = $addresses })
        $url = [uri]$uri
        if ($url.AbsolutePath.StartsWith('/kv/')) {
            if ($state.failures.Count) {
                $status = $state.failures.Dequeue()
                if ($status -ne 200) { return @{ statusCode = $status; headers = @{ 'Retry-After' = '0' }; body = @{} } }
            }
            $name = [uri]::UnescapeDataString($url.AbsolutePath.Substring(4))
            $label = ($url.Query.TrimStart('?').Split('&') | Where-Object { $_.StartsWith('label=') }).Substring(6)
            $key = "$name|$label"
            if ($method -eq 'GET') {
                if (-not $state.entries.Contains($key)) { return @{ statusCode = 404; headers = @{}; body = @{} } }
                return @{ statusCode = 200; headers = @{ ETag = '"synthetic-etag"' }; body = $state.entries[$key] }
            }
            Assert-True ($method -ceq 'PUT') 'No deletion is permitted.'
            Assert-True ($headers.Contains('If-Match') -or $headers.Contains('If-None-Match')) 'Unconditional App Configuration overwrite.'
            $state.entries[$key] = $body
            return @{ statusCode = 200; headers = @{ ETag = '"synthetic-etag"' }; body = $body }
        }
        if ($url.AbsolutePath -in @('/health', '/ready')) {
            return @{ statusCode = 200; headers = @{}; body = @{ service = 'developer-smoke'; version = $state.healthVersion; status = $(if ($url.AbsolutePath -eq '/health') { 'ok' } else { 'ready' }) } }
        }
        if ($url.AbsolutePath -eq '/infer') {
            $status = if (-not $headers.Contains('Authorization') -or $headers.Authorization -eq 'Bearer deliberately-invalid') { $state.unauthorizedStatus } else { $state.inferStatus }
            return @{ statusCode = $status; headers = @{ 'x-correlation-id' = $headers['x-correlation-id']; 'apim-request-id' = 'synthetic-apim-correlation' }; body = @{
                id = 'resp_synthetic'; object = 'response'; status = 'completed'
                output = @(@{ type = 'message'; content = @(@{ type = 'output_text'; text = $state.outputText }) })
                usage = @{ input_tokens = 8; output_tokens = 1; total_tokens = 9 }
            } }
        }
        if ($url.AbsolutePath -eq '/openai/v1/responses') { return @{ statusCode = $state.directStatus; headers = @{ 'x-ms-request-id' = 'synthetic-backend-correlation' }; body = @{} } }
        return @{ statusCode = 401; headers = @{}; body = @{} }
    }.GetNewClosure()
    $native = {
        param($command, $arguments)
        $state.calls.Add(@{ kind = 'native'; command = $command; arguments = $arguments })
        if ($state.nativeFailure) { throw 'Native authentication or fetch failed.' }
        if ($command -eq 'python' -and $arguments[0] -eq '--version') { return 'Python 3.13.14' }
        if ($command -eq 'pwsh') { return 'PowerShell 7.5.2' }
        if ($command -eq 'git') {
            if ($arguments -contains '--porcelain=v1') { return $(if ($state.dirty) { ' M keep.txt' } else { '' }) }
            if ($arguments -contains '--get') { return $state.workspaceOrigin }
            if ($arguments -contains '--show-toplevel') { return $arguments[1] }
            if ($arguments -contains 'rev-parse') { return $state.workspaceHead }
            return 'git version synthetic'
        }
        if ($command -eq 'az' -and $arguments -contains 'show') {
            return (ConvertTo-Json -InputObject @{ id = $profile.azure.subscriptionId; tenantId = $profile.azure.tenantId; user = @{ type = $state.ssoType; name = $profile.identities.deploy.clientId } } -Compress)
        }
        return 'synthetic-tool-version'
    }.GetNewClosure()
    $adapter = @{
        ArmGet = $arm; Http = $http; Native = $native
        Resolve = { param($hostname) $state.calls.Add(@{ kind = 'dns'; host = $hostname }); return ,$state.addresses }.GetNewClosure()
        Token = { param($audience) $state.calls.Add(@{ kind = 'token'; audience = $audience }); return 'synthetic-token' }.GetNewClosure()
        Sleep = { param($seconds) $state.calls.Add(@{ kind = 'sleep'; seconds = $seconds }) }.GetNewClosure()
        Gateway = { param($resolution, $output) if (-not $state.gatewayReady) { throw 'Gateway private verification failed.' }; return @{ privateReady = $true } }.GetNewClosure()
        Tool = { param($name) if ($state.missingTool -eq $name) { throw 'Required tool is missing.' }; return $name }.GetNewClosure()
        IsSystem = { return $state.system }.GetNewClosure()
    }
    return @{ resolution = $resolution; output = $output; state = $state; adapter = $adapter }
}
function Complete-Fixture($fixture) {
    Invoke-DeveloperCompletion -Resolution $fixture.resolution -DeploymentOutput $fixture.output -OfflineTest -Adapter $fixture.adapter
}

Test-Case 'Library imports preserve the caller environment exports' {
    $names = @('Read-EnvironmentProfile', 'Resolve-EnvironmentProfile', 'ConvertTo-CanonicalJson', 'Get-CanonicalHash', 'Invoke-CheckedNative', 'Write-JsonFile')
    foreach ($name in $names) { Assert-True ($null -ne (Get-Command $name -ErrorAction Stop)) 'Caller export was unavailable before import.' }
    Import-Module (Join-Path $root 'scripts\github\Completion.psm1') -ErrorAction Stop
    foreach ($name in $names) { Assert-True ($null -ne (Get-Command $name -ErrorAction Stop)) 'Completion library unloaded a caller export.' }
    $f = New-Fixture
    Assert-True (-not $f.output.Contains('INFERENCE_ACCESS_MODE') -and $f.output.gateway.accessMode -ceq 'gateway') 'Fixture must use only the nested gateway access-mode output contract.'
}

Test-Case 'Management reads retain real ETags for P3 without credentials or redirect fallback' {
    $f = New-Fixture
    $state = @{ calls = [Collections.Generic.List[object]]::new(); attempts = 0 }
    $native = {
        param($command, $arguments)
        Assert-True ($command -ceq 'az' -and $arguments[0] -ceq 'account' -and $arguments[1] -ceq 'get-access-token') 'Management authentication left Azure login.'
        return '{"accessToken":"synthetic-management-token"}'
    }
    $http = {
        param($method, $uri, $headers, $body, $addresses)
        Assert-True ($method -ceq 'GET' -and ([uri]$uri).DnsSafeHost -ceq 'management.azure.com' -and $null -eq $body) 'Management transport attempted a write or alternate origin.'
        Assert-True ($headers.Authorization -ceq 'Bearer synthetic-management-token' -and $addresses[0] -ceq '203.0.113.7') 'Management token or checked destination was lost.'
        $state.attempts++
        if ($state.attempts -eq 1) { return @{ statusCode = 429; headers = @{ 'Retry-After' = '0' }; body = @{} } }
        return @{ statusCode = 200; headers = @{ ETag = '"server-etag"' }; body = @{ properties = @{ description = 'owned metadata' } } }
    }.GetNewClosure()
    $resolve = { param($hostname) Assert-True ($hostname -ceq 'management.azure.com') 'Unapproved management hostname.'; return ,@('203.0.113.7') }
    $sleep = { param($seconds) $state.calls.Add($seconds) }.GetNewClosure()
    $result = & (Get-Module Completion) {
        param($id, $native, $http, $resolve, $sleep)
        Invoke-CompletionArmGet -ResourceId $id -ApiVersion '2024-05-01' -Native $native -Http $http -Resolve $resolve -Sleep $sleep
    } $f.output.gateway.resourceId $native $http $resolve $sleep
    Assert-True ($result.etag -ceq '"server-etag"' -and $result.properties.description -ceq 'owned metadata') 'Observed server ETag or entity body was dropped.'
    Assert-True ($state.attempts -eq 2 -and $state.calls.Count -eq 1) 'Management retry did not remain bounded and transient-only.'
}

Test-Case 'Plan-only never consults credentials, DNS, native commands or APIs' {
    $f = New-Fixture
    $result = Invoke-DeveloperCompletion -Resolution $f.resolution -DeploymentOutput $f.output -Adapter $f.adapter
    Assert-True ($f.state.calls.Count -eq 0) 'Plan mode performed an operation.'
    Assert-True (-not $result.runnerReady -and -not $result.promotionEligible) 'Plan was presented as ready.'
}
Test-Case 'Execution rejects synthetic inputs and injected production adapters' {
    $f = New-Fixture
    Assert-Rejected { Invoke-DeveloperCompletion -Resolution $f.resolution -DeploymentOutput $f.output -Execute -Adapter $f.adapter }
    Assert-Rejected { Invoke-DeveloperCompletion -Resolution $f.resolution -DeploymentOutput $f.output -Execute }
    Assert-True ($f.state.calls.Count -eq 0) 'Rejected execution called a transport.'
}
Test-Case 'Completion populates all supplied keys and reruns without writes or image updates' {
    $f = New-Fixture
    $first = Complete-Fixture $f
    Assert-True ($f.state.entries.Count -eq $f.output.appConfiguration.settings.Count) 'Supplied optional settings were dropped.'
    $firstPuts = @($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count
    $second = Complete-Fixture $f
    Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count -eq $firstPuts) 'Idempotent rerun wrote again.'
    Assert-True ($second.configuration.unchanged -eq $f.output.appConfiguration.settings.Count) 'Rerun did not verify existing values.'
    Assert-True (-not $first.humanReady -and -not $first.promotionEligible) 'Runner access was mistaken for human readiness.'
    Assert-True ((ConvertTo-CanonicalJson $second) -notlike '*PRIVATE-OBSERVABILITY-VALUE*') 'Evidence leaked observability credentials.'
    Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'native' -and ($_.arguments -contains 'update') }).Count -eq 0) 'Completion repaired the image imperatively.'
}
Test-Case 'Unrelated and unowned existing configuration survives' {
    $f = New-Fixture
    $f.state.entries['unrelated|synthetic-label'] = @{ value = 'KEEP'; tags = @{ thirdParty = 'owner' } }
    $name = $f.output.appConfiguration.settings[0].name
    $f.state.entries["$name|synthetic-label"] = @{ value = 'DO NOT OVERWRITE'; content_type = 'text/plain'; tags = @{} }
    Assert-Rejected { Complete-Fixture $f } '*ownership*'
    Assert-True ($f.state.entries["$name|synthetic-label"].value -eq 'DO NOT OVERWRITE') 'Unowned configuration was overwritten.'
    Assert-True ($f.state.entries['unrelated|synthetic-label'].value -eq 'KEEP') 'Unrelated configuration was changed.'
    Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count -eq 0) 'Conflict preflight allowed a partial write.'
}
Test-Case 'Transient retries are bounded; forbidden access and ETag races are fatal' {
    $f = New-Fixture
    $f.state.failures.Enqueue(429); $f.state.failures.Enqueue(503)
    Complete-Fixture $f | Out-Null
    Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'sleep' }).Count -eq 2) 'Transient retry count mismatch.'
    foreach ($status in @(403, 412)) {
        $f = New-Fixture
        $f.state.failures.Enqueue($status)
        Assert-Rejected { Complete-Fixture $f }
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'sleep' }).Count -eq 0) 'Fatal status was retried.'
    }
    $f = New-Fixture
    1..5 | ForEach-Object { $f.state.failures.Enqueue(503) }
    Assert-Rejected { Complete-Fixture $f }
    Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'sleep' }).Count -eq 2) 'Retries were unbounded.'
}
Test-Case 'A partial write failure propagates; rerun reconciles only outstanding keys' {
    $f = New-Fixture
    $originalHttp = $f.adapter.Http
    $counter = @{ puts = 0; fail = $true }
    $f.adapter.Http = {
        param($method, $uri, $headers, $body, $addresses)
        if ($method -eq 'PUT') {
            $counter.puts++
            if ($counter.fail -and $counter.puts -eq 2) { return @{ statusCode = 403; body = @{}; headers = @{} } }
        }
        & $originalHttp $method $uri $headers $body $addresses
    }.GetNewClosure()
    Assert-Rejected { Complete-Fixture $f }
    Assert-True ($f.state.entries.Count -eq 1) 'Failure did not stop subsequent writes.'
    $counter.fail = $false
    Complete-Fixture $f | Out-Null
    Assert-True ($f.state.entries.Count -eq $f.output.appConfiguration.settings.Count) 'Partial rerun did not complete.'
}
Test-Case 'Private routing, active digest, required config and starter identity fail closed' {
    foreach ($change in @(
        { param($f) $f.state.addresses = @('8.8.8.8') },
        { param($f) $f.state.addresses = @('10.220.2.5', '8.8.8.8') },
        { param($f) $f.state.addresses = @('10.221.2.5') },
        { param($f) $f.state.publicConfig = $true },
        { param($f) $f.state.template.containers[0].image = 'mcr.microsoft.com/dotnet/samples:aspnetapp' },
        { param($f) $f.state.template.containers[0].env = @($f.state.template.containers[0].env | Where-Object { $_.name -ne 'SMOKE_MODEL_DEPLOYMENT' }) },
        { param($f) $f.state.healthVersion = 'generic-200-placeholder' },
        { param($f) $f.state.gatewayReady = $false }
    )) {
        $f = New-Fixture
        & $change $f
        Assert-Rejected { Complete-Fixture $f }
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count -eq 0) 'Private/image/config preflight failed after mutation.'
    }
    Test-Case 'Owned changed values retain unrelated tags and use the exact prior ETag' {
        $f = New-Fixture
        Complete-Fixture $f | Out-Null
        $key = 'CUSTOM_OPTIONAL_COSMOS_SETTING|synthetic-label'
        $f.state.entries[$key].tags['other-owner-metadata'] = 'PRESERVE'
        $f.state.entries[$key].value = 'old-owned-value'
        $result = Complete-Fixture $f
        Assert-True ($result.configuration.updated -eq 1) 'Changed owned setting was not reconciled.'
        Assert-True ($f.state.entries[$key].value -eq 'preserve-all-supplied-settings') 'Owned setting did not persist.'
        Assert-True ($f.state.entries[$key].tags['other-owner-metadata'] -eq 'PRESERVE') 'Unrelated metadata was removed.'
        $put = @($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' })[-1]
        Assert-True ($put.headers['If-Match'] -ceq '"synthetic-etag"') 'Prior ETag was not used.'
    }
    Test-Case 'A second deployment reverting to a placeholder fails without an imperative repair' {
        $f = New-Fixture
        Complete-Fixture $f | Out-Null
        $writes = @($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count
        $f.state.template.containers[0].image = 'mcr.microsoft.com/dotnet/samples:aspnetapp'
        Assert-Rejected { Complete-Fixture $f } '*image*'
        Assert-True ($f.state.template.containers[0].image -eq 'mcr.microsoft.com/dotnet/samples:aspnetapp') 'Completion took image ownership away from infrastructure.'
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count -eq $writes) 'Failed second deployment changed configuration.'
    }
    Test-Case 'The real P3 verifier is wired through GET-only fake management reads' {
        $f = New-Fixture
        $production = & (Get-Module Completion) { New-CompletionAdapter }
        $f.adapter.Gateway = $production.Gateway
        $originalArm = $f.adapter.ArmGet
        $id = $f.output.gateway.resourceId
        $workloadKey = $f.resolution.profile.gateway.workloadKey
        $owner = "ailz-inference-dev-$workloadKey"
        $pe = $f.output.gateway.privateEndpointResourceId
        $serviceTags = @{
            'ailz-managed-by' = 'github-dev-environment'
            'ailz-environment' = $f.resolution.environment
            'ailz-owner' = $owner
        }
        $peTags = @{} + $serviceTags
        $reads = [Collections.Generic.List[string]]::new()
        $f.adapter.ArmGet = {
            param($resourceId, $apiVersion)
            $reads.Add($resourceId)
            if ($resourceId -eq $id) {
                return @{ id = $id; tags = $serviceTags; properties = @{
                    publicNetworkAccess = 'Disabled'; provisioningState = 'Succeeded'
                    privateEndpointConnections = @(@{ properties = @{
                        privateEndpoint = @{ id = $pe }
                        privateLinkServiceConnectionState = @{ status = 'Approved' }
                    } })
                } }
            }
            if ($resourceId -eq $pe) {
                return @{ id = $pe; tags = $peTags; properties = @{ provisioningState = 'Succeeded'; privateLinkServiceConnections = @(@{ properties = @{
                    privateLinkServiceId = $id; groupIds = @('Gateway'); privateLinkServiceConnectionState = @{ status = 'Approved' }
                } }) } }
            }
            if ($resourceId -eq "$id/apis") {
                return @{ value = @(@{ name = $owner; properties = @{ description = "owner:$owner"; path = "inference/$workloadKey"; subscriptionRequired = $false } }) }
            }
            if ($resourceId -eq "$id/apis/$owner/operations") {
                return @{ value = @(@{ name = 'responses'; properties = @{ description = "owner:$owner"; method = 'POST'; urlTemplate = '/v1/responses' } }) }
            }
            if ($resourceId -cin @("$id/apis/$owner/policies/policy", "$id/apis/$owner/schemas/responses", "$id/apis/$owner/diagnostics/applicationinsights")) {
                return @{ id = $resourceId; etag = '"synthetic-api-child-etag"'; properties = @{ description = 'Synthetic offline owned-child observation' } }
            }
            if ($resourceId -eq "$id/backends") {
                return @{ value = @(@{ name = "$owner-foundry"; properties = @{ description = "owner:$owner" } }) }
            }
            if ($resourceId -eq "$id/namedValues") {
                return @{ value = @('configuration', 'tenant', 'audience', 'stop' | ForEach-Object { @{ name = "$owner-$_"; properties = @{ tags = @($owner) } } }) }
            }
            if ($resourceId -eq "$id/loggers") { return @{ value = @() } }
            if ($resourceId -cmatch ('^' + [regex]::Escape($id) + '/(apis|backends|namedValues)/[^/]+$')) {
                return @{ id = $resourceId; etag = '"synthetic-observed-etag"'; properties = @{ description = "owner:$owner" } }
            }
            return & $originalArm $resourceId $apiVersion
        }.GetNewClosure()
        $result = Complete-Fixture $f
        Assert-True ($result.mode -ceq 'offline-test') 'Fake execution was mislabeled.'
        Assert-True ($reads -contains $pe -and $reads -contains "$id/apis/$owner/operations") 'P3 private endpoint or governed operation verification was skipped.'
        foreach ($child in @('policies/policy', 'schemas/responses', 'diagnostics/applicationinsights')) {
            Assert-True ($reads -contains "$id/apis/$owner/$child") 'P3 owned API-child inventory was skipped.'
        }
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'native' -and $_.arguments -contains 'rest' }).Count -eq 0) 'Production gateway adapter escaped the fake management boundary.'
        $writes = @($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count
        $serviceTags.Remove('ailz-owner')
        $peTags.Remove('ailz-owner')
        Complete-Fixture $f | Out-Null
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count -eq $writes) 'Valid parent-pair ownership was not an idempotent rerun.'
        $serviceTags['ailz-owner'] = $owner
        $peTags['ailz-owner'] = $owner
        foreach ($ownership in @(
            @{ tags = $serviceTags; kind = 'service' },
            @{ tags = $peTags; kind = 'private endpoint' }
        )) {
            foreach ($key in @('ailz-managed-by', 'ailz-environment')) {
                $expected = $ownership.tags[$key]
                $ownership.tags.Remove($key)
                Assert-Rejected { Complete-Fixture $f } "*$($ownership.kind) ownership conflict*"
                $ownership.tags[$key] = 'invalid-parent-tag'
                Assert-Rejected { Complete-Fixture $f } "*$($ownership.kind) ownership conflict*"
                $ownership.tags[$key] = $expected
            }
            $ownership.tags['ailz-owner'] = 'ailz-inference-other'
            Assert-Rejected { Complete-Fixture $f } "*$($ownership.kind) ownership conflict*"
            $ownership.tags['ailz-owner'] = $owner
        }
        $f.output.gateway.privateEndpointResourceId = "$pe-other"
        Assert-Rejected { Complete-Fixture $f } '*private endpoint*'
        $f.output.gateway.Remove('privateEndpointResourceId')
        Assert-Rejected { Complete-Fixture $f } '*private endpoint*'
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'PUT' }).Count -eq $writes) 'Ownership or declared-PE mismatch permitted configuration writes.'
    }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('completion-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$workspace = Join-Path $scratch 'customer-work'
$bootstrap = Join-Path $scratch 'disposable-bootstrap'
[IO.Directory]::CreateDirectory($workspace) | Out-Null
[IO.File]::WriteAllText((Join-Path $workspace 'keep.txt'), 'user-owned-work')
try {
    Test-Case 'Direct and ARM-enveloped completion outputs and every default CLI stay local plans' {
        $f = New-Fixture
        $profileFile = Join-Path $scratch 'profile.json'
        $outputFile = Join-Path $scratch 'outputs.json'
        Write-JsonFile $profileFile $f.resolution.profile
        Write-JsonFile $outputFile @{ properties = @{ outputs = @{ DEVELOPER_COMPLETION = @{ type = 'Object'; value = $f.output } } } }
        $read = Read-DeveloperCompletionOutput $outputFile
        Assert-True ((Get-CanonicalHash $read) -ceq (Get-CanonicalHash $f.output)) 'ARM output was not unwrapped exactly.'
        $completion = & (Join-Path $root 'scripts\github\Complete-DeveloperEnvironment.ps1') -ProfilePath $profileFile -DeploymentOutputsPath $outputFile | ConvertFrom-Json -AsHashtable
        $gate = & (Join-Path $root 'scripts\github\Invoke-LiveDevGate.ps1') -ProfilePath $profileFile -DeploymentOutputsPath $outputFile | ConvertFrom-Json -AsHashtable
        $workspacePlan = & (Join-Path $root 'scripts\github\Prepare-DeveloperWorkspace.ps1') -ProfilePath $profileFile -WorkspacePath $workspace -BootstrapCheckoutPath $bootstrap | ConvertFrom-Json -AsHashtable
        Assert-True ($completion.mode -ceq 'plan' -and $gate.mode -ceq 'plan' -and $workspacePlan.mode -ceq 'plan') 'A default entry point executed instead of planning.'
        Assert-True (-not $gate.promotionEligible -and -not $completion.runnerReady -and -not $workspacePlan.humanReady) 'A default CLI emitted ready evidence.'
        Write-JsonFile $outputFile $f.output
        Assert-True ((Get-CanonicalHash (Read-DeveloperCompletionOutput $outputFile)) -ceq (Get-CanonicalHash $f.output)) 'Direct output could not be read.'
        [IO.File]::Delete($profileFile)
        [IO.File]::Delete($outputFile)
    }
    Test-Case 'Live plan cannot publish or replace an observed evidence artifact' {
        $f = New-Fixture
        $profileFile = Join-Path $scratch 'profile.json'
        $outputFile = Join-Path $scratch 'outputs.json'
        $evidenceFile = Join-Path $scratch 'live-evidence.json'
        Write-JsonFile $profileFile $f.resolution.profile
        Write-JsonFile $outputFile $f.output
        $entry = Join-Path $root 'scripts\github\Invoke-LiveDevGate.ps1'
        Assert-Rejected { & $entry -ProfilePath $profileFile -DeploymentOutputsPath $outputFile -EvidencePath $evidenceFile } '*observed*'
        Assert-True (-not (Test-Path -LiteralPath $evidenceFile)) 'A plan was persisted as observed evidence.'
        [IO.File]::WriteAllText($evidenceFile, 'preserve-existing-evidence')
        Assert-Rejected { & $entry -ProfilePath $profileFile -DeploymentOutputsPath $outputFile -EvidencePath $evidenceFile } '*observed*'
        Assert-True ([IO.File]::ReadAllText($evidenceFile) -ceq 'preserve-existing-evidence') 'Plan mode replaced existing evidence.'
        [IO.File]::Delete($profileFile)
        [IO.File]::Delete($outputFile)
        [IO.File]::Delete($evidenceFile)
    }
    Test-Case 'Workspace plan, SYSTEM guard, required tools and dirty/ref preservation' {
        $f = New-Fixture
        $plan = Invoke-DeveloperWorkspace -Resolution $f.resolution -WorkspacePath $workspace -BootstrapCheckoutPath $bootstrap -Adapter $f.adapter
        Assert-True ($f.state.calls.Count -eq 0 -and -not $plan.humanReady) 'Plan prepared or authenticated a workspace.'
        foreach ($change in @(
            { param($f) $f.state.system = $true },
            { param($f) $f.state.dirty = $true },
            { param($f) $f.state.workspaceHead = '3' * 40 },
            { param($f) $f.state.workspaceOrigin = 'https://github.com/unapproved/repository' },
            { param($f) $f.state.missingTool = 'azd' },
            { param($f) $f.state.nativeFailure = $true },
            { param($f) $f.state.ssoType = 'servicePrincipal' }
        )) {
            $f = New-Fixture
            & $change $f
            Assert-Rejected { Invoke-DeveloperWorkspace -Resolution $f.resolution -WorkspacePath $workspace -BootstrapCheckoutPath $bootstrap -OfflineTest -Adapter $f.adapter }
            Assert-True ([IO.File]::ReadAllText((Join-Path $workspace 'keep.txt')) -eq 'user-owned-work') 'User files changed.'
            foreach ($call in @($f.state.calls | Where-Object { $_.kind -eq 'native' })) {
                Assert-True (-not (@('reset', 'clean', 'checkout', 'switch', 'fetch', 'login') | Where-Object { $call.arguments -contains $_ })) 'Existing workspace/ref/authentication was modified.'
            }
        }
        Assert-Rejected { Invoke-DeveloperWorkspace -Resolution $f.resolution -WorkspacePath $bootstrap -BootstrapCheckoutPath $bootstrap -OfflineTest -Adapter $f.adapter }
    }
    Test-Case 'Clean workspace uses only its pinned local venv; dependency failure cannot return ready' {
        $sample = Join-Path $workspace 'samples\developer-smoke'
        [IO.Directory]::CreateDirectory($sample) | Out-Null
        $lockFile = Join-Path $sample 'requirements.lock'
        [IO.File]::WriteAllText($lockFile, '# synthetic; fake native transport never installs')
        $f = New-Fixture
        $result = Invoke-DeveloperWorkspace -Resolution $f.resolution -WorkspacePath $workspace -BootstrapCheckoutPath $bootstrap -OfflineTest -Adapter $f.adapter
        Assert-True (-not $result.humanReady -and -not $result.workspacePrepared) 'Offline workspace test claimed human readiness.'
        $installs = @($f.state.calls | Where-Object { $_.kind -eq 'native' -and $_.arguments -contains 'install' })
        Assert-True ($installs.Count -eq 1 -and $installs[0].command -like '*developer-smoke*.venv*python*' -and $installs[0].arguments -contains '--require-hashes') 'Dependencies escaped the locked local venv.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $workspace 'keep.txt')) -eq 'user-owned-work') 'User work changed.'
        $originalNative = $f.adapter.Native
        $f.adapter.Native = {
            param($command, $arguments)
            if ($arguments -contains 'install') { throw 'Required dependency install failed.' }
            return & $originalNative $command $arguments
        }.GetNewClosure()
        Assert-Rejected { Invoke-DeveloperWorkspace -Resolution $f.resolution -WorkspacePath $workspace -BootstrapCheckoutPath $bootstrap -OfflineTest -Adapter $f.adapter } '*dependency*'
        [IO.File]::Delete($lockFile)
        [IO.Directory]::Delete($sample)
        [IO.Directory]::Delete((Join-Path $workspace 'samples'))
    }
    Test-Case 'Live gate default cannot spend; approval, budget and synthetic execute guards are mandatory' {
        $f = New-Fixture
        $plan = Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -Adapter $f.adapter
        Assert-True (-not $plan.promotionEligible -and $plan.pending.Count -gt 0) 'Health-only plan became promotion evidence.'
        Assert-True ($f.state.calls.Count -eq 0) 'Default gate performed HTTP or credential work.'
        Assert-Rejected { Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -ExecutePaidProbes }
        Assert-Rejected { Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -OfflineTest -Adapter $f.adapter -MaxRequests 0 -MaxTotalTokens 0 }
        Assert-True ($f.state.calls.Count -eq 0) 'Rejected paid gate called a transport.'
    }
    Test-Case 'All required P5 checks have nonempty pending descriptions before observation' {
        $f = New-Fixture
        $plan = Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -Adapter $f.adapter
        $expected = @('privateConnectivity', 'identityIsolation', 'applicationInference', 'gatewayEnforcement',
            'meteringCoverage', 'costOperations', 'promotionIntegrity', 'recovery', 'developerWorkspace')
        Assert-True (($expected | Sort-Object) -join ',' -ceq (($plan.checks.Keys | Sort-Object) -join ',')) 'Live-gate keys differ from the frozen P5 contract.'
        foreach ($name in $expected) {
            Assert-True ($plan.checks[$name].status -ceq 'pending' -and
                -not [string]::IsNullOrWhiteSpace($plan.checks[$name].evidence)) 'An unobserved gate has no pending description or was marked passed.'
        }
        Assert-True ($null -eq $plan.observedAt -and $plan.probes.Count -eq 0 -and
            $f.state.calls.Count -eq 0 -and -not $plan.promotionEligible) 'Plan mode claimed observations or promotion eligibility.'
    }
    Test-Case 'Locally simulated live probes preserve pending full-gate evidence and reject bypass success' {
        $f = New-Fixture
        $arguments = @{
            Resolution = $f.resolution; DeploymentOutput = $f.output; Adapter = $f.adapter; OfflineTest = $true
            ApprovedEnvironment = 'dev'; ApprovedSourceSha = $f.resolution.profile.release.sourceSha
            MaxRequests = 4; MaxTotalTokens = 512; IdentityContext = 'human'
            ReleaseFingerprint = 'b' * 64; WorkflowRunId = 12345
        }
        $evidence = Invoke-LiveDeveloperGate @arguments
        Assert-True (-not $evidence.promotionEligible) 'Incomplete identity/enforcement evidence was promoted.'
        Assert-True ($evidence.probes.applicationInference.status -ceq 'passed') 'Positive application request not observed.'
        Assert-True ($evidence.probes.unauthenticated.status -ceq 'passed') 'Unauthenticated rejection not observed.'
        Assert-True ($evidence.probes.directBackendHuman.status -ceq 'passed') 'Available caller bypass check not observed.'
        Assert-True ($evidence.checks.gatewayEnforcement.status -ceq 'pending') 'Native rate/quota/stop checks were fabricated.'
        foreach ($check in $evidence.checks.Values) {
            Assert-True ($check.status -ceq 'pending' -and -not [string]::IsNullOrWhiteSpace($check.evidence)) 'Offline simulation was emitted as a passed live gate.'
        }
        Assert-True ($null -eq $evidence.observedAt) 'Offline simulation claimed a live observation timestamp.'
        $f.state.directStatus = 200
        Assert-Rejected { Invoke-LiveDeveloperGate @arguments } '*bypass*'
    }
    Test-Case 'Live positive probe checks its actual text, not only a success-shaped Responses object' {
        $f = New-Fixture
        $f.state.outputText = 'WRONG'
        Assert-Rejected {
            Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -OfflineTest -Adapter $f.adapter `
                -ApprovedEnvironment 'dev' -ApprovedSourceSha $f.resolution.profile.release.sourceSha `
                -MaxRequests 4 -MaxTotalTokens 512 -ReleaseFingerprint ('b' * 64) -WorkflowRunId 12345
        }
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/openai/v1/responses' }).Count -eq 0) 'Incorrect application output was accepted before the bypass probe.'
    }
    Test-Case 'Runner context proves caller rejection rather than assuming it is an allowed developer' {
        $f = New-Fixture
        $f.state.ssoType = 'servicePrincipal'
        $f.state.inferStatus = 403
        $result = Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -OfflineTest -Adapter $f.adapter `
            -ApprovedEnvironment 'dev' -ApprovedSourceSha $f.resolution.profile.release.sourceSha `
            -MaxRequests 4 -MaxTotalTokens 512 -ReleaseFingerprint ('b' * 64) -WorkflowRunId 12345 -IdentityContext runner
        Assert-True ($result.probes.applicationForbiddenRunner.status -ceq 'passed') 'Runner caller separation was not observed.'
        Assert-True ($result.checks.applicationInference.status -ceq 'pending') 'A rejected runner request was labeled successful inference.'
        Assert-True ($result.probes.directBackendRunner.status -ceq 'passed') 'Runner direct-backend rejection was not observed.'
        Assert-True (-not $result.promotionEligible) 'Partial runner observations became promotion eligible.'
    }
    Test-Case 'The live private gate also rejects App Configuration public access' {
        $f = New-Fixture
        $f.state.publicConfig = $true
        Assert-Rejected {
            Invoke-LiveDeveloperGate -Resolution $f.resolution -DeploymentOutput $f.output -OfflineTest -Adapter $f.adapter `
                -ApprovedEnvironment 'dev' -ApprovedSourceSha $f.resolution.profile.release.sourceSha `
                -MaxRequests 4 -MaxTotalTokens 512 -ReleaseFingerprint ('b' * 64) -WorkflowRunId 12345
        }
        Assert-True (@($f.state.calls | Where-Object { $_.kind -eq 'http' -and $_.method -eq 'POST' }).Count -eq 0) 'Public routing preflight permitted an inference attempt.'
    }
}
finally {
    foreach ($file in @((Join-Path $scratch 'profile.json'), (Join-Path $scratch 'outputs.json'), (Join-Path $scratch 'live-evidence.json'), (Join-Path $workspace 'samples\developer-smoke\requirements.lock'))) {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    foreach ($directory in @((Join-Path $workspace 'samples\developer-smoke'), (Join-Path $workspace 'samples'))) {
        if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory) }
    }
    [IO.File]::Delete((Join-Path $workspace 'keep.txt'))
    [IO.Directory]::Delete($workspace)
    [IO.Directory]::Delete($scratch)
}
Write-Host "Completion tests: $script:passed passed; $script:failed failed."
if ($script:failed) { exit 1 }
