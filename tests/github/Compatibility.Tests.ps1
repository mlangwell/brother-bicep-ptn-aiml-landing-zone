#Requires -Version 7.0
[CmdletBinding()]
param([string]$TemplatePath)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$baseline = Get-Content (Join-Path $PSScriptRoot 'fixtures\legacy-contract.json') -Raw | ConvertFrom-Json -AsHashtable
$temporaryTemplate = $null
$assertions = 0

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function ConvertTo-SortedValue {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-SortedValue $Value[$key]
        }
        return $result
    }
    if ($Value -is [array]) {
        return ,@($Value | ForEach-Object { ConvertTo-SortedValue $_ })
    }
    return $Value
}

function Get-ComparableJson {
    param($Value)
    ConvertTo-Json -InputObject (ConvertTo-SortedValue $Value) -Depth 100 -Compress
}

try {
    if (-not $TemplatePath) {
        $temporaryTemplate = Join-Path ([IO.Path]::GetTempPath()) "ailz-compatibility-$([guid]::NewGuid().ToString('N')).json"
        & az bicep build --file (Join-Path $root 'main.bicep') --outfile $temporaryTemplate --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Compatibility Bicep compilation failed.' }
        $TemplatePath = $temporaryTemplate
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
    $parameterFile = Get-Content (Join-Path $root 'main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable

    foreach ($name in $baseline.parameters.Keys) {
        Assert-Contract ($template.parameters.Contains($name)) "Removed legacy parameter: $name"
        $actual = $template.parameters[$name]
        $expected = $baseline.parameters[$name]
        Assert-Contract ($actual.type -ceq $expected.type) "Changed legacy parameter type: $name"
        Assert-Contract ($actual.Contains('defaultValue') -eq $expected.Contains('defaultValue')) "Changed required/default contract: $name"
        if ($expected.Contains('defaultValue')) {
            Assert-Contract ((Get-ComparableJson $actual.defaultValue) -ceq (Get-ComparableJson $expected.defaultValue)) "Changed legacy default: $name"
        }
    }
    foreach ($name in $baseline.parameterFile.Keys) {
        Assert-Contract ((Get-ComparableJson $parameterFile.parameters[$name]) -ceq (Get-ComparableJson $baseline.parameterFile[$name])) "Changed legacy azd binding: $name"
    }
    foreach ($name in $baseline.outputs.Keys) {
        Assert-Contract ($template.outputs[$name].type -ceq $baseline.outputs[$name]) "Changed or removed legacy output: $name"
    }
    foreach ($relativePath in $baseline.preservedFiles.Keys) {
        $text = [IO.File]::ReadAllText((Join-Path $root $relativePath)).Replace("`r`n", "`n")
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
        Assert-Contract ($hash -ceq $baseline.preservedFiles[$relativePath]) "Changed preserved deployment entry point or Azure DevOps asset: $relativePath"
    }

    foreach ($flag in @('deployApiManagement', 'enableDeveloperExperience')) {
        Assert-Contract ($template.parameters.Contains($flag)) "Missing additive flag: $flag"
        Assert-Contract ($template.parameters[$flag].defaultValue -eq $false) "Feature must default off: $flag"
    }
    foreach ($configuration in @('apiManagementConfiguration', 'developerExperience')) {
        Assert-Contract ($template.parameters.Contains($configuration)) "Missing additive configuration: $configuration"
        Assert-Contract ((Get-ComparableJson $template.parameters[$configuration].defaultValue) -ceq '{}') "Nonempty default configuration: $configuration"
    }
    $foundryPe = Get-ComparableJson $template.resources.aiFoundry.properties.parameters.privateEndpointSubnetResourceId
    Assert-Contract ($foundryPe -match "parameters\('peSubnetName'\)" -and $foundryPe -notmatch '/subnets/pe-subnet') 'Foundry private endpoints must honor the configured PE subnet name.'
    # The gateway is created only when this landing zone owns it, and only in a
    # supported topology (ADR-002). That is a strict narrowing of the original
    # default-off flag: _createApiManagement is and(deployApiManagement,
    # not(_hasExistingApiManagement), _apiManagementTopologySupported), so it
    # can never be true while deployApiManagement is false.
    Assert-Contract ($template.resources.apiManagement.condition -ceq "[variables('_createApiManagement')]") 'The gateway resource must be gated by the default-off flag.'
    Assert-Contract ($template.variables._createApiManagement -ceq "[and(and(parameters('deployApiManagement'), not(variables('_hasExistingApiManagement'))), variables('_apiManagementTopologySupported'))]") 'Gateway creation must remain default-off, suppressed when an existing gateway is supplied, and limited to a supported topology.'
    Assert-Contract ($template.parameters.existingApiManagementResourceId.ContainsKey('nullable') -or $template.parameters.existingApiManagementResourceId.type -ceq 'string') 'Consuming a shared gateway must be an additive, optional parameter.'
    Assert-Contract ($template.resources.apiManagementNsg.condition -match "variables\('_createApiManagement'\)") 'The gateway NSG must also be default-off.'
    Assert-Contract ($template.resources.appConfig.properties.disableLocalAuth -ceq "[parameters('enableDeveloperExperience')]") 'App Configuration authentication must change only in the opt-in developer profile.'
    $mainSource = [IO.File]::ReadAllText((Join-Path $root 'main.bicep')).Replace("`r`n", "`n")
    $baseSubnets = [regex]::Match($mainSource, '(?ms)^var baseSubnets = \[.*?^\]').Value
    $baseSubnetsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($baseSubnets))).ToLowerInvariant()
    Assert-Contract ($baseSubnetsHash -ceq 'de33257d8033728a048e24b8a6b78cd94fbea05088cf15481923a3a7fe3095d7') 'Legacy base subnet definitions changed rather than adding a separately gated subnet.'
    $cosmosSettings = Get-ComparableJson $template.resources.cosmosConfigKeyVaultPopulate.properties.parameters.keyValues
    Assert-Contract ($cosmosSettings.Contains('COSMOS_DB_ACCOUNT_RESOURCE_ID') -and $cosmosSettings.Contains('COSMOS_DB_ENDPOINT')) 'Shared private completion removed legacy Cosmos runtime identifiers.'

    $resources = @($template.resources.Values)
    if ($template.resources -is [array]) { $resources = $template.resources }
    $apps = @($resources | Where-Object { $_.copy.name -eq 'containerApps' })[0]
    Assert-Contract ($null -ne $apps) 'Container App deployment loop was removed.'
    $image = $apps.properties.parameters.containers.value[0].image
    Assert-Contract ($image -match "containerAppsList.*image") 'Provisioning must use the selected application image on first and subsequent deployments.'
    Assert-Contract ($image -match '_containerDummyImageName') 'Legacy consumers must retain the placeholder fallback.'
    Assert-Contract ($apps.properties.parameters.ingressTargetPort.value -match 'target_port.*8080') 'The existing target_port fallback changed.'
    Assert-Contract ((Get-ComparableJson $apps.properties.parameters.registries) -match 'registry') 'The image must retain its managed-identity registry configuration during provision.'
    Assert-Contract ($apps.properties.parameters.managedIdentities.value.userAssignedResourceIds -match 'managedIdentity') 'The pre-created workload identity must be bound before private image pull.'

    $populate = @($resources | Where-Object { $_.name -eq 'appConfigPopulate' })[0]
    $settingsExpression = $populate.properties.parameters.keyValues.value.TrimStart('[').TrimEnd(']')
    $completionExpression = [string]$template.outputs.DEVELOPER_COMPLETION.value
    Assert-Contract ($settingsExpression -and $completionExpression.Contains($settingsExpression, [StringComparison]::Ordinal)) 'Standard and private completion must reuse one App Configuration shaping expression.'
    Assert-Contract ($completionExpression.Contains("'sourceProperty'") -and $completionExpression.Contains("'sourceResourceId'")) 'Missing secret-free private configuration projection.'
    Assert-Contract ($template.outputs.DEVELOPER_COMPLETION.value -match 'enableDeveloperExperience') 'Completion output must remain opt-in.'
    Assert-Contract ($template.outputs.INFERENCE_GATEWAY_ENDPOINT.value -match 'deployApiManagement') 'Gateway output must have a disabled-feature fallback.'
    Import-Module (Join-Path $root 'scripts\github\Environment.psm1')
    $synthetic = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
    $resolved = Resolve-EnvironmentProfile -Profile $synthetic -AllowSynthetic
    foreach ($name in $template.parameters.Keys) {
        $definition = $template.parameters[$name]
        if (-not $definition.Contains('defaultValue') -and $definition['nullable'] -ne $true) {
            Assert-Contract ($resolved.parameters.parameters.Contains($name)) "Resolver omitted required compiled parameter: $name"
        }
    }
    foreach ($name in $resolved.parameters.parameters.Keys) {
        Assert-Contract ($template.parameters.Contains($name)) "Resolver emits an unknown compiled parameter: $name"
        $value = $resolved.parameters.parameters[$name].value
        $definition = $template.parameters[$name]
        if ($definition.Contains('$ref')) { $definition = $template.definitions[$definition['$ref'].Split('/')[-1]] }
        $valid = switch ($definition.type) {
            'bool' { $value -is [bool] }
            'array' { $value -is [array] }
            'object' { $value -is [Collections.IDictionary] }
            'string' { $value -is [string] }
            'securestring' { $value -is [string] }
            'int' { $value -is [int] -or $value -is [long] }
            default { throw "Unrecognized compiled parameter type for $name." }
        }
        Assert-Contract $valid "Resolver does not preserve the compiled type of $name."
    }
    Write-Host "Compatibility: $assertions assertions passed."
}
finally {
    if ($temporaryTemplate -and (Test-Path -LiteralPath $temporaryTemplate)) {
        Remove-Item -LiteralPath $temporaryTemplate
    }
}
