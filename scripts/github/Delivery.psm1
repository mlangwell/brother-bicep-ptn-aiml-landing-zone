#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')

function Assert-DeliveryCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-RepositoryIdentity {
    param([System.Collections.IDictionary]$Profile, [System.Collections.IDictionary]$Repository)
    Assert-DeliveryCondition ($Repository.id -eq $Profile.github.repositoryId) 'Target repository ID does not match the approved profile.'
    Assert-DeliveryCondition ($Repository.owner.id -eq $Profile.github.ownerId) 'Target owner ID does not match the approved profile.'
    Assert-DeliveryCondition ($Repository.full_name -ieq $Profile.github.repository) 'Target repository name does not match the approved profile.'
}

function Assert-TrustedReleaseRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Repository,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Workflow,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run
    )
    Assert-RepositoryIdentity $Profile $Repository
    $release = $Profile.release
    Assert-DeliveryCondition ($release.repository -ieq $Profile.github.repository) 'Release repository differs from the deployment repository.'
    Assert-DeliveryCondition ($release.ref -ceq $Profile.github.protectedRef -and $release.ref -cmatch '^refs/heads/.+$') 'Release ref is not the approved branch.'
    Assert-DeliveryCondition ($Workflow.path -ceq '.github/workflows/bicep-validate.yml' -and $release.workflow -ceq $Workflow.path) 'Release did not originate in the trusted CI workflow.'
    Assert-DeliveryCondition ($Run.workflow_id -eq $Workflow.id -and $Run.id -eq $release.runId -and $Run.run_attempt -eq $release.runAttempt) 'Release workflow/run identity mismatch.'
    Assert-DeliveryCondition ($Run.event -ceq 'push' -and $Run.status -ceq 'completed' -and $Run.conclusion -ceq 'success') 'Only a completed successful trusted push CI run can supply a release.'
    Assert-DeliveryCondition ($Run.head_repository.id -eq $Repository.id -and $Run.head_repository.full_name -ieq $Repository.full_name) 'Fork artifacts are not deployment inputs.'
    Assert-DeliveryCondition ($Run.head_sha -ceq $release.sourceSha -and $Run.head_sha -cmatch '^[a-f0-9]{40}$') 'Release source SHA mismatch.'
    Assert-DeliveryCondition ($Run.head_branch -ceq $release.ref.Substring('refs/heads/'.Length)) 'Release branch mismatch.'
    Assert-DeliveryCondition ($release.artifactName -ceq "ailz-release-$($Run.id)-$($Run.run_attempt)") 'Release artifact name is not bound to the selected run attempt.'
}

function Assert-TrustedDeploymentRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Repository,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Workflow,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [Parameter(Mandatory)][long]$ExpectedRunId,
        [ValidateSet('.github/workflows/deploy-environment.yml', '.github/workflows/record-live-gates.yml')]
        [string]$ExpectedWorkflowPath = '.github/workflows/deploy-environment.yml'
    )
    Assert-RepositoryIdentity $Profile $Repository
    Assert-DeliveryCondition ($Workflow.path -ceq $ExpectedWorkflowPath -and $Run.workflow_id -eq $Workflow.id) 'Promotion evidence came from an untrusted workflow.'
    Assert-DeliveryCondition ($Run.id -eq $ExpectedRunId -and $Run.event -ceq 'workflow_dispatch' -and $Run.status -ceq 'completed' -and $Run.conclusion -ceq 'success') 'Prior deployment run is not a successful protected dispatch.'
    Assert-DeliveryCondition ($Run.head_repository.id -eq $Repository.id -and $Run.head_repository.full_name -ieq $Repository.full_name) 'Promotion evidence came from another repository.'
    Assert-DeliveryCondition ("refs/heads/$($Run.head_branch)" -ceq $Profile.github.protectedRef) 'Promotion evidence came from an unapproved ref.'
}

function Get-SafeRelativePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    $normalized = if ($Directory) { $Path.TrimEnd('/') } else { $Path }
    if (-not $normalized -or $normalized -match '[\\:\x00-\x1f]' -or $normalized.StartsWith('/') -or $normalized -match '(^|/)\.\.?(/|$)' -or $normalized -match '//') {
        throw 'Unsafe archive or manifest path.'
    }
    foreach ($segment in $normalized.Split('/')) {
        if ($segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)' -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw 'Archive path is not portable.'
        }
    }
    return $normalized
}

function Expand-VerifiedZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MaximumExpandedBytes = 4GB
    )
    Assert-DeliveryCondition ($MaximumExpandedBytes -gt 0) 'Archive size limit must be positive.'
    Assert-DeliveryCondition (-not (Test-Path -LiteralPath $Destination)) 'Archive destination must be a new directory.'
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$expanded = 0
        foreach ($entry in $zip.Entries) {
            $directory = $entry.FullName.EndsWith('/')
            $name = Get-SafeRelativePath -Path $entry.FullName -Directory:$directory
            Assert-DeliveryCondition ($names.Add($name)) 'Duplicate or case-colliding archive entry.'
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            Assert-DeliveryCondition ($unixType -ne 0xA000 -and ($entry.ExternalAttributes -band 0x400) -eq 0) 'Archive links are not permitted.'
            $expanded += $entry.Length
            Assert-DeliveryCondition ($expanded -le $MaximumExpandedBytes) 'Archive exceeds the local expanded-size safety limit.'
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($Destination)) | Out-Null
        foreach ($entry in $zip.Entries) {
            $target = Join-Path $Destination (Get-SafeRelativePath -Path $entry.FullName -Directory:$entry.FullName.EndsWith('/'))
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            $source = $entry.Open()
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try { $source.CopyTo($output) } finally { $output.Dispose(); $source.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Test-ReleaseBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedRelease,
        [string]$ExpectedFingerprint
    )
    $directory = Get-Item -LiteralPath $BundlePath
    Assert-DeliveryCondition ($directory.PSIsContainer -and -not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Bundle must be a real directory.'
    $entries = @(Get-ChildItem -LiteralPath $BundlePath -Recurse -Force)
    foreach ($entry in $entries) {
        Assert-DeliveryCondition (-not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Bundle links are not permitted.'
    }
    $manifest = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $BundlePath 'bundle.json') -Raw)
    Assert-DeliveryCondition ($manifest.schemaVersion -eq 1 -and $manifest.configurationSchemaVersion -eq 1) 'Unsupported release or configuration schema.'
    Assert-DeliveryCondition ($manifest.files -is [System.Collections.IDictionary]) 'Release manifest lacks file checksums.'
    Assert-DeliveryCondition ((Get-CanonicalHash -Value $manifest.release) -ceq (Get-CanonicalHash -Value $ExpectedRelease)) 'Bundle release identity differs from the selected run, source, version, or image.'
    Assert-DeliveryCondition ($manifest.release.imageDigest -cmatch '^sha256:[a-f0-9]{64}$') 'Release image is not digest-pinned.'
    $fingerprint = Get-CanonicalHash -Value $manifest
    if ($ExpectedFingerprint) {
        Assert-DeliveryCondition ($fingerprint -ceq $ExpectedFingerprint) 'Release manifest changed after selection.'
    }
    Assert-DeliveryCondition ($manifest.files.Contains('payload/main.json') -and $manifest.files.Contains('image.oci.tar')) 'Release payload is incomplete.'
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $manifest.files.Keys) {
        $safePath = Get-SafeRelativePath $path
        Assert-DeliveryCondition ($safePath -cne 'bundle.json' -and $names.Add($safePath)) 'Invalid or duplicate manifest filename.'
        Assert-DeliveryCondition ($manifest.files[$path] -cmatch '^[a-f0-9]{64}$') 'Invalid manifest checksum.'
        $file = Get-Item -LiteralPath (Join-Path $BundlePath $safePath)
        Assert-DeliveryCondition (-not $file.PSIsContainer) 'Manifest references a directory.'
        $actual = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-DeliveryCondition ($actual -ceq $manifest.files[$path]) 'Release payload checksum mismatch.'
    }
    $files = @($entries | Where-Object { -not $_.PSIsContainer })
    Assert-DeliveryCondition ($files.Count -eq $manifest.files.Count + 1) 'Release contains missing or unlisted files.'
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($directory.FullName, $file.FullName).Replace('\', '/')
        Assert-DeliveryCondition ($relative -ceq 'bundle.json' -or $manifest.files.Contains($relative)) 'Release contains an unlisted file.'
    }
    return @{ manifest = $manifest; fingerprint = $fingerprint }
}

function New-PreviewRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$BundleFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ObservedState,
        [Parameter(Mandatory)][string]$WhatIfHash,
        [string]$GatewayPlanHash = '',
        [System.Collections.IDictionary]$WhatIfSummary = @{},
        [string]$PlatformHash = ''
    )
    $record = @{
        schemaVersion = 1
        environment = $Profile.environment
        profileHash = Get-CanonicalHash -Value $Profile
        parameterHash = Get-CanonicalHash -Value $Parameters
        bundleFingerprint = $BundleFingerprint
        observedState = $ObservedState
        whatIfHash = $WhatIfHash
        gatewayPlanHash = $GatewayPlanHash
        whatIfSummary = $WhatIfSummary
        platformHash = $PlatformHash
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $record.hash = Get-CanonicalHash -Value $record
    return $record
}

function Assert-PreviewRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$BundleFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ObservedState,
        [Parameter(Mandatory)][string]$ApprovedHash,
        [string]$PlatformHash = ''
    )
    $unsigned = @{}
    foreach ($key in $Record.Keys) { if ($key -cne 'hash') { $unsigned[$key] = $Record[$key] } }
    Assert-DeliveryCondition ($Record.schemaVersion -eq 1 -and $Record.hash -ceq (Get-CanonicalHash -Value $unsigned) -and $Record.hash -ceq $ApprovedHash) 'Preview evidence or its approval hash changed.'
    Assert-DeliveryCondition ($Record.environment -ceq $Profile.environment -and $Record.profileHash -ceq (Get-CanonicalHash -Value $Profile)) 'Configuration changed after preview; obtain a new preview and approval.'
    Assert-DeliveryCondition ($Record.parameterHash -ceq (Get-CanonicalHash -Value $Parameters)) 'Resolved deployment inputs changed after preview.'
    Assert-DeliveryCondition ($Record.bundleFingerprint -ceq $BundleFingerprint) 'Release changed after preview.'
    Assert-DeliveryCondition ($Record.platformHash -ceq $PlatformHash) 'Prepared network or platform inputs changed after preview.'
    Assert-DeliveryCondition ((Get-CanonicalHash -Value $Record.observedState) -ceq (Get-CanonicalHash -Value $ObservedState)) 'Gateway provisioning state changed after preview; an initial plan must never re-enable a private gateway.'
}

function Get-RequiredLiveGates {
    return @('privateConnectivity', 'identityIsolation', 'applicationInference', 'gatewayEnforcement', 'meteringCoverage', 'costOperations', 'promotionIntegrity', 'recovery', 'developerWorkspace')
}

function Assert-PromotionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][ValidateSet('test', 'prod')][string]$TargetEnvironment,
        [Parameter(Mandatory)][string]$ReleaseFingerprint,
        [Parameter(Mandatory)][long]$ExpectedWorkflowRunId
    )
    $previous = if ($TargetEnvironment -ceq 'test') { 'dev' } else { 'test' }
    Assert-DeliveryCondition ($Record.schemaVersion -eq 1 -and $Record.environment -ceq $previous) 'Promotion must follow dev -> test -> prod.'
    Assert-DeliveryCondition ($Record.workflowRunId -eq $ExpectedWorkflowRunId) 'Promotion evidence run identity mismatch.'
    Assert-DeliveryCondition ($Record.releaseFingerprint -ceq $ReleaseFingerprint) 'Prior environment did not validate this exact release.'
    Assert-DeliveryCondition ($Record.promotionEligible -is [bool] -and $Record.promotionEligible) 'Prior environment still has pending live gates.'
    Assert-DeliveryCondition ($Record.configurationHash -cmatch '^[a-f0-9]{64}$') 'Promotion evidence lacks resolved configuration identity.'
    foreach ($gate in Get-RequiredLiveGates) {
        Assert-DeliveryCondition ($Record.checks.Contains($gate)) 'Promotion evidence is missing a required live gate.'
        Assert-DeliveryCondition ($Record.checks[$gate].status -ceq 'passed' -and -not [string]::IsNullOrWhiteSpace([string]$Record.checks[$gate].evidence)) 'A required live gate lacks passing evidence.'
    }
}

function Invoke-GitHubJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Assert-DeliveryCondition ($Path -cmatch '^(repos|orgs)/[A-Za-z0-9_.%/?=&-]+$') 'Invalid GitHub API read path.'
    $json = Invoke-CheckedNative -Command 'gh' -Arguments @('api', '--method', 'GET', '-H', 'Accept: application/vnd.github+json', $Path)
    return (ConvertFrom-BootstrapJson -Json $json)
}

function Save-GitHubArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][long]$RunId,
        [Parameter(Mandatory)][string]$ArtifactName,
        [Parameter(Mandatory)][string]$Destination
    )
    Assert-DeliveryCondition ($Repository -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and $RunId -gt 0) 'Invalid artifact scope.'
    $artifactCandidates = @()
    for ($page = 1; $page -le 100; $page++) {
        $response = Invoke-GitHubJson "repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page"
        $artifactCandidates += @($response.artifacts | Where-Object { $_.name -ceq $ArtifactName })
        if ($response.artifacts.Count -lt 100) { break }
        if ($page -eq 100) { throw 'Artifact inventory exceeds the bounded lookup; narrow the run.' }
    }
    Assert-DeliveryCondition ($artifactCandidates.Count -eq 1 -and -not $artifactCandidates[0].expired) 'Selected artifact is missing, expired, or ambiguous.'
    $artifact = $artifactCandidates[0]
    Assert-DeliveryCondition ($artifact.digest -cmatch '^sha256:[a-f0-9]{64}$') 'GitHub did not provide an artifact digest.'
    Assert-DeliveryCondition ($artifact.workflow_run.id -eq $RunId) 'Artifact belongs to another run.'
    Assert-DeliveryCondition (-not (Test-Path -LiteralPath $Destination)) 'Artifact destination already exists.'
    $zipPath = "$Destination.zip"
    Assert-DeliveryCondition (-not (Test-Path -LiteralPath $zipPath)) 'Artifact download path already exists.'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($zipPath))) | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new('gh')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('api', '--method', 'GET', "repos/$Repository/actions/artifacts/$($artifact.id)/zip")) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-DeliveryCondition ($process.Start()) 'Artifact download could not start.'
        $errorRead = $process.StandardError.ReadToEndAsync()
        $output = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $process.StandardOutput.BaseStream.CopyTo($output) } finally { $output.Dispose() }
        $process.WaitForExit()
        $null = $errorRead.GetAwaiter().GetResult()
        Assert-DeliveryCondition ($process.ExitCode -eq 0) 'GitHub artifact download failed.'
        $digest = 'sha256:' + (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-DeliveryCondition ($digest -ceq $artifact.digest) 'Downloaded archive differs from GitHub artifact digest.'
        Expand-VerifiedZip -Path $zipPath -Destination $Destination
    }
    finally {
        $process.Dispose()
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
    }
    return @{ id = $artifact.id; digest = $artifact.digest; name = $artifact.name; runId = $RunId }
}

function Receive-PromotionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Repository,
        [Parameter(Mandatory)][long]$RunId,
        [Parameter(Mandatory)][string]$ReleaseFingerprint,
        [Parameter(Mandatory)][string]$Destination
    )
    if ($Profile.environment -cnotin @('test', 'prod') -or $RunId -le 0) { throw 'Test and production require a specific prior-environment deployment run.' }
    $previous = if ($Profile.environment -ceq 'test') { 'dev' } else { 'test' }
    $repoName = $Profile.github.repository
    $run = Invoke-GitHubJson "repos/$repoName/actions/runs/$RunId"
    $workflow = Invoke-GitHubJson "repos/$repoName/actions/workflows/$($run.workflow_id)"
    if ($workflow.path -cnotin @('.github/workflows/deploy-environment.yml', '.github/workflows/record-live-gates.yml')) { throw 'Promotion artifact producer is not an approved deployment or protected live-evidence recorder.' }
    Assert-TrustedDeploymentRun -Profile $Profile -Repository $Repository -Workflow $workflow -Run $run -ExpectedRunId $RunId -ExpectedWorkflowPath $workflow.path
    $artifact = Save-GitHubArtifact -Repository $repoName -RunId $RunId -ArtifactName "ailz-promotion-$previous-$($run.run_attempt)" -Destination $Destination
    $record = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $Destination 'promotion.json') -Raw)
    Assert-PromotionRecord -Record $record -TargetEnvironment $Profile.environment -ReleaseFingerprint $ReleaseFingerprint -ExpectedWorkflowRunId $RunId
    return @{ runId = $RunId; artifact = $artifact; recordHash = Get-CanonicalHash -Value $record }
}

Export-ModuleMember -Function Assert-TrustedReleaseRun, Assert-TrustedDeploymentRun, Test-ReleaseBundle, Expand-VerifiedZip, New-PreviewRecord, Assert-PreviewRecord, Get-RequiredLiveGates, Assert-PromotionRecord, Invoke-GitHubJson, Save-GitHubArtifact, Get-SafeRelativePath, Receive-PromotionEvidence
