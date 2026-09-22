<#
.SYNOPSIS
    Proves the API Management gateway uses classic VNet injection in Internal
    mode, on both the landing-zone-created and platform-owned paths.

.DESCRIPTION
    This landing zone runs API Management on the classic Developer and Premium
    tiers, injected into a virtual network in Internal mode. That topology is
    not a stylistic preference: it is the only shape that is simultaneously
    private on the inbound side AND able to reach a private-endpoint-only
    Foundry account on the outbound side.

    Three Microsoft Learn facts make the invariants below load-bearing, and each
    one is a defect that compiles cleanly if it regresses:

      1. Injected classic instances cannot hold a private endpoint.
         "In the classic API Management tiers, private endpoints aren't
          supported in instances injected in an internal or external virtual
          network."

      2. Therefore publicNetworkAccess can never be Disabled here.
         "You can disable public network access in API Management instances
          configured with a private endpoint, not with other networking
          configurations."
         Inbound privacy comes from Internal mode instead: "None of the API
         Management endpoints are registered on the public DNS."

      3. The injection subnet must NOT be delegated, and its NSG must carry
         explicit rules, because "the load balancer used internally by API
         Management is secure by default and rejects all inbound traffic."

    A regression to the previous Standard v2 shape - a serverFarms-delegated
    subnet, an inbound private endpoint, External mode, or a rule-less NSG -
    would deploy without error and then fail at runtime, or worse, silently
    publish the gateway to the internet. Hence this contract.

.NOTES
    Offline and read-only. Compiles Bicep; never contacts Azure.
#>

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleFile = Join-Path $RepositoryRoot 'modules\api-management\main.bicep'
$nsgFile = Join-Path $RepositoryRoot 'modules\networking\api-management-injection-nsg.bicep'
$platformFile = Join-Path $RepositoryRoot 'platform\api-management\main.bicep'
$platformNetworkFile = Join-Path $RepositoryRoot 'platform\api-management\network.bicep'
$mainFile = Join-Path $RepositoryRoot 'main.bicep'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "apim-classic-injection-$([guid]::NewGuid().ToString('N'))"
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

function Build-Template {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$OutFile
    )

    az bicep build --file $Path --outfile $OutFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation of $Path failed with exit code $LASTEXITCODE." }
    return (Get-Content -LiteralPath $OutFile -Raw)
}

Write-Host 'API Management classic VNet-injection contract' -ForegroundColor Cyan

[System.IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $moduleSource = Get-Content -LiteralPath $moduleFile -Raw
    $mainSource = Get-Content -LiteralPath $mainFile -Raw
    $nsgSource = Get-Content -LiteralPath $nsgFile -Raw
    $platformSource = Get-Content -LiteralPath $platformFile -Raw
    $platformNetworkSource = Get-Content -LiteralPath $platformNetworkFile -Raw

    # ---------------------------------------------------------------------
    # Internal mode on BOTH gateway creation paths.
    # ---------------------------------------------------------------------
    foreach ($path in @(
        @{ name = 'landing-zone-created gateway'; source = $moduleSource },
        @{ name = 'platform-owned gateway'; source = $platformSource }
    )) {
        Assert-True `
            -Condition ($path.source -match "virtualNetworkType:\s*'Internal'") `
            -Message "The $($path.name) is injected in Internal mode"

        Assert-True `
            -Condition ($path.source -notmatch "virtualNetworkType:\s*'External'") `
            -Message "The $($path.name) never selects External mode, which would publish the data plane to the internet"

        # AVM's availabilityZones default is [1,2,3] - MANUAL zone selection,
        # which requires capacity to be an exact multiple of the zone count and
        # therefore fails on a single-unit Premium gateway.
        Assert-True `
            -Condition ($path.source -match 'availabilityZones:\s*(\[\]|effectiveAvailabilityZones)') `
            -Message "The $($path.name) passes availabilityZones explicitly rather than inheriting the AVM manual default"
    }

    # ---------------------------------------------------------------------
    # No private endpoint, and no attempt to disable public network access.
    # ---------------------------------------------------------------------
    Assert-True `
        -Condition ($moduleSource -match 'privateEndpoints:\s*\[\]' -and $platformSource -match 'privateEndpoints:\s*\[\]') `
        -Message 'Neither gateway path declares a private endpoint, which injection does not support'

    Assert-True `
        -Condition ($moduleSource -match "publicNetworkAccess:\s*'Enabled'" -and $platformSource -match "publicNetworkAccess:\s*'Enabled'") `
        -Message 'Both gateway paths use the only publicNetworkAccess value Azure permits on an injected instance'

    Assert-True `
        -Condition ($moduleSource -notmatch "publicNetworkAccess:\s*initialProvisioning" -and
            $platformSource -notmatch "publicNetworkAccess:\s*initialProvisioning") `
        -Message 'Neither path drives publicNetworkAccess from initialProvisioning; Disabled is unreachable without a private endpoint'

    Assert-True `
        -Condition ($moduleSource -notmatch 'privateEndpointSubnetResourceId' -and $platformSource -notmatch 'privateEndpointSubnetResourceId') `
        -Message 'Neither path still carries a private endpoint subnet parameter'

    # ---------------------------------------------------------------------
    # Structural: the compiled templates must emit no private endpoint at all
    # on the gateway path, and must carry Internal mode into the ARM body.
    # ---------------------------------------------------------------------
    foreach ($target in @(
        @{ name = 'landing-zone gateway module'; file = $moduleFile; out = 'api-management.json' },
        @{ name = 'platform gateway template'; file = $platformFile; out = 'platform-api-management.json' }
    )) {
        $raw = Build-Template -Path $target.file -OutFile (Join-Path $scratch $target.out)

        Assert-True `
            -Condition ($raw -match 'Microsoft\.ApiManagement/service') `
            -Message "The compiled $($target.name) emits an API Management service resource"

        Assert-True `
            -Condition ($raw -match '(?s)"virtualNetworkType":\s*\{\s*"value":\s*"Internal"') `
            -Message "The compiled $($target.name) passes Internal as the virtual network type to the gateway resource"

        Assert-True `
            -Condition ($raw -notmatch '(?s)"virtualNetworkType":\s*\{\s*"value":\s*"External"') `
            -Message "The compiled $($target.name) never passes External, which would publish the data plane"

        # The AVM module accepts a privateEndpoints parameter, so its own nested
        # template legitimately contains private endpoint machinery. What must
        # never appear is this repository PASSING a non-empty value for it.
        Assert-True `
            -Condition ($raw -notmatch '"privateEndpoints":\s*\[\s*\{') `
            -Message "The compiled $($target.name) passes no private endpoint definition"

        Assert-True `
            -Condition ($raw -notmatch '"publicNetworkAccess":\s*"Disabled"') `
            -Message "The compiled $($target.name) never requests Disabled public network access, which injection cannot satisfy"
    }

    # ---------------------------------------------------------------------
    # The injection subnet must not be delegated, on either path.
    # ---------------------------------------------------------------------
    Assert-True `
        -Condition ($mainSource -notmatch "delegation:\s*'Microsoft\.Web/serverFarms'") `
        -Message 'The landing zone no longer delegates the injection subnet to Microsoft.Web/serverFarms'

    Assert-True `
        -Condition ($platformNetworkSource -match 'delegations:\s*\[\]') `
        -Message 'The platform injection subnet declares no delegations'

    # ---------------------------------------------------------------------
    # The NSG must carry the required rules; a rule-less NSG blocks everything.
    # ---------------------------------------------------------------------
    Assert-True `
        -Condition ($mainSource -match 'modules/networking/api-management-injection-nsg\.bicep') `
        -Message 'The landing zone uses the rule-carrying injection NSG, not the empty shared NSG helper'

    Assert-True `
        -Condition ($platformNetworkSource -match 'api-management-injection-nsg\.bicep') `
        -Message 'The platform path shares the same authoritative NSG rule set, so the two paths cannot drift'

    foreach ($required in @(
        @{ tag = 'ApiManagement'; port = '3443'; why = 'control-plane management endpoint' },
        @{ tag = 'AzureLoadBalancer'; port = '6390'; why = 'infrastructure load balancer health probe' }
    )) {
        Assert-True `
            -Condition ($nsgSource -match [regex]::Escape($required.tag) -and $nsgSource -match "destinationPortRange:\s*'$($required.port)'") `
            -Message "The injection NSG allows inbound $($required.tag) on $($required.port) ($($required.why))"
    }

    foreach ($tag in @('Storage', 'Sql', 'AzureKeyVault', 'AzureMonitor', 'AzureActiveDirectory')) {
        Assert-True `
            -Condition ($nsgSource -match "destinationAddressPrefix:\s*'$tag'") `
            -Message "The injection NSG allows the required outbound dependency on $tag"
    }

    # Internet:80,443 INBOUND is external-mode only. Allowing it would defeat the
    # entire point of Internal mode. Outbound Internet:80 for CRL/OCSP is
    # required and legitimate, so the assertion is direction-specific.
    $inboundInternet = [regex]::Matches(
        $nsgSource,
        "sourceAddressPrefix:\s*'Internet'"
    )
    Assert-True `
        -Condition ($inboundInternet.Count -eq 0) `
        -Message 'The injection NSG allows no inbound from Internet; that rule is external-mode only and would expose the data plane'

    Assert-True `
        -Condition ($nsgSource -notmatch "sourceAddressPrefix:\s*'AzureTrafficManager'") `
        -Message 'The injection NSG carries no AzureTrafficManager rule, which applies only to external multi-region deployments'

    # ---------------------------------------------------------------------
    # DNS: service-scoped zone only. An apex azure-api.net private zone is
    # explicitly unsupported by Learn and breaks unrelated Azure services.
    # ---------------------------------------------------------------------
    Assert-True `
        -Condition ($platformSource -notmatch '(?m)^param\s+privateDnsZoneResourceId') `
        -Message 'The platform gateway template no longer takes a privatelink DNS zone it cannot use'

    $schemaPath = Join-Path $RepositoryRoot 'environments\schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -Depth 100
    $gatewayDns = $schema.definitions.gatewayPrivateDnsId
    Assert-True `
        -Condition ($null -ne $gatewayDns) `
        -Message 'The profile schema defines a gateway-specific private DNS zone contract'

    if ($null -ne $gatewayDns) {
        $allOf = @($gatewayDns.allOf)
        $patterns = [System.Collections.Generic.List[string]]::new()
        $notPatterns = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $allOf) {
            $names = $entry.PSObject.Properties.Name
            if ($names -contains 'pattern') { $patterns.Add([string]$entry.pattern) }
            if ($names -contains 'not') { $notPatterns.Add([string]$entry.not.pattern) }
        }
        Assert-True `
            -Condition (($patterns -join ' ') -match 'azure-api') `
            -Message 'The gateway DNS contract requires an azure-api.net zone'

        Assert-True `
            -Condition (($notPatterns -join ' ') -match 'privatelink') `
            -Message 'The gateway DNS contract explicitly rejects a privatelink.azure-api.net zone'
    }

    # ---------------------------------------------------------------------
    # Tier contract: classic tiers only.
    # ---------------------------------------------------------------------
    $typesSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'modules\api-management\types.bicep') -Raw
    Assert-True `
        -Condition ($typesSource -match "sku:\s*'Developer'\s*\|\s*'Premium'") `
        -Message 'The gateway type accepts only the classic injection tiers'

    Assert-True `
        -Condition ($typesSource -notmatch 'StandardV2' -and $typesSource -notmatch 'PremiumV2') `
        -Message 'The gateway type no longer accepts the v2 tiers, which cannot use this topology'

    Assert-True `
        -Condition ($platformSource -match "sku 'Developer' \| 'Premium'") `
        -Message 'The platform gateway template accepts only the classic injection tiers'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`nAPI Management classic VNet-injection contract failed with $($failures.Count) error(s)." -ForegroundColor Red
    exit 1
}

Write-Host "`nAPI Management classic VNet-injection contract checks passed." -ForegroundColor Green
