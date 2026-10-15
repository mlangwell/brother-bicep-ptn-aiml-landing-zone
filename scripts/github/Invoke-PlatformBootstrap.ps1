#Requires -Version 7.0
<#
.SYNOPSIS
Inspect and plan platform bootstrap; apply only an explicitly approved saved plan.
.DESCRIPTION
Plan is the default, even when GitHub/Azure credentials exist. A blocked plan is
saved for inspection and exits nonzero. No workflow is dispatched.

Foundation requires PlatformInputs.foundation, not a completed P1 profile. It
creates only separately named managed identities and returns observed IDs.
Other stages consume Read/Resolve-EnvironmentProfile without changing its schema.

The network foundation is an explicitly pre-existing administrator-prepared
spoke, not a dependency of full main provisioning. Profiles must select
useExistingVNet=true, existingVnetResourceId, deploySubnets=false and
hubIntegrationCreateHubPeering=false. Supply the prepared ACA/PE subnet
names/prefixes, hub VNet, existing route-table ID, and existing ACR DNS zone.
Omit hubIntegrationEgressNextHopIp from that profile to preserve P1's routing
mutex; the approved next hop is PlatformInputs.network.egress.expectedNextHopIp.
Run approved Network and Access preparation before CD. Access assigns the
workload UAI AcrPull on the existing private registry before main, not afterward.
The private phase calls Assert-PreparedDeploymentFoundation -Profile $profile
-PlatformInputs $inputs before preview/main to verify connected peering, DNS,
approved ACA/PE subnet NSG fingerprints, registry TLS and pull RBAC. Both inputs
must come from the immutable approved configuration, not local .azure state.
That gate performs no image import; a missing-image preview block requires a
separately approved pre-import decision.

P5's hosted select job calls Assert-GitHubBootstrapReadiness -Profile $profile
-PlatformInputs $inputs with GitHub-only reads. Existing-private reuse requires
approved runnerId/runnerName/VM/NIC bindings and NSG fingerprints in that file.
After OIDC login on the private runner, Assert-PreparedDeploymentFoundation
uses RUNNER_NAME and performs the actual Azure checks before What-If/main.

An execution uses the existing PlanPath, never silently replaces it with a new
plan, and requires Execute plus ApprovedPlanHash plus ShouldProcess. Replanning
is mandatory after any configuration, ownership or remote-state change.

CompletionPath is the actual DEVELOPER_COMPLETION value, not ARM expressions or
a handwritten copy of runtime settings. Evidence never claims live readiness.

Governance is a separate privileged stage (also included in All). It consumes
PlatformInputs.governance.billingCurrency as independently observed billing
evidence, reuses P3's exact parameter/resource renderer and frozen ownership
plan, and reconciles only those owned definition/assignment/budget IDs. A
successful resource PUT is not readiness: P3's GET-only exact-state assertion
must pass afterward, including the live budget currentSpend.unit. Source files,
parameters, prior state hashes and budget eTag are bound into the saved plan.
No installed-control or notification-delivery claim comes from profile values.
.EXAMPLE
.\Invoke-PlatformBootstrap.ps1 -ProfilePath .\dev.json -PlatformInputsPath .\platform.json -Stage Environments -PlanPath .\environment-plan.json
.EXAMPLE
.\Invoke-PlatformBootstrap.ps1 -ProfilePath .\dev.json -PlatformInputsPath .\platform.json -PlanPath .\environment-plan.json -Execute -ApprovedPlanHash <inspected-lowercase-sha256>
.EXAMPLE
.\Invoke-PlatformBootstrap.ps1 -PlatformInputsPath .\platform.json -Stage Foundation -PlanPath .\foundation-plan.json
.EXAMPLE
.\Invoke-PlatformBootstrap.ps1 -ProfilePath .\dev.json -PlatformInputsPath .\platform.json -Stage Governance -PlanPath .\governance-plan.json
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ProfilePath,
    [Parameter(Mandatory)][string]$PlatformInputsPath,
    [ValidateSet('All', 'Foundation', 'Environments', 'Federation', 'Runner', 'Network', 'Access', 'Completion', 'Governance')]
    [string]$Stage = 'All',
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$CompletionPath,
    [string]$EvidencePath,
    [switch]$Execute,
    [string]$ApprovedPlanHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -ErrorAction Stop

try {
    if ($Execute -and $ApprovedPlanHash -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Execute requires ApprovedPlanHash with the exact inspected lowercase SHA256.'
    }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $planFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PlanPath)
    $inputPaths = @($PlatformInputsPath, $ProfilePath, $CompletionPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($inputPath in $inputPaths) {
        $inputFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inputPath)
        if ($planFullPath.Equals($inputFullPath, $comparison)) { throw 'PlanPath cannot overwrite a profile, platform input or completion artifact.' }
    }
    if ($Execute -and -not $EvidencePath) { $EvidencePath = "$PlanPath.evidence.json" }
    if ($EvidencePath) {
        $evidenceFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidencePath)
        foreach ($inputPath in @($inputPaths) + @($PlanPath)) {
            $inputFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inputPath)
            if ($evidenceFullPath.Equals($inputFullPath, $comparison)) { throw 'EvidencePath cannot overwrite the inspected plan or its inputs.' }
        }
    }
    $inputs = Read-PlatformInputs -Path $PlatformInputsPath
    $plan = $null
    if ($Execute) {
        $plan = Read-BootstrapJsonFile -Path $PlanPath
        if ($PSBoundParameters.ContainsKey('Stage') -and $Stage -ine $plan.stage) { throw 'Stage differs from the inspected saved plan.' }
        $Stage = $plan.stage
    }
    $resolved = $null
    if ($Stage -ine 'Foundation') {
        if (-not $ProfilePath) { throw 'ProfilePath is required except for the separate foundation stage.' }
        $profile = Read-EnvironmentProfile -Path $ProfilePath
        $resolved = Resolve-EnvironmentProfile -Profile $profile
    }
    elseif ($CompletionPath) { throw 'Foundation cannot consume deployment completion output.' }
    $completion = if ($CompletionPath) { Read-BootstrapJsonFile -Path $CompletionPath } else { $null }
    if (-not $Execute) {
        $plan = if ($Stage -ieq 'Foundation') {
            New-BootstrapFoundationPlan -PlatformInputs $inputs
        }
        else {
            New-PlatformBootstrapPlan -ResolvedEnvironment $resolved -PlatformInputs $inputs -Stage $Stage -Completion $completion
        }
        Write-JsonFile -Path $PlanPath -Value $plan
        Write-Host "Bootstrap plan: $($plan.planHash); status: $($plan.status); operations: $($plan.operations.Count)."
        if ($plan.status -eq 'blocked') {
            foreach ($blocker in $plan.blockers) { Write-Warning "$($blocker.code): $($blocker.target) -- $($blocker.requirement)" }
            exit 1
        }
        exit 0
    }
    if ($PSCmdlet.ShouldProcess("$($plan.environment)/$($plan.stage)", "Apply inspected bootstrap plan $ApprovedPlanHash")) {
        $result = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $resolved -PlatformInputs $inputs -Completion $completion -Execute -ApprovedPlanHash $ApprovedPlanHash -Confirm:$false
    }
    else { $result = @{ status = 'notExecuted'; planHash = $plan.planHash; liveReady = $false } }
    Write-JsonFile -Path $EvidencePath -Value $result
    Write-Host "Bootstrap result: $($result.status). Live deployment readiness is not certified."
    exit 0
}
catch {
    if ($EvidencePath -and $_.Exception.Data.Contains('BootstrapEvidence')) {
        Write-JsonFile -Path $EvidencePath -Value $_.Exception.Data['BootstrapEvidence']
    }
    $code = 1
    if ($_.Exception.Message -match 'Native process failed with exit code ([1-9][0-9]*)\.') { $code = [int]$Matches[1] }
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit $code
}
