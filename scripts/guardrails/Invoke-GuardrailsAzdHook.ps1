#Requires -Version 7.0
<#
.SYNOPSIS
    azd postprovision hook: run the AI guardrails playbook against the landing
    zone that was just provisioned.

.DESCRIPTION
    Wired into azure.yaml so `azd provision` and `azd up` finish by reporting the
    post-deployment governance position rather than leaving it to be remembered.

    IT IS SAFE TO DO NOTHING, AND THAT IS THE DEFAULT SHAPE. The playbook needs
    three decisions nobody can discover - who hears about spend, what "too much"
    means, and who gets the cost-bounded role. Without them this hook skips with
    instructions instead of guessing, and a skip never fails the deployment.

    IT DOES NOT WRITE TO AZURE UNLESS ASKED. A dry run is the default, because
    applying subscription-scope governance as a side effect of a provision -
    before anyone has read what it would do - is exactly the surprise the rest of
    this playbook refuses to create. Set GUARDRAILS_AUTO_APPLY=true to opt in.

    Environment variables, all read from the azd environment:

      GUARDRAILS_ENABLED           false to skip entirely
      GUARDRAILS_AUTO_APPLY        true to run with -Apply instead of a dry run
      COST_ALERT_EMAILS            required to bootstrap a missing .env
      SUBSCRIPTION_BUDGET_AMOUNT   required to bootstrap a missing .env
      ROLE_ASSIGN_PRINCIPAL_IDS    optional; blank creates the role unassigned

    azd already exports AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
    AZURE_RESOURCE_GROUP, AZURE_LOCATION and AZURE_ENV_NAME, which the bootstrap
    reads directly, so the estate itself never has to be restated here.

.NOTES
    Exit code policy, because a hook that cries wolf gets ignored:

      skip              0   nothing was attempted
      dry run           0   advisory only; the deployment itself is fine
      apply             the playbook's own exit code, because a failure there
                            means governance was NOT applied, and that matters

    azure.yaml also sets continueOnError so that a governance finding never
    rolls back or fails a provision that genuinely succeeded.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guardrailsRoot = $PSScriptRoot
$playbook = Join-Path $guardrailsRoot 'Invoke-AiGuardrails.ps1'
$envFile = Join-Path $guardrailsRoot '.env'

function Write-HookLine {
    param([string]$Message, [string]$Colour = 'Gray')
    Write-Host "  [guardrails] $Message" -ForegroundColor $Colour
}

function Test-HookFlag {
    param([string]$Name, [bool]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw.Trim().ToLowerInvariant() -in @('true', '1', 'yes')
}

Write-Host ''
Write-Host ' AI guardrails (post-provision)' -ForegroundColor Cyan

if (-not (Test-HookFlag -Name 'GUARDRAILS_ENABLED' -Default $true)) {
    Write-HookLine 'GUARDRAILS_ENABLED is false - skipping.' 'DarkGray'
    exit 0
}

if (-not (Test-Path -LiteralPath $playbook)) {
    Write-HookLine "Playbook not found at '$playbook' - skipping." 'Yellow'
    exit 0
}

$apply = Test-HookFlag -Name 'GUARDRAILS_AUTO_APPLY' -Default $false
$arguments = @{ EnvFile = $envFile; NonInteractive = $true }
if ($apply) { $arguments['Apply'] = $true }

if (-not (Test-Path -LiteralPath $envFile)) {
    # Bootstrap only when the decisions this playbook cannot discover are
    # already in the environment. Anything else would be a guess about who gets
    # alerted and what the budget is, which is worse than doing nothing.
    $emails = [Environment]::GetEnvironmentVariable('COST_ALERT_EMAILS')
    $budget = [Environment]::GetEnvironmentVariable('SUBSCRIPTION_BUDGET_AMOUNT')

    if ([string]::IsNullOrWhiteSpace($emails) -or [string]::IsNullOrWhiteSpace($budget)) {
        Write-HookLine 'No scripts/guardrails/.env, and the values it cannot discover are not set - skipping.' 'Yellow'
        Write-HookLine 'The landing zone is deployed; the post-deployment governance playbook has not run.' 'DarkGray'
        Write-HookLine 'To run it now:' 'DarkGray'
        Write-HookLine '  pwsh ./scripts/guardrails/Invoke-AiGuardrails.ps1 -Bootstrap -CostAlertEmails <distribution-list> -SubscriptionBudgetAmount <monthly-amount>' 'DarkGray'
        Write-HookLine 'To have every future provision run it, set these in the azd environment:' 'DarkGray'
        Write-HookLine '  azd env set COST_ALERT_EMAILS <distribution-list>' 'DarkGray'
        Write-HookLine '  azd env set SUBSCRIPTION_BUDGET_AMOUNT <monthly-amount>' 'DarkGray'
        exit 0
    }

    Write-HookLine 'No scripts/guardrails/.env - generating one from the azd environment.'
    $arguments['Bootstrap'] = $true
}

Write-HookLine $(if ($apply) {
        'GUARDRAILS_AUTO_APPLY=true - this run WILL write governance to Azure.'
    }
    else {
        'Dry run: reporting what the playbook would do. Set GUARDRAILS_AUTO_APPLY=true to apply it.'
    }) $(if ($apply) { 'Yellow' } else { 'DarkGray' })

try {
    & $playbook @arguments
    $playbookExit = $LASTEXITCODE
}
catch {
    # A configuration refusal is a real answer, not a crash. It is also not a
    # reason to mark a provision that genuinely succeeded as failed.
    Write-HookLine "The playbook stopped: $($_.Exception.Message)" 'Yellow'
    if ($apply) { exit 1 }
    exit 0
}

if ($apply) {
    if ($playbookExit -ne 0) {
        Write-HookLine "The playbook exited $playbookExit - governance was NOT fully applied. Read the findings above." 'Red'
    }
    exit $playbookExit
}

Write-HookLine 'Dry run complete - nothing was written to Azure.' 'DarkGray'
exit 0
