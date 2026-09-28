#Requires -Version 7.0
<#
.SYNOPSIS
Capture verified, nonsecret OIDC claims in a separately authorized Actions probe.
.DESCRIPTION
This script has no Azure access or login path. It requests only a GitHub OIDC
token, verifies its RS256 signature using the trusted issuer's JWKS, and checks
the exact repository IDs, environment, protected ref and workflow/run context.
The JWT and bearer request credential remain in memory and are never emitted.

Use a dedicated workflow_dispatch job with id-token: write and the exact
preview/deployment environment. This file creates or dispatches no workflow.
Publish the resulting claims artifact only from that trusted probe run.
.EXAMPLE
.\Export-OidcClaims.ps1 -ProfilePath .\dev.json -Purpose preview -ExpectedWorkflowRef 'owner/repo/.github/workflows/oidc-probe.yml@refs/heads/main' -ExpectedWorkflowSha <workflow-sha> -OutputPath .\claims.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][ValidateSet('preview', 'deploy')][string]$Purpose,
    [Parameter(Mandatory)][string]$ExpectedWorkflowRef,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ExpectedWorkflowSha,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -ErrorAction Stop
$token = $null
$requestCredential = $null
$headers = $null
try {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_SERVER_URL -cne 'https://github.com' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch') {
        throw 'OIDC evidence requires a github.com workflow_dispatch probe; no Azure access is used.'
    }
    $profile = Read-EnvironmentProfile -Path $ProfilePath
    $g = $profile.github
    $environmentName = if ($Purpose -ceq 'preview') { "$($profile.environment)-preview" } else { $profile.environment }
    if ($env:GITHUB_REPOSITORY -cne $g.repository -or [string]$env:GITHUB_REPOSITORY_ID -cne [string]$g.repositoryId -or
        [string]$env:GITHUB_REPOSITORY_OWNER_ID -cne [string]$g.ownerId -or $env:GITHUB_REF -cne $g.protectedRef -or
        $env:GITHUB_WORKFLOW_REF -cne $ExpectedWorkflowRef -or $env:GITHUB_WORKFLOW_SHA -cne $ExpectedWorkflowSha -or
        $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$' -or
        -not $ExpectedWorkflowRef.StartsWith("$($g.repository)/.github/workflows/", [StringComparison]::Ordinal) -or
        -not $ExpectedWorkflowRef.EndsWith("@$($g.protectedRef)", [StringComparison]::Ordinal)) {
        throw 'Actions server/repository/ref/workflow/run context does not match the inspected probe inputs.'
    }
    $requestUri = [uri]$env:ACTIONS_ID_TOKEN_REQUEST_URL
    if (-not $requestUri.IsAbsoluteUri -or $requestUri.Scheme -cne 'https' -or $requestUri.Port -ne 443 -or
        -not $requestUri.Host.EndsWith('.actions.githubusercontent.com', [StringComparison]::OrdinalIgnoreCase) -or
        $requestUri.UserInfo -or $requestUri.Fragment -or $requestUri.AbsolutePath -notmatch '/oidctoken$') {
        throw 'Rejected OIDC request URL; credentials are never sent to another host.'
    }
    $requestCredential = $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN
    if ([string]::IsNullOrWhiteSpace($requestCredential)) { throw 'Actions OIDC request authorization is missing.' }
    $expected = @{
        iss = $g.oidc.issuer; aud = $g.oidc.audience; sub = $g.oidc["${Purpose}Subject"]
        repository = $g.repository; repository_id = [string]$g.repositoryId; repository_owner_id = [string]$g.ownerId
        environment = $environmentName; ref = $g.protectedRef; run_id = $env:GITHUB_RUN_ID; run_attempt = $env:GITHUB_RUN_ATTEMPT
        workflow_ref = $ExpectedWorkflowRef; workflow_sha = $ExpectedWorkflowSha; event_name = 'workflow_dispatch'
    }
    $discovery = Invoke-RestMethod -Uri 'https://token.actions.githubusercontent.com/.well-known/openid-configuration' -Method Get -MaximumRedirection 0 -TimeoutSec 30 -Verbose:$false -Debug:$false
    $jwksUri = [uri]$discovery.jwks_uri
    if ($discovery.issuer -cne $expected.iss -or $jwksUri.Scheme -cne 'https' -or $jwksUri.Host -cne 'token.actions.githubusercontent.com' -or
        $jwksUri.Port -ne 443 -or $jwksUri.UserInfo -or $jwksUri.Fragment) { throw 'Untrusted OIDC discovery/JWKS endpoint.' }
    $jwks = Invoke-RestMethod -Uri $jwksUri -Method Get -MaximumRedirection 0 -TimeoutSec 30 -Verbose:$false -Debug:$false
    $jwks = ConvertTo-Json -InputObject $jwks -Depth 20 -Compress | ConvertFrom-Json -AsHashtable
    $builder = [UriBuilder]::new($requestUri)
    $query = $builder.Query.TrimStart('?')
    if ($query -match '(?i)(^|&)audience=') { throw 'OIDC request URL already contains an audience; do not accept ambiguous token requests.' }
    $builder.Query = "$query&audience=$([uri]::EscapeDataString($expected.aud))".TrimStart('&')
    $headers = @{ Authorization = "Bearer $requestCredential" }
    try {
        $reply = Invoke-RestMethod -Uri $builder.Uri -Method Get -Headers $headers -MaximumRedirection 0 -TimeoutSec 30 -Verbose:$false -Debug:$false
        $token = [string]$reply.value
    }
    catch { throw 'GitHub OIDC token request failed. Response and request credentials are suppressed.' }
    $claims = ConvertFrom-VerifiedGitHubOidcToken -Token $token -Jwks $jwks -ExpectedClaims $expected
    Write-JsonFile -Path $OutputPath -Value @{ schemaVersion = 1; serverUrl = 'https://github.com'; claims = $claims }
    Write-Host 'Verified nonsecret OIDC claim evidence written. No Azure access was performed.'
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    $token = $null
    $reply = $null
    $requestCredential = $null
    if ($null -ne $headers) { $headers.Clear() }
}
