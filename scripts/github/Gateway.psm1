#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -Scope Local

function Get-GatewayOwnerName {
    <#
    .SYNOPSIS
    The single PowerShell-side definition of the workload-scoped owner marker.
    .DESCRIPTION
    Must stay identical to `var owner` in modules/api-management/main.bicep.
    Keying by environment alone collides as soon as a second landing zone shares
    the gateway in the same subscription and environment.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$EnvironmentName,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$WorkloadKey
    )
    return "ailz-inference-$EnvironmentName-$WorkloadKey"
}

function Get-GatewayApiPath {
    <#
    .SYNOPSIS
    The workload-scoped APIM API path. Must match `var apiPath` in the module.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$WorkloadKey)
    return "inference/$WorkloadKey"
}

function Assert-GatewayConfiguration {
    <#
    .SYNOPSIS
    Validate P1 plus the concrete APIM name, backend route and encoded payload.
    .DESCRIPTION
    Call before both preview and deployment. Backend account/endpoint must be
    verified deployment inputs, not caller routing metadata. This starter targets
    the public Azure cloud and an account-named OpenAI/Foundry root endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$BackendAccountResourceId,
        [Parameter(Mandatory)][string]$BackendEndpoint,
        [switch]$AllowSynthetic
    )
    $resolved = Resolve-EnvironmentProfile -Profile $Profile -AllowSynthetic:$AllowSynthetic
    $profileValue = $resolved.profile
    $configuration = $profileValue.gateway
    if (-not $configuration.enabled) { throw 'Gateway configuration must explicitly opt in before calling the gateway module.' }
    if ($ServiceName.Length -gt 50 -or $ServiceName -cnotmatch '^[a-zA-Z](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$') {
        throw 'Gateway service name must satisfy the APIM service-name contract.'
    }
    if ($configuration.Contains('name') -and $configuration.name -cne $ServiceName) { throw 'Gateway explicit name conflicts with the resolved module name.' }
    if ($BackendAccountResourceId -cnotmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_][A-Za-z0-9_.-]*/providers/Microsoft\.CognitiveServices/accounts/[A-Za-z0-9][A-Za-z0-9-]*$') {
        throw 'Gateway backend must identify the approved Foundry account resource.'
    }
    $backend = $null
    if ($BackendEndpoint -cne $BackendEndpoint.Trim() -or -not [uri]::TryCreate($BackendEndpoint, [UriKind]::Absolute, [ref]$backend) -or
        $backend.Scheme -cne 'https' -or $backend.UserInfo -or $backend.Query -or $backend.Fragment -or
        $backend.AbsolutePath -cne '/' -or $backend.Authority.Contains(':')) {
        throw 'Gateway backend endpoint must be a credential-free HTTPS account root, without path, port, query or fragment.'
    }
    $accountName = ($BackendAccountResourceId -split '/')[-1].ToLowerInvariant()
    if ($backend.DnsSafeHost -cnotin @("$accountName.openai.azure.com", "$accountName.services.ai.azure.com")) {
        throw 'Gateway backend endpoint does not match the approved account in the supported Azure cloud.'
    }
    $payload = ConvertTo-CanonicalJson @{
        environment = $profileValue.environment
        tenantId = $profileValue.azure.tenantId.ToLowerInvariant()
        backendHost = $backend.DnsSafeHost
        callerMappings = $configuration.callerMappings
    }
    $encodedLength = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).Length
    if ($encodedLength -gt 4096 -or $configuration.audience.Length -gt 4096) {
        throw 'Gateway encoded configuration exceeds the APIM named-value limit (4096 characters). Reduce explicit mappings or implement a separately reviewed configuration layout.'
    }
    if (-not $configuration.privateDnsZoneResourceId.EndsWith('/providers/Microsoft.Network/privateDnsZones/privatelink.azure-api.net', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Gateway requires the approved privatelink.azure-api.net private DNS zone.'
    }
}

function Assert-GatewayResourceId {
    param([string]$ResourceId)
    if ($ResourceId -cnotmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_][A-Za-z0-9_.-]*/providers/Microsoft\.ApiManagement/service/[a-zA-Z](?:[a-zA-Z0-9-]{0,48}[a-zA-Z0-9])?$') {
        throw 'Gateway service resource ID must identify one explicit workload resource.'
    }
}

function Invoke-GatewayRequest {
    param([scriptblock]$Request, [string]$Method, [string]$ResourceId, [string]$ApiVersion = '2024-05-01', [AllowNull()][object]$Body = $null, [Collections.IDictionary]$Headers = @{})
    $response = & $Request $Method "https://management.azure.com${ResourceId}?api-version=$ApiVersion" $Body $Headers
    if ($response -isnot [Collections.IDictionary] -or -not $response.Contains('StatusCode') -or -not $response.Contains('Body') -or
        -not $response.Contains('Headers') -or $response.Body -isnot [Collections.IDictionary] -or $response.Headers -isnot [Collections.IDictionary]) {
        throw 'Gateway ARM transport must return StatusCode, Body and Headers without printing credentials or response bodies.'
    }
    return $response
}

function Assert-GatewayOwnership {
    param([AllowNull()][object]$Tags, [string]$EnvironmentName, [string]$ResourceKind = 'service', [AllowNull()][string]$Owner = $null)
    if ($Tags -isnot [Collections.IDictionary] -or $Tags['ailz-managed-by'] -cne 'github-dev-environment' -or
        $Tags['ailz-environment'] -cne $EnvironmentName -or
        ($Tags.Contains('ailz-owner') -and $Owner -and $Tags['ailz-owner'] -cne $Owner)) {
        throw "Gateway $ResourceKind ownership conflict; the management/environment pair must match and any namespace marker must not contradict it."
    }
}

function Get-GatewayService {
    param([string]$ServiceResourceId, [string]$EnvironmentName, [scriptblock]$Request, [switch]$AllowAbsent, [AllowNull()][string]$Owner = $null)
    $response = Invoke-GatewayRequest $Request GET $ServiceResourceId
    if ($response.StatusCode -eq 404 -and $AllowAbsent -and $response.Body.Contains('error') -and
        $response.Body.error -is [Collections.IDictionary] -and $response.Body.error['code'] -in @('ResourceNotFound', 'ResourceGroupNotFound')) {
        return $null
    }
    if ($response.StatusCode -ne 200) { throw "Gateway service read failed (HTTP $($response.StatusCode))." }
    $service = $response.Body
    if ($service -isnot [Collections.IDictionary] -or -not $service.Contains('id') -or $service.id -ine $ServiceResourceId -or
        -not $service.Contains('tags')) {
        throw 'Gateway ownership conflict; an existing service must never be adopted implicitly.'
    }
    Assert-GatewayOwnership $service.tags $EnvironmentName 'service' $Owner
    return $service
}

function Get-GatewayOwnedChildren {
    param([string]$ServiceResourceId, [string]$Owner, [scriptblock]$Request, [Parameter(Mandatory)][string]$ApiPath)
    $facts = [Collections.Generic.List[object]]::new()
    foreach ($collection in @('apis', 'backends', 'namedValues', 'loggers')) {
        $response = Invoke-GatewayRequest $Request GET "$ServiceResourceId/$collection"
        if ($response.StatusCode -ne 200 -or -not $response.Body.Contains('value') -or $response.Body.value -isnot [Collections.IList]) {
            throw "Gateway owned $collection inventory failed (HTTP $($response.StatusCode))."
        }
        if ($response.Body.Contains('nextLink') -and $response.Body.nextLink) {
            throw 'Gateway inventory is paginated; a complete scoped inventory is required before deployment.'
        }
        foreach ($item in $response.Body.value) {
            $name = $item.name
            $ownedName = switch ($collection) {
                apis { $name -ceq $Owner }
                backends { $name -ceq "$Owner-foundry" }
                namedValues { $name -cin @("$Owner-configuration", "$Owner-tenant", "$Owner-audience", "$Owner-stop") }
                loggers { $name -ceq "$Owner-insights" }
            }
            if ($collection -eq 'apis' -and -not $ownedName) {
                throw 'Gateway has an unapproved API/revision. Preserve it and obtain a dedicated-scope decision; do not delete or overwrite it.'
            }
            if (-not $ownedName) { continue }
            $owned = if ($collection -eq 'namedValues') { @($item.properties['tags']) -ccontains $Owner } else { $item.properties['description'] -ceq "owner:$Owner" }
            if (-not $owned) { throw "Gateway $collection ownership conflict." }
            $entity = Invoke-GatewayRequest $Request GET "$ServiceResourceId/$collection/$name"
            if ($entity.StatusCode -ne 200) { throw "Gateway owned $collection entity read failed (HTTP $($entity.StatusCode))." }
            $etag = $entity.Headers['ETag']
            if (-not $etag -and $entity.Body.Contains('etag')) { $etag = $entity.Body.etag }
            if (-not $etag) { throw 'Gateway owned entity ETag is required to detect policy/named-value changes without retrieving secrets.' }
            if ($collection -eq 'apis') {
                if ($item.properties.path -cne $ApiPath -or $item.properties.subscriptionRequired -ne $false) {
                    throw 'Gateway owned API route/authentication conflict.'
                }
                $operations = Invoke-GatewayRequest $Request GET "$ServiceResourceId/apis/$Owner/operations"
                if ($operations.StatusCode -ne 200 -or -not $operations.Body.Contains('value') -or
                    $operations.Body.value -isnot [Collections.IList] -or ($operations.Body.Contains('nextLink') -and $operations.Body.nextLink)) {
                    throw 'Gateway operation inventory is incomplete.'
                }
                foreach ($operation in $operations.Body.value) {
                    if ($operation.name -cne 'responses' -or $operation.properties.method -cne 'POST' -or
                        $operation.properties.urlTemplate -cne '/v1/responses' -or $operation.properties.description -cne "owner:$Owner") {
                        throw 'Gateway unapproved operation or ownership conflict; no automatic resource deletion is permitted.'
                    }
                }
                $facts.Add(@{ kind = 'operations'; name = $Owner; configurationHash = Get-CanonicalHash $operations.Body })
                foreach ($child in @('policies/policy', 'schemas/responses', 'diagnostics/applicationinsights')) {
                    $childResponse = Invoke-GatewayRequest $Request GET "$ServiceResourceId/apis/$Owner/$child"
                    if ($childResponse.StatusCode -ne 200) { throw "Gateway owned API child inventory is incomplete (HTTP $($childResponse.StatusCode))." }
                    $facts.Add(@{ kind = 'api-child'; name = $child; configurationHash = Get-CanonicalHash @{ entity = $childResponse.Body; etag = $childResponse.Headers['ETag'] } })
                }
            }
            $facts.Add(@{ kind = $collection; name = $name; configurationHash = Get-CanonicalHash @{ entity = $entity.Body; etag = $etag } })
        }
    }
    return ,@($facts | Sort-Object kind, name)
}

function Get-GatewayDeploymentPlan {
    <#
    .SYNOPSIS
    Observe absent, interrupted-public, public-with-PE or private state; never writes.
    .DESCRIPTION
    Request is the parent's authorized ARM transport: (method, absolute URI,
    body, headers) -> IDictionary { StatusCode; Body; Headers }. It must not log
    tokens/response bodies. Freeze this whole result alongside resolved inputs.
    Only absence or an owned already-public service without an approved PE may
    use initial=true. P4 readiness still requires observedState=Private.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceResourceId,
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$EnvironmentName,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$WorkloadKey,
        [Parameter(Mandatory)][scriptblock]$Request
    )
    Assert-GatewayResourceId $ServiceResourceId
    $owner = Get-GatewayOwnerName -EnvironmentName $EnvironmentName -WorkloadKey $WorkloadKey
    $apiPath = Get-GatewayApiPath -WorkloadKey $WorkloadKey
    $service = Get-GatewayService $ServiceResourceId $EnvironmentName $Request -AllowAbsent -Owner $owner
    $scope = $ServiceResourceId -replace '/providers/.*$', ''
    $privateEndpointId = "$scope/providers/Microsoft.Network/privateEndpoints/$(($ServiceResourceId -split '/')[-1])-inbound"
    $privateEndpoint = $null
    $observedState = 'Absent'
    $initialProvisioning = $true
    $facts = @()
    if ($null -eq $service) {
        $peResponse = Invoke-GatewayRequest $Request GET $privateEndpointId
        if ($peResponse.StatusCode -ne 404 -or -not $peResponse.Body.Contains('error') -or
            $peResponse.Body.error -isnot [Collections.IDictionary] -or $peResponse.Body.error['code'] -notin @('ResourceNotFound', 'ResourceGroupNotFound')) {
            throw 'Gateway initial provisioning requires an absent owned-name private endpoint; inspect the existing endpoint or failed read before planning recovery.'
        }
    }
    else {
        $access = $service.properties.publicNetworkAccess
        if ($access -cnotin @('Enabled', 'Disabled')) { throw 'Gateway returned an unsupported public network access state.' }
        $approvedConnections = @()
        if ($service.properties.Contains('privateEndpointConnections')) {
            $approvedConnections = @($service.properties.privateEndpointConnections | Where-Object { $_.properties.privateLinkServiceConnectionState.status -ceq 'Approved' })
        }
        $initialProvisioning = $access -ceq 'Enabled' -and $approvedConnections.Count -eq 0
        if ($initialProvisioning) {
            if ($service.properties.provisioningState -cnotin @('Succeeded', 'Failed', 'Canceled')) { throw 'Gateway provisioning is still in progress; wait and re-observe before recovery.' }
            $observedState = 'PublicPendingPrivateEndpoint'
            $privateEndpoint = Assert-GatewayPrivateEndpoint $service $privateEndpointId $Request -AllowUnapproved -AllowAbsent -Owner $owner
        }
        else {
            if ($service.properties.provisioningState -cne 'Succeeded') { throw 'Gateway is not in a stable provisioning state.' }
            $observedState = if ($access -ceq 'Disabled') { 'Private' } else { 'PublicPendingDisable' }
            $privateEndpoint = Assert-GatewayPrivateEndpoint $service $privateEndpointId $Request -Owner $owner
        }
        $facts = Get-GatewayOwnedChildren $ServiceResourceId $owner $Request -ApiPath $apiPath
    }
    return [ordered]@{
        schemaVersion = 1
        serviceResourceId = $ServiceResourceId
        privateEndpointResourceId = $privateEndpointId
        environmentName = $EnvironmentName
        workloadKey = $WorkloadKey
        owner = $owner
        apiPath = $apiPath
        observedState = $observedState
        initialProvisioning = $initialProvisioning
        observedStateHash = Get-CanonicalHash @{ service = $service; privateEndpoint = $privateEndpoint; ownedChildren = $facts }
        ownedChildren = $facts
    }
}

function Assert-GatewayDeploymentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Plan, [Parameter(Mandatory)][scriptblock]$Request)
    if ($Plan.schemaVersion -ne 1 -or $Plan.owner -cne (Get-GatewayOwnerName -EnvironmentName $Plan.environmentName -WorkloadKey $Plan.workloadKey) -or
        $Plan.apiPath -cne (Get-GatewayApiPath -WorkloadKey $Plan.workloadKey) -or
        $Plan.observedState -cnotin @('Absent', 'PublicPendingPrivateEndpoint', 'PublicPendingDisable', 'Private') -or
        $Plan.initialProvisioning -ne ($Plan.observedState -cin @('Absent', 'PublicPendingPrivateEndpoint'))) { throw 'Invalid gateway state plan.' }
    $current = Get-GatewayDeploymentPlan -ServiceResourceId $Plan.serviceResourceId -EnvironmentName $Plan.environmentName -WorkloadKey $Plan.workloadKey -Request $Request
    if ($current.observedStateHash -cne $Plan.observedStateHash) { throw 'Gateway plan is stale; repeat preview and approval with observed state.' }
}

function Assert-GatewayPrivateEndpoint {
    param([Collections.IDictionary]$Service, [string]$PrivateEndpointResourceId, [scriptblock]$Request, [switch]$AllowUnapproved, [switch]$AllowAbsent, [AllowNull()][string]$Owner = $null)
    $response = Invoke-GatewayRequest $Request GET $PrivateEndpointResourceId '2024-05-01'
    if ($response.StatusCode -eq 404 -and $AllowAbsent -and $response.Body.Contains('error') -and
        $response.Body.error -is [Collections.IDictionary] -and $response.Body.error['code'] -in @('ResourceNotFound', 'ResourceGroupNotFound')) { return $null }
    if ($response.StatusCode -ne 200) { throw "Gateway private endpoint read failed (HTTP $($response.StatusCode))." }
    $pe = $response.Body
    if ($pe.id -ine $PrivateEndpointResourceId -or (-not $AllowUnapproved -and $pe.properties.provisioningState -cne 'Succeeded')) { throw 'Gateway private endpoint is not provisioned.' }
    if (-not $pe.Contains('tags')) { throw 'Gateway private endpoint ownership conflict.' }
    Assert-GatewayOwnership $pe.tags $Service.tags['ailz-environment'] 'private endpoint' $Owner
    $connections = if ($pe.properties.Contains('privateLinkServiceConnections')) { @($pe.properties.privateLinkServiceConnections) } else { @() }
    if ($pe.properties.Contains('manualPrivateLinkServiceConnections')) { $connections += @($pe.properties.manualPrivateLinkServiceConnections) }
    $targets = @($connections | Where-Object { $_.properties.privateLinkServiceId -ieq $Service.id -and @($_.properties.groupIds) -icontains 'Gateway' })
    if ($targets.Count -ne 1 -or $connections.Count -ne 1) { throw 'Gateway private endpoint target is conflicting or ambiguous.' }
    $approved = @($connections | Where-Object {
        $_.properties.privateLinkServiceId -ieq $Service.id -and
        @($_.properties.groupIds) -icontains 'Gateway' -and
        $_.properties.privateLinkServiceConnectionState.status -ceq 'Approved'
    })
    $serviceConnections = if ($Service.properties.Contains('privateEndpointConnections')) { @($Service.properties.privateEndpointConnections) } else { @() }
    $approvedService = @($serviceConnections | Where-Object {
        $_.properties.privateEndpoint.id -ieq $PrivateEndpointResourceId -and
        $_.properties.privateLinkServiceConnectionState.status -ceq 'Approved'
    })
    if (-not $AllowUnapproved -and ($approved.Count -ne 1 -or $approvedService.Count -ne 1)) { throw 'Gateway private endpoint must be Approved on both resource sides before disabling public access.' }
    return $pe
}

function Get-GatewayStopValue {
    param([string]$ServiceResourceId, [string]$Owner, [scriptblock]$Request)
    $id = "$ServiceResourceId/namedValues/$Owner-stop"
    $metadata = Invoke-GatewayRequest $Request GET $id
    if ($metadata.StatusCode -ne 200) { throw "Gateway stop-control metadata read failed (HTTP $($metadata.StatusCode))." }
    $properties = $metadata.Body.properties
    if ($metadata.Body.id -ine $id -or $properties.displayName -cne "$Owner-stop" -or
        -not $properties.Contains('secret') -or $properties.secret -ne $false -or @($properties['tags']) -cnotcontains $Owner -or
        ($properties.Contains('keyVault') -and $null -ne $properties.keyVault)) {
        throw 'Gateway stop control must be the owned nonsecret Boolean named value, never a key or secret reference.'
    }
    $metadataEtag = [string]$metadata.Headers['ETag']
    if ([string]::IsNullOrWhiteSpace($metadataEtag) -or $metadataEtag -ceq '*') { throw 'Gateway stop-control ETag is required.' }
    $value = Invoke-GatewayRequest $Request POST "$id/listValue"
    if ($value.StatusCode -ne 200) { throw "Gateway stop-control value read failed (HTTP $($value.StatusCode))." }
    if ($value.Body['value'] -cnotin @('true', 'false')) { throw 'Gateway stop control has an invalid Boolean value; response content is withheld.' }
    $valueEtag = [string]$value.Headers['ETag']
    if ([string]::IsNullOrWhiteSpace($valueEtag) -or $valueEtag -ceq '*') { throw 'Gateway stop-control value ETag is required.' }
    return @{ resourceId = $id; value = $value.Body.value; etag = $valueEtag; stable = $metadataEtag -ceq $valueEtag }
}

function Complete-GatewayPrivateAccess {
    <#
    .SYNOPSIS
    Plan or explicitly apply the public-disable completion of an owned gateway.
    .DESCRIPTION
    No resource creation/deletion, PE approval, public enable, or global-policy
    change is performed. Service PATCH has no documented If-Match contract:
    the parent must hold the environment mutation lease. Re-read ownership and
    PE state on every retry; return success only after a Succeeded/Disabled GET.
    Optional StopNewRequests explicitly restores and verifies the approved
    Boolean after private completion. It uses only the owned nonsecret stop
    entity: GET metadata, POST listValue, and If-Match-protected value-only PATCH.
    Without Apply this function remains GET-only, including with StopNewRequests.
    DNS/connectivity, backend permissions and inference are separate live gates.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$PrivateEndpointResourceId,
        [Parameter(Mandatory)][scriptblock]$Request,
        [switch]$Apply,
        [bool]$StopNewRequests,
        [ValidateRange(1, 120)][int]$MaxAttempts = 60,
        [ValidateRange(0, 30)][int]$RetryDelaySeconds = 10
    )
    Assert-GatewayResourceId $Plan.serviceResourceId
    if ($Plan.schemaVersion -ne 1 -or $Plan.environmentName -cnotin @('dev', 'test', 'prod') -or
        $Plan.owner -cne (Get-GatewayOwnerName -EnvironmentName $Plan.environmentName -WorkloadKey $Plan.workloadKey)) { throw 'Invalid gateway completion ownership plan.' }
    $scope = $Plan.serviceResourceId -replace '/providers/.*$', ''
    $expectedPe = "$scope/providers/Microsoft.Network/privateEndpoints/$(($Plan.serviceResourceId -split '/')[-1])-inbound"
    if ($PrivateEndpointResourceId -ine $expectedPe) { throw 'Gateway private endpoint is outside the owned resource scope/name.' }
    $restoreStop = $PSBoundParameters.ContainsKey('StopNewRequests')
    $desiredStop = if ($StopNewRequests) { 'true' } else { 'false' }
    $mayWrite = $Apply -and $PSCmdlet.ShouldProcess($Plan.serviceResourceId, 'Complete private access and, when explicitly supplied, restore the approved stop control')
    $patchAccepted = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $service = Get-GatewayService $Plan.serviceResourceId $Plan.environmentName $Request -Owner $Plan.owner
        $null = Assert-GatewayPrivateEndpoint $service $PrivateEndpointResourceId $Request -Owner $Plan.owner
        if ($service.properties.publicNetworkAccess -ceq 'Disabled' -and $service.properties.provisioningState -ceq 'Succeeded') {
            if (-not $restoreStop) {
                return @{ serviceResourceId = $Plan.serviceResourceId; privateEndpointResourceId = $PrivateEndpointResourceId; publicNetworkAccess = 'Disabled'; status = 'VerifiedControlPlane'; changed = $patchAccepted }
            }
            if (-not $mayWrite) {
                return @{ serviceResourceId = $Plan.serviceResourceId; privateEndpointResourceId = $PrivateEndpointResourceId; publicNetworkAccess = 'Disabled'; status = 'Planned'; action = 'ReconcileOwnedStopControl' }
            }
            $stop = Get-GatewayStopValue $Plan.serviceResourceId $Plan.owner $Request
            $latestService = Get-GatewayService $Plan.serviceResourceId $Plan.environmentName $Request -Owner $Plan.owner
            $stillPrivate = $latestService.properties.publicNetworkAccess -ceq 'Disabled' -and $latestService.properties.provisioningState -ceq 'Succeeded'
            if ($stop.stable -and $stillPrivate) {
                $null = Assert-GatewayPrivateEndpoint $latestService $PrivateEndpointResourceId $Request -Owner $Plan.owner
                if ($stop.value -ceq $desiredStop) {
                    return @{
                        serviceResourceId = $Plan.serviceResourceId; privateEndpointResourceId = $PrivateEndpointResourceId
                        publicNetworkAccess = 'Disabled'; status = 'VerifiedControlPlane'; changed = $patchAccepted
                        stopControlVerified = $true; stopNewRequests = $StopNewRequests
                    }
                }
                $response = Invoke-GatewayRequest $Request PATCH $stop.resourceId '2024-05-01' @{ properties = @{ value = $desiredStop } } @{ 'If-Match' = $stop.etag }
                if ($response.StatusCode -in @(200, 202)) { $patchAccepted = $true }
                elseif ($response.StatusCode -notin @(409, 412, 429, 503)) { throw "Gateway stop-control PATCH failed (HTTP $($response.StatusCode))." }
            }
        }
        elseif (-not $mayWrite) {
            return @{ serviceResourceId = $Plan.serviceResourceId; privateEndpointResourceId = $PrivateEndpointResourceId; publicNetworkAccess = $service.properties.publicNetworkAccess; status = 'Planned'; action = 'DisablePublicNetworkAccess' }
        }
        if ($service.properties.provisioningState -cin @('Failed', 'Canceled')) { throw 'Gateway provisioning failed; private completion cannot declare success.' }
        if ($service.properties.publicNetworkAccess -cnotin @('Enabled', 'Disabled')) { throw 'Gateway returned an unsupported public network access state.' }
        elseif ($service.properties.provisioningState -ceq 'Succeeded' -and $service.properties.publicNetworkAccess -ceq 'Enabled') {
            $response = Invoke-GatewayRequest $Request PATCH $Plan.serviceResourceId '2024-05-01' @{ properties = @{ publicNetworkAccess = 'Disabled' } }
            if ($response.StatusCode -in @(200, 202)) { $patchAccepted = $true }
            elseif ($response.StatusCode -notin @(409, 412, 429, 503)) { throw "Gateway public-disable PATCH failed (HTTP $($response.StatusCode))." }
        }
        if ($attempt -lt $MaxAttempts -and $RetryDelaySeconds) { Start-Sleep -Seconds $RetryDelaySeconds }
    }
    throw 'Gateway private completion exceeded its bounded retry budget; public-disable success was not verified.'
}

Export-ModuleMember -Function Assert-GatewayConfiguration, Get-GatewayDeploymentPlan, Assert-GatewayDeploymentPlan, Complete-GatewayPrivateAccess
