#Requires -Version 7.4
[CmdletBinding()]
param([string]$PythonExecutable = $env:AILZ_TEST_PYTHON)
$ErrorActionPreference = 'Stop'
if (-not $PythonExecutable) { $PythonExecutable = 'python' }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Push-Location $root
try {
    $suites = @(
        '.github\scripts\Validate-CopilotAssets.ps1'
        'scripts\Measure-MainJsonSize.ps1'
        'tests\contracts\Test-ApiManagementWorkloadIsolationContract.ps1'
        'tests\contracts\Test-ApiManagementClassicInjectionContract.ps1'
        'tests\contracts\Test-AzdOperationsContract.ps1'
    )
    foreach ($suite in $suites) {
        & pwsh -NoProfile -NonInteractive -File (Join-Path $root $suite)
        if ($LASTEXITCODE -ne 0) { throw "Local gate failed: $suite (exit $LASTEXITCODE)." }
    }
    & az bicep lint --file (Join-Path $root 'main.bicep')
    if ($LASTEXITCODE -ne 0) { throw 'Bicep lint failed.' }
    & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-GitHubEnvironment.ps1') -TemplatePath (Join-Path $root 'main.json') -RequireOras
    if ($LASTEXITCODE -ne 0) { throw 'GitHub environment validation failed.' }
    & pwsh -NoProfile -NonInteractive -File (Join-Path $root 'samples\developer-smoke\Test-Smoke.ps1') -PythonExecutable $PythonExecutable
    if ($LASTEXITCODE -ne 0) { throw 'Starter validation failed.' }
}
finally { Pop-Location }
