#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) "ailz-compact-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $temporary 'scripts') -Force | Out-Null
$count = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
try {
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Measure-MainJsonSize.ps1') -Destination (Join-Path $temporary 'scripts\Measure-MainJsonSize.ps1')
    [IO.File]::WriteAllText((Join-Path $temporary 'main.bicep'), "targetScope = 'resourceGroup'")
    $inputPath = Join-Path $temporary 'compiler-output.json'
    $mainPath = Join-Path $temporary 'main.json'
    $inputJson = @'
{
  "resources": [],
  "integer": 18446744073709551615,
  "text": "<policy attr='value'>\\escaped\n\u00e9</policy>",
  "date": "2026-09-16T00:00:00.0000000Z"
}
'@
    [IO.File]::WriteAllText($inputPath, $inputJson)
    $wrapper = Join-Path $temporary 'run.ps1'
    [IO.File]::WriteAllText($wrapper, @'
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
function bicep {
    param($Verb, $File)
    if ($Verb -cne 'build') { throw 'Unexpected compiler operation.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compiler-output.json') -Destination (Join-Path $PSScriptRoot 'main.json')
    $global:LASTEXITCODE = 0
}
& (Join-Path $PSScriptRoot 'scripts\Measure-MainJsonSize.ps1') -SkipBuild:$SkipBuild
'@)
    & pwsh -NoProfile -NonInteractive -File $wrapper | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Compact template build failed.'
    $compact = [IO.File]::ReadAllText($mainPath)
    Assert-True (-not $compact.Contains("`n")) 'Fresh build was not compacted before the unchanged size gate.'
    $before = [Text.Json.JsonDocument]::Parse($inputJson)
    $after = [Text.Json.JsonDocument]::Parse($compact)
    try {
        Assert-True ($before.RootElement.GetProperty('integer').GetRawText() -ceq $after.RootElement.GetProperty('integer').GetRawText()) 'Compaction changed numeric precision.'
        foreach ($property in @('text', 'date')) {
            Assert-True ($before.RootElement.GetProperty($property).GetString() -ceq $after.RootElement.GetProperty($property).GetString()) "Compaction changed $property."
        }
    } finally { $before.Dispose(); $after.Dispose() }
    [IO.File]::WriteAllText($mainPath, $inputJson)
    $hash = (Get-FileHash -LiteralPath $mainPath).Hash
    & pwsh -NoProfile -NonInteractive -File $wrapper -SkipBuild | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $mainPath).Hash -ceq $hash) 'SkipBuild must measure the supplied artifact without modifying it.'
    [IO.File]::WriteAllText($inputPath, ('{"resources":[],"large":"' + ('x' * [int](5.1MB)) + '"}'))
    & pwsh -NoProfile -NonInteractive -File $wrapper *> (Join-Path $temporary 'expected-failure.txt')
    Assert-True ($LASTEXITCODE -ne 0) 'Compaction bypassed the existing hard size failure.'
    Write-Host "Compact template: $count assertions passed."
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
