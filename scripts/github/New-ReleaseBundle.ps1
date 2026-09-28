#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$CompiledTemplatePath,
    [Parameter(Mandatory)][string]$OciArchivePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][long]$RunId,
    [Parameter(Mandatory)][int]$RunAttempt,
    [Parameter(Mandatory)][string]$SourceSha,
    [Parameter(Mandatory)][string]$Ref
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Oci.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')

if ($RunId -le 0 -or $RunAttempt -le 0 -or $SourceSha -cnotmatch '^[a-f0-9]{40}$' -or $Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Ref -cnotmatch '^refs/heads/[^:*?\\]+$') {
    throw 'A release requires an exact repository, push ref, source commit, run and attempt.'
}
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$actualSha = (Invoke-CheckedNative -Command 'git' -Arguments @('-C', $SourceRoot, 'rev-parse', 'HEAD')).Trim()
if ($actualSha -cne $SourceSha) { throw 'Source checkout differs from the release commit.' }
$status = Invoke-CheckedNative -Command 'git' -Arguments @('-C', $SourceRoot, 'status', '--porcelain')
if (-not [string]::IsNullOrWhiteSpace([string]$status)) { throw 'Release bundles require a clean committed source tree; local changes cannot masquerade as a commit.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Release output directory already exists; it will not be overwritten.' }
$infra = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath (Join-Path $SourceRoot 'manifest.json') -Raw)
if ($infra.tag -cnotmatch '^v\d+\.\d+\.\d+$') { throw 'Infrastructure manifest is not version-pinned.' }
$compiled = Get-Content -LiteralPath $CompiledTemplatePath -Raw | ConvertFrom-Json -AsHashtable
if (-not $compiled.Contains('resources')) { throw 'Compiled infrastructure payload is not an ARM template.' }
$image = Test-OciArchive -Path $OciArchivePath
$tracked = (Invoke-CheckedNative -Command 'git' -Arguments @('-C', $SourceRoot, 'ls-files')) -split '\r?\n'
$selected = @($tracked | Where-Object {
    $_ -cmatch '^(main\.bicep|main\.parameters\.json|manifest\.json|azure\.yaml|LICENSE|modules/.+|constants/.+|scripts/.+|platform/.+|environments/(schema|live-evidence\.schema)\.json|samples/developer-smoke/.+)$'
})
foreach ($relative in $selected) {
    $null = Get-SafeRelativePath -Path $relative
    $source = Get-Item -LiteralPath (Join-Path $SourceRoot $relative)
    if ($source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Release inputs must be regular committed files.' }
}
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'payload') -Force | Out-Null
foreach ($relative in $selected) {
    $target = Join-Path (Join-Path $OutputDirectory 'payload') $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($target))) | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination $target
}
Copy-Item -LiteralPath $CompiledTemplatePath -Destination (Join-Path $OutputDirectory 'payload\main.json')
Copy-Item -LiteralPath $OciArchivePath -Destination (Join-Path $OutputDirectory 'image.oci.tar')
$files = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Sort-Object FullName) {
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($OutputDirectory), $file.FullName).Replace('\', '/')
    $files[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$release = @{
    repository = $Repository
    runId = $RunId
    runAttempt = $RunAttempt
    sourceSha = $SourceSha
    workflow = '.github/workflows/bicep-validate.yml'
    ref = $Ref
    infrastructureVersion = $infra.tag
    imageDigest = $image.digest
    artifactName = "ailz-release-$RunId-$RunAttempt"
}
$manifest = @{ schemaVersion = 1; configurationSchemaVersion = 1; release = $release; files = $files }
Write-JsonFile -Path (Join-Path $OutputDirectory 'bundle.json') -Value $manifest
$verified = Test-ReleaseBundle -BundlePath $OutputDirectory -ExpectedRelease $release
Write-Output (@{ release = $release; fingerprint = $verified.fingerprint } | ConvertTo-Json -Depth 10 -Compress)
