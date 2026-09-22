#Requires -Version 7.0
<#
.SYNOPSIS
Resolves one validated, nonsecret profile into deterministic local JSON files.
.DESCRIPTION
Writes resolved.json and main.parameters.json under an explicit output directory.
Does not print resolved values, call Azure, GitHub or azd, or use .azure state.
AllowSynthetic enables offline fixtures only. Deployment execution entry points
must use the shared module without offering or forwarding that switch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$AllowSynthetic
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
$root = [IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$inputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
$trim = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ($output.TrimEnd($trim) -ieq $root.TrimEnd($trim)) {
    throw 'OutputDirectory must not be the repository root: legacy main.parameters.json is read-only to this path.'
}
if (($output -split '[\\/]') -icontains '.azure') { throw 'OutputDirectory must not target .azure state.' }
$ancestor = [IO.Path]::GetFullPath($output)
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'OutputDirectory must use real directories, not files, symbolic links or junctions.'
        }
    }
    $parent = [IO.Directory]::GetParent($ancestor)
    $ancestor = if ($null -ne $parent) { $parent.FullName } else { $null }
}
foreach ($name in @('resolved.json', 'main.parameters.json')) {
    if ((Join-Path $output $name) -ieq $inputPath) { throw 'OutputDirectory would overwrite the source environment profile.' }
}

$profile = Read-EnvironmentProfile -Path $inputPath -AllowSynthetic:$AllowSynthetic
$resolved = Resolve-EnvironmentProfile -Profile $profile -AllowSynthetic:$AllowSynthetic
Write-JsonFile -Path (Join-Path $output 'resolved.json') -Value $resolved
Write-JsonFile -Path (Join-Path $output 'main.parameters.json') -Value $resolved.parameters
