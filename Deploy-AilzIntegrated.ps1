<#
THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.

This sample is not supported under any Microsoft standard support program or service. 
 The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
 implied warranties including, without limitation, any implied warranties of merchantability
 or of fitness for a particular purpose. The entire risk arising out of the use or performance
 of the sample and documentation remains with you. In no event shall Microsoft, its authors,
 or anyone else involved in the creation, production, or delivery of the script be liable for 
 any damages whatsoever (including, without limitation, damages for loss of business profits, 
 business interruption, loss of business information, or other pecuniary loss) arising out of 
 the use of or inability to use the sample or documentation, even if Microsoft has been advised 
 of the possibility of such damages, rising out of the use of or inability to use the sample script, 
 even if Microsoft has been advised of the possibility of such damages.
 #>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Location,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $HubVnetResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EgressNextHopIp,

    [string] $ExistingLogAnalyticsWorkspaceResourceId,
    [string] $ExistingApplicationInsightsResourceId,
    [string] $ExistingApplicationInsightsConnectionString,
    [switch] $DeployApiManagement,
    [string] $ApiManagementPublisherEmail,
    [string] $ApiManagementPublisherName = 'AI Landing Zone',
    [string[]] $ApiManagementIngressSourceAddressPrefixes = @(),
    [string] $GatewayConfigurationPath,
    [hashtable] $AdditionalEnvironmentVariables = @{},
    [ValidateSet('Full', 'Slim')]
    [string] $PreviewOutput = 'Slim',
    [switch] $PreviewOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Azd {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]] $Arguments)

    & azd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd failed with exit code $LASTEXITCODE."
    }
}

function Get-HubFirewallSubnetPrefix {
    param([Parameter(Mandatory)][string] $HubVnetResourceId)

    # Azure Firewall source-NATs DNAT and application-rule traffic to a back-end
    # instance IP in AzureFirewallSubnet, not to its frontend private IP, so the
    # gateway NSG must admit that subnet's range (ADR-002). Returns $null when
    # the hub has no readable AzureFirewallSubnet, for example with an NVA.
    $subnetId = '{0}/subnets/AzureFirewallSubnet' -f $HubVnetResourceId.TrimEnd('/')
    $prefix = & az network vnet subnet show --ids $subnetId --query 'addressPrefix || addressPrefixes[0]' --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$prefix)) {
        return $null
    }

    return ([string]$prefix).Trim()
}

function Read-GatewayConfiguration {
    param([Parameter(Mandatory)][string] $Path)

    # Without a gateway configuration the deployment produces an API Management
    # instance carrying only the stock echo-api: no workload API, no named
    # values and no llm-token-limit (ADR-007). This reads the operator's
    # configuration and hands it to azd as a compact JSON string, because azd
    # cannot substitute an object into a Bicep object parameter.
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "GatewayConfigurationPath '$Path' was not found."
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    try {
        $configuration = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "GatewayConfigurationPath '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    # Drop $-prefixed annotation keys so a documented example file can be copied
    # and filled in directly. main.bicep rebuilds the configuration field by
    # field and would ignore them anyway, but there is no reason to carry
    # commentary into the azd environment.
    $clean = [ordered]@{}
    foreach ($property in $configuration.PSObject.Properties) {
        if ($property.Name.StartsWith('$')) { continue }
        $clean[$property.Name] = $property.Value
    }
    $configuration = [pscustomobject]$clean

    # Validated here rather than left to ARM, because main.bicep rebuilds the
    # gatewayConfiguration field by field: a missing required key surfaces as an
    # opaque evaluation failure inside a nested deployment, minutes in, while an
    # unexpected key is silently dropped.
    $required = @(
        'sku', 'capacity', 'publisherEmail', 'publisherName', 'audience',
        'integrationSubnetName', 'integrationSubnetPrefix',
        'privateDnsZoneResourceId', 'stopNewRequests', 'callerMappings'
    )
    $missing = @($required | Where-Object { -not $configuration.PSObject.Properties[$_] })
    if ($missing.Count -gt 0) {
        throw ("GatewayConfigurationPath '$Path' is missing required field(s): {0}. See environments/gateway-configuration.example.json and the gatewayServiceConfiguration definition in environments/schema.json." -f ($missing -join ', '))
    }

    if ($configuration.sku -notin @('Developer', 'Premium')) {
        throw "GatewayConfigurationPath '$Path' has sku '$($configuration.sku)'. Only Developer and Premium support classic VNet injection."
    }

    $callers = @($configuration.callerMappings)
    if ($callers.Count -lt 1) {
        throw "GatewayConfigurationPath '$Path' must declare at least one callerMappings entry. The gateway is a closed allow-list; a caller with no mapping is refused with 403 gateway_forbidden."
    }

    $callerRequired = @('objectId', 'project', 'models')
    for ($i = 0; $i -lt $callers.Count; $i++) {
        $caller = $callers[$i]
        $callerMissing = @($callerRequired | Where-Object { -not $caller.PSObject.Properties[$_] })
        if ($callerMissing.Count -gt 0) {
            throw ("callerMappings[$i] is missing required field(s): {0}." -f ($callerMissing -join ', '))
        }
        if ([string]$caller.objectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw "callerMappings[$i].objectId '$($caller.objectId)' is not an Entra object ID (GUID). This is the object ID of the service principal or group that calls the gateway, not an application ID URI."
        }
        if (@($caller.models).Count -lt 1) {
            throw "callerMappings[$i].models must name at least one deployed model."
        }
    }

    # $PSScriptRoot is the repository root for this script, where main.parameters.json
    # lives. Guarded because it is empty when the function is dot-sourced outside a
    # script file, and an advisory check must never be the thing that breaks a deploy.
    $parametersPath = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        'main.parameters.json'
    }
    else {
        Join-Path $PSScriptRoot 'main.parameters.json'
    }
    Test-GatewayTokenOversubscription -Configuration $configuration -ParametersPath $parametersPath

    return ConvertTo-Json -InputObject $configuration -Depth 12 -Compress
}

function Test-GatewayTokenOversubscription {
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)][string] $ParametersPath
    )

    # Each llm-token-limit counter is keyed per caller AND per model - the policy
    # builds counter-key as owner|environment|tid|caller-id|project|model - so a
    # caller's tokensPerMinute applies separately to every model it may call. What
    # the callers actually share is the model deployment's own TPM assignment.
    #
    # Compare per model: if the callers permitted on a deployment sum past what
    # that deployment was assigned, the excess is refused by the MODEL, not by the
    # gateway. That matters because a gateway refusal carries Retry-After and a
    # remaining-quota count, whereas a model refusal surfaces as an opaque backend
    # error. Warn rather than fail: the capacity-to-TPM ratio is model-specific and
    # this assumes the published chat-class figure, so a wrong guess must not block
    # a deployment.
    if (-not (Test-Path -LiteralPath $ParametersPath)) { return }
    try {
        $deployments = @((Get-Content -LiteralPath $ParametersPath -Raw | ConvertFrom-Json).parameters.modelDeploymentList.value)
    }
    catch {
        return
    }
    if ($deployments.Count -eq 0) { return }

    $gatewayDefault = if ($Configuration.PSObject.Properties['defaultTokensPerMinute']) {
        [long]$Configuration.defaultTokensPerMinute
    }
    else {
        10000
    }

    foreach ($deployment in $deployments) {
        $capacity = 0L
        if ($deployment.PSObject.Properties['sku'] -and $deployment.sku.PSObject.Properties['capacity']) {
            $capacity = [long]$deployment.sku.capacity
        }
        if ($capacity -le 0) { continue }
        $assignedTpm = $capacity * 1000

        $demand = 0L
        foreach ($caller in @($Configuration.callerMappings)) {
            if (@($caller.models) -notcontains [string]$deployment.name) { continue }
            $demand += if ($caller.PSObject.Properties['tokensPerMinute']) { [long]$caller.tokensPerMinute } else { $gatewayDefault }
        }

        if ($demand -gt $assignedTpm) {
            Write-Warning ("Model deployment '{0}' has capacity {1} (about {2} TPM), but the gateway admits {3} TPM across the callers mapped to it. The model will refuse the excess instead of the gateway, so the caller gets an opaque backend error rather than Retry-After. Lower defaultTokensPerMinute, set per-caller tokensPerMinute, or raise the deployment capacity. Assumes the published 1 unit = 1,000 TPM chat-class ratio, which Microsoft notes varies by model." -f $deployment.name, $capacity, $assignedTpm, $demand)
        }
    }
}

function Assert-ApiManagementIngressSource {
    param([Parameter(Mandatory)][string] $SerializedValue)

    try {
        $ingressPrefixes = @($SerializedValue | ConvertFrom-Json)
    }
    catch {
        throw 'API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES must be a JSON array of hub firewall source CIDRs.'
    }

    # A bare JSON string parses and counts as one element, so the count check
    # alone cannot tell ["10.0.0.0/26"] from "10.0.0.0/26". azd stores the scalar
    # form with broken escaping, which leaves the environment unreadable, and the
    # Bicep array parameter would reject it, so reject the shape here.
    if (-not $SerializedValue.TrimStart().StartsWith('[')) {
        throw 'API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES must be a JSON array of hub firewall source CIDRs.'
    }

    if ($ingressPrefixes.Count -eq 0) {
        throw 'At least one hub firewall source CIDR is required when DeployApiManagement is enabled.'
    }
}

function Get-AzdEnvironmentValues {
    param([Parameter(Mandatory)][string] $EnvironmentName)

    $rawValues = & azd env get-values --environment $EnvironmentName
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read azd environment '$EnvironmentName'."
    }

    $values = @{}
    foreach ($line in $rawValues) {
        if ($line -notmatch '^\s*([A-Z0-9_]+)=(.*)$') {
            continue
        }

        $serializedValue = $matches[2].Trim()
        if ($serializedValue.StartsWith('"') -and $serializedValue.EndsWith('"')) {
            try {
                $values[$matches[1]] = [string]($serializedValue | ConvertFrom-Json)
                continue
            }
            catch {
                throw "Unable to parse azd environment value '$($matches[1])'."
            }
        }

        $values[$matches[1]] = $serializedValue
    }

    return $values
}

function Resolve-AzdParameterValue {
    param(
        $Value,
        [Parameter(Mandatory)][hashtable] $EnvironmentValues
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $tokenPattern = [regex]'\$\{([A-Z0-9_]+)(?:=([^}]*))?\}'
        return $tokenPattern.Replace($Value, {
                param($match)

                $name = $match.Groups[1].Value
                if ($EnvironmentValues.ContainsKey($name)) {
                    return $EnvironmentValues[$name]
                }

                return $match.Groups[2].Value
            })
    }

    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $Value[$index] = Resolve-AzdParameterValue -Value $Value[$index] -EnvironmentValues $EnvironmentValues
        }
        return ,$Value
    }

    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $property.Value = Resolve-AzdParameterValue -Value $property.Value -EnvironmentValues $EnvironmentValues
        }
    }

    return $Value
}

function Get-ResourceDescription {
    param([Parameter(Mandatory)][string] $ResourceId)

    $segments = $ResourceId.Trim('/') -split '/'
    $providerIndex = -1
    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($segments[$index] -ieq 'providers') {
            $providerIndex = $index
        }
    }

    if ($providerIndex -lt 0 -or $providerIndex + 2 -ge $segments.Count) {
        return $ResourceId
    }

    $resourceTypes = [System.Collections.Generic.List[string]]::new()
    $resourceNames = [System.Collections.Generic.List[string]]::new()
    for ($index = $providerIndex + 2; $index -lt $segments.Count; $index += 2) {
        $resourceTypes.Add($segments[$index])
        if ($index + 1 -lt $segments.Count) {
            $resourceNames.Add($segments[$index + 1])
        }
    }

    $resourceType = '{0}/{1}' -f $segments[$providerIndex + 1], ($resourceTypes -join '/')
    $resourceName = $resourceNames -join '/'
    $label = switch ($resourceType) {
        'Microsoft.CognitiveServices/accounts' { ' [Microsoft Foundry account]' }
        'Microsoft.CognitiveServices/accounts/projects' { ' [Microsoft Foundry project]' }
        'Microsoft.CognitiveServices/accounts/deployments' { ' [Microsoft Foundry model deployment]' }
        'Microsoft.ApiManagement/service' { ' [Azure API Management]' }
        default { '' }
    }

    return '{0} : {1}{2}' -f $resourceType, $resourceName, $label
}

function Get-CompiledResourceDeclarations {
    param(
        [Parameter(Mandatory)] $Template,
        [string] $Path = 'main',
        [bool] $AncestorConditional = $false
    )

    $resourcesProperty = $Template.PSObject.Properties['resources']
    if ($null -eq $resourcesProperty) {
        return
    }

    $entries = if ($resourcesProperty.Value -is [pscustomobject]) {
        @($resourcesProperty.Value.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ Key = $_.Name; Resource = $_.Value }
            })
    }
    else {
        $resourceIndex = 0
        @($resourcesProperty.Value | ForEach-Object {
                [pscustomobject]@{ Key = "resource[$resourceIndex]"; Resource = $_ }
                $resourceIndex++
            })
    }

    foreach ($entry in $entries) {
        $typeProperty = $entry.Resource.PSObject.Properties['type']
        if ($null -eq $typeProperty) {
            continue
        }

        $resourceType = [string]$typeProperty.Value
        $resourcePath = '{0}/{1}' -f $Path, $entry.Key
        $conditionProperty = $entry.Resource.PSObject.Properties['condition']
        $isConditional = $AncestorConditional -or $null -ne $conditionProperty

        if ($resourceType -ieq 'Microsoft.Resources/deployments') {
            $propertiesProperty = $entry.Resource.PSObject.Properties['properties']
            $nestedTemplateProperty = if ($null -ne $propertiesProperty) {
                $propertiesProperty.Value.PSObject.Properties['template']
            }
            if ($null -ne $nestedTemplateProperty) {
                Get-CompiledResourceDeclarations `
                    -Template $nestedTemplateProperty.Value `
                    -Path $resourcePath `
                    -AncestorConditional $isConditional
            }
            continue
        }

        [pscustomobject]@{
            Conditional = $isConditional
            Path        = $resourcePath
            Type        = $resourceType
        }
    }
}

function Get-CompiledResourceDescription {
    param([Parameter(Mandatory)] $Declaration)

    $label = switch ([string]$Declaration.Type) {
        'Microsoft.CognitiveServices/accounts' { ' [Microsoft Foundry account]' }
        'Microsoft.CognitiveServices/accounts/projects' { ' [Microsoft Foundry project]' }
        'Microsoft.CognitiveServices/accounts/deployments' { ' [Microsoft Foundry model deployment]' }
        'Microsoft.CognitiveServices/accounts/capabilityHosts' { ' [Microsoft Foundry account capability host]' }
        'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' { ' [Microsoft Foundry project capability host]' }
        'Microsoft.CognitiveServices/accounts/connections' { ' [Microsoft Foundry connection]' }
        'Microsoft.CognitiveServices/accounts/projects/connections' { ' [Microsoft Foundry project connection]' }
        'Microsoft.ApiManagement/service' { ' [Azure API Management]' }
        default { '' }
    }

    return '{0} : {1}{2}' -f $Declaration.Type, $Declaration.Path, $label
}

function Get-WhatIfResourceChanges {
    param([Parameter(Mandatory)] $Node)

    $changes = [System.Collections.Generic.List[object]]::new()
    $visitNode = {
        param($CurrentNode)

        if ($null -eq $CurrentNode -or $CurrentNode -is [string]) {
            return
        }

        if ($CurrentNode -is [System.Collections.IEnumerable] -and $CurrentNode -isnot [pscustomobject]) {
            foreach ($item in $CurrentNode) {
                & $visitNode $item
            }
            return
        }

        $properties = $CurrentNode.PSObject.Properties
        if ($null -ne $properties['resourceId'] -and $null -ne $properties['changeType']) {
            $changes.Add($CurrentNode)
        }

        foreach ($property in $properties) {
            & $visitNode $property.Value
        }
    }

    & $visitNode $Node
    return $changes
}

function Invoke-CompletePreview {
    param([Parameter(Mandatory)][string] $EnvironmentName)

    $environmentValues = Get-AzdEnvironmentValues -EnvironmentName $EnvironmentName
    $resourceGroupName = [string]$environmentValues['AZURE_RESOURCE_GROUP']
    $subscriptionId = [string]$environmentValues['AZURE_SUBSCRIPTION_ID']
    if ([string]::IsNullOrWhiteSpace($resourceGroupName) -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "The azd environment must define AZURE_RESOURCE_GROUP and AZURE_SUBSCRIPTION_ID."
    }

    $parametersPath = Join-Path $PSScriptRoot 'main.parameters.json'
    $templatePath = Join-Path $PSScriptRoot 'main.bicep'
    $parameterDocument = Get-Content -Path $parametersPath -Raw | ConvertFrom-Json
    $parameterDocument = Resolve-AzdParameterValue -Value $parameterDocument -EnvironmentValues $environmentValues
    $temporaryTemplateFile = (New-TemporaryFile).FullName
    & az bicep build --file $templatePath --outfile $temporaryTemplateFile --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep compilation failed with exit code $LASTEXITCODE."
    }

    $compiledTemplate = Get-Content -Path $temporaryTemplateFile -Raw | ConvertFrom-Json
    foreach ($property in @($parameterDocument.parameters.PSObject.Properties)) {
        $compiledParameter = $compiledTemplate.parameters.PSObject.Properties[$property.Name]
        if ($null -eq $compiledParameter) {
            $parameterDocument.parameters.PSObject.Properties.Remove($property.Name)
            continue
        }

        $typeProperty = $compiledParameter.Value.PSObject.Properties['type']
        if ($null -eq $typeProperty) {
            continue
        }

        $parameterType = [string]$typeProperty.Value
        $nullableProperty = $compiledParameter.Value.PSObject.Properties['nullable']
        $parameterValue = $property.Value.value
        if ($parameterValue -isnot [string]) {
            continue
        }

        $primitiveType = $parameterType.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($parameterValue) -and $primitiveType -in @('bool', 'int')) {
            $parameterDocument.parameters.PSObject.Properties.Remove($property.Name)
        }
        elseif ($null -ne $nullableProperty -and $nullableProperty.Value -eq $true -and $parameterValue -eq 'null') {
            $property.Value.value = $null
        }
        elseif ($primitiveType -eq 'bool' -and $parameterValue -match '^(true|false)$') {
            $property.Value.value = [bool]::Parse($parameterValue)
        }
        elseif ($primitiveType -eq 'int' -and $parameterValue -match '^-?\d+$') {
            $property.Value.value = [int64]::Parse($parameterValue, [Globalization.CultureInfo]::InvariantCulture)
        }
        elseif ($primitiveType -eq 'array' -and $parameterValue.TrimStart().StartsWith('[')) {
            $property.Value.value = @($parameterValue | ConvertFrom-Json)
        }
    }
    $temporaryParametersFile = New-TemporaryFile

    try {
        $parameterDocument | ConvertTo-Json -Depth 100 | Set-Content -Path $temporaryParametersFile -Encoding utf8

        Write-Host ''
        Write-Host 'Generating complete ARM What-If resource inventory...'
        $whatIfOutput = & az deployment group what-if `
            --subscription $subscriptionId `
            --resource-group $resourceGroupName `
            --template-file $templatePath `
            --parameters "@$temporaryParametersFile" `
            --result-format FullResourcePayloads `
            --validation-level Template `
            --no-pretty-print `
            --only-show-errors `
            --output json
        if ($LASTEXITCODE -ne 0) {
            throw "Azure What-If failed with exit code $LASTEXITCODE."
        }

        $whatIfResult = ($whatIfOutput -join "`n") | ConvertFrom-Json
        $changes = @(Get-WhatIfResourceChanges -Node $whatIfResult |
            Sort-Object -Property resourceId, changeType -Unique)
        $createCount = @($changes | Where-Object changeType -eq 'Create').Count
        $declarations = @(Get-CompiledResourceDeclarations -Template $compiledTemplate |
            Sort-Object -Property Type, Path)

        Write-Host ''
        Write-Host "ARM What-If resource changes ($($changes.Count) changes; $createCount creates):"
        foreach ($change in $changes) {
            $description = Get-ResourceDescription -ResourceId ([string]$change.resourceId)
            Write-Host ('  {0,-11} {1}' -f ([string]$change.changeType).ToUpperInvariant(), $description)
        }

        Write-Host ''
        Write-Host "Complete compiled nested resource inventory ($($declarations.Count) declarations):"
        Write-Host '  INCLUDED entries are unconditional. CONDITIONAL entries depend on a template or module condition.'
        foreach ($declaration in $declarations) {
            $status = if ($declaration.Conditional) { 'CONDITIONAL' } else { 'INCLUDED' }
            $description = Get-CompiledResourceDescription -Declaration $declaration
            Write-Host ('  {0,-11} {1}' -f $status, $description)
        }
    }
    finally {
        Remove-Item -Path $temporaryParametersFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $temporaryTemplateFile -Force -ErrorAction SilentlyContinue
    }
}

foreach ($command in @('az', 'azd', 'pwsh')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found. Install it and try again."
    }
}

if ([bool]$ExistingApplicationInsightsResourceId -ne [bool]$ExistingApplicationInsightsConnectionString) {
    throw 'ExistingApplicationInsightsResourceId and ExistingApplicationInsightsConnectionString must be supplied together.'
}

$explicitApiManagementIngressSourceAddressPrefixes = @(
    $ApiManagementIngressSourceAddressPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

# With API Management enabled and no explicit ingress sources, the default is
# resolved after sign-in from the hub's AzureFirewallSubnet (ADR-002).
# With API Management disabled the value is left unset rather than defaulted to
# the next hop's /32. The Bicep parameter is inert while deployApiManagement is
# false, azd substitutes the parameter file's [] for an unset variable, and a
# written /32 would persist in the azd environment as a working-looking default
# that Azure Firewall never matches: it source-NATs gateway traffic to a
# back-end instance address in AzureFirewallSubnet, not to its frontend IP
# (ADR-002 live proof, 2026-09-23). Enabling the gateway by any route that does
# not re-resolve the default would then build an unreachable gateway.
$defaultApiManagementIngressSourceAddressPrefixes = if ($explicitApiManagementIngressSourceAddressPrefixes.Count -gt 0) {
    ConvertTo-Json -InputObject $explicitApiManagementIngressSourceAddressPrefixes -Compress
}
else {
    ''
}

# Read and validate before sign-in, so a malformed configuration fails in
# seconds rather than after a preview. An empty string clears any value left in
# the azd environment by an earlier run, which matters because a stale
# configuration would otherwise be silently reused.
$resolvedGatewayConfiguration = if ($PSBoundParameters.ContainsKey('GatewayConfigurationPath') -and
    -not [string]::IsNullOrWhiteSpace($GatewayConfigurationPath)) {
    if (-not $DeployApiManagement) {
        throw 'GatewayConfigurationPath requires -DeployApiManagement. The configuration only has an effect when a gateway is deployed.'
    }
    Read-GatewayConfiguration -Path $GatewayConfigurationPath
}
else {
    ''
}

$settings = [ordered]@{
    AZURE_LOCATION                           = $Location
    DEPLOYMENT_MODE                         = 'ailz-integrated'
    NETWORK_ISOLATION                       = 'true'
    DEPLOY_AZURE_FIREWALL                   = 'false'
    DEPLOY_API_MANAGEMENT                   = $DeployApiManagement.ToString().ToLowerInvariant()
    API_MANAGEMENT_PUBLISHER_EMAIL          = $ApiManagementPublisherEmail
    API_MANAGEMENT_PUBLISHER_NAME           = $ApiManagementPublisherName
    API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES = $defaultApiManagementIngressSourceAddressPrefixes
    API_MANAGEMENT_CONFIGURATION            = $resolvedGatewayConfiguration
    HUB_INTEGRATION_HUB_VNET_RESOURCE_ID    = $HubVnetResourceId
    HUB_INTEGRATION_EGRESS_NEXT_HOP_IP      = $EgressNextHopIp
    HUB_INTEGRATION_EXISTING_ROUTE_TABLE_RESOURCE_ID = ''
    EXISTING_LOG_ANALYTICS_WORKSPACE_RESOURCE_ID = $ExistingLogAnalyticsWorkspaceResourceId
    EXISTING_APPLICATION_INSIGHTS_RESOURCE_ID     = $ExistingApplicationInsightsResourceId
    EXISTING_APPLICATION_INSIGHTS_CONNECTION_STRING = $ExistingApplicationInsightsConnectionString
}

foreach ($name in $AdditionalEnvironmentVariables.Keys) {
    $settings[$name] = [string]$AdditionalEnvironmentVariables[$name]
}

$settings['DEPLOYMENT_MODE'] = 'ailz-integrated'
$settings['NETWORK_ISOLATION'] = 'true'
$settings['DEPLOY_AZURE_FIREWALL'] = 'false'
$settings['USE_EXISTING_VNET'] = 'false'
$settings['DEPLOY_NSGS'] = 'true'

if ([string]$settings.DEPLOY_API_MANAGEMENT -ieq 'true') {
    if ([string]::IsNullOrWhiteSpace([string]$settings.API_MANAGEMENT_PUBLISHER_EMAIL) -or
        [string]$settings.API_MANAGEMENT_PUBLISHER_EMAIL -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw 'ApiManagementPublisherEmail must be a valid email address when DeployApiManagement is enabled.'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$settings.API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES)) {
        Assert-ApiManagementIngressSource -SerializedValue ([string]$settings.API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$settings.HUB_INTEGRATION_EXISTING_ROUTE_TABLE_RESOURCE_ID)) {
        throw 'API Management is supported only with the new spoke route table managed by this deployment. Remove HUB_INTEGRATION_EXISTING_ROUTE_TABLE_RESOURCE_ID.'
    }
}

Push-Location $PSScriptRoot
try {
    & az account show --output none
    if ($LASTEXITCODE -ne 0) {
        & az login
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI sign-in failed with exit code $LASTEXITCODE."
        }
    }

    if ([string]$settings.DEPLOY_API_MANAGEMENT -ieq 'true' -and
        [string]::IsNullOrWhiteSpace([string]$settings.API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES)) {
        $firewallSubnetPrefix = Get-HubFirewallSubnetPrefix -HubVnetResourceId $HubVnetResourceId
        $resolvedIngressPrefixes = if ($firewallSubnetPrefix) {
            Write-Host "API Management ingress source: hub AzureFirewallSubnet $firewallSubnetPrefix."
            @($firewallSubnetPrefix)
        }
        else {
            Write-Warning ("No AzureFirewallSubnet was readable in the hub VNet, so API Management ingress falls back to $EgressNextHopIp/32. " +
                'Azure Firewall source-NATs gateway traffic to a back-end instance IP in AzureFirewallSubnet, not to its frontend IP. ' +
                'If the hub uses Azure Firewall, pass -ApiManagementIngressSourceAddressPrefixes with that subnet range.')
            @("$EgressNextHopIp/32")
        }
        # Assigning the output of an if statement unwraps a single-element array
        # to a scalar, which would serialize as a JSON string rather than a JSON
        # array, so re-wrap before serializing.
        $settings['API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES'] = ConvertTo-Json -InputObject @($resolvedIngressPrefixes) -Compress
        Assert-ApiManagementIngressSource -SerializedValue ([string]$settings.API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES)
    }

    & azd auth login --check-status
    if ($LASTEXITCODE -ne 0) {
        Invoke-Azd -Arguments @('auth', 'login')
    }

    & azd env select $EnvironmentName
    if ($LASTEXITCODE -ne 0) {
        Invoke-Azd -Arguments @('env', 'new', $EnvironmentName, '--location', $Location)
    }

    foreach ($setting in $settings.GetEnumerator()) {
        # Empty values are normally skipped so an unset option does not overwrite
        # something an operator set by hand. These two are written even when
        # empty, because a value left over from a previous run is actively
        # harmful: a stale route table breaks the gateway topology, and a stale
        # gateway configuration would silently redeploy a caller set and token
        # limits the operator did not ask for on this run.
        $alwaysWrite = @('HUB_INTEGRATION_EXISTING_ROUTE_TABLE_RESOURCE_ID', 'API_MANAGEMENT_CONFIGURATION')
        if (-not [string]::IsNullOrWhiteSpace([string]$setting.Value) -or
            $alwaysWrite -contains [string]$setting.Key) {
            Invoke-Azd -Arguments @('env', 'set', [string]$setting.Key, [string]$setting.Value)
        }
    }

    if ($PreviewOutput -eq 'Full') {
        # The full preview calls ARM What-If directly, so the azd preprovision
        # hook does not run before it. Run the same preflight first, so blocking
        # findings such as an unsupported azd or a missing hub-to-spoke peering
        # for API Management surface before the preview is reviewed and approved.
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'scripts' 'Invoke-PreflightChecks.ps1') -AzdEnv $EnvironmentName
        if ($LASTEXITCODE -ne 0) {
            throw "Preflight failed with exit code $LASTEXITCODE. Resolve the FAIL findings above and rerun."
        }
        Invoke-CompletePreview -EnvironmentName $EnvironmentName
    }
    else {
        Invoke-Azd -Arguments @('provision', '--preview')
    }
    if ($PreviewOnly) {
        return
    }

    if ((Read-Host 'Preview complete. Type DEPLOY to continue') -cne 'DEPLOY') {
        Write-Host 'Deployment cancelled.'
        return
    }

    Invoke-Azd -Arguments @('provision')
}
finally {
    Pop-Location
}