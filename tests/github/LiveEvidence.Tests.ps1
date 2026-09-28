#Requires -Version 7.4
<#
.SYNOPSIS
Offline attestation tests with synthetic GitHub responses and source artifacts.
.DESCRIPTION
No REST, Azure, authentication, inference or GitHub writes are performed.
The profile reader is explicitly adapted inside this test module to accept the
synthetic fixture. The shipped recorder has no synthetic or approval bypass.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts\github\Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'scripts\github\Delivery.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'scripts\github\Bootstrap.psm1') -ErrorAction Stop
$module = Import-Module (Join-Path $root 'scripts\github\LiveEvidence.psm1') -PassThru -ErrorAction Stop
Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop

$script:count = 0
$script:failures = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    $script:count++
    try { & $Action; Write-Host "[PASS] $Name" }
    catch { $script:failures++; Write-Host "[FAIL] $Name -- $($_.Exception.Message)" }
    finally { Remove-PromotionFiles }
}
function Assert-Rejected([scriptblock]$Action) {
    $errorRecord = $null
    try { & $Action | Out-Null } catch { $errorRecord = $_ }
    Assert-True ($null -ne $errorRecord) 'Invalid attestation unexpectedly succeeded.'
    Assert-True ($errorRecord.Exception.Message -notmatch 'synthetic-sensitive-value') 'A rejected receipt disclosed sensitive content.'
}
function Copy-Data($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $Value.Keys) { $copy[$key] = Copy-Data $Value[$key] }
        return ,$copy
    }
    if ($Value -is [Collections.IList]) {
        $copy = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $copy.Add((Copy-Data $item)) }
        return ,$copy.ToArray()
    }
    return $Value
}
function Get-BytesHash([byte[]]$Bytes, [string]$Algorithm = 'SHA256') {
    $hash = [Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function New-GitFile([string]$Path, $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonicalJson $Value) + "`n")
    $prefix = [Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)$([char]0)")
    $blob = [byte[]]::new($prefix.Length + $bytes.Length)
    [Array]::Copy($prefix, 0, $blob, 0, $prefix.Length)
    [Array]::Copy($bytes, 0, $blob, $prefix.Length, $bytes.Length)
    return @{
        path = $Path; type = 'file'; encoding = 'base64'; size = $bytes.Length
        sha = Get-BytesHash $blob 'SHA1'; content = [Convert]::ToBase64String($bytes)
    }
}
function Update-EvidenceFiles($Fixture) {
    $Fixture.evidenceFiles = @{}
    $Fixture.evidenceTree.tree = @()
    foreach ($gate in Get-RequiredLiveGates) {
        $path = "environments/evidence/$($Fixture.profile.environment)/receipts/$gate.json"
        $file = New-GitFile $path $Fixture.receipts[$gate]
        $Fixture.manifest.checks[$gate].evidence = @(@{
            path = $path; sha256 = Get-BytesHash ([Convert]::FromBase64String($file.content))
        })
        $Fixture.evidenceFiles[$path] = $file
        $Fixture.evidenceTree.tree += @{ path = $path; type = 'blob'; mode = '100644'; sha = $file.sha }
    }
    Update-ManifestFile $Fixture
}
function Update-ManifestFile($Fixture) {
    $path = "environments/evidence/$($Fixture.profile.environment)/live-gates.json"
    $file = New-GitFile $path $Fixture.manifest
    $Fixture.evidenceFiles[$path] = $file
    $Fixture.evidenceTree.tree = @($Fixture.evidenceTree.tree | Where-Object path -CNE $path)
    $Fixture.evidenceTree.tree += @{ path = $path; type = 'blob'; mode = '100644'; sha = $file.sha }
}
function Update-PlatformFile($Fixture) {
    $path = "environments/$($Fixture.profile.environment).platform.json"
    $Fixture.platformFile = New-GitFile $path $Fixture.platformInputs
    $Fixture.configTree.tree = @($Fixture.configTree.tree | Where-Object path -CNE $path)
    $Fixture.configTree.tree += @{ path = $path; type = 'blob'; mode = '100644'; sha = $Fixture.platformFile.sha }
}
function Update-SelectionHash($Fixture) {
    $unsigned = @{}
    foreach ($key in $Fixture.selection.Keys) { if ($key -cne 'hash') { $unsigned[$key] = $Fixture.selection[$key] } }
    $Fixture.selection.hash = Get-CanonicalHash $unsigned
}
function New-Fixture([string]$Environment = 'dev', [string]$RunnerMode = 'github-hosted-private') {
    $profile = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1') -Environment $Environment
    $profile.github.runner.mode = $RunnerMode
    if ($RunnerMode -ceq 'existing-private') { $profile.github.runner.labels = @('self-hosted', 'linux', 'synthetic-private') }
    $profile.github.protectedRef = 'refs/heads/main'
    if ($Environment -ceq 'dev') { $profile.github.environmentReviewers = @() }
    $profile.release.runId = 101
    $profile.release.runAttempt = 1
    $profile.release.sourceSha = 'a' * 40
    $profile.release.workflow = '.github/workflows/bicep-validate.yml'
    $profile.release.ref = 'refs/heads/main'
    $profile.release.artifactName = 'ailz-release-101-1'
    $now = [DateTimeOffset]::UtcNow
    $repository = @{
        id = $profile.github.repositoryId; full_name = $profile.github.repository
        owner = @{ id = $profile.github.ownerId }
    }
    $observer = @{ login = 'synthetic-observer'; id = 7001 }
    $actor = @{ login = 'synthetic-attester'; id = 7002; type = 'User' }
    $scope = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)"
    $platformInputs = @{
        schemaVersion = 1; owner = 'synthetic-live-gates'
        github = @{ serverUrl = 'https://github.com'; apiUrl = 'https://api.github.com' }
        runner = @{
            groupId = 8001; approvedRepositoryIds = @($profile.github.repositoryId)
            approvedWorkflowRefs = @("$($profile.github.repository)/.github/workflows/deploy-environment-reusable.yml@refs/heads/main")
            adminLogin = 'synthetic-platform-admin'; adminId = 8002
            nsgResourceId = "$scope/providers/Microsoft.Network/networkSecurityGroups/synthetic-runner-nsg"
            approvedNsgFingerprint = '5' * 64
            machineBindings = @(@{
                runnerId = 8003; runnerName = 'synthetic-existing-runner'
                virtualMachineResourceId = "$scope/providers/Microsoft.Compute/virtualMachines/synthetic-runner"
                networkInterfaceResourceId = "$scope/providers/Microsoft.Network/networkInterfaces/synthetic-runner-nic"
            })
        }
    }
    $baseRun = @{
        run_attempt = 1; head_repository = @{ id = $repository.id; full_name = $repository.full_name }
        head_branch = 'main'; actor = $actor; triggering_actor = $actor
    }
    $releaseRun = Copy-Data $baseRun
    $releaseRun += @{
        id = 101; workflow_id = 11; event = 'push'; status = 'completed'; conclusion = 'success'
        head_sha = 'a' * 40; created_at = $now.AddHours(-6).ToString('o'); updated_at = $now.AddHours(-5).ToString('o')
    }
    $deploymentRun = Copy-Data $baseRun
    $deploymentRun += @{
        id = 301; workflow_id = 12; event = 'workflow_dispatch'; status = 'completed'; conclusion = 'success'
        head_sha = 'b' * 40; created_at = $now.AddHours(-4).ToString('o'); updated_at = $now.AddHours(-3).ToString('o')
    }
    $recorderRun = Copy-Data $baseRun
    $recorderRun += @{
        id = 501; workflow_id = 13; event = 'workflow_dispatch'; status = 'in_progress'; conclusion = $null
        head_sha = 'e' * 40; created_at = $now.AddMinutes(-30).ToString('o'); updated_at = $now.AddMinutes(-10).ToString('o')
    }
    $payload = [Text.Encoding]::UTF8.GetBytes('{"resources":[]}')
    $image = [Text.Encoding]::UTF8.GetBytes('SYNTHETIC OCI PLACEHOLDER; NEVER EXECUTE OR DEPLOY')
    $bundleManifest = @{
        schemaVersion = 1; configurationSchemaVersion = 1; release = $profile.release
        files = @{ 'payload/main.json' = Get-BytesHash $payload; 'image.oci.tar' = Get-BytesHash $image }
    }
    $fingerprint = Get-CanonicalHash $bundleManifest
    $configurationHash = 'c' * 64
    $resolutionHash = (Resolve-EnvironmentProfile $profile -AllowSynthetic).configurationHash
    $source = @{
        schemaVersion = 1; environment = $Environment; workflowRunId = 301
        releaseFingerprint = $fingerprint; configurationHash = $configurationHash
        profileHash = Get-CanonicalHash $profile; previewHash = 'd' * 64
        status = 'InfrastructureAndPrivateCompletionVerified'
        completion = @{
            schemaVersion = 1; environment = $Environment; release = $profile.release
            configurationHash = $resolutionHash; observedAt = $now.AddHours(-3.5).ToString('o')
            mode = 'executed'; runnerReady = $true; humanReady = $false; promotionEligible = $false
            privateConnectivity = @{ status = 'verified'; endpointCount = 4 }
            applications = @(@{
                name = $profile.application.name; revision = 'synthetic-revision'
                resourceId = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)/providers/Microsoft.App/containerApps/$($profile.application.name)"
                image = 'syntheticneverdeployacr.azurecr.io/synthetic/developer-smoke@' + $profile.release.imageDigest
                healthVersion = $profile.release.sourceSha; configurationVerified = $true
            })
        }
        liveGate = @{
            schemaVersion = 1; environment = $Environment; workflowRunId = 301; release = $profile.release
            releaseFingerprint = $fingerprint; configurationHash = $resolutionHash
            mode = 'observed-live-partial'; promotionEligible = $false; checks = @{}; probes = @{}
        }
    }
    $manifest = @{
        schemaVersion = 1; evidenceKind = 'reviewed-live-observations'
        environment = $Environment; releaseFingerprint = $fingerprint
        deploymentRunId = 301; configurationHash = $configurationHash; checks = @{}
    }
    $receipts = @{}
    foreach ($gate in Get-RequiredLiveGates) {
        $source.liveGate.checks[$gate] = @{ status = 'pending'; evidence = 'SYNTHETIC P4 pending observation fixture.' }
        $observation = @{
            observedAt = $now.AddHours(-2).ToString('o'); observedBy = Copy-Data $observer
            procedure = "docs/synthetic-live-runbook.md#$gate"
            result = @{ status = 'passed'; summary = "SYNTHETIC reviewed $gate observation; not real live evidence." }
        }
        $manifest.checks[$gate] = Copy-Data $observation
        $receipts[$gate] = @{
            schemaVersion = 1; evidenceKind = 'reviewed-live-observations'
            environment = $Environment; releaseFingerprint = $fingerprint
            deploymentRunId = 301; configurationHash = $configurationHash; gate = $gate
            observedAt = $observation.observedAt; observedBy = Copy-Data $observer
            procedure = $observation.procedure; result = Copy-Data $observation.result
            observations = @(
                foreach ($context in @('human', 'workload', 'runner', 'platform')) {
                    @{
                        context = $context; name = "synthetic-$gate-measurement"
                        observed = 'SYNTHETIC measured observation; no real procedure was run.'
                        expected = 'SYNTHETIC approved procedure expectation.'
                    }
                }
            )
        }
    }
    $source.liveGate.checks.privateConnectivity = @{ status = 'passed'; evidence = 'SYNTHETIC automatic private-connectivity fixture.' }
    $profileFile = New-GitFile "environments/$Environment.json" $profile
    $fixture = @{
        profile = $profile; repository = $repository; actor = $actor; observer = $observer
        configurationSha = 'c' * 40; evidenceCommitSha = 'd' * 40
        configTreeSha = '1' * 40; evidenceTreeSha = '2' * 40
        configurationFile = $profileFile
        platformInputs = $platformInputs
        configTree = @{ truncated = $false; tree = @(@{ path = $profileFile.path; type = 'blob'; mode = '100644'; sha = $profileFile.sha }) }
        evidenceTree = @{ truncated = $false; tree = @() }; evidenceFiles = @{}
        evidenceCommitTime = $now.AddHours(-1).ToString('o')
        branch = @{ name = 'main'; protected = $true; commit = @{ sha = 'f' * 40 } }
        workflows = @{
            'bicep-validate.yml' = @{ id = 11; path = '.github/workflows/bicep-validate.yml' }
            'deploy-environment.yml' = @{ id = 12; path = '.github/workflows/deploy-environment.yml' }
            'record-live-gates.yml' = @{ id = 13; path = '.github/workflows/record-live-gates.yml' }
        }
        releaseRun = $releaseRun; deploymentRun = $deploymentRun; recorderRun = $recorderRun
        jobs = @{ jobs = @(@{ name = 'preflight'; status = 'in_progress' }, @{ name = 'record'; status = 'in_progress' }) }
        bundleManifest = $bundleManifest; payload = $payload; image = $image
        source = $source; manifest = $manifest; receipts = $receipts
        selection = @{
            schemaVersion = 1; environment = $Environment
            repository = $repository.full_name; repositoryId = $repository.id
            configurationSha = 'c' * 40; profileHash = Get-CanonicalHash $profile
            platformHash = Get-CanonicalHash $platformInputs; bundleFingerprint = $fingerprint
            releaseArtifact = @{ id = 1101; digest = 'sha256:' + ('9' * 64); name = $profile.release.artifactName; runId = 101 }
            priorPromotion = $null
        }
        readiness = $true; ancestry = $true; artifactDigestValid = $true; syntheticReader = $true
        observerPermission = @{ permission = 'write'; user = @{ login = $observer.login; id = $observer.id; type = 'User' } }
        calls = [Collections.Generic.List[string]]::new()
    }
    Update-PlatformFile $fixture
    Update-SelectionHash $fixture
    Update-EvidenceFiles $fixture
    return $fixture
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ailz-live-evidence-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$envNames = @('GITHUB_ACTIONS','GITHUB_EVENT_NAME','GITHUB_REPOSITORY','GITHUB_REPOSITORY_ID','GITHUB_REPOSITORY_OWNER_ID','GITHUB_REF','GITHUB_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_JOB','GITHUB_ACTOR','GITHUB_ACTOR_ID','GITHUB_TRIGGERING_ACTOR','GITHUB_WORKFLOW_REF','GITHUB_OUTPUT')
$savedEnvironment = @{}
foreach ($name in $envNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$actualReader = Get-Command Read-EnvironmentProfile
$actualResolver = Get-Command Resolve-EnvironmentProfile

function Set-Fixture($Fixture, [string]$Phase = 'Record') {
    & $module {
        param($Fixture, $Reader, $Resolver)
        $script:Fixture = $Fixture
        $script:ActualProfileReader = $Reader
        $script:ActualProfileResolver = $Resolver
        function script:Read-EnvironmentProfile {
            param([string]$Path)
            if ($script:Fixture.syntheticReader) { return & $script:ActualProfileReader -Path $Path -AllowSynthetic }
            return & $script:ActualProfileReader -Path $Path
        }
        function script:Resolve-EnvironmentProfile {
            param([Collections.IDictionary]$Profile)
            if ($script:Fixture.syntheticReader) { return & $script:ActualProfileResolver -Profile $Profile -AllowSynthetic }
            return & $script:ActualProfileResolver -Profile $Profile
        }
        function script:Assert-GitHubBootstrapReadiness {
            param($Profile, $PlatformInputs)
            $script:Fixture.calls.Add('readiness')
            if ($null -eq $PlatformInputs -or (Get-CanonicalHash $PlatformInputs) -cne (Get-CanonicalHash $script:Fixture.platformInputs)) {
                throw 'Synthetic P2 contract requires the exact validated immutable platform inputs.'
            }
            if ($Profile.github.runner.mode -ceq 'existing-private' -and
                (-not $PlatformInputs.runner.Contains('machineBindings') -or $PlatformInputs.runner.machineBindings.Count -eq 0)) {
                throw 'Synthetic existing-private P2 readiness requires administrator machine bindings.'
            }
            if (-not $script:Fixture.readiness) { throw 'Synthetic GitHub protections are not ready.' }
            if ($script:Fixture.Contains('readinessResponse')) { return $script:Fixture.readinessResponse }
        }
        function script:Invoke-GitHubJson {
            param([string]$Path)
            $f = $script:Fixture
            $f.calls.Add("GET $Path")
            $repo = "repos/$($f.profile.github.repository)"
            if ($Path -ceq $repo) { return $f.repository }
            if ($Path -ceq "$repo/branches/main") { return $f.branch }
            if ($Path -cmatch '/compare/([a-f0-9]{40})\.\.\.main$') {
                return @{ merge_base_commit = @{ sha = $(if ($f.ancestry) { $Matches[1] } else { '0' * 40 }) }; status = 'ahead' }
            }
            if ($Path -ceq "$repo/commits/$($f.configurationSha)") {
                return @{ sha = $f.configurationSha; commit = @{ tree = @{ sha = $f.configTreeSha }; committer = @{ date = $f.releaseRun.created_at } } }
            }
            if ($Path -ceq "$repo/commits/$($f.evidenceCommitSha)") {
                return @{ sha = $f.evidenceCommitSha; commit = @{ tree = @{ sha = $f.evidenceTreeSha }; committer = @{ date = $f.evidenceCommitTime } } }
            }
            if ($Path -ceq "$repo/git/trees/$($f.configTreeSha)?recursive=1") { return $f.configTree }
            if ($Path -ceq "$repo/git/trees/$($f.evidenceTreeSha)?recursive=1") { return $f.evidenceTree }
            if ($Path -ceq "$repo/contents/$($f.configurationFile.path)?ref=$($f.configurationSha)") { return $f.configurationFile }
            if ($Path -ceq "$repo/contents/$($f.platformFile.path)?ref=$($f.configurationSha)") { return $f.platformFile }
            foreach ($file in $f.evidenceFiles.Values) {
                if ($Path -ceq "$repo/contents/$($file.path)?ref=$($f.evidenceCommitSha)") { return $file }
            }
            foreach ($name in $f.workflows.Keys) {
                if ($Path -ceq "$repo/actions/workflows/$name") { return $f.workflows[$name] }
            }
            foreach ($run in @($f.releaseRun, $f.deploymentRun, $f.recorderRun)) {
                if ($Path -ceq "$repo/actions/runs/$($run.id)") { return $run }
            }
            if ($Path -ceq "$repo/actions/runs/501/attempts/1/jobs?per_page=100") { return $f.jobs }
            if ($Path -ceq "$repo/collaborators/$($f.observer.login)/permission") { return $f.observerPermission }
            throw 'Unexpected GitHub read in the offline fixture.'
        }
        function script:Save-GitHubArtifact {
            param([string]$Repository, [long]$RunId, [string]$ArtifactName, [string]$Destination)
            $f = $script:Fixture
            $f.calls.Add("artifact $RunId $ArtifactName")
            if (-not $f.artifactDigestValid) { throw 'Synthetic downloaded artifact digest verification failed.' }
            if ($Repository -cne $f.profile.github.repository) { throw 'Wrong synthetic artifact repository.' }
            if (Test-Path -LiteralPath $Destination) { throw 'Artifact destination already exists.' }
            [IO.Directory]::CreateDirectory($Destination) | Out-Null
            if ($RunId -eq 101 -and $ArtifactName -ceq 'ailz-release-101-1') {
                [IO.Directory]::CreateDirectory((Join-Path $Destination 'payload')) | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $Destination 'payload\main.json'), $f.payload)
                [IO.File]::WriteAllBytes((Join-Path $Destination 'image.oci.tar'), $f.image)
                Write-JsonFile (Join-Path $Destination 'bundle.json') $f.bundleManifest
            }
            elseif ($RunId -eq 301 -and $ArtifactName -ceq "ailz-deployment-$($f.profile.environment)-$($f.deploymentRun.run_attempt)") {
                Write-JsonFile (Join-Path $Destination 'deployment.json') $f.source
            }
            elseif ($RunId -eq 301 -and $ArtifactName -ceq "ailz-selection-301-$($f.deploymentRun.run_attempt)") {
                Write-JsonFile (Join-Path $Destination 'selected.json') $f.selection
                Write-JsonFile (Join-Path $Destination 'profile.json') $f.profile
                Write-JsonFile (Join-Path $Destination 'platform.json') $f.platformInputs
            }
            else { throw 'Only the exact source deployment and release artifacts are valid fixtures.' }
            return @{ id = $RunId + 1000; digest = 'sha256:' + ('9' * 64); name = $ArtifactName; runId = $RunId }
        }
    } $Fixture $actualReader $actualResolver
    $values = @{
        GITHUB_ACTIONS = 'true'; GITHUB_EVENT_NAME = 'workflow_dispatch'
        GITHUB_REPOSITORY = $Fixture.profile.github.repository; GITHUB_REPOSITORY_ID = [string]$Fixture.profile.github.repositoryId
        GITHUB_REPOSITORY_OWNER_ID = [string]$Fixture.profile.github.ownerId
        GITHUB_REF = 'refs/heads/main'; GITHUB_SHA = 'e' * 40; GITHUB_RUN_ID = '501'; GITHUB_RUN_ATTEMPT = '1'
        GITHUB_JOB = $Phase.ToLowerInvariant(); GITHUB_ACTOR = $Fixture.actor.login
        GITHUB_ACTOR_ID = [string]$Fixture.actor.id; GITHUB_TRIGGERING_ACTOR = $Fixture.actor.login
        GITHUB_WORKFLOW_REF = "$($Fixture.profile.github.repository)/.github/workflows/record-live-gates.yml@refs/heads/main"
        GITHUB_OUTPUT = Join-Path $scratch 'github-output'
    }
    foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name, $values[$name]) }
}
function Invoke-Fixture($Fixture, [string]$Phase = 'Record', [string]$ExpectedHash) {
    Set-Fixture $Fixture $Phase
    $work = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
    $output = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
    $args = @{
        Phase = $Phase; Environment = $Fixture.profile.environment; Repository = $Fixture.profile.github.repository
        ConfigurationSha = $Fixture.configurationSha; EvidenceCommitSha = $Fixture.evidenceCommitSha
        ReleaseRunId = 101; DeploymentRunId = 301; WorkDirectory = $work; OutputDirectory = $output
    }
    if ($Phase -ceq 'Record' -and -not $ExpectedHash) {
        $preflight = Invoke-Fixture $Fixture 'Preflight'
        $ExpectedHash = $preflight.summary.preflightHash
        Set-Fixture $Fixture 'Record'
    }
    if ($ExpectedHash) { $args.ExpectedPreflightHash = $ExpectedHash }
    $summary = Invoke-LiveGateEvidenceRecording @args
    return @{ summary = $summary; output = $output; work = $work }
}
function Assert-NoPromotionFiles {
    Assert-True (@(Get-ChildItem -LiteralPath $scratch -Recurse -File -Filter 'promotion.json').Count -eq 0) 'Rejected inputs produced a promotion artifact.'
}
function Remove-PromotionFiles {
    foreach ($file in @(Get-ChildItem -LiteralPath $scratch -Recurse -File -Filter 'promotion.json')) { Remove-Item -LiteralPath $file.FullName }
}

try {
    Test-Case 'Preflight validates real primitive contracts but writes no promotion record' {
        $f = New-Fixture
        $result = Invoke-Fixture $f 'Preflight'
        Assert-True ($result.summary.preflightHash -cmatch '^[a-f0-9]{64}$') 'Preflight lacks an immutable review binding.'
        Assert-NoPromotionFiles
        Assert-True ($f.calls -contains 'readiness') 'P2 protections were not inspected.'
        Assert-True ($f.calls -contains 'artifact 301 ailz-deployment-dev-1') 'The actual source deployment artifact was not verified.'
        Assert-True ($f.calls -contains 'artifact 301 ailz-selection-301-1') 'The source configuration/platform selection artifact was not verified.'
        Assert-True ($f.calls -contains "GET repos/$($f.profile.github.repository)/contents/environments/dev.platform.json?ref=$($f.configurationSha)") 'Platform inputs were not fetched from the exact profile commit.'
    }
    Test-Case 'Public CLI carries the preflight hash into protected record execution without printing receipts' {
        $f = New-Fixture
        $scriptPath = Join-Path $root 'scripts\github\Record-LiveGateEvidence.ps1'
        $arguments = @{
            Repository = $f.profile.github.repository; Environment = 'dev'
            ConfigurationSha = $f.configurationSha; EvidenceCommitSha = $f.evidenceCommitSha
            ReleaseRunId = 101; DeploymentRunId = 301
        }
        Set-Fixture $f 'Preflight'
        $stdout = @(& $scriptPath @arguments -Phase Preflight -WorkDirectory (Join-Path $scratch ([guid]::NewGuid().ToString('N'))))
        Assert-True ($stdout.Count -eq 0) 'Preflight printed profile or receipt values.'
        $line = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)[-1]
        Assert-True ($line -cmatch '\Apreflight_hash=([a-f0-9]{64})\z') 'CLI did not produce its safe workflow output binding.'
        $hash = $Matches[1]
        Set-Fixture $f 'Record'
        $output = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        $stdout = @(& $scriptPath @arguments -Phase Record -ExpectedPreflightHash $hash -WorkDirectory (Join-Path $scratch ([guid]::NewGuid().ToString('N'))) -OutputDirectory $output)
        Assert-True ($stdout.Count -eq 0) 'Recorder printed profile or receipt values.'
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'promotion.json')) 'Protected CLI did not persist the validated record.'
        Assert-True (@($f.calls | Where-Object { $_ -ceq 'readiness' }).Count -eq 2) 'Protections were not rechecked after the protected gate.'
    }
    Test-Case 'Reviewed receipts produce explicitly manual evidence bound to source run and commit' {
        $f = New-Fixture
        $result = Invoke-Fixture $f
        $record = Read-BootstrapJsonFile -Path (Join-Path $result.output 'promotion.json')
        Assert-True ($record.evidenceKind -ceq 'reviewed-live-observations' -and $record.automatedProof -eq $false) 'Reviewed observations were mislabeled as automatic proof.'
        Assert-True ($record.workflowRunId -eq 501 -and $record.sourceDeploymentRunId -eq 301 -and $record.evidenceCommit -ceq $f.evidenceCommitSha) 'Run/commit provenance was not preserved.'
        Assert-True ($record.actor.id -eq $f.actor.id -and $record.actor.login -ceq $f.actor.login) 'Actual recording actor was not preserved.'
        Assert-True ($record.profileHash -ceq (Get-CanonicalHash $f.profile) -and $record.configurationHash -ceq $f.source.configurationHash) 'Profile or immutable deployed configuration binding was lost.'
        Assert-True ($record.configurationHash -cne $f.source.completion.configurationHash) 'The deployed parameter hash must not be replaced by P4 resolution identity.'
        Assert-True ($record.platformHash -ceq (Get-CanonicalHash $f.platformInputs)) 'Validated platform identity was not recorded.'
        Assert-True ($record.sourceDeploymentArtifact.digest -cmatch '^sha256:[a-f0-9]{64}$') 'Verified deployment artifact digest is missing.'
        Assert-PromotionRecord -Record $record -TargetEnvironment test -ReleaseFingerprint $f.source.releaseFingerprint -ExpectedWorkflowRunId 501
        foreach ($gate in Get-RequiredLiveGates) {
            Assert-True ($record.checks[$gate].status -ceq 'passed' -and $record.checks[$gate].evidence -like "*$($f.evidenceCommitSha)*") 'A gate lacks its verified immutable receipt reference.'
        }
        Assert-True ($f.source.liveGate.promotionEligible -eq $false) 'The recorder modified or self-certified P4 evidence.'
        Remove-PromotionFiles
    }
    Test-Case 'Existing-private passes the same administrator platform bindings to both recorder phases' {
        $f = New-Fixture -RunnerMode 'existing-private'
        $result = Invoke-Fixture $f
        $record = Read-BootstrapJsonFile (Join-Path $result.output 'promotion.json')
        Assert-True ($record.platformHash -ceq $f.selection.platformHash) 'Existing-private platform binding was lost.'
        Assert-True (@($f.calls | Where-Object { $_ -ceq 'readiness' }).Count -eq 2) 'Existing-private readiness was not checked before and after protection.'
        Assert-True (@($f.calls | Where-Object { $_ -ceq "GET repos/$($f.profile.github.repository)/contents/environments/dev.platform.json?ref=$($f.configurationSha)" }).Count -eq 2) 'Both phases must fetch platform inputs from the same immutable SHA.'
    }
    Test-Case 'Current P5 deployment-record producer accepts actual P4 pending-gate metadata' {
        $f = New-Fixture
        $producerPath = Join-Path $root 'scripts\github\Invoke-EnvironmentDeployment.ps1'
        $tokens = $null
        $parseErrors = $null
        $producerAst = [Management.Automation.Language.Parser]::ParseFile($producerPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) 'The parent deployment producer must parse.'
        $assignments = @($producerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$record' -and
                $node.Right.Extent.Text.Contains('InfrastructureAndPrivateCompletionVerified')
        }, $true))
        Assert-True ($assignments.Count -eq 1) 'The actual P5 deployment-record producer was not found unambiguously.'
        Assert-True (@($assignments[0].Right.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)).Count -eq 0) 'Only the trusted local data-construction expression may be exercised, never deployment commands.'
        $factory = [scriptblock]::Create('param($profile,$workflowRunId,$bundle,$preview,$completion,$live)' + "`n" + $assignments[0].Right.Extent.Text)
        $completionModule = Import-Module (Join-Path $root 'scripts\github\Completion.psm1') -PassThru -ErrorAction Stop
        try {
            $resolution = Resolve-EnvironmentProfile $f.profile -AllowSynthetic
            $pending = & $completionModule {
                param($Resolution, $Fingerprint)
                New-LiveGateEvidence -Resolution $Resolution -ReleaseFingerprint $Fingerprint -WorkflowRunId 301
            } $resolution $f.source.releaseFingerprint
            Assert-True ($pending.mode -ceq 'plan' -and -not $pending.promotionEligible) 'P4 metadata construction must remain pending and make no live claim.'
            $f.source = & $factory $f.profile 301 @{ fingerprint = $f.source.releaseFingerprint } @{
                parameterHash = $f.source.configurationHash
                profileHash = $f.source.profileHash
                hash = $f.source.previewHash
            } $f.source.completion $pending
            $result = Invoke-Fixture $f
            $record = Read-BootstrapJsonFile (Join-Path $result.output 'promotion.json')
            Assert-True ($record.configurationHash -ceq $f.source.configurationHash -and $record.resolutionHash -ceq $pending.configurationHash) 'Actual P5/P4 hash domains were confused.'
            foreach ($gate in Get-RequiredLiveGates) {
                Assert-True ($pending.checks[$gate].status -ceq 'pending') 'The recorder must not rewrite P4 pending observations into automatic passes.'
            }
        }
        finally { Remove-Module -ModuleInfo $completionModule -ErrorAction Stop }
    }
    Test-Case 'Changed platform approvals invalidate the previously reviewed preflight binding' {
        $f = New-Fixture
        $preflight = Invoke-Fixture $f 'Preflight'
        $f.platformInputs.owner = 'synthetic-updated-owner'
        Update-PlatformFile $f
        $f.selection.platformHash = Get-CanonicalHash $f.platformInputs
        Update-SelectionHash $f
        Assert-Rejected { Invoke-Fixture $f 'Record' $preflight.summary.preflightHash }
        Assert-NoPromotionFiles
    }
    Test-Case 'Protected test and prod recordings require their actual same-environment deployments' {
        foreach ($environment in @('test', 'prod')) {
            $f = New-Fixture $environment
            $result = Invoke-Fixture $f
            $record = Read-BootstrapJsonFile (Join-Path $result.output 'promotion.json')
            Assert-True ($record.environment -ceq $environment) 'Recorder changed environment.'
            if ($environment -ceq 'test') {
                Assert-PromotionRecord -Record $record -TargetEnvironment prod -ReleaseFingerprint $f.source.releaseFingerprint -ExpectedWorkflowRunId 501
            }
            Remove-PromotionFiles
        }
    }
    Test-Case 'An unreviewed changed preflight binding cannot produce promotion evidence' {
        $f = New-Fixture
        Assert-Rejected { Invoke-Fixture $f 'Record' ('7' * 64) }
        Assert-NoPromotionFiles
    }
    Test-Case 'Changed source evidence after preflight requires a new protected review' {
        $f = New-Fixture
        $preflight = Invoke-Fixture $f 'Preflight'
        $f.source.previewHash = '8' * 64
        Assert-Rejected { Invoke-Fixture $f 'Record' $preflight.summary.preflightHash }
        Assert-NoPromotionFiles
    }
    Test-Case 'Malformed evidence commit is rejected before any GitHub or artifact read' {
        $f = New-Fixture
        $f.evidenceCommitSha = '../unapproved-read'
        Assert-Rejected { Invoke-Fixture $f 'Preflight' }
        Assert-True ($f.calls.Count -eq 0) 'An unvalidated evidence commit reached a GitHub API path.'
        Assert-NoPromotionFiles
    }
    $badCases = [ordered]@{
        'missing environment protections' = { param($f) $f.readiness = $false }
        'readiness returned an error string instead of asserting protections' = { param($f) $f.readinessResponse = 'failed' }
        'unprotected branch' = { param($f) $f.branch.protected = $false }
        'missing immutable platform file' = { param($f) $f.configTree.tree = @($f.configTree.tree | Where-Object path -CNE $f.platformFile.path) }
        'invalid platform schema' = { param($f) $f.platformInputs.owner = $null; Update-PlatformFile $f }
        'platform file is not an ordinary Git blob' = { param($f) ($f.configTree.tree | Where-Object path -CEQ $f.platformFile.path).mode = '120000' }
        'platform bytes disagree with committed blob metadata' = { param($f) $f.platformFile.content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"changed":true}')) }
        'source selection names another configuration commit' = { param($f) $f.selection.configurationSha = '6' * 40; Update-SelectionHash $f }
        'source platform approval differs from selected immutable inputs' = { param($f) $f.selection.platformHash = '6' * 64; Update-SelectionHash $f }
        'source selection self-hash is invalid' = { param($f) $f.selection.hash = '6' * 64 }
        'evidence/configuration outside protected ancestry' = { param($f) $f.ancestry = $false }
        'repository ID mismatch' = { param($f) $f.repository.id++ }
        'owner ID mismatch' = { param($f) $f.repository.owner.id++ }
        'untrusted source workflow ID' = { param($f) $f.deploymentRun.workflow_id = 999 }
        'boolean source workflow ID' = { param($f) $f.deploymentRun.workflow_id = $true }
        'health-only source workflow path' = { param($f) $f.workflows['deploy-environment.yml'].path = '.github/workflows/health-only.yml' }
        'failed source deployment run' = { param($f) $f.deploymentRun.conclusion = 'failure' }
        'source fork' = { param($f) $f.deploymentRun.head_repository.id++ }
        'source deployment branch mismatch' = { param($f) $f.deploymentRun.head_branch = 'untrusted' }
        'untrusted recording workflow' = { param($f) $f.recorderRun.workflow_id = 999 }
        'boolean recording workflow ID' = { param($f) $f.recorderRun.workflow_id = $true }
        'boolean release workflow ID' = { param($f) $f.releaseRun.workflow_id = $true }
        'nonmanual recording run' = { param($f) $f.recorderRun.event = 'push' }
        'boolean source event is not a dispatch' = { param($f) $f.deploymentRun.event = $true }
        'recording actor mismatch' = { param($f) $f.recorderRun.actor = @{ id = 999; login = 'synthetic-other'; type = 'User' } }
        'record job has not passed the environment gate' = { param($f) $f.jobs.jobs[1].status = 'queued' }
        'downloaded source artifact checksum failure' = { param($f) $f.artifactDigestValid = $false }
        'release payload checksum failure' = { param($f) $f.payload = [Text.Encoding]::UTF8.GetBytes('changed synthetic release payload') }
        'release fingerprint mismatch' = { param($f) $f.source.releaseFingerprint = '0' * 64 }
        'source profile mismatch' = { param($f) $f.source.profileHash = '0' * 64 }
        'source configuration mismatch' = { param($f) $f.source.configurationHash = '0' * 64 }
        'source run identity mismatch' = { param($f) $f.source.workflowRunId = 999 }
        'health-only deployment status' = { param($f) $f.source.status = 'Healthy' }
        'P4 completion is only a plan' = { param($f) $f.source.completion.mode = 'plan' }
        'P4 simulated completion' = { param($f) $f.source.completion.mode = 'offline-test' }
        'P4 runner is not ready' = { param($f) $f.source.completion.runnerReady = $false }
        'P4 image differs from selected release' = { param($f) $f.source.completion.applications[0].image = 'synthetic/image:latest' }
        'P4 boolean application fields cannot claim the selected artifact' = { param($f) foreach ($key in @('name','resourceId','image','healthVersion','revision')) { $f.source.completion.applications[0][$key] = $true } }
        'P4 boolean environment cannot identify the deployment' = { param($f) $f.source.environment = $true }
        'P4 observed failed gate cannot be overridden' = { param($f) $f.source.liveGate.checks.privateConnectivity.status = 'failed' }
        'P4 nested uppercase failure cannot be hidden by a pending top-level gate' = { param($f) $f.source.liveGate.probes.recovery = @{ status = 'FAILED'; evidence = 'SYNTHETIC failed automatic observation.' } }
        'P4 fake boolean check cannot be overridden' = { param($f) $f.source.liveGate.checks.privateConnectivity = $true }
        'P4 wrong configuration identity' = { param($f) $f.source.liveGate.configurationHash = '0' * 64 }
        'P4 boolean workflow identity' = { param($f) $f.source.liveGate.workflowRunId = $true }
        'P4 array fingerprint is not a scalar identity' = { param($f) $f.source.liveGate.releaseFingerprint = @($f.source.releaseFingerprint) }
        'manifest is a passed boolean' = { param($f) $f.manifest.checks.privateConnectivity = $true; Update-ManifestFile $f }
        'manifest missing a gate' = { param($f) $f.manifest.checks.Remove('costOperations'); Update-ManifestFile $f }
        'manifest pending result' = { param($f) $f.manifest.checks.gatewayEnforcement.result.status = 'pending'; Update-ManifestFile $f }
        'manifest failed result' = { param($f) $f.manifest.checks.gatewayEnforcement.result.status = 'failed'; Update-ManifestFile $f }
        'manifest claims automatic proof' = { param($f) $f.manifest.evidenceKind = 'automated-proof'; Update-ManifestFile $f }
        'manifest wrong environment' = { param($f) $f.manifest.environment = 'prod'; Update-ManifestFile $f }
        'manifest wrong source deployment' = { param($f) $f.manifest.deploymentRunId++; Update-ManifestFile $f }
        'manifest wrong release fingerprint' = { param($f) $f.manifest.releaseFingerprint = '0' * 64; Update-ManifestFile $f }
        'manifest wrong configuration' = { param($f) $f.manifest.configurationHash = '0' * 64; Update-ManifestFile $f }
        'manifest cannot substitute the P4 resolution hash for deployed parameter identity' = { param($f) $f.manifest.configurationHash = $f.source.completion.configurationHash; Update-ManifestFile $f }
        'external evidence URL' = { param($f) $f.manifest.checks.recovery.evidence[0].path = 'https://example.invalid/passed.json'; Update-ManifestFile $f }
        'receipt traversal' = { param($f) $f.manifest.checks.recovery.evidence[0].path = 'environments/evidence/dev/../passed.json'; Update-ManifestFile $f }
        'receipt script path' = { param($f) $f.manifest.checks.recovery.evidence[0].path = 'environments/evidence/dev/receipts/run.ps1'; Update-ManifestFile $f }
        'receipt checksum mismatch' = { param($f) $f.manifest.checks.recovery.evidence[0].sha256 = '0' * 64; Update-ManifestFile $f }
        'receipt observer differs from manifest' = { param($f) $f.receipts.recovery.observedBy.id++; Update-EvidenceFiles $f }
        'unknown observer identity' = { param($f) $f.observerPermission.user.id++ }
        'boolean observer identity' = { param($f) $f.observerPermission.user.id = $true }
        'observer is not a repository collaborator' = { param($f) $f.observerPermission.permission = 'none' }
        'future observation' = { param($f) $f.receipts.recovery.observedAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); $f.manifest.checks.recovery.observedAt = $f.receipts.recovery.observedAt; Update-EvidenceFiles $f }
        'observation predates source deployment' = { param($f) $f.receipts.recovery.observedAt = $f.releaseRun.created_at; $f.manifest.checks.recovery.observedAt = $f.receipts.recovery.observedAt; Update-EvidenceFiles $f }
        'receipt result contradicts manifest' = { param($f) $f.receipts.recovery.result.status = 'failed'; Update-EvidenceFiles $f }
        'receipt has no observations' = { param($f) $f.receipts.recovery.observations = @(); Update-EvidenceFiles $f }
        'receipt observation is still pending' = { param($f) $f.receipts.recovery.observations[0].observed = 'pending'; Update-EvidenceFiles $f }
        'receipt summary reports failure' = { param($f) $f.receipts.recovery.result.summary = 'FAILED'; $f.manifest.checks.recovery.result.summary = 'FAILED'; Update-EvidenceFiles $f }
        'identity receipt lacks workload and human context' = { param($f) $f.receipts.identityIsolation.observations = @($f.receipts.identityIsolation.observations | Where-Object context -EQ 'runner'); Update-EvidenceFiles $f }
        'authorization header in receipt' = { param($f) $f.receipts.recovery.observations[0].observed = 'Authorization: Bearer synthetic-sensitive-value'; Update-EvidenceFiles $f }
        'prompt content in receipt' = { param($f) $f.receipts.recovery.observations[0].observed = 'prompt: synthetic-sensitive-value'; Update-EvidenceFiles $f }
        'completion content in receipt' = { param($f) $f.receipts.recovery.observations[0].observed = 'completion: synthetic-sensitive-value'; Update-EvidenceFiles $f }
        'SAS token in receipt' = { param($f) $f.receipts.recovery.observations[0].observed = 'https://example.invalid/blob?sig=synthetic-sensitive-value'; Update-EvidenceFiles $f }
        'secret field in receipt' = { param($f) $f.receipts.recovery.clientSecret = 'synthetic-sensitive-value'; Update-EvidenceFiles $f }
        'receipt link instead of regular git blob' = { param($f) $f.evidenceTree.tree[0].mode = '120000' }
        'truncated evidence tree' = { param($f) $f.evidenceTree.truncated = $true }
    }
    foreach ($case in $badCases.GetEnumerator()) {
        Test-Case $case.Key {
            $f = New-Fixture
            & $case.Value $f
            Assert-Rejected { Invoke-Fixture $f }
            Assert-NoPromotionFiles
        }
    }
    Test-Case 'Unsigned simple boolean file cannot stand in for a structured receipt' {
        $f = New-Fixture
        $path = $f.manifest.checks.recovery.evidence[0].path
        $file = New-GitFile $path $true
        $f.evidenceFiles[$path] = $file
        ($f.evidenceTree.tree | Where-Object path -CEQ $path).sha = $file.sha
        $f.manifest.checks.recovery.evidence[0].sha256 = Get-BytesHash ([Convert]::FromBase64String($file.content))
        Update-ManifestFile $f
        Assert-Rejected { Invoke-Fixture $f }
        Assert-NoPromotionFiles
    }
    Test-Case 'Empty receipt bytes cannot produce a promotion artifact' {
        $f = New-Fixture
        $path = $f.manifest.checks.recovery.evidence[0].path
        $f.evidenceFiles[$path].content = ''
        $f.evidenceFiles[$path].size = 0
        Assert-Rejected { Invoke-Fixture $f }
        Assert-NoPromotionFiles
    }
    Test-Case 'Production cannot reuse a dev deployment or an unapproved production profile' {
        $f = New-Fixture prod
        $f.source.environment = 'dev'
        Assert-Rejected { Invoke-Fixture $f }
        $f = New-Fixture prod
        $f.profile.production.approved = $false
        $f.configurationFile = New-GitFile 'environments/prod.json' $f.profile
        $f.configTree.tree[0].sha = $f.configurationFile.sha
        Assert-Rejected { Invoke-Fixture $f }
        Assert-NoPromotionFiles
    }
    Test-Case 'Existing-private cannot omit administrator runner approval fields' {
        foreach ($field in @('adminLogin', 'adminId', 'nsgResourceId', 'approvedNsgFingerprint', 'machineBindings')) {
            $f = New-Fixture -RunnerMode 'existing-private'
            $f.platformInputs.runner.Remove($field)
            Update-PlatformFile $f
            Assert-Rejected { Invoke-Fixture $f }
            Assert-NoPromotionFiles
        }
    }
    Test-Case 'The real profile reader rejects synthetic inputs on the recorder path' {
        $f = New-Fixture
        $f.syntheticReader = $false
        Assert-Rejected { Invoke-Fixture $f }
        Assert-NoPromotionFiles
    }
    Test-Case 'Workflow is manual, public-hosted and pre-gated before its protected record job' {
        $path = Join-Path $root '.github\workflows\record-live-gates.yml'
        $yaml = Get-Content -LiteralPath $path -Raw
        $workflow = ConvertFrom-Yaml -Yaml $yaml
        Assert-True ($workflow.on.Keys.Count -eq 1 -and $workflow.on.Contains('workflow_dispatch')) 'Recorder has an automatic or reusable trigger.'
        Assert-True ($workflow.permissions.contents -ceq 'read' -and $workflow.permissions.actions -ceq 'read' -and $workflow.permissions.Keys.Count -eq 2) 'Recorder grants write or Azure-token permissions.'
        Assert-True (-not $workflow.jobs.preflight.Contains('environment')) 'Pre-gate must not reference an environment before proving it exists.'
        Assert-True (@($workflow.jobs.record.needs) -contains 'preflight') 'Protected job can bypass readiness preflight.'
        Assert-True ($workflow.jobs.record.environment -ceq '${{ inputs.environment }}') 'Protected environment is not the exact selected environment.'
        Assert-True ($workflow.concurrency.'cancel-in-progress' -eq $false) 'Recording can cancel a running protected gate.'
        foreach ($job in $workflow.jobs.Values) {
            Assert-True ($job.'runs-on' -ceq 'ubuntu-latest') 'Recorder uses a private or privileged runner.'
            foreach ($step in $job.steps) {
                if ($step.Contains('run')) {
                    Assert-True ($step.run -notmatch '\$\{\{\s*(inputs|github\.event\.inputs)\.') 'Untrusted inputs are interpolated into executable script text.'
                }
                if ($step.Contains('uses')) {
                    Assert-True ($step.uses -cmatch '^actions/(checkout|upload-artifact)@[a-f0-9]{40}$') 'Recorder uses an unapproved action or floating pin.'
                }
            }
        }
        Assert-True ($yaml -match '3d3c42e5aac5ba805825da76410c181273ba90b1' -and $yaml -match '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a') 'Recorder action pins differ from the approved pins.'
        Assert-True ($yaml -match 'ExpectedPreflightHash' -and $yaml -match 'preflight_hash') 'Protected execution does not bind the pre-gate inputs.'
        Assert-True ($yaml -match 'ailz-promotion-' -and $yaml -match 'promotion.json') 'Promotion artifact naming/output contract is missing.'
        Assert-True ($yaml -notmatch 'azure/login|id-token|continue-on-error|pull_request_target') 'Recorder contains an Azure credential path or fail-open workflow.'
    }
    Test-Case 'Owned recorder code has no Azure, paid-probe, write-API or evidence-execution path' {
        foreach ($name in @('LiveEvidence.psm1', 'Record-LiveGateEvidence.ps1')) {
            $text = Get-Content -LiteralPath (Join-Path $root "scripts\github\$name") -Raw
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) 'Recorder code does not parse.'
            foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
                Assert-True ($command.GetCommandName() -notin @('az','azd','Invoke-WebRequest','Invoke-RestMethod','Invoke-Expression','Invoke-LiveDeveloperGate','Invoke-DeveloperCompletion')) 'Recorder can run a live probe, Azure operation or receipt code.'
                if ($command.GetCommandName() -eq 'Import-Module') {
                    Assert-True (@($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force' }).Count -eq 0) 'Nested forced import can unload parent exports.'
                }
            }
        }
    }
}
finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Module -ModuleInfo $module -ErrorAction Stop
    [IO.Directory]::Delete($scratch, $true)
}
Write-Host "Live evidence tests: $($script:count - $script:failures)/$script:count passed."
if ($script:failures) { throw "$script:failures live-evidence test(s) failed." }
