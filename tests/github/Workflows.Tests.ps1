#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml -RequiredVersion 0.4.12
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$count = 0
function Assert-Workflow([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Read-Workflow([string]$Name) {
    ConvertFrom-Yaml -Yaml (Get-Content (Join-Path $root ".github\workflows\$Name") -Raw)
}
$ci = Read-Workflow 'bicep-validate.yml'
Assert-Workflow ($ci.permissions.contents -ceq 'read' -and -not $ci.permissions.Contains('pull-requests') -and -not $ci.permissions.Contains('id-token')) 'CI must be credential-free and must not receive write permissions.'
foreach ($event in @('push', 'pull_request')) {
    foreach ($path in @('scripts/**', 'tests/github/**', 'environments/**', 'platform/**', 'samples/developer-smoke/**', '.github/workflows/**', 'package.json')) {
        Assert-Workflow ($path -cin $ci.on[$event].paths) "Missing validation trigger coverage: $event / $path"
    }
}
foreach ($job in $ci.jobs.Values) {
    Assert-Workflow ($job.'runs-on' -ceq 'ubuntu-latest') 'Untrusted CI must never use the private pool.'
    foreach ($step in $job.steps) {
        if ($step.Contains('uses')) { Assert-Workflow ($step.uses -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[a-f0-9]{40}$') 'An action is not commit-pinned.' }
    }
}
Assert-Workflow ($ci.jobs.'release-bundle'.if -match "event_name == 'push'" -and $ci.jobs.'release-bundle'.if -match 'default_branch') 'Release publication is not restricted to the trusted push ref.'
Assert-Workflow ('build-and-measure' -cin $ci.jobs.'release-bundle'.needs -and 'validate-copilot-assets' -cin $ci.jobs.'release-bundle'.needs) 'Release can bypass required CI jobs.'
$ciText = Get-Content (Join-Path $root '.github\workflows\bicep-validate.yml') -Raw
Assert-Workflow ($ciText -notmatch 'releases/latest|az login|azure/login@') 'Credential-free CI uses an unpinned release or Azure credentials.'
Assert-Workflow ($ciText -match 'provenance: false' -and $ciText -match 'sbom: false' -and $ciText -match 'platforms: linux/amd64' -and $ciText -match 'type=oci') 'The tested image must be a single preserved OCI artifact.'

$dispatch = Read-Workflow 'deploy-environment.yml'
Assert-Workflow (@($dispatch.on.Keys).Count -eq 1 -and $dispatch.on.Contains('workflow_dispatch')) 'CD must be manual-only.'
Assert-Workflow ($dispatch.on.workflow_dispatch.inputs.environment.type -ceq 'choice') 'CD environment selection must be constrained.'
Assert-Workflow ($dispatch.jobs.deploy.uses -ceq './.github/workflows/deploy-environment-reusable.yml') 'CD must use the shared implementation.'
Assert-Workflow ($dispatch.concurrency.'cancel-in-progress' -eq $false) 'In-progress environment mutations must not be cancelled.'

$reusable = Read-Workflow 'deploy-environment-reusable.yml'
Assert-Workflow (@($reusable.on.Keys).Count -eq 1 -and $reusable.on.Contains('workflow_call')) 'Reusable deployment must not add automatic triggers.'
Assert-Workflow (-not $reusable.permissions.Contains('id-token')) 'Reusable defaults must not expose OIDC to selection.'
Assert-Workflow ($reusable.jobs.select.'runs-on' -ceq 'ubuntu-latest' -and $reusable.jobs.select.if -match "event_name == 'workflow_dispatch'") 'Untrusted callers can reach private runners.'
Assert-Workflow ($reusable.jobs.preview.needs -contains 'select') 'Private preview lacks the credential-free selection gate.'
Assert-Workflow ($reusable.jobs.preview.environment -ceq '${{ inputs.environment }}-preview') 'Preview environment must be separate from deployment approval.'
Assert-Workflow ($reusable.jobs.deploy.environment -ceq '${{ inputs.environment }}') 'Deployment must use its protected environment.'
foreach ($jobName in @('preview', 'deploy')) {
    $job = $reusable.jobs[$jobName]
    Assert-Workflow ($job.permissions.'id-token' -ceq 'write') 'Trusted Azure jobs require explicitly scoped OIDC.'
    Assert-Workflow ($job.'runs-on'.group -match 'needs.select.outputs.runner_group' -and $job.'runs-on'.labels -match 'runner_labels') 'Deployment cannot silently substitute a public runner.'
    $steps = @($job.steps)
    $verification = -1
    $login = -1
    for ($index = 0; $index -lt $steps.Count; $index++) {
        if ($steps[$index].id -ceq 'verify') { $verification = $index }
        if ($steps[$index].Contains('uses')) {
            Assert-Workflow ($steps[$index].uses -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[a-f0-9]{40}$') 'Deployment action is not commit-pinned.'
            if ($steps[$index].uses -cmatch '^azure/login@') { $login = $index }
        }
    }
    Assert-Workflow ($verification -ge 0 -and $login -gt $verification) 'Artifact provenance must be checked before acquiring Azure credentials.'
}
$reusableText = Get-Content (Join-Path $root '.github\workflows\deploy-environment-reusable.yml') -Raw
Assert-Workflow ($reusableText -match 'Verify-SelectedRelease.ps1' -and $reusableText -match 'Invoke-EnvironmentDeployment.ps1') 'Workflow does not invoke its verified shared implementation.'
Assert-Workflow ($reusableText -match 'prior_promotion_run_id' -and $reusableText -match 'configuration_sha') 'Cross-run promotion or immutable configuration identity is missing.'
Assert-Workflow ($reusableText -notmatch 'continue-on-error: true|cancel-in-progress: true|pull_request_target') 'Delivery contains a fail-open or unsafe trigger.'
$deploymentScript = Get-Content (Join-Path $root 'scripts\github\Invoke-EnvironmentDeployment.ps1') -Raw
Assert-Workflow ($deploymentScript -match 'ProviderNoRbac' -and $deploymentScript -match 'Assert-PreviewRecord' -and $deploymentScript -match 'Resolve-EnvironmentProfile') 'Preview/deploy must share typed inputs and check the frozen approval.'
Assert-Workflow ($deploymentScript -match 'Import-ReleaseImage' -and $deploymentScript -match 'EnablePaidProbes') 'Image promotion or the explicit paid-probe boundary is missing.'
$verifyScript = Get-Content (Join-Path $root 'scripts\github\Verify-SelectedRelease.ps1') -Raw
Assert-Workflow ($verifyScript -match 'CurrentRunnerName\s*=\s*\$env:RUNNER_NAME' -and $verifyScript -match '\$RequireWorkflowContext') 'A running approved private worker must be reverified as the current runner, not require a spare idle worker.'
$probe = Read-Workflow 'oidc-probe.yml'
Assert-Workflow (@($probe.on.Keys).Count -eq 1 -and $probe.on.Contains('workflow_dispatch')) 'OIDC claim capture must be explicitly dispatched.'
Assert-Workflow (-not $probe.permissions.Contains('id-token') -and $probe.jobs.capture.permissions.'id-token' -ceq 'write') 'Only the trusted claim-capture job may request OIDC.'
Assert-Workflow ($probe.jobs.capture.needs -contains 'prepare' -and $probe.jobs.capture.'runs-on' -ceq 'ubuntu-latest') 'Claim capture requires the pre-existing protection gate, not a private bootstrap runner.'
$probeText = Get-Content (Join-Path $root '.github\workflows\oidc-probe.yml') -Raw
Assert-Workflow ($probeText -match 'Export-OidcClaims.ps1' -and $probeText -notmatch 'azure/login@|az login|ExecutePaidProbes|Invoke-EnvironmentDeployment') 'OIDC capture must not deploy or make model calls.'
Write-Host "Workflows: $count assertions passed."
