#Requires -Version 7.0
<#
.SYNOPSIS
Plan a live gate, or perform explicitly approved bounded paid inference probes.
.DESCRIPTION
No calls occur by default. Execution requires real approved inputs, positive
request/token ceilings and explicit environment/source-SHA approval. Partial
observations never establish promotion eligibility. This entry point cannot
mutate gateway controls, consume unsigned boolean evidence, or stand in for
separately approved human/workload/runner, quota, notification and recovery gates.
Plan output goes to stdout. EvidencePath is reserved for actually observed live
probes; plans cannot create or replace an observed-evidence artifact.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$DeploymentOutputsPath,
    [string]$EvidencePath,
    [switch]$ExecutePaidProbes,
    [string]$ApprovedEnvironment,
    [string]$ApprovedSourceSha,
    [int]$MaxRequests,
    [long]$MaxTotalTokens,
    [ValidateSet('human', 'runner')][string]$IdentityContext = 'human',
    [string]$ReleaseFingerprint,
    [long]$WorkflowRunId
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Completion.psm1') -ErrorAction Stop
$profile = Read-EnvironmentProfile -Path $ProfilePath -AllowSynthetic:(-not $ExecutePaidProbes)
$resolution = Resolve-EnvironmentProfile -Profile $profile -AllowSynthetic:(-not $ExecutePaidProbes)
$outputs = Read-DeveloperCompletionOutput -Path $DeploymentOutputsPath
$run = $ExecutePaidProbes -and $PSCmdlet.ShouldProcess('explicitly approved environment/release and identity context', 'Issue bounded potentially billable inference and negative bypass probes')
$result = Invoke-LiveDeveloperGate -Resolution $resolution -DeploymentOutput $outputs -ExecutePaidProbes:$run `
    -ApprovedEnvironment $ApprovedEnvironment -ApprovedSourceSha $ApprovedSourceSha -MaxRequests $MaxRequests `
    -MaxTotalTokens $MaxTotalTokens -IdentityContext $IdentityContext -ReleaseFingerprint $ReleaseFingerprint -WorkflowRunId $WorkflowRunId
if ($EvidencePath) {
    if (-not $run -or $result.mode -cne 'observed-live-partial' -or $null -eq $result.observedAt -or $result.probes.Count -eq 0) {
        throw 'EvidencePath requires actually observed live probes. Omit it for a stdout-only plan; existing evidence is preserved.'
    }
    Write-JsonFile -Path $EvidencePath -Value $result
}
$result | ConvertTo-Json -Depth 50
