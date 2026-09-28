#Requires -Version 7.0
<#
.SYNOPSIS
    Post-deployment AI guardrails for the Brother AI Landing Zone: responsible
    defaults for cost, policy, quota and access.

.DESCRIPTION
    Runs AFTER the landing zone is deployed, as part of the delivery playbook.
    It closes the gaps the Bicep template deliberately leaves open, and it
    verifies - rather than duplicates - what the template already owns.

    THE ONE THING TO UNDERSTAND BEFORE RUNNING THIS

    Azure has no native hard spend cap for AI. Microsoft says so in writing:

      "While OpenAI has an option for hard limits that prevent you from going
       over your budget, Azure OpenAI doesn't currently provide this
       functionality."

    So this script does not create a spend cap, because one does not exist to
    create. The only real-time hard stop is the APIM token limit, which the
    landing zone already deploys and which this script VERIFIES. Everything
    else here is either a deployment gate (policy), a throughput ceiling
    (quota), or a smoke detector (budgets, anomaly alerts, daily cap).

    EXECUTION ORDER IS DELIBERATE

      plane 4  cost and logging     zero risk, cannot block a deployment
      plane 3  gateway              read-only verification
      plane 2  Foundry control      subscription-level quota settings
      plane 1  policy               CAN block deployments - staged last
      plane 0  access               the role is handed out only once the
                                    SKU ceilings from plane 1 exist

    That is safest-first, blocking-last. It is also why the script refuses to
    create the custom role if the policy plane was skipped: the role and the
    ceilings are two halves of one guardrail, and half of it is worse than
    none, because it looks finished.

.PARAMETER EnvFile
    Path to the .env file. Defaults to .env beside this script.

.PARAMETER Apply
    Perform writes. WITHOUT THIS THE SCRIPT WRITES NOTHING - it reports exactly
    what it would do. Run it without -Apply first, read the output, then run it
    again with -Apply.

.PARAMETER Plane
    Restrict the run to specific planes. Accepts Cost, Gateway, Foundry,
    Policy, Access. Defaults to all.

.PARAMETER Bootstrap
    Generate .env from .env.example before running, so a clean checkout needs no
    hand-editing. Every setting resolves through one ladder, first non-empty
    wins: explicit parameter, environment variable, existing .env, discovery
    from the signed-in `az` context, prompt.

    Tenant, subscription, resource group, region, assignment prefix, APIM
    instance, Log Analytics workspace and Foundry account are all discovered.
    Only three values are decisions rather than facts and cannot be: who hears
    about spend (-CostAlertEmails), what "too much" means here
    (-SubscriptionBudgetAmount), and who gets the role (-RoleAssignPrincipalIds,
    where blank is the recommended first answer).

    An existing .env is NEVER overwritten without -Force; it is reported and
    reused, so re-running converges instead of clobbering.

.PARAMETER Force
    With -Bootstrap, regenerate an existing .env. Values already in that file
    are carried over, including settings the bootstrap does not manage, so a
    hand-tuned ceiling is not reset to the template default.

.PARAMETER NonInteractive
    Never prompt. A required value with nothing to supply it becomes a named
    failure rather than a hang. Redirected stdin and the usual CI variables
    imply this already; the switch is for forcing it.

.EXAMPLE
    ./Invoke-AiGuardrails.ps1 -Bootstrap -CostAlertEmails ai-alerts@contoso.com -SubscriptionBudgetAmount 2500
    One command from a clean checkout: discovers the estate, writes .env, then
    dry runs every plane against it. Writes nothing to Azure.

.EXAMPLE
    ./Invoke-AiGuardrails.ps1 -Bootstrap -NonInteractive -Apply
    The CI shape. Every value must already be a parameter or an environment
    variable; anything missing fails by name instead of waiting for a human.

.EXAMPLE
    ./Invoke-AiGuardrails.ps1
    Dry run against the target in .env. Writes nothing.

.EXAMPLE
    ./Invoke-AiGuardrails.ps1 -Plane Cost,Gateway
    Dry run of the zero-risk cost plane and the read-only gateway assertions.

.EXAMPLE
    ./Invoke-AiGuardrails.ps1 -Apply -Plane Cost
    Apply phase 0 only: tag inheritance, anomaly alert, saved cost view,
    action group and the Log Analytics daily cap.

.NOTES
    Idempotent. Every action reads current state first and is skipped when the
    desired state already holds, so reruns converge rather than duplicate.

    ARM completion is not compliance. A policy assignment existing does not
    mean the estate is compliant, and a budget existing does not mean spend is
    capped. The evidence file records configuration, nothing more.
#>

[CmdletBinding()]
param(
    [string]$EnvFile,

    [switch]$Apply,

    [ValidateSet('Cost', 'Gateway', 'Foundry', 'Policy', 'Access')]
    [string[]]$Plane = @('Cost', 'Gateway', 'Foundry', 'Policy', 'Access'),

    [switch]$Bootstrap,

    [switch]$Force,

    [switch]$NonInteractive,

    # Bootstrap inputs. Presence, not value, decides the top rung of the
    # resolution ladder, so an explicitly supplied empty string still counts as
    # an answer. Supplying any of these without -Bootstrap is refused rather
    # than silently ignored.
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$AssignmentPrefix,
    [string]$ProjectName,
    [string]$EnvironmentName,
    [string]$GatewayOwner,
    [string]$ApimName,
    [string]$LogAnalyticsWorkspace,
    [string]$FoundryAccountName,
    [string[]]$CostAlertEmails,
    [double]$SubscriptionBudgetAmount,
    [string[]]$RoleAssignPrincipalIds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
if (-not $EnvFile) { $EnvFile = Join-Path $scriptRoot '.env' }

$modulePath = Join-Path $scriptRoot 'modules'
foreach ($module in @('Common', 'Bootstrap', 'Cost', 'Gateway', 'Foundry', 'Policy', 'Access')) {
    Import-Module (Join-Path $modulePath "Guardrails.$module.psm1") -Force -DisableNameChecking
}

$bootstrapParameters = @(
    'TenantId', 'SubscriptionId', 'ResourceGroup', 'Location', 'AssignmentPrefix'
    'ProjectName', 'EnvironmentName', 'GatewayOwner', 'ApimName'
    'LogAnalyticsWorkspace', 'FoundryAccountName', 'CostAlertEmails'
    'SubscriptionBudgetAmount', 'RoleAssignPrincipalIds'
)

function Get-GuardrailConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Map)

    $policyScope = (Get-EnvValue -Map $Map -Key 'POLICY_SCOPE' -Default 'subscription').ToLowerInvariant()
    if ($policyScope -notin @('resourcegroup', 'subscription')) {
        throw "POLICY_SCOPE must be 'resourcegroup' or 'subscription', got '$policyScope'."
    }

    $policyEffect = Get-EnvValue -Map $Map -Key 'POLICY_EFFECT' -Default 'Deny'
    if ($policyEffect -notin @('Audit', 'Deny', 'Disabled')) {
        throw "POLICY_EFFECT must be Audit, Deny or Disabled, got '$policyEffect'."
    }

    $quotaPolicy = Get-EnvValue -Map $Map -Key 'FOUNDRY_QUOTA_TIER_POLICY' -Default 'NoAutoUpgrade'
    if ($quotaPolicy -notin @('NoAutoUpgrade', 'OnceUpgradeIsAvailable', 'skip')) {
        throw "FOUNDRY_QUOTA_TIER_POLICY must be NoAutoUpgrade, OnceUpgradeIsAvailable or skip, got '$quotaPolicy'."
    }

    $capGb = [double](Get-EnvValue -Map $Map -Key 'LOG_ANALYTICS_DAILY_CAP_GB' -Default '50')
    if ($capGb -ne -1 -and $capGb -lt 0.023) {
        throw "LOG_ANALYTICS_DAILY_CAP_GB must be at least 0.023 (the platform minimum) or -1 for unlimited, got $capGb."
    }

    $budgetAmount = [double](Get-EnvValue -Map $Map -Key 'SUBSCRIPTION_BUDGET_AMOUNT' -Default '1000')
    if ($budgetAmount -le 0) {
        throw "SUBSCRIPTION_BUDGET_AMOUNT must be greater than zero, got $budgetAmount. A zero or negative budget alerts on everything and is indistinguishable from a misconfiguration."
    }

    return @{
        TenantId            = Get-EnvValue -Map $Map -Key 'AZ_TENANT_ID' -Required
        SubscriptionId      = Get-EnvValue -Map $Map -Key 'AZ_SUBSCRIPTION_ID' -Required
        ResourceGroup       = Get-EnvValue -Map $Map -Key 'AZ_RESOURCE_GROUP' -Required
        Location            = Get-EnvValue -Map $Map -Key 'AZ_LOCATION' -Required
        ProjectName         = Get-EnvValue -Map $Map -Key 'PROJECT_NAME' -Default 'ai-platform'
        Environment         = Get-EnvValue -Map $Map -Key 'ENVIRONMENT' -Default 'dev'
        AssignmentPrefix    = Get-EnvValue -Map $Map -Key 'ASSIGNMENT_PREFIX' -Required

        # plane 0
        RoleEnabled            = Get-EnvBool  -Map $Map -Key 'ROLE_ENABLED' -Default $true
        RoleName               = Get-EnvValue -Map $Map -Key 'ROLE_NAME' -Default 'AI Innovator (Cost-Bounded)'
        RoleDescription        = Get-EnvValue -Map $Map -Key 'ROLE_DESCRIPTION' -Default 'Deploy and operate AI workload resources within approved cost ceilings.'
        RoleAssignableScope    = Get-EnvValue -Map $Map -Key 'ROLE_ASSIGNABLE_SCOPE' -Default 'subscription'
        RoleAllowedProviders   = Get-EnvList  -Map $Map -Key 'ROLE_ALLOWED_PROVIDERS'
        RoleExtraProviders     = Get-EnvList  -Map $Map -Key 'ROLE_EXTRA_PROVIDERS'
        RoleAssignPrincipalIds = Get-EnvList  -Map $Map -Key 'ROLE_ASSIGN_PRINCIPAL_IDS'
        # The role is only half a control. This requires the other half to be
        # not merely SELECTED but actually IN FORCE before the role is created.
        # Setting it false is a deliberate, recorded choice to accept a role
        # whose ceilings do not block anything.
        RoleRequireEnforcingCeilings = Get-EnvBool -Map $Map -Key 'ROLE_REQUIRE_ENFORCING_CEILINGS' -Default $true

        # plane 1
        PolicyScope                  = $policyScope
        PolicyEffect                 = $policyEffect
        RequiredTags                 = Get-EnvList -Map $Map -Key 'REQUIRED_TAGS' -Default @('environment', 'owner')
        AllowedLocations             = Get-EnvList -Map $Map -Key 'ALLOWED_LOCATIONS'
        DeniedResourceTypes          = Get-EnvList -Map $Map -Key 'DENIED_RESOURCE_TYPES'
        FoundryMaxDeploymentCapacity = Get-EnvInt  -Map $Map -Key 'FOUNDRY_MAX_DEPLOYMENT_CAPACITY' -Default 50 -Minimum 1
        FoundryAllowedDeploymentSkus = Get-EnvList -Map $Map -Key 'FOUNDRY_ALLOWED_DEPLOYMENT_SKUS' -Default @('GlobalStandard', 'DataZoneStandard', 'Standard')
        FoundryAllowedAccountSkus    = Get-EnvList -Map $Map -Key 'FOUNDRY_ALLOWED_ACCOUNT_SKUS' -Default @('S0', 'F0')
        FoundryDenyDynamicThrottling = Get-EnvBool -Map $Map -Key 'FOUNDRY_DENY_DYNAMIC_THROTTLING' -Default $true
        FoundryAllowedPublishers     = Get-EnvList -Map $Map -Key 'FOUNDRY_ALLOWED_PUBLISHERS'
        FoundryAllowedAssetIds       = Get-EnvList -Map $Map -Key 'FOUNDRY_ALLOWED_ASSET_IDS'
        SearchAllowedSkus            = Get-EnvList -Map $Map -Key 'SEARCH_ALLOWED_SKUS' -Default @('basic', 'standard')
        SearchMaxReplicas            = Get-EnvInt  -Map $Map -Key 'SEARCH_MAX_REPLICAS' -Default 2 -Minimum 1
        SearchMaxPartitions          = Get-EnvInt  -Map $Map -Key 'SEARCH_MAX_PARTITIONS' -Default 2 -Minimum 1
        FabricAllowedSkus            = Get-EnvList -Map $Map -Key 'FABRIC_ALLOWED_SKUS' -Default @('F2', 'F4', 'F8')
        CosmosMaxThroughputRu        = Get-EnvInt  -Map $Map -Key 'COSMOS_MAX_THROUGHPUT_RU' -Default 4000 -Minimum 400
        AmlAllowedVmSizes            = Get-EnvList -Map $Map -Key 'AML_ALLOWED_VM_SIZES' -Default @('Standard_DS3_v2', 'Standard_DS11_v2', 'Standard_D4s_v3', 'Standard_E4s_v3')
        AcrAllowedSkus               = Get-EnvList -Map $Map -Key 'ACR_ALLOWED_SKUS' -Default @('Basic', 'Standard')
        # Distinct from LOG_ANALYTICS_DAILY_CAP_GB (plane 4). That one SETS the
        # cap on one named workspace; this one is the policy CEILING every
        # workspace in scope must stay at or under. Keep this >= that, or the
        # script's own plane-4 workspace fails its own plane-1 ceiling.
        LogAnalyticsPolicyMaxDailyGb = Get-EnvInt  -Map $Map -Key 'LOG_ANALYTICS_POLICY_MAX_DAILY_GB' -Default 50 -Minimum 1
        AcaAllowedWorkloadProfileTypes = Get-EnvList -Map $Map -Key 'ACA_ALLOWED_WORKLOAD_PROFILE_TYPES' -Default @('Consumption', 'D4', 'D8')
        AcaMaxReplicas               = Get-EnvInt  -Map $Map -Key 'ACA_MAX_REPLICAS' -Default 10 -Minimum 1
        StorageAllowedSkus           = Get-EnvList -Map $Map -Key 'STORAGE_ALLOWED_SKUS' -Default @('Standard_LRS', 'Standard_ZRS', 'Standard_GRS')

        # plane 2
        FoundryAccountName    = Get-EnvValue -Map $Map -Key 'FOUNDRY_ACCOUNT_NAME'
        FoundryQuotaTierPolicy = $quotaPolicy
        FoundryQuotaApiVersion = Get-EnvValue -Map $Map -Key 'FOUNDRY_QUOTA_API_VERSION' -Default '2026-07-01'

        # plane 3
        ApimName                    = Get-EnvValue -Map $Map -Key 'APIM_NAME'
        ApimResourceGroup           = Get-EnvValue -Map $Map -Key 'APIM_RESOURCE_GROUP'
        GatewayOwner                = Get-EnvValue -Map $Map -Key 'GATEWAY_OWNER' -Default 'ailz'
        GatewayMetricNamespace      = Get-EnvValue -Map $Map -Key 'GATEWAY_METRIC_NAMESPACE' -Default 'ailz-inference'
        GatewayExpectedEnvironments = Get-EnvInt -Map $Map -Key 'GATEWAY_EXPECTED_ENVIRONMENTS' -Default 3 -Minimum 1
        GatewayExpectedProjects     = Get-EnvInt -Map $Map -Key 'GATEWAY_EXPECTED_PROJECTS' -Default 10 -Minimum 1
        GatewayExpectedModels       = Get-EnvInt -Map $Map -Key 'GATEWAY_EXPECTED_MODELS' -Default 5 -Minimum 1
        GatewayExpectedCallers      = Get-EnvInt -Map $Map -Key 'GATEWAY_EXPECTED_CALLERS' -Default 6 -Minimum 1

        # plane 4
        LogAnalyticsWorkspace        = Get-EnvValue -Map $Map -Key 'LOG_ANALYTICS_WORKSPACE'
        LogAnalyticsResourceGroup    = Get-EnvValue -Map $Map -Key 'LOG_ANALYTICS_RESOURCE_GROUP'
        LogAnalyticsDailyCapGb       = $capGb
        LogAnalyticsEnablePrecapAlert = Get-EnvBool -Map $Map -Key 'LOG_ANALYTICS_ENABLE_PRECAP_ALERT' -Default $true
        CostAlertEmails              = Get-EnvList  -Map $Map -Key 'COST_ALERT_EMAILS'
        SubscriptionBudgetEnabled    = Get-EnvBool  -Map $Map -Key 'SUBSCRIPTION_BUDGET_ENABLED' -Default $true
        SubscriptionBudgetAmount     = $budgetAmount
        ActionGroupName              = Get-EnvValue -Map $Map -Key 'ACTION_GROUP_NAME' -Default 'ag-ai-cost-alerts'
        ActionGroupShortName         = Get-EnvValue -Map $Map -Key 'ACTION_GROUP_SHORT_NAME' -Default 'aicost'
        CostAnomalyAlertEnabled      = Get-EnvBool  -Map $Map -Key 'COST_ANOMALY_ALERT_ENABLED' -Default $true
        CostAnomalyAlertName         = Get-EnvValue -Map $Map -Key 'COST_ANOMALY_ALERT_NAME' -Default 'ai-cost-anomaly'
        CostViewEnabled              = Get-EnvBool  -Map $Map -Key 'COST_VIEW_ENABLED' -Default $true
        CostViewName                 = Get-EnvValue -Map $Map -Key 'COST_VIEW_NAME' -Default 'ai-platform-total-cost'
        TagInheritanceEnabled        = Get-EnvBool  -Map $Map -Key 'TAG_INHERITANCE_ENABLED' -Default $true
        TagInheritancePreferContainerTags = Get-EnvBool -Map $Map -Key 'TAG_INHERITANCE_PREFER_CONTAINER_TAGS' -Default $false

        # run behaviour
        EvidencePath = Get-EnvValue -Map $Map -Key 'EVIDENCE_PATH' -Default './evidence'
        FailFast     = Get-EnvBool  -Map $Map -Key 'FAIL_FAST' -Default $false
    }
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Host ' AI GUARDRAILS - post-deployment responsible defaults' -ForegroundColor Cyan
Write-Host ('=' * 78) -ForegroundColor DarkCyan

# Redirected stdin, azd hooks without `interactive: true`, and CI agents all
# mean nobody is there to answer. Detect it rather than hanging on a prompt that
# no one will ever see.
$noPrompting = $NonInteractive.IsPresent -or -not (Test-GuardrailInteractive)

if ($Bootstrap) {
    $EnvFile = Invoke-GuardrailBootstrap `
        -ScriptRoot $scriptRoot `
        -EnvFile $EnvFile `
        -Parameters $PSBoundParameters `
        -Force:$Force `
        -NonInteractive:$noPrompting
}
else {
    # Refuse rather than ignore. A caller who passed -SubscriptionBudgetAmount
    # without -Bootstrap believes they set it; silently running against whatever
    # .env already says would be the wrong number reported as the right one.
    $supplied = @($bootstrapParameters | Where-Object { $PSBoundParameters.ContainsKey($_) })
    if ($Force) { $supplied += 'Force' }
    if ($supplied.Count -gt 0) {
        throw @"
REFUSING TO RUN - bootstrap-only parameter(s) supplied without -Bootstrap.

  $($supplied -join ', ')

These only take effect while generating .env. Without -Bootstrap the run reads
'$EnvFile' as it stands, so honouring them would be impossible and ignoring them
would report the wrong configuration as the right one.

Add -Bootstrap to generate .env from these values, or drop them to run against
the file as it is.
"@
    }
}

$envMap = Import-GuardrailEnvironment -Path $EnvFile
$config = Get-GuardrailConfiguration -Map $envMap

Initialize-GuardrailRun -Apply $Apply.IsPresent -FailFast $config.FailFast

# ---------------------------------------------------------------------------
# Configuration refusals. These are pure local checks, so they run BEFORE the
# Azure pre-flight: a combination that can never be safe should not cost a round
# trip to discover, and keeping them offline means they can be tested without a
# subscription.
# ---------------------------------------------------------------------------
$runsPolicy = $Plane -contains 'Policy'
$runsAccess = $Plane -contains 'Access'

# The role without the ceilings is worse than neither, because it looks
# finished. Refuse rather than ship half a guardrail.
if ($runsAccess -and -not $runsPolicy -and $config.RoleEnabled) {
    throw @"
REFUSING TO RUN - incomplete guardrail.

The custom role controls WHICH resource types can be created. It cannot control
SKU, size or capacity, because RBAC has no visibility of request-body
properties. The plane 1 SKU-ceiling policies are the other half of the control.

Creating the role without them would let its holders deploy an F2048 Fabric
capacity, a 12x12 AI Search service and an unbounded Foundry deployment - and
it would look finished while doing it.

Either include Policy in -Plane, or set ROLE_ENABLED=false.
"@
}

# Selecting both planes is necessary but NOT sufficient. The role is scoped by
# ROLE_ASSIGNABLE_SCOPE and the ceilings by POLICY_SCOPE; if the role is broader
# than the ceilings, its holders can simply build outside the policed scope -
# create a fresh resource group, deploy there, and no ceiling ever evaluates.
# That defeats the pairing even when every ceiling is set to Deny.
if ($runsAccess -and $config.RoleEnabled -and
    $config.RoleAssignableScope -eq 'subscription' -and $config.PolicyScope -ne 'subscription') {
    throw @"
REFUSING TO RUN - the role is scoped wider than its ceilings.

  ROLE_ASSIGNABLE_SCOPE = $($config.RoleAssignableScope)
  POLICY_SCOPE          = $($config.PolicyScope)

The role would grant create rights across the whole subscription while the SKU
ceilings evaluate only one resource group. The role also carries
Microsoft.Resources/subscriptions/resourceGroups/write, so a holder can create a
new resource group and deploy into it with no ceiling in scope at all.

Set POLICY_SCOPE=subscription so the ceilings follow the role, or narrow
ROLE_ASSIGNABLE_SCOPE to the resource group.
"@
}

# Pre-flight. Fails closed on a tenant, subscription or resource-group mismatch
# before anything is written. This is the cross-engagement guard and it is not
# optional.
Write-Host ''
Write-Host ' Pre-flight' -ForegroundColor Cyan
$target = Assert-GuardrailTarget `
    -ExpectedTenantId $config.TenantId `
    -ExpectedSubscriptionId $config.SubscriptionId `
    -ResourceGroup $config.ResourceGroup

Write-Host ("  Subscription : {0} ({1})" -f $target.SubscriptionName, $target.SubscriptionId) -ForegroundColor Gray
Write-Host ("  Tenant       : {0}" -f $target.TenantId) -ForegroundColor Gray
Write-Host ("  Signed in as : {0}" -f $target.User) -ForegroundColor Gray
Write-Host ("  Resource grp : {0} ({1})" -f $target.ResourceGroup, $target.Location) -ForegroundColor Gray
Write-Host ("  Project      : {0} / {1}" -f $config.ProjectName, $config.Environment) -ForegroundColor Gray

if ($Apply) {
    Write-Host ''
    Write-Host '  MODE: APPLY - this run will write to Azure.' -ForegroundColor Yellow
}
else {
    Write-Host ''
    Write-Host '  MODE: DRY RUN - nothing will be written. Re-run with -Apply to act.' -ForegroundColor Cyan
}

$planeOrder = @(
    @{ Key = 'Cost';    Label = '4-Cost and logging (zero risk)' }
    @{ Key = 'Gateway'; Label = '3-Gateway (read-only verification)' }
    @{ Key = 'Foundry'; Label = '2-Foundry control plane' }
    @{ Key = 'Policy';  Label = '1-Azure Policy (can block deployments)' }
    @{ Key = 'Access';  Label = '0-Access (custom role)' }
)

$exitCode = 0
try {
    foreach ($entry in $planeOrder) {
        if ($Plane -notcontains $entry.Key) { continue }

        Write-Host ''
        Write-Host (' {0}' -f $entry.Label) -ForegroundColor Cyan
        Write-Host (' ' + ('-' * 76)) -ForegroundColor DarkGray

        switch ($entry.Key) {
            'Cost'    { Invoke-CostGuardrails    -Config $config -Target $target }
            'Gateway' { Invoke-GatewayGuardrails -Config $config -Target $target }
            'Foundry' { Invoke-FoundryGuardrails -Config $config -Target $target }
            'Policy'  { Invoke-PolicyGuardrails  -Config $config -Target $target -RootPath $scriptRoot }
            'Access'  {
                # The pre-flight refusal above checked that Policy was SELECTED.
                # It cannot know whether Policy SUCCEEDED. The two planes need
                # different permissions, so a caller with rights to create a role
                # but not to create policy definitions reaches this point with a
                # clean selection and zero ceilings - exactly the half-built
                # state the refusal exists to prevent. Check the outcome.
                # Assign before filtering. Get-GuardrailResults returns `, @(...)`
                # so that an assignment receives the array intact - but that same
                # comma makes a DIRECT pipe hand Where-Object the whole array as
                # a single object, where `$_.Plane -eq '1-Policy'` becomes a
                # member enumeration that is truthy whenever ANY result matches.
                # Piped straight in, this gate fired on a failure in any other
                # plane, and threw while rendering its own message.
                $allResults = Get-GuardrailResults
                $ceilingFailures = @($allResults |
                    Where-Object { $_.Plane -eq '1-Policy' -and $_.Status -eq 'Failed' })

                if ($config.RoleEnabled -and $ceilingFailures.Count -gt 0) {
                    $names = ($ceilingFailures | Select-Object -ExpandProperty Name -Unique) -join ', '
                    throw @"
REFUSING TO CREATE THE ROLE - the ceilings did not apply.

$($ceilingFailures.Count) policy-plane action(s) failed: $names

The role and the SKU ceilings are two halves of one control. The Policy plane was
selected and ran, but it did not succeed, so creating the role now would hand out
create rights with nothing bounding SKU, size or capacity.

This is usually a permissions gap: the Policy plane needs Resource Policy
Contributor, and the Access plane needs Owner or User Access Administrator. Having
rights for one does not imply the other.

Fix the failures above and re-run, or set ROLE_ENABLED=false.
"@
                }

                # Ceilings that exist but do not enforce are not ceilings. Audit
                # assignments deploy with enforcementMode=DoNotEnforce: they report
                # and block nothing. Deny is the default, so reaching this means
                # somebody opted into Audit - which is legitimate when retrofitting
                # an existing subscription, but it must be chosen, not stumbled into.
                if ($config.RoleEnabled -and $config.RoleRequireEnforcingCeilings -and
                    $config.PolicyEffect -ne 'Deny') {
                    throw @"
REFUSING TO CREATE THE ROLE - the ceilings are not enforcing.

  POLICY_EFFECT = $($config.PolicyEffect)

At this effect the assignments deploy with enforcementMode=DoNotEnforce. They
evaluate and report; they block nothing. A role paired with non-enforcing ceilings
is the same unbounded grant as a role with no ceilings at all - it just looks
finished.

POLICY_EFFECT=Deny is the default, so something set this. If that was deliberate -
retrofitting these ceilings onto a subscription that already has running workloads,
where a soak is genuinely needed - set ROLE_REQUIRE_ENFORCING_CEILINGS=false and
accept that the role is unbounded until you flip to Deny. Otherwise remove the
override and re-run.
"@
                }

                Invoke-AccessGuardrails -Config $config -Target $target -RootPath $scriptRoot
            }
        }
    }
}
finally {
    $evidenceRoot = if ([System.IO.Path]::IsPathRooted($config.EvidencePath)) {
        $config.EvidencePath
    }
    else {
        Join-Path $scriptRoot $config.EvidencePath
    }

    Write-GuardrailReport -Target $target -EvidencePath $evidenceRoot -Applied $Apply.IsPresent | Out-Null

    $results = Get-GuardrailResults
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    if ($failed.Count -gt 0) { $exitCode = 1 }

    if (-not $Apply) {
        $pending = @($results | Where-Object { $_.Status -eq 'WouldApply' })
        Write-Host (" {0} change(s) pending. Re-run with -Apply to make them." -f $pending.Count) -ForegroundColor Cyan
        Write-Host ''
    }
}

exit $exitCode
