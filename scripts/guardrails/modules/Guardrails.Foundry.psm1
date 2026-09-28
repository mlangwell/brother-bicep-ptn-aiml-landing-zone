#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Plane 2 - the Foundry control plane: throughput, not currency.

.DESCRIPTION
    Nothing in this plane is a spend control, and the module says so in its own
    output rather than letting anyone infer otherwise.

    Quota allocates THROUGHPUT. A 240,000 TPM deployment run flat out for a
    month is a large bill and a compliant one. Microsoft is explicit:

      "Some customers use quota to manage their billing. Using quota to manage
       billing isn't the Azure best practice, but if your system is configured
       that way, you might not want to break it."

    Since 2026 quota tiers also rise automatically with usage, so a TPM ceiling
    set once can move on its own. There are two defensible responses - pin the
    tier, or document loudly that quota is not the ceiling - and one
    indefensible one, which is to leave it undecided. This module forces the
    choice and records which was taken.
#>

$ErrorActionPreference = 'Stop'

function Invoke-FoundryGuardrails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target
    )

    $plane = '2-Foundry'

    Add-GuardrailResult -Plane $plane -Name 'Quota is not a budget (informational)' -Status 'Finding' `
        -Detail 'Foundry quota is a throughput ceiling in TPM, not a currency ceiling, and it is enforced on an estimate at request time rather than the billed count. Nothing configured in this plane stops spend.' `
        -Remediation 'The only real-time hard stop is the APIM llm-token-limit policy (plane 3). Make sure that is understood by whoever inherits this configuration.' `
        -Reference 'https://learn.microsoft.com/azure/ai-foundry/openai/how-to/manage-costs' | Out-Null

    Set-QuotaTierPolicy -Config $Config -Target $Target -Plane $plane

    if ([string]::IsNullOrWhiteSpace($Config.FoundryAccountName)) {
        Add-GuardrailResult -Plane $plane -Name 'Foundry account checks' -Status 'Skipped' `
            -Detail 'FOUNDRY_ACCOUNT_NAME is not set, so the account-level posture checks were not run.' | Out-Null
        return
    }

    Test-FoundryAccountPosture -Config $Config -Target $Target -Plane $plane
}

function Set-QuotaTierPolicy {
    <#
    .SYNOPSIS
        Pin or deliberately decline to pin the subscription's quota tier
        upgrade policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    $desired = $Config.FoundryQuotaTierPolicy

    if ($desired -ieq 'skip') {
        Add-GuardrailResult -Plane $Plane -Name 'Quota tier upgrade policy' -Status 'Skipped' `
            -Detail 'FOUNDRY_QUOTA_TIER_POLICY=skip. No change made, and this is recorded as a deliberate decision rather than an oversight.' `
            -Remediation 'If this was not deliberate, choose NoAutoUpgrade (pin the tier; the opt-out is a preview feature) or OnceUpgradeIsAvailable (accept that quota rises with usage, and document that quota is not the cost ceiling).' | Out-Null
        return
    }

    $url = "https://management.azure.com/subscriptions/$($Target.SubscriptionId)/providers/Microsoft.CognitiveServices/quotaTiers/default" +
           "?api-version=$($Config.FoundryQuotaApiVersion)"

    Invoke-GuardrailAction -Plane $Plane -Name 'Quota tier upgrade policy' `
        -Reference 'https://learn.microsoft.com/azure/ai-foundry/openai/how-to/quota' `
        -WouldDo "Set tierUpgradePolicy to '$desired' for subscription $($Target.SubscriptionId)" `
        -Probe {
            $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $live) {
                # `readable=$false` matters: without it, "we could not read it"
                # and "it was explicitly unset" both land as a null prior value,
                # and a teardown cannot tell a value it may restore from one it
                # must report as unknown.
                return @{
                    Compliant = $false
                    Detail    = "quotaTiers/default is not readable at api-version $($Config.FoundryQuotaApiVersion)"
                    Evidence  = @{ readable = $false }
                }
            }

            $current = $null
            if ($live.PSObject.Properties.Name -contains 'properties' -and $live.properties) {
                if ($live.properties.PSObject.Properties.Name -contains 'tierUpgradePolicy') {
                    $current = [string]$live.properties.tierUpgradePolicy
                }
            }

            if ($current -ieq $desired) {
                return @{
                    Compliant = $true
                    Detail    = "already '$current'"
                    Evidence  = @{ readable = $true; tierUpgradePolicy = $current; currentTier = $(if ($live.properties.PSObject.Properties.Name -contains 'currentTierName') { $live.properties.currentTierName } else { $null }) }
                }
            }

            return @{
                Compliant = $false
                Detail    = "currently '$(if ($current) { $current } else { 'unset' })'"
                Evidence  = @{ readable = $true; tierUpgradePolicy = $current; wasUnset = ($null -eq $current) }
            }
        } `
        -Action {
            $result = Invoke-AzRestJson -Method patch -Url $url -Body @{
                properties = @{ tierUpgradePolicy = $desired }
            }
            return @{ tierUpgradePolicy = $desired; response = $result }
        } | Out-Null

    if ($desired -ieq 'NoAutoUpgrade') {
        Add-GuardrailResult -Plane $Plane -Name 'Quota tier opt-out is preview' -Status 'Finding' `
            -Detail 'The quota tier auto-upgrade opt-out is a preview feature and Microsoft states it "may be subject to change/removal". Do not treat the pinned tier as a permanent guarantee.' `
            -Remediation 'Re-check this setting periodically, and do not let anyone describe the pinned TPM ceiling as the cost ceiling.' | Out-Null
    }
}

function Test-FoundryAccountPosture {
    <#
    .SYNOPSIS
        Read-only posture checks on the Foundry account. Reports findings; the
        durable enforcement lives in the plane 1 policies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    $account = Invoke-AzCli -AllowNotFound -Arguments @(
        'cognitiveservices', 'account', 'show',
        '--name', $Config.FoundryAccountName,
        '--resource-group', $Target.ResourceGroup,
        '-o', 'json'
    )

    if (-not $account) {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry account' -Status 'Failed' `
            -Detail "Foundry account '$($Config.FoundryAccountName)' not found in resource group '$($Target.ResourceGroup)'." | Out-Null
        return
    }

    if ($account.PSObject.Properties.Name -notcontains 'properties' -or -not $account.properties) {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry account' -Status 'Unverifiable' `
            -Detail "Account '$($Config.FoundryAccountName)' was found but returned no readable properties block." | Out-Null
        return
    }

    $properties = $account.properties
    $propertyNames = $properties.PSObject.Properties.Name

    # --- public network access -------------------------------------------
    # This is load-bearing for the whole design. The gateway can only be an
    # authoritative spend control for traffic it actually fronts. If public
    # access is ever enabled on the Foundry account, the token limit stops
    # being a control and becomes a suggestion.
    $publicAccess = if ($propertyNames -contains 'publicNetworkAccess') { [string]$properties.publicNetworkAccess } else { 'unknown' }
    if ($publicAccess -ieq 'Disabled') {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry public network access' -Status 'Compliant' `
            -Detail 'Disabled. The gateway remains authoritative over inference traffic.' `
            -Evidence @{ publicNetworkAccess = $publicAccess } | Out-Null
    }
    else {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry public network access' -Status 'Finding' `
            -Detail "publicNetworkAccess is '$publicAccess'. Callers can reach Foundry without passing through API Management, which means the gateway token limit is no longer a spend control for that traffic." `
            -Remediation 'Set publicNetworkAccess to Disabled in the landing-zone Bicep and redeploy. Do not fix this imperatively - the template is the source of truth.' `
            -Evidence @{ publicNetworkAccess = $publicAccess } | Out-Null
    }

    # --- local auth --------------------------------------------------------
    $localAuthDisabled = $false
    if ($propertyNames -contains 'disableLocalAuth') { $localAuthDisabled = [bool]$properties.disableLocalAuth }

    if ($localAuthDisabled) {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry local (key) auth' -Status 'Compliant' `
            -Detail 'disableLocalAuth is true. Key-based access cannot quietly become the real path around the gateway.' | Out-Null
    }
    else {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry local (key) auth' -Status 'Finding' `
            -Detail 'disableLocalAuth is false or unset, so account keys still work. A key is a path to Foundry that bypasses APIM entirely.' `
            -Remediation 'Set aiFoundryDisableLocalAuth true in the landing-zone environment configuration and redeploy.' | Out-Null
    }

    # --- dynamic quota -----------------------------------------------------
    $dynamic = $null
    if ($propertyNames -contains 'dynamicThrottlingEnabled') { $dynamic = $properties.dynamicThrottlingEnabled }

    if ($null -eq $dynamic) {
        Add-GuardrailResult -Plane $Plane -Name 'Dynamic quota state' -Status 'Unverifiable' `
            -Detail 'dynamicThrottlingEnabled is not present on the account response, and Microsoft publishes no default state for it. There is also no metric or log indicating when dynamic quota has engaged, so its effect cannot be observed after the fact.' `
            -Remediation 'The plane 1 policy "Foundry dynamic quota must be off" makes the desired state explicit and durable. Leave it assigned.' `
            -Reference 'https://learn.microsoft.com/azure/foundry-classic/openai/how-to/dynamic-quota' | Out-Null
    }
    elseif ([bool]$dynamic) {
        Add-GuardrailResult -Plane $Plane -Name 'Dynamic quota state' -Status 'Finding' `
            -Detail 'dynamicThrottlingEnabled is true. Deployments may exceed their assigned TPM opportunistically, and the overage is billed at normal rates. Microsoft: "there is no call enforcement of a ceiling quota or throughput".' `
            -Remediation 'Set it to false explicitly in Bicep rather than relying on an undocumented default.' | Out-Null
    }
    else {
        Add-GuardrailResult -Plane $Plane -Name 'Dynamic quota state' -Status 'Compliant' `
            -Detail 'dynamicThrottlingEnabled is explicitly false.' | Out-Null
    }

    # --- abuse-monitoring content logging ---------------------------------
    # The ContentLogging capability appears ONLY when logging is off, so its
    # absence is the ambiguous case, not its presence.
    $contentLoggingOff = $false
    if (($propertyNames -contains 'capabilities') -and $properties.capabilities) {
        foreach ($capability in @($properties.capabilities)) {
            if ([string]$capability.name -eq 'ContentLogging' -and [string]$capability.value -eq 'false') {
                $contentLoggingOff = $true
            }
        }
    }

    if ($contentLoggingOff) {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry content logging' -Status 'Compliant' `
            -Detail 'The ContentLogging=false capability is present, which is how the platform signals content logging is off.' | Out-Null
    }
    else {
        Add-GuardrailResult -Plane $Plane -Name 'Foundry content logging' -Status 'Unverifiable' `
            -Detail 'The ContentLogging capability is absent. That property surfaces only when logging is off, so its absence does not prove logging is on - it just means this check cannot confirm either way.' `
            -Remediation 'Confirm in the portal: <Foundry resource> > Overview > JSON view > Capabilities. Note also that NO abuse-monitoring retention period is published by Microsoft - do not state a number; route the question to the DPA or the account team.' | Out-Null
    }

    # --- deployment inventory ---------------------------------------------
    $deployments = Invoke-AzCli -AllowNotFound -Arguments @(
        'cognitiveservices', 'account', 'deployment', 'list',
        '--name', $Config.FoundryAccountName,
        '--resource-group', $Target.ResourceGroup,
        '-o', 'json'
    )

    if (-not $deployments) {
        Add-GuardrailResult -Plane $Plane -Name 'Model deployment inventory' -Status 'Skipped' `
            -Detail 'No model deployments found on the account.' | Out-Null
        return
    }

    $overCapacity = @()
    $unapprovedSku = @()
    $inventory = @()

    foreach ($deployment in @($deployments)) {
        $skuName = if ($deployment.sku) { [string]$deployment.sku.name } else { 'unknown' }
        $capacity = if ($deployment.sku -and $deployment.sku.PSObject.Properties.Name -contains 'capacity') { [int]$deployment.sku.capacity } else { 0 }

        $inventory += @{ name = [string]$deployment.name; sku = $skuName; capacity = $capacity }

        if ($capacity -gt $Config.FoundryMaxDeploymentCapacity) {
            $overCapacity += "$($deployment.name) (capacity $capacity)"
        }
        if ($skuName -notin $Config.FoundryAllowedDeploymentSkus) {
            $unapprovedSku += "$($deployment.name) (sku $skuName)"
        }
    }

    if ($overCapacity.Count -eq 0 -and $unapprovedSku.Count -eq 0) {
        Add-GuardrailResult -Plane $Plane -Name 'Model deployment inventory' -Status 'Compliant' `
            -Detail "$($inventory.Count) deployment(s), all within the configured SKU allow-list and capacity ceiling." `
            -Evidence $inventory | Out-Null
    }
    else {
        $issues = @()
        if ($overCapacity.Count -gt 0)  { $issues += "over the capacity ceiling of $($Config.FoundryMaxDeploymentCapacity): $($overCapacity -join ', ')" }
        if ($unapprovedSku.Count -gt 0) { $issues += "outside the SKU allow-list: $($unapprovedSku -join ', ')" }

        Add-GuardrailResult -Plane $Plane -Name 'Model deployment inventory' -Status 'Finding' `
            -Detail "Existing deployments $($issues -join '; ')." `
            -Remediation 'Policy does not retroactively change existing resources - it marks them non-compliant. These pre-date the guardrail and must be resized or explicitly exempted before POLICY_EFFECT is flipped to Deny, or the first redeploy of them will fail.' `
            -Evidence $inventory | Out-Null
    }
}

Export-ModuleMember -Function @(
    'Invoke-FoundryGuardrails'
    'Set-QuotaTierPolicy'
    'Test-FoundryAccountPosture'
)

