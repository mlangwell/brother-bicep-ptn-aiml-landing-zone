#Requires -Version 7.0
<#
.SYNOPSIS
Runs dependency-free, deterministic tests of the shared environment contract.
.DESCRIPTION
No Azure, GitHub, azd, inference, credentials, packages or remote state are used.
Every deployment-shaped input is synthetic and must opt in to offline resolution.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $root 'scripts\github\Environment.psm1'
$resolverPath = Join-Path $root 'scripts\github\Resolve-Environment.ps1'
$fixturePath = Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1'
$legacyPath = Join-Path $root 'main.parameters.json'
$legacyHash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash
Import-Module $modulePath -ErrorAction Stop

$script:tests = 0
$script:failures = 0
function Assert-True {
    param([bool]$Condition, [string]$Reason)
    if (-not $Condition) { throw $Reason }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected rejection, but the operation succeeded.'
    Assert-True ($caught.Exception.Message -like $Pattern) "Error did not match expected path/policy: $Pattern"
    return $caught
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    $script:tests++
    try {
        & $Action
        Write-Host "[PASS] $Name"
    }
    catch {
        $script:failures++
        Write-Host "[FAIL] $Name -- $($_.Exception.Message)"
    }
}
function New-Profile {
    param([string]$Environment = 'dev')
    return & $fixturePath -Environment $Environment
}
function Remove-GatewayWorkloadKey {
    <#
    .SYNOPSIS
    The gateway block as it is handed to the sealed Bicep gatewayConfiguration type.
    .DESCRIPTION
    workloadKey is a profile input but not gateway service configuration, so the
    composer lifts it into the separate apiManagementWorkloadKey parameter. Every
    other field must still be copied through verbatim.
    #>
    param([Collections.IDictionary]$Gateway)
    $copy = [ordered]@{}
    foreach ($key in $Gateway.Keys) {
        if ($key -ceq 'workloadKey') { continue }
        $copy[$key] = $Gateway[$key]
    }
    return $copy
}
function Assert-Rejected {
    param([scriptblock]$Change, [string]$Pattern = '*')
    $p = New-Profile
    & $Change $p
    Assert-Throws { Resolve-EnvironmentProfile -Profile $p -AllowSynthetic } $Pattern | Out-Null
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ailz-environment-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    Test-Case 'Only the six intended functions are exported' {
        $actual = @((Get-Module Environment).ExportedFunctions.Keys | Sort-Object)
        $expected = @('ConvertTo-CanonicalJson', 'Get-CanonicalHash', 'Invoke-CheckedNative', 'Read-EnvironmentProfile', 'Resolve-EnvironmentProfile', 'Write-JsonFile' | Sort-Object)
        Assert-True (($actual -join ',') -ceq ($expected -join ',')) 'Unexpected module exports.'
    }
    Test-Case 'Typed direct resolution produces standard ARM parameters and pinned external identity/image' {
        $p = New-Profile
        $before = ConvertTo-CanonicalJson $p
        $r = Resolve-EnvironmentProfile -Profile $p -AllowSynthetic
        Assert-True ($r -is [Collections.IDictionary]) 'Resolution must be a dictionary.'
        Assert-True ($r.schemaVersion -eq 1 -and $r.environment -ceq 'dev') 'Wrong resolution envelope.'
        Assert-True ($r.parameters.'$schema' -eq 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#') 'Wrong ARM parameter schema.'
        $v = $r.parameters.parameters
        Assert-True ($v.networkIsolation.value -is [bool] -and $v.networkIsolation.value) 'Boolean type was lost.'
        Assert-True ($v.modelDeploymentList.value -is [array]) 'Model list was stringified.'
        Assert-True ($v.modelDeploymentList.value[0].sku.capacity -is [long] -or $v.modelDeploymentList.value[0].sku.capacity -is [int]) 'Integer type was lost.'
        Assert-True ($v.deploymentTags.value -is [Collections.IDictionary]) 'Tag object was stringified.'
        Assert-True ($v.principalId.value -eq $p.identities.deploy.principalId) 'Deployment identity was not bound.'
        Assert-True ($v.principalType.value -ceq 'ServicePrincipal') 'Deployment identity type is wrong.'
        Assert-True ($v.Contains('vmAdminPassword') -and $v.vmAdminPassword.value -is [string] -and $v.vmAdminPassword.value -ceq '') 'The unused required VM password must be an empty ARM string, never a generated credential.'
        Assert-True ($v.deployApiManagement.value -and $v.enableDeveloperExperience.value) 'New opt-in parameters were not composed.'
        $app = $v.containerAppsList.value[0]
        Assert-True ($v.containerAppsList.value.Count -eq 1) 'Only the developer smoke app is in scope.'
        Assert-True ($app.image -ceq ('syntheticneverdeployacr.azurecr.io/synthetic/developer-smoke@sha256:' + ('a' * 64))) 'The exact selected image digest was not composed.'
        Assert-True (($app.roles -join ',') -ceq 'AppConfigurationDataReader,AcrPull') 'Runtime caller has unexpected roles.'
        Assert-True ($app.managedIdentity.resourceId -eq $p.identities.workload.resourceId) 'External workload identity was not preserved.'
        Assert-True ($app.registry.identity -eq $p.identities.workload.resourceId) 'Private image pull identity is wrong.'
        Assert-True ((ConvertTo-CanonicalJson $p) -ceq $before) 'Resolver mutated its input.'
        Assert-True ((ConvertTo-CanonicalJson $r.profile) -ceq $before) 'Validated original profile was not preserved.'
    }
    Test-Case 'Developer handoff has exactly the frozen parent-owned runtime input shape' {
        $p = New-Profile
        $expected = @{
            application = $p.application
            workloadIdentity = $p.identities.workload
            developerObjectIds = $p.identities.developerObjectIds
            developerGroupObjectIds = $p.identities.developerGroupObjectIds
            release = $p.release
        }
        $v = (Resolve-EnvironmentProfile $p -AllowSynthetic).parameters.parameters
        Assert-True ((ConvertTo-CanonicalJson $v.developerExperience.value) -ceq (ConvertTo-CanonicalJson $expected)) 'developerExperience must contain exactly the five frozen fields with their original typed values.'
        Assert-True (-not $v.containerAppsList.value[0].Contains('environmentVariables')) 'Runtime environment variables must remain derived in the parent Bicep.'
        Assert-True (-not $v.Contains('additionalAppConfigurationSettings')) 'The resolver must not hand-copy parent-owned App Configuration settings.'
    }
    Test-Case 'Gateway handoff preserves supplied fields without derived runtime context' {
        $p = New-Profile
        $v = (Resolve-EnvironmentProfile $p -AllowSynthetic).parameters.parameters
        # workloadKey is lifted into its own top-level parameter because the Bicep
        # gatewayConfiguration type is sealed. It is still handed off verbatim, so
        # the no-synthesis contract is unchanged.
        Assert-True ((ConvertTo-CanonicalJson $v.apiManagementConfiguration.value) -ceq (ConvertTo-CanonicalJson (Remove-GatewayWorkloadKey $p.gateway))) 'apiManagementConfiguration must copy the supplied gateway fields without environment, tenant or endpoint additions.'
        Assert-True ($v.apiManagementWorkloadKey.value -ceq $p.gateway.workloadKey) 'The landing-zone workload key must be handed off verbatim, not derived.'
    }
    Test-Case 'Both audience slots accept GUIDs and approved URI forms without normalization' {
        $path = Join-Path $scratch 'synthetic-audience-profile.json'
        foreach ($section in @('gateway', 'application')) {
            foreach ($audience in @(
                'abcdef01-2345-4678-89ab-cdef01234567',
                'ABCDEF01-2345-4678-89AB-CDEF01234567',
                'api://synthetic-approved-api',
                'https://synthetic-api.example.invalid/ExactAudience/'
            )) {
                $p = New-Profile
                $p[$section].audience = $audience
                Write-JsonFile $path $p
                $read = Read-EnvironmentProfile $path -AllowSynthetic
                $r = Resolve-EnvironmentProfile $read -AllowSynthetic
                $actual = if ($section -ceq 'gateway') {
                    $r.parameters.parameters.apiManagementConfiguration.value.audience
                }
                else {
                    $r.parameters.parameters.developerExperience.value.application.audience
                }
                Assert-True ($read[$section].audience -ceq $audience -and $actual -ceq $audience) 'Audience spelling, GUID case, URI scheme, path or trailing slash was normalized.'
                Assert-True ((ConvertTo-CanonicalJson $r.profile) -ceq (ConvertTo-CanonicalJson $p)) 'The validated original audience changed.'
            }
        }
    }
    Test-Case 'GUID, URI-prefixed GUID and GUID case changes remain distinct configuration inputs' {
        $p = New-Profile
        $p.gateway.audience = 'abcdef01-2345-4678-89ab-cdef01234567'
        $bareHash = (Resolve-EnvironmentProfile $p -AllowSynthetic).configurationHash
        $p.gateway.audience = 'api://abcdef01-2345-4678-89ab-cdef01234567'
        $uriHash = (Resolve-EnvironmentProfile $p -AllowSynthetic).configurationHash
        $p.gateway.audience = 'ABCDEF01-2345-4678-89AB-CDEF01234567'
        $caseHash = (Resolve-EnvironmentProfile $p -AllowSynthetic).configurationHash
        Assert-True ($bareHash -cne $uriHash -and $bareHash -cne $caseHash) 'Exact audience changes must invalidate the configuration hash, not become aliases.'
    }
    $invalidAudiences = [ordered]@{
        'zero GUID' = '00000000-0000-0000-0000-000000000000'
        'missing GUID separators' = 'abcdef012345467889abcdef01234567'
        'braced GUID' = '{abcdef01-2345-4678-89ab-cdef01234567}'
        'nonhex GUID' = 'zzzzzzzz-2345-4678-89ab-cdef01234567'
        'truncated GUID' = 'abcdef01-2345-4678-89ab-cdef0123456'
        'whitespace-padded GUID' = ' abcdef01-2345-4678-89ab-cdef01234567 '
        'newline-suffixed GUID' = "abcdef01-2345-4678-89ab-cdef01234567`n"
        'newline-suffixed URI' = "api://synthetic-approved-api`n"
        'insecure URI' = 'http://synthetic-api.example.invalid'
        'URL user credentials' = 'https://synthetic-user:synthetic-sensitive-audience-value@synthetic-api.example.invalid'
        'URL SAS credentials' = 'https://synthetic-api.example.invalid/?sig=synthetic-sensitive-audience-value'
        'URL client credentials' = 'https://synthetic-api.example.invalid/?client_secret=synthetic-sensitive-audience-value'
        'encoded URL credentials' = 'https://synthetic-user%3Asynthetic-sensitive-audience-value%40synthetic-api.example.invalid'
        'URL fragment' = 'https://synthetic-api.example.invalid/#synthetic-sensitive-audience-value'
        'numeric audience' = 42
    }
    foreach ($section in @('gateway', 'application')) {
        foreach ($case in $invalidAudiences.GetEnumerator()) {
            Test-Case "$section audience rejects $($case.Key)" {
                $p = New-Profile
                $p[$section].audience = $case.Value
                $caught = Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic }
                Assert-True ($caught.Exception.Message -notlike '*synthetic-sensitive-audience-value*') 'Rejected audience credentials leaked through validation diagnostics.'
            }
        }
    }
    Test-Case 'P5-observed provisioning state is absent from P1 defaults and can be bound into the parameter hash' {
        $r = Resolve-EnvironmentProfile (New-Profile) -AllowSynthetic
        $gateway = $r.parameters.parameters.apiManagementConfiguration.value
        Assert-True (-not $gateway.Contains('initialProvisioning')) 'P1 must not guess APIM existence or initial provisioning state.'
        $hashInput = @{
            schemaVersion = $r.schemaVersion
            environment = $r.environment
            profile = $r.profile
            parameters = $r.parameters
        }
        Assert-True ((Get-CanonicalHash $hashInput) -ceq $r.configurationHash) 'The documented resolved hash envelope is inconsistent.'
        $gateway.initialProvisioning = $true
        $initialHash = Get-CanonicalHash $hashInput
        $gateway.initialProvisioning = $false
        $existingHash = Get-CanonicalHash $hashInput
        Assert-True ($initialHash -cne $existingHash -and $initialHash -cne $r.configurationHash -and $existingHash -cne $r.configurationHash) 'Observed provisioning state must invalidate the previous parameter/preview hash.'
        Assert-True (-not $r.profile.gateway.Contains('initialProvisioning')) 'P5 runtime state must not mutate the original profile.'
    }
    Test-Case 'Frozen composed overrides accept identical values and reject schema or release conflicts' {
        $p = New-Profile
        $expected = @{
            application = $p.application
            workloadIdentity = $p.identities.workload
            developerObjectIds = $p.identities.developerObjectIds
            developerGroupObjectIds = $p.identities.developerGroupObjectIds
            release = $p.release
        }
        $p.parameters.developerExperience = ConvertTo-CanonicalJson $expected | ConvertFrom-Json -AsHashtable
        $p.parameters.apiManagementConfiguration = ConvertTo-CanonicalJson (Remove-GatewayWorkloadKey $p.gateway) | ConvertFrom-Json -AsHashtable
        Resolve-EnvironmentProfile $p -AllowSynthetic | Out-Null
        $schemaPath = Join-Path $root 'environments\schema.json'
        foreach ($extra in @('environment', 'tenantId', 'gatewayAudience', 'environmentVariables')) {
            $p.parameters.developerExperience[$extra] = 'synthetic-extra-field'
            $valid = Test-Json -Json (ConvertTo-CanonicalJson $p) -SchemaFile $schemaPath -ErrorAction SilentlyContinue
            Assert-True (-not $valid) 'The published schema must reject additional developerExperience fields.'
            Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic } | Out-Null
            $p.parameters.developerExperience.Remove($extra)
        }
        $p.parameters.developerExperience.release.runAttempt++
        Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic } '*developerExperience*' | Out-Null
    }
    Test-Case 'Existing private workspace resolves without deployVM or a credential prerequisite' {
        $p = New-Profile
        $p.parameters.Remove('deployVM')
        $p.parameters.existingJumpboxResourceId = $p.identities.workload.resourceId -replace '/providers/.*$', '/providers/Microsoft.Compute/virtualMachines/synthetic-existing-workspace'
        $before = ConvertTo-CanonicalJson $p
        $path = Join-Path $scratch 'existing-private-workspace.json'
        Write-JsonFile $path $p
        $read = Read-EnvironmentProfile -Path $path -AllowSynthetic
        $r = Resolve-EnvironmentProfile $read -AllowSynthetic
        $v = $r.parameters.parameters
        Assert-True ($v.vmAdminPassword.value -is [string] -and $v.vmAdminPassword.value -ceq '') 'No-VM onboarding must not require a password or secret reference.'
        Assert-True ($v.deployVM.value -is [bool] -and -not $v.deployVM.value -and -not $v.deployJumpbox.value) 'The resolved legacy and jumpbox flags must explicitly remain off.'
        Assert-True ((ConvertTo-CanonicalJson $r.profile) -ceq $before) 'The original profile must retain the omitted legacy VM flag.'
    }
    Test-Case 'Every emitted parameter exists in the parent Bicep contract' {
        $names = @(Select-String -LiteralPath (Join-Path $root 'main.bicep') -Pattern '^param\s+(\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $r = Resolve-EnvironmentProfile (New-Profile) -AllowSynthetic
        foreach ($name in $r.parameters.parameters.Keys) {
            Assert-True ($names -ccontains $name) 'Resolver emitted an unknown Bicep parameter.'
        }
    }
    Test-Case 'Enabled data services retain typed lists, flags and nullable throughput' {
        $p = New-Profile
        foreach ($flag in @('deployStorageAccount', 'deployCosmosDb', 'deploySearchService', 'deployKeyVault')) { $p.parameters[$flag] = $true }
        $dnsScope = $p.parameters.existingPrivateDnsZoneOpenAiResourceId -replace '/privateDnsZones/[^/]+$', '/privateDnsZones/'
        $p.parameters.existingPrivateDnsZoneBlobResourceId = $dnsScope + 'privatelink.blob.core.windows.net'
        $p.parameters.existingPrivateDnsZoneCosmosResourceId = $dnsScope + 'privatelink.documents.azure.com'
        $p.parameters.existingPrivateDnsZoneSearchResourceId = $dnsScope + 'privatelink.search.windows.net'
        $p.parameters.existingPrivateDnsZoneKeyVaultResourceId = $dnsScope + 'privatelink.vaultcore.azure.net'
        $p.parameters.dbDatabaseThroughput = $null
        $p.parameters.databaseContainersList = @(@{
            name = 'synthetic-items'; canonical_name = 'SYNTHETIC_ITEMS'; partitionKey = '/id'
            indexingPolicy = @{ automatic = $true; indexingMode = 'consistent'; excludedPaths = @(@{ path = '/ignored/*' }) }
        })
        $p.parameters.storageAccountContainersList = @(@{ name = 'synthetic-documents'; canonical_name = 'SYNTHETIC_DOCUMENTS' })
        $p.parameters.workloadProfiles = @(
            @{ name = 'synthetic-dedicated'; workloadProfileType = 'D4'; minimumCount = 0; maximumCount = 1 }
            @{ name = 'Consumption'; workloadProfileType = 'Consumption' }
        )
        $v = (Resolve-EnvironmentProfile $p -AllowSynthetic).parameters.parameters
        foreach ($name in @('databaseContainersList', 'storageAccountContainersList', 'workloadProfiles')) {
            Assert-True ((ConvertTo-CanonicalJson $v[$name].value) -ceq (ConvertTo-CanonicalJson $p.parameters[$name])) 'Typed service configuration changed during composition.'
        }
        Assert-True ($v.dbDatabaseThroughput.Contains('value') -and $null -eq $v.dbDatabaseThroughput.value) 'Explicit nullable throughput was lost.'
        Assert-True ($v.containerAppsList.value[0].profile_name -ceq 'synthetic-dedicated') 'The explicitly ordered workload profile was not selected.'
    }
    Test-Case 'Supported infrastructure-only, private runner and legacy OIDC variants resolve without fallback' {
        $p = New-Profile
        $p.gateway.enabled = $false
        $p.gateway.callerMappings = @()
        $p.gateway.Remove('foundryIntegration')
        $p.parameters.deployContainerApps = $false
        $p.github.runner.mode = 'existing-private'
        $p.github.runner.networkConfigurationId = $null
        $p.github.runner.labels = @('self-hosted', 'linux', 'synthetic-private')
        $p.github.oidc.subjectFormat = 'legacy'
        $p.github.oidc.previewSubject = "repo:$($p.github.repository):environment:dev-preview"
        $p.github.oidc.deploySubject = "repo:$($p.github.repository):environment:dev"
        $v = (Resolve-EnvironmentProfile $p -AllowSynthetic).parameters.parameters
        Assert-True (-not $v.deployApiManagement.value -and -not $v.enableDeveloperExperience.value) 'Disabled profile enabled a deployment path.'
        Assert-True ($v.containerAppsList.value.Count -eq 0) 'Disabled profile supplied an inference workload.'
        Assert-True (-not $v.apiManagementConfiguration.value.Contains('foundryIntegration')) 'An omitted disabled Foundry integration flag must not change the supplied gateway shape.'
        Assert-True ($v.apiManagementConfiguration.value.name -ceq $p.gateway.name) 'The explicit gateway lookup name must be preserved even when disabled.'
        Assert-True ((ConvertTo-CanonicalJson $v.apiManagementConfiguration.value) -ceq (ConvertTo-CanonicalJson (Remove-GatewayWorkloadKey $p.gateway))) 'Optional gateway fields were synthesized.'
    }
    Test-Case 'Standalone private topology explicitly selects local egress and a distinct spoke runner allocation' {
        $p = New-Profile
        $p.parameters.deploymentMode = 'standalone'
        $p.parameters.deployAzureFirewall = $true
        foreach ($name in @($p.parameters.Keys | Where-Object { $_ -like 'hubIntegration*' })) { $p.parameters.Remove($name) }
        $p.network.hubAddressPrefixes = @()
        $p.network.runnerSubnetPrefix = '10.220.5.0/27'
        $p.github.runner.subnetResourceId = "/subscriptions/$($p.azure.subscriptionId)/resourceGroups/$($p.azure.resourceGroup)/providers/Microsoft.Network/virtualNetworks/$($p.parameters.vnetName)/subnets/synthetic-private-runner"
        Resolve-EnvironmentProfile $p -AllowSynthetic | Out-Null
    }
    Test-Case 'File, direct and CLI inputs resolve identically without environment substitution' {
        $path = Join-Path $scratch 'synthetic.json'
        $p = New-Profile
        Write-JsonFile $path $p
        $oldLocation = $env:AZURE_LOCATION
        $oldCi = $env:CI
        try {
            $env:AZURE_LOCATION = 'ignored-synthetic-environment-variable'
            $env:CI = 'true'
            $read = Read-EnvironmentProfile -Path $path -AllowSynthetic
            Assert-True ($read -is [Collections.IDictionary]) 'Read must return IDictionary.'
            $direct = Resolve-EnvironmentProfile $p -AllowSynthetic
            $fromFile = Resolve-EnvironmentProfile $read -AllowSynthetic
            Assert-True ((ConvertTo-CanonicalJson $direct) -ceq (ConvertTo-CanonicalJson $fromFile)) 'Local and CI resolutions diverge.'
            $output = Join-Path $scratch 'resolved'
            $cliOutput = @(& $resolverPath -ProfilePath $path -OutputDirectory $output -AllowSynthetic)
            Assert-True ($cliOutput.Count -eq 0) 'CLI must write files without logging resolved profile values.'
            $cliResolved = Get-Content -LiteralPath (Join-Path $output 'resolved.json') -Raw | ConvertFrom-Json -AsHashtable
            $cliParameters = Get-Content -LiteralPath (Join-Path $output 'main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-True ((ConvertTo-CanonicalJson $cliResolved) -ceq (ConvertTo-CanonicalJson $direct)) 'CLI resolution diverges.'
            Assert-True ((ConvertTo-CanonicalJson $cliParameters) -ceq (ConvertTo-CanonicalJson $direct.parameters)) 'CLI ARM parameter file diverges.'
        }
        finally {
            $env:AZURE_LOCATION = $oldLocation
            $env:CI = $oldCi
        }
    }
    Test-Case 'Nested CLI resolution preserves caller-visible shared module exports' {
        $path = Join-Path $scratch 'nested-consumer-profile.json'
        Write-JsonFile $path (New-Profile)
        $consumerPath = Join-Path $scratch 'SyntheticNestedEnvironmentConsumer.psm1'
        $consumerCode = @'
function Invoke-SyntheticNestedResolution {
    param([string]$ResolverPath, [string]$ProfilePath, [string]$OutputDirectory)
    & $ResolverPath -ProfilePath $ProfilePath -OutputDirectory $OutputDirectory -AllowSynthetic
}
Export-ModuleMember -Function Invoke-SyntheticNestedResolution
'@
        [IO.File]::WriteAllText($consumerPath, $consumerCode)
        $consumer = Import-Module $consumerPath -PassThru -ErrorAction Stop
        try {
            Invoke-SyntheticNestedResolution -ResolverPath $resolverPath -ProfilePath $path -OutputDirectory (Join-Path $scratch 'nested-resolved')
            foreach ($name in @('Read-EnvironmentProfile', 'Resolve-EnvironmentProfile', 'ConvertTo-CanonicalJson', 'Get-CanonicalHash', 'Invoke-CheckedNative', 'Write-JsonFile')) {
                Assert-True ($null -ne (Get-Command -Name $name -ErrorAction SilentlyContinue)) 'Nested import removed a caller-visible Environment export.'
            }
            Assert-True ((Get-CanonicalHash @{ probe = 'synthetic-caller-context' }) -cmatch '^[0-9a-f]{64}$') 'The caller can no longer use canonical helpers after nested resolution.'
        }
        finally {
            Remove-Module -ModuleInfo $consumer -ErrorAction Stop
            Import-Module $modulePath -Global -ErrorAction Stop
        }
    }
    Test-Case 'Canonical JSON sorts recursively using ordinal keys but preserves array order and scalar types' {
        $a = [ordered]@{ z = @([ordered]@{ b = 2; a = $false }, 1); A = 'true'; b = $true }
        $b = [ordered]@{ b = $true; A = 'true'; z = @([ordered]@{ a = $false; b = 2 }, 1) }
        Assert-True ((ConvertTo-CanonicalJson $a) -ceq (ConvertTo-CanonicalJson $b)) 'Object insertion order affected canonical JSON.'
        Assert-True ((Get-CanonicalHash @{ values = @(1, 2) }) -cne (Get-CanonicalHash @{ values = @(2, 1) })) 'Array order must remain meaningful.'
        Assert-True ((Get-CanonicalHash $true) -cne (Get-CanonicalHash 'true')) 'String and boolean hashes must differ.'
        Assert-True ((Get-CanonicalHash 1) -cne (Get-CanonicalHash '1')) 'String and integer hashes must differ.'
        Assert-True ((ConvertTo-CanonicalJson @{ empty = @(); nil = $null }) -ceq '{"empty":[],"nil":null}') 'Empty arrays/nulls were lost.'
    }
    Test-Case 'Canonical hashing is culture-independent and preserves JSON escaping' {
        $prior = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = 'fr-FR'
            $a = Get-CanonicalHash @{ number = [decimal]1.25; text = "quoted`"line`n" }
            [Globalization.CultureInfo]::CurrentCulture = 'tr-TR'
            $b = Get-CanonicalHash @{ text = "quoted`"line`n"; number = [decimal]1.25 }
            Assert-True ($a -ceq $b) 'Culture affected canonical hashing.'
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $prior }
    }
    Test-Case 'Configuration, release provenance and image mutations invalidate the configuration hash' {
        $original = (Resolve-EnvironmentProfile (New-Profile) -AllowSynthetic).configurationHash
        foreach ($change in @(
            { param($p) $p.gateway.stopNewRequests = $true },
            { param($p) $p.parameters.deploymentTags.owner = 'synthetic-other-owner' },
            { param($p) $p.release.runAttempt = 2 },
            { param($p) $p.release.sourceSha = '3333333333333333333333333333333333333333' },
            { param($p) $p.release.imageDigest = 'sha256:' + ('b' * 64) }
        )) {
            $p = New-Profile
            & $change $p
            $hash = (Resolve-EnvironmentProfile $p -AllowSynthetic).configurationHash
            Assert-True ($hash -cmatch '^[0-9a-f]{64}$' -and $hash -cne $original) 'A changed input retained the approved hash.'
        }
    }
    Test-Case 'Equivalent explicit composed overrides are accepted, conflicting overrides are rejected' {
        $p = New-Profile
        $p.parameters.location = $p.azure.location
        $p.parameters.environmentName = $p.environment
        $p.parameters.principalId = $p.identities.deploy.principalId
        $p.parameters.principalType = 'ServicePrincipal'
        Resolve-EnvironmentProfile $p -AllowSynthetic | Out-Null
        foreach ($name in @('location', 'environmentName', 'principalId', 'principalType', 'containerAppsList', 'apiManagementConfiguration', 'developerExperience')) {
            $q = New-Profile
            $q.parameters[$name] = switch ($name) {
                'location' { 'westus2' }
                'environmentName' { 'test' }
                'principalId' { $q.identities.preview.principalId }
                'principalType' { 'User' }
                'containerAppsList' { ,@() }
                default { @{} }
            }
            Assert-Throws { Resolve-EnvironmentProfile $q -AllowSynthetic } | Out-Null
        }
    }
    Test-Case 'Missing required root fields fail closed' {
        foreach ($name in @('schemaVersion', 'environment', 'synthetic', 'azure', 'github', 'identities', 'parameters', 'gateway', 'application', 'release', 'governance', 'network')) {
            $p = New-Profile
            $p.Remove($name)
            Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic } | Out-Null
        }
    }
    $invalid = [ordered]@{
        'Unknown environment' = { param($p) $p.environment = 'staging' }
        'Wrong schema version type' = { param($p) $p.schemaVersion = '1' }
        'Unknown Bicep parameter' = { param($p) $p.parameters.imaginaryParameter = $true }
        'Unknown nested property' = { param($p) $p.application.unrecognized = 'value' }
        'Stringified boolean' = { param($p) $p.parameters.networkIsolation = 'true' }
        'Stringified list' = { param($p) $p.parameters.vnetAddressPrefixes = '["10.220.0.0/16"]' }
        'Stringified integer' = { param($p) $p.gateway.capacity = '1' }
        'Fractional integer' = { param($p) $p.gateway.capacity = 1.5 }
        'Malformed tenant ID' = { param($p) $p.azure.tenantId = 'not-a-guid' }
        'Empty subscription ID' = { param($p) $p.azure.subscriptionId = '00000000-0000-0000-0000-000000000000' }
        'Malformed identity resource ID' = { param($p) $p.identities.workload.resourceId = '/wrong/resource/type' }
        'Wrong registry resource type' = { param($p) $p.application.registryResourceId = $p.identities.workload.resourceId }
        'Preview and deploy identity collision' = { param($p) $p.identities.preview = $p.identities.deploy }
        'Privileged workload identity' = { param($p) $p.identities.workload.principalId = $p.identities.deploy.principalId }
        'Duplicate developer identity' = { param($p) $p.identities.developerObjectIds += $p.identities.developerObjectIds[0] }
        'No explicit developer identity or group' = { param($p) $p.identities.developerObjectIds = @(); $p.identities.developerGroupObjectIds = @(); $p.gateway.callerMappings = @($p.gateway.callerMappings[0]) }
        'Developer identity is deployment principal' = { param($p) $p.identities.developerObjectIds[0] = $p.identities.deploy.principalId }
        'Duplicate reviewer' = { param($p) $p.github.environmentReviewers += $p.github.environmentReviewers[0] }
        'Wrong OIDC issuer' = { param($p) $p.github.oidc.issuer = 'https://example.invalid' }
        'OIDC wildcard trust' = { param($p) $p.github.oidc.deploySubject = 'repo:*:environment:dev' }
        'OIDC wrong repository ID' = { param($p) $p.github.repositoryId++ }
        'OIDC deploy subject reused for preview' = { param($p) $p.github.oidc.previewSubject = $p.github.oidc.deploySubject }
        'Unprotected release ref' = { param($p) $p.release.ref = 'refs/heads/untrusted' }
        'Release from another repository' = { param($p) $p.release.repository = 'synthetic-other/repo' }
        'Mutable release SHA' = { param($p) $p.release.sourceSha = 'main' }
        'Mutable image tag' = { param($p) $p.release.imageDigest = 'latest' }
        'Image repository contains a tag' = { param($p) $p.application.imageRepository = 'sample:latest' }
        'Missing release attempt' = { param($p) $p.release.Remove('runAttempt') }
        'Invalid run ID' = { param($p) $p.release.runId = 0 }
        'Workflow path traversal' = { param($p) $p.release.workflow = '.github/workflows/../../untrusted.yml' }
        'Workspace URL contains credentials' = { param($p) $p.application.workspaceRepository = 'https://user:password@github.com/synthetic/workspace' }
        'Workspace URL is not HTTPS GitHub' = { param($p) $p.application.workspaceRepository = 'http://example.invalid/repo' }
        'Workspace ref is not immutable' = { param($p) $p.application.workspaceRef = 'main' }
        'Gateway missing rate' = { param($p) $p.gateway.callerMappings[0].Remove('tokensPerMinute') }
        'Gateway missing explicit lookup name' = { param($p) $p.gateway.Remove('name') }
        'Gateway lookup name is null' = { param($p) $p.gateway.name = $null }
        'Gateway lookup name is blank' = { param($p) $p.gateway.name = ' ' }
        'Gateway zero rate' = { param($p) $p.gateway.callerMappings[0].tokensPerMinute = 0 }
        'Gateway missing quota' = { param($p) $p.gateway.callerMappings[0].Remove('tokenQuota') }
        'Gateway zero quota' = { param($p) $p.gateway.callerMappings[0].tokenQuota = 0 }
        'Gateway negative capacity' = { param($p) $p.gateway.capacity = -1 }
        'Gateway missing mapping' = { param($p) $p.gateway.callerMappings = @() }
        'Duplicate caller mapping' = { param($p) $p.gateway.callerMappings += $p.gateway.callerMappings[0] }
        'Conflicting mapping project' = { param($p) $p.gateway.callerMappings[0].project = 'different-project' }
        'Unknown caller identity' = { param($p) $p.gateway.callerMappings[0].objectId = '00000000-0000-4000-8000-000000000099' }
        'Unknown mapped deployment' = { param($p) $p.gateway.callerMappings[0].models = @('not-approved') }
        'Duplicate mapped deployment' = { param($p) $p.gateway.callerMappings[0].models += 'synthetic-chat' }
        'Unknown application deployment' = { param($p) $p.application.modelDeployment = 'not-approved' }
        'Native Foundry integration unsupported' = { param($p) $p.gateway.foundryIntegration = $true }
        'Wildcard publisher approval' = { param($p) $p.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/*') }
        'Publisher-only approval' = { param($p) $p.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/') }
        'Unsafe model-name prefix approval' = { param($p) $p.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/gpt-5') }
        'Different exact approved model' = { param($p) $p.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/gpt-5/') }
        'Different exact approved version' = { param($p) $p.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/gpt-5-nano/versions/other') }
        'Unapproved deployment SKU' = { param($p) $p.governance.allowedDeploymentSkus = @('Standard') }
        'Unsupported inference route model' = { param($p) $p.parameters.modelDeploymentList[0].model.name = 'text-embedding-3-large' }
        'Duplicate model deployment' = { param($p) $p.parameters.modelDeploymentList += $p.parameters.modelDeploymentList[0] }
        'Agent enabled' = { param($p) $p.parameters.deployAAfAgentSvc = $true }
        'Public resource allowlist enabled' = { param($p) $p.parameters.allowedIpRanges = @('192.0.2.0/24') }
        'Key-based Foundry authentication enabled' = { param($p) $p.parameters.aiFoundryDisableLocalAuth = $false }
        'Shared app API key enabled' = { param($p) $p.parameters.useCAppAPIKey = $true }
        'Runtime configuration bypass' = { param($p) $p.parameters.appRuntimeConfigurationMode = 'none' }
        'VM enabled without a supported secret reference path' = { param($p) $p.parameters.deployVM = $true }
        'Null VM flag is not an explicit no-VM input' = { param($p) $p.parameters.deployVM = $null }
        'Jumpbox enabled' = { param($p) $p.parameters.deployJumpbox = $true }
        'Missing explicit jumpbox flag' = { param($p) $p.parameters.Remove('deployJumpbox') }
        'VM software path enabled' = { param($p) $p.parameters.deploySoftware = $true }
        'VM vault path enabled' = { param($p) $p.parameters.deployVmKeyVault = $true }
        'Plaintext password input' = { param($p) $p.parameters.vmAdminPassword = 'synthetic-password-must-not-leak' }
        'Secret nested in tags' = { param($p) $p.parameters.deploymentTags.clientSecret = 'synthetic-secret-must-not-leak' }
        'Generic token secret field in tags' = { param($p) $p.parameters.deploymentTags.token = 'synthetic-opaque-token-must-not-leak' }
        'Authorization header value in a nonsecret field' = { param($p) $p.parameters.deploymentTags.owner = 'Bearer synthetic-opaque-token-must-not-leak' }
        'SAS credential in a nonsecret field' = { param($p) $p.parameters.deploymentTags.owner = 'https://example.invalid/blob?sv=synthetic&sig=synthetic-signature-must-not-leak' }
        'Unresolved substitution' = { param($p) $p.parameters.deploymentTags.owner = '${UNRESOLVED_OWNER}' }
        'Unresolved example placeholder' = { param($p) $p.parameters.deploymentTags.owner = '<OWNER_REQUIRED>' }
        'ARM expression injection' = { param($p) $p.parameters.deploymentTags.owner = '[parameters(''secret'')]' }
        'Gateway overlaps delegated app subnet' = { param($p) $p.gateway.integrationSubnetPrefix = $p.parameters.acaEnvironmentSubnetPrefix }
        'Gateway reuses agent subnet name' = { param($p) $p.gateway.integrationSubnetName = $p.parameters.agentSubnetName }
        'Runner overlaps agent subnet' = { param($p) $p.network.runnerSubnetPrefix = $p.parameters.agentSubnetPrefix }
        'Gateway outside spoke' = { param($p) $p.gateway.integrationSubnetPrefix = '10.223.0.0/27' }
        'Hub overlaps spoke' = { param($p) $p.network.hubAddressPrefixes = @('10.220.0.0/16') }
        'Unaligned subnet CIDR' = { param($p) $p.gateway.integrationSubnetPrefix = '10.220.4.1/27' }
        'Invalid IPv4 address' = { param($p) $p.parameters.peSubnetPrefix = '999.0.0.0/24' }
        'Reserved network overlaps workload subnet' = { param($p) $p.network.reservedAddressPrefixes = @($p.parameters.peSubnetPrefix) }
        'Both hub routing mechanisms supplied' = { param($p) $p.parameters.hubIntegrationExistingRouteTableResourceId = $p.parameters.hubIntegrationHubVnetResourceId -replace 'virtualNetworks/synthetic-hub$', 'routeTables/synthetic-route-table' }
        'Integrated profile missing hub' = { param($p) $p.parameters.Remove('hubIntegrationHubVnetResourceId') }
        'Integrated profile missing a required service DNS zone' = { param($p) $p.parameters.Remove('existingPrivateDnsZoneAppConfigResourceId') }
        'Wrong private DNS namespace' = { param($p) $p.parameters.existingPrivateDnsZoneAppConfigResourceId = $p.parameters.existingPrivateDnsZoneOpenAiResourceId }
        'Runner resource ID disagrees with address allocation' = { param($p) $p.github.runner.subnetResourceId = $p.github.runner.subnetResourceId -replace 'virtualNetworks/synthetic-hub/', 'virtualNetworks/synthetic-other/' }
        'Missing explicit feature flag' = { param($p) $p.parameters.Remove('deployGroundingWithBing') }
        'Dedicated profile missing explicit capacity' = { param($p) $p.parameters.workloadProfiles = @(@{ name = 'synthetic-dedicated'; workloadProfileType = 'D4' }) }
        'Container app without environment' = { param($p) $p.parameters.deployContainerEnv = $false }
        'Container app without App Configuration' = { param($p) $p.parameters.deployAppConfig = $false }
        'Database containers while database disabled' = { param($p) $p.parameters.databaseContainersList = @(@{ name = 'synthetic'; canonical_name = 'SYNTHETIC'; partitionKey = '/id' }) }
        'Deny policy without assessment' = { param($p) $p.governance.policyEffect = 'Deny' }
        'Missing budget amount' = { param($p) $p.governance.budget.Remove('amount') }
        'Zero budget amount' = { param($p) $p.governance.budget.amount = 0 }
        'Budget has no notification owner' = { param($p) $p.governance.budget.contactEmails = @() }
        'Budget date reversed' = { param($p) $p.governance.budget.endDate = '2026-08-01' }
        'Budget invalid calendar date' = { param($p) $p.governance.budget.startDate = '2026-02-30' }
        'Allowance currency conflict' = { param($p) $p.governance.inferenceAllowance.currency = 'EUR' }
        'Allowance exceeds environment budget' = { param($p) $p.governance.inferenceAllowance.amount = 11 }
        'Quota exceeds allocated token allowance' = { param($p) $p.governance.inferenceAllowance.allocatedTokens = 1 }
        'Required ownership tag missing' = { param($p) $p.parameters.deploymentTags.Remove('owner') }
        'Unapproved resource region' = { param($p) $p.governance.allowedLocations = @('westus2') }
    }
    foreach ($case in $invalid.GetEnumerator()) {
        Test-Case $case.Key { Assert-Rejected $case.Value }
    }
    Test-Case 'Synthetic profiles are rejected by Read, Resolve and CLI unless explicitly offline' {
        $p = New-Profile
        $path = Join-Path $scratch 'synthetic-live-rejected.json'
        Write-JsonFile $path $p
        Assert-Throws { Read-EnvironmentProfile $path } '*synthetic*' | Out-Null
        Assert-Throws { Resolve-EnvironmentProfile $p } '*synthetic*' | Out-Null
        $output = Join-Path $scratch 'must-not-exist'
        Assert-Throws { & $resolverPath -ProfilePath $path -OutputDirectory $output } '*synthetic*' | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $output)) 'Rejected resolution wrote deployment artifacts.'
    }
    Test-Case 'Synthetic fixture identifiers cannot be made deployable by flipping the marker' {
        $p = New-Profile
        $p.synthetic = $false
        Assert-Throws { Resolve-EnvironmentProfile $p } '*synthetic*' | Out-Null
    }
    Test-Case 'Production requires every explicit readiness policy and independent reviewers' {
        $p = New-Profile prod
        Resolve-EnvironmentProfile $p -AllowSynthetic | Out-Null
        foreach ($field in @('identityIsolation', 'dataIsolation', 'residency', 'capacity', 'backupRecovery', 'retention', 'availability', 'approverOwnership')) {
            $q = New-Profile prod
            $q.production[$field] = ' '
            Assert-Throws { Resolve-EnvironmentProfile $q -AllowSynthetic } | Out-Null
        }
        $p.production.approved = $false
        Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic } '*production*' | Out-Null
        $p = New-Profile prod
        $p.github.environmentReviewers = @()
        Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic } | Out-Null
    }
    Test-Case 'Private protected test promotion requires a compatible offering' {
        $p = New-Profile test
        $p.github.offering = 'team'
        Assert-Throws { Resolve-EnvironmentProfile $p -AllowSynthetic } | Out-Null
    }
    Test-Case 'Exact version model approval is supported without prefix matching' {
        $p = New-Profile
        $p.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/gpt-5-nano/versions/2025-08-07')
        Resolve-EnvironmentProfile $p -AllowSynthetic | Out-Null
    }
    Test-Case 'Malformed JSON and duplicate or case-colliding keys fail without echoing values' {
        $path = Join-Path $scratch 'malformed.json'
        foreach ($json in @('{"schemaVersion":1,', '{"schemaVersion":1,"schemaVersion":1}', '{"schemaVersion":1,"SchemaVersion":1}')) {
            [IO.File]::WriteAllText($path, $json)
            Assert-Throws { Read-EnvironmentProfile $path -AllowSynthetic } | Out-Null
        }
        $p = New-Profile
        $p.parameters.vmAdminPassword = 'synthetic-password-must-not-leak'
        Write-JsonFile $path $p
        $caught = Assert-Throws { Read-EnvironmentProfile $path -AllowSynthetic }
        Assert-True ($caught.Exception.Message -notlike '*synthetic-password-must-not-leak*') 'Validation disclosed a rejected secret.'
    }
    Test-Case 'Read applies semantic validation rather than accepting schema-valid conflicts' {
        $p = New-Profile
        $p.parameters.location = 'westus2'
        $path = Join-Path $scratch 'schema-valid-conflict.json'
        Write-JsonFile $path $p
        Assert-True (Test-Json -Path $path -SchemaFile (Join-Path $root 'environments\schema.json')) 'Test input should pass shape validation.'
        Assert-Throws { Read-EnvironmentProfile $path -AllowSynthetic } | Out-Null
    }
    Test-Case 'Unresolved example templates are JSON but never deployable, even offline' {
        foreach ($environment in @('dev', 'test', 'prod')) {
            $path = Join-Path $root "environments\$environment.example.json"
            $raw = Get-Content -LiteralPath $path -Raw
            Assert-True (Test-Json -Json $raw -ErrorAction Stop) 'Example is malformed JSON.'
            Assert-Throws { Read-EnvironmentProfile $path -AllowSynthetic } | Out-Null
        }
    }
    Test-Case 'CLI cannot overwrite legacy parameters or write into azd state' {
        $path = Join-Path $scratch 'safe-output-test.json'
        Write-JsonFile $path (New-Profile)
        Assert-Throws { & $resolverPath -ProfilePath $path -OutputDirectory $root -AllowSynthetic } | Out-Null
        Assert-Throws { & $resolverPath -ProfilePath $path -OutputDirectory (Join-Path $scratch '.azure') -AllowSynthetic } | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $scratch '.azure'))) 'CLI wrote azd state.'
    }
    Test-Case 'CLI rejects directory links rather than bypassing its output boundary' {
        $path = Join-Path $scratch 'linked-output-test.json'
        Write-JsonFile $path (New-Profile)
        $target = Join-Path $scratch 'link-target'
        $alias = Join-Path $scratch 'output-alias'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path $alias -Target $target -ErrorAction Stop | Out-Null
        Assert-Throws { & $resolverPath -ProfilePath $path -OutputDirectory $alias -AllowSynthetic } | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'main.parameters.json'))) 'Linked output directory bypassed the safety boundary.'
    }
    Test-Case 'JSON writer is deterministic, UTF-8 and round-trips nested typed values' {
        $path = Join-Path $scratch 'writer.json'
        $value = @{ nested = @{ bool = $false; list = @(); count = 3 }; string = "a`nb`"c" }
        Write-JsonFile $path $value
        $first = [IO.File]::ReadAllBytes($path)
        Write-JsonFile $path $value
        $second = [IO.File]::ReadAllBytes($path)
        Assert-True ([Convert]::ToBase64String($first) -ceq [Convert]::ToBase64String($second)) 'Repeated writes changed bytes.'
        Assert-True (-not ($first[0] -eq 239 -and $first[1] -eq 187 -and $first[2] -eq 191)) 'Output unexpectedly contains a BOM.'
        $read = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ((ConvertTo-CanonicalJson $read) -ceq (ConvertTo-CanonicalJson $value)) 'Writer changed typed data.'
    }
    Test-Case 'Checked native wrapper returns stdout, preserves arguments and fails without disclosing output' {
        $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
        $output = Invoke-CheckedNative -Command $pwsh -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("synthetic stdout")')
        Assert-True ($output -ceq 'synthetic stdout') 'Native stdout was not captured.'
        $echoPath = Join-Path $scratch 'echo-native-arguments.ps1'
        [IO.File]::WriteAllText($echoPath, '[Console]::Out.Write((ConvertTo-Json -InputObject $args -Compress))')
        $arguments = @('synthetic with spaces', 'synthetic"quoted', "synthetic'quoted", ';exit 7', 'synthetic\')
        $output = Invoke-CheckedNative $pwsh (@('-NoProfile', '-NonInteractive', '-File', $echoPath) + $arguments)
        Assert-True ((ConvertTo-CanonicalJson (ConvertFrom-Json -InputObject $output -NoEnumerate)) -ceq (ConvertTo-CanonicalJson $arguments)) 'Native arguments were split, evaluated or re-quoted.'
        $caught = Assert-Throws {
            Invoke-CheckedNative $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("synthetic-sensitive-output"); [Console]::Error.Write("synthetic-sensitive-error"); exit 7')
        } '*7*'
        Assert-True ($caught.Exception.Message -notmatch 'synthetic-sensitive|Console|Command') 'Native failure disclosed command content or output.'
        Assert-Throws { Invoke-CheckedNative 'synthetic-nonexistent-executable' @('synthetic-sensitive-argument') } | Out-Null
    }
    Test-Case 'Legacy main.parameters.json is byte-for-byte unchanged' {
        Assert-True ((Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash -ceq $legacyHash) 'Legacy parameters changed.'
    }
}
finally {
    # This exact, uniquely created test directory is the only cleanup target.
    $link = Join-Path $scratch 'output-alias'
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -ErrorAction Stop }
    [IO.Directory]::Delete($scratch, $true)
}
Write-Host "Environment tests: $($script:tests - $script:failures)/$script:tests passed."
if ($script:failures -gt 0) { throw "$script:failures environment test(s) failed." }
