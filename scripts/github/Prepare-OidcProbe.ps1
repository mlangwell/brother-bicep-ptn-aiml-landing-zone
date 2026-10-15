#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$Environment,
    [Parameter(Mandatory)][ValidateSet('preview', 'deploy')][string]$Purpose,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ConfigurationSha,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Delivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1')
if ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_SERVER_URL -cne 'https://github.com' -or $env:GITHUB_REPOSITORY -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'OIDC preparation requires a trusted github.com manual workflow.'
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OIDC preparation requires a new output directory.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$repoName = $env:GITHUB_REPOSITORY
foreach ($suffix in @('', '.platform')) {
    $file = Invoke-GitHubJson "repos/$repoName/contents/environments/$Environment$suffix.json?ref=$ConfigurationSha"
    if ($file.type -cne 'file' -or $file.encoding -cne 'base64' -or $file.size -gt 1MB) { throw 'OIDC profile input is unavailable or invalid.' }
    $name = if ($suffix) { 'platform.json' } else { 'profile.json' }
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory $name), [Convert]::FromBase64String($file.content))
}
$profile = Read-EnvironmentProfile -Path (Join-Path $OutputDirectory 'profile.json')
$platform = Read-PlatformInputs -Path (Join-Path $OutputDirectory 'platform.json')
if ($profile.environment -cne $Environment -or $profile.github.repository -cne $repoName -or
    [string]$profile.github.repositoryId -cne $env:GITHUB_REPOSITORY_ID -or
    [string]$profile.github.ownerId -cne $env:GITHUB_REPOSITORY_OWNER_ID -or $profile.github.protectedRef -cne $env:GITHUB_REF) {
    throw 'OIDC preparation repository, ref or environment mismatch.'
}
$branch = [Uri]::EscapeDataString($profile.github.protectedRef.Substring('refs/heads/'.Length))
$comparison = Invoke-GitHubJson "repos/$repoName/compare/$ConfigurationSha...$branch"
if ($comparison.merge_base_commit.sha -cne $ConfigurationSha -or $comparison.status -cnotin @('ahead', 'identical')) { throw 'OIDC profile is not on the approved protected history.' }
$null = Assert-GitHubBootstrapReadiness -Profile $profile -PlatformInputs $platform
$jobEnvironment = if ($Purpose -ceq 'preview') { "$Environment-preview" } else { $Environment }
$profileHash = Get-CanonicalHash -Value $profile
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "job_environment=$jobEnvironment" -Encoding utf8
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "profile_hash=$profileHash" -Encoding utf8
Write-Output 'Existing protections and immutable profile checked. The next job captures claims only; no Azure authority is exercised.'
