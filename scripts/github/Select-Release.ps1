#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'LocalProfile')]
param(
    [Parameter(Mandatory, ParameterSetName = 'LocalProfile')][string]$ProfilePath,
    [Parameter(Mandatory, ParameterSetName = 'LocalProfile')][string]$PlatformInputsPath,
    [Parameter(Mandatory, ParameterSetName = 'GitHubProfile')][string]$Repository,
    [Parameter(Mandatory, ParameterSetName = 'GitHubProfile')][string]$ConfigurationSha,
    [Parameter(Mandatory)][long]$ReleaseRunId,
    [long]$PriorPromotionRunId = 0,
    [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$Environment,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$RequireWorkflowContext
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Oci.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Selection directory already exists; use a fresh destination.' }
if ($ReleaseRunId -le 0) { throw 'A specific successful CI run ID is required.' }
if ($RequireWorkflowContext -and ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID))) {
    throw 'Privileged delivery can only follow a trusted manual dispatch, never PR code.'
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$selectedProfilePath = Join-Path $OutputDirectory 'profile.json'
$selectedPlatformPath = Join-Path $OutputDirectory 'platform.json'
if ($PSCmdlet.ParameterSetName -ceq 'GitHubProfile') {
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $ConfigurationSha -cnotmatch '^[a-f0-9]{40}$') { throw 'Configuration must identify a repository and immutable commit.' }
    if ($RequireWorkflowContext -and $Repository -ine $env:GITHUB_REPOSITORY) { throw 'Configuration repository differs from this workflow.' }
    $file = Invoke-GitHubJson "repos/$Repository/contents/environments/$Environment.json?ref=$ConfigurationSha"
    if ($file.type -cne 'file' -or $file.encoding -cne 'base64' -or $file.size -gt 1MB) { throw 'Invalid or oversized environment configuration file.' }
    [IO.File]::WriteAllBytes($selectedProfilePath, [Convert]::FromBase64String($file.content))
    $platformFile = Invoke-GitHubJson "repos/$Repository/contents/environments/$Environment.platform.json?ref=$ConfigurationSha"
    if ($platformFile.type -cne 'file' -or $platformFile.encoding -cne 'base64' -or $platformFile.size -gt 1MB) { throw 'Invalid or oversized platform input file.' }
    [IO.File]::WriteAllBytes($selectedPlatformPath, [Convert]::FromBase64String($platformFile.content))
} else {
    Copy-Item -LiteralPath $ProfilePath -Destination $selectedProfilePath
    Copy-Item -LiteralPath $PlatformInputsPath -Destination $selectedPlatformPath
}
$profile = Read-EnvironmentProfile -Path $selectedProfilePath
$platformInputs = Read-PlatformInputs -Path $selectedPlatformPath
if ($profile.environment -cne $Environment -or $profile.release.runId -ne $ReleaseRunId) { throw 'Environment or release run differs from the supplied profile.' }
$Repository = $profile.github.repository
$repo = Invoke-GitHubJson "repos/$Repository"
if ($ConfigurationSha) {
    $branch = [Uri]::EscapeDataString($profile.github.protectedRef.Substring('refs/heads/'.Length))
    $comparison = Invoke-GitHubJson "repos/$Repository/compare/$ConfigurationSha...$branch"
    if ($comparison.merge_base_commit.sha -cne $ConfigurationSha -or $comparison.status -cnotin @('ahead', 'identical')) {
        throw 'Configuration commit is not on the approved protected branch history.'
    }
}
if ($RequireWorkflowContext) {
    if ($env:GITHUB_REF -cne $profile.github.protectedRef -or [long]$env:GITHUB_REPOSITORY_ID -ne $profile.github.repositoryId) { throw 'Dispatch repository/ref is not approved.' }
    $dispatch = Invoke-GitHubJson "repos/$Repository/actions/runs/$($env:GITHUB_RUN_ID)"
    $dispatchWorkflow = Invoke-GitHubJson "repos/$Repository/actions/workflows/deploy-environment.yml"
    if ($dispatch.workflow_id -ne $dispatchWorkflow.id -or $dispatch.event -cne 'workflow_dispatch' -or $dispatch.head_repository.id -ne $repo.id -or $dispatch.head_sha -cne $env:GITHUB_SHA) {
        throw 'Only the approved manual deployment workflow may schedule private jobs.'
    }
}
$null = Assert-GitHubBootstrapReadiness -Profile $profile -PlatformInputs $platformInputs
$workflow = Invoke-GitHubJson "repos/$Repository/actions/workflows/bicep-validate.yml"
$run = Invoke-GitHubJson "repos/$Repository/actions/runs/$ReleaseRunId"
Assert-TrustedReleaseRun -Profile $profile -Repository $repo -Workflow $workflow -Run $run
$bundlePath = Join-Path $OutputDirectory 'bundle'
$artifact = Save-GitHubArtifact -Repository $Repository -RunId $ReleaseRunId -ArtifactName $profile.release.artifactName -Destination $bundlePath
$bundle = Test-ReleaseBundle -BundlePath $bundlePath -ExpectedRelease $profile.release
$null = Test-OciArchive -Path (Join-Path $bundlePath 'image.oci.tar') -ExpectedDigest $profile.release.imageDigest
$prior = $null
if ($Environment -cne 'dev') {
    $prior = Receive-PromotionEvidence -Profile $profile -Repository $repo -RunId $PriorPromotionRunId -ReleaseFingerprint $bundle.fingerprint -Destination (Join-Path $OutputDirectory 'prior-promotion')
}
$resolved = Resolve-EnvironmentProfile -Profile $profile
$selection = @{
    schemaVersion = 1
    environment = $Environment
    repository = $Repository
    repositoryId = $repo.id
    configurationSha = $ConfigurationSha
    profileHash = Get-CanonicalHash -Value $profile
    platformHash = Get-CanonicalHash -Value $platformInputs
    bundleFingerprint = $bundle.fingerprint
    releaseArtifact = $artifact
    priorPromotion = $prior
}
$selection.hash = Get-CanonicalHash -Value $selection
Write-JsonFile -Path (Join-Path $OutputDirectory 'selected.json') -Value $selection
Write-JsonFile -Path (Join-Path $OutputDirectory 'resolved.json') -Value $resolved
if ($RequireWorkflowContext) {
    $outputs = @{
        runner_group = $profile.github.runner.group
        runner_labels = ConvertTo-Json -InputObject @($profile.github.runner.labels) -Compress
        preview_client_id = $profile.identities.preview.clientId
        deploy_client_id = $profile.identities.deploy.clientId
        tenant_id = $profile.azure.tenantId
        subscription_id = $profile.azure.subscriptionId
        bundle_fingerprint = $bundle.fingerprint
        profile_hash = $selection.profileHash
        selection_hash = $selection.hash
    }
    foreach ($key in $outputs.Keys) {
        if ([string]$outputs[$key] -match "[`r`n]") { throw 'Invalid multiline workflow output.' }
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$key=$($outputs[$key])" -Encoding utf8
    }
}
Write-Output "Selected trusted release $ReleaseRunId; profile $($selection.profileHash); bundle $($bundle.fingerprint)."
