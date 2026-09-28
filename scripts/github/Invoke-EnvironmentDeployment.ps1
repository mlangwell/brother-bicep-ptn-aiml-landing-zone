#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Deploy', 'Complete')][string]$Phase = 'Preview',
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$SelectionPath,
    [Parameter(Mandatory)][string]$PlatformInputsPath,
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$PreviewDirectory,
    [string]$ApprovedPreviewHash,
    [string]$InfrastructureDirectory,
    [switch]$Execute,
    [switch]$EnablePaidProbes,
    [int]$MaxProbeRequests = 0,
    [long]$MaxProbeTokens = 0
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Oci.psm1')
Import-Module (Join-Path $PSScriptRoot 'Gateway.psm1')
Import-Module (Join-Path $PSScriptRoot 'Completion.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')
Import-Module (Join-Path $PSScriptRoot '..\..\platform\policy\Governance.psm1')
if ($Phase -cne 'Preview' -and (-not $Execute -or $ApprovedPreviewHash -cnotmatch '^[a-f0-9]{64}$' -or -not $PreviewDirectory)) {
    throw 'Mutation requires explicit Execute and the exact approved preview hash/directory.'
}
if ($EnablePaidProbes -and ($Phase -cne 'Complete' -or $MaxProbeRequests -le 0 -or $MaxProbeTokens -le 0)) { throw 'Paid probes require the completion phase and explicit positive request/token ceilings.' }
if ($env:PREFLIGHT_SKIP -in @('true', '1') -or $env:LZ_PREFLIGHT_REGIONAL_SKIP -in @('true', '1')) { throw 'Protected delivery does not permit preflight bypasses.' }
$ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
$SelectionPath = [IO.Path]::GetFullPath($SelectionPath)
$PlatformInputsPath = [IO.Path]::GetFullPath($PlatformInputsPath)
$BundlePath = [IO.Path]::GetFullPath($BundlePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($PreviewDirectory) { $PreviewDirectory = [IO.Path]::GetFullPath($PreviewDirectory) }
if ($InfrastructureDirectory) { $InfrastructureDirectory = [IO.Path]::GetFullPath($InfrastructureDirectory) }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new phase evidence directory; existing evidence is immutable.' }
$profile = Read-EnvironmentProfile -Path $ProfilePath
$resolved = Resolve-EnvironmentProfile -Profile $profile
if (-not $resolved.parameters.parameters.Contains('aiFoundryAccountName') -or
    [string]::IsNullOrWhiteSpace([string]$resolved.parameters.parameters.aiFoundryAccountName.value)) {
    throw 'The governed GitHub path requires an explicit parameters.aiFoundryAccountName for pre-deployment backend validation.'
}
$backendName = [string]$resolved.parameters.parameters.aiFoundryAccountName.value
$backendId = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$backendName"
$backendEndpoint = "https://$backendName.openai.azure.com/"
Assert-GatewayConfiguration -Profile $profile -ServiceName $profile.gateway.name -BackendAccountResourceId $backendId -BackendEndpoint $backendEndpoint
$selection = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath $SelectionPath -Raw)
$platformInputs = Read-PlatformInputs -Path $PlatformInputsPath
$platformHash = Get-CanonicalHash -Value $platformInputs
if ($selection.platformHash -cne $platformHash) { throw 'Selection and platform inputs differ.' }
if ($selection.profileHash -cne (Get-CanonicalHash -Value $profile) -or $selection.environment -cne $profile.environment) { throw 'Selection and profile differ.' }
$bundle = Test-ReleaseBundle -BundlePath $BundlePath -ExpectedRelease $profile.release -ExpectedFingerprint $selection.bundleFingerprint
$repo = Invoke-GitHubJson "repos/$($profile.github.repository)"
$workflow = Invoke-GitHubJson "repos/$($profile.github.repository)/actions/workflows/bicep-validate.yml"
$run = Invoke-GitHubJson "repos/$($profile.github.repository)/actions/runs/$($profile.release.runId)"
Assert-TrustedReleaseRun -Profile $profile -Repository $repo -Workflow $workflow -Run $run
$account = ConvertFrom-BootstrapJson -Json (Invoke-CheckedNative -Command az -Arguments @('account', 'show', '--only-show-errors', '--output', 'json'))
$identityPhase = if ($Phase -ceq 'Preview') { 'Preview' } else { 'Deploy' }
Assert-AzureDeploymentIdentity -Profile $profile -Phase $identityPhase -Account $account
$null = Assert-PreparedDeploymentFoundation -Profile $profile -PlatformInputs $platformInputs
$governanceRequest = New-BootstrapGovernanceRequest -Profile $profile
$governanceReady = Assert-GovernanceDeploymentReadiness -Profile $profile -BillingCurrency $platformInputs.governance.billingCurrency -Request $governanceRequest
if ($governanceReady -isnot [bool] -or -not $governanceReady) { throw 'Deployed governance was not verified against the approved profile.' }
$request = New-EnvironmentArmRequest -Profile $profile
$payload = Join-Path $BundlePath 'payload'
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

if ($Phase -ceq 'Complete') {
    if (-not $InfrastructureDirectory) { throw 'Completion requires the exact preceding infrastructure evidence directory.' }
    $preview = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $PreviewDirectory 'preview.json') -Raw)
    $parameters = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $PreviewDirectory 'main.parameters.json') -Raw)
    Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $parameters -BundleFingerprint $bundle.fingerprint -ObservedState $preview.observedState -ApprovedHash $ApprovedPreviewHash -PlatformHash $platformHash
    $infrastructure = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $InfrastructureDirectory 'infrastructure.json') -Raw)
    if ($infrastructure.previewHash -cne $preview.hash -or $infrastructure.bundleFingerprint -cne $bundle.fingerprint -or $infrastructure.status -cne 'Succeeded') { throw 'Infrastructure evidence does not match the approved release.' }
    $outputPath = Join-Path $InfrastructureDirectory 'completion-input.json'
    if ((Get-FileHash -LiteralPath $outputPath).Hash.ToLowerInvariant() -cne $infrastructure.outputHash) { throw 'Deployment outputs changed before completion.' }
    $output = Read-DeveloperCompletionOutput -Path $outputPath
    if ($output.gateway.backendResourceId -ine $backendId -or $output.gateway.backendEndpoint -cne $backendEndpoint) { throw 'Actual Foundry backend differs from the approved explicit binding.' }
    $gatewayPlan = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $PreviewDirectory 'gateway-plan.json') -Raw)
    if ($preview.gatewayPlanHash -cne (Get-CanonicalHash -Value $gatewayPlan)) { throw 'Approved gateway plan changed before completion.' }
    # Classic VNet injection has no inbound private endpoint to verify. The
    # equivalent evidence is that the instance really is Internal-mode, injected
    # into the approved subnet, and carrying the approved stop control.
    $gatewayEvidence = Complete-GatewayActivation -Plan $gatewayPlan -Request $request `
        -Apply -StopNewRequests $profile.gateway.stopNewRequests -Confirm:$false
    if ($gatewayEvidence.status -cne 'VerifiedControlPlane' -or $gatewayEvidence.virtualNetworkType -cne 'Internal' -or
        $gatewayEvidence.stopControlVerified -ne $true -or $gatewayEvidence.stopNewRequests -ne $profile.gateway.stopNewRequests) {
        throw 'Gateway injected private topology and the approved stop control were not verified.'
    }
    Write-JsonFile -Path (Join-Path $OutputDirectory 'gateway.json') -Value $gatewayEvidence
    $completion = Invoke-DeveloperCompletion -Resolution $resolved -DeploymentOutput $output -Execute
    $workflowRunId = if ($env:GITHUB_RUN_ID) { [long]$env:GITHUB_RUN_ID } else { 0L }
    $live = Invoke-LiveDeveloperGate -Resolution $resolved -DeploymentOutput $output -ExecutePaidProbes:$EnablePaidProbes `
        -ApprovedEnvironment $profile.environment -ApprovedSourceSha $profile.release.sourceSha `
        -MaxRequests $MaxProbeRequests -MaxTotalTokens $MaxProbeTokens -IdentityContext runner `
        -ReleaseFingerprint $bundle.fingerprint -WorkflowRunId $workflowRunId
    $record = @{
        schemaVersion=1; environment=$profile.environment; workflowRunId=$workflowRunId
        releaseFingerprint=$bundle.fingerprint; configurationHash=$preview.parameterHash
        profileHash=$preview.profileHash; previewHash=$preview.hash
        status='InfrastructureAndPrivateCompletionVerified'; completion=$completion; liveGate=$live
    }
    Write-JsonFile -Path (Join-Path $OutputDirectory 'deployment.json') -Value $record
    Write-Output 'Infrastructure image and private configuration verified. Human, enforcement, cost-routing and recovery evidence remains separately gated; no promotion eligibility is implied.'
    exit 0
}

$state = Get-GatewayObservedState -Profile $profile
# InjectionSubnetResourceId is deliberately NOT passed here. The always-true
# invariants (Internal mode, an injection subnet present, no private endpoint)
# are still asserted by Get-GatewayDeploymentPlan. The additional exact-subnet
# match is only meaningful for a landing-zone-created gateway: on the BYO path
# the gateway lives in the platform VNet and this orchestrator has no reliable
# knowledge of that subnet. Asserting against a guessed ID would be worse than
# not asserting at all.
$gatewayPlan = Get-GatewayDeploymentPlan -ServiceResourceId $state.resourceId -EnvironmentName $profile.environment `
    -WorkloadKey $profile.gateway.workloadKey -Request $request
$parameters = Get-DeploymentParameters -Resolved $resolved -ObservedState $state
if ($parameters.parameters.apiManagementConfiguration.value.initialProvisioning -ne $gatewayPlan.initialProvisioning) { throw 'Gateway state planners disagree; resolve ownership/completion before proceeding.' }
Write-JsonFile -Path (Join-Path $OutputDirectory 'main.parameters.json') -Value $parameters
Write-JsonFile -Path (Join-Path $OutputDirectory 'gateway-plan.json') -Value $gatewayPlan
$parameterPath = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'main.parameters.json'))
Push-Location $payload
try {
    & pwsh -NoProfile -NonInteractive -File (Join-Path $payload 'scripts\Invoke-PreflightChecks.ps1') -SubscriptionId $profile.azure.subscriptionId -ParametersFile $parameterPath
    if ($LASTEXITCODE -ne 0) { throw 'Selected-release preflight failed.' }
} finally { Pop-Location }
if ($Phase -ceq 'Preview') {
    $version = ConvertFrom-BootstrapJson -Json (Invoke-CheckedNative -Command az -Arguments @('version', '--output', 'json'))
    if ([version]$version['azure-cli'] -lt [version]'2.76.0') { throw 'Constrained ProviderNoRbac preview requires Azure CLI 2.76.0 or newer.' }
    $whatIf = ConvertFrom-BootstrapJson -Json (Invoke-CheckedNative -Command az -Arguments @(
        'deployment', 'group', 'what-if', '--subscription', $profile.azure.subscriptionId,
        '--resource-group', $profile.azure.resourceGroup, '--template-file', (Join-Path $payload 'main.json'),
        '--parameters', "@$parameterPath", '--validation-level', 'ProviderNoRbac', '--no-pretty-print', '--only-show-errors', '--output', 'json'
    ))
    if ($whatIf.status -cne 'Succeeded') { throw 'Azure What-If did not succeed.' }
    $summary = @{
        status=$whatIf.status; profileHash=(Get-CanonicalHash -Value $profile); parameterHash=(Get-CanonicalHash -Value $parameters)
        valuesRedacted=$true
        changes=@($whatIf.changes | ForEach-Object { @{ resourceId=$_.resourceId; changeType=$_.changeType; propertyPaths=@($_.delta | ForEach-Object { $_.path }) } })
    }
    $preview = New-PreviewRecord -Profile $profile -Parameters $parameters -BundleFingerprint $bundle.fingerprint -ObservedState $state `
        -WhatIfHash (Get-CanonicalHash -Value $whatIf) -GatewayPlanHash (Get-CanonicalHash -Value $gatewayPlan) -WhatIfSummary $summary -PlatformHash $platformHash
    Write-JsonFile -Path (Join-Path $OutputDirectory 'what-if-summary.json') -Value $summary
    Write-JsonFile -Path (Join-Path $OutputDirectory 'preview.json') -Value $preview
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "preview_hash=$($preview.hash)" -Encoding utf8 }
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "Preview hash: ``$($preview.hash)``. Resolved inputs: ``$($preview.parameterHash)``. Review the preview artifact and selected source/configuration; values are redacted from the change summary." -Encoding utf8
    }
    Write-Output "Preview recorded: $($preview.hash). This is not authorization to deploy."
    exit 0
}

$preview = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $PreviewDirectory 'preview.json') -Raw)
Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $parameters -BundleFingerprint $bundle.fingerprint -ObservedState $state -ApprovedHash $ApprovedPreviewHash -PlatformHash $platformHash
$approvedGatewayPlan = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $PreviewDirectory 'gateway-plan.json') -Raw)
if ($preview.gatewayPlanHash -cne (Get-CanonicalHash -Value $approvedGatewayPlan)) { throw 'Approved gateway plan was altered.' }
if ((Get-CanonicalHash -Value $approvedGatewayPlan) -cne (Get-CanonicalHash -Value $gatewayPlan)) { throw 'Owned gateway APIs/configuration changed after preview.' }
Assert-GatewayDeploymentPlan -Plan $approvedGatewayPlan -Request $request
$image = Import-ReleaseImage -Resolved $resolved -BundlePath $BundlePath -Execute -Confirm:$false
Write-JsonFile -Path (Join-Path $OutputDirectory 'image.json') -Value $image
$deploymentName = "ailz-$($profile.environment)-$($profile.release.runId)-$($profile.release.runAttempt)"
$deployment = ConvertFrom-BootstrapJson -Json (Invoke-CheckedNative -Command az -Arguments @(
    'deployment', 'group', 'create', '--subscription', $profile.azure.subscriptionId, '--resource-group', $profile.azure.resourceGroup,
    '--name', $deploymentName, '--mode', 'Incremental', '--template-file', (Join-Path $payload 'main.json'),
    '--parameters', "@$parameterPath", '--only-show-errors', '--output', 'json'
))
if ($deployment.properties.provisioningState -cne 'Succeeded') { throw 'Infrastructure deployment did not succeed.' }
$output = $deployment.properties.outputs.DEVELOPER_COMPLETION.value
if (-not $output -or $output.schemaVersion -ne 1) { throw 'Deployment lacks the opt-in private completion output.' }
$outputPath = Join-Path $OutputDirectory 'completion-input.json'
Write-JsonFile -Path $outputPath -Value $output
Write-JsonFile -Path (Join-Path $OutputDirectory 'infrastructure.json') -Value @{
    schemaVersion=1; status='Succeeded'; deploymentName=$deploymentName; previewHash=$preview.hash; bundleFingerprint=$bundle.fingerprint
    outputHash=(Get-FileHash -LiteralPath $outputPath).Hash.ToLowerInvariant()
}
Write-Output 'Infrastructure finished. Refresh the scoped deployment login, then run the Complete phase; this is not developer readiness.'
