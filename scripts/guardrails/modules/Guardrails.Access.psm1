#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Plane 0 - the custom "innovate but don't spend" RBAC role.

.DESCRIPTION
    This module creates ONE HALF of a two-part guardrail.

    Azure RBAC is a list of resource-provider operations. It cannot read the
    SKU, size, capacity or throughput in a request body, so no role can express
    "may create a Fabric capacity, but not an F2048". Microsoft states the
    division of labour directly in the Azure Policy overview: Policy evaluates
    properties on resources, RBAC manages user actions.

    Therefore:
      this module  -> WHICH resource types may be created
      Guardrails.Policy -> HOW EXPENSIVE each one may be

    The orchestrator refuses to create the role without the ceiling policies
    for exactly this reason.
#>

$ErrorActionPreference = 'Stop'

$script:RoleApiVersion = '2022-04-01'
$script:PolicyOverviewRef = 'https://learn.microsoft.com/azure/governance/policy/overview'

function Build-RoleDefinitionBody {
    <#
    .SYNOPSIS
        Expand the role template from .env values into a concrete definition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$RoleDescription,
        [Parameter(Mandatory)][string]$AssignableScope,
        [Parameter(Mandatory)][string[]]$Providers
    )

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Role template not found at '$TemplatePath'."
    }

    $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -Depth 30

    # Every named provider gets full write within its own namespace. The
    # bounding is done by which namespaces are named, plus the notActions, plus
    # the SKU-ceiling policies.
    $providerActions = @($Providers | ForEach-Object { "$_/*" })

    $actions = [System.Collections.Generic.List[string]]::new()
    foreach ($action in $template.permissions[0].actions) {
        if ($action -eq '__PROVIDER_ACTIONS__') {
            foreach ($providerAction in $providerActions) { $actions.Add($providerAction) }
        }
        else {
            $actions.Add($action)
        }
    }

    # Deduplicate while preserving order, then drop any explicit action already
    # covered by a broader wildcard we just added (e.g. Microsoft.Network/... is
    # kept because Microsoft.Network is NOT a wildcard provider by default).
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $wildcards = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($providerAction in $providerActions) { [void]$wildcards.Add($providerAction) }

    $finalActions = [System.Collections.Generic.List[string]]::new()
    foreach ($action in $actions) {
        if (-not $seen.Add($action)) { continue }

        $namespace = ($action -split '/')[0]
        if ($wildcards.Contains("$namespace/*") -and $action -ne "$namespace/*") {
            continue  # already covered by the namespace wildcard
        }
        $finalActions.Add($action)
    }

    return [pscustomobject]@{
        Name             = $RoleName
        Description      = $RoleDescription
        AssignableScopes = @($AssignableScope)
        Actions          = @($finalActions)
        NotActions       = @($template.permissions[0].notActions)
        DataActions      = @()
        NotDataActions   = @()
    }
}

function ConvertTo-CliRoleDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Role,
        [string]$ExistingRoleId
    )

    $body = [ordered]@{
        Name             = $Role.Name
        Description      = $Role.Description
        AssignableScopes = @($Role.AssignableScopes)
        Actions          = @($Role.Actions)
        NotActions       = @($Role.NotActions)
        DataActions      = @($Role.DataActions)
        NotDataActions   = @($Role.NotDataActions)
    }

    # An update must carry the existing definition's GUID or the CLI creates a
    # duplicate role with the same display name, which is confusing and hard to
    # unpick later.
    if ($ExistingRoleId) { $body['Id'] = $ExistingRoleId }

    return $body
}

function Get-ExistingRoleDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$Scope
    )

    $found = Invoke-AzCli -AllowNotFound -Arguments @(
        'role', 'definition', 'list',
        '--name', $RoleName,
        '--scope', $Scope,
        '--custom-role-only', 'true',
        '-o', 'json'
    )

    if (-not $found) { return $null }
    $list = @($found)
    if ($list.Count -eq 0) { return $null }
    return $list[0]
}

function Test-RoleDefinitionMatches {
    <#
    .SYNOPSIS
        Compare desired versus live permissions, order-insensitively.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Desired,
        [Parameter(Mandatory)]$Existing
    )

    $normalise = {
        param($values)
        if ($null -eq $values) { return @() }
        return @($values | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    }

    $existingActions = & $normalise $Existing.permissions[0].actions
    $existingNotActions = & $normalise $Existing.permissions[0].notActions
    $desiredActions = & $normalise $Desired.Actions
    $desiredNotActions = & $normalise $Desired.NotActions

    $actionsMatch = -not (Compare-Object -ReferenceObject $existingActions -DifferenceObject $desiredActions)
    $notActionsMatch = -not (Compare-Object -ReferenceObject $existingNotActions -DifferenceObject $desiredNotActions)
    $descriptionMatch = ([string]$Existing.description) -eq $Desired.Description

    return [pscustomobject]@{
        Matches         = ($actionsMatch -and $notActionsMatch -and $descriptionMatch)
        ActionsMatch    = $actionsMatch
        NotActionsMatch = $notActionsMatch
        MissingActions  = @(($desiredActions | Where-Object { $_ -notin $existingActions }))
        ExtraActions    = @(($existingActions | Where-Object { $_ -notin $desiredActions }))
    }
}

function Invoke-AccessGuardrails {
    <#
    .SYNOPSIS
        Create or converge the cost-bounded custom role, and optionally assign it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$RootPath
    )

    $plane = '0-Access'

    if (-not $Config.RoleEnabled) {
        Add-GuardrailResult -Plane $plane -Name 'Custom role' -Status 'Skipped' `
            -Detail 'ROLE_ENABLED is false.' | Out-Null
        return
    }

    $scope = if ($Config.RoleAssignableScope -eq 'subscription') {
        "/subscriptions/$($Target.SubscriptionId)"
    }
    else {
        $Config.RoleAssignableScope
    }

    $providers = @($Config.RoleAllowedProviders + $Config.RoleExtraProviders |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)

    if ($providers.Count -eq 0) {
        Add-GuardrailResult -Plane $plane -Name 'Custom role' -Status 'Failed' `
            -Detail 'No providers configured. ROLE_ALLOWED_PROVIDERS and ROLE_EXTRA_PROVIDERS are both empty, which would create a read-only role.' | Out-Null
        return
    }

    $templatePath = Join-Path $RootPath 'roles/ai-innovator.role.json'
    $desired = Build-RoleDefinitionBody `
        -TemplatePath $templatePath `
        -RoleName $Config.RoleName `
        -RoleDescription $Config.RoleDescription `
        -AssignableScope $scope `
        -Providers $providers

    # The load-bearing caveat, recorded in the evidence file every run so it
    # cannot be lost between the person who built this and the person who
    # inherits it.
    Add-GuardrailResult -Plane $plane -Name 'RBAC scope limitation (informational)' -Status 'Finding' `
        -Detail 'This role controls WHICH resource types can be created. It cannot control SKU, size, capacity or throughput - RBAC has no visibility of request-body properties. The SKU ceilings in plane 1 are the other half of this guardrail and must be assigned for the control to hold.' `
        -Remediation 'Confirm the plane 1 policy assignments (Foundry capacity, Foundry account SKU, AI Search ceiling, Fabric SKU, Cosmos throughput) are present and, eventually, set to Deny.' `
        -Reference $script:PolicyOverviewRef | Out-Null

    $existing = Get-ExistingRoleDefinition -RoleName $Config.RoleName -Scope $scope

    Invoke-GuardrailAction -Plane $plane -Name "Custom role '$($Config.RoleName)'" `
        -Reference $script:PolicyOverviewRef `
        -WouldDo "Create or update the role with $($desired.Actions.Count) actions and $($desired.NotActions.Count) notActions at $scope" `
        -Probe {
            if (-not $existing) {
                return @{ Compliant = $false; Detail = 'role does not exist'; Evidence = @{ present = $false } }
            }

            $comparison = Test-RoleDefinitionMatches -Desired $desired -Existing $existing
            if ($comparison.Matches) {
                return @{
                    Compliant = $true
                    Detail    = "already matches ($($desired.Actions.Count) actions, $($desired.NotActions.Count) notActions)"
                    Evidence  = @{ roleId = $existing.id; roleName = $existing.roleName }
                }
            }

            $drift = @()
            if ($comparison.MissingActions.Count -gt 0) { $drift += "$($comparison.MissingActions.Count) missing action(s)" }
            if ($comparison.ExtraActions.Count -gt 0)   { $drift += "$($comparison.ExtraActions.Count) extra action(s)" }
            if (-not $comparison.NotActionsMatch)       { $drift += 'notActions differ' }

            return @{
                Compliant = $false
                Detail    = "drift: $($drift -join ', ')"
                Evidence  = @{
                    roleId         = $existing.id
                    missingActions = $comparison.MissingActions
                    extraActions   = $comparison.ExtraActions
                }
            }
        } `
        -Action {
            $existingId = if ($existing) { [string]$existing.name } else { $null }
            $body = ConvertTo-CliRoleDefinition -Role $desired -ExistingRoleId $existingId

            $file = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                "guardrail-role-$([guid]::NewGuid().ToString('N')).json")
            try {
                $body | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file -Encoding utf8NoBOM

                $verb = if ($existing) { 'update' } else { 'create' }
                $result = Invoke-AzCli -Arguments @(
                    'role', 'definition', $verb,
                    '--role-definition', "@$file",
                    '-o', 'json'
                )
                return @{ roleId = $result.id; roleName = $result.roleName; operation = $verb }
            }
            finally {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            }
        } | Out-Null

    Invoke-RoleAssignments -Config $Config -Target $Target -Scope $scope -Plane $plane
}

function Invoke-RoleAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Plane
    )

    if ($Config.RoleAssignPrincipalIds.Count -eq 0) {
        Add-GuardrailResult -Plane $Plane -Name 'Role assignment' -Status 'Skipped' `
            -Detail 'ROLE_ASSIGN_PRINCIPAL_IDS is empty. The role definition exists but is assigned to nobody.' `
            -Remediation 'Recommended for a first run. Read the role in the portal, then populate ROLE_ASSIGN_PRINCIPAL_IDS with a GROUP object ID rather than individual users.' | Out-Null
        return
    }

    foreach ($principalId in $Config.RoleAssignPrincipalIds) {
        Invoke-GuardrailAction -Plane $Plane -Name "Role assignment -> $principalId" `
            -WouldDo "Assign '$($Config.RoleName)' to principal $principalId at $Scope" `
            -Probe {
                $existing = Invoke-AzCli -AllowNotFound -Arguments @(
                    'role', 'assignment', 'list',
                    '--assignee-object-id', $principalId,
                    '--role', $Config.RoleName,
                    '--scope', $Scope,
                    '-o', 'json'
                )
                if ($existing -and @($existing).Count -gt 0) {
                    return @{ Compliant = $true; Detail = 'assignment already exists'; Evidence = @($existing)[0] }
                }
                return @{ Compliant = $false; Detail = 'not assigned'; Evidence = @{ present = $false } }
            } `
            -Action {
                # --assignee-object-id avoids a Graph lookup, so this works for
                # groups and service principals without directory read rights.
                $result = Invoke-AzCli -Arguments @(
                    'role', 'assignment', 'create',
                    '--assignee-object-id', $principalId,
                    '--role', $Config.RoleName,
                    '--scope', $Scope,
                    '-o', 'json'
                )
                return @{ assignmentId = $result.id; principalId = $principalId }
            } | Out-Null
    }

    Add-GuardrailResult -Plane $Plane -Name 'RBAC propagation notice' -Status 'Finding' `
        -Detail 'Role assignments take up to 10 minutes to take effect, and an already-issued access token keeps its old role claims until it is refreshed. A 403 immediately after assignment is expected, not a defect.' `
        -Remediation 'Sign out and back in, or request a fresh token, before concluding the assignment did not work. Do not widen the role in response.' `
        -Reference 'https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#azure-role-assignments' | Out-Null
}

Export-ModuleMember -Function @(
    'Invoke-AccessGuardrails'
    'Build-RoleDefinitionBody'
    'Test-RoleDefinitionMatches'
)
