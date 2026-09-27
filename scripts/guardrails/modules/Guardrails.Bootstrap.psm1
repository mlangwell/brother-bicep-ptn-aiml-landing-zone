#Requires -Version 7.0
Set-StrictMode -Version Latest

# The .env parser lives in Guardrails.Common and there must only ever be one of
# it - two parsers drift. Import without -Force so the orchestrator's already
# loaded instance (and its accumulated results) is reused rather than reset.
if (-not (Get-Module -Name 'Guardrails.Common')) {
    Import-Module (Join-Path $PSScriptRoot 'Guardrails.Common.psm1') -DisableNameChecking
}

<#
.SYNOPSIS
    One-command adoption for the guardrails playbook: generates `.env` from
    `.env.example` so a clean checkout needs no hand-editing.

.DESCRIPTION
    Every setting resolves through one ladder. The first rung that supplies a
    non-empty value wins:

      1. an explicit script parameter
      2. an environment variable
      3. the value already in .env
      4. discovery from the signed-in `az` context
      5. a prompt

    Rung 5 exists for a human at a terminal. CI has no human, so a value that
    reaches rung 5 with nothing to answer it is a NAMED failure rather than a
    hang: the message says which setting it was, which parameter would have
    supplied it, and which environment variable would have supplied it.

    Discovery is best-effort and is never fatal by itself. `az` being absent or
    signed out is recorded as a note and the ladder falls through. A caller that
    supplies everything by parameter never invokes discovery at all, which is
    how both the CI path and the offline tests work.

    THREE VALUES CANNOT BE DISCOVERED, because they are decisions rather than
    facts about the estate:

      COST_ALERT_EMAILS           who hears about spend
      SUBSCRIPTION_BUDGET_AMOUNT  what "too much" means here
      ROLE_ASSIGN_PRINCIPAL_IDS   who gets the cost-bounded role

    The first two are required. The third is deliberately allowed to be blank,
    because `.env.example` documents blank as the recommended first run: create
    the role definition, read it, and hand it out as a separate decision.

.NOTES
    Writing is merge-not-replace. Regenerating over an existing .env carries
    every key that file already had, including ones this module does not manage,
    so an operator's hand-tuned ceiling is never silently reset to the template
    default. Without -Force an existing .env is left completely alone.
#>

# Settings this module can fill in. Everything else in .env.example keeps the
# template's own documented default.
#
#   Parameter  - the -Bootstrap parameter that supplies it (rung 1)
#   EnvNames   - environment variables consulted in order (rung 2)
#   Discover   - key in the discovery map; $null means it is not discoverable
#   Prompt     - the question asked at rung 5; $null means never prompt
#   Required   - the playbook cannot run without it
#   AllowEmpty - blank is a legitimate, documented answer
function Get-GuardrailSettingCatalog {
    [CmdletBinding()]
    param()

    return @(
        @{
            Key = 'AZ_TENANT_ID'; Parameter = 'TenantId'
            EnvNames = @('AZ_TENANT_ID', 'AZURE_TENANT_ID')
            Discover = 'AZ_TENANT_ID'; Required = $true; AllowEmpty = $false
            Prompt = 'Azure tenant ID'
        }
        @{
            Key = 'AZ_SUBSCRIPTION_ID'; Parameter = 'SubscriptionId'
            EnvNames = @('AZ_SUBSCRIPTION_ID', 'AZURE_SUBSCRIPTION_ID')
            Discover = 'AZ_SUBSCRIPTION_ID'; Required = $true; AllowEmpty = $false
            Prompt = 'Azure subscription ID'
        }
        @{
            Key = 'AZ_RESOURCE_GROUP'; Parameter = 'ResourceGroup'
            EnvNames = @('AZ_RESOURCE_GROUP', 'AZURE_RESOURCE_GROUP')
            Discover = 'AZ_RESOURCE_GROUP'; Required = $true; AllowEmpty = $false
            Prompt = 'Workload resource group'
        }
        @{
            Key = 'AZ_LOCATION'; Parameter = 'Location'
            EnvNames = @('AZ_LOCATION', 'AZURE_LOCATION')
            Discover = 'AZ_LOCATION'; Required = $true; AllowEmpty = $false
            Prompt = 'Azure region of the workload resource group'
        }
        @{
            Key = 'ASSIGNMENT_PREFIX'; Parameter = 'AssignmentPrefix'
            EnvNames = @('ASSIGNMENT_PREFIX')
            Discover = 'ASSIGNMENT_PREFIX'; Required = $true; AllowEmpty = $false
            Prompt = 'Governance assignment prefix (must match governance.assignmentPrefix in the environment JSON)'
        }
        @{
            Key = 'PROJECT_NAME'; Parameter = 'ProjectName'
            EnvNames = @('PROJECT_NAME'); Discover = $null
            Required = $false; AllowEmpty = $true; Prompt = $null
        }
        @{
            Key = 'ENVIRONMENT'; Parameter = 'EnvironmentName'
            EnvNames = @('ENVIRONMENT', 'AZURE_ENV_NAME'); Discover = $null
            Required = $false; AllowEmpty = $true; Prompt = $null
        }
        @{
            Key = 'GATEWAY_OWNER'; Parameter = 'GatewayOwner'
            EnvNames = @('GATEWAY_OWNER'); Discover = $null
            Required = $false; AllowEmpty = $true; Prompt = $null
        }
        # Plane-specific. Blank is safe: each plane reports its own missing
        # prerequisite as a Skipped result rather than guessing a name.
        @{
            Key = 'APIM_NAME'; Parameter = 'ApimName'
            EnvNames = @('APIM_NAME'); Discover = 'APIM_NAME'
            Required = $false; AllowEmpty = $true; Prompt = $null
        }
        @{
            Key = 'LOG_ANALYTICS_WORKSPACE'; Parameter = 'LogAnalyticsWorkspace'
            EnvNames = @('LOG_ANALYTICS_WORKSPACE'); Discover = 'LOG_ANALYTICS_WORKSPACE'
            Required = $false; AllowEmpty = $true; Prompt = $null
        }
        @{
            Key = 'FOUNDRY_ACCOUNT_NAME'; Parameter = 'FoundryAccountName'
            EnvNames = @('FOUNDRY_ACCOUNT_NAME'); Discover = 'FOUNDRY_ACCOUNT_NAME'
            Required = $false; AllowEmpty = $true; Prompt = $null
        }
        # The three decisions. Not facts about the estate, so not discoverable.
        @{
            Key = 'COST_ALERT_EMAILS'; Parameter = 'CostAlertEmails'
            EnvNames = @('COST_ALERT_EMAILS'); Discover = $null
            Required = $true; AllowEmpty = $false
            Prompt = 'Cost alert recipients, comma separated (use a distribution list, not a person)'
        }
        @{
            Key = 'SUBSCRIPTION_BUDGET_AMOUNT'; Parameter = 'SubscriptionBudgetAmount'
            EnvNames = @('SUBSCRIPTION_BUDGET_AMOUNT'); Discover = $null
            Required = $true; AllowEmpty = $false
            Prompt = 'Monthly subscription budget amount, in the subscription billing currency'
        }
        @{
            Key = 'ROLE_ASSIGN_PRINCIPAL_IDS'; Parameter = 'RoleAssignPrincipalIds'
            EnvNames = @('ROLE_ASSIGN_PRINCIPAL_IDS'); Discover = $null
            Required = $false; AllowEmpty = $true
            Prompt = 'Object IDs to receive the cost-bounded role, comma separated (blank creates the definition without assigning it, which is the recommended first run)'
        }
    )
}

function Test-GuardrailInteractive {
    <#
    .SYNOPSIS
        Is there a human who can answer a prompt?

    .DESCRIPTION
        Redirected stdin is the reliable cross-platform signal: azd hooks
        without `interactive: true`, pipelines and `pwsh -File script < file`
        all redirect it. The CI variables are belt and braces for agents that
        allocate a TTY anyway.
    #>
    [CmdletBinding()]
    param()

    foreach ($name in @('CI', 'TF_BUILD', 'GITHUB_ACTIONS', 'BUILD_BUILDID', 'SYSTEM_TEAMPROJECTID')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -ne 'false') { return $false }
    }

    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch {
        # No console at all is not a human either.
        return $false
    }

    return $true
}

function Get-GuardrailAzureDiscovery {
    <#
    .SYNOPSIS
        Best-effort discovery of the estate from the signed-in `az` context.

    .DESCRIPTION
        Never throws. Everything it cannot determine comes back absent with a
        note explaining why, so the caller's ladder can fall through to a prompt
        or to a named failure. A guessed value here would be far worse than an
        absent one: it would point a governance run at the wrong estate.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroup,
        [string]$EnvironmentName
    )

    $values = @{}
    $notes = [System.Collections.Generic.List[string]]::new()

    $azCommand = Get-Command -Name az -CommandType Application -ErrorAction SilentlyContinue
    if (-not $azCommand) {
        $notes.Add("Azure CLI ('az') is not on PATH, so nothing was discovered.")
        return @{ Available = $false; Values = $values; Notes = @($notes) }
    }

    $accountJson = & az account show -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $notes.Add("Not signed in to Azure ('az account show' failed), so nothing was discovered. Run 'az login', or supply the values as parameters.")
        return @{ Available = $false; Values = $values; Notes = @($notes) }
    }

    try { $account = $accountJson | ConvertFrom-Json }
    catch {
        $notes.Add("'az account show' returned output that could not be parsed as JSON, so nothing was discovered.")
        return @{ Available = $false; Values = $values; Notes = @($notes) }
    }

    $values['AZ_TENANT_ID'] = [string]$account.tenantId
    $values['AZ_SUBSCRIPTION_ID'] = [string]$account.id

    # An operator-supplied resource group is authoritative. A discovered one is
    # a guess until something corroborates it.
    $resolvedGroup = $ResourceGroup
    $corroborated = $true
    if ([string]::IsNullOrWhiteSpace($resolvedGroup)) {
        $found = Find-GuardrailWorkloadResourceGroup -EnvironmentName $EnvironmentName
        foreach ($note in $found.Notes) { $notes.Add($note) }
        $resolvedGroup = $found.Name
        $corroborated = $found.Corroborated
    }

    if ([string]::IsNullOrWhiteSpace($resolvedGroup)) {
        return @{ Available = $true; Values = $values; Notes = @($notes) }
    }

    # The resource group decides which estate this run governs, so "the only one
    # with a Foundry account in it" is not good enough on its own - plenty of
    # subscriptions hold exactly one unrelated Foundry account. Landing-zone
    # policy assignments are the corroboration: they are stamped by the same
    # template that created the resource group this playbook is meant to follow.
    $prefix = Get-GuardrailPrefixDiscovery -ResourceGroup $resolvedGroup
    if (-not $corroborated -and -not $prefix.Values.ContainsKey('ASSIGNMENT_PREFIX')) {
        $notes.Add("'$resolvedGroup' holds the only Foundry account in this subscription, but carries no landing-zone policy assignments and no matching azd environment tag, so it was NOT accepted as the workload resource group. Pass -ResourceGroup '$resolvedGroup' if it really is the right one.")
        return @{ Available = $true; Values = $values; Notes = @($notes) }
    }

    $values['AZ_RESOURCE_GROUP'] = $resolvedGroup
    foreach ($key in $prefix.Values.Keys) { $values[$key] = $prefix.Values[$key] }
    foreach ($note in $prefix.Notes) { $notes.Add($note) }

    $groupJson = & az group show --name $resolvedGroup -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        try { $values['AZ_LOCATION'] = [string]($groupJson | ConvertFrom-Json).location }
        catch { $notes.Add("Could not read the region of '$resolvedGroup': $($_.Exception.Message)") }
    }
    else {
        $notes.Add("Resource group '$resolvedGroup' could not be read, so its region was not discovered.")
    }

    $resources = Get-GuardrailResourceDiscovery -ResourceGroup $resolvedGroup
    foreach ($key in $resources.Values.Keys) { $values[$key] = $resources.Values[$key] }
    foreach ($note in $resources.Notes) { $notes.Add($note) }

    return @{ Available = $true; Values = $values; Notes = @($notes) }
}

function Find-GuardrailWorkloadResourceGroup {
    <#
    .SYNOPSIS
        Locate a candidate workload resource group, or return nothing and say why.

    .DESCRIPTION
        Two signals, strongest first. The azd environment tag is placed by the
        same deployment this playbook follows, so a hit there is corroborated.
        The presence of a Foundry account is only a candidate, and the caller
        must corroborate it before governing anything.

        Ambiguity is reported rather than resolved by taking the first match: a
        coin toss here is a cross-engagement hazard.
    #>
    [CmdletBinding()]
    param([string]$EnvironmentName)

    $notes = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
        $tagged = & az group list --tag "azd-env-name=$EnvironmentName" --query "[].name" -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $names = @()
            try { $names = @($tagged | ConvertFrom-Json) }
            catch { $notes.Add("Could not parse the azd-tagged resource group list: $($_.Exception.Message)") }
            if ($names.Count -eq 1) {
                $notes.Add("Resource group '$($names[0])' discovered from the azd tag azd-env-name=$EnvironmentName.")
                return @{ Name = [string]$names[0]; Corroborated = $true; Notes = @($notes) }
            }
            if ($names.Count -gt 1) {
                $notes.Add("$($names.Count) resource groups carry azd-env-name=$EnvironmentName ($($names -join ', ')), so the workload resource group is ambiguous.")
            }
        }
    }

    $foundryJson = & az resource list --resource-type 'Microsoft.CognitiveServices/accounts' --query "[].resourceGroup" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $notes.Add('Could not list Foundry accounts in the subscription, so the workload resource group was not discovered.')
        return @{ Name = ''; Corroborated = $false; Notes = @($notes) }
    }

    $groups = @()
    try { $groups = @($foundryJson | ConvertFrom-Json | Sort-Object -Unique) }
    catch { $notes.Add("Could not parse the Foundry account list: $($_.Exception.Message)") }

    if ($groups.Count -eq 1) {
        return @{ Name = [string]$groups[0]; Corroborated = $false; Notes = @($notes) }
    }
    if ($groups.Count -eq 0) {
        $notes.Add('No Foundry account was found in this subscription, so the workload resource group was not discovered. This playbook runs AFTER the landing zone is deployed.')
    }
    else {
        $notes.Add("$($groups.Count) resource groups hold a Foundry account ($($groups -join ', ')), so the workload resource group is ambiguous.")
    }

    return @{ Name = ''; Corroborated = $false; Notes = @($notes) }
}

function Get-GuardrailResourceDiscovery {
    <#
    .SYNOPSIS
        Find the APIM instance, Log Analytics workspace and Foundry account from
        one listing of the workload resource group.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceGroup)

    $values = @{}
    $notes = [System.Collections.Generic.List[string]]::new()

    $resourceJson = & az resource list --resource-group $ResourceGroup --query "[].{name:name,type:type,kind:kind}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $notes.Add("Could not list resources in '$ResourceGroup', so the gateway, workspace and Foundry account were not discovered.")
        return @{ Values = $values; Notes = @($notes) }
    }

    $resources = @()
    try { $resources = @($resourceJson | ConvertFrom-Json) }
    catch { return @{ Values = $values; Notes = @($notes) } }

    $wanted = @(
        @{ Key = 'APIM_NAME';               Type = 'Microsoft.ApiManagement/service';          Label = 'API Management instance' }
        @{ Key = 'LOG_ANALYTICS_WORKSPACE'; Type = 'Microsoft.OperationalInsights/workspaces'; Label = 'Log Analytics workspace' }
        @{ Key = 'FOUNDRY_ACCOUNT_NAME';    Type = 'Microsoft.CognitiveServices/accounts';     Label = 'Foundry account' }
    )

    foreach ($item in $wanted) {
        $matched = @($resources | Where-Object { $_.type -eq $item.Type } | Select-Object -ExpandProperty name)
        if ($matched.Count -eq 1) {
            $values[$item.Key] = [string]$matched[0]
        }
        elseif ($matched.Count -gt 1) {
            $notes.Add("$($matched.Count) resources match the $($item.Label) in '$ResourceGroup' ($($matched -join ', ')). Left blank - set $($item.Key) explicitly.")
        }
        else {
            $notes.Add("No $($item.Label) found in '$ResourceGroup'. Left blank; the plane that needs it reports it as a missing prerequisite.")
        }
    }

    return @{ Values = $values; Notes = @($notes) }
}

function Get-GuardrailPrefixDiscovery {
    <#
    .SYNOPSIS
        Recover ASSIGNMENT_PREFIX from the governance the landing zone deployed.

    .DESCRIPTION
        platform/policy stamps every assignment it owns with an `ailz-owner`
        metadata value of `ailz-governance:<resource group id>:<prefix>`. Reading
        the prefix back out of that is exact, where deriving it from the project
        and environment names would be a guess that silently points the playbook
        at governance it does not own.

        Only the `ailz-governance:` namespace counts. The playbook stamps its own
        creations `ailz-guardrails:` (see Get-GuardrailOwnerStamp), and matching
        those too would make discovery circular: on a subscription where the
        landing-zone governance was never deployed, it would read back a prefix
        the playbook itself had written and report success instead of the honest
        "governance may have been deployed with enabled=false".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceGroup)

    $values = @{}
    $notes = [System.Collections.Generic.List[string]]::new()

    $assignmentJson = & az policy assignment list --resource-group $ResourceGroup -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $notes.Add("Could not list policy assignments in '$ResourceGroup', so ASSIGNMENT_PREFIX was not discovered.")
        return @{ Values = $values; Notes = @($notes) }
    }

    $assignments = @()
    try { $assignments = @($assignmentJson | ConvertFrom-Json) }
    catch { return @{ Values = $values; Notes = @($notes) } }

    $prefixes = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($assignment in $assignments) {
        $owner = ''
        try { $owner = [string]$assignment.metadata.'ailz-owner' } catch { continue }
        if ([string]::IsNullOrWhiteSpace($owner)) { continue }
        if (-not $owner.StartsWith('ailz-governance:')) { continue }

        $segments = $owner -split ':'
        if ($segments.Count -lt 2) { continue }
        $candidate = $segments[-1].Trim()
        if ($candidate) { [void]$prefixes.Add($candidate) }
    }

    if ($prefixes.Count -eq 1) {
        $values['ASSIGNMENT_PREFIX'] = @($prefixes)[0]
    }
    elseif ($prefixes.Count -eq 0) {
        $notes.Add("No landing-zone policy assignments were found in '$ResourceGroup', so ASSIGNMENT_PREFIX was not discovered. Governance may have been deployed with enabled=false.")
    }
    else {
        $notes.Add("Policy assignments in '$ResourceGroup' carry $($prefixes.Count) different prefixes ($((@($prefixes)) -join ', ')), so ASSIGNMENT_PREFIX is ambiguous.")
    }

    return @{ Values = $values; Notes = @($notes) }
}

function Resolve-GuardrailSettings {
    <#
    .SYNOPSIS
        Walk every setting down the resolution ladder and report where each
        value came from.

    .PARAMETER Parameters
        The caller's $PSBoundParameters. Presence, not value, decides rung 1, so
        an explicitly supplied empty string still counts as an answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Parameters,
        [hashtable]$Existing = @{},
        [switch]$NonInteractive
    )

    $catalog = Get-GuardrailSettingCatalog
    $values = @{}
    $provenance = @{}
    $notes = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    $discovery = $null
    $needsDiscovery = $false
    foreach ($setting in $catalog) {
        if (-not $setting.Discover) { continue }
        if ($Parameters.ContainsKey($setting.Parameter)) { continue }
        if (Get-GuardrailEnvironmentValue -Names $setting.EnvNames) { continue }
        if ($Existing.ContainsKey($setting.Key) -and -not [string]::IsNullOrWhiteSpace($Existing[$setting.Key])) { continue }
        $needsDiscovery = $true
        break
    }

    if ($needsDiscovery) {
        $discoveryGroup = ''
        if ($Parameters.ContainsKey('ResourceGroup')) { $discoveryGroup = [string]$Parameters['ResourceGroup'] }
        if (-not $discoveryGroup) { $discoveryGroup = Get-GuardrailEnvironmentValue -Names @('AZ_RESOURCE_GROUP', 'AZURE_RESOURCE_GROUP') }
        if (-not $discoveryGroup -and $Existing.ContainsKey('AZ_RESOURCE_GROUP')) { $discoveryGroup = [string]$Existing['AZ_RESOURCE_GROUP'] }

        $discoveryEnvironment = ''
        if ($Parameters.ContainsKey('EnvironmentName')) { $discoveryEnvironment = [string]$Parameters['EnvironmentName'] }
        if (-not $discoveryEnvironment) { $discoveryEnvironment = Get-GuardrailEnvironmentValue -Names @('AZURE_ENV_NAME', 'ENVIRONMENT') }

        Write-Host '  Discovering the estate from the signed-in az context...' -ForegroundColor DarkGray
        $discovery = Get-GuardrailAzureDiscovery -ResourceGroup $discoveryGroup -EnvironmentName $discoveryEnvironment
        foreach ($note in $discovery.Notes) { $notes.Add($note) }
    }

    foreach ($setting in $catalog) {
        $key = $setting.Key
        $resolved = $null
        $source = $null

        if ($Parameters.ContainsKey($setting.Parameter)) {
            $resolved = ConvertTo-GuardrailEnvString -Value $Parameters[$setting.Parameter]
            $source = 'parameter'
        }

        if ($null -eq $source) {
            $fromEnvironment = Get-GuardrailEnvironmentValue -Names $setting.EnvNames
            if ($fromEnvironment) { $resolved = $fromEnvironment; $source = 'environment' }
        }

        if ($null -eq $source -and $Existing.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($Existing[$key])) {
            $resolved = [string]$Existing[$key]
            $source = 'existing .env'
        }

        if ($null -eq $source -and $setting.Discover -and $discovery -and $discovery.Values.ContainsKey($setting.Discover)) {
            $candidate = [string]$discovery.Values[$setting.Discover]
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $resolved = $candidate; $source = 'azure' }
        }

        if ($null -eq $source -and $setting.Prompt) {
            if ($NonInteractive) {
                if ($setting.Required) {
                    $missing.Add(("  {0}`n      parameter           -{1}`n      environment variable {2}" -f
                        $key, $setting.Parameter, ($setting.EnvNames -join ' or ')))
                    continue
                }
            }
            else {
                $answer = Read-Host -Prompt ("  {0}`n    {1}" -f $setting.Prompt, $key)
                if (-not [string]::IsNullOrWhiteSpace($answer)) { $resolved = $answer.Trim(); $source = 'prompt' }
                elseif ($setting.Required) {
                    $missing.Add("  $key was left blank at the prompt, and it is required.")
                    continue
                }
            }
        }

        if ($null -eq $source) {
            if ($setting.Required) {
                $missing.Add(("  {0}`n      parameter           -{1}`n      environment variable {2}" -f
                    $key, $setting.Parameter, ($setting.EnvNames -join ' or ')))
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($resolved) -and -not $setting.AllowEmpty -and $setting.Required) {
            $missing.Add("  $key resolved to an empty value from $source, and it is required.")
            continue
        }

        $values[$key] = $resolved
        $provenance[$key] = $source
    }

    if ($missing.Count -gt 0) {
        $reason = if ($NonInteractive) {
            'This run is non-interactive, so nothing could be prompted for.'
        }
        else {
            'These have no value and no default.'
        }

        throw @"
BOOTSTRAP INCOMPLETE - $($missing.Count) required setting(s) could not be resolved.

$reason Supply each one as a parameter or an environment variable:

$($missing -join "`n`n")

Resolution order is: parameter, environment variable, existing .env, az discovery, prompt.
$(if ($notes.Count -gt 0) { "`nDiscovery notes:`n" + (($notes | ForEach-Object { "  - $_" }) -join "`n") })
"@
    }

    return @{ Values = $values; Provenance = $provenance; Notes = @($notes) }
}

function Get-GuardrailEnvironmentValue {
    [CmdletBinding()]
    param([string[]]$Names = @())

    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return ''
}

function ConvertTo-GuardrailEnvString {
    <#
    .SYNOPSIS
        Render a parameter value the way .env expects it: arrays become a
        comma-separated list, everything else its invariant string form.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }

    if ($Value -is [System.Array]) {
        return (@($Value | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim() }) -join ',')
    }

    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }

    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    }

    return ([string]$Value).Trim()
}

function Write-GuardrailEnvFile {
    <#
    .SYNOPSIS
        Render .env from .env.example, substituting resolved values and keeping
        every comment the template carries.

    .DESCRIPTION
        The template is the documentation. Copying it verbatim except for the
        values means an operator who opens the generated file still reads why
        each ceiling is where it is, rather than a bare list of keys.

        Merge, not replace: keys the template no longer carries but the existing
        file did are appended rather than dropped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Template not found: '$TemplatePath'. The bootstrap renders .env from .env.example and cannot run without it."
    }

    foreach ($key in $Values.Keys) {
        $value = [string]$Values[$key]
        if ($value -match "[`r`n]") {
            throw "Value for '$key' contains a line break. A .env value is a single line."
        }
    }

    $remaining = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Values.Keys))
    $output = [System.Collections.Generic.List[string]]::new()

    foreach ($line in (Get-Content -LiteralPath $TemplatePath)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { $output.Add($line); continue }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { $output.Add($line); continue }

        $key = $trimmed.Substring(0, $separator).Trim()
        if (-not $Values.ContainsKey($key)) { $output.Add($line); continue }

        # Keep the template's trailing hint, mirroring the parser's rule that an
        # inline comment only exists when the value is unquoted.
        $comment = ''
        $rawValue = $trimmed.Substring($separator + 1)
        if ($rawValue.TrimStart() -notmatch '^["'']') {
            $hash = $rawValue.IndexOf('#')
            if ($hash -ge 0) { $comment = $rawValue.Substring($hash).TrimEnd() }
        }

        $output.Add((Format-GuardrailEnvLine -Key $key -Value ([string]$Values[$key]) -Comment $comment -CommentColumn $line.IndexOf('#')))
        [void]$remaining.Remove($key)
    }

    if ($remaining.Count -gt 0) {
        $output.Add('')
        $output.Add('# -----------------------------------------------------------------------------')
        $output.Add('# Carried over from the previous .env; no longer present in .env.example.')
        $output.Add('# -----------------------------------------------------------------------------')
        foreach ($key in (@($remaining) | Sort-Object)) {
            $output.Add((Format-GuardrailEnvLine -Key $key -Value ([string]$Values[$key]) -Comment '' -CommentColumn -1))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the guardrails .env')) { return $Path }

    Set-Content -LiteralPath $Path -Value $output -Encoding utf8NoBOM
    return $Path
}

function Format-GuardrailEnvLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Comment,
        [Parameter(Mandatory)][int]$CommentColumn
    )

    # A '#' inside an unquoted value would be read back as the start of a
    # comment and silently truncate the value, so quote it instead.
    $rendered = if ($Value.Contains('#')) { '"' + $Value.Replace('"', '') + '"' } else { $Value }
    $pair = "$Key=$rendered"

    if (-not $Comment) { return $pair }

    $padding = [Math]::Max(1, $CommentColumn - $pair.Length)
    return $pair + (' ' * $padding) + $Comment
}

function Invoke-GuardrailBootstrap {
    <#
    .SYNOPSIS
        Generate .env, or report why the existing one was kept.

    .DESCRIPTION
        Returns the path that the run should load. An existing .env is never
        overwritten without -Force; it is reported and reused, so re-running the
        bootstrap converges rather than clobbering.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [switch]$Force,
        [switch]$NonInteractive
    )

    $templatePath = Join-Path $ScriptRoot '.env.example'
    $exists = Test-Path -LiteralPath $EnvFile

    Write-Host ''
    Write-Host ' Bootstrap' -ForegroundColor Cyan

    if ($exists -and -not $Force) {
        Write-Host ("  '{0}' already exists - keeping it untouched and running against it." -f $EnvFile) -ForegroundColor Yellow
        Write-Host '  Re-run with -Force to regenerate it (your existing values are carried over).' -ForegroundColor DarkGray
        return $EnvFile
    }

    $existingValues = @{}
    if ($exists) {
        $existingValues = Import-GuardrailEnvironment -Path $EnvFile
        Write-Host ("  Regenerating '{0}'; {1} existing value(s) carried over." -f $EnvFile, $existingValues.Count) -ForegroundColor Gray
    }

    if ($NonInteractive) {
        Write-Host '  Non-interactive: nothing will be prompted for.' -ForegroundColor DarkGray
    }

    $resolution = Resolve-GuardrailSettings -Parameters $Parameters -Existing $existingValues -NonInteractive:$NonInteractive

    # Merge, do not replace. Everything the previous file held survives, and the
    # newly resolved values win where they overlap.
    $merged = @{}
    foreach ($key in $existingValues.Keys) { $merged[$key] = $existingValues[$key] }
    foreach ($key in $resolution.Values.Keys) { $merged[$key] = $resolution.Values[$key] }

    Write-GuardrailEnvFile -TemplatePath $templatePath -Path $EnvFile -Values $merged | Out-Null

    Write-Host ("  Wrote {0}" -f $EnvFile) -ForegroundColor Green
    foreach ($key in ($resolution.Provenance.Keys | Sort-Object)) {
        $shown = $resolution.Values[$key]
        if ([string]::IsNullOrWhiteSpace($shown)) { $shown = '(blank)' }
        Write-Host ("    {0,-28} {1,-14} {2}" -f $key, "[$($resolution.Provenance[$key])]", $shown) -ForegroundColor DarkGray
    }

    if ($resolution.Notes.Count -gt 0) {
        Write-Host '  Discovery notes:' -ForegroundColor DarkGray
        foreach ($note in $resolution.Notes) { Write-Host "    - $note" -ForegroundColor DarkGray }
    }

    return $EnvFile
}

Export-ModuleMember -Function @(
    'Get-GuardrailSettingCatalog'
    'Test-GuardrailInteractive'
    'Get-GuardrailAzureDiscovery'
    'Resolve-GuardrailSettings'
    'Write-GuardrailEnvFile'
    'Invoke-GuardrailBootstrap'
)
