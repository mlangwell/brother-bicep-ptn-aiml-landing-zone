#Requires -Version 7.4
param([switch]$RequireOras)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts\github\Environment.psm1') -Force
Import-Module (Join-Path $root 'scripts\github\Delivery.psm1')
Import-Module (Join-Path $root 'scripts\github\Oci.psm1') -Force
$count = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "ailz-oci-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $temp 'layout\blobs\sha256') -Force | Out-Null
function Add-Blob([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    [IO.File]::WriteAllBytes((Join-Path $temp "layout\blobs\sha256\$hash"), $bytes)
    return @{ digest = "sha256:$hash"; size = $bytes.Length }
}
try {
    $config = Add-Blob '{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}'
    $config.mediaType = 'application/vnd.oci.image.config.v1+json'
    $manifest = Add-Blob (ConvertTo-Json -InputObject @{
        schemaVersion = 2
        mediaType = 'application/vnd.oci.image.manifest.v1+json'
        config = $config
        layers = @()
    } -Depth 10 -Compress)
    $manifest.mediaType = 'application/vnd.oci.image.manifest.v1+json'
    [IO.File]::WriteAllText((Join-Path $temp 'layout\oci-layout'), '{"imageLayoutVersion":"1.0.0"}')
    [IO.File]::WriteAllText((Join-Path $temp 'layout\index.json'), (ConvertTo-Json -InputObject @{schemaVersion=2; manifests=@($manifest)} -Depth 10 -Compress))
    $archive = Join-Path $temp 'image.oci.tar'
    [System.Formats.Tar.TarFile]::CreateFromDirectory((Join-Path $temp 'layout'), $archive, $false)
    $result = Test-OciArchive -Path $archive
    Assert-True ($result.digest -ceq $manifest.digest) 'OCI manifest digest was not preserved.'
    Assert-True ($result.os -ceq 'linux' -and $result.architecture -ceq 'amd64') 'OCI platform was not verified from its configuration.'
    Assert-Rejected { Test-OciArchive -Path $archive -ExpectedDigest ('sha256:' + ('f' * 64)) } 'A substituted OCI digest was accepted.'

    $oras = Get-Command oras -ErrorAction SilentlyContinue
    if ($oras) {
        $sourceLayout = Join-Path $temp 'layout'
        $targetLayout = Join-Path $temp 'copied-layout'
        & $oras.Source cp --from-oci-layout "${sourceLayout}@$($manifest.digest)" --to-oci-layout "${targetLayout}:selected" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Local ORAS digest-preserving copy failed.' }
        $copied = & $oras.Source manifest fetch --descriptor --oci-layout "${targetLayout}:selected"
        if ($LASTEXITCODE -ne 0) { throw 'Local ORAS manifest probe failed.' }
        Assert-True (($copied | ConvertFrom-Json).digest -ceq $manifest.digest) 'ORAS changed the image digest during transfer.'
    } elseif ($RequireOras) { throw 'ORAS is required for the local transport gate; install the pinned session tool.' }
    else { Write-Host 'SKIP: local ORAS copy probe (pinned ORAS not on PATH).' }

    $sourceRepo = Join-Path $temp 'source'
    New-Item -ItemType Directory -Path (Join-Path $sourceRepo '.azure') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceRepo 'main.bicep'), "targetScope = 'resourceGroup'")
    [IO.File]::WriteAllText((Join-Path $sourceRepo 'manifest.json'), '{"tag":"v2.6.1"}')
    [IO.File]::WriteAllText((Join-Path $sourceRepo '.gitignore'), ".azure`n")
    [IO.File]::WriteAllText((Join-Path $sourceRepo '.azure\synthetic-private-state'), 'synthetic private fixture; never release')
    & git -C $sourceRepo init --quiet --initial-branch main
    if ($LASTEXITCODE -ne 0) { throw 'Fixture repository initialization failed.' }
    & git -C $sourceRepo add -- main.bicep manifest.json .gitignore
    if ($LASTEXITCODE -ne 0) { throw 'Fixture repository staging failed.' }
    & git -C $sourceRepo -c user.name='Synthetic fixture' -c user.email='fixture@example.invalid' commit --quiet -m 'Synthetic release fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Fixture repository commit failed.' }
    $sourceSha = & git -C $sourceRepo rev-parse HEAD
    $compiled = Join-Path $temp 'compiled.json'
    [IO.File]::WriteAllText($compiled, '{"resources":[]}')
    $builtBundle = Join-Path $temp 'built-bundle'
    $builder = Join-Path $root 'scripts\github\New-ReleaseBundle.ps1'
    $null = & $builder -SourceRoot $sourceRepo -CompiledTemplatePath $compiled -OciArchivePath $archive -OutputDirectory $builtBundle -Repository 'synthetic-owner/synthetic-repo' -RunId 101 -RunAttempt 1 -SourceSha $sourceSha -Ref 'refs/heads/main'
    $builtManifest = Get-Content (Join-Path $builtBundle 'bundle.json') -Raw | ConvertFrom-Json -AsHashtable
    $fullProfile = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
    $fullProfile.release.infrastructureVersion = $builtManifest.release.infrastructureVersion
    $resolvedBundleVersion = Resolve-EnvironmentProfile -Profile $fullProfile -AllowSynthetic
    Assert-True ($resolvedBundleVersion.profile.release.infrastructureVersion -ceq $builtManifest.release.infrastructureVersion) 'The actual bundle version cannot pass the real environment contract unchanged.'
    $verifiedBundle = Test-ReleaseBundle -BundlePath $builtBundle -ExpectedRelease $builtManifest.release
    Assert-True ($verifiedBundle.manifest.release.sourceSha -ceq $sourceSha) 'Bundle was not bound to its committed source.'
    Assert-True ($verifiedBundle.manifest.release.imageDigest -ceq $manifest.digest) 'Builder changed the tested OCI identity.'
    Assert-True (-not (Test-Path (Join-Path $builtBundle 'payload\.azure'))) 'Private local azd state entered a release bundle.'
    [IO.File]::WriteAllText((Join-Path $sourceRepo 'main.bicep'), "targetScope = 'subscription'")
    Assert-Rejected { & $builder -SourceRoot $sourceRepo -CompiledTemplatePath $compiled -OciArchivePath $archive -OutputDirectory (Join-Path $temp 'dirty-bundle') -Repository 'synthetic-owner/synthetic-repo' -RunId 101 -RunAttempt 1 -SourceSha $sourceSha -Ref 'refs/heads/main' } 'Dirty source masqueraded as an immutable release.'

    $bundle = Join-Path $temp 'bundle'
    New-Item -ItemType Directory -Path (Join-Path $bundle 'payload') -Force | Out-Null
    Copy-Item -LiteralPath $archive -Destination (Join-Path $bundle 'image.oci.tar')
    [IO.File]::WriteAllText((Join-Path $bundle 'payload\main.json'), '{"resources":[]}')
    $release = @{ imageDigest=$manifest.digest; runId=101; runAttempt=1; sourceSha=('a' * 40) }
    Write-JsonFile -Path (Join-Path $bundle 'bundle.json') -Value @{
        schemaVersion=1; configurationSchemaVersion=1; release=$release
        files=@{
            'payload/main.json'=(Get-FileHash (Join-Path $bundle 'payload\main.json')).Hash.ToLowerInvariant()
            'image.oci.tar'=(Get-FileHash (Join-Path $bundle 'image.oci.tar')).Hash.ToLowerInvariant()
        }
    }
    $registryId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/synthetic/providers/Microsoft.ContainerRegistry/registries/synthetic'
    $resolved = @{ profile=@{ synthetic=$false; release=$release; application=@{ registryResourceId=$registryId; imageRepository='developer-smoke' } } }
    $state = @{ orasWrites=0; headCalls=0; existingDigest=$manifest.digest; manifestMissing=$false }
    $native = {
        param($Command, $Arguments, $InputText)
        if ($Command -eq 'oras') { $state.orasWrites++; return '' }
        if ($Arguments[1] -eq 'show') { return (@{id=$registryId;publicNetworkAccess='Disabled';loginServer='synthetic.azurecr.io'} | ConvertTo-Json -Compress) }
        if ($Arguments[1] -eq 'login') { return '{"loginServer":"synthetic.azurecr.io","accessToken":"synthetic-not-a-credential"}' }
        throw 'Unexpected native operation in registry test.'
    }.GetNewClosure()
    $request = {
        param($Method, $Uri, $Headers, $Body)
        if ($Method -eq 'POST') { return @{StatusCode=200;Content='{"access_token":"synthetic-not-a-credential"}'} }
        if ($Method -eq 'HEAD') {
            $state.headCalls++
            if ($state.manifestMissing -and $state.headCalls -eq 1) { return @{StatusCode=404;Headers=@{}} }
            return @{StatusCode=200;Headers=@{'Docker-Content-Digest'=$state.existingDigest}}
        }
        throw 'Unexpected registry mutation in test.'
    }.GetNewClosure()
    $reused = Import-ReleaseImage -Resolved $resolved -BundlePath $bundle -Execute -Native $native -Request $request -Confirm:$false
    Assert-True ($reused.reused -and $state.orasWrites -eq 0) 'An existing identical registry image was rewritten.'
    $state.existingDigest = 'sha256:' + ('e' * 64)
    Assert-Rejected { Import-ReleaseImage -Resolved $resolved -BundlePath $bundle -Execute -Native $native -Request $request -Confirm:$false } 'A conflicting registry tag was overwritten.'
    Assert-True ($state.orasWrites -eq 0) 'Registry conflict still reached a write.'
    $state.existingDigest = $manifest.digest
    $state.manifestMissing = $true
    $state.headCalls = 0
    $imported = Import-ReleaseImage -Resolved $resolved -BundlePath $bundle -Execute -Native $native -Request $request -Confirm:$false
    Assert-True ($imported.executed -and $state.headCalls -eq 2 -and $state.orasWrites -eq 2) 'An OCI import was not followed by a digest verification.'

    [IO.File]::WriteAllText((Join-Path $temp "layout\blobs\sha256\$($config.digest.Substring(7))"), '{"tampered":true}')
    $tampered = Join-Path $temp 'tampered.oci.tar'
    [System.Formats.Tar.TarFile]::CreateFromDirectory((Join-Path $temp 'layout'), $tampered, $false)
    Assert-Rejected { Test-OciArchive -Path $tampered } 'A tampered OCI blob was accepted.'

    foreach ($entryType in @([System.Formats.Tar.TarEntryType]::SymbolicLink, [System.Formats.Tar.TarEntryType]::HardLink, [System.Formats.Tar.TarEntryType]::RegularFile)) {
        $unsafe = Join-Path $temp "$([guid]::NewGuid().ToString('N')).tar"
        $stream = [IO.File]::Create($unsafe)
        $writer = [System.Formats.Tar.TarWriter]::new($stream)
        try {
            $entry = [System.Formats.Tar.PaxTarEntry]::new($entryType, '../escape')
            if ($entryType -ne [System.Formats.Tar.TarEntryType]::RegularFile) { $entry.LinkName = '../escape-target' }
            else { $entry.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('unsafe')) }
            $writer.WriteEntry($entry)
        } finally { $writer.Dispose(); $stream.Dispose() }
        Assert-Rejected { Test-OciArchive -Path $unsafe } 'An OCI link or traversal entry was accepted.'
    }
    Assert-Rejected { Import-ReleaseImage -Resolved @{profile=@{synthetic=$true}} -BundlePath $temp -Execute } 'Synthetic data reached an image registry write.'
    Write-Host "OCI: $count assertions passed."
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
