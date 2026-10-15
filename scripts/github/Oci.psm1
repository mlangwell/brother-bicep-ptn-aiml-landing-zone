#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')

function Read-OciJson {
    param([string]$Path)
    if ((Get-Item -LiteralPath $Path).Length -gt 16MB) { throw 'OCI metadata exceeds the local JSON safety limit.' }
    return (ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath $Path -Raw))
}

function Test-OciArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedDigest,
        [string]$Destination,
        [long]$MaximumExpandedBytes = 4GB
    )
    if ($MaximumExpandedBytes -le 0) { throw 'OCI expanded-size limit must be positive.' }
    $temporary = -not $Destination
    if ($temporary) { $Destination = Join-Path ([IO.Path]::GetTempPath()) "ailz-oci-$([guid]::NewGuid().ToString('N'))" }
    if (Test-Path -LiteralPath $Destination) { throw 'OCI extraction requires a new directory.' }
    $Destination = [IO.Path]::GetFullPath($Destination)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $succeeded = $false
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        $reader = [System.Formats.Tar.TarReader]::new($stream)
        try {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            [long]$bytes = 0
            while ($entry = $reader.GetNextEntry()) {
                $name = $entry.Name
                while ($name.StartsWith('./', [StringComparison]::Ordinal)) { $name = $name.Substring(2) }
                $directory = $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory
                if ($directory -and ($name -eq '' -or $name -eq '.')) { continue }
                if (-not $directory -and $entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile)) {
                    throw 'OCI archives may contain only regular files and directories, never links or devices.'
                }
                $name = Get-SafeRelativePath -Path $name -Directory:$directory
                if (-not $seen.Add($name)) { throw 'OCI archive contains duplicate or case-colliding paths.' }
                $target = Join-Path $Destination $name
                if ($directory) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
                if ($name -cnotmatch '^(oci-layout|index\.json|blobs/sha256/[a-f0-9]{64})$') { throw 'Unexpected file in OCI image layout.' }
                $bytes += $entry.Length
                if ($bytes -gt $MaximumExpandedBytes) { throw 'OCI archive exceeds the expanded-size safety limit.' }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { if ($entry.DataStream) { $entry.DataStream.CopyTo($output) } } finally { $output.Dispose() }
            }
        }
        finally { $reader.Dispose(); $stream.Dispose() }
        $layout = Read-OciJson (Join-Path $Destination 'oci-layout')
        if ($layout.imageLayoutVersion -cne '1.0.0') { throw 'Unsupported OCI layout version.' }
        foreach ($blob in Get-ChildItem -LiteralPath (Join-Path $Destination 'blobs\sha256') -File) {
            if ((Get-FileHash -LiteralPath $blob.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $blob.Name) { throw 'OCI blob content does not match its digest.' }
        }
        $index = Read-OciJson (Join-Path $Destination 'index.json')
        if ($index.schemaVersion -ne 2 -or $index.manifests.Count -ne 1) { throw 'The starter release requires exactly one Linux amd64 OCI image, not a multi-platform or attestation index.' }
        $descriptor = $index.manifests[0]
        if ($descriptor.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid OCI image digest.' }
        if ($ExpectedDigest -and $descriptor.digest -cne $ExpectedDigest) { throw 'OCI image differs from the release digest.' }
        $manifestPath = Join-Path $Destination "blobs\sha256\$($descriptor.digest.Substring(7))"
        if ((Get-Item -LiteralPath $manifestPath).Length -ne $descriptor.size) { throw 'OCI manifest size mismatch.' }
        $manifest = Read-OciJson $manifestPath
        if ($manifest.schemaVersion -ne 2 -or $manifest.mediaType -cne 'application/vnd.oci.image.manifest.v1+json') { throw 'Unsupported OCI image manifest.' }
        foreach ($item in @($manifest.config) + @($manifest.layers)) {
            if ($item.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid OCI configuration or layer digest.' }
            $blobPath = Join-Path $Destination "blobs\sha256\$($item.digest.Substring(7))"
            if ((Get-Item -LiteralPath $blobPath).Length -ne $item.size) { throw 'OCI configuration or layer size mismatch.' }
        }
        $config = Read-OciJson (Join-Path $Destination "blobs\sha256\$($manifest.config.digest.Substring(7))")
        if ($config.os -cne 'linux' -or $config.architecture -cne 'amd64') { throw 'Starter OCI image must target Linux amd64.' }
        $succeeded = $true
        return @{ digest = $descriptor.digest; configDigest = $manifest.config.digest; os = $config.os; architecture = $config.architecture; layoutPath = if ($temporary) { '' } else { $Destination } }
    }
    finally {
        if (($temporary -or -not $succeeded) -and (Test-Path -LiteralPath $Destination)) { Remove-Item -LiteralPath $Destination -Recurse }
    }
}

function Invoke-ReleaseTool {
    [CmdletBinding()]
    param([string]$Command, [string[]]$Arguments, [string]$InputText)
    if (-not $PSBoundParameters.ContainsKey('InputText')) {
        return (Invoke-CheckedNative -Command $Command -Arguments $Arguments)
    }
    $start = [Diagnostics.ProcessStartInfo]::new($Command)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Release tool could not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($InputText)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Release tool failed with exit code $($process.ExitCode); credentials and arguments were not logged." }
        return $stdout.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

function Import-ReleaseImage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Resolved,
        [Parameter(Mandatory)][string]$BundlePath,
        [switch]$Execute,
        [scriptblock]$Native = { param($Command, $Arguments, $InputText)
            if ($null -ne $InputText) { Invoke-ReleaseTool -Command $Command -Arguments $Arguments -InputText $InputText }
            else { Invoke-ReleaseTool -Command $Command -Arguments $Arguments }
        },
        [scriptblock]$Request = { param($Method, $Uri, $Headers, $Body)
            $options = @{ Method = $Method; Uri = $Uri; Headers = $Headers; MaximumRedirection = 0; TimeoutSec = 60; SkipHttpErrorCheck = $true; Verbose = $false; Debug = $false }
            if ($null -ne $Body) { $options.Body = $Body; $options.ContentType = 'application/x-www-form-urlencoded' }
            Invoke-WebRequest @options
        }
    )
    $profile = $Resolved.profile
    if ($Execute -and $profile.synthetic) { throw 'Synthetic fixtures cannot be imported into a registry.' }
    $null = Test-ReleaseBundle -BundlePath $BundlePath -ExpectedRelease $profile.release
    $image = Test-OciArchive -Path (Join-Path $BundlePath 'image.oci.tar') -ExpectedDigest $profile.release.imageDigest
    $registryId = $profile.application.registryResourceId
    if ($registryId -cnotmatch '^/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[^/]+/providers/Microsoft\.ContainerRegistry/registries/([a-zA-Z0-9]+)$') { throw 'Invalid target registry resource ID.' }
    $registryName = $Matches[1]
    $repository = $profile.application.imageRepository
    if ($repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$') { throw 'Invalid target image repository.' }
    $targetTag = "release-$($profile.release.runId)-$($profile.release.runAttempt)-$($profile.release.sourceSha)"
    $plan = @{ operation = 'ImportExactOciImage'; registryResourceId = $registryId; repository = $repository; tag = $targetTag; digest = $image.digest; executed = $false }
    if (-not $Execute -or -not $PSCmdlet.ShouldProcess($registryId, 'Import the selected immutable OCI image without rebuilding')) { return $plan }

    $registry = ConvertFrom-BootstrapJson -Json (& $Native 'az' @('acr', 'show', '--ids', $registryId, '--only-show-errors', '--output', 'json') $null)
    if ($registry.id -ine $registryId -or $registry.publicNetworkAccess -cne 'Disabled') { throw 'The target registry must already exist with public network access disabled.' }
    $server = $registry.loginServer
    if ($server -cnotmatch '^[a-z0-9]+\.azurecr\.io$') { throw 'This profile supports only verified Azure public-cloud registry endpoints.' }
    $login = ConvertFrom-BootstrapJson -Json (& $Native 'az' @('acr', 'login', '--name', $registryName, '--subscription', $registryId.Split('/')[2], '--expose-token', '--only-show-errors', '--output', 'json') $null)
    if ($login.loginServer -cne $server -or [string]::IsNullOrWhiteSpace($login.accessToken)) { throw 'Registry Entra authentication returned an unexpected endpoint or empty token.' }
    $tokenResponse = & $Request 'POST' "https://$server/oauth2/token" @{} @{
        grant_type = 'refresh_token'; service = $server; scope = "repository:${repository}:pull,push"; refresh_token = $login.accessToken
    }
    if ($tokenResponse.StatusCode -ne 200) { throw "Registry token exchange failed with HTTP $($tokenResponse.StatusCode)." }
    $access = (ConvertFrom-BootstrapJson -Json $tokenResponse.Content).access_token
    if ([string]::IsNullOrWhiteSpace($access)) { throw 'Registry token exchange returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $access"; Accept = 'application/vnd.oci.image.manifest.v1+json' }
    $manifestUri = "https://$server/v2/$repository/manifests/$targetTag"
    $existing = & $Request 'HEAD' $manifestUri $headers $null
    if ($existing.StatusCode -eq 200) {
        $existingDigest = [string](@($existing.Headers['Docker-Content-Digest'])[0])
        if ($existingDigest -cne $image.digest) { throw 'An existing release tag belongs to different image content; it will not be overwritten.' }
        return @{ executed = $false; reused = $true; image = "$server/$repository@$($image.digest)"; digest = $image.digest }
    }
    if ($existing.StatusCode -ne 404) { throw "Registry manifest inspection failed with HTTP $($existing.StatusCode)." }
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "ailz-import-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        $layout = Test-OciArchive -Path (Join-Path $BundlePath 'image.oci.tar') -ExpectedDigest $image.digest -Destination (Join-Path $scratch 'layout')
        $authFile = Join-Path $scratch 'registry-auth.json'
        $null = & $Native 'oras' @('login', $server, '--username', '00000000-0000-0000-0000-000000000000', '--password-stdin', '--registry-config', $authFile) $login.accessToken
        $target = "${server}/${repository}:$targetTag"
        $null = & $Native 'oras' @('cp', '--from-oci-layout', "$($layout.layoutPath)@$($image.digest)", $target, '--to-registry-config', $authFile) $null
        $actual = & $Request 'HEAD' $manifestUri $headers $null
        if ($actual.StatusCode -ne 200 -or [string](@($actual.Headers['Docker-Content-Digest'])[0]) -cne $image.digest) { throw 'Private registry import did not preserve the selected OCI digest.' }
        return @{ executed = $true; reused = $false; image = "$server/$repository@$($image.digest)"; digest = $image.digest }
    }
    finally {
        $access = $null
        $login.accessToken = $null
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    }
}

Export-ModuleMember -Function Test-OciArchive, Import-ReleaseImage, Invoke-ReleaseTool
