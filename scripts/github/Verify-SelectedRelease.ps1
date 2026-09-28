#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SelectionDirectory,
    [Parameter(Mandatory)][string]$ExpectedProfileHash,
    [Parameter(Mandatory)][string]$ExpectedBundleFingerprint,
    [Parameter(Mandatory)][string]$ExpectedSelectionHash,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$RequireWorkflowContext
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Oci.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Verification requires a new output directory.' }
$profile = Read-EnvironmentProfile -Path (Join-Path $SelectionDirectory 'profile.json')
$selection = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $SelectionDirectory 'selected.json') -Raw)
$platformInputs = Read-PlatformInputs -Path (Join-Path $SelectionDirectory 'platform.json')
$unsignedSelection = @{}
foreach ($key in $selection.Keys) { if ($key -cne 'hash') { $unsignedSelection[$key] = $selection[$key] } }
if ($selection.hash -cne $ExpectedSelectionHash -or (Get-CanonicalHash -Value $unsignedSelection) -cne $ExpectedSelectionHash -or
    (Get-CanonicalHash -Value $platformInputs) -cne $selection.platformHash) { throw 'Selection or approved platform inputs changed.' }
if ($selection.schemaVersion -ne 1 -or $selection.profileHash -cne $ExpectedProfileHash -or (Get-CanonicalHash -Value $profile) -cne $ExpectedProfileHash -or $selection.bundleFingerprint -cne $ExpectedBundleFingerprint) {
    throw 'Selected configuration or release changed before privileged execution.'
}
$repoName = $profile.github.repository
if ($RequireWorkflowContext -and ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne $profile.github.protectedRef -or $env:GITHUB_REPOSITORY -ine $repoName -or [long]$env:GITHUB_REPOSITORY_ID -ne $profile.github.repositoryId)) {
    throw 'This job is not an approved repository/ref dispatch.'
}
$repository = Invoke-GitHubJson "repos/$repoName"
$workflow = Invoke-GitHubJson "repos/$repoName/actions/workflows/bicep-validate.yml"
$run = Invoke-GitHubJson "repos/$repoName/actions/runs/$($profile.release.runId)"
Assert-TrustedReleaseRun -Profile $profile -Repository $repository -Workflow $workflow -Run $run
if ($selection.configurationSha) {
    if ($selection.configurationSha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid immutable configuration reference.' }
    $file = Invoke-GitHubJson "repos/$repoName/contents/environments/$($profile.environment).json?ref=$($selection.configurationSha)"
    if ($file.type -cne 'file' -or $file.encoding -cne 'base64' -or $file.size -gt 1MB) { throw 'Configuration source is unavailable or invalid.' }
    $sourceProfile = ConvertFrom-BootstrapJson -Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($file.content)))
    if ((Get-CanonicalHash -Value $sourceProfile) -cne $ExpectedProfileHash) { throw 'Configuration source changed after selection.' }
    $platformFile = Invoke-GitHubJson "repos/$repoName/contents/environments/$($profile.environment).platform.json?ref=$($selection.configurationSha)"
    if ($platformFile.type -cne 'file' -or $platformFile.encoding -cne 'base64' -or $platformFile.size -gt 1MB) { throw 'Platform input source is unavailable or invalid.' }
    $sourcePlatform = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($platformFile.content))
    $sourcePlatformInputs = Read-PlatformInputs -Json $sourcePlatform
    if ((Get-CanonicalHash -Value $sourcePlatformInputs) -cne $selection.platformHash) { throw 'Platform input source changed after selection.' }
}
$readinessArguments = @{ Profile=$profile; PlatformInputs=$platformInputs }
if ($RequireWorkflowContext -and $profile.github.runner.mode -ceq 'existing-private') {
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) { throw 'The executing private runner identity is unavailable.' }
    $readinessArguments.CurrentRunnerName = $env:RUNNER_NAME
}
$null = Assert-GitHubBootstrapReadiness @readinessArguments
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$bundlePath = Join-Path $OutputDirectory 'bundle'
$artifact = Save-GitHubArtifact -Repository $repoName -RunId $profile.release.runId -ArtifactName $profile.release.artifactName -Destination $bundlePath
if ($artifact.id -ne $selection.releaseArtifact.id -or $artifact.digest -cne $selection.releaseArtifact.digest) { throw 'Selected CI archive identity changed.' }
$null = Test-ReleaseBundle -BundlePath $bundlePath -ExpectedRelease $profile.release -ExpectedFingerprint $ExpectedBundleFingerprint
$null = Test-OciArchive -Path (Join-Path $bundlePath 'image.oci.tar') -ExpectedDigest $profile.release.imageDigest
foreach ($required in @('scripts/github/Environment.psm1', 'scripts/github/Invoke-EnvironmentDeployment.ps1', 'environments/schema.json', 'main.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $bundlePath 'payload') $required) -PathType Leaf)) { throw 'Verified bundle lacks a required deployment entry point.' }
}
if ($profile.environment -cne 'dev') {
    if (-not $selection.priorPromotion) { throw 'Prior-environment evidence is missing.' }
    $prior = Receive-PromotionEvidence -Profile $profile -Repository $repository -RunId $selection.priorPromotion.runId -ReleaseFingerprint $ExpectedBundleFingerprint -Destination (Join-Path $OutputDirectory 'prior-promotion')
    if ((Get-CanonicalHash -Value $prior) -cne (Get-CanonicalHash -Value $selection.priorPromotion)) { throw 'Prior-environment evidence changed after selection.' }
}
Copy-Item -LiteralPath (Join-Path $SelectionDirectory 'profile.json') -Destination (Join-Path $OutputDirectory 'profile.json')
Copy-Item -LiteralPath (Join-Path $SelectionDirectory 'selected.json') -Destination (Join-Path $OutputDirectory 'selected.json')
Copy-Item -LiteralPath (Join-Path $SelectionDirectory 'platform.json') -Destination (Join-Path $OutputDirectory 'platform.json')
Write-Output "Verified selected payload before Azure authentication: $ExpectedBundleFingerprint."
