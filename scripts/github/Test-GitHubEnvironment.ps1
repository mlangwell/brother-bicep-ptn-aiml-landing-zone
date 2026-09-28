#Requires -Version 7.4
[CmdletBinding()]
param([string]$TemplatePath, [switch]$RequireOras)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tests = Join-Path $root 'tests\github'
$required = @('Environment', 'Bootstrap', 'Gateway', 'Governance', 'Completion', 'Delivery', 'Oci', 'Compatibility', 'Workflows')
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $tests "$name.Tests.ps1"))) { throw "Required local test suite is missing: $name" }
}
$files = @(Get-ChildItem -LiteralPath $tests -Filter '*.Tests.ps1' -File | Sort-Object Name)
foreach ($file in $files) {
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $file.FullName)
    if ($file.Name -ceq 'Compatibility.Tests.ps1' -and $TemplatePath) { $arguments += @('-TemplatePath', [IO.Path]::GetFullPath($TemplatePath)) }
    if ($file.Name -ceq 'Oci.Tests.ps1' -and $RequireOras) { $arguments += '-RequireOras' }
    & pwsh @arguments
    if ($LASTEXITCODE -ne 0) { throw "Required suite $($file.Name) failed with exit code $LASTEXITCODE." }
}
Write-Host "GitHub development environment: $($files.Count) required suites passed. No live Azure, GitHub mutation, or model gates were executed."
