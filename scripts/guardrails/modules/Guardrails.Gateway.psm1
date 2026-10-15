#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Plane 3 - API Management. The only real-time spend control, verified but
    never rewritten.

.DESCRIPTION
    READ-ONLY BY DESIGN. This module asserts; it does not write.

    Two reasons, and both matter:

      1. The gateway policy XML is owned by the landing-zone Bicep repository.
         Rewriting it here would create drift between the running gateway and
         its source of truth.

      2. Neither API Management v2 tier supports backup or restore. The Bicep
         repository is the ONLY copy of these spend controls. A script that
         edits the live policy and then fails halfway has no undo.

    So failures here surface as findings with the fix to make in Bicep, rather
    than as imperative repairs.

    Context for why this plane is the important one: Azure has no native spend
    cap for AI. Microsoft's own sentence -

      "While OpenAI has an option for hard limits that prevent you from going
       over your budget, Azure OpenAI doesn't currently provide this
       functionality."

    Everything in plane 4 is a smoke detector. This is the sprinkler.
#>

$ErrorActionPreference = 'Stop'

$script:ApimApiVersion = '2024-05-01'
$script:MetricsApiVersion = '2024-02-01'

# Documented API Management custom-metric limits. Exceeding either causes
# SILENT data loss - the dashboard simply under-reports, which is the worst
# possible failure mode for a control whose job is telling you what you spent.
$script:MaxActiveTimeSeries = 1000
$script:MaxDimensionValues = 100

function Invoke-GatewayGuardrails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target
    )

    $plane = '3-Gateway'

    if ([string]::IsNullOrWhiteSpace($Config.ApimName)) {
        Add-GuardrailResult -Plane $plane -Name 'API Management checks' -Status 'Skipped' `
            -Detail 'APIM_NAME is not set, so the live gateway assertions were not run.' | Out-Null
        Test-MetricCardinality -Config $Config -Plane $plane -Mappings $null
        return
    }

    $apimResourceGroup = if ([string]::IsNullOrWhiteSpace($Config.ApimResourceGroup)) { $Target.ResourceGroup } else { $Config.ApimResourceGroup }

    $service = Invoke-AzCli -AllowNotFound -Arguments @(
        'apim', 'show', '--name', $Config.ApimName, '--resource-group', $apimResourceGroup, '-o', 'json'
    )

    if (-not $service) {
        Add-GuardrailResult -Plane $plane -Name 'API Management service' -Status 'Failed' `
            -Detail "API Management service '$($Config.ApimName)' not found in resource group '$apimResourceGroup'." | Out-Null
        Test-MetricCardinality -Config $Config -Plane $plane -Mappings $null
        return
    }

    $sku = if ($service.PSObject.Properties.Name -contains 'sku' -and $service.sku) { [string]$service.sku.name } else { 'unknown' }
    Add-GuardrailResult -Plane $plane -Name 'API Management service' -Status 'Compliant' `
        -Detail "Found '$($service.name)' on tier '$sku' in $($service.location)." `
        -Evidence @{ id = $service.id; sku = $sku; location = [string]$service.location } | Out-Null

    if ($sku -like '*V2') {
        Add-GuardrailResult -Plane $plane -Name 'v2 tier constraints' -Status 'Finding' `
            -Detail "Tier '$sku' has no backup or restore, so the Bicep repository is the only copy of these spend controls. The v2 buffered payload limit is also 2 MiB rather than the 500 MiB of the classic tiers, which bounds what estimate-prompt-tokens can read. Premium v2 additionally does not support multi-region." `
            -Remediation 'Confirm the gateway policy XML and named values are committed and that any DR plan does not assume multi-region APIM. Test estimate-prompt-tokens at real prompt and image payload sizes.' | Out-Null
    }
    elseif ($sku -ieq 'Developer') {
        Add-GuardrailResult -Plane $plane -Name 'Developer tier caveat' -Status 'Finding' `
            -Detail 'Developer has no SLA, is capped at one unit, and is a classic tier using a sliding-window throttling algorithm where the v2 tiers use a token bucket.' `
            -Remediation 'Treat throttling behaviour observed here as directional, not predictive of a v2 production gateway.' | Out-Null
    }

    $serviceId = [string]$service.id
    $mappings = Get-GatewayCallerMappings -Config $Config -ServiceId $serviceId -Plane $plane

    Test-MetricCardinality -Config $Config -Plane $plane -Mappings $mappings
    Test-EmergencyStopControl -Config $Config -ServiceId $serviceId -Plane $plane
    Test-TokenLimitPolicy -Config $Config -ServiceId $serviceId -Plane $plane -Mappings $mappings
    Test-ThrottledSeriesMetric -Target $Target -Plane $plane
}

function Get-GatewayCallerMappings {
    <#
    .SYNOPSIS
        Read the real caller configuration out of the gateway's own named value.

    .DESCRIPTION
        The landing zone stores the approved caller set as base64 JSON in
        `<owner>-configuration`. Reading it means the cardinality arithmetic is
        performed against what is actually deployed, rather than against numbers
        an operator typed into .env and may never revisit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ServiceId,
        [Parameter(Mandatory)][string]$Plane
    )

    $namedValue = "$($Config.GatewayOwner)-configuration"
    $url = "https://management.azure.com$ServiceId/namedValues/$namedValue" + "?api-version=$script:ApimApiVersion"
    $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound

    if (-not $live -or ($live.PSObject.Properties.Name -notcontains 'properties') -or
        ($live.properties.PSObject.Properties.Name -notcontains 'value')) {
        Add-GuardrailResult -Plane $Plane -Name 'Caller configuration' -Status 'Unverifiable' `
            -Detail "Named value '$namedValue' was not readable, so the deployed caller set could not be inspected. Cardinality is reported from the .env estimates instead, which may not reflect reality." `
            -Remediation 'Confirm GATEWAY_OWNER matches the deployed owner token.' | Out-Null
        return $null
    }

    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$live.properties.value))
        $parsed = $decoded | ConvertFrom-Json
    }
    catch {
        Add-GuardrailResult -Plane $Plane -Name 'Caller configuration' -Status 'Unverifiable' `
            -Detail "Named value '$namedValue' could not be decoded: $($_.Exception.Message)" | Out-Null
        return $null
    }

    if ($parsed.PSObject.Properties.Name -notcontains 'callerMappings') { return $null }
    $mappings = @($parsed.callerMappings)

    # The 4,096-character cap on the encoded named value is the real ceiling on
    # how many callers this gateway can carry, and billing labels consume it.
    $encodedLength = ([string]$live.properties.value).Length
    $status = if ($encodedLength -gt 3686) { 'Finding' } else { 'Compliant' }
    Add-GuardrailResult -Plane $Plane -Name 'Caller configuration' -Status $status `
        -Detail "$($mappings.Count) configured caller(s); the encoded configuration is $encodedLength of the 4096-character named-value limit." `
        -Remediation $(if ($status -eq 'Finding') { 'Approaching the named-value limit. Adding callers or billing labels past this point will fail validation before it fails deployment.' } else { $null }) `
        -Evidence @{ callerCount = $mappings.Count; encodedLength = $encodedLength } | Out-Null

    return $mappings
}

function Test-MetricCardinality {
    <#
    .SYNOPSIS
        Cardinality arithmetic for the token metric, computed from the deployed
        caller set when it is readable.

    .DESCRIPTION
        A naive model multiplies every dimension together and concludes the
        namespace cap is reached at about six callers. That is the worst case
        for an arbitrary policy, and it materially overstates the risk for THIS
        one: the gateway returns 403 before emitting a metric unless the caller
        matches exactly one configured mapping, and each mapping names exactly
        one project. So active series is the SUM over callers of their approved
        model count, not the full cross-product.

        The binding constraint is therefore the 100-unique-values-per-dimension
        cap, not the 1,000-active-time-series namespace cap. Both are checked,
        because both fail the same way: silently.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Plane,
        $Mappings
    )

    if ($Mappings -and @($Mappings).Count -gt 0) {
        $list = @($Mappings)
        $callerValues = @($list | ForEach-Object {
            $names = $_.PSObject.Properties.Name
            if (($names -contains 'label') -and -not [string]::IsNullOrWhiteSpace([string]$_.label)) { [string]$_.label }
            else { [string]$_.objectId }
        } | Sort-Object -Unique)

        $projects = @($list | ForEach-Object { [string]$_.project } | Sort-Object -Unique)
        $series = 0
        foreach ($mapping in $list) {
            $modelCount = if ($mapping.PSObject.Properties.Name -contains 'models') { @($mapping.models).Count } else { 1 }
            $series += $modelCount
        }

        $source = 'deployed gateway configuration'
        $labelled = @($list | Where-Object {
            ($_.PSObject.Properties.Name -contains 'label') -and -not [string]::IsNullOrWhiteSpace([string]$_.label)
        }).Count
    }
    else {
        # Fall back to the .env estimates, and say plainly that is what happened.
        $callerValues = 1..$Config.GatewayExpectedCallers | ForEach-Object { "estimated-$_" }
        $projects = 1..$Config.GatewayExpectedProjects | ForEach-Object { "estimated-$_" }
        $series = $Config.GatewayExpectedCallers * $Config.GatewayExpectedModels
        $source = '.env estimates (the deployed configuration was not readable)'
        $labelled = 0
    }

    $evidence = @{
        namespace                 = $Config.GatewayMetricNamespace
        source                    = $source
        distinctCallerValues      = @($callerValues).Count
        distinctProjects          = @($projects).Count
        projectedActiveTimeSeries = $series
        activeTimeSeriesCap       = $script:MaxActiveTimeSeries
        dimensionValueCap         = $script:MaxDimensionValues
        labelledCallers           = $labelled
    }

    if ($series -gt $script:MaxActiveTimeSeries) {
        Add-GuardrailResult -Plane $Plane -Name 'Token metric cardinality' -Status 'Finding' `
            -Detail "Projected $series active time series against a documented cap of $script:MaxActiveTimeSeries, from $source. Past the cap the metric data is SILENTLY DISCARDED and the cost dashboard simply under-reports." `
            -Remediation 'Reduce the approved model count per caller, or aggregate callers into billing groups. If per-caller attribution at this scale is genuinely needed, use logs rather than metric dimensions - that is Azure Monitor own guidance.' `
            -Evidence $evidence `
            -Reference 'https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy' | Out-Null
    }
    else {
        Add-GuardrailResult -Plane $Plane -Name 'Token metric cardinality' -Status 'Compliant' `
            -Detail "Projected $series active time series against a cap of $script:MaxActiveTimeSeries, from $source. Each caller maps to exactly one project and its approved models, so series grow linearly with callers rather than as a cross-product." `
            -Evidence $evidence | Out-Null
    }

    $callerCount = @($callerValues).Count
    if ($callerCount -gt $script:MaxDimensionValues) {
        Add-GuardrailResult -Plane $Plane -Name 'Caller dimension value count' -Status 'Finding' `
            -Detail "$callerCount distinct caller dimension values exceeds the documented per-dimension limit of $script:MaxDimensionValues. Values past the limit are not tracked at all." `
            -Remediation 'Aggregate callers into a bounded set of billing labels rather than emitting one value per caller.' | Out-Null
    }
    elseif ($callerCount -gt [int]($script:MaxDimensionValues * 0.8)) {
        Add-GuardrailResult -Plane $Plane -Name 'Caller dimension value count' -Status 'Finding' `
            -Detail "$callerCount distinct caller dimension values is within 80% of the $script:MaxDimensionValues per-dimension cap. This is the binding constraint on how many callers this gateway can meter." `
            -Remediation 'Plan billing-label aggregation before adding more callers.' | Out-Null
    }

    Add-GuardrailResult -Plane $Plane -Name 'Custom metrics are preview' -Status 'Finding' `
        -Detail 'Azure Monitor custom metrics with dimensions are public preview, and Microsoft states the feature "won''t be made generally available" because Application Insights with OpenTelemetry supersedes it. Chargeback built on llm-emit-token-metric rests on a preview surface with a named successor.' `
        -Remediation 'Do not anchor a long-lived chargeback commitment to this metric without a migration position.' `
        -Reference 'https://learn.microsoft.com/azure/azure-monitor/metrics/metrics-custom-overview' | Out-Null
}

function Test-EmergencyStopControl {
    <#
    .SYNOPSIS
        Confirm the emergency-stop named value exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ServiceId,
        [Parameter(Mandatory)][string]$Plane
    )

    $namedValue = "$($Config.GatewayOwner)-stop"
    $url = "https://management.azure.com$ServiceId/namedValues/$namedValue" + "?api-version=$script:ApimApiVersion"

    $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound

    if (-not $live) {
        Add-GuardrailResult -Plane $Plane -Name 'Emergency stop control' -Status 'Finding' `
            -Detail "Named value '$namedValue' was not found. The real-time kill switch this architecture depends on is not present, or GATEWAY_OWNER does not match the owner token the gateway module substituted." `
            -Remediation "Confirm GATEWAY_OWNER matches the deployed owner, then check APIM > APIs > Named values." | Out-Null
        return
    }

    $value = '(unreadable)'
    if (($live.PSObject.Properties.Name -contains 'properties') -and $live.properties -and
        ($live.properties.PSObject.Properties.Name -contains 'value')) {
        $value = [string]$live.properties.value
    }

    Add-GuardrailResult -Plane $Plane -Name 'Emergency stop control' -Status 'Compliant' `
        -Detail "Named value '$namedValue' exists and currently reads '$value'. Any value other than 'false' makes the gateway return 503 to new inference requests." `
        -Evidence @{ namedValue = $namedValue; value = $value } | Out-Null

    Add-GuardrailResult -Plane $Plane -Name 'Emergency stop un-stop procedure' -Status 'Finding' `
        -Detail 'A 503 kill switch is only safe if somebody knows how to turn it off. This is the control that a budget alert would eventually trigger, so it must have a documented, tested, named owner.' `
        -Remediation 'Confirm a named person at the customer has actually RUN the un-stop path (Complete-GatewayPrivateAccess -Apply -StopNewRequests and its reverse) in a non-production environment. Wiring a budget alert to this control before that rehearsal is a bad trade: budget data is 8-24h behind, so it is a backstop, not a real-time control.' | Out-Null
}

function Test-TokenLimitPolicy {
    <#
    .SYNOPSIS
        Confirm the owned API policy still contains the spend controls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ServiceId,
        [Parameter(Mandatory)][string]$Plane,
        $Mappings
    )

    $apisUrl = "https://management.azure.com$ServiceId/apis" + "?api-version=$script:ApimApiVersion"
    $apis = Invoke-AzRestJson -Method get -Url $apisUrl -AllowNotFound

    if (-not $apis -or -not $apis.value) {
        Add-GuardrailResult -Plane $Plane -Name 'Gateway token limit' -Status 'Unverifiable' `
            -Detail 'No APIs were readable on this API Management instance, so the token-limit policy could not be inspected.' | Out-Null
        return
    }

    $ownerTag = "owner:$($Config.GatewayOwner)"
    $owned = @($apis.value | Where-Object {
        $_.properties.PSObject.Properties.Name -contains 'description' -and
        [string]$_.properties.description -ceq $ownerTag
    })

    if ($owned.Count -eq 0) {
        Add-GuardrailResult -Plane $Plane -Name 'Gateway token limit' -Status 'Unverifiable' `
            -Detail "No API carried the ownership marker '$ownerTag', so the owned inference API could not be identified. GATEWAY_OWNER may not match the deployed owner token." | Out-Null
        return
    }

    foreach ($api in $owned) {
        $apiName = [string]$api.name
        $policyUrl = "https://management.azure.com$ServiceId/apis/$apiName/policies/policy" +
                     "?format=rawxml&api-version=$script:ApimApiVersion"

        $policy = Invoke-AzRestJson -Method get -Url $policyUrl -AllowNotFound
        if (-not $policy -or ($policy.PSObject.Properties.Name -notcontains 'properties') -or -not $policy.properties -or
            ($policy.properties.PSObject.Properties.Name -notcontains 'value')) {
            Add-GuardrailResult -Plane $Plane -Name "Policy on API '$apiName'" -Status 'Unverifiable' `
                -Detail 'The policy document was not readable.' | Out-Null
            continue
        }

        $xml = [string]$policy.properties.value

        $checks = [ordered]@{
            'llm-token-limit'                 = 'the real-time token ceiling'
            'estimate-prompt-tokens="true"'   = 'pre-flight estimation, so an over-limit caller costs nothing'
            'llm-emit-token-metric'           = 'per-caller token attribution'
            'validate-azure-ad-token'         = 'Entra authentication, which makes the gateway authoritative'
            'rate-limit-by-key'               = 'the call-volume backstop, which engages before tokens are counted'
        }

        $missing = @()
        foreach ($needle in $checks.Keys) {
            if ($xml -notlike "*$needle*") { $missing += "$needle ($($checks[$needle]))" }
        }

        if ($missing.Count -eq 0) {
            Add-GuardrailResult -Plane $Plane -Name "Policy on API '$apiName'" -Status 'Compliant' `
                -Detail 'All expected spend and auth controls are present in the policy document.' | Out-Null
        }
        else {
            Add-GuardrailResult -Plane $Plane -Name "Policy on API '$apiName'" -Status 'Finding' `
                -Detail "Missing from the policy document: $($missing -join '; ')." `
                -Remediation 'Fix this in the landing-zone Bicep and redeploy. Do not hand-edit the live policy - the v2 tiers have no backup or restore, so source control is the only copy.' | Out-Null
        }

        # ---- streaming posture (ADR-004) ----
        # This is the check that matters most, because the failure it detects is
        # silent: a streaming request is still throttled, just on estimates.
        if ($xml -like '*streaming-forbidden*') {
            Add-GuardrailResult -Plane $Plane -Name "Streaming posture on '$apiName'" -Status 'Compliant' `
                -Detail 'Streaming is refused, so llm-token-limit always enforces against the configured contract rather than falling back to estimated prompt AND completion tokens.' | Out-Null
        }
        else {
            Add-GuardrailResult -Plane $Plane -Name "Streaming posture on '$apiName'" -Status 'Finding' `
                -Detail 'The policy permits stream:true. Microsoft documents that when streaming is enabled, llm-token-limit ALWAYS estimates prompt tokens regardless of estimate-prompt-tokens, and estimates completion tokens too. The documented remedy is the include_usage request parameter, which DOES NOT EXIST on the Responses API - ResponseStreamOptions carries only include_obfuscation. Streaming traffic is therefore enforced, and metered, on estimates with no available correction.' `
                -Remediation 'If this was deliberate, record it as an accepted trade-off per ADR-004. If not, set gateway.allowStreaming to false in the environment profile and redeploy.' `
                -Reference 'https://learn.microsoft.com/azure/api-management/llm-token-limit-policy' | Out-Null
        }

        # ---- caller dimension readability ----
        if ($xml -like '*caller-label*') {
            $labelled = 0
            if ($Mappings) {
                $labelled = @($Mappings | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'label') -and -not [string]::IsNullOrWhiteSpace([string]$_.label)
                }).Count
            }
            $total = if ($Mappings) { @($Mappings).Count } else { 0 }

            if ($total -gt 0 -and $labelled -lt $total) {
                Add-GuardrailResult -Plane $Plane -Name "Caller billing labels on '$apiName'" -Status 'Finding' `
                    -Detail "$labelled of $total callers carry a billing label; the rest fall back to their raw Entra object ID, which is unreadable in a cost dashboard and puts a directory identifier into retained telemetry." `
                    -Remediation 'Add a label to each callerMapping in the environment profile. Note labels consume the 4096-character named-value budget.' | Out-Null
            }
            else {
                Add-GuardrailResult -Plane $Plane -Name "Caller billing labels on '$apiName'" -Status 'Compliant' `
                    -Detail "The caller metric dimension resolves a billing label$(if ($total -gt 0) { ", and all $total configured caller(s) have one" })." | Out-Null
            }
        }
        else {
            Add-GuardrailResult -Plane $Plane -Name "Caller billing labels on '$apiName'" -Status 'Finding' `
                -Detail 'The caller metric dimension emits the raw Entra object ID. A GUID is not usable for chargeback without an out-of-band mapping, and it places a directory identifier into telemetry retained for at least 31 days.' `
                -Remediation 'Adopt the callerMapping.label field and redeploy.' | Out-Null
        }

        # v2 uses a token bucket rather than a sliding window, and Microsoft
        # warns that reusing a counter-key at multiple scopes with different
        # tokens-per-minute values "can cause unpredictable behavior".
        if ($xml -match 'counter-key="([^"]+)"') {
            $keys = @([regex]::Matches($xml, 'counter-key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            $duplicates = @($keys | Group-Object | Where-Object { $_.Count -gt 1 })
            if ($duplicates.Count -gt 0) {
                Add-GuardrailResult -Plane $Plane -Name "Counter-key reuse on '$apiName'" -Status 'Finding' `
                    -Detail "The counter-key(s) $($duplicates.Name -join ', ') appear more than once. On v2 tiers, tokens-per-minute must be consistent everywhere a counter-key is reused." `
                    -Remediation 'Confirm every reuse carries the same tokens-per-minute value, and add a comment in the policy file so a future engineer does not reuse it at two scopes with different limits.' | Out-Null
            }
        }
    }

    Add-GuardrailResult -Plane $Plane -Name 'Token counter scope' -Status 'Finding' `
        -Detail 'llm-token-limit counters are tracked independently per gateway and are not aggregated across the instance. Multiple gateways mean multiple independent budgets, not one shared ceiling. Limits are also approximate at the boundary for streaming, concurrency and images.' `
        -Remediation 'Say this out loud in any review, so nobody assumes a tenant-wide ceiling exists.' | Out-Null
}

function Test-ThrottledSeriesMetric {
    <#
    .SYNOPSIS
        Try to resolve the custom-metric throttling signal empirically.

    .DESCRIPTION
        The portal exposes this under Monitor > Metrics > Custom Metric Usage >
        Throttled Time Series. It is a SUBSCRIPTION + REGION scoped Azure
        Monitor self-monitoring metric, not an API Management resource metric,
        so an APIM-scoped metric alert cannot reach it.

        Microsoft publishes no metricNamespace/metricName pair for it. Rather
        than hardcode a plausible-looking string, this probes the live metric
        definitions and reports what is actually there. If it cannot be
        resolved, that is reported as Unverifiable - not quietly skipped, and
        not filled in with a guess.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    $url = "https://management.azure.com/subscriptions/$($Target.SubscriptionId)/providers/microsoft.insights/metricDefinitions" +
           "?api-version=$script:MetricsApiVersion&region=$($Target.Location)"

    $definitions = Invoke-AzRestJson -Method get -Url $url -AllowNotFound

    if (-not $definitions -or -not ($definitions.PSObject.Properties.Name -contains 'value')) {
        Add-GuardrailResult -Plane $Plane -Name 'Throttled Time Series alert' -Status 'Unverifiable' `
            -Detail "Subscription-scope metric definitions were not readable in region '$($Target.Location)', so the throttling signal could not be resolved. Microsoft publishes no metricNamespace/metricName pair for it and this playbook will not invent one." `
            -Remediation 'Resolve it by hand: Azure portal > Monitor > Metrics > Select a scope > Refine scope > Custom Metric Usage + your region > Apply, then read Throttled Time Series. Create the alert from that blade once, and record the resulting namespace and metric name here.' `
            -Reference 'https://learn.microsoft.com/azure/azure-monitor/essentials/metrics-custom-overview' | Out-Null
        return
    }

    $candidates = @($definitions.value | Where-Object {
        ($_.PSObject.Properties.Name -contains 'name') -and $_.name -and
        (([string]$_.name.value -match 'Throttled') -or ([string]$_.name.value -match 'ActiveTimeSeries'))
    })

    if ($candidates.Count -eq 0) {
        Add-GuardrailResult -Plane $Plane -Name 'Throttled Time Series alert' -Status 'Unverifiable' `
            -Detail "Subscription-scope metric definitions were readable in '$($Target.Location)' but none matched a throttled or active-time-series name. The signal exists in the portal; its programmatic identifiers are not published." `
            -Remediation 'Create the alert once from Monitor > Metrics > Custom Metric Usage, then record the namespace and metric name it produces.' `
            -Reference 'https://learn.microsoft.com/azure/azure-monitor/essentials/metrics-custom-overview' | Out-Null
        return
    }

    $found = @($candidates | ForEach-Object {
        $names = $_.PSObject.Properties.Name
        @{
            namespace = if ($names -contains 'namespace') { [string]$_.namespace } else { '' }
            name      = [string]$_.name.value
            unit      = if ($names -contains 'unit') { [string]$_.unit } else { '' }
        }
    })

    Add-GuardrailResult -Plane $Plane -Name 'Throttled Time Series alert' -Status 'Finding' `
        -Detail "Resolved $($found.Count) candidate metric definition(s) at subscription scope in '$($Target.Location)'. This playbook reports them rather than creating the alert, because the mapping was resolved empirically and has not been confirmed against published documentation." `
        -Remediation 'Review the candidates in the evidence file, then create a metric alert on the throttling metric at subscription scope. Route it to the same action group as the cost alerts.' `
        -Evidence $found `
        -Reference 'https://learn.microsoft.com/azure/azure-monitor/essentials/metrics-custom-overview' | Out-Null
}

Export-ModuleMember -Function @(
    'Invoke-GatewayGuardrails'
    'Test-MetricCardinality'
    'Get-GatewayCallerMappings'
    'Test-EmergencyStopControl'
    'Test-TokenLimitPolicy'
    'Test-ThrottledSeriesMetric'
)

