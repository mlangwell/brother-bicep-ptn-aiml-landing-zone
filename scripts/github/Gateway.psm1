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
    # ---------------------------------------------------------------------
    # Private DNS zone contract - classic VNet injection
    # ---------------------------------------------------------------------
    # Injected instances cannot hold a private endpoint, so privatelink.azure-api.net
    # does not apply. Internal mode registers NOTHING on public DNS, so the
    # operator must publish a service-scoped zone instead. Learn is also explicit
    # that a zone for the shared apex domain is unsupported and actively harmful:
    # "Do not create a Private DNS zone or forward lookup zone for azure-api.net."
    $zoneName = ($configuration.privateDnsZoneResourceId -split '/')[-1]
    if ($zoneName -ieq 'azure-api.net') {
        throw 'Gateway must never use a private DNS zone for the apex azure-api.net domain. It is a shared public Azure domain; an apex private zone becomes authoritative inside the VNet and breaks resolution for other Azure services.'
    }
    if ($zoneName -ieq 'privatelink.azure-api.net') {
        throw 'Gateway uses classic VNet injection, which cannot hold a private endpoint, so a privatelink.azure-api.net zone does not apply. Supply the service-scoped <service>.azure-api.net zone instead.'
    }
    if ($zoneName -cne "$($ServiceName.ToLowerInvariant()).azure-api.net") {
        throw "Gateway requires the service-scoped private DNS zone $($ServiceName.ToLowerInvariant()).azure-api.net, holding an apex (@) A record for the instance private VIP."
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

function Assert-GatewayInjection {
    <#
    .SYNOPSIS
    Assert the privacy invariants that actually apply to a classic injected gateway.
    .DESCRIPTION
    This replaces the private-endpoint assertions used by the previous v2 shape.
    On classic VNet injection a private endpoint CANNOT exist (Learn: "In the
    classic API Management tiers, private endpoints aren't supported in instances
    injected in an internal or external virtual network"), and public network
    access CANNOT be disabled (Learn: "You can disable public network access in
    API Management instances configured with a private endpoint, not with other
    networking configurations").

    So asserting publicNetworkAccess=Disabled here would be unsatisfiable. The
    properties that genuinely deliver inbound privacy on this topology are:
      - virtualNetworkType is Internal, so no endpoint is on public DNS, and
      - the instance is attached to the approved undelegated injection subnet.
    Both are checked, plus the negative: no private endpoint has appeared.
    #>
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Service,
        [AllowNull()][AllowEmptyString()][string]$InjectionSubnetResourceId = $null
    )
    $virtualNetworkType = if ($Service.properties.Contains('virtualNetworkType')) { $Service.properties['virtualNetworkType'] } else { $null }
    if ($virtualNetworkType -cne 'Internal') {
        throw "Gateway must be injected in Internal virtual network mode; observed '$virtualNetworkType'. External publishes the gateway to the internet and None means it is not injected at all, so neither keeps the data plane private."
    }
    $configuredSubnet = $null
    if ($Service.properties.Contains('virtualNetworkConfiguration') -and
        $Service.properties.virtualNetworkConfiguration -is [Collections.IDictionary]) {
        $configuredSubnet = $Service.properties.virtualNetworkConfiguration['subnetResourceId']
    }
    if ([string]::IsNullOrWhiteSpace($configuredSubnet)) {
        throw 'Gateway reports Internal mode without an injection subnet; the observed network configuration is incoherent and must not be treated as private.'
    }
    if (-not [string]::IsNullOrWhiteSpace($InjectionSubnetResourceId) -and $configuredSubnet -ine $InjectionSubnetResourceId) {
        throw 'Gateway is injected into a subnet other than the approved injection subnet; preserve it and obtain a dedicated-scope decision rather than moving a live gateway.'
    }
    $connections = @()
    if ($Service.properties.Contains('privateEndpointConnections') -and $Service.properties.privateEndpointConnections) {
        $connections = @($Service.properties.privateEndpointConnections)
    }
    if ($connections.Count -gt 0) {
        throw 'Gateway has a private endpoint connection, which classic VNet injection does not support. Investigate before proceeding; this indicates the instance is not the topology this automation manages.'
    }
    return $configuredSubnet
}

function Get-GatewayDeploymentPlan {
    <#
    .SYNOPSIS
    Observe absent, interrupted or injected gateway state; never writes.
    .DESCRIPTION
    Request is the parent's authorized ARM transport: (method, absolute URI,
    body, headers) -> IDictionary { StatusCode; Body; Headers }. It must not log
    tokens/response bodies. Freeze this whole result alongside resolved inputs.

    There is no public-then-private transition on this topology: an injected
    Internal-mode gateway is private from the moment it exists. `initialProvisioning`
    therefore no longer gates public network access. It means "this is a first or
    interrupted creation", and it holds the owned stop control on so the gateway
    serves no request until the operator has published the private DNS A record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceResourceId,
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$EnvironmentName,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$WorkloadKey,
        [Parameter(Mandatory)][scriptblock]$Request,
        [AllowNull()][AllowEmptyString()][string]$InjectionSubnetResourceId = $null
    )
    Assert-GatewayResourceId $ServiceResourceId
    $owner = Get-GatewayOwnerName -EnvironmentName $EnvironmentName -WorkloadKey $WorkloadKey
    $apiPath = Get-GatewayApiPath -WorkloadKey $WorkloadKey
    $service = Get-GatewayService $ServiceResourceId $EnvironmentName $Request -AllowAbsent -Owner $owner
    $observedState = 'Absent'
    $initialProvisioning = $true
    $injectionSubnet = ''
    $facts = @()
    if ($null -ne $service) {
        $access = $service.properties.publicNetworkAccess
        if ($access -cnotin @('Enabled', 'Disabled')) { throw 'Gateway returned an unsupported public network access state.' }
        if ($service.properties.provisioningState -cnotin @('Succeeded', 'Failed', 'Canceled')) {
            throw 'Gateway provisioning is still in progress; wait and re-observe before planning.'
        }
        $injectionSubnet = Assert-GatewayInjection -Service $service -InjectionSubnetResourceId $InjectionSubnetResourceId
        if ($service.properties.provisioningState -ceq 'Succeeded') {
            $observedState = 'Injected'
            $initialProvisioning = $false
        }
        else {
            # An owned failed/cancelled creation is resumable. It is NOT a
            # private-to-public regression, because Internal mode is set at
            # creation and a redeploy cannot silently publish the gateway.
            $observedState = 'InterruptedProvisioning'
            $initialProvisioning = $true
        }
        $facts = Get-GatewayOwnedChildren $ServiceResourceId $owner $Request -ApiPath $apiPath
    }
    return [ordered]@{
        schemaVersion = 2
        serviceResourceId = $ServiceResourceId
        networkModel = 'classic-vnet-injection'
        virtualNetworkType = 'Internal'
        injectionSubnetResourceId = $injectionSubnet
        environmentName = $EnvironmentName
        workloadKey = $WorkloadKey
        owner = $owner
        apiPath = $apiPath
        observedState = $observedState
        initialProvisioning = $initialProvisioning
        observedStateHash = Get-CanonicalHash @{ service = $service; ownedChildren = $facts }
        ownedChildren = $facts
    }
}

function Assert-GatewayDeploymentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Plan, [Parameter(Mandatory)][scriptblock]$Request)
    if ($Plan.schemaVersion -ne 2 -or $Plan.owner -cne (Get-GatewayOwnerName -EnvironmentName $Plan.environmentName -WorkloadKey $Plan.workloadKey) -or
        $Plan.apiPath -cne (Get-GatewayApiPath -WorkloadKey $Plan.workloadKey) -or
        $Plan.networkModel -cne 'classic-vnet-injection' -or
        $Plan.observedState -cnotin @('Absent', 'InterruptedProvisioning', 'Injected') -or
        $Plan.initialProvisioning -ne ($Plan.observedState -cin @('Absent', 'InterruptedProvisioning'))) { throw 'Invalid gateway state plan.' }
    $current = Get-GatewayDeploymentPlan -ServiceResourceId $Plan.serviceResourceId -EnvironmentName $Plan.environmentName `
        -WorkloadKey $Plan.workloadKey -Request $Request -InjectionSubnetResourceId $Plan.injectionSubnetResourceId
    if ($current.observedStateHash -cne $Plan.observedStateHash) { throw 'Gateway plan is stale; repeat preview and approval with observed state.' }
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

function Complete-GatewayActivation {
    <#
    .SYNOPSIS
    Verify an owned injected gateway's private topology and reconcile its stop control.
    .DESCRIPTION
    Replaces the former Complete-GatewayPrivateAccess. On classic VNet injection
    there is no public-disable step to perform, because there is no private
    endpoint to enable one. Learn: "In the classic API Management tiers, private
    endpoints aren't supported in instances injected in an internal or external
    virtual network", and "You can disable public network access in API
    Management instances configured with a private endpoint, not with other
    networking configurations".

    Privacy on this topology is established at CREATION by virtualNetworkType
    Internal - "None of the API Management endpoints are registered on the public
    DNS" - so there is nothing to complete. What this function verifies instead is
    that the observed instance really is Internal-mode, injected into the approved
    subnet, carries no private endpoint, and has settled in Succeeded.

    No resource creation/deletion, public-access change, or global-policy change
    is performed. Optional StopNewRequests explicitly restores and verifies the
    approved Boolean using only the owned nonsecret stop entity: GET metadata,
    POST listValue, and If-Match-protected value-only PATCH. Without Apply this
    function remains GET-only, including with StopNewRequests.

    DNS resolution, backend permissions and live inference remain separate gates.
    In particular this function CANNOT prove the operator created the private DNS
    A record; an injected gateway with no DNS record is unreachable but otherwise
    perfectly healthy from the control plane's point of view.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][scriptblock]$Request,
        [switch]$Apply,
        [bool]$StopNewRequests,
        [ValidateRange(1, 120)][int]$MaxAttempts = 60,
        [ValidateRange(0, 30)][int]$RetryDelaySeconds = 10
    )
    Assert-GatewayResourceId $Plan.serviceResourceId
    if ($Plan.schemaVersion -ne 2 -or $Plan.environmentName -cnotin @('dev', 'test', 'prod') -or
        $Plan.networkModel -cne 'classic-vnet-injection' -or
        $Plan.owner -cne (Get-GatewayOwnerName -EnvironmentName $Plan.environmentName -WorkloadKey $Plan.workloadKey)) {
        throw 'Invalid gateway completion ownership plan.'
    }
    $restoreStop = $PSBoundParameters.ContainsKey('StopNewRequests')
    $desiredStop = if ($StopNewRequests) { 'true' } else { 'false' }
    $mayWrite = $Apply -and $PSCmdlet.ShouldProcess($Plan.serviceResourceId, 'Reconcile the approved stop control on the owned injected gateway')
    $patchAccepted = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $service = Get-GatewayService $Plan.serviceResourceId $Plan.environmentName $Request -Owner $Plan.owner
        if ($service.properties.publicNetworkAccess -cnotin @('Enabled', 'Disabled')) { throw 'Gateway returned an unsupported public network access state.' }
        if ($service.properties.provisioningState -cin @('Failed', 'Canceled')) { throw 'Gateway provisioning failed; activation cannot declare success.' }
        $injectionSubnet = Assert-GatewayInjection -Service $service -InjectionSubnetResourceId $Plan.injectionSubnetResourceId
        $base = @{
            serviceResourceId = $Plan.serviceResourceId
            injectionSubnetResourceId = $injectionSubnet
            virtualNetworkType = 'Internal'
            networkModel = 'classic-vnet-injection'
            publicNetworkAccess = $service.properties.publicNetworkAccess
        }
        if ($service.properties.provisioningState -ceq 'Succeeded') {
            if (-not $restoreStop) {
                return $base + @{ status = 'VerifiedControlPlane'; changed = $patchAccepted }
            }
            if (-not $mayWrite) {
                return $base + @{ status = 'Planned'; action = 'ReconcileOwnedStopControl' }
            }
            $stop = Get-GatewayStopValue $Plan.serviceResourceId $Plan.owner $Request
            $latestService = Get-GatewayService $Plan.serviceResourceId $Plan.environmentName $Request -Owner $Plan.owner
            $null = Assert-GatewayInjection -Service $latestService -InjectionSubnetResourceId $Plan.injectionSubnetResourceId
            if ($stop.stable -and $latestService.properties.provisioningState -ceq 'Succeeded') {
                if ($stop.value -ceq $desiredStop) {
                    return $base + @{
                        status = 'VerifiedControlPlane'; changed = $patchAccepted
                        stopControlVerified = $true; stopNewRequests = $StopNewRequests
                    }
                }
                $response = Invoke-GatewayRequest $Request PATCH $stop.resourceId '2024-05-01' @{ properties = @{ value = $desiredStop } } @{ 'If-Match' = $stop.etag }
                if ($response.StatusCode -in @(200, 202)) { $patchAccepted = $true }
                elseif ($response.StatusCode -notin @(409, 412, 429, 503)) { throw "Gateway stop-control PATCH failed (HTTP $($response.StatusCode))." }
            }
        }
        elseif (-not $mayWrite) {
            return $base + @{ status = 'Planned'; action = 'AwaitProvisioning' }
        }
        if ($attempt -lt $MaxAttempts -and $RetryDelaySeconds) { Start-Sleep -Seconds $RetryDelaySeconds }
    }
    throw 'Gateway activation exceeded its bounded retry budget; verification did not complete.'
}
Export-ModuleMember -Function Assert-GatewayConfiguration, Get-GatewayDeploymentPlan, Assert-GatewayDeploymentPlan, Complete-GatewayActivation
