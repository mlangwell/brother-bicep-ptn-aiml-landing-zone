#Requires -Version 7.0
<#
.SYNOPSIS
Shared, offline environment validation and typed ARM parameter composition.
.DESCRIPTION
Read and Resolve validate the same closed v1 contract. They never consult azd,
environment variables, Azure or GitHub. AllowSynthetic is for offline tests,
not an execution authorization. Live callers must not expose that switch.
VM deployment is unsupported. The required but unused secure VM parameter is
emitted as an empty string only after validating that every VM path is off.
Developer and gateway handoffs contain profile inputs, not runtime settings.
The parent Bicep derives gateway URLs, application environment and App Configuration.

The hash covers the original validated profile and the exact ARM parameter
document, excluding only configurationHash itself. Object keys use ordinal
ordering; array order is significant. No general deployment substitution occurs.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SchemaPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'environments\schema.json'
$script:SubnetStems = @('agent', 'acaEnvironment', 'pe', 'azureBastion', 'azureFirewall', 'gateway', 'azureAppGateway', 'jumpbox', 'devopsBuildAgents')

function ConvertTo-CanonicalValue {
    param([AllowNull()][AllowEmptyCollection()][AllowEmptyString()][object]$Value, [int]$Depth = 0)
    if ($Depth -gt 90) { throw 'Canonical JSON exceeds the supported nesting depth.' }
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [Collections.IDictionary] -or $Value.GetType() -eq [pscustomobject]) {
        $map = $Value
        if ($Value -isnot [Collections.IDictionary]) {
            $map = [ordered]@{}
            foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = $property.Value }
        }
        foreach ($key in $map.Keys) {
            if ($key -isnot [string]) { throw 'Canonical JSON object keys must be strings.' }
        }
        [string[]]$keys = @($map.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $parts = foreach ($key in $keys) {
            (ConvertTo-Json -InputObject $key -Compress) + ':' + (ConvertTo-CanonicalValue -Value $map[$key] -Depth ($Depth + 1))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Collections.IList]) {
        $parts = foreach ($item in $Value) { ConvertTo-CanonicalValue -Value $item -Depth ($Depth + 1) }
        return '[' + ($parts -join ',') + ']'
    }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [decimal]) { return $Value.ToString('G29', $culture) }
    if ($Value -is [double] -or $Value -is [single]) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw 'Canonical JSON requires finite numbers.' }
        if ($Value -eq 0) { return '0' }
        return $Value.ToString('R', $culture)
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        return $Value.ToString($culture)
    }
    throw 'Canonical JSON supports only dictionaries, JSON arrays and JSON scalar values.'
}

function ConvertTo-CanonicalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][object]$Value)
    ConvertTo-CanonicalValue -Value $Value
}

function Get-CanonicalHash {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][object]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonicalJson -Value $Value))
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertFrom-ProfileElement {
    param([System.Text.Json.JsonElement]$Element)
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $result = [ordered]@{}
            $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $keys.Add($property.Name)) { throw 'Profile JSON contains duplicate or case-colliding object keys.' }
                $result[$property.Name] = ConvertFrom-ProfileElement $property.Value
            }
            return ,$result
        }
        'Array' {
            $result = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $result.Add((ConvertFrom-ProfileElement $item)) }
            return ,$result.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            [long]$integer = 0
            [decimal]$number = 0
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            if ($Element.TryGetDecimal([ref]$number)) { return $number }
            $double = $Element.GetDouble()
            if ([double]::IsInfinity($double) -or [double]::IsNaN($double)) { throw 'Profile JSON contains a nonfinite number.' }
            return $double
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'Profile contains an unsupported JSON token.' }
    }
}

function ConvertFrom-ProfileJson {
    param([string]$Json)
    $document = $null
    try {
        try { $document = [System.Text.Json.JsonDocument]::Parse($Json) }
        catch { throw 'Profile is not valid strict JSON. Values are not included in diagnostics.' }
        ConvertFrom-ProfileElement $document.RootElement
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Assert-SafeProfileValues {
    param([AllowNull()][AllowEmptyCollection()][object]$Value, [bool]$Synthetic, [string]$Path = 'profile')
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $safeKey = if ($key -cmatch '^[A-Za-z][A-Za-z0-9_]*$') { $key } else { '[property]' }
            $childPath = "$Path.$safeKey"
            if ($key -match '(?i)(password|passwd|secret|credential|connectionstring|authorization|private.?key|access.?token|refresh.?token|api.?key|account.?key|sas.?token|^(?:tokens?|keys?|headers?)$)' -and
                -not ($key -ceq 'useCAppAPIKey' -and $Value[$key] -is [bool])) {
                throw "Secret fields are not permitted at $childPath."
            }
            Assert-SafeProfileValues -Value $Value[$key] -Synthetic $Synthetic -Path $childPath
        }
    }
    elseif ($Value -is [Collections.IList]) {
        for ($i = 0; $i -lt $Value.Count; $i++) {
            Assert-SafeProfileValues -Value $Value[$i] -Synthetic $Synthetic -Path "$Path[$i]"
        }
    }
    elseif ($Value -is [string]) {
        if ($Value -match '\$\{|\$\(|<[^>]+>|(?i)\b(?:REPLACE_ME|CHANGEME|TODO_REQUIRED)\b' -or $Value -match '^\s*\[') {
            throw "Unresolved substitution, placeholder or ARM expression at $Path."
        }
        if ($Value -match '(?i)(?:password|passwd|clientsecret|api[_-]?key|accountkey|sharedaccesssignature|authorization)\s*[:=]|(?:^|[?&;])sig=|^\s*Bearer\s+\S+|-----BEGIN .*PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' -or
            $Value -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/\s]*@') {
            throw "Credential-bearing value is not permitted at $Path."
        }
        if (-not $Synthetic -and $Value -match '(?i)synthetic|never-deploy|example\.invalid|00000000-0000-4000-8000-') {
            throw "Synthetic fixture markers at $Path require synthetic=true and offline AllowSynthetic."
        }
        if ($Value -match '^/subscriptions/') {
            $parts = $Value.Split('/')
            $subscription = [guid]::Empty
            if ($parts.Count -lt 9 -or -not [guid]::TryParseExact($parts[2], 'D', [ref]$subscription) -or $subscription -eq [guid]::Empty) {
                throw "Malformed ARM subscription identifier at $Path."
            }
        }
    }
}

function Assert-UniqueValues {
    param([AllowEmptyCollection()][object[]]$Values, [string]$Path, [switch]$CaseSensitive)
    $comparer = if ($CaseSensitive) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
    $seen = [Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($value in $Values) {
        if (-not $seen.Add([string]$value)) { throw "Duplicate or conflicting entries at $Path." }
    }
}

function Get-Ipv4Number {
    param([string]$Address, [string]$Path)
    if ($Address -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') {
        throw "A canonical IPv4 address is required at $Path."
    }
    [uint64]$value = 0
    foreach ($part in $Address.Split('.')) {
        $octet = [int]$part
        if ($octet -gt 255) { throw "Invalid IPv4 address at $Path." }
        $value = ($value -shl 8) + $octet
    }
    return $value
}

function Get-ProfileCidrRange {
    param([string]$Cidr, [string]$Path)
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^(?:[0-9]|[12][0-9]|3[0-2])$') { throw "Invalid CIDR at $Path." }
    $address = Get-Ipv4Number $parts[0] $Path
    $size = [uint64][Math]::Pow(2, 32 - [int]$parts[1])
    if (($address % $size) -ne 0) { throw "CIDR must be network-aligned at $Path." }
    return @{ Start = $address; End = $address + $size - 1; Path = $Path }
}

function Test-RangeOverlap {
    param([Collections.IDictionary]$Left, [Collections.IDictionary]$Right)
    return $Left.Start -le $Right.End -and $Right.Start -le $Left.End
}

function Test-RangeContained {
    param([Collections.IDictionary]$Inner, [AllowEmptyCollection()][object[]]$Outers)
    foreach ($outer in $Outers) {
        if ($Inner.Start -ge $outer.Start -and $Inner.End -le $outer.End) { return $true }
    }
    return $false
}

function Assert-NoRangeOverlap {
    param([AllowEmptyCollection()][object[]]$Ranges)
    for ($i = 0; $i -lt $Ranges.Count; $i++) {
        for ($j = $i + 1; $j -lt $Ranges.Count; $j++) {
            if (Test-RangeOverlap $Ranges[$i] $Ranges[$j]) {
                throw "Network overlap between $($Ranges[$i].Path) and $($Ranges[$j].Path)."
            }
        }
    }
}

function Assert-ProfileTopology {
    param([Collections.IDictionary]$Profile)
    $p = $Profile.parameters
    $spokes = @($p.vnetAddressPrefixes | ForEach-Object { Get-ProfileCidrRange $_ 'parameters.vnetAddressPrefixes' })
    $hubs = @($Profile.network.hubAddressPrefixes | ForEach-Object { Get-ProfileCidrRange $_ 'network.hubAddressPrefixes' })
    $reserved = @($Profile.network.reservedAddressPrefixes | ForEach-Object { Get-ProfileCidrRange $_ 'network.reservedAddressPrefixes' })
    Assert-NoRangeOverlap -Ranges @($spokes + $hubs + $reserved)
    $subnets = @(
        foreach ($stem in $script:SubnetStems) {
            Get-ProfileCidrRange $p["${stem}SubnetPrefix"] "parameters.${stem}SubnetPrefix"
        }
        Get-ProfileCidrRange $Profile.gateway.integrationSubnetPrefix 'gateway.integrationSubnetPrefix'
    )
    foreach ($subnet in $subnets) {
        if (-not (Test-RangeContained $subnet $spokes)) { throw "Subnet must be contained in the spoke at $($subnet.Path)." }
    }
    $runner = Get-ProfileCidrRange $Profile.network.runnerSubnetPrefix 'network.runnerSubnetPrefix'
    if (-not (Test-RangeContained $runner @($spokes + $hubs))) { throw 'network.runnerSubnetPrefix must belong to the declared spoke or hub.' }
    Assert-NoRangeOverlap -Ranges @($subnets + @($runner) + $reserved)
    $names = @($script:SubnetStems | ForEach-Object { $p["${_}SubnetName"] }) + @($Profile.gateway.integrationSubnetName)
    Assert-UniqueValues -Values $names -Path 'parameters subnet names / gateway.integrationSubnetName'

    if ($p.useExistingVNet -and -not $p.Contains('existingVnetResourceId')) { throw 'parameters.existingVnetResourceId is required for useExistingVNet.' }
    if (-not $p.useExistingVNet -and $p.Contains('existingVnetResourceId')) { throw 'parameters.existingVnetResourceId conflicts with useExistingVNet=false.' }
    if (-not $p.useExistingVNet -and -not $p.deploySubnets) { throw 'parameters.deploySubnets must be true for a new VNet.' }
    $hasHub = $p.Contains('hubIntegrationHubVnetResourceId')
    $hasNextHop = $p.Contains('hubIntegrationEgressNextHopIp')
    $hasRouteTable = $p.Contains('hubIntegrationExistingRouteTableResourceId')
    if ($hasNextHop -and $hasRouteTable) { throw 'Conflicting parameters.hubIntegrationEgressNextHopIp and hubIntegrationExistingRouteTableResourceId.' }
    if ($p.deploymentMode -ceq 'ailz-integrated') {
        if (-not $hasHub -or $hubs.Count -eq 0) { throw 'Integrated topology requires parameters.hubIntegrationHubVnetResourceId and network.hubAddressPrefixes.' }
        if (-not $hasNextHop -and -not $hasRouteTable) { throw 'Integrated topology requires one explicit hub egress routing mechanism.' }
        if ($p.deployAzureFirewall) { throw 'Integrated hub egress conflicts with parameters.deployAzureFirewall.' }
        foreach ($flag in @('hubIntegrationCreateHubPeering', 'hubIntegrationPeeringAllowGatewayTransit', 'hubIntegrationPeeringUseRemoteGateways')) {
            if (-not $p.Contains($flag)) { throw "Integrated topology requires explicit parameters.$flag." }
        }
        if ($p.hubIntegrationPeeringAllowGatewayTransit -and $p.hubIntegrationPeeringUseRemoteGateways) { throw 'Conflicting hub peering gateway transit flags.' }
    }
    elseif ($hasHub -or $hasNextHop -or $hasRouteTable -or $hubs.Count -gt 0) {
        throw 'Hub inputs require parameters.deploymentMode=ailz-integrated.'
    }
    elseif (-not $p.deployAzureFirewall) {
        throw 'Standalone private topology requires an explicit local firewall; hub egress uses ailz-integrated mode.'
    }
    if ($hasNextHop) {
        $ip = Get-Ipv4Number $p.hubIntegrationEgressNextHopIp 'parameters.hubIntegrationEgressNextHopIp'
        if (-not (Test-RangeContained @{ Start = $ip; End = $ip } $hubs)) { throw 'parameters.hubIntegrationEgressNextHopIp must be inside the declared hub.' }
    }
    $runnerVnet = $Profile.github.runner.subnetResourceId -replace '/subnets/[^/]+$', ''
    if (Test-RangeContained $runner $hubs) {
        if (-not $hasHub -or $runnerVnet -ine $p.hubIntegrationHubVnetResourceId) { throw 'github.runner.subnetResourceId conflicts with the declared hub allocation.' }
    }
    else {
        if ($p.useExistingVNet) { $spokeId = $p.existingVnetResourceId }
        else {
            if (-not $p.Contains('vnetName')) { throw 'parameters.vnetName must be explicit when the runner is allocated in the new spoke.' }
            $spokeId = "/subscriptions/$($Profile.azure.subscriptionId)/resourceGroups/$($Profile.azure.resourceGroup)/providers/Microsoft.Network/virtualNetworks/$($p.vnetName)"
        }
        if ($runnerVnet -ine $spokeId) { throw 'github.runner.subnetResourceId conflicts with the declared spoke allocation.' }
        $runnerName = ($Profile.github.runner.subnetResourceId -split '/')[-1]
        if ($names -icontains $runnerName) { throw 'github.runner.subnetResourceId must not reuse a workload or gateway subnet.' }
    }
    if ($p.Contains('privateEndpointLocation') -and $p.privateEndpointLocation -cne $Profile.azure.location) {
        throw 'parameters.privateEndpointLocation conflicts with the private profile VNet location.'
    }
    $zones = @{
        CogSvcs = 'privatelink.cognitiveservices.azure.com'
        OpenAi = 'privatelink.openai.azure.com'
        AiServices = 'privatelink.services.ai.azure.com'
        Search = 'privatelink.search.windows.net'
        Cosmos = 'privatelink.documents.azure.com'
        Blob = 'privatelink.blob.core.windows.net'
        KeyVault = 'privatelink.vaultcore.azure.net'
        AppConfig = 'privatelink.azconfig.io'
        ContainerApps = "privatelink.$($Profile.azure.location).azurecontainerapps.io"
        Acr = 'privatelink.azurecr.io'
        AzureMonitor = 'privatelink.monitor.azure.com'
        OmsOpsInsights = 'privatelink.oms.opinsights.azure.com'
        OdsOpsInsights = 'privatelink.ods.opinsights.azure.com'
        AzureAutomation = 'privatelink.agentsvc.azure.automation.net'
        AppInsights = 'privatelink.applicationinsights.io'
    }
    $requiredZones = [Collections.Generic.List[string]]::new()
    if ($p.deployAiFoundry) { $requiredZones.AddRange([string[]]@('CogSvcs', 'OpenAi', 'AiServices')) }
    if ($p.deploySpeechService) { $requiredZones.Add('CogSvcs') }
    foreach ($entry in @(
        @('deploySearchService', 'Search'), @('deployCosmosDb', 'Cosmos'), @('deployStorageAccount', 'Blob'),
        @('deployKeyVault', 'KeyVault'), @('deployAppConfig', 'AppConfig'), @('deployContainerEnv', 'ContainerApps'), @('deployContainerApps', 'Acr')
    )) { if ($p[$entry[0]]) { $requiredZones.Add($entry[1]) } }
    if ($p.enablePrivateLogAnalytics -and $p.deployLogAnalytics -and -not $p.Contains('existingLogAnalyticsWorkspaceResourceId')) {
        $requiredZones.AddRange([string[]]@('AzureMonitor', 'OmsOpsInsights', 'OdsOpsInsights', 'AzureAutomation', 'AppInsights'))
    }
    foreach ($zone in $zones.Keys) {
        $parameter = "existingPrivateDnsZone${zone}ResourceId"
        if ($p.Contains($parameter) -and ($p[$parameter] -split '/')[-1] -cne $zones[$zone]) { throw "Wrong private DNS namespace at parameters.$parameter." }
        if ($p.deploymentMode -ceq 'ailz-integrated' -and $requiredZones.Contains($zone) -and -not $p.Contains($parameter)) {
            throw "Integrated topology requires the BYO private DNS input parameters.$parameter."
        }
    }
    # Classic VNet injection: the gateway has no private endpoint, so there is no
    # privatelink zone. Internal mode registers nothing on public DNS, so the
    # operator supplies a SERVICE-SCOPED zone instead. Learn forbids a private
    # zone for the shared apex domain azure-api.net outright.
    $gatewayZone = ($Profile.gateway.privateDnsZoneResourceId -split '/')[-1]
    if ($gatewayZone -ieq 'azure-api.net') {
        throw 'gateway.privateDnsZoneResourceId must never be the apex azure-api.net domain; an apex private zone breaks resolution for other Azure services.'
    }
    if ($gatewayZone -ieq 'privatelink.azure-api.net') {
        throw 'gateway.privateDnsZoneResourceId must not be a privatelink zone: classic VNet injection cannot hold a private endpoint. Supply the service-scoped <gateway-name>.azure-api.net zone.'
    }
    if ($gatewayZone -cne "$($Profile.gateway.name.ToLowerInvariant()).azure-api.net") {
        throw 'Wrong private DNS namespace at gateway.privateDnsZoneResourceId; it must be the service-scoped <gateway-name>.azure-api.net zone.'
    }
}

function Assert-ProfileIdentitiesAndRelease {
    param([Collections.IDictionary]$Profile)
    $ids = $Profile.identities
    if ($ids.developerObjectIds.Count + $ids.developerGroupObjectIds.Count -eq 0) {
        throw 'identities must explicitly name at least one developer object or developer group; the executor is not a developer default.'
    }
    foreach ($field in @('clientId', 'principalId', 'resourceId')) {
        Assert-UniqueValues @($ids.preview[$field], $ids.deploy[$field], $ids.workload[$field]) "identities.$field"
    }
    $privileged = @($ids.preview.clientId, $ids.preview.principalId, $ids.deploy.clientId, $ids.deploy.principalId)
    $callers = @($ids.developerObjectIds) + @($ids.developerGroupObjectIds) + @($ids.workload.clientId, $ids.workload.principalId)
    Assert-UniqueValues $callers 'identities developer/workload identities'
    foreach ($caller in $callers) {
        if ($privileged -icontains $caller) { throw 'Developer/workload identities must be isolated from preview and deployment identities.' }
    }
    $g = $Profile.github
    foreach ($ref in @($g.protectedRef, $Profile.release.ref)) {
        if ($ref -match '\.\.|//|@\{|\.lock(?:/|$)|[/.]$') { throw 'Invalid exact Git ref in github.protectedRef or release.ref.' }
    }
    if ($Profile.release.repository -cne $g.repository -or $Profile.release.ref -cne $g.protectedRef) {
        throw 'release.repository and release.ref must exactly match the trusted GitHub repository and protected ref.'
    }
    $repoParts = $g.repository.Split('/')
    $repoSubject = if ($g.oidc.subjectFormat -ceq 'immutable') {
        "repo:$($repoParts[0])@$($g.ownerId)/$($repoParts[1])@$($g.repositoryId)"
    }
    else { "repo:$($g.repository)" }
    if ($g.oidc.previewSubject -cne "${repoSubject}:environment:$($Profile.environment)-preview" -or
        $g.oidc.deploySubject -cne "${repoSubject}:environment:$($Profile.environment)") {
        throw 'github.oidc subjects must exactly bind the configured repository identity to distinct preview/deploy environments.'
    }
    Assert-UniqueValues @($g.environmentReviewers | ForEach-Object { "$($_.type):$($_.id)" }) 'github.environmentReviewers'
    Assert-UniqueValues $g.runner.labels 'github.runner.labels'
    if ($g.runner.labels -icontains 'ubuntu-latest' -or ($g.runner.labels -join ' ') -match '(?i)windows|macos') {
        throw 'github.runner.labels must select the approved private Linux runner, not a public or non-Linux pool.'
    }
    if ($g.runner.mode -ceq 'github-hosted-private' -and $g.offering -notin @('enterprise-cloud', 'team')) {
        throw 'github.offering is incompatible with the selected GitHub-hosted private runner contract.'
    }
    if ($g.visibility -ceq 'internal' -and $g.offering -cne 'enterprise-cloud') { throw 'Internal repository visibility requires an enterprise-cloud profile.' }
    if ($Profile.environment -in @('test', 'prod')) {
        if ($g.environmentReviewers.Count -eq 0) { throw 'github.environmentReviewers must explicitly protect test/prod deployment.' }
        if ($g.visibility -cne 'public' -and $g.offering -cne 'enterprise-cloud') {
            throw 'The private protected promotion contract requires an enterprise-cloud offering; entitlement must also be inspected before execution.'
        }
    }
}

function Assert-ProfileServicesAndGovernance {
    param([Collections.IDictionary]$Profile)
    $p = $Profile.parameters
    foreach ($flag in @('networkIsolation', 'aiFoundryDisableLocalAuth', 'deployNsgs')) {
        if (-not $p[$flag]) { throw "The private profile requires parameters.$flag=true." }
    }
    foreach ($flag in @('deployVM', 'deployJumpbox', 'deploySoftware', 'deployVmKeyVault', 'deployAAfAgentSvc', 'prepareHostedAgent',
        'deployHostedAgent', 'deployGroundingWithBing', 'enableAgenticRetrieval', 'useCAppAPIKey', 'policyManagedPrivateDns',
        'deployContainerRegistry', 'deployAcrTaskAgentPool')) {
        if ($p[$flag]) { throw "parameters.$flag is unsupported by the initial private developer profile." }
    }
    if ($p.allowedIpRanges.Count -gt 0) { throw 'parameters.allowedIpRanges must be empty for the private profile.' }
    if ($p.appRuntimeConfigurationMode -cne 'appConfig') { throw 'parameters.appRuntimeConfigurationMode must be appConfig.' }
    if ($p.deployContainerApps -and (-not $p.deployContainerEnv -or -not $p.deployAppConfig -or -not $Profile.gateway.enabled)) {
        throw 'Container Apps require a private environment, App Configuration and the governed gateway; direct inference fallback is not supported.'
    }
    if ($Profile.gateway.enabled -and (-not $p.deployAiFoundry -or -not $p.deployAfProject)) { throw 'Enabled gateway requires Foundry and its explicitly named project.' }
    if (($p.deployContainerEnv -or $p.deployAppInsights -or $Profile.gateway.enabled) -and
        -not $p.deployLogAnalytics -and -not $p.Contains('existingLogAnalyticsWorkspaceResourceId')) {
        throw 'Enabled compute, telemetry and gateway services require a local or existing Log Analytics workspace.'
    }
    if ($p.Contains('existingLogAnalyticsWorkspaceResourceId') -and $p.existingLogAnalyticsWorkspaceResourceId -notmatch '/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
        throw 'Wrong resource type at parameters.existingLogAnalyticsWorkspaceResourceId.'
    }
    if ($p.enableCosmosAnalyticalStorage -and -not $p.deployCosmosDb) { throw 'Analytical storage requires parameters.deployCosmosDb.' }
    if (-not $p.deployCosmosDb -and $p.databaseContainersList.Count -gt 0) { throw 'parameters.databaseContainersList requires deployCosmosDb.' }
    if (-not $p.deployStorageAccount -and $p.storageAccountContainersList.Count -gt 0) { throw 'parameters.storageAccountContainersList requires deployStorageAccount.' }
    if ($p.Contains('cafEnvironmentName') -and $p.cafEnvironmentName -cne $Profile.environment) { throw 'parameters.cafEnvironmentName conflicts with environment.' }
    foreach ($tag in @('environment', 'azd-env-name')) {
        if ($p.deploymentTags.Contains($tag) -and $p.deploymentTags[$tag] -cne $Profile.environment) { throw 'Environment deployment tags conflict with environment.' }
    }
    if ($p.deploymentTags.Contains('deploymentMode') -and $p.deploymentTags.deploymentMode -cne $p.deploymentMode) { throw 'deploymentTags.deploymentMode conflicts with parameters.deploymentMode.' }

    $governance = $Profile.governance
    foreach ($list in @('allowedLocations', 'allowedModelAssetIds', 'allowedDeploymentSkus', 'requiredTags')) {
        Assert-UniqueValues $governance[$list] "governance.$list"
    }
    $locations = @($Profile.azure.location)
    foreach ($key in @('cosmosLocation', 'searchServiceLocation', 'speechServiceLocation', 'privateEndpointLocation')) {
        if ($p.Contains($key)) { $locations += $p[$key] }
    }
    foreach ($location in $locations) {
        if ($governance.allowedLocations -cnotcontains $location) { throw 'All configured resource locations must be in governance.allowedLocations.' }
    }
    foreach ($tag in $governance.requiredTags) {
        if (-not $p.deploymentTags.Contains($tag)) { throw 'A governance.requiredTags entry is missing from parameters.deploymentTags.' }
    }
    if ($governance.policyEffect -ceq 'Deny' -and -not $governance.assessmentApproved) { throw 'governance.assessmentApproved is required before Deny enforcement.' }

    Assert-UniqueValues @($p.modelDeploymentList | ForEach-Object { $_.name }) 'parameters.modelDeploymentList.name'
    $canonicalNames = @()
    foreach ($list in @('modelDeploymentList', 'databaseContainersList', 'storageAccountContainersList')) {
        Assert-UniqueValues @($p[$list] | ForEach-Object { $_.name }) "parameters.$list.name"
        $canonicalNames += @($p[$list] | ForEach-Object { $_.canonical_name })
    }
    Assert-UniqueValues $canonicalNames 'parameters deployment-list canonical_name'
    foreach ($model in $p.modelDeploymentList) {
        $baseId = "azureml://registries/azure-openai/models/$($model.model.name)/"
        $versionId = "${baseId}versions/$($model.model.version)"
        if ($governance.allowedModelAssetIds -cnotcontains $baseId -and $governance.allowedModelAssetIds -cnotcontains $versionId) {
            throw 'parameters.modelDeploymentList contains a model/version without an exact governance.allowedModelAssetIds approval.'
        }
        if ($governance.allowedDeploymentSkus -cnotcontains $model.sku.name) { throw 'Model deployment SKU is not explicitly approved in governance.allowedDeploymentSkus.' }
    }
    Assert-UniqueValues @($p.workloadProfiles | ForEach-Object { $_.name }) 'parameters.workloadProfiles.name'
    foreach ($workload in $p.workloadProfiles) {
        if ($workload.workloadProfileType -cne 'Consumption' -and (-not $workload.Contains('minimumCount') -or -not $workload.Contains('maximumCount'))) {
            throw 'Dedicated parameters.workloadProfiles entries require explicit minimumCount and maximumCount.'
        }
        if ($workload.Contains('minimumCount') -and $workload.Contains('maximumCount') -and $workload.minimumCount -gt $workload.maximumCount) {
            throw 'parameters.workloadProfiles capacity bounds are reversed.'
        }
    }

    $deploymentNames = @($p.modelDeploymentList | ForEach-Object { $_.name })
    if ($deploymentNames -cnotcontains $Profile.application.modelDeployment) { throw 'application.modelDeployment is not an approved deployed model.' }
    $mappings = $Profile.gateway.callerMappings
    Assert-UniqueValues @($mappings | ForEach-Object { $_.objectId }) 'gateway.callerMappings.objectId'
    $approvedCallers = @($Profile.identities.workload.principalId) + @($Profile.identities.developerObjectIds)
    [decimal]$allocated = 0
    $quotaPeriods = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($mapping in $mappings) {
        if ($approvedCallers -inotcontains $mapping.objectId) { throw 'gateway.callerMappings contains an unapproved or privileged caller identity.' }
        if ($mapping.project -cne $p.aiFoundryProjectName) { throw 'gateway.callerMappings.project conflicts with the environment Foundry project.' }
        Assert-UniqueValues $mapping.models 'gateway.callerMappings.models'
        foreach ($model in $mapping.models) {
            if ($deploymentNames -cnotcontains $model) { throw 'gateway.callerMappings.models contains a deployment outside the exact approved model set.' }
        }
        if ($mapping.models -ccontains $Profile.application.modelDeployment -and
            ($Profile.application.maxOutputTokens -gt $mapping.tokensPerMinute -or $Profile.application.maxOutputTokens -gt $mapping.tokenQuota)) {
            throw 'application.maxOutputTokens exceeds its governed caller rate/quota.'
        }
        $allocated += [decimal]$mapping.tokenQuota * $mapping.models.Count
        $null = $quotaPeriods.Add($mapping.tokenQuotaPeriod)
    }
    if ($quotaPeriods.Count -gt 1) { throw 'gateway.callerMappings must use one explicit quota period for the environment token allocation.' }
    if ($Profile.gateway.enabled) {
        foreach ($caller in $approvedCallers) {
            $matches = @($mappings | Where-Object { $_.objectId -ieq $caller -and $_.models -ccontains $Profile.application.modelDeployment })
            if ($matches.Count -ne 1) { throw 'Every declared developer/workload caller requires exactly one governed application model mapping.' }
        }
    }
    elseif ($mappings.Count -gt 0) { throw 'Disabled gateway must not advertise active gateway.callerMappings.' }

    $budget = $governance.budget
    $allowance = $governance.inferenceAllowance
    if ($budget.contactEmails.Count + $budget.contactGroups.Count -eq 0) { throw 'governance.budget requires explicit notification recipients.' }
    Assert-UniqueValues $budget.contactEmails 'governance.budget.contactEmails'
    Assert-UniqueValues $budget.contactGroups 'governance.budget.contactGroups'
    $dates = @{}
    foreach ($entry in @(@('startDate', $budget.startDate), @('endDate', $budget.endDate), @('pricingDate', $allowance.pricingDate))) {
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($entry[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
            throw "Invalid calendar date at governance.$($entry[0])."
        }
        $dates[$entry[0]] = $date
    }
    if ($dates.startDate -ge $dates.endDate) { throw 'governance.budget.endDate must be later than startDate.' }
    if ($allowance.currency -cne $budget.currency) { throw 'governance inference allowance and budget currencies must match.' }
    if ($allowance.amount -gt $budget.amount) { throw 'governance.inferenceAllowance.amount exceeds the whole-environment budget.' }
    if ($allocated -gt $allowance.allocatedTokens) { throw 'gateway.callerMappings quotas exceed governance.inferenceAllowance.allocatedTokens.' }
}

function Get-ComposedParameterValues {
    param([Collections.IDictionary]$Profile)
    # workloadKey is a top-level deployment parameter, not gateway service
    # configuration: the Bicep gatewayConfiguration type is sealed, so it must be
    # lifted out of the copied gateway block rather than passed through with it.
    $gateway = [ordered]@{}
    foreach ($key in $Profile.gateway.Keys) {
        if ($key -ceq 'workloadKey') { continue }
        $gateway[$key] = $Profile.gateway[$key]
    }
    $developer = @{
        application = $Profile.application
        workloadIdentity = $Profile.identities.workload
        developerObjectIds = $Profile.identities.developerObjectIds
        developerGroupObjectIds = $Profile.identities.developerGroupObjectIds
        release = $Profile.release
    }
    $apps = @()
    if ($Profile.parameters.deployContainerApps) {
        $registryName = ($Profile.application.registryResourceId -split '/')[-1]
        $server = $registryName.ToLowerInvariant() + '.azurecr.io'
        # This single, bounded starter is not a customer application scale policy.
        $apps = @(@{
            name = $Profile.application.name
            service_name = 'developer-smoke'
            canonical_name = 'DEVELOPER_SMOKE_APP'
            external = $true
            target_port = 8080
            profile_name = $Profile.parameters.workloadProfiles[0].name
            min_replicas = 1
            max_replicas = 1
            cpu = '0.5'
            memory = '1.0Gi'
            roles = @('AppConfigurationDataReader', 'AcrPull')
            managedIdentity = $Profile.identities.workload
            registry = @{ server = $server; identity = $Profile.identities.workload.resourceId }
            image = "$server/$($Profile.application.imageRepository)@$($Profile.release.imageDigest)"
        })
    }
    $values = @{
        environmentName = $Profile.environment
        location = $Profile.azure.location
        principalId = $Profile.identities.deploy.principalId
        principalType = 'ServicePrincipal'
        deployApiManagement = $Profile.gateway.enabled
        apiManagementConfiguration = $gateway
        apiManagementWorkloadKey = $Profile.gateway.workloadKey
        enableDeveloperExperience = $Profile.parameters.deployContainerApps
        developerExperience = $developer
        containerAppsList = $apps
        acrDnsSuffix = 'azurecr.io'
        deployVM = $false
        # main.bicep requires this secure parameter even when no VM is deployed.
        vmAdminPassword = ''
    }
    foreach ($key in $values.Keys) {
        if ($Profile.parameters.Contains($key) -and
            (ConvertTo-CanonicalJson $Profile.parameters[$key]) -cne (ConvertTo-CanonicalJson $values[$key])) {
            throw "Conflicting composed override at parameters.$key."
        }
    }
    return $values
}

function Assert-EnvironmentProfile {
    param([Collections.IDictionary]$Profile, [switch]$AllowSynthetic)
    $synthetic = $Profile.Contains('synthetic') -and $Profile.synthetic -is [bool] -and $Profile.synthetic
    if ($synthetic -and -not $AllowSynthetic) { throw 'Synthetic profiles are rejected. AllowSynthetic is exclusively for offline tests, never deployment execution.' }
    Assert-SafeProfileValues -Value $Profile -Synthetic $synthetic
    $issues = @()
    $valid = Test-Json -Json (ConvertTo-CanonicalJson $Profile) -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue -ErrorVariable issues
    if (-not $valid) {
        $paths = @(
            foreach ($issue in $issues) {
                if ($issue.Exception.Message -match " at '([/A-Za-z0-9_~-]*)'$") {
                    if ($Matches[1]) { 'profile' + $Matches[1] } else { 'profile' }
                }
            }
        ) | Select-Object -Unique
        $where = if (@($paths).Count) { $paths -join ', ' } else { 'profile' }
        throw "Environment schema validation failed at $where. Supply required fields with exact types and allowed values; no input values are logged."
    }
    Assert-ProfileIdentitiesAndRelease $Profile
    Assert-ProfileServicesAndGovernance $Profile
    Assert-ProfileTopology $Profile
    return Get-ComposedParameterValues $Profile
}

function Read-EnvironmentProfile {
    [CmdletBinding()]
    [OutputType([Collections.IDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [switch]$AllowSynthetic
    )
    try { $json = [IO.File]::ReadAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) }
    catch { throw 'Environment profile could not be read. Check the selected file path and access.' }
    $profile = ConvertFrom-ProfileJson $json
    if ($profile -isnot [Collections.IDictionary]) { throw 'Environment profile must be a JSON object.' }
    $null = Assert-EnvironmentProfile $profile -AllowSynthetic:$AllowSynthetic
    return ,$profile
}

function Resolve-EnvironmentProfile {
    [CmdletBinding()]
    [OutputType([Collections.IDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][Collections.IDictionary]$Profile,
        [switch]$AllowSynthetic
    )
    $validated = ConvertFrom-ProfileJson (ConvertTo-CanonicalJson $Profile)
    $composed = Assert-EnvironmentProfile $validated -AllowSynthetic:$AllowSynthetic
    $parameters = @{}
    foreach ($key in $validated.parameters.Keys) { $parameters[$key] = @{ value = $validated.parameters[$key] } }
    foreach ($key in $composed.Keys) { $parameters[$key] = @{ value = $composed[$key] } }
    $resolved = @{
        schemaVersion = 1
        environment = $validated.environment
        profile = $validated
        parameters = @{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters = $parameters
        }
    }
    $resolved.configurationHash = Get-CanonicalHash $resolved
    return ,$resolved
}

function Invoke-CheckedNative {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Command,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Arguments = @()
    )
    try { $executable = @(Get-Command -Name $Command -CommandType Application -ErrorAction Stop)[0] }
    catch { throw 'Native executable was not found. No arguments or output are logged.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable.Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        try { $started = $process.Start() }
        catch { throw 'Native executable could not be started. No arguments or output are logged.' }
        if (-not $started) { throw 'Native executable did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Native process failed with exit code $($process.ExitCode). Output suppressed." }
        return $output
    }
    finally { $process.Dispose() }
}

function Write-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowNull()][AllowEmptyCollection()][object]$Value
    )
    $json = (ConvertTo-CanonicalJson $Value) + "`n"
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = [IO.Path]::GetDirectoryName($target)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.environment-json-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $target, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

Export-ModuleMember -Function Read-EnvironmentProfile, Resolve-EnvironmentProfile, ConvertTo-CanonicalJson, Get-CanonicalHash, Invoke-CheckedNative, Write-JsonFile
