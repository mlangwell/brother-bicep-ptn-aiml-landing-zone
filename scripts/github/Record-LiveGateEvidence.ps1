#Requires -Version 7.4
<#
.SYNOPSIS
Preflights or records protected, reviewed live gate observations.
.DESCRIPTION
Default Preflight mode cannot write promotion.json. Record mode requires the
trusted workflow's running protected record job and the preflight hash.
Evidence is read from its exact approved commit, never executed. No Azure
identity, live probe, model request or GitHub settings write is performed.

The environment profile and <environment>.platform.json are read from the same
configuration commit. P2's GitHub-only Assert-GitHubBootstrapReadiness receives
both Profile and validated PlatformInputs before and after the protected gate.
Independent test/prod environment review and sanitized human observations are
the trust boundary; a checksum is not proof of an operator's truthfulness.
#>
[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Record')][string]$Phase = 'Preflight',
    [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$Environment,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$ConfigurationSha,
    [Parameter(Mandatory)][string]$EvidenceCommitSha,
    [Parameter(Mandatory)][long]$ReleaseRunId,
    [Parameter(Mandatory)][long]$DeploymentRunId,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$OutputDirectory,
    [string]$ExpectedPreflightHash
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'LiveEvidence.psm1') -ErrorAction Stop
if ($Phase -ceq 'Preflight' -and [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'Preflight requires the workflow output channel; no protected job may proceed without its binding.'
}
$summary = Invoke-LiveGateEvidenceRecording @PSBoundParameters
if ($Phase -ceq 'Preflight') {
    if ($summary.preflightHash -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Invalid preflight binding.' }
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "preflight_hash=$($summary.preflightHash)" -Encoding utf8
}
