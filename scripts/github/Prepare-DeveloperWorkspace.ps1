#Requires -Version 7.0
<#
.SYNOPSIS
Prepare a developer-owned workspace outside the disposable CSE checkout.
.DESCRIPTION
Default is a local plan. Execute requires the developer own interactive SSO,
checks all required tools, preserves existing origin/HEAD/dirty files, and
installs hashed dependencies only into the workspace virtual environment.
It never calls az login or claims that a runner login proves human readiness.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$WorkspacePath,
    [Parameter(Mandatory)][string]$BootstrapCheckoutPath,
    [string]$EvidencePath,
    [switch]$Execute
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Completion.psm1') -ErrorAction Stop
$profile = Read-EnvironmentProfile -Path $ProfilePath -AllowSynthetic:(-not $Execute)
$resolution = Resolve-EnvironmentProfile -Profile $profile -AllowSynthetic:(-not $Execute)
$run = $Execute -and $PSCmdlet.ShouldProcess('separate developer-owned workspace', 'Clone only when absent and install hash-locked dependencies into its local venv')
$result = Invoke-DeveloperWorkspace -Resolution $resolution -WorkspacePath $WorkspacePath -BootstrapCheckoutPath $BootstrapCheckoutPath -Execute:$run
if ($EvidencePath) { Write-JsonFile -Path $EvidencePath -Value $result }
$result | ConvertTo-Json -Depth 50
