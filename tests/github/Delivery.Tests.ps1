#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts\github\Environment.psm1') -Force
Import-Module (Join-Path $root 'scripts\github\Delivery.psm1') -Force
$script:count = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}
function Copy-Value($Value) {
    ConvertTo-Json -InputObject $Value -Depth 100 | ConvertFrom-Json -AsHashtable
}

$profile = @{
    environment = 'dev'
    synthetic = $true
    github = @{
        repository = 'synthetic-owner/synthetic-repo'; repositoryId = 9002; ownerId = 9001
        protectedRef = 'refs/heads/main'
    }
    release = @{
        repository = 'synthetic-owner/synthetic-repo'; runId = 101; runAttempt = 1
        sourceSha = 'a' * 40; workflow = '.github/workflows/bicep-validate.yml'; ref = 'refs/heads/main'
        infrastructureVersion = 'v2.6.1'; imageDigest = 'sha256:' + ('b' * 64)
        artifactName = 'ailz-release-101-1'
    }
}
$repository = @{ id = 9002; full_name = $profile.github.repository; owner = @{ id = 9001 } }
$workflow = @{ id = 19; path = $profile.release.workflow }
$run = @{
    id = 101; run_attempt = 1; workflow_id = 19; event = 'push'
    status = 'completed'; conclusion = 'success'; head_sha = 'a' * 40; head_branch = 'main'
    head_repository = @{ id = 9002; full_name = $profile.github.repository }
}
Assert-TrustedReleaseRun -Profile $profile -Repository $repository -Workflow $workflow -Run $run
$script:count++
foreach ($mutation in @(
    { param($r) $r.event = 'pull_request' },
    { param($r) $r.conclusion = 'failure' },
    { param($r) $r.status = 'in_progress' },
    { param($r) $r.head_repository.id = 9999 },
    { param($r) $r.head_repository.full_name = 'fork/synthetic-repo' },
    { param($r) $r.head_sha = 'c' * 40 },
    { param($r) $r.head_branch = 'untrusted' },
    { param($r) $r.workflow_id = 99 },
    { param($r) $r.run_attempt = 2 }
)) {
    $bad = Copy-Value $run
    & $mutation $bad
    Assert-Rejected { Assert-TrustedReleaseRun -Profile $profile -Repository $repository -Workflow $workflow -Run $bad } 'Untrusted CI provenance was accepted.'
}
$badRepository = Copy-Value $repository
$badRepository.owner.id = 9999
Assert-Rejected { Assert-TrustedReleaseRun -Profile $profile -Repository $badRepository -Workflow $workflow -Run $run } 'Repository transfer was accepted.'

$temp = Join-Path ([IO.Path]::GetTempPath()) "ailz-delivery-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $bundle = Join-Path $temp 'bundle'
    New-Item -ItemType Directory -Path (Join-Path $bundle 'payload') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $bundle 'payload\main.json'), '{"resources":[]}')
    [IO.File]::WriteAllText((Join-Path $bundle 'image.oci.tar'), 'synthetic image fixture; never deploy')
    $manifest = @{
        schemaVersion = 1; configurationSchemaVersion = 1; release = $profile.release
        files = @{
            'payload/main.json' = (Get-FileHash (Join-Path $bundle 'payload\main.json')).Hash.ToLowerInvariant()
            'image.oci.tar' = (Get-FileHash (Join-Path $bundle 'image.oci.tar')).Hash.ToLowerInvariant()
        }
    }
    Write-JsonFile -Path (Join-Path $bundle 'bundle.json') -Value $manifest
    $verified = Test-ReleaseBundle -BundlePath $bundle -ExpectedRelease $profile.release
    Assert-True ($verified.fingerprint -match '^[a-f0-9]{64}$') 'Bundle identity is not a digest.'
    [IO.File]::WriteAllText((Join-Path $bundle 'payload\main.json'), '{"resources":[{"changed":true}]}')
    Assert-Rejected { Test-ReleaseBundle -BundlePath $bundle -ExpectedRelease $profile.release } 'Changed payload was accepted.'
    [IO.File]::WriteAllText((Join-Path $bundle 'payload\main.json'), '{"resources":[]}')
    [IO.File]::WriteAllText((Join-Path $bundle 'payload\unexpected.ps1'), 'throw "untrusted"')
    Assert-Rejected { Test-ReleaseBundle -BundlePath $bundle -ExpectedRelease $profile.release } 'Unlisted executable was accepted.'
    Remove-Item -LiteralPath (Join-Path $bundle 'payload\unexpected.ps1')
    $badRelease = Copy-Value $profile.release
    $badRelease.imageDigest = 'sha256:' + ('d' * 64)
    Assert-Rejected { Test-ReleaseBundle -BundlePath $bundle -ExpectedRelease $badRelease } 'Rebuilt or substituted image was accepted.'
    $badManifest = Copy-Value $manifest
    $badManifest.files['../outside.ps1'] = 'd' * 64
    Write-JsonFile -Path (Join-Path $bundle 'bundle.json') -Value $badManifest
    Assert-Rejected { Test-ReleaseBundle -BundlePath $bundle -ExpectedRelease $profile.release } 'Bundle path traversal was accepted.'
    Write-JsonFile -Path (Join-Path $bundle 'bundle.json') -Value $manifest

    foreach ($unsafeName in @('../escape.txt', '/absolute.txt', 'C:/escape.txt', 'payload\escape.txt', 'payload/../escape.txt')) {
        $zipPath = Join-Path $temp "$([guid]::NewGuid().ToString('N')).zip"
        $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry($unsafeName)
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('unsafe') } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        Assert-Rejected { Expand-VerifiedZip -Path $zipPath -Destination (Join-Path $temp ([guid]::NewGuid().ToString('N'))) } "Unsafe ZIP entry was extracted: $unsafeName"
        Assert-True (-not (Test-Path (Join-Path (Split-Path $temp) 'escape.txt'))) 'Archive wrote outside its extraction root.'
    }

    $parameters = @{ parameters = @{ deployApiManagement = @{ value = $true } } }
    $observed = @{ gatewayExists = $false; publicNetworkAccess = ''; privateEndpointIds = @() }
    $preview = New-PreviewRecord -Profile $profile -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -WhatIfHash ('e' * 64) -GatewayPlanHash ('a' * 64) -WhatIfSummary @{ status='Succeeded' }
    Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -ApprovedHash $preview.hash
    $script:count++
    $alteredPreview = Copy-Value $preview
    $alteredPreview.gatewayPlanHash = 'b' * 64
    Assert-Rejected { Assert-PreviewRecord -Record $alteredPreview -Profile $profile -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -ApprovedHash $preview.hash } 'Gateway policy/ownership evidence could be replaced without invalidating approval.'
    $alteredPreview = Copy-Value $preview
    $alteredPreview.whatIfSummary.status = 'Failed'
    Assert-Rejected { Assert-PreviewRecord -Record $alteredPreview -Profile $profile -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -ApprovedHash $preview.hash } 'The displayed What-If summary was not bound to approval.'
    $changed = Copy-Value $profile
    $changed.environment = 'test'
    Assert-Rejected { Assert-PreviewRecord -Record $preview -Profile $changed -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -ApprovedHash $preview.hash } 'Changed environment reused approval.'
    $changedParameters = Copy-Value $parameters
    $changedParameters.parameters.deployApiManagement.value = $false
    Assert-Rejected { Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $changedParameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -ApprovedHash $preview.hash } 'Changed parameters reused approval.'
    $changedState = @{ gatewayExists = $true; publicNetworkAccess = 'Disabled'; privateEndpointIds = @('synthetic-private-endpoint') }
    Assert-Rejected { Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $changedState -ApprovedHash $preview.hash } 'An initial APIM plan could re-enable a now-private gateway.'
    Assert-Rejected { Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $parameters -BundleFingerprint ('f' * 64) -ObservedState $observed -ApprovedHash $preview.hash } 'Changed artifact reused approval.'
    Assert-Rejected { Assert-PreviewRecord -Record $preview -Profile $profile -Parameters $parameters -BundleFingerprint $verified.fingerprint -ObservedState $observed -ApprovedHash $preview.hash -PlatformHash ('a' * 64) } 'Changed platform inputs reused approval.'

    $promotion = @{
        schemaVersion = 1; environment = 'dev'; releaseFingerprint = $verified.fingerprint
        workflowRunId = 201; promotionEligible = $true; configurationHash = 'c' * 64
        checks = @{}
    }
    foreach ($gate in Get-RequiredLiveGates) {
        $promotion.checks[$gate] = @{ status = 'passed'; evidence = 'synthetic observed test evidence' }
    }
    Assert-PromotionRecord -Record $promotion -TargetEnvironment 'test' -ReleaseFingerprint $verified.fingerprint -ExpectedWorkflowRunId 201
    $script:count++
    Assert-Rejected { Assert-PromotionRecord -Record $promotion -TargetEnvironment 'prod' -ReleaseFingerprint $verified.fingerprint -ExpectedWorkflowRunId 201 } 'Production skipped test.'
    $promotion.checks.applicationInference.status = 'pending'
    Assert-Rejected { Assert-PromotionRecord -Record $promotion -TargetEnvironment 'test' -ReleaseFingerprint $verified.fingerprint -ExpectedWorkflowRunId 201 } 'Health-only evidence qualified for promotion.'
    $promotion.checks.applicationInference.status = 'passed'
    Assert-Rejected { Assert-PromotionRecord -Record $promotion -TargetEnvironment 'test' -ReleaseFingerprint ('f' * 64) -ExpectedWorkflowRunId 201 } 'A different release qualified for promotion.'
    $promotion.promotionEligible = $false
    Assert-Rejected { Assert-PromotionRecord -Record $promotion -TargetEnvironment 'test' -ReleaseFingerprint $verified.fingerprint -ExpectedWorkflowRunId 201 } 'Pending readiness qualified for promotion.'

    Write-Host "Delivery: $script:count assertions passed."
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse }
}
