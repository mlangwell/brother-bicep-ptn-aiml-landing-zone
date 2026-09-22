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
        'tests\scripts\Validate-CopilotAssets.Tests.ps1'
        'scripts\Measure-MainJsonSize.ps1'
        'tests\scripts\Measure-MainJsonSize.Tests.ps1'
        'tests\scripts\Invoke-PreflightChecks.Tests.ps1'
        'tests\contracts\Test-HostedAgentContract.ps1'
        'tests\contracts\Test-AcrTaskAgentPoolFirewallContract.ps1'
        'tests\contracts\Test-FirewallAgent365ObservabilityContract.ps1'
        'tests\contracts\Test-FoundrySharedPrivateLinkNameContract.ps1'
        'tests\contracts\Test-MaintenanceConfigurationWrapperContract.ps1'
        'tests\contracts\Test-ComponentDeploymentFlagsContract.ps1'
        'tests\contracts\Test-CosmosDeploymentNameContract.ps1'
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
