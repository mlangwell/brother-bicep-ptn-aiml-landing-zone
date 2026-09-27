#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Plane 4 - logging and cost management. Smoke detectors, not sprinklers.

.DESCRIPTION
    Say this plainly to anyone who inherits this: NOTHING in this module stops
    spend.

      budgets            alert 8-24h after the fact, plus ~1h to evaluate
      anomaly detection  runs ~36h after end of day
      daily cap          stops INGESTION, not spend - overshoot is still
                         billed, and when it fires you go blind

    It is all necessary and none of it is a control. The control is the gateway
    token limit in plane 3.

    OWNERSHIP BOUNDARY: the landing-zone Bicep owns the budget and its
    contactGroups. This module VERIFIES the budget and never writes to it. It
    creates the action group - which Bicep does not own - and prints the
    resource ID for an operator to paste into the environment JSON, so Bicep
    stays the single owner of the budget.
#>

$ErrorActionPreference = 'Stop'

$script:CostManagementApiVersion = '2026-06-01'
$script:BudgetApiVersion = '2024-08-01'
$script:ScheduledQueryApiVersion = '2023-12-01'

# The anomaly alert is only rendered in the portal when its viewId carries this
# identifier. An alert created without it works but is invisible in the UI,
# which makes it unmanageable by anyone who did not create it.
$script:AnomalyViewName = 'ms:DailyAnomalyByResourceGroup'

function Invoke-CostGuardrails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target
    )

    $plane = '4-Cost'

    Add-GuardrailResult -Plane $plane -Name 'No native spend cap (informational)' -Status 'Finding' `
        -Detail 'Azure has no native hard spend cap for AI. The subscription spending limit - the one mechanism that actually halts consumption - is not available on EA or MCA agreements, only on credit-based subscription types, and custom spending limits do not exist.' `
        -Remediation 'Do not let a budget be described as a cap. The real-time hard stop is the APIM token limit in plane 3.' `
        -Reference 'https://learn.microsoft.com/azure/cost-management-billing/manage/spending-limit' | Out-Null

    $actionGroupId = New-CostActionGroup -Config $Config -Target $Target -Plane $plane

    Set-TagInheritance      -Config $Config -Target $Target -Plane $plane
    Set-CostAnomalyAlert    -Config $Config -Target $Target -Plane $plane
    Set-SavedCostView       -Config $Config -Target $Target -Plane $plane
    Test-ExistingBudget     -Config $Config -Target $Target -Plane $plane -ActionGroupId $actionGroupId
    Set-SubscriptionBudget  -Config $Config -Target $Target -Plane $plane -ActionGroupId $actionGroupId
    Set-LogAnalyticsControls -Config $Config -Target $Target -Plane $plane -ActionGroupId $actionGroupId
}

function Set-SubscriptionBudget {
    <#
    .SYNOPSIS
        Create a subscription-scope budget when none exists. Never modifies one.

    .DESCRIPTION
        OWNERSHIP: this is NOT the Bicep-owned budget. The landing-zone template
        owns a RESOURCE-GROUP budget (see Test-ExistingBudget, which only reads
        it). A subscription-scope budget is a different object at a different
        scope that nothing else owns, so creating it here introduces no conflict.

        It exists because the custom role and the SKU ceilings are both
        subscription-scoped: spend can land anywhere in the subscription, so the
        smoke detector has to watch the whole subscription too. A resource-group
        budget cannot see a resource group a role holder creates tomorrow.

        CREATE-ONLY, BY DESIGN. If a budget of this name already exists it is
        reported and left completely alone, whatever its amount. An operator who
        has tuned a threshold should not have it silently reset on the next run.

        A BUDGET IS NOT A CAP. Microsoft: "Resources aren't affected, and your
        consumption isn't stopped." Cost data lags 8-24 hours and budgets
        evaluate about every 24 hours, so this alerts well after the money is
        spent. The only real-time stop in this architecture is the APIM token
        limit in plane 3.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane,
        [string]$ActionGroupId
    )

    if (-not $Config.SubscriptionBudgetEnabled) {
        Add-GuardrailResult -Plane $Plane -Name 'Subscription budget' -Status 'Skipped' `
            -Detail 'SUBSCRIPTION_BUDGET_ENABLED is false.' | Out-Null
        return
    }

    $budgetName = "$($Config.AssignmentPrefix)-subscription"
    $scope = "/subscriptions/$($Target.SubscriptionId)"
    $url = "https://management.azure.com$scope/providers/Microsoft.Consumption/budgets/$budgetName" +
           "?api-version=$script:BudgetApiVersion"

    # A notification needs at least one contact email OR one contact group, and
    # contactGroups is only supported at subscription and resource-group scopes -
    # which is exactly where we are. Sending contactEmails as an empty array with
    # contactGroups populated is Microsoft's own documented CLI shape.
    $contactGroups = @()
    if ($ActionGroupId) { $contactGroups = @($ActionGroupId) }
    $contactEmails = @($Config.CostAlertEmails | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($contactGroups.Count -eq 0 -and $contactEmails.Count -eq 0) {
        Add-GuardrailResult -Plane $Plane -Name 'Subscription budget' -Status 'Failed' `
            -Detail 'A budget notification requires at least one contact group or contact email, and neither is available. The action group was not created and COST_ALERT_EMAILS is empty.' `
            -Remediation 'Set COST_ALERT_EMAILS, or resolve the action group failure above.' | Out-Null
        return
    }

    # startDate must be the first of a month, and a past start date must fall
    # within the timegrain period - so for a Monthly budget that is the first of
    # the CURRENT month. Anything earlier is rejected.
    $now = [datetime]::UtcNow
    $startDate = [datetime]::new($now.Year, $now.Month, 1, 0, 0, 0, [DateTimeKind]::Utc).ToString('yyyy-MM-dd')

    # Documented ceiling is five notifications per budget. Four leaves headroom.
    $thresholds = @(
        @{ Key = 'actual-50';      Threshold = 50.0;  Type = 'Actual' }
        @{ Key = 'actual-80';      Threshold = 80.0;  Type = 'Actual' }
        @{ Key = 'actual-100';     Threshold = 100.0; Type = 'Actual' }
        @{ Key = 'forecasted-100'; Threshold = 100.0; Type = 'Forecasted' }
    )

    $notifications = [ordered]@{}
    foreach ($entry in $thresholds) {
        $notifications[$entry.Key] = [ordered]@{
            enabled       = $true
            operator      = 'GreaterThanOrEqualTo'
            threshold     = $entry.Threshold
            thresholdType = $entry.Type
            contactEmails = $contactEmails
            contactGroups = $contactGroups
        }
    }

    $amount = $Config.SubscriptionBudgetAmount

    Invoke-GuardrailAction -Plane $Plane -Name 'Subscription budget' `
        -WouldDo "Create subscription-scope budget '$budgetName' at $amount per month with $($thresholds.Count) notification(s)" `
        -Reference 'https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets' `
        -Probe {
            $existing = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $existing) { return @{ Compliant = $false; Detail = 'no subscription-scope budget exists' } }

            # Create-only. An existing budget is the operator's, not ours.
            $properties = $existing.properties
            $names = $properties.PSObject.Properties.Name
            $liveAmount = if ($names -contains 'amount') { $properties.amount } else { 'unknown' }
            $liveGrain = if ($names -contains 'timeGrain') { [string]$properties.timeGrain } else { 'unknown' }
            $liveCount = if (($names -contains 'notifications') -and $properties.notifications) {
                @($properties.notifications.PSObject.Properties).Count
            } else { 0 }

            return @{
                Compliant = $true
                Detail = "Budget '$budgetName' already exists: $liveAmount $liveGrain, $liveCount notification(s). Left unchanged - this playbook creates a subscription budget but never edits one."
                Evidence = @{ name = $budgetName; amount = $liveAmount; timeGrain = $liveGrain; notifications = $liveCount; managed = $false }
            }
        } `
        -Action {
            $body = @{
                properties = [ordered]@{
                    category      = 'Cost'
                    amount        = $amount
                    timeGrain     = 'Monthly'
                    timePeriod    = [ordered]@{ startDate = $startDate }
                    notifications = $notifications
                }
            }
            $created = Invoke-AzRestJson -Method put -Url $url -Body $body
            return @{
                id = [string]$created.id
                amount = $amount
                startDate = $startDate
                endDate = 'defaulted by the service to 10 years from start'
                notifications = $thresholds.Count
                routedTo = if ($contactGroups.Count -gt 0) { 'action group' } else { 'contact emails' }
            }
        } | Out-Null

    Add-GuardrailResult -Plane $Plane -Name 'Subscription budget is not a cap' -Status 'Finding' `
        -Detail "A budget alerts; it does not stop anything. Microsoft: `"Resources aren't affected, and your consumption isn't stopped.`" Cost data lags 8-24 hours and budgets evaluate roughly daily, so this fires well after the spend has happened." `
        -Remediation 'Treat it as a smoke detector. The only real-time hard stop is the APIM token limit in plane 3.' `
        -Reference 'https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets' | Out-Null
}

function Set-GuardrailResourceLock {
    <#
    .SYNOPSIS
        Apply a CanNotDelete lock to a guardrail resource.

    .DESCRIPTION
        The custom role grants Microsoft.Insights/* so the team can build their
        own monitoring - which also means they could delete the action group
        and alert rule that watch their spend. Usually not maliciously; usually
        somebody tidying up a resource they do not recognise.

        A notActions entry would be the blunt fix and would cripple legitimate
        alerting work. A CanNotDelete lock is targeted: it blocks deletion,
        still allows updates, and the role cannot remove it, because
        Microsoft.Authorization/*/write is already in its notActions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Plane,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ResourceName,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$Label
    )

    $lockName = "$ResourceName-nodelete"

    Invoke-GuardrailAction -Plane $Plane -Name "Delete lock: $Label" `
        -WouldDo "Apply a CanNotDelete lock to $ResourceType/$ResourceName" `
        -Probe {
            $existing = Invoke-AzCli -AllowNotFound -Arguments @(
                'lock', 'show', '--name', $lockName,
                '--resource-group', $ResourceGroup,
                '--resource-name', $ResourceName,
                '--resource-type', $ResourceType,
                '-o', 'json'
            )
            if ($existing) { return @{ Compliant = $true; Detail = 'lock already present'; Evidence = @{ id = [string]$existing.id } } }
            return @{ Compliant = $false; Detail = 'no delete lock' }
        } `
        -Action {
            $result = Invoke-AzCli -Arguments @(
                'lock', 'create', '--name', $lockName,
                '--lock-type', 'CanNotDelete',
                '--resource-group', $ResourceGroup,
                '--resource-name', $ResourceName,
                '--resource-type', $ResourceType,
                '--notes', 'AI cost guardrail. Removing this lock removes the alerting that watches AI spend.',
                '-o', 'json'
            )
            return @{ id = [string]$result.id }
        } | Out-Null
}

function New-CostActionGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    $name = $Config.ActionGroupName
    $shortName = $Config.ActionGroupShortName
    $expectedId = "$($Target.ResourceGroupId)/providers/Microsoft.Insights/actionGroups/$name"

    if ($shortName.Length -gt 12) {
        Add-GuardrailResult -Plane $Plane -Name 'Action group' -Status 'Failed' `
            -Detail "ACTION_GROUP_SHORT_NAME '$shortName' is $($shortName.Length) characters; the platform limit is 12." | Out-Null
        return $null
    }

    $receiverArgs = @()
    $index = 0
    foreach ($email in $Config.CostAlertEmails) {
        $index++
        $receiverArgs += @('--action', 'email', "cost$index", $email)
    }

    Invoke-GuardrailAction -Plane $Plane -Name 'Cost alert action group' `
        -WouldDo "Create action group '$name' with $($Config.CostAlertEmails.Count) email receiver(s)" `
        -Probe {
            $existing = Invoke-AzCli -AllowNotFound -Arguments @(
                'monitor', 'action-group', 'show',
                '--name', $name, '--resource-group', $Target.ResourceGroup, '-o', 'json'
            )
            if (-not $existing) { return @{ Compliant = $false; Detail = 'action group does not exist' } }

            $liveEmails = @()
            if ($existing.PSObject.Properties.Name -contains 'emailReceivers' -and $existing.emailReceivers) {
                $liveEmails = @($existing.emailReceivers | ForEach-Object { [string]$_.emailAddress })
            }

            $missing = @($Config.CostAlertEmails | Where-Object { $_ -notin $liveEmails })
            if ($missing.Count -eq 0) {
                return @{ Compliant = $true; Detail = "exists with $($liveEmails.Count) receiver(s)"; Evidence = @{ id = [string]$existing.id; emails = $liveEmails } }
            }
            return @{ Compliant = $false; Detail = "missing receiver(s): $($missing -join ', ')"; Evidence = @{ id = [string]$existing.id } }
        } `
        -Action {
            $arguments = @(
                'monitor', 'action-group', 'create',
                '--name', $name,
                '--resource-group', $Target.ResourceGroup,
                '--short-name', $shortName,
                '-o', 'json'
            ) + $receiverArgs

            $result = Invoke-AzCli -Arguments $arguments
            return @{ id = [string]$result.id }
        } | Out-Null

    Set-GuardrailResourceLock -Plane $Plane -ResourceGroup $Target.ResourceGroup `
        -ResourceName $name -ResourceType 'Microsoft.Insights/actionGroups' `
        -Label 'cost alert action group'

    # Tell the operator what to do with it, rather than reaching into the
    # Bicep-owned budget from here.
    Add-GuardrailResult -Plane $Plane -Name 'Wire the action group into the budget' -Status 'Finding' `
        -Detail "The landing-zone Bicep owns the budget and its contactGroups. This playbook will not modify the budget, because two owners for one resource is how drift starts." `
        -Remediation "Add this to governance.budget.contactGroups in the environment JSON and redeploy: $expectedId" `
        -Evidence @{ actionGroupId = $expectedId } | Out-Null

    return $expectedId
}

function Set-TagInheritance {
    <#
    .SYNOPSIS
        Enable Cost Management tag inheritance at subscription scope.

    .DESCRIPTION
        The single highest value-to-risk item in this playbook. One setting, no
        managed identity, no remediation task, cannot block a deployment, and
        it is retroactive to the 1st of the current month.

        It applies billing, resource-group and subscription tags to child
        resource USAGE RECORDS - not to the resources themselves. That is the
        distinction from the Policy tag work, and it is why the two are
        complementary rather than redundant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    if (-not $Config.TagInheritanceEnabled) {
        Add-GuardrailResult -Plane $Plane -Name 'Tag inheritance' -Status 'Skipped' `
            -Detail 'TAG_INHERITANCE_ENABLED is false.' | Out-Null
        return
    }

    $url = "https://management.azure.com/subscriptions/$($Target.SubscriptionId)/providers/Microsoft.CostManagement/settings/taginheritance" +
           "?api-version=$script:CostManagementApiVersion"
    $prefer = $Config.TagInheritancePreferContainerTags

    Invoke-GuardrailAction -Plane $Plane -Name 'Cost Management tag inheritance' `
        -Reference 'https://learn.microsoft.com/azure/cost-management-billing/costs/enable-tag-inheritance' `
        -WouldDo "Enable tag inheritance at subscription scope with preferContainerTags=$prefer" `
        -Probe {
            $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $live) { return @{ Compliant = $false; Detail = 'not enabled' } }

            $current = $null
            if ($live.PSObject.Properties.Name -contains 'properties' -and $live.properties -and
                $live.properties.PSObject.Properties.Name -contains 'preferContainerTags') {
                $current = [bool]$live.properties.preferContainerTags
            }

            if ($null -ne $current -and $current -eq $prefer) {
                return @{ Compliant = $true; Detail = "already enabled (preferContainerTags=$current)"; Evidence = @{ preferContainerTags = $current } }
            }
            return @{ Compliant = $false; Detail = "enabled but preferContainerTags=$current, want $prefer" }
        } `
        -Action {
            $result = Invoke-AzRestJson -Method put -Url $url -Body @{
                kind       = 'taginheritance'
                properties = @{ preferContainerTags = $prefer }
            }
            return @{ preferContainerTags = $prefer; id = [string]$result.id }
        } | Out-Null

    Add-GuardrailResult -Plane $Plane -Name 'Tag inheritance timing' -Status 'Finding' `
        -Detail 'Usage records take 8-24 hours to reflect inherited tags, and the change applies retroactively to the 1st of the current month. Budgets can filter on inherited tags 24 hours after enabling. Supported on EA, MCA and MPA with Azure plan only.' `
        -Remediation 'Do not conclude it failed because Cost Analysis looks unchanged an hour later. Purchases and resources that do not emit usage at subscription scope will not pick up subscription tags at all.' | Out-Null
}

function Set-CostAnomalyAlert {
    <#
    .SYNOPSIS
        Create a cost anomaly alert at subscription scope.

    .DESCRIPTION
        Free, needs no thresholds, and requires no tuning - which makes it more
        durable than a fixed budget for a team that will not revisit
        configuration. It is detection, not control: it runs about 36 hours
        after end of day.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    if (-not $Config.CostAnomalyAlertEnabled) {
        Add-GuardrailResult -Plane $Plane -Name 'Cost anomaly alert' -Status 'Skipped' `
            -Detail 'COST_ANOMALY_ALERT_ENABLED is false.' | Out-Null
        return
    }

    $scope = "subscriptions/$($Target.SubscriptionId)"
    $name = $Config.CostAnomalyAlertName
    $url = "https://management.azure.com/$scope/providers/Microsoft.CostManagement/scheduledActions/$name" +
           "?api-version=$script:CostManagementApiVersion"

    $start = (Get-Date).ToUniversalTime().Date
    $end = $start.AddYears(1)

    # Subject is capped at 70 characters by the API.
    $subject = "Cost anomaly detected - $($Config.ProjectName) $($Config.Environment)"
    if ($subject.Length -gt 70) { $subject = $subject.Substring(0, 70) }

    Invoke-GuardrailAction -Plane $Plane -Name 'Cost anomaly alert' `
        -Reference 'https://learn.microsoft.com/azure/cost-management-billing/understand/analyze-unexpected-charges' `
        -WouldDo "Create anomaly alert '$name' at subscription scope, notifying $($Config.CostAlertEmails -join ', ')" `
        -Probe {
            $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $live) { return @{ Compliant = $false; Detail = 'alert does not exist' } }

            $liveProperties = $live.properties
            $livePropertyNames = $liveProperties.PSObject.Properties.Name
            $status = if ($livePropertyNames -contains 'status') { [string]$liveProperties.status } else { 'unknown' }

            $recipients = @()
            if (($livePropertyNames -contains 'notification') -and $liveProperties.notification -and
                ($liveProperties.notification.PSObject.Properties.Name -contains 'to')) {
                $recipients = @($liveProperties.notification.to)
            }

            $missing = @($Config.CostAlertEmails | Where-Object { $_ -notin $recipients })
            if ($status -eq 'Enabled' -and $missing.Count -eq 0) {
                return @{ Compliant = $true; Detail = "enabled, notifying $($recipients.Count) recipient(s)"; Evidence = @{ status = $status; to = $recipients } }
            }
            return @{ Compliant = $false; Detail = "status=$status, missing recipient(s): $($missing -join ', ')" }
        } `
        -Action {
            $body = @{
                kind       = 'InsightAlert'
                properties = @{
                    displayName  = "$($Config.ProjectName) $($Config.Environment) cost anomaly"
                    status       = 'Enabled'
                    viewId       = "/$scope/providers/Microsoft.CostManagement/views/$script:AnomalyViewName"
                    notification = @{
                        to      = @($Config.CostAlertEmails)
                        subject = $subject
                    }
                    schedule     = @{
                        frequency = 'Daily'
                        startDate = $start.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        endDate   = $end.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                }
            }
            $result = Invoke-AzRestJson -Method put -Url $url -Body $body
            return @{ id = [string]$result.id; expiresOn = $end.ToString('yyyy-MM-dd') }
        } | Out-Null

    Add-GuardrailResult -Plane $Plane -Name 'Anomaly alert caveats' -Status 'Finding' `
        -Detail "Three things that make this alert quietly stop working. (1) It EXPIRES - this one is set to $($end.ToString('yyyy-MM-dd')). (2) Alerts are sent based on the RULE CREATOR'S access at send time, so if the creating identity loses access or leaves, delivery stops silently. (3) Detection runs about 36 hours after end of day, and the email is sent ONCE, at detection." `
        -Remediation "Diarise renewal before $($end.ToString('yyyy-MM-dd')). Create this under a service principal rather than a person where policy allows, and keep the recipient a distribution list. Limits: subscription scope only, max five alerts per subscription, not available in Azure Government or sovereign clouds." | Out-Null
}

function Set-SavedCostView {
    <#
    .SYNOPSIS
        Saved Cost Analysis view at SUBSCRIPTION scope, grouped by service.

    .DESCRIPTION
        This exists to close one specific documented trap. Microsoft: costs for
        sending data to Azure Monitor Logs and alerting "aren't visible when
        scoped just to your Foundry resource".

        Scope Cost Analysis to the Foundry resource and AI looks cheap while
        Log Analytics ingestion accrues invisibly under a different service.
        This view spans both.

        Note also that Azure OpenAI is not a filterable service in Cost
        Analysis - usage appears under the broader Cognitive Services
        classification. Use Service tier: Azure OpenAI, and group by Meter for
        per-model input and output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane
    )

    if (-not $Config.CostViewEnabled) {
        Add-GuardrailResult -Plane $Plane -Name 'Saved cost view' -Status 'Skipped' `
            -Detail 'COST_VIEW_ENABLED is false.' | Out-Null
        return
    }

    $scope = "subscriptions/$($Target.SubscriptionId)"
    $name = $Config.CostViewName
    $url = "https://management.azure.com/$scope/providers/Microsoft.CostManagement/views/$name" +
           "?api-version=$script:CostManagementApiVersion"

    Invoke-GuardrailAction -Plane $Plane -Name 'Saved cost view (subscription scope)' `
        -Reference 'https://learn.microsoft.com/azure/ai-foundry/openai/how-to/manage-costs' `
        -WouldDo "Create saved view '$name' at subscription scope, daily actual cost grouped by service name" `
        -Probe {
            $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $live) { return @{ Compliant = $false; Detail = 'view does not exist' } }
            return @{ Compliant = $true; Detail = 'view already exists'; Evidence = @{ id = [string]$live.id } }
        } `
        -Action {
            $body = @{
                properties = @{
                    displayName = "$($Config.ProjectName) $($Config.Environment) - AI platform total cost"
                    chart       = 'StackedColumn'
                    accumulated = 'false'
                    metric      = 'ActualCost'
                    query       = @{
                        type      = 'ActualCost'
                        timeframe = 'MonthToDate'
                        dataSet   = @{
                            granularity = 'Daily'
                            aggregation = @{
                                totalCost = @{ name = 'Cost'; function = 'Sum' }
                            }
                            grouping    = @(
                                @{ type = 'Dimension'; name = 'ServiceName' }
                            )
                        }
                    }
                }
            }
            $result = Invoke-AzRestJson -Method put -Url $url -Body $body
            return @{ id = [string]$result.id }
        } | Out-Null

    Add-GuardrailResult -Plane $Plane -Name 'Cost Analysis traps' -Status 'Finding' `
        -Detail 'Two traps that make AI look cheaper than it is. (1) Azure OpenAI is not a filterable service - it sits under the broader Cognitive Services classification; use Service tier: Azure OpenAI, and group by Meter for per-model input and output. (2) Scoping to the Foundry resource hides Azure Monitor, Log Analytics and Application Insights cost entirely.' `
        -Remediation 'Use the subscription-scope view this playbook created, and subscribe to it on a schedule (Cost analysis > Subscribe) so it reaches people without them going looking.' | Out-Null
}

function Test-ExistingBudget {
    <#
    .SYNOPSIS
        Verify the Bicep-owned budget. Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane,
        [string]$ActionGroupId
    )

    $budgetName = "$($Config.AssignmentPrefix)-environment"
    $url = "https://management.azure.com$($Target.ResourceGroupId)/providers/Microsoft.Consumption/budgets/$budgetName" +
           "?api-version=$script:BudgetApiVersion"

    $budget = Invoke-AzRestJson -Method get -Url $url -AllowNotFound

    if (-not $budget) {
        Add-GuardrailResult -Plane $Plane -Name 'Budget (Bicep-owned)' -Status 'Finding' `
            -Detail "No budget named '$budgetName' at $($Target.ResourceGroupId). The landing-zone template creates this, so either governance was deployed with enabled=false, or ASSIGNMENT_PREFIX does not match the deployed value." `
            -Remediation 'Deploy platform/governance.bicep with enabled=true, or correct ASSIGNMENT_PREFIX. Do not create the budget from here - Bicep owns it.' | Out-Null
        return
    }

    $notifications = @()
    $budgetProperties = $budget.properties
    $budgetPropertyNames = $budgetProperties.PSObject.Properties.Name

    if (($budgetPropertyNames -contains 'notifications') -and $budgetProperties.notifications) {
        $notifications = @($budgetProperties.notifications.PSObject.Properties)
    }

    $amount = if ($budgetPropertyNames -contains 'amount') { $budgetProperties.amount } else { 'unknown' }
    $category = if ($budgetPropertyNames -contains 'category') { [string]$budgetProperties.category } else { '' }

    $hasActual = $false
    $hasForecast = $false
    $wiredToActionGroup = $false

    foreach ($notification in $notifications) {
        $value = $notification.Value
        if ($null -eq $value) { continue }
        $valueNames = $value.PSObject.Properties.Name

        $thresholdType = if ($valueNames -contains 'thresholdType') { [string]$value.thresholdType } else { 'Actual' }
        if ($thresholdType -eq 'Actual')     { $hasActual = $true }
        if ($thresholdType -eq 'Forecasted') { $hasForecast = $true }

        if ($ActionGroupId -and ($valueNames -contains 'contactGroups') -and $value.contactGroups) {
            foreach ($group in @($value.contactGroups)) {
                if ([string]$group -ieq $ActionGroupId) { $wiredToActionGroup = $true }
            }
        }
    }

    $detail = "Budget '$budgetName' exists: amount $amount $category, $($notifications.Count) notification(s)."
    if ($hasActual -and $hasForecast) {
        Add-GuardrailResult -Plane $Plane -Name 'Budget (Bicep-owned)' -Status 'Compliant' `
            -Detail "$detail Both Actual and Forecasted thresholds are configured, which is the right shape." `
            -Evidence @{ name = $budgetName; amount = $amount; hasActual = $hasActual; hasForecast = $hasForecast } | Out-Null
    }
    else {
        $gap = @()
        if (-not $hasActual)   { $gap += 'Actual' }
        if (-not $hasForecast) { $gap += 'Forecasted' }
        Add-GuardrailResult -Plane $Plane -Name 'Budget (Bicep-owned)' -Status 'Finding' `
            -Detail "$detail Missing threshold type(s): $($gap -join ', ')." `
            -Remediation 'Add the missing threshold in governance.budget in the environment JSON and redeploy.' | Out-Null
    }

    if ($ActionGroupId -and -not $wiredToActionGroup) {
        Add-GuardrailResult -Plane $Plane -Name 'Budget notification routing' -Status 'Finding' `
            -Detail 'The budget does not route to the cost action group, so budget alerts and anomaly alerts reach different places.' `
            -Remediation "Add $ActionGroupId to governance.budget.contactGroups and redeploy." | Out-Null
    }

    Add-GuardrailResult -Plane $Plane -Name 'Budget latency' -Status 'Finding' `
        -Detail 'Cost data is 8-24 hours behind, plus about an hour to evaluate. A budget alert is a backstop, never a real-time control.' `
        -Remediation 'If the budget is ever wired to the gateway emergency stop, present that as a backstop with a day of latency - not as a spend cap.' | Out-Null
}

function Set-LogAnalyticsControls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane,
        [string]$ActionGroupId
    )

    if ([string]::IsNullOrWhiteSpace($Config.LogAnalyticsWorkspace)) {
        Add-GuardrailResult -Plane $Plane -Name 'Log Analytics controls' -Status 'Skipped' `
            -Detail 'LOG_ANALYTICS_WORKSPACE is not set.' | Out-Null
        return
    }

    $workspaceRg = if ([string]::IsNullOrWhiteSpace($Config.LogAnalyticsResourceGroup)) { $Target.ResourceGroup } else { $Config.LogAnalyticsResourceGroup }

    $workspace = Invoke-AzCli -AllowNotFound -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--workspace-name', $Config.LogAnalyticsWorkspace,
        '--resource-group', $workspaceRg, '-o', 'json'
    )

    if (-not $workspace) {
        Add-GuardrailResult -Plane $Plane -Name 'Log Analytics workspace' -Status 'Failed' `
            -Detail "Workspace '$($Config.LogAnalyticsWorkspace)' not found in resource group '$workspaceRg'." | Out-Null
        return
    }

    $workspaceId = [string]$workspace.id
    $capGb = $Config.LogAnalyticsDailyCapGb

    Invoke-GuardrailAction -Plane $Plane -Name 'Log Analytics daily cap' `
        -Reference 'https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap' `
        -WouldDo "Set the daily ingestion cap to $capGb GB/day" `
        -Probe {
            $current = -1
            if ($workspace.PSObject.Properties.Name -contains 'workspaceCapping' -and $workspace.workspaceCapping -and
                $workspace.workspaceCapping.PSObject.Properties.Name -contains 'dailyQuotaGb') {
                $current = [double]$workspace.workspaceCapping.dailyQuotaGb
            }

            if ([math]::Abs($current - $capGb) -lt 0.001) {
                return @{ Compliant = $true; Detail = "already $current GB/day"; Evidence = @{ dailyQuotaGb = $current } }
            }
            $shown = if ($current -lt 0) { 'unlimited' } else { "$current GB/day" }
            return @{ Compliant = $false; Detail = "currently $shown"; Evidence = @{ dailyQuotaGb = $current } }
        } `
        -Action {
            $result = Invoke-AzCli -Arguments @(
                'monitor', 'log-analytics', 'workspace', 'update',
                '--workspace-name', $Config.LogAnalyticsWorkspace,
                '--resource-group', $workspaceRg,
                '--quota', "$capGb",
                '-o', 'json'
            )
            return @{ dailyQuotaGb = $capGb; id = [string]$result.id }
        } | Out-Null

    Add-GuardrailResult -Plane $Plane -Name 'Daily cap semantics' -Status 'Finding' `
        -Detail 'Microsoft is explicit that the daily cap "should not be used as a primary mechanism to filter or reduce data", that it "can''t stop data collection at precisely the specified cap level" so overshoot is still billed, and that when it fires "you are effectively blind to the current state of your monitored environment". No latency figure is published. Auxiliary-plan tables are not subject to any daily cap.' `
        -Remediation 'Treat hitting the cap as an incident, not as cost control working. The actual control is not emitting the data - which the zero-sampling, zero-body-byte APIM diagnostic configuration already does. Protect that configuration rather than adding filtering.' | Out-Null

    $retention = if ($workspace.PSObject.Properties.Name -contains 'retentionInDays') { [int]$workspace.retentionInDays } else { 0 }
    if ($retention -gt 0 -and $retention -lt 31) {
        Add-GuardrailResult -Plane $Plane -Name 'Retention below the free tier' -Status 'Finding' `
            -Detail "Workspace retention is $retention days. 31 days are INCLUDED in the ingestion price, so anything below 31 loses data for zero saving." `
            -Remediation 'Raise retention to at least 31 days. If a strict 30-day privacy requirement applies, set immediatePurgeDataOn30Days instead - otherwise a 30-day workspace may keep data for 31 days anyway.' | Out-Null
    }

    if ($Config.LogAnalyticsEnablePrecapAlert) {
        Set-PrecapAlert -Config $Config -Target $Target -Plane $Plane `
            -WorkspaceId $workspaceId -ActionGroupId $ActionGroupId
    }
}

function Set-PrecapAlert {
    <#
    .SYNOPSIS
        Log search alert on Microsoft's documented pre-cap signal.

    .DESCRIPTION
        The point of this alert is to hear about the cap BEFORE monitoring goes
        dark, because for a team that is not watching a dashboard, "monitoring
        silently stopped" is worse than a cost overrun.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Plane,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [string]$ActionGroupId
    )

    if ([string]::IsNullOrWhiteSpace($ActionGroupId)) {
        Add-GuardrailResult -Plane $Plane -Name 'Daily cap pre-alert' -Status 'Skipped' `
            -Detail 'No action group is available, so the alert would have nowhere to send. Fix the action group first.' | Out-Null
        return
    }

    $name = "$($Config.AssignmentPrefix)-la-overquota"
    $url = "https://management.azure.com$($Target.ResourceGroupId)/providers/Microsoft.Insights/scheduledQueryRules/$name" +
           "?api-version=$script:ScheduledQueryApiVersion"

    # Microsoft's own pre-cap query.
    $query = '_LogOperation | where Category =~ "Ingestion" | where Detail contains "OverQuota"'

    Invoke-GuardrailAction -Plane $Plane -Name 'Daily cap pre-alert' `
        -Reference 'https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap' `
        -WouldDo "Create log search alert '$name' on the documented OverQuota signal, routed to the cost action group" `
        -Probe {
            $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $live) { return @{ Compliant = $false; Detail = 'alert rule does not exist' } }
            $enabled = if ($live.properties.PSObject.Properties.Name -contains 'enabled') { [bool]$live.properties.enabled } else { $false }
            if ($enabled) { return @{ Compliant = $true; Detail = 'alert rule exists and is enabled'; Evidence = @{ id = [string]$live.id } } }
            return @{ Compliant = $false; Detail = 'alert rule exists but is disabled' }
        } `
        -Action {
            $body = @{
                location   = $Target.Location
                properties = @{
                    displayName         = "Log Analytics ingestion over daily cap - $($Config.ProjectName) $($Config.Environment)"
                    description         = 'Fires when the workspace reports OverQuota ingestion. Hitting the daily cap means monitoring is going dark, so treat this as an incident.'
                    severity            = 1
                    enabled             = $true
                    evaluationFrequency = 'PT5M'
                    windowSize          = 'PT5M'
                    scopes              = @($WorkspaceId)
                    criteria            = @{
                        allOf = @(
                            @{
                                query           = $query
                                timeAggregation = 'Count'
                                operator        = 'GreaterThan'
                                threshold       = 0
                                failingPeriods  = @{
                                    numberOfEvaluationPeriods = 1
                                    minFailingPeriodsToAlert  = 1
                                }
                            }
                        )
                    }
                    actions             = @{ actionGroups = @($ActionGroupId) }
                }
            }
            $result = Invoke-AzRestJson -Method put -Url $url -Body $body
            return @{ id = [string]$result.id }
        } | Out-Null

    Set-GuardrailResourceLock -Plane $Plane -ResourceGroup $Target.ResourceGroup `
        -ResourceName $name -ResourceType 'Microsoft.Insights/scheduledQueryRules' `
        -Label 'daily cap pre-alert rule'
}

Export-ModuleMember -Function @(
    'Invoke-CostGuardrails'
    'New-CostActionGroup'
    'Set-GuardrailResourceLock'
    'Set-TagInheritance'
    'Set-CostAnomalyAlert'
    'Set-SavedCostView'
    'Test-ExistingBudget'
    'Set-SubscriptionBudget'
    'Set-LogAnalyticsControls'
    'Set-PrecapAlert'
)
