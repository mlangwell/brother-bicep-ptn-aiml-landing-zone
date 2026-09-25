#Requires -Version 7.4
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$pins = Get-Content (Join-Path $PSScriptRoot 'release-tools.json') -Raw | ConvertFrom-Json -AsHashtable
Import-Module PSScriptAnalyzer -RequiredVersion $pins.psScriptAnalyzer -ErrorAction Stop
# Initialize parameter metadata before PSScriptAnalyzer's parallel module rules.
$null = (Get-Command Export-ModuleMember -CommandType Cmdlet -ErrorAction Stop).Parameters.Keys
$files = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -in @('.ps1', '.psm1')
    Get-ChildItem -LiteralPath (Join-Path $root 'tests\github') -File | Where-Object Extension -in @('.ps1', '.psm1')
    Get-ChildItem -LiteralPath (Join-Path $root 'samples\developer-smoke') -File -Recurse | Where-Object Extension -in @('.ps1', '.psm1')
    Get-ChildItem -LiteralPath (Join-Path $root 'platform') -File -Recurse | Where-Object Extension -in @('.ps1', '.psm1')
    Get-Item -LiteralPath (Join-Path $root 'scripts\Measure-MainJsonSize.ps1')
)
if ($files.Count -eq 0) { throw 'No PowerShell surfaces were found to lint.' }
$diagnostics = @(
    foreach ($file in $files) {
        Write-Host "Analyzing $([IO.Path]::GetRelativePath($root, $file.FullName))"
        try {
            Invoke-ScriptAnalyzer -Path $file.FullName -Severity Error, Warning, Information -ErrorAction Stop |
                Select-Object ScriptPath, Line, RuleName, @{Name='Severity';Expression={$_.Severity.ToString()}}, Message
        }
        catch {
            throw "PSScriptAnalyzer failed on $($file.Name): $($_.Exception.ToString())"
        }
    }
)
$errors = @($diagnostics | Where-Object Severity -eq 'Error')
$warnings = @($diagnostics | Where-Object Severity -eq 'Warning')
if (-not $ReportPath) { $ReportPath = Join-Path $root 'artifacts\validation\powershell-lint.json' }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath))) | Out-Null
ConvertTo-Json -InputObject @{ analyzer=$pins.psScriptAnalyzer; files=$files.Count; errors=$errors.Count; warnings=$warnings.Count; diagnostics=$diagnostics } -Depth 10 |
    Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
Write-Host "PSScriptAnalyzer: $($files.Count) files, $($errors.Count) errors, $($warnings.Count) warnings (full report in artifacts/validation/powershell-lint.json)."
if ($errors.Count) {
    $errors | Format-Table ScriptPath, Line, RuleName, Message -Wrap | Out-Host
    throw 'PowerShell analysis found blocking errors.'
}
$actionlint = Get-Command actionlint -ErrorAction Stop
$workflows = @('bicep-validate.yml', 'deploy-environment.yml', 'deploy-environment-reusable.yml', 'oidc-probe.yml')
if (Test-Path (Join-Path $root '.github\workflows\record-live-gates.yml')) { $workflows += 'record-live-gates.yml' }
$workflowPaths = @($workflows | ForEach-Object { Join-Path $root ".github\workflows\$_" })
& $actionlint.Source -shellcheck= -pyflakes= @workflowPaths
if ($LASTEXITCODE -ne 0) { throw 'GitHub Actions workflow semantic validation failed.' }
Write-Host "actionlint: $($workflowPaths.Count) workflow definitions passed."
