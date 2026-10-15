#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination, [switch]$IncludeWorkflowValidator)
$ErrorActionPreference = 'Stop'
$pins = Get-Content (Join-Path $PSScriptRoot 'release-tools.json') -Raw | ConvertFrom-Json -AsHashtable
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'This release path requires an x64 runner.'
}
$platform = if ($IsWindows) { 'windows_amd64' } elseif ($IsLinux) { 'linux_amd64' } else { throw 'Release tooling supports Windows and Linux only.' }
$Destination = [IO.Path]::GetFullPath($Destination)
$tools = @('oras')
if ($IncludeWorkflowValidator) { $tools += 'actionlint' }
foreach ($tool in $tools) {
    $pin = $pins[$tool][$platform]
    $executable = Join-Path $Destination $(if ($IsWindows) { "$tool.exe" } else { $tool })
    $receiptPath = Join-Path $Destination "$tool-install.json"
    if (Test-Path -LiteralPath $executable) {
        if (-not (Test-Path -LiteralPath $receiptPath)) { throw "An unowned $tool binary already exists; use a different tools directory." }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        if ($receipt.archiveHash -cne $pin.sha256 -or $receipt.binaryHash -cne (Get-FileHash -LiteralPath $executable).Hash.ToLowerInvariant()) {
            throw "Installed $tool content does not match its verified receipt."
        }
        continue
    }
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "ailz-tools-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        $archive = Join-Path $scratch $pin.file
        $url = $pins[$tool].source.Replace('/releases/tag/', '/releases/download/') + '/' + $pin.file
        Invoke-WebRequest -Uri $url -OutFile $archive -TimeoutSec 120
        if ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -cne $pin.sha256) { throw "$tool distribution checksum mismatch." }
        $expanded = Join-Path $scratch 'expanded'
        New-Item -ItemType Directory -Path $expanded | Out-Null
        if ($IsWindows) { Expand-Archive -LiteralPath $archive -DestinationPath $expanded }
        else {
            & tar -xzf $archive -C $expanded
            if ($LASTEXITCODE -ne 0) { throw "Verified $tool archive extraction failed." }
        }
        $source = Join-Path $expanded ([IO.Path]::GetFileName($executable))
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Verified distribution lacks the expected $tool executable." }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $executable
        if ($IsLinux) {
            & chmod u+x $executable
            if ($LASTEXITCODE -ne 0) { throw "Cannot make the verified $tool executable runnable." }
        }
        $license = Join-Path $expanded 'LICENSE'
        if (Test-Path -LiteralPath $license) { Copy-Item -LiteralPath $license -Destination (Join-Path $Destination "$tool-LICENSE") }
        @{
            version = $pins[$tool].version
            archiveHash = $pin.sha256
            binaryHash = (Get-FileHash -LiteralPath $executable).Hash.ToLowerInvariant()
        } | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
        $versionArgument = if ($tool -ceq 'oras') { 'version' } else { '-version' }
        & $executable $versionArgument
        if ($LASTEXITCODE -ne 0) { throw "Installed $tool version probe failed." }
    }
    finally {
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse }
    }
}
Write-Output $Destination
