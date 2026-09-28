#Requires -Version 7.0
<#
.SYNOPSIS
Plan or explicitly execute private completion from actual deployment outputs.
.DESCRIPTION
The default makes no credential, DNS or API calls. Execute reconciles only owned
App Configuration settings using Entra and ETags, and verifies the already
deployed image/configuration. It never deploys or updates a Container App.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$DeploymentOutputsPath,
    [string]$EvidencePath,
    [switch]$Execute
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Completion.psm1') -ErrorAction Stop
$profile = Read-EnvironmentProfile -Path $ProfilePath -AllowSynthetic:(-not $Execute)
$resolution = Resolve-EnvironmentProfile -Profile $profile -AllowSynthetic:(-not $Execute)
$outputs = Read-DeveloperCompletionOutput -Path $DeploymentOutputsPath
$run = $Execute -and $PSCmdlet.ShouldProcess('approved private environment', 'Reconcile owned App Configuration settings and verify infrastructure-owned application')
$result = Invoke-DeveloperCompletion -Resolution $resolution -DeploymentOutput $outputs -Execute:$run
if ($EvidencePath) { Write-JsonFile -Path $EvidencePath -Value $result }
$result | ConvertTo-Json -Depth 50
