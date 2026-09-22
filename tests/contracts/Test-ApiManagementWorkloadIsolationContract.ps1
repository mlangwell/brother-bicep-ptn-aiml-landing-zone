<#
.SYNOPSIS
    Proves API Management per-workload resources are keyed per landing zone.

.DESCRIPTION
    API Management is per-subscription platform infrastructure: one gateway is
    shared by many landing zones. Every resource the landing zone owns inside
    that gateway must therefore be keyed by a landing-zone-scoped value.

    Before this contract, the module derived `owner` from `environmentName`
    alone and used the fixed literal `inference` as the API path. Two landing
    zones in the same subscription and environment collided on the API name,
    the backend, the named values and the public route.

    The test proves, structurally against compiled ARM and functionally against
    the real exported policy functions, that:
      - the owner marker and API path are derived from `workloadKey`;
      - the API, backend, logger and named values all inherit that key;
      - the published inference route is workload-scoped, not `/inference/...`;
      - two distinct workload keys produce fully disjoint resource names; and
      - the parent default key is NOT derived from subscription + environment +
        location, because that hash is identical for two landing zones in the
        same subscription, environment and region.
#>

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleFile = Join-Path $RepositoryRoot 'modules\api-management\main.bicep'
$workloadFile = Join-Path $RepositoryRoot 'modules\api-management\workload.bicep'
$policyFile = Join-Path $RepositoryRoot 'modules\api-management\policy.bicep'
$mainFile = Join-Path $RepositoryRoot 'main.bicep'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "apim-workload-isolation-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)] [string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if ($Condition) { Write-Host "  [PASS] $Message" -ForegroundColor Green }
    else { Add-Failure $Message }
}

function New-GatewayConfiguration {
    param([Parameter(Mandatory)] [string]$Audience)

    $zoneScope = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg-contract-never-deploy'
    return [ordered]@{
        enabled                  = $true
        sku                      = 'Developer'
        capacity                 = 1
        publisherEmail           = 'contract-owner@example.invalid'
        publisherName            = 'CONTRACT OFFLINE TEST OWNER'
        audience                 = $Audience
        integrationSubnetName    = 'contract-apim-integration'
        integrationSubnetPrefix  = '10.220.4.0/27'
        # Service-scoped zone: classic VNet injection has no private endpoint,
        # so privatelink.azure-api.net does not apply.
        privateDnsZoneResourceId = "$zoneScope/providers/Microsoft.Network/privateDnsZones/contract-gateway.azure-api.net"
        stopNewRequests          = $false
        callerMappings           = @(
            [ordered]@{
                objectId         = '00000000-0000-4000-8000-000000000042'
                project          = 'contract-project'
                models           = @('contract-chat')
                tokensPerMinute  = 1000
                tokenQuota       = 10000
                tokenQuotaPeriod = 'Daily'
            }
        )
    }
}

Write-Host 'API Management workload-isolation contract' -ForegroundColor Cyan

[System.IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    # ---------------------------------------------------------------------
    # Structural: the compiled workload module must thread workloadKey into
    # every per-workload resource name and into the published route.
    # ---------------------------------------------------------------------
    $compiledWorkload = Join-Path $scratch 'api-management-workload.json'
    az bicep build --file $workloadFile --outfile $compiledWorkload | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation of the API Management workload module failed with exit code $LASTEXITCODE." }

    $template = Get-Content -LiteralPath $compiledWorkload -Raw | ConvertFrom-Json -Depth 100
    $owner = [string]$template.variables.owner
    $apiPath = [string]$template.variables.apiPath

    Assert-True `
        -Condition ($owner.Contains("parameters('workloadKey')")) `
        -Message 'The owner marker is derived from workloadKey'

    Assert-True `
        -Condition ($apiPath.Contains("parameters('workloadKey')")) `
        -Message 'The API path is derived from workloadKey'

    Assert-True `
        -Condition ([string]$template.resources.api.properties.path -eq "[variables('apiPath')]") `
        -Message 'The API resource uses the workload-scoped path, not a fixed literal'

    foreach ($resource in @(
            @{ Key = 'api'; Label = 'API' },
            @{ Key = 'backend'; Label = 'backend' },
            @{ Key = 'logger'; Label = 'logger' },
            @{ Key = 'namedValues'; Label = 'named values' }
        )) {
        $name = [string]$template.resources.($resource.Key).name
        Assert-True `
            -Condition ($name.Contains("variables('owner')")) `
            -Message "The $($resource.Label) resource name inherits the workload-scoped owner"
    }

    $endpoint = [string]$template.outputs.inferenceEndpoint.value
    Assert-True `
        -Condition ($endpoint.Contains("variables('apiPath')")) `
        -Message 'The published inference route is workload-scoped'

    Assert-True `
        -Condition (-not $endpoint.Contains('/inference/v1/responses')) `
        -Message 'The published inference route is not the unscoped, collision-prone path'

    $policyXml = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'modules\api-management\responses-policy.xml') -Raw
    Assert-True `
        -Condition ($policyXml.Contains('/__API_PATH__/v1/responses') -and -not $policyXml.Contains('&quot;/inference/v1/responses&quot;')) `
        -Message 'The policy pins the request to the workload-scoped route token, not a fixed literal'

    # ---------------------------------------------------------------------
    # Cross-resource-group: a shared gateway lives in the platform resource
    # group, so the workload children must be deployed at ITS scope. The old
    # current-resource-group `existing` lookup silently resolved nothing.
    # ---------------------------------------------------------------------
    $workloadSource = Get-Content -LiteralPath $workloadFile -Raw
    Assert-True `
        -Condition (-not $workloadSource.Contains('../security/resource-role-assignment.bicep')) `
        -Message 'The gateway-scoped module assigns no roles; landing zone resources are granted at the landing zone scope'

    $compiledMain = Join-Path $scratch 'main.json'
    az bicep build --file $mainFile --outfile $compiledMain | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation of main.bicep failed with exit code $LASTEXITCODE." }

    $mainTemplate = Get-Content -LiteralPath $compiledMain -Raw | ConvertFrom-Json -Depth 100
    $byoWorkload = $mainTemplate.resources.apiManagementWorkload
    Assert-True `
        -Condition ($null -ne $byoWorkload) `
        -Message 'main.bicep deploys the workload children against an existing shared gateway'

    if ($null -ne $byoWorkload) {
        Assert-True `
            -Condition ([string]$byoWorkload.subscriptionId -match "_apimSubscriptionId" -and
                [string]$byoWorkload.resourceGroup -match "_apimResourceGroupName") `
            -Message 'Workload children target the gateway subscription and resource group, not the landing zone resource group'

        Assert-True `
            -Condition ([string]$byoWorkload.condition -match '_hasExistingApiManagement') `
            -Message 'The cross-resource-group workload deployment is gated on the BYO gateway'
    }

    # On the BYO path the delegated integration subnet and its NSG belong to the
    # platform VNet, so the landing zone must not carve them out of its spoke.
    $integrationNsg = $mainTemplate.resources.apiManagementNsg
    Assert-True `
        -Condition ($null -ne $integrationNsg -and [string]$integrationNsg.condition -match '_createApiManagement') `
        -Message 'The integration NSG is created only when this landing zone owns the gateway'

    # Bicep inlines the `subnets` variable into the VNet module parameters, so
    # assert against the materialized parameter rather than a named variable.
    $subnetConsumers = @(
        foreach ($key in @('virtualNetwork', 'virtualNetworkSubnets')) {
            $resource = $mainTemplate.resources.$key
            if ($null -ne $resource -and $null -ne $resource.properties.parameters.subnets) {
                [string]($resource.properties.parameters.subnets | ConvertTo-Json -Depth 30 -Compress)
            }
        }
    )
    Assert-True `
        -Condition ($subnetConsumers.Count -gt 0) `
        -Message 'The compiled template still materializes a subnet list'

    $gatedSubnetConsumers = @($subnetConsumers | Where-Object { $_ -match '_createApiManagement' })
    Assert-True `
        -Condition ($gatedSubnetConsumers.Count -eq $subnetConsumers.Count) `
        -Message 'The delegated integration subnet is added only when this landing zone owns the gateway'

    Assert-True `
        -Condition (@($subnetConsumers | Where-Object { $_ -match 'deployApiManagement''\)\), createArray\(createObject\(''name''' }).Count -eq 0) `
        -Message 'The integration subnet is no longer gated on deployApiManagement alone, which would also fire on the BYO path'

    # ---------------------------------------------------------------------
    # Functional: two distinct landing-zone identities must produce fully
    # disjoint concrete names and distinct routes from the REAL exported
    # functions, not from a re-implementation of them.
    # ---------------------------------------------------------------------
    $firstKey = 'lzalpha001'
    $secondKey = 'lzbravo002'
    $tenantId = '00000000-0000-4000-8000-000000000009'
    $backendEndpoint = 'https://contract-foundry.openai.azure.com/'

    New-GatewayConfiguration -Audience 'api://contract-alpha' |
        ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath (Join-Path $scratch 'gateway.json')

    $relativePolicy = [System.IO.Path]::GetRelativePath($scratch, $policyFile).Replace('\', '/')
    $parametersFile = Join-Path $scratch 'collision.bicepparam'
    @"
using none
import { renderPolicy, gatewayNamedValues } from '$relativePolicy'
var configuration = loadJsonContent('./gateway.json')
param firstNamedValues = gatewayNamedValues('ailz-inference-dev-$firstKey', 'dev', '$tenantId', configuration, '$backendEndpoint', false)
param secondNamedValues = gatewayNamedValues('ailz-inference-dev-$secondKey', 'dev', '$tenantId', configuration, '$backendEndpoint', false)
param firstPolicy = renderPolicy('ailz-inference-dev-$firstKey', 'inference/$firstKey', configuration.callerMappings)
param secondPolicy = renderPolicy('ailz-inference-dev-$secondKey', 'inference/$secondKey', configuration.callerMappings)
"@ | Set-Content -LiteralPath $parametersFile

    $renderedFile = Join-Path $scratch 'collision.parameters.json'
    az bicep build-params --file $parametersFile --outfile $renderedFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bicep build-params for the collision fixture failed with exit code $LASTEXITCODE." }

    $rendered = Get-Content -LiteralPath $renderedFile -Raw | ConvertFrom-Json -Depth 100
    $firstNames = @($rendered.parameters.firstNamedValues.value | ForEach-Object { [string]$_.name })
    $secondNames = @($rendered.parameters.secondNamedValues.value | ForEach-Object { [string]$_.name })

    Assert-True `
        -Condition ($firstNames.Count -eq 4 -and $secondNames.Count -eq 4) `
        -Message 'Both landing zones render the full named-value set'

    $shared = @($firstNames | Where-Object { $secondNames -ccontains $_ })
    Assert-True `
        -Condition ($shared.Count -eq 0) `
        -Message 'Two landing zones on one gateway share no named-value name'

    Assert-True `
        -Condition (@($firstNames | Where-Object { $_.Contains($firstKey) }).Count -eq 4) `
        -Message 'Every named value carries its own landing-zone key'

    $firstTags = @($rendered.parameters.firstNamedValues.value | ForEach-Object { [string]$_.tags[0] })
    $secondTags = @($rendered.parameters.secondNamedValues.value | ForEach-Object { [string]$_.tags[0] })
    Assert-True `
        -Condition (@($firstTags | Where-Object { $secondTags -ccontains $_ }).Count -eq 0) `
        -Message 'Ownership tags do not overlap between landing zones'

    $firstPolicyText = [string]$rendered.parameters.firstPolicy.value
    $secondPolicyText = [string]$rendered.parameters.secondPolicy.value
    Assert-True `
        -Condition ($firstPolicyText.Contains("/inference/$firstKey/v1/responses") -and
            $secondPolicyText.Contains("/inference/$secondKey/v1/responses")) `
        -Message 'Each rendered policy pins its own workload-scoped route'

    Assert-True `
        -Condition (-not $firstPolicyText.Contains("/inference/$secondKey/v1/responses") -and
            -not $secondPolicyText.Contains("/inference/$firstKey/v1/responses")) `
        -Message "A landing zone's policy rejects its neighbour's route on the shared gateway"

    Assert-True `
        -Condition ($firstPolicyText.Contains("backend-id=`"ailz-inference-dev-$firstKey-foundry`"") -and
            $secondPolicyText.Contains("backend-id=`"ailz-inference-dev-$secondKey-foundry`"")) `
        -Message 'Each policy routes to its own backend, never a shared one'

    Assert-True `
        -Condition (-not $firstPolicyText.Contains('__') -and -not $secondPolicyText.Contains('__')) `
        -Message 'No policy placeholder is left unresolved'

    # ---------------------------------------------------------------------
    # The parent default must not reintroduce the collision. resourceToken and
    # the CAF workload token both hash subscription + environment + location,
    # which is identical for two landing zones in the same subscription,
    # environment and region.
    # ---------------------------------------------------------------------
    $mainSource = Get-Content -LiteralPath $mainFile -Raw
    $keyDefault = [regex]::Match($mainSource, '(?m)^param apiManagementWorkloadKey string = (?<value>.+?)\r?$')
    Assert-True `
        -Condition $keyDefault.Success `
        -Message 'main.bicep declares the apiManagementWorkloadKey parameter'

    if ($keyDefault.Success) {
        $defaultExpression = $keyDefault.Groups['value'].Value
        Assert-True `
            -Condition ($defaultExpression.Contains('resourceGroup().id')) `
            -Message 'The default workload key is derived from the resource group, which is unique per landing zone'

        Assert-True `
            -Condition (-not $defaultExpression.Contains('resourceToken') -and
                -not $defaultExpression.Contains('subscription().id')) `
            -Message 'The default workload key is not derived from subscription + environment + location'
    }

    Assert-True `
        -Condition ($mainSource.Contains('workloadKey: apiManagementWorkloadKey')) `
        -Message 'The parent forwards the workload key to the API Management module'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`nAPI Management workload-isolation contract failed with $($failures.Count) error(s)." -ForegroundColor Red
    exit 1
}

Write-Host "`nAPI Management workload-isolation contract checks passed." -ForegroundColor Green
