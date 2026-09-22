#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')

function Get-GatewayObservedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [scriptblock]$Native = { param($Command, $Arguments) Invoke-CheckedNative -Command $Command -Arguments $Arguments }
    )
    $scope = $Profile.azure
    $name = $Profile.gateway.name
    $resourceId = "/subscriptions/$($scope.subscriptionId)/resourceGroups/$($scope.resourceGroup)/providers/Microsoft.ApiManagement/service/$name"
    $inventory = ConvertFrom-BootstrapJson -Json (& $Native 'az' @('resource', 'list', '--subscription', $scope.subscriptionId, '--resource-group', $scope.resourceGroup, '--resource-type', 'Microsoft.ApiManagement/service', '--only-show-errors', '--output', 'json'))
    $gateways = @($inventory | Where-Object { $_.name -ieq $name })
    if ($gateways.Count -eq 0) {
        return @{ gatewayExists = $false; resourceId = $resourceId; publicNetworkAccess = ''; privateEndpointIds = @() }
    }
    if ($gateways.Count -ne 1 -or $gateways[0].id -ine $resourceId) { throw 'Gateway inventory is ambiguous or outside the approved environment scope.' }
    $gateway = ConvertFrom-BootstrapJson -Json (& $Native 'az' @('resource', 'show', '--ids', $resourceId, '--api-version', '2024-05-01', '--only-show-errors', '--output', 'json'))
    if ($gateway.id -ine $resourceId -or -not $gateway.Contains('tags') -or $null -eq $gateway.tags -or $gateway.tags['ailz-managed-by'] -cne 'github-dev-environment' -or $gateway.tags['ailz-environment'] -cne $Profile.environment) {
        throw 'An existing gateway is not owned by this GitHub environment; it will not be adopted or overwritten.'
    }
    $access = $gateway.properties.publicNetworkAccess
    if ($access -cnotin @('Enabled', 'Disabled')) { throw 'Gateway public-network state could not be established.' }
    $privateIds = @()
    if ($gateway.properties.Contains('privateEndpointConnections') -and $null -ne $gateway.properties.privateEndpointConnections) {
        foreach ($connection in $gateway.properties.privateEndpointConnections) {
            if ($connection.properties.privateLinkServiceConnectionState.status -ceq 'Approved') {
                if ([string]::IsNullOrWhiteSpace($connection.properties.privateEndpoint.id)) { throw 'Approved private connection lacks its endpoint ID.' }
                $privateIds += $connection.properties.privateEndpoint.id
            }
        }
    }
    if ($access -ceq 'Disabled' -and $privateIds.Count -eq 0) { throw 'A private gateway has no approved private endpoint; repair and re-preview before deployment.' }
    return @{ gatewayExists = $true; resourceId = $resourceId; publicNetworkAccess = $access; privateEndpointIds = @($privateIds | Sort-Object -Unique -CaseSensitive) }
}

function Get-DeploymentParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Resolved,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ObservedState
    )
    $parameters = ConvertFrom-BootstrapJson -Json (ConvertTo-CanonicalJson -Value $Resolved.parameters)
    if ($parameters.parameters.deployApiManagement.value -isnot [bool]) { throw 'Gateway feature flag is not a typed boolean.' }
    if ($parameters.parameters.deployApiManagement.value) {
        if ($ObservedState.gatewayExists -and $ObservedState.publicNetworkAccess -cnotin @('Enabled', 'Disabled')) { throw 'Unknown existing gateway state.' }
        $parameters.parameters.apiManagementConfiguration.value.initialProvisioning =
            -not $ObservedState.gatewayExists -or
            ($ObservedState.publicNetworkAccess -ceq 'Enabled' -and $ObservedState.privateEndpointIds.Count -eq 0)
    }
    return $parameters
}

function Assert-AzureDeploymentIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][ValidateSet('Preview', 'Deploy')][string]$Phase,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Account
    )
    $identity = $Profile.identities[$Phase.ToLowerInvariant()]
    if ($Account.id -ine $Profile.azure.subscriptionId -or $Account.tenantId -ine $Profile.azure.tenantId) { throw 'Azure session is outside the approved subscription or tenant.' }
    if ($Account.user.type -ine 'servicePrincipal' -or $Account.user.name -ine $identity.clientId) {
        throw 'Azure session is not the separate identity approved for this phase; interactive or ambient credentials are not a substitute.'
    }
}

function New-EnvironmentArmRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Profile)
    $subscriptionId = $Profile.azure.subscriptionId
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$($Profile.azure.resourceGroup)"
    $gatewayId = "$scope/providers/Microsoft.ApiManagement/service/$($Profile.gateway.name)"
    $stopId = "$gatewayId/namedValues/ailz-inference-$($Profile.environment)-$($Profile.gateway.workloadKey)-stop"
    $approvedStop = $Profile.gateway.stopNewRequests
    $nativeCommand = Get-Command Invoke-CheckedNative -ErrorAction Stop
    $jsonCommand = Get-Command ConvertTo-CanonicalJson -ErrorAction Stop
    $parserCommand = Get-Command ConvertFrom-BootstrapJson -ErrorAction Stop
    return {
        param($Method, $Uri, $Body, $Headers)
        $target = [Uri]$Uri
        $allowedPath = $target.AbsolutePath.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase)
        if ($target.Scheme -cne 'https' -or $target.Host -cne 'management.azure.com' -or $target.Port -ne 443 -or $target.UserInfo -or -not $allowedPath) {
            throw 'ARM request is outside the approved environment.'
        }
        $stopValueRead = $Method -ceq 'POST' -and $target.AbsolutePath -ieq "$stopId/listValue" -and $null -eq $Body
        if ($Method -cne 'GET' -and -not $stopValueRead) {
            $disablePublic = $Method -ceq 'PATCH' -and $target.AbsolutePath -ieq $gatewayId -and
                (& $jsonCommand -Value $Body) -ceq '{"properties":{"publicNetworkAccess":"Disabled"}}'
            $setStop = $Method -cin @('PUT', 'PATCH') -and $target.AbsolutePath -ieq $stopId -and
                $Body.properties.value -ceq ([string]$approvedStop).ToLowerInvariant()
            if ($setStop) {
                if (@($Body.Keys | Where-Object { $_ -cne 'properties' }).Count -or
                    @($Body.properties.Keys | Where-Object { $_ -cnotin @('value', 'displayName', 'secret', 'tags') }).Count -or
                    ($Body.properties.Contains('secret') -and $Body.properties.secret -ne $false)) {
                    throw 'Stop-control completion cannot introduce keys, secret references or unrelated properties.'
                }
            }
            if (-not $disablePublic -and -not $setStop) { throw 'Completion transport only permits public-disable and the approved owned stop-control value.' }
        }
        foreach ($key in $Headers.Keys) {
            if ($key -cnotin @('If-Match', 'If-None-Match', 'Accept')) { throw 'ARM transport header override is not permitted.' }
        }
        $token = & $parserCommand -Json (& $nativeCommand -Command az -Arguments @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '--subscription', $subscriptionId, '--only-show-errors', '--output', 'json'))
        $requestHeaders = @{ Authorization = "Bearer $($token.accessToken)" }
        foreach ($key in $Headers.Keys) {
            $requestHeaders[$key] = $Headers[$key]
        }
        $options = @{ Method=$Method; Uri=$target.AbsoluteUri; Headers=$requestHeaders; SkipHttpErrorCheck=$true; MaximumRedirection=0; TimeoutSec=60; Verbose=$false; Debug=$false }
        if ($null -ne $Body) { $options.ContentType='application/json'; $options.Body=& $jsonCommand -Value $Body }
        try {
            $response = Invoke-WebRequest @options
            $responseBody = if ([string]::IsNullOrWhiteSpace($response.Content)) { @{} } else { & $parserCommand -Json $response.Content }
            $responseHeaders = @{}
            foreach ($key in $response.Headers.Keys) { $responseHeaders[$key] = [string](@($response.Headers[$key])[0]) }
            return @{ StatusCode=[int]$response.StatusCode; Body=$responseBody; Headers=$responseHeaders }
        }
        finally {
            $token.accessToken = $null
            $requestHeaders.Authorization = $null
        }
    }.GetNewClosure()
}

Export-ModuleMember -Function Get-GatewayObservedState, Get-DeploymentParameters, Assert-AzureDeploymentIdentity, New-EnvironmentArmRequest
