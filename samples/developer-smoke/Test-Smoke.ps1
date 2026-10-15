#Requires -Version 7.0
<#
.SYNOPSIS
Run the sample's real local HTTP pytest suite and reject zero-execution runs.
.DESCRIPTION
Installs nothing and makes no Azure or inference calls. Supply the Python
executable from a venv populated using requirements-test.lock. CPython 3.13
is required; .python-version contains the verified setup-python CI patch pin.
Pytest failures propagate unchanged. A successful process must also produce a
valid JUnit report with at least one executed, non-skipped test and no failures.
#>
[CmdletBinding()]
param([string]$PythonExecutable = 'python')

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest
$python = (Get-Command -Name $PythonExecutable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$versionJson = & $python -c 'import json,sys; print(json.dumps({"implementation":sys.implementation.name,"version":list(sys.version_info[:3])}))'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$runtime = $versionJson | ConvertFrom-Json -AsHashtable
if ($runtime.implementation -cne 'cpython' -or $runtime.version[0] -ne 3 -or $runtime.version[1] -ne 13) {
    throw 'The developer-smoke suite requires CPython 3.13; use the CI pin in .python-version.'
}
$tests = Join-Path $PSScriptRoot 'tests'
$configuration = Join-Path $PSScriptRoot 'pyproject.toml'
$reportPath = Join-Path ([IO.Path]::GetTempPath()) ('developer-smoke-tests-' + [guid]::NewGuid().ToString('N') + '.xml')
try {
    & $python -m pytest -c $configuration --strict-config --strict-markers --junitxml $reportPath $tests -q
    $pytestExit = $LASTEXITCODE
    if ($pytestExit -ne 0) { exit $pytestExit }
    if (-not [IO.File]::Exists($reportPath)) { throw 'Pytest returned success without a test report; no successful test execution is established.' }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($reportPath, $settings)
    try {
        $report = [Xml.XmlDocument]::new()
        $report.XmlResolver = $null
        $report.Load($reader)
    }
    finally { $reader.Dispose() }
    $total = 0L
    $skipped = 0L
    $failed = 0L
    foreach ($suite in $report.SelectNodes('/testsuites/testsuite')) {
        $total += [long]::Parse($suite.GetAttribute('tests'), [Globalization.CultureInfo]::InvariantCulture)
        $skipped += [long]::Parse($suite.GetAttribute('skipped'), [Globalization.CultureInfo]::InvariantCulture)
        $failed += [long]::Parse($suite.GetAttribute('failures'), [Globalization.CultureInfo]::InvariantCulture)
        $failed += [long]::Parse($suite.GetAttribute('errors'), [Globalization.CultureInfo]::InvariantCulture)
    }
    $executed = $total - $skipped
    if ($total -le 0 -or $skipped -lt 0 -or $executed -le 0 -or $failed -ne 0) {
        throw 'No executed passing tests were established by the report; collection-only, all-skipped and zero-test runs are not success.'
    }
    Write-Output "SMOKE TESTS PASSED: $executed executed; $skipped skipped; CPython $($runtime.version -join '.')."
}
finally {
    if ([IO.File]::Exists($reportPath)) { [IO.File]::Delete($reportPath) }
}
