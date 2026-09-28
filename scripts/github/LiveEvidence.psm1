#Requires -Version 7.4
<#
.SYNOPSIS
Records reviewed live observations from an immutable, protected GitHub commit.
.DESCRIPTION
This is not a probe runner or an automatic runtime certifier. It makes GitHub
reads through Delivery, verifies deployment/release artifacts and receipt bytes,
and relies on the trusted workflow's protected environment for human review.
An observation's checksum proves its bytes, not the operator's truthfulness.
The deployed configurationHash is P5's approved ARM parameter hash. P4's
different resolution hash is independently reproduced from the frozen profile.
Profile and platform inputs come from one immutable configuration commit.
The source run's verified selection artifact binds that commit and both hashes.

The only public operation requires actual workflow/run/job context. Preflight
never writes promotion.json. Record repeats all reads after the environment gate
and requires the preflight binding. There is no synthetic or approval switch.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -ErrorAction Stop
$script:LiveSchema = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'environments\live-evidence.schema.json'
$script:RecorderWorkflow = '.github/workflows/record-live-gates.yml'

function Assert-LiveCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-LiveField {
    param([AllowNull()]$Value, [string]$Name)
    if ($Value -is [Collections.IDictionary] -and $Value.Contains($Name)) { return ,$Value[$Name] }
    return $null
}

function Test-LiveInteger {
    param([AllowNull()]$Value, [long]$Minimum = 1)
    if ($Value -is [bool] -or $Value -is [string] -or $null -eq $Value) { return $false }
    if ($Value -isnot [ValueType] -or $Value -is [datetime] -or $Value -is [DateTimeOffset]) { return $false }
    try { $number = [decimal]$Value } catch { return $false }
    return $number -ge $Minimum -and $number -le [long]::MaxValue -and $number -eq [decimal]::Truncate($number)
}

function Test-LiveHash {
    param([AllowNull()]$Value)
    return $Value -is [string] -and $Value -cmatch '\A[a-f0-9]{64}\z' -and $Value -cne ('0' * 64)
}

function Test-LiveText {
    param([AllowNull()]$Value)
    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Assert-LiveRunNumbers {
    param($Run)
    foreach ($field in @('id', 'workflow_id', 'run_attempt')) {
        Assert-LiveCondition (Test-LiveInteger (Get-LiveField $Run $field)) 'GitHub run identity fields must be positive integers, never booleans or strings.'
    }
    Assert-LiveCondition (Test-LiveInteger (Get-LiveField (Get-LiveField $Run 'head_repository') 'id')) 'GitHub run repository identity must be a positive integer.'
    foreach ($field in @('event', 'status', 'head_sha', 'head_branch')) {
        Assert-LiveCondition (Test-LiveText (Get-LiveField $Run $field)) 'GitHub run event, state and revision fields must be nonempty strings.'
    }
    Assert-LiveCondition ($Run.head_sha -cmatch '\A[a-f0-9]{40}\z' -and (Test-LiveText $Run.head_repository.full_name)) 'GitHub run revision or repository name is malformed.'
    $conclusion = Get-LiveField $Run 'conclusion'
    Assert-LiveCondition ($null -eq $conclusion -or (Test-LiveText $conclusion)) 'GitHub run conclusion must be a string or null.'
}

function Get-LiveBytesHash {
    param([byte[]]$Bytes, [switch]$GitBlob)
    $hash = if ($GitBlob) { [Security.Cryptography.SHA1]::Create() } else { [Security.Cryptography.SHA256]::Create() }
    try {
        if ($GitBlob) {
            $prefix = [Text.Encoding]::UTF8.GetBytes("blob $($Bytes.Length)$([char]0)")
            $inputBytes = [byte[]]::new($prefix.Length + $Bytes.Length)
            [Array]::Copy($prefix, 0, $inputBytes, 0, $prefix.Length)
            [Array]::Copy($Bytes, 0, $inputBytes, $prefix.Length, $Bytes.Length)
        }
        else { $inputBytes = $Bytes }
        return [BitConverter]::ToString($hash.ComputeHash($inputBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function Get-LiveTime {
    param([AllowNull()]$Value, [string]$Label)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime] -and $Value.Kind -ne [DateTimeKind]::Unspecified) {
        return [DateTimeOffset]::new($Value).ToUniversalTime()
    }
    Assert-LiveCondition ($Value -is [string] -and $Value -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z') "A timezone-qualified timestamp is required at $Label."
    $parsed = [DateTimeOffset]::MinValue
    Assert-LiveCondition ([DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) "Invalid calendar timestamp at $Label."
    return $parsed.ToUniversalTime()
}

function Assert-LiveContentSafe {
    param([AllowNull()][AllowEmptyCollection()]$Value)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Assert-LiveCondition ($key -is [string]) 'Evidence object keys must be strings.'
            if ($key -match '(?i)(password|passwd|secret|credential|authorization|connectionstring|private.?key|api.?key|account.?key|access.?token|refresh.?token|sas.?token|jwt|^(tokens?|headers?|prompts?|completions?|input|output|body|output_text|input_text)$|prompt.?text|completion.?text)') {
                throw 'Live evidence contains a forbidden credential or model-content field. Values are not logged.'
            }
            Assert-LiveContentSafe $Value[$key]
        }
    }
    elseif ($Value -is [Collections.IList]) {
        foreach ($item in $Value) { Assert-LiveContentSafe $item }
    }
    elseif ($Value -is [string]) {
        if ($Value -match '(?i)\bBearer\s+\S+|\b(?:authorization|password|passwd|client.?secret|api.?key|accountkey|sharedaccesssignature|prompt|completion|input_text|output_text)\s*[:=]|(?:^|[?&;])sig=|-----BEGIN .*PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|\b(?:gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)|\b[a-z][a-z0-9+.-]*://[^\s/]*@' -or
            $Value -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') {
            throw 'Live evidence contains forbidden token, authorization, model-content or control text. Values are not logged.'
        }
    }
}

function Read-LiveJson {
    param([string]$Path, [ValidateSet('Manifest', 'Receipt', 'Source')][string]$Kind)
    $value = Read-BootstrapJsonFile -Path $Path
    Assert-LiveCondition ($value -is [Collections.IDictionary]) 'Live evidence must be a structured JSON object, never a boolean or status string.'
    if ($Kind -ceq 'Source') {
        # The source envelope's completion property is P4 metadata, not model text.
        foreach ($key in $value.Keys) {
            if ($key -ceq 'completion') { Assert-LiveContentSafe $value[$key] }
            else { Assert-LiveContentSafe @{ $key = $value[$key] } }
        }
    }
    else {
        Assert-LiveContentSafe $value
        $valid = Test-Json -Json (ConvertTo-CanonicalJson $value) -SchemaFile $script:LiveSchema -ErrorAction SilentlyContinue
        Assert-LiveCondition $valid "Invalid $Kind schema: complete reviewed observations and verified receipt references are required."
        $discriminator = if ($Kind -ceq 'Manifest') { 'checks' } else { 'gate' }
        Assert-LiveCondition $value.Contains($discriminator) "Expected a $Kind document."
    }
    return ,$value
}

function New-LiveDirectory {
    param([string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    Assert-LiveCondition (-not (Test-Path -LiteralPath $full)) 'Recorder destinations must be new directories; existing artifacts are never overwritten.'
    Assert-LiveCondition ((($full -split '[\\/]') -inotcontains '.azure')) 'Recorder destinations must not use azd state.'
    $ancestor = [IO.Directory]::GetParent($full)
    while ($null -ne $ancestor) {
        if (Test-Path -LiteralPath $ancestor.FullName) {
            $item = Get-Item -LiteralPath $ancestor.FullName -Force
            Assert-LiveCondition ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Recorder destinations must not traverse files, links or junctions.'
        }
        $ancestor = $ancestor.Parent
    }
    [IO.Directory]::CreateDirectory($full) | Out-Null
    return $full
}

function Get-RecorderRuntime {
    param([string]$Repository, [string]$Phase)
    Assert-LiveCondition ($env:GITHUB_ACTIONS -ceq 'true' -and $env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch') 'The recorder requires an explicit GitHub workflow dispatch; local JSON is not promotion proof.'
    Assert-LiveCondition ($Repository -cmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -and $Repository -ieq $env:GITHUB_REPOSITORY) 'Recorder repository does not match its workflow context.'
    Assert-LiveCondition ($env:GITHUB_REF -cmatch '\Arefs/heads/[A-Za-z0-9_./-]+\z' -and $env:GITHUB_SHA -cmatch '\A[a-f0-9]{40}\z') 'Recorder requires an immutable approved branch workflow revision.'
    Assert-LiveCondition ($env:GITHUB_JOB -ceq $Phase.ToLowerInvariant()) 'Record mode may only run in the protected record job; preflight cannot emit promotion evidence.'
    Assert-LiveCondition ($env:GITHUB_WORKFLOW_REF -ceq "$Repository/$script:RecorderWorkflow@$($env:GITHUB_REF)") 'Recorder workflow reference is not the approved entry workflow.'
    $numbers = @{}
    foreach ($name in @('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REPOSITORY_ID', 'GITHUB_REPOSITORY_OWNER_ID', 'GITHUB_ACTOR_ID')) {
        $raw = [Environment]::GetEnvironmentVariable($name)
        $number = 0L
        Assert-LiveCondition ($raw -cmatch '\A[1-9][0-9]*\z' -and [long]::TryParse($raw, [ref]$number)) 'Recorder workflow identity metadata is missing or invalid.'
        $numbers[$name] = $number
    }
    return @{
        runId = $numbers.GITHUB_RUN_ID; attempt = $numbers.GITHUB_RUN_ATTEMPT
        repositoryId = $numbers.GITHUB_REPOSITORY_ID; ownerId = $numbers.GITHUB_REPOSITORY_OWNER_ID
        actor = @{ id = $numbers.GITHUB_ACTOR_ID; login = $env:GITHUB_ACTOR }
        triggeringActor = $env:GITHUB_TRIGGERING_ACTOR; ref = $env:GITHUB_REF; sha = $env:GITHUB_SHA
        job = $env:GITHUB_JOB
    }
}

function Get-LiveCommit {
    param([string]$Repository, [string]$Sha)
    Assert-LiveCondition ($Sha -cmatch '\A[a-f0-9]{40}\z' -and $Sha -cne ('0' * 40)) 'An exact nonzero commit SHA is required.'
    $commit = Invoke-GitHubJson "repos/$Repository/commits/$Sha"
    Assert-LiveCondition ($commit.sha -ceq $Sha -and $commit.commit.tree.sha -cmatch '\A[a-f0-9]{40}\z') 'GitHub commit identity does not match the selected immutable commit.'
    $tree = Invoke-GitHubJson "repos/$Repository/git/trees/$($commit.commit.tree.sha)?recursive=1"
    Assert-LiveCondition ($tree.truncated -is [bool] -and -not $tree.truncated -and $tree.tree -is [Collections.IList]) 'An incomplete Git tree cannot establish evidence paths.'
    return @{ commit = $commit; tree = $tree }
}

function Receive-LiveGitFile {
    param(
        [string]$Repository, [string]$CommitSha, [Collections.IDictionary]$Tree,
        [string]$Path, [string]$Destination, [string]$ExpectedSha256
    )
    $safe = Get-SafeRelativePath -Path $Path
    Assert-LiveCondition ($safe -cmatch '\A[A-Za-z0-9_./-]+\.json\z') 'Only fixed-path JSON configuration and receipt files are accepted.'
    $entries = @($Tree.tree | Where-Object { $_.path -ieq $safe })
    Assert-LiveCondition ($entries.Count -eq 1 -and (Test-LiveText $entries[0].path) -and $entries[0].path -ceq $safe -and
        (Test-LiveText $entries[0].type) -and $entries[0].type -ceq 'blob' -and
        (Test-LiveText $entries[0].mode) -and $entries[0].mode -ceq '100644') 'Evidence must be an unambiguous regular Git file, not a link or executable.'
    $file = Invoke-GitHubJson "repos/$Repository/contents/$safe`?ref=$CommitSha"
    Assert-LiveCondition ((Test-LiveText $file.type) -and $file.type -ceq 'file' -and (Test-LiveText $file.path) -and
        $file.path -ceq $safe -and (Test-LiveText $file.encoding) -and $file.encoding -ceq 'base64' -and
        (Test-LiveText $file.sha) -and
        (Test-LiveInteger $file.size) -and $file.size -le 1MB -and $file.sha -ceq $entries[0].sha) 'Evidence file metadata is missing, empty, oversized or inconsistent.'
    try { $bytes = [Convert]::FromBase64String($file.content) }
    catch { throw 'Evidence file encoding is invalid. Content is not logged.' }
    Assert-LiveCondition ($bytes.Length -eq $file.size -and (Get-LiveBytesHash $bytes -GitBlob) -ceq $file.sha) 'Evidence bytes do not match the exact commit Git blob.'
    try { $null = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw 'Evidence must be valid UTF-8 JSON, not an opaque binary receipt.' }
    $sha256 = Get-LiveBytesHash $bytes
    if ($ExpectedSha256) {
        Assert-LiveCondition ((Test-LiveHash $ExpectedSha256) -and $sha256 -ceq $ExpectedSha256) 'Referenced evidence SHA-256 does not match the committed bytes.'
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    [IO.File]::WriteAllBytes($Destination, $bytes)
    return @{ path = $safe; sha256 = $sha256; blobSha = $file.sha; localPath = $Destination }
}

function Assert-LiveAncestry {
    param([string]$Repository, [string]$Sha, [string]$Branch)
    Assert-LiveCondition ($Sha -cmatch '\A[a-f0-9]{40}\z' -and $Sha -cne ('0' * 40)) 'Ancestry lookup requires an exact nonzero commit SHA.'
    $encoded = [Uri]::EscapeDataString($Branch)
    $comparison = Invoke-GitHubJson "repos/$Repository/compare/$Sha...$encoded"
    Assert-LiveCondition ($comparison.merge_base_commit.sha -ceq $Sha -and $comparison.status -cin @('ahead', 'identical')) 'A selected commit is outside the approved protected branch history.'
}

function Assert-RecorderRun {
    param($Profile, $Repository, $Workflow, $Run, $Runtime)
    Assert-LiveRunNumbers $Run
    Assert-LiveCondition ((Test-LiveInteger $Repository.id) -and (Test-LiveInteger $Repository.owner.id)) 'GitHub repository identities must be positive integers.'
    Assert-LiveCondition ((Test-LiveText $Repository.full_name) -and $Repository.id -eq $Profile.github.repositoryId -and $Repository.owner.id -eq $Profile.github.ownerId -and
        $Repository.full_name -ieq $Profile.github.repository -and $Runtime.repositoryId -eq $Repository.id -and $Runtime.ownerId -eq $Repository.owner.id) 'Recorder repository or owner identity mismatch.'
    Assert-LiveCondition ((Test-LiveText $Workflow.path) -and $Workflow.path -ceq $script:RecorderWorkflow -and
        (Test-LiveInteger $Workflow.id) -and $Run.workflow_id -eq $Workflow.id) 'Only the approved recorder workflow ID may issue reviewed evidence.'
    Assert-LiveCondition ((Test-LiveInteger $Run.id) -and $Run.id -eq $Runtime.runId -and $Run.run_attempt -eq $Runtime.attempt -and
        $Run.event -ceq 'workflow_dispatch' -and $Run.status -ceq 'in_progress') 'Recorder run is not the active explicit dispatch attempt.'
    Assert-LiveCondition ($Run.head_repository.id -eq $Repository.id -and $Run.head_repository.full_name -ieq $Repository.full_name -and
        $Run.head_sha -ceq $Runtime.sha -and "refs/heads/$($Run.head_branch)" -ceq $Profile.github.protectedRef -and $Runtime.ref -ceq $Profile.github.protectedRef) 'Recorder workflow revision, repository or protected ref mismatch.'
    Assert-LiveCondition ((Test-LiveText $Run.actor.type) -and $Run.actor.type -ceq 'User' -and
        (Test-LiveInteger $Run.actor.id) -and $Run.actor.id -eq $Runtime.actor.id -and (Test-LiveText $Run.actor.login) -and
        $Run.actor.login -ceq $Runtime.actor.login) 'Recorder actor metadata does not identify the actual human dispatch actor.'
    $triggering = Get-LiveField $Run 'triggering_actor'
    if ($null -ne $triggering) {
        Assert-LiveCondition ((Test-LiveText $triggering.type) -and $triggering.type -ceq 'User' -and
            (Test-LiveInteger $triggering.id) -and (Test-LiveText $triggering.login) -and
            $triggering.login -ceq $Runtime.triggeringActor) 'Recorder rerun actor is not the actual human triggering actor.'
    }
    $jobs = Invoke-GitHubJson "repos/$($Profile.github.repository)/actions/runs/$($Runtime.runId)/attempts/$($Runtime.attempt)/jobs?per_page=100"
    $current = @($jobs.jobs | Where-Object { (Test-LiveText $_.name) -and $_.name -ceq $Runtime.job })
    Assert-LiveCondition ($current.Count -eq 1 -and (Test-LiveText $current[0].status) -and
        $current[0].status -ceq 'in_progress') 'The selected workflow job has not started; protected approval must not be bypassed.'
}

function Assert-NoFailedAutomaticEvidence {
    param([AllowNull()][AllowEmptyCollection()]$Value)
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains('status')) {
            Assert-LiveCondition ((Test-LiveText $Value.status) -and $Value.status -cin @('passed', 'pending', 'verified', 'completed', 'ok', 'ready')) 'Actual failed, unknown, cancelled or simulated P4 evidence cannot be overridden by an attestation.'
        }
        foreach ($child in $Value.Values) { Assert-NoFailedAutomaticEvidence $child }
    }
    elseif ($Value -is [Collections.IList]) {
        foreach ($child in $Value) { Assert-NoFailedAutomaticEvidence $child }
    }
}

function Assert-SourceDeployment {
    param($Source, $Profile, [long]$RunId, [string]$Fingerprint, [string]$ResolutionHash)
    Assert-LiveCondition ((Test-LiveInteger (Get-LiveField $Source 'schemaVersion')) -and $Source.schemaVersion -eq 1 -and
        (Test-LiveText $Source.environment) -and $Source.environment -ceq $Profile.environment -and
        (Test-LiveInteger $Source.workflowRunId) -and $Source.workflowRunId -eq $RunId) 'Source deployment record identity is missing or mismatched.'
    Assert-LiveCondition ($Source.status -is [string] -and $Source.status -ceq 'InfrastructureAndPrivateCompletionVerified') 'A health-only or incomplete deployment is not a source for live attestation.'
    Assert-LiveCondition ((Test-LiveHash $Source.releaseFingerprint) -and $Source.releaseFingerprint -ceq $Fingerprint -and
        (Test-LiveHash $Source.configurationHash) -and (Test-LiveHash $Source.profileHash) -and
        $Source.profileHash -ceq (Get-CanonicalHash $Profile) -and (Test-LiveHash $Source.previewHash)) 'Source deployment release, profile, configuration or preview binding is invalid.'
    $completion = Get-LiveField $Source 'completion'
    $live = Get-LiveField $Source 'liveGate'
    foreach ($data in @($completion, $live)) {
        Assert-LiveCondition ($data -is [Collections.IDictionary] -and (Test-LiveInteger $data.schemaVersion) -and $data.schemaVersion -eq 1 -and
            $data.environment -is [string] -and $data.environment -ceq $Profile.environment -and
            (Test-LiveHash $data.configurationHash) -and $data.configurationHash -ceq $ResolutionHash -and
            (Get-CanonicalHash $data.release) -ceq (Get-CanonicalHash $Profile.release)) 'Source P4 metadata disagrees with the deployed environment, configuration or release.'
        Assert-NoFailedAutomaticEvidence $data
        Assert-LiveCondition ($data.promotionEligible -is [bool] -and -not $data.promotionEligible) 'P4 evidence must not masquerade as a self-certified complete live gate.'
    }
    Assert-LiveCondition ((Test-LiveText $completion.mode) -and $completion.mode -ceq 'executed' -and $completion.runnerReady -is [bool] -and $completion.runnerReady -and
        $completion.privateConnectivity.status -ceq 'verified') 'Actual private completion is required, not a plan, simulation or health-only check.'
    Assert-LiveCondition ($completion.applications -is [Collections.IList] -and $completion.applications.Count -eq 1) 'Source completion must identify the selected application.'
    $app = $completion.applications[0]
    foreach ($field in @('name', 'resourceId', 'image', 'healthVersion', 'revision')) {
        Assert-LiveCondition (Test-LiveText (Get-LiveField $app $field)) 'P4 application identity and revision fields must be literal nonempty strings.'
    }
    $registry = ($Profile.application.registryResourceId -split '/')[-1]
    $image = "$($registry.ToLowerInvariant()).azurecr.io/$($Profile.application.imageRepository)@$($Profile.release.imageDigest)"
    $resourceId = "/subscriptions/$($Profile.azure.subscriptionId)/resourceGroups/$($Profile.azure.resourceGroup)/providers/Microsoft.App/containerApps/$($Profile.application.name)"
    Assert-LiveCondition ($app.name -ceq $Profile.application.name -and $app.resourceId -ieq $resourceId -and $app.image -ceq $image -and
        $app.healthVersion -ceq $Profile.release.sourceSha -and $app.configurationVerified -is [bool] -and $app.configurationVerified -and
        -not [string]::IsNullOrWhiteSpace($app.revision)) 'P4 completion does not verify the exact immutable application and configuration.'
    Assert-LiveCondition ($live.mode -cin @('plan', 'observed-live-partial') -and (Test-LiveInteger $live.workflowRunId) -and
        $live.workflowRunId -eq $RunId -and (Test-LiveHash $live.releaseFingerprint) -and
        $live.releaseFingerprint -ceq $Fingerprint -and $live.checks -is [Collections.IDictionary]) 'Source live-gate metadata is not bound to this actual deployment run.'
    foreach ($gate in Get-RequiredLiveGates) {
        $check = Get-LiveField $live.checks $gate
        Assert-LiveCondition ($check -is [Collections.IDictionary] -and (Test-LiveText $check.status) -and $check.status -cin @('passed', 'pending') -and
            $check.evidence -is [string] -and -not [string]::IsNullOrWhiteSpace($check.evidence)) 'Source P4 contains a missing, fake or failed required gate.'
    }
}

function Assert-SourceSelection {
    param($Selection, $Profile, $Source, [string]$ConfigurationSha, [string]$PlatformHash)
    Assert-LiveCondition ((Test-LiveInteger (Get-LiveField $Selection 'schemaVersion')) -and $Selection.schemaVersion -eq 1 -and
        (Test-LiveText $Selection.environment) -and $Selection.environment -ceq $Profile.environment -and
        (Test-LiveText $Selection.repository) -and $Selection.repository -ieq $Profile.github.repository -and
        (Test-LiveInteger $Selection.repositoryId) -and $Selection.repositoryId -eq $Profile.github.repositoryId) 'Source selection is not bound to this repository and environment.'
    Assert-LiveCondition ((Test-LiveText $Selection.configurationSha) -and $Selection.configurationSha -ceq $ConfigurationSha -and
        (Test-LiveHash $Selection.profileHash) -and $Selection.profileHash -ceq $Source.profileHash -and
        (Test-LiveHash $Selection.platformHash) -and $Selection.platformHash -ceq $PlatformHash -and
        (Test-LiveHash $Selection.bundleFingerprint) -and $Selection.bundleFingerprint -ceq $Source.releaseFingerprint) 'Source deployment used a different configuration commit, profile, platform approval or release.'
    $unsigned = @{}
    foreach ($key in $Selection.Keys) { if ($key -cne 'hash') { $unsigned[$key] = $Selection[$key] } }
    Assert-LiveCondition ((Test-LiveHash $Selection.hash) -and $Selection.hash -ceq (Get-CanonicalHash $unsigned)) 'Source selection record hash is invalid.'
}

function Get-RequiredObservationContexts {
    param([string]$Gate)
    switch ($Gate) {
        { $_ -in @('privateConnectivity', 'identityIsolation', 'gatewayEnforcement') } { return @('human', 'workload', 'runner') }
        'applicationInference' { return @('human', 'workload') }
        'meteringCoverage' { return @('workload') }
        'developerWorkspace' { return @('human') }
        default { return @('platform') }
    }
}

function Assert-LiveObservationBinding {
    param($Value, $Profile, $Source, [long]$DeploymentRunId)
    Assert-LiveCondition ($Value.environment -ceq $Profile.environment -and $Value.deploymentRunId -eq $DeploymentRunId -and
        $Value.releaseFingerprint -ceq $Source.releaseFingerprint -and $Value.configurationHash -ceq $Source.configurationHash) 'Reviewed evidence does not identify this exact deployment, environment, release and configuration.'
}

function Assert-RecordedObservationText {
    param([string]$Text, [switch]$Summary)
    Assert-LiveCondition ($Text -inotmatch '\A\s*(pending|failed|failure|unknown|skipped|not[-_ ]run|not[-_ ]observed|n/?a)\s*\z') 'A failed, pending or unobserved result cannot be reported as a passed live gate.'
    if ($Summary) {
        Assert-LiveCondition ($Text -inotmatch '\A\s*(pass|passed|true|false|ok|success)\s*\z') 'A status word alone is not a reviewed observation summary.'
    }
}

function Receive-ReviewedObservations {
    param($Profile, $Source, $Commit, [string]$CommitSha, [long]$DeploymentRunId, $SourceFinished, $RecorderStarted, [string]$Directory)
    $repo = $Profile.github.repository
    $base = "environments/evidence/$($Profile.environment)"
    $manifestFile = Receive-LiveGitFile -Repository $repo -CommitSha $CommitSha -Tree $Commit.tree -Path "$base/live-gates.json" -Destination (Join-Path $Directory 'live-gates.json')
    $manifest = Read-LiveJson $manifestFile.localPath 'Manifest'
    Assert-LiveObservationBinding $manifest $Profile $Source $DeploymentRunId
    $commitTime = Get-LiveTime $Commit.commit.commit.committer.date 'evidence commit'
    Assert-LiveCondition ($commitTime -ge $SourceFinished -and $commitTime -le $RecorderStarted) 'Evidence commit must follow the source deployment and precede this recording dispatch.'
    $references = @{}
    $observers = @{}
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($gate in Get-RequiredLiveGates) {
        $entry = $manifest.checks[$gate]
        Assert-RecordedObservationText $entry.result.summary -Summary
        $observed = Get-LiveTime $entry.observedAt "checks.$gate.observedAt"
        Assert-LiveCondition ($observed -ge $SourceFinished -and $observed -le $commitTime) 'An observation predates the source deployment or postdates its evidence commit.'
        $observerKey = "$($entry.observedBy.id):$($entry.observedBy.login)"
        if (-not $observers.Contains($observerKey)) {
            $permission = Invoke-GitHubJson "repos/$repo/collaborators/$($entry.observedBy.login)/permission"
            Assert-LiveCondition ((Test-LiveText $permission.user.type) -and $permission.user.type -ceq 'User' -and (Test-LiveInteger $permission.user.id) -and
                $permission.user.id -eq $entry.observedBy.id -and $permission.user.login -is [string] -and
                $permission.user.login -ceq $entry.observedBy.login -and $permission.permission -cin @('read', 'triage', 'write', 'maintain', 'admin')) 'The recorded observer is not the identified human repository collaborator.'
            $observers[$observerKey] = $entry.observedBy
        }
        $gateReferences = @()
        $contexts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($reference in $entry.evidence) {
            Assert-LiveCondition ($reference.path.StartsWith("$base/receipts/", [StringComparison]::Ordinal) -and $seenPaths.Add($reference.path)) 'Receipt paths must be unique and inside the selected environment evidence directory.'
            $destination = Join-Path $Directory ("receipt-$gate-$($gateReferences.Count).json")
            $file = Receive-LiveGitFile -Repository $repo -CommitSha $CommitSha -Tree $Commit.tree -Path $reference.path -Destination $destination -ExpectedSha256 $reference.sha256
            $receipt = Read-LiveJson $file.localPath 'Receipt'
            Assert-LiveObservationBinding $receipt $Profile $Source $DeploymentRunId
            Assert-LiveCondition ($receipt.gate -ceq $gate) 'A receipt belongs to a different gate.'
            foreach ($field in @('observedAt', 'observedBy', 'procedure', 'result')) {
                Assert-LiveCondition ((ConvertTo-CanonicalJson $receipt[$field]) -ceq (ConvertTo-CanonicalJson $entry[$field])) 'Receipt identity, timestamp, procedure or result contradicts the manifest.'
            }
            foreach ($observation in $receipt.observations) {
                Assert-RecordedObservationText $observation.observed
                $null = $contexts.Add($observation.context)
            }
            $gateReferences += @{ path = $file.path; sha256 = $file.sha256; blobSha = $file.blobSha }
        }
        foreach ($context in Get-RequiredObservationContexts $gate) {
            Assert-LiveCondition ($contexts.Contains($context)) "Reviewed $gate receipts lack a required human, workload, runner or platform context."
        }
        $references[$gate] = $gateReferences
    }
    [string[]]$observerKeys = @($observers.Keys)
    [Array]::Sort($observerKeys, [StringComparer]::Ordinal)
    return @{
        manifest = $manifest; manifestPath = $manifestFile.path; manifestHash = $manifestFile.sha256
        receipts = $references; observers = @($observerKeys | ForEach-Object { $observers[$_] })
    }
}

function Invoke-LiveGateEvidenceRecording {
    [CmdletBinding()]
    param(
        [ValidateSet('Preflight', 'Record')][string]$Phase = 'Preflight',
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$Environment,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ConfigurationSha,
        [Parameter(Mandatory)][string]$EvidenceCommitSha,
        [Parameter(Mandatory)][long]$ReleaseRunId,
        [Parameter(Mandatory)][long]$DeploymentRunId,
        [Parameter(Mandatory)][string]$WorkDirectory,
        [string]$OutputDirectory,
        [string]$ExpectedPreflightHash
    )
    $runtime = Get-RecorderRuntime $Repository $Phase
    foreach ($sha in @($ConfigurationSha, $EvidenceCommitSha)) {
        Assert-LiveCondition ($sha -cmatch '\A[a-f0-9]{40}\z' -and $sha -cne ('0' * 40)) 'Configuration and evidence require exact nonzero commit SHAs before any GitHub read.'
    }
    Assert-LiveCondition ($ReleaseRunId -gt 0 -and $DeploymentRunId -gt 0 -and $ReleaseRunId -ne $DeploymentRunId -and
        $runtime.runId -ne $ReleaseRunId -and $runtime.runId -ne $DeploymentRunId) 'Distinct trusted release, deployment and recorder run IDs are required.'
    if ($Phase -ceq 'Record') {
        Assert-LiveCondition ((Test-LiveHash $ExpectedPreflightHash) -and -not [string]::IsNullOrWhiteSpace($OutputDirectory)) 'Record requires the pre-gate hash and a fresh promotion output directory.'
        Assert-LiveCondition (-not (Test-Path -LiteralPath $OutputDirectory)) 'Existing promotion output must not be reused.'
    }
    $readiness = Get-Command Assert-GitHubBootstrapReadiness -ErrorAction SilentlyContinue
    Assert-LiveCondition ($null -ne $readiness -and $readiness.Parameters.ContainsKey('PlatformInputs')) 'P2 integration requires the GitHub-only Assert-GitHubBootstrapReadiness -Profile -PlatformInputs helper. No environment job or attestation may bypass it.'
    $schema = Get-Content -LiteralPath $script:LiveSchema -Raw | ConvertFrom-Json -AsHashtable
    $knownGates = @(Get-RequiredLiveGates | Sort-Object -CaseSensitive)
    Assert-LiveCondition ((ConvertTo-CanonicalJson @($schema.definitions.manifest.properties.checks.required | Sort-Object -CaseSensitive)) -ceq (ConvertTo-CanonicalJson $knownGates)) 'Live evidence schema has drifted from Delivery required gates.'
    $work = New-LiveDirectory $WorkDirectory
    $configuration = Get-LiveCommit $Repository $ConfigurationSha
    $profileFile = Receive-LiveGitFile -Repository $Repository -CommitSha $ConfigurationSha -Tree $configuration.tree -Path "environments/$Environment.json" -Destination (Join-Path $work 'profile.json')
    $platformFile = Receive-LiveGitFile -Repository $Repository -CommitSha $ConfigurationSha -Tree $configuration.tree -Path "environments/$Environment.platform.json" -Destination (Join-Path $work 'platform.json')
    $profile = Read-EnvironmentProfile -Path $profileFile.localPath
    $platformInputs = Read-PlatformInputs -Path $platformFile.localPath
    $platformHash = Get-CanonicalHash $platformInputs
    Assert-LiveCondition ($profile.environment -ceq $Environment -and $profile.github.repository -ieq $Repository -and $profile.release.runId -eq $ReleaseRunId) 'Immutable profile differs from the selected environment, repository or release run.'
    $resolution = Resolve-EnvironmentProfile -Profile $profile
    Assert-LiveCondition ($profile.github.protectedRef -cmatch '\Arefs/heads/.+\z') 'Recorder profiles require an approved protected branch, not a moving or arbitrary ref.'
    $repo = Invoke-GitHubJson "repos/$Repository"
    $branchName = $profile.github.protectedRef.Substring('refs/heads/'.Length)
    $branch = Invoke-GitHubJson "repos/$Repository/branches/$([Uri]::EscapeDataString($branchName))"
    Assert-LiveCondition ($branch.protected -is [bool] -and $branch.protected) 'The configured evidence/source branch is not protected.'
    foreach ($sha in @($ConfigurationSha, $EvidenceCommitSha, $runtime.sha)) { Assert-LiveAncestry $Repository $sha $branchName }
    $recorderWorkflow = Invoke-GitHubJson "repos/$Repository/actions/workflows/record-live-gates.yml"
    $recorderRun = Invoke-GitHubJson "repos/$Repository/actions/runs/$($runtime.runId)"
    Assert-RecorderRun $profile $repo $recorderWorkflow $recorderRun $runtime
    $readinessResult = & $readiness -Profile $profile -PlatformInputs $platformInputs
    Assert-LiveCondition ($null -eq $readinessResult -or ($readinessResult -is [bool] -and $readinessResult)) 'P2 readiness must throw on unproven protections and return no output or true; ambiguous status output is not proof.'

    $releaseWorkflow = Invoke-GitHubJson "repos/$Repository/actions/workflows/bicep-validate.yml"
    $releaseRun = Invoke-GitHubJson "repos/$Repository/actions/runs/$ReleaseRunId"
    Assert-LiveRunNumbers $releaseRun
    Assert-LiveCondition ((Test-LiveInteger $releaseWorkflow.id) -and (Test-LiveText $releaseWorkflow.path)) 'Trusted CI workflow identity is invalid.'
    Assert-TrustedReleaseRun -Profile $profile -Repository $repo -Workflow $releaseWorkflow -Run $releaseRun
    $releasePath = Join-Path $work 'release'
    $releaseArtifact = Save-GitHubArtifact -Repository $Repository -RunId $ReleaseRunId -ArtifactName $profile.release.artifactName -Destination $releasePath
    $bundle = Test-ReleaseBundle -BundlePath $releasePath -ExpectedRelease $profile.release

    $deploymentWorkflow = Invoke-GitHubJson "repos/$Repository/actions/workflows/deploy-environment.yml"
    $deploymentRun = Invoke-GitHubJson "repos/$Repository/actions/runs/$DeploymentRunId"
    Assert-LiveRunNumbers $deploymentRun
    Assert-LiveCondition ((Test-LiveInteger $deploymentWorkflow.id) -and (Test-LiveText $deploymentWorkflow.path)) 'Trusted deployment workflow identity is invalid.'
    Assert-TrustedDeploymentRun -Profile $profile -Repository $repo -Workflow $deploymentWorkflow -Run $deploymentRun -ExpectedRunId $DeploymentRunId -ExpectedWorkflowPath '.github/workflows/deploy-environment.yml'
    Assert-LiveCondition ((Test-LiveInteger $deploymentRun.run_attempt) -and $deploymentRun.head_sha -cmatch '\A[a-f0-9]{40}\z') 'Source deployment attempt/revision is invalid.'
    Assert-LiveAncestry $Repository $deploymentRun.head_sha $branchName
    $deploymentPath = Join-Path $work 'deployment'
    $deploymentArtifact = Save-GitHubArtifact -Repository $Repository -RunId $DeploymentRunId -ArtifactName "ailz-deployment-$Environment-$($deploymentRun.run_attempt)" -Destination $deploymentPath
    $source = Read-LiveJson (Join-Path $deploymentPath 'deployment.json') 'Source'
    Assert-SourceDeployment -Source $source -Profile $profile -RunId $DeploymentRunId -Fingerprint $bundle.fingerprint -ResolutionHash $resolution.configurationHash
    $selectionPath = Join-Path $work 'source-selection'
    $selectionArtifact = Save-GitHubArtifact -Repository $Repository -RunId $DeploymentRunId -ArtifactName "ailz-selection-$DeploymentRunId-$($deploymentRun.run_attempt)" -Destination $selectionPath
    $sourceSelection = Read-LiveJson (Join-Path $selectionPath 'selected.json') 'Source'
    Assert-SourceSelection -Selection $sourceSelection -Profile $profile -Source $source -ConfigurationSha $ConfigurationSha -PlatformHash $platformHash
    foreach ($artifact in @($releaseArtifact, $deploymentArtifact, $selectionArtifact)) {
        Assert-LiveCondition ((Test-LiveInteger $artifact.id) -and $artifact.digest -cmatch '\Asha256:[a-f0-9]{64}\z') 'Verified GitHub artifact metadata is incomplete.'
    }
    $sourceStarted = Get-LiveTime $deploymentRun.created_at 'source deployment start'
    $sourceFinished = Get-LiveTime $deploymentRun.updated_at 'source deployment finish'
    $recorderStarted = Get-LiveTime $recorderRun.created_at 'recording dispatch'
    Assert-LiveCondition ((Get-LiveTime $releaseRun.updated_at 'release completion') -le $sourceStarted -and
        $sourceStarted -le $sourceFinished -and $sourceFinished -le $recorderStarted -and $recorderStarted -le [DateTimeOffset]::UtcNow) 'Release, deployment and recording timestamps are inconsistent.'
    $evidenceCommit = Get-LiveCommit $Repository $EvidenceCommitSha
    $observations = Receive-ReviewedObservations -Profile $profile -Source $source -Commit $evidenceCommit -CommitSha $EvidenceCommitSha -DeploymentRunId $DeploymentRunId -SourceFinished $sourceFinished -RecorderStarted $recorderStarted -Directory (Join-Path $work 'evidence')
    $actor = if ($null -ne (Get-LiveField $recorderRun 'triggering_actor')) { $recorderRun.triggering_actor } else { $recorderRun.actor }
    $binding = @{
        schemaVersion = 1; environment = $Environment; repositoryId = $repo.id; ownerId = $repo.owner.id
        protectedRef = $profile.github.protectedRef; workflowId = $recorderWorkflow.id
        workflowRunId = $runtime.runId; workflowRunAttempt = $runtime.attempt; workflowSha = $runtime.sha
        actor = @{ id = $actor.id; login = $actor.login }
        configurationSha = $ConfigurationSha; profileHash = Get-CanonicalHash $profile; platformHash = $platformHash
        releaseFingerprint = $bundle.fingerprint; releaseArtifact = $releaseArtifact
        configurationHash = $source.configurationHash; resolutionHash = $resolution.configurationHash; previewHash = $source.previewHash
        sourceDeploymentRunId = $DeploymentRunId; sourceDeploymentRunAttempt = $deploymentRun.run_attempt
        sourceDeploymentSha = $deploymentRun.head_sha; sourceDeploymentArtifact = $deploymentArtifact
        sourceDeploymentRecordHash = Get-CanonicalHash $source
        sourceSelectionArtifact = $selectionArtifact; sourceSelectionRecordHash = Get-CanonicalHash $sourceSelection
        evidenceCommit = $EvidenceCommitSha; evidenceManifestPath = $observations.manifestPath
        evidenceManifestHash = $observations.manifestHash; receipts = $observations.receipts; observers = $observations.observers
    }
    $preflightHash = Get-CanonicalHash $binding
    if ($Phase -ceq 'Preflight') { return @{ phase = 'Preflight'; preflightHash = $preflightHash } }
    Assert-LiveCondition ($ExpectedPreflightHash -ceq $preflightHash) 'Source run, release, configuration or reviewed evidence changed after preflight; obtain a new protected review.'
    $checks = @{}
    foreach ($gate in Get-RequiredLiveGates) {
        $references = @($observations.receipts[$gate] | ForEach-Object { "https://github.com/$Repository/blob/$EvidenceCommitSha/$($_.path)#sha256=$($_.sha256)" })
        $checks[$gate] = @{ status = 'passed'; evidence = $references -join '; ' }
    }
    $record = @{
        schemaVersion = 1; environment = $Environment
        workflowRunId = $runtime.runId; workflowRunAttempt = $runtime.attempt
        releaseFingerprint = $bundle.fingerprint; configurationHash = $source.configurationHash
        resolutionHash = $resolution.configurationHash
        profileHash = $binding.profileHash; previewHash = $source.previewHash; configurationSha = $ConfigurationSha
        platformHash = $platformHash; sourceSelectionArtifact = $selectionArtifact
        sourceDeploymentRunId = $DeploymentRunId; sourceDeploymentArtifact = $deploymentArtifact
        evidenceKind = 'reviewed-live-observations'; automatedProof = $false
        actor = $binding.actor; evidenceCommit = $EvidenceCommitSha
        evidenceManifest = @{ path = $observations.manifestPath; sha256 = $observations.manifestHash }
        preflightHash = $preflightHash; checks = $checks
        promotionEligible = $true
    }
    if ($Environment -cne 'prod') {
        $next = if ($Environment -ceq 'dev') { 'test' } else { 'prod' }
        Assert-PromotionRecord -Record $record -TargetEnvironment $next -ReleaseFingerprint $bundle.fingerprint -ExpectedWorkflowRunId $runtime.runId
    }
    $output = New-LiveDirectory $OutputDirectory
    Write-JsonFile -Path (Join-Path $output 'promotion.json') -Value $record
    return @{ phase = 'Record'; preflightHash = $preflightHash; artifactName = "ailz-promotion-$Environment-$($runtime.attempt)"; recordHash = Get-CanonicalHash $record }
}

Export-ModuleMember -Function Invoke-LiveGateEvidenceRecording
