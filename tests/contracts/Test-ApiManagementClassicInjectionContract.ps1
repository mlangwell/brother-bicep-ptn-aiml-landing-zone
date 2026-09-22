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

    # ---------------------------------------------------------------------
    # NSG rules, asserted STRUCTURALLY against the compiled ARM body.
    # ---------------------------------------------------------------------
    # An earlier version of this test grepped the .bicep source for a service
    # tag and, separately, for a port number, anywhere in the file. That could
    # not bind tag, port and direction to the SAME rule, so it survived three
    # internet-exposing mutations: widening the 3443 source tag to '*',
    # flipping that rule to Outbound, and adding an inbound '*' -> :443 rule.
    # Parsing the compiled template and asserting per rule closes that gap.
    $nsgTemplate = Build-Template -Path $nsgFile -OutFile (Join-Path $scratch 'injection-nsg.json') |
        ConvertFrom-Json -Depth 100
    # Bicep emits `resources` as either an array or a symbolic-name-keyed object
    # depending on languageVersion. Handle both rather than assuming one.
    $nsgResource = $null
    if ($nsgTemplate.resources -is [System.Collections.IEnumerable] -and $nsgTemplate.resources -isnot [string] -and
        $nsgTemplate.resources -isnot [System.Management.Automation.PSCustomObject]) {
        $nsgResource = @($nsgTemplate.resources | Where-Object { [string]$_.type -eq 'Microsoft.Network/networkSecurityGroups' })[0]
    }
    else {
        $nsgResource = @($nsgTemplate.resources.PSObject.Properties.Value |
            Where-Object { [string]$_.type -eq 'Microsoft.Network/networkSecurityGroups' })[0]
    }
    Assert-True `
        -Condition ($null -ne $nsgResource) `
        -Message 'The compiled injection NSG template emits a network security group'
    $rules = @($nsgResource.properties.securityRules)

    Assert-True `
        -Condition ($rules.Count -ge 9) `
        -Message "The injection NSG declares its full rule set (found $($rules.Count))"

    function Get-Rule {
        param([string]$Name)
        return ($rules | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1)
    }

    # Each required rule is asserted as a whole: direction, access, protocol,
    # source and destination together. A mutation to any single field fails.
    foreach ($spec in @(
        @{ n = 'AllowApiManagementControlPlaneInbound'; dir = 'Inbound'; proto = 'Tcp'; src = 'ApiManagement'; dst = 'VirtualNetwork'; port = '3443' },
        @{ n = 'AllowAzureLoadBalancerInbound'; dir = 'Inbound'; proto = 'Tcp'; src = 'AzureLoadBalancer'; dst = 'VirtualNetwork'; port = '6390' },
        @{ n = 'AllowStorageOutbound'; dir = 'Outbound'; proto = 'Tcp'; src = 'VirtualNetwork'; dst = 'Storage'; port = '443' },
        @{ n = 'AllowSqlOutbound'; dir = 'Outbound'; proto = 'Tcp'; src = 'VirtualNetwork'; dst = 'Sql'; port = '1433' },
        @{ n = 'AllowKeyVaultOutbound'; dir = 'Outbound'; proto = 'Tcp'; src = 'VirtualNetwork'; dst = 'AzureKeyVault'; port = '443' },
        @{ n = 'AllowCertificateValidationOutbound'; dir = 'Outbound'; proto = 'Tcp'; src = 'VirtualNetwork'; dst = 'Internet'; port = '80' },
        @{ n = 'AllowMicrosoftEntraIdOutbound'; dir = 'Outbound'; proto = 'Tcp'; src = 'VirtualNetwork'; dst = 'AzureActiveDirectory'; port = '443' }
    )) {
        $rule = Get-Rule $spec.n
        if ($null -eq $rule) {
            Add-Failure "The injection NSG is missing the required rule $($spec.n)"
            continue
        }
        $p = $rule.properties
        $ok = ([string]$p.direction -ceq $spec.dir) -and
              ([string]$p.access -ceq 'Allow') -and
              ([string]$p.protocol -ceq $spec.proto) -and
              ([string]$p.sourceAddressPrefix -ceq $spec.src) -and
              ([string]$p.destinationAddressPrefix -ceq $spec.dst) -and
              ([string]$p.destinationPortRange -ceq $spec.port)
        Assert-True `
            -Condition $ok `
            -Message "$($spec.n) is exactly $($spec.dir) Allow $($spec.proto) $($spec.src) -> $($spec.dst):$($spec.port)"
    }

    # AzureMonitor uses destinationPortRanges (plural) for 1886 + 443.
    $monitor = Get-Rule 'AllowAzureMonitorOutbound'
    Assert-True `
        -Condition ($null -ne $monitor -and
            [string]$monitor.properties.direction -ceq 'Outbound' -and
            [string]$monitor.properties.destinationAddressPrefix -ceq 'AzureMonitor' -and
            (@($monitor.properties.destinationPortRanges) -contains '1886') -and
            (@($monitor.properties.destinationPortRanges) -contains '443')) `
        -Message 'AllowAzureMonitorOutbound is Outbound to AzureMonitor on both 1886 and 443'

    $dns = Get-Rule 'AllowDnsOutbound'
    Assert-True `
        -Condition ($null -ne $dns -and
            [string]$dns.properties.direction -ceq 'Outbound' -and
            [string]$dns.properties.destinationPortRange -ceq '53') `
        -Message 'AllowDnsOutbound is Outbound on port 53'

    # ---------------------------------------------------------------------
    # The exposure check. This is the assertion that matters most: it must
    # reject ANY inbound rule whose source is broader than a specific Azure
    # service tag or the VNet itself. '*' is strictly broader than 'Internet',
    # so matching only on 'Internet' was insufficient.
    # ---------------------------------------------------------------------
    $permittedInboundSources = @('ApiManagement', 'AzureLoadBalancer', 'VirtualNetwork')
    $inboundRules = @($rules | Where-Object { [string]$_.properties.direction -ceq 'Inbound' })
    $exposing = @(
        foreach ($rule in $inboundRules) {
            $src = [string]$rule.properties.sourceAddressPrefix
            if ([string]$rule.properties.access -cne 'Allow') { continue }
            if ($src -notin $permittedInboundSources) { "$($rule.name) (source '$src')" }
        }
    )
    Assert-True `
        -Condition ($exposing.Count -eq 0) `
        -Message "Every inbound Allow rule sources from a specific Azure service tag or the VNet$(if ($exposing.Count) { ' - VIOLATIONS: ' + ($exposing -join ', ') })"

    # Internal mode must never carry the external-mode client-traffic rules.
    Assert-True `
        -Condition (@($inboundRules | Where-Object { [string]$_.properties.sourceAddressPrefix -cin @('Internet', '*', '0.0.0.0/0') }).Count -eq 0) `
        -Message 'No inbound rule sources from Internet, * or 0.0.0.0/0; those are external-mode only and would expose the data plane'

    Assert-True `
        -Condition (@($inboundRules | Where-Object { [string]$_.properties.sourceAddressPrefix -ceq 'AzureTrafficManager' }).Count -eq 0) `
        -Message 'No AzureTrafficManager rule, which applies only to external multi-region deployments'

    # The module advertises its rule names in an output. That claim is only
    # meaningful if something checks it against the rules actually declared.
    $declaredNames = @($rules | ForEach-Object { [string]$_.name } | Sort-Object)
    $advertisedNames = @($nsgTemplate.outputs.ruleNames.value | ForEach-Object { [string]$_ } | Sort-Object)
    Assert-True `
        -Condition (($declaredNames -join '|') -ceq ($advertisedNames -join '|')) `
        -Message 'The ruleNames output matches the rules actually declared, so a dropped rule cannot be misreported to the operator'

    # ---------------------------------------------------------------------
    # Public IP: required by Azure for a zone-redundant injected instance.
    # ---------------------------------------------------------------------
    # Learn, reliability-api-management: "When you enable availability zone
    # support on an API Management instance that's deployed in an external or
    # internal virtual network, you must specify a public IP address resource
    # for the instance to use." Premium is zone redundant by default in an
    # AZ-capable region, so Premium without a public IP fails to deploy - and
    # that failure is invisible to compilation. Hence these assertions.
    #
    # The same Learn page: "In an internal virtual network, the public IP
    # address is used only for management operations, not for API requests."
    # So this is not a data-plane exposure, and must not be "hardened" away.
    foreach ($path in @(
        @{ name = 'landing-zone-created gateway'; source = $moduleSource },
        @{ name = 'platform-owned gateway'; source = $platformSource }
    )) {
        Assert-True `
            -Condition ($path.source -match 'publicIpAddressResourceId:\s*empty\(_effectivePublicIpResourceId\)\s*\?\s*null\s*:\s*_effectivePublicIpResourceId') `
            -Message "The $($path.name) passes a public IP to the gateway, which Azure requires for zone redundancy, and null when there is none"

        Assert-True `
            -Condition ($path.source -match "_needsPublicIp\s*=\s*(configuration\.)?sku\s*==\s*'Premium'") `
            -Message "The $($path.name) requires a public IP exactly when the tier is Premium, the only classic tier with availability zones"

        # Both paths must expose zone control. A hardcoded [1,2,3] cannot deploy
        # into a region without availability zones, so a path that omits this
        # makes Premium undeployable there - and the two paths must not drift.
        Assert-True `
            -Condition ($path.source -match 'availabilityZones:\s*publicIpAvailabilityZones') `
            -Message "The $($path.name) passes public IP zones explicitly rather than hardcoding zone redundancy"
    }

    $pipFile = Join-Path $RepositoryRoot 'modules\networking\api-management-public-ip.bicep'
    Assert-True `
        -Condition (Test-Path -LiteralPath $pipFile) `
        -Message 'The shared API Management public IP module exists'

    if (Test-Path -LiteralPath $pipFile) {
        $pipTemplate = Build-Template -Path $pipFile -OutFile (Join-Path $scratch 'apim-public-ip.json') |
            ConvertFrom-Json -Depth 100
        $pipResource = $null
        if ($pipTemplate.resources -is [System.Collections.IEnumerable] -and $pipTemplate.resources -isnot [string] -and
            $pipTemplate.resources -isnot [System.Management.Automation.PSCustomObject]) {
            $pipResource = @($pipTemplate.resources | Where-Object { [string]$_.type -eq 'Microsoft.Network/publicIPAddresses' })[0]
        }
        else {
            $pipResource = @($pipTemplate.resources.PSObject.Properties.Value |
                Where-Object { [string]$_.type -eq 'Microsoft.Network/publicIPAddresses' })[0]
        }

        Assert-True `
            -Condition ($null -ne $pipResource) `
            -Message 'The public IP module emits a public IP address resource'

        if ($null -ne $pipResource) {
            # Both are mandatory for API Management VNet deployments on stv2.
            # Basic or Dynamic is rejected by the platform, at deploy time only.
            Assert-True `
                -Condition ([string]$pipResource.sku.name -ceq 'Standard') `
                -Message 'The gateway public IP is Standard SKU, which API Management VNet deployment requires'

            Assert-True `
                -Condition ([string]$pipResource.properties.publicIPAllocationMethod -ceq 'Static') `
                -Message 'The gateway public IP uses Static allocation, which API Management VNet deployment requires'

            # Learn: "ensure you assign a DNS name label to it."
            Assert-True `
                -Condition ($null -ne $pipResource.properties.dnsSettings.domainNameLabel) `
                -Message 'The gateway public IP carries a DNS name label, which Learn requires for an injected instance'
        }
    }

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
