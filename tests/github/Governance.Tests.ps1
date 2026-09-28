#Requires -Version 7.0
[CmdletBinding()]
param([string]$TemplatePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'platform\policy\Governance.psm1') -Force
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected governance rejection.'
    Assert-True ($caught.Exception.Message -like $Pattern) "Unexpected failure; expected $Pattern"
}
function New-Profile { & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1') }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ailz-governance-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $profile = New-Profile
    $contactGroup = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)/providers/Microsoft.Insights/actionGroups/synthetic-budget-alerts"
    $profile.governance.budget.contactGroups = @($contactGroup)
    $resolved = New-GovernanceDeploymentParameters -Profile $profile -BillingCurrency USD -AllowSynthetic
    $p = $resolved.parameters
    Assert-True ($p.enabled.value -eq $true) 'Explicit governance resolution did not opt in.'
    Assert-True ($p.resourceGroupName.value -ceq $profile.azure.resourceGroup) 'Governance was not scoped to the exact workload RG.'
    Assert-True ($p.expectedSubscriptionId.value -ceq $profile.azure.subscriptionId -and $p.expectedTenantId.value -ceq $profile.azure.tenantId) 'The privileged boundary must reject an unintended execution subscription/tenant.'
    Assert-True ($p.configuration.value.policyEffect -ceq 'Audit') 'Initial governance must be audit-first.'
    Assert-True ($p.configuration.value.budget.amount -eq 10) 'Budget amount changed.'
    Assert-True ($p.configuration.value.inferenceAllowance.allocatedTokens -eq 2000) 'Inference allowance was lost.'
    Assert-Throws { New-GovernanceDeploymentParameters -Profile $profile -BillingCurrency EUR -AllowSynthetic } '*currency*'
    Assert-Throws { New-GovernanceDeploymentParameters -Profile $profile -BillingCurrency '' -AllowSynthetic } '*'
    foreach ($mutation in @(
        { param($x) $x.governance.policyEffect = 'Deny'; $x.governance.assessmentApproved = $false },
        { param($x) $x.governance.budget.amount = 0 },
        { param($x) $x.governance.budget.contactEmails = @(); $x.governance.budget.contactGroups = @() },
        { param($x) $x.governance.budget.actualThreshold = 0 },
        { param($x) $x.governance.budget.forecastThreshold = 1001 },
        { param($x) $x.governance.budget.startDate = '2026-09-02' },
        { param($x) $x.governance.budget.endDate = '2026-08-01' },
        { param($x) $x.governance.budget.currency = 'EUR' },
        { param($x) $x.governance.allowedLocations = @() },
        { param($x) $x.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/gpt-5') },
        { param($x) $x.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/') },
        { param($x) $x.governance.allowedModelAssetIds = @('azureml://registries/azure-openai/models/*/') },
        { param($x) $x.governance.allowedDeploymentSkus = @() },
        { param($x) $x.governance.inferenceAllowance.pricingSources = @() }
    )) {
        $bad = New-Profile
        & $mutation $bad
        Assert-Throws { New-GovernanceDeploymentParameters -Profile $bad -BillingCurrency USD -AllowSynthetic }
    }
    $decimalProfile = New-Profile
    $decimalProfile.governance.budget.amount = [decimal]10.75
    $decimalProfile.governance.budget.actualThreshold = [decimal]55.5
    $decimalParameters = New-GovernanceDeploymentParameters -Profile $decimalProfile -BillingCurrency USD -AllowSynthetic
    Assert-True ($decimalParameters.parameters.configuration.value.budget.amount -eq [decimal]10.75) 'Currency amount was rounded or converted.'
    Assert-True ($decimalParameters.parameters.configuration.value.budget.actualThreshold -eq [decimal]55.5) 'Threshold was rounded.'
    $denied = New-Profile
    $denied.governance.policyEffect = 'Deny'
    $denied.governance.assessmentApproved = $true
    Assert-True ((New-GovernanceDeploymentParameters -Profile $denied -BillingCurrency USD -AllowSynthetic).parameters.configuration.value.policyEffect -ceq 'Deny') 'Approved Deny was silently downgraded.'

    $contract = [IO.Path]::GetRelativePath($scratch, (Join-Path $root 'platform\policy\contracts.bicep')).Replace('\', '/')
    $profile.governance | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $scratch 'governance.json')
    $decimalProfile.governance.budget | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $scratch 'decimal-budget.json')
    @"
using none
import { approvedModels, budgetProperties } from '$contract'
var configuration = loadJsonContent('./governance.json')
param models = approvedModels(configuration.allowedModelAssetIds)
param versionedModels = approvedModels(['azureml://registries/azure-openai/models/gpt-5-nano/versions/1'])
param budget = budgetProperties(configuration.budget)
param decimalBudget = budgetProperties(loadJsonContent('./decimal-budget.json'))
"@ | Set-Content -LiteralPath (Join-Path $scratch 'contracts.bicepparam')
    & bicep build-params (Join-Path $scratch 'contracts.bicepparam') --outfile (Join-Path $scratch 'contracts.parameters.json')
    if ($LASTEXITCODE -ne 0) { throw 'Governance contract compilation failed.' }
    $generatedJson = Get-Content -LiteralPath (Join-Path $scratch 'contracts.parameters.json') -Raw
    $generated = $generatedJson | ConvertFrom-Json -AsHashtable
    $budget = $generated.parameters.budget.value
    Assert-True ($generated.parameters.decimalBudget.value.amount -eq [decimal]10.75 -and $generated.parameters.decimalBudget.value.notifications.actual.threshold -eq [decimal]55.5) 'The actual Bicep renderer rounded a financial input.'
    Assert-True (-not $budget.Contains('filter')) 'A whole-environment budget must not filter to inference or tags.'
    Assert-True (-not $budget.Contains('currency')) 'Currency is not a writable Consumption budget property.'
    Assert-True ($budget.category -ceq 'Cost' -and $budget.timeGrain -ceq 'Monthly') 'Incorrect budget category/period.'
    $jsonDocument = [System.Text.Json.JsonDocument]::Parse($generatedJson)
    try {
        $period = $jsonDocument.RootElement.GetProperty('parameters').GetProperty('budget').GetProperty('value').GetProperty('timePeriod')
        Assert-True ($period.GetProperty('startDate').GetString() -ceq '2026-09-01T00:00:00Z' -and $period.GetProperty('endDate').GetString() -ceq '2026-10-01T00:00:00Z') 'Budget dates were invented or changed.'
    }
    finally { $jsonDocument.Dispose() }
    Assert-True ($budget.notifications.actual.thresholdType -ceq 'Actual' -and $budget.notifications.forecast.thresholdType -ceq 'Forecasted') 'Both actual and forecast notifications are required.'
    foreach ($n in $budget.notifications.Values) {
        Assert-True ($n.enabled -and $n.contactEmails[0] -ceq 'synthetic-owner@example.invalid' -and $n.contactGroups.Count -eq 1 -and $n.contactGroups[0] -ceq $contactGroup) 'Actual/forecast email and action-group recipients changed.'
        Assert-True ($n.contactRoles.Count -eq 0 -and $n.operator -ceq 'GreaterThanOrEqualTo') 'Unexpected notification authority or comparison.'
    }

    $rule = Get-Content -LiteralPath (Join-Path $root 'platform\policy\exact-models.policy.json') -Raw | ConvertFrom-Json -AsHashtable
    $skuRule = Get-Content -LiteralPath (Join-Path $root 'platform\policy\deployment-skus.policy.json') -Raw | ConvertFrom-Json -AsHashtable
    function Resolve-PolicyValue {
        param($Value, $Parameters, $Current)
        if ($Value -isnot [string]) { return $Value }
        if ($Value -match "^\[parameters\('([^']+)'\)\]$") { return ,$Parameters[$Matches[1]] }
        if ($Value -match "^\[current\('approvedModel'\)\.([a-zA-Z]+)\]$") { return $Current[$Matches[1]] }
        return $Value
    }
    function Test-PolicyCondition {
        param($Condition, $Fields, $Parameters, $Current = @{})
        if ($Condition.Contains('allOf')) {
            foreach ($c in $Condition.allOf) { if (-not (Test-PolicyCondition $c $Fields $Parameters $Current)) { return $false } }
            return $true
        }
        if ($Condition.Contains('anyOf')) {
            foreach ($c in $Condition.anyOf) { if (Test-PolicyCondition $c $Fields $Parameters $Current) { return $true } }
            return $false
        }
        $left = if ($Condition.Contains('field')) { $Fields[$Condition.field] }
        elseif ($Condition.Contains('count')) {
            $count = 0
            foreach ($item in (Resolve-PolicyValue $Condition.count.value $Parameters $Current)) {
                if (Test-PolicyCondition $Condition.count.where $Fields $Parameters $item) { $count++ }
            }
            $count
        } else { Resolve-PolicyValue $Condition.value $Parameters $Current }
        foreach ($operator in @('equals', 'notEquals', 'in', 'notIn')) {
            if ($Condition.Contains($operator)) {
                $right = Resolve-PolicyValue $Condition[$operator] $Parameters $Current
                switch ($operator) {
                    'equals' { return $left -eq $right }
                    'notEquals' { return $left -ne $right }
                    'in' { return $left -in $right }
                    'notIn' { return $left -notin $right }
                }
            }
        }
        throw 'Unsupported policy test condition.'
    }
    $fields = @{
        type = 'Microsoft.CognitiveServices/accounts/deployments'
        'Microsoft.CognitiveServices/accounts/deployments/model.format' = 'OpenAI'
        'Microsoft.CognitiveServices/accounts/deployments/model.name' = 'gpt-5-nano'
        'Microsoft.CognitiveServices/accounts/deployments/model.version' = '2025-08-07'
        'Microsoft.CognitiveServices/accounts/deployments/sku.name' = 'GlobalStandard'
    }
    $parameters = @{ allowedModels = $generated.parameters.models.value; allowedDeploymentSkus = @('GlobalStandard') }
    Assert-True (-not (Test-PolicyCondition $rule.if $fields $parameters)) 'Exact approved model was denied.'
    foreach ($badModel in @('gpt-5', 'gpt-5-nano-evil', 'prefix-gpt-5-nano', 'gpt-5-nano/versions/other')) {
        $fields['Microsoft.CognitiveServices/accounts/deployments/model.name'] = $badModel
        Assert-True (Test-PolicyCondition $rule.if $fields $parameters) 'Model prefix or publisher overmatch.'
    }
    $fields['Microsoft.CognitiveServices/accounts/deployments/model.name'] = 'gpt-5-nano'
    $parameters.allowedModels = $generated.parameters.versionedModels.value
    foreach ($version in @('10', '1-preview', '', '2025-08-07')) {
        $fields['Microsoft.CognitiveServices/accounts/deployments/model.version'] = $version
        Assert-True (Test-PolicyCondition $rule.if $fields $parameters) 'Version prefix overmatch.'
    }
    $fields['Microsoft.CognitiveServices/accounts/deployments/model.version'] = '1'
    Assert-True (-not (Test-PolicyCondition $rule.if $fields $parameters)) 'Exact version was denied.'
    Assert-True (-not (Test-PolicyCondition $skuRule.if $fields $parameters)) 'Approved deployment SKU was denied.'
    $fields['Microsoft.CognitiveServices/accounts/deployments/sku.name'] = 'GlobalProvisionedManaged'
    Assert-True (Test-PolicyCondition $skuRule.if $fields $parameters) 'Unapproved deployment SKU was allowed.'
    $fields.type = 'Microsoft.Storage/storageAccounts'
    Assert-True (-not (Test-PolicyCondition $rule.if $fields $parameters) -and -not (Test-PolicyCondition $skuRule.if $fields $parameters)) 'AI custom policy affects unrelated resource types.'

    $script:requests = [Collections.Generic.List[object]]::new()
    $request = {
        param($Method, $Uri, $Body, $Headers)
        $script:requests.Add(@{ method = $Method; uri = $Uri })
        return @{ StatusCode = 404; Headers = @{}; Body = @{ error = @{ code = 'ResourceNotFound' } } }
    }
    $plan = Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $request -AllowSynthetic
    $scope = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)"
    Assert-True ($plan.scope -ceq $scope) 'Plan widened the assignment/budget scope.'
    Assert-True ($script:requests.Count -gt 0 -and @($script:requests | Where-Object method -ne GET).Count -eq 0) 'Governance planning did not exclusively read actual mocked ARM state.'
    foreach ($fact in $plan.resources) {
        if ($fact.kind -in @('assignment', 'budget')) { Assert-True ($fact.resourceId.StartsWith("$scope/providers/", [StringComparison]::OrdinalIgnoreCase)) 'Workload governance escaped the RG.' }
    }
    $unowned = {
        param($Method, $Uri, $Body, $Headers)
        return @{ StatusCode = 200; Headers = @{}; Body = @{ properties = @{ metadata = @{ 'ailz-owner' = 'unrelated' } } } }
    }
    Assert-Throws { Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $unowned -AllowSynthetic } '*ownership*'
    $orphanState = @{ disabled = $false }
    $orphan = {
        param($Method, $Uri, $Body, $Headers)
        if ($Uri -match '/policyAssignments\?') {
            return @{ StatusCode = 200; Headers = @{}; Body = @{ value = @(@{
                id = "$scope/providers/Microsoft.Authorization/policyAssignments/synthetic-dev-tag-99"
                properties = @{
                    metadata = @{ 'ailz-owner' = $plan.owner }
                    notScopes = $(if ($orphanState.disabled) { @($scope) } else { @() })
                    enforcementMode = 'DoNotEnforce'
                }
            }) } }
        }
        return @{ StatusCode = 404; Headers = @{}; Body = @{ error = @{ code = 'ResourceNotFound' } } }
    }.GetNewClosure()
    Assert-Throws { Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $orphan -AllowSynthetic } '*removed*'
    $orphanState.disabled = $true
    $preserved = Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $orphan -AllowSynthetic
    Assert-True (@($preserved.resources | Where-Object kind -eq 'preservedDisabledAssignment').Count -eq 1) 'A previously disabled owned assignment was not preserved and recorded.'
    $budgetState = @{ etag = 'budget-version-1' }
    $budgetId = "$scope/providers/Microsoft.Consumption/budgets/synthetic-dev-environment"
    $owned = {
        param($Method, $Uri, $Body, $Headers)
        if ($Uri -match '/policyAssignments/synthetic-dev-network\?') {
            return @{ StatusCode = 200; Headers = @{}; Body = @{
                id = "$scope/providers/Microsoft.Authorization/policyAssignments/synthetic-dev-network"
                properties = @{ metadata = @{ 'ailz-owner' = $plan.owner; budgetResourceId = $budgetId } }
            } }
        }
        if ($Uri -match '/budgets/synthetic-dev-environment\?') {
            return @{ StatusCode = 200; Headers = @{}; Body = @{
                id = $budgetId; eTag = $budgetState.etag
                properties = @{ amount = 10; category = 'Cost'; timePeriod = @{ startDate = '2026-09-01T00:00:00Z' } }
            } }
        }
        return @{ StatusCode = 404; Headers = @{}; Body = @{ error = @{ code = 'ResourceNotFound' } } }
    }.GetNewClosure()
    $firstOwned = Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $owned -AllowSynthetic
    $sameOwned = Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $owned -AllowSynthetic
    Assert-True ($firstOwned.parameters.parameters.budgetEtag.value -ceq 'budget-version-1' -and $firstOwned.planHash -ceq $sameOwned.planHash) 'An unchanged owned budget did not produce stable parameters/state.'
    $budgetState.etag = 'budget-version-2'
    $changedOwned = Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency USD -Request $owned -AllowSynthetic
    Assert-True ($changedOwned.planHash -cne $firstOwned.planHash) 'A changed budget eTag did not invalidate approval.'

    $desired = Get-GovernanceDesiredState -Profile $profile -BillingCurrency USD -AllowSynthetic
    Assert-True ($desired.scope -ceq $scope -and $desired.parameters.parameters.configuration.value.policyEffect -ceq 'Audit') 'Desired-state conversion changed the frozen profile or scope.'
    Assert-True (@($desired.resources | Where-Object kind -eq definition).Count -eq 3 -and
        @($desired.resources | Where-Object kind -eq budget).Count -eq 1) 'The executable governance contract was not fully rendered.'
    Assert-True ((($desired.resources.resourceId | Sort-Object) -join "`n") -ceq (($plan.resources.resourceId | Sort-Object) -join "`n")) 'Planning and Bicep disagree about owned resource IDs.'
    function Copy-JsonValue {
        param($Value)
        if ($Value -is [Collections.IDictionary]) {
            $copy = @{}
            foreach ($key in $Value.Keys) { $copy[$key] = Copy-JsonValue $Value[$key] }
            return $copy
        }
        if ($Value -is [Collections.IList]) { return ,@($Value | ForEach-Object { Copy-JsonValue $_ }) }
        return $Value
    }
    function New-LiveGovernance {
        $values = @{}
        foreach ($resource in $desired.resources) {
            $values[$resource.resourceId] = @{ id = $resource.resourceId; properties = Copy-JsonValue $resource.properties }
            if ($resource.kind -eq 'assignment') { $values[$resource.resourceId].properties.scope = $scope }
            if ($resource.kind -eq 'budget') {
                $values[$resource.resourceId].eTag = 'observed-budget-etag'
                $values[$resource.resourceId].properties.currentSpend = @{ amount = 0; unit = 'USD' }
            }
        }
        $values[$scope] = @{ id = $scope; location = $profile.azure.location }
        $values[$contactGroup] = @{ id = $contactGroup; properties = @{ enabled = $true } }
        foreach ($builtin in $desired.requiredBuiltins.Values) {
            $id = "$($builtin.id)/versions/$($builtin.version)"
            $parameterSchema = @{}
            foreach ($assignment in @($desired.resources | Where-Object { $_.kind -ceq 'assignment' -and $_.properties.policyDefinitionId -ieq $builtin.id })) {
                foreach ($key in $assignment.properties.parameters.Keys) {
                    $value = $assignment.properties.parameters[$key].value
                    $parameterSchema[$key] = @{ type = $(if ($value -is [Collections.IList]) { 'Array' } elseif ($value -is [bool]) { 'Boolean' } else { 'String' }) }
                    if ($key -ceq 'effect') { $parameterSchema[$key].allowedValues = @('Audit', 'Deny', 'Disabled') }
                }
            }
            $ruleField = if ($builtin.id -ceq $desired.requiredBuiltins.diagnostics.id) { 'Microsoft.Insights/diagnosticSettings/logs.enabled' } else { 'type' }
            $values[$id] = @{ id = $id; properties = @{
                policyType = 'BuiltIn'; version = $builtin.version; parameters = $parameterSchema
                policyRule = @{ if = @{ field = $ruleField; equals = 'synthetic' }; then = @{ effect = 'Audit' } }
            } }
        }
        $providerAliases = @{
            'Microsoft.CognitiveServices' = @(
                'Microsoft.CognitiveServices/accounts/deployments/model.format'
                'Microsoft.CognitiveServices/accounts/deployments/model.name'
                'Microsoft.CognitiveServices/accounts/deployments/model.version'
                'Microsoft.CognitiveServices/accounts/deployments/sku.name'
                'Microsoft.CognitiveServices/accounts/publicNetworkAccess'
            )
            'Microsoft.Search' = @('Microsoft.Search/searchServices/publicNetworkAccess')
            'Microsoft.Insights' = @('Microsoft.Insights/diagnosticSettings/logs.enabled')
        }
        foreach ($namespace in $providerAliases.Keys) {
            $id = "/subscriptions/$($profile.azure.subscriptionId)/providers/$namespace"
            $values[$id] = @{ id = $id; namespace = $namespace; resourceTypes = @(@{
                resourceType = 'synthetic-alias-catalog'
                aliases = @($providerAliases[$namespace] | ForEach-Object { @{ name = $_ } })
            }) }
        }
        return @{ values = $values; calls = [Collections.Generic.List[object]]::new(); failCode = 0; exemptions = @() }
    }
    $live = New-LiveGovernance
    $liveRead = {
        param($Method, $Uri, $Body, $Headers)
        if ($Method -cne 'GET' -or $null -ne $Body) { throw 'Readiness attempted a write.' }
        $path = ([uri]$Uri).AbsolutePath
        $live.calls.Add(@{ method = $Method; path = $path })
        if ($path -match '/providers/Microsoft\.(CognitiveServices|Search|Insights)$' -and $Uri -notlike '*$expand=resourceTypes/aliases*') {
            throw 'Alias discovery omitted the documented expansion.'
        }
        if ($live.failCode) { return @{ StatusCode = $live.failCode; Body = @{}; Headers = @{} } }
        if ($path -ceq "$scope/providers/Microsoft.Authorization/policyAssignments") {
            return @{ StatusCode = 200; Body = @{ value = @($live.values.Values | Where-Object { $_.id -like "$scope/providers/Microsoft.Authorization/policyAssignments/*" }) }; Headers = @{} }
        }
        if ($path -ceq "$scope/providers/Microsoft.Authorization/policyExemptions") {
            return @{ StatusCode = 200; Body = @{ value = $live.exemptions }; Headers = @{} }
        }
        if (-not $live.values.Contains($path)) { return @{ StatusCode = 404; Headers = @{}; Body = @{ error = @{ code = 'ResourceNotFound' } } } }
        return @{ StatusCode = 200; Headers = @{}; Body = $live.values[$path] }
    }.GetNewClosure()
    $clock = [datetimeoffset]'2026-09-16T12:00:00Z'
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $request -AllowSynthetic -AtTime $clock } '*not ready*'
    $ready = Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock
    Assert-True ($ready.readyForWorkloadDeployment -and $ready.controlPlaneVerified -and $ready.policyEffect -ceq 'Audit') 'Observed installed controls did not produce scoped control-plane readiness.'
    Assert-True ($ready.scope -ceq $scope -and $ready.budgetResourceId -ceq $budgetId -and -not $ready.liveEnforcementVerified) 'Configuration verification was widened into enforcement or another scope.'
    Assert-True ($ready.mode -ceq 'offline-test') 'Synthetic observation was mislabeled as live evidence.'
    Assert-True ($live.calls.Count -gt $desired.resources.Count -and @($live.calls | Where-Object method -ne GET).Count -eq 0) 'Readiness did not read actual RG, built-ins, assignments, budget and notification dependencies.'
    Assert-True ($ready.providerAliasesVerified -and $ready.builtinParametersVerified) 'Readiness did not establish provider aliases and built-in parameter compatibility.'
    $networkId = "$scope/providers/Microsoft.Authorization/policyAssignments/synthetic-dev-network"
    $modelId = "/subscriptions/$($profile.azure.subscriptionId)/providers/Microsoft.Authorization/policyDefinitions/synthetic-dev-models"
    $liveFailures = @(
        { param($s) $s.values.Remove($budgetId) },
        { param($s) $s.values.Remove($networkId) },
        { param($s) $s.values[$networkId].properties.parameters.effect.value = 'Disabled' },
        { param($s) $s.values[$networkId].properties.notScopes = @($scope) },
        { param($s) $s.values[$networkId].properties.scope = "/subscriptions/$($profile.azure.subscriptionId)" },
        { param($s) $s.values[$networkId].properties.metadata['ailz-owner'] = 'unrelated' },
        { param($s) $s.values[$networkId].properties.resourceSelectors = @(@{ name = 'exclude-workload'; selectors = @() }) },
        { param($s) $s.values[$modelId].properties.policyRule.then.effect = 'Disabled' },
        { param($s) $s.values[$budgetId].properties.amount = 999 },
        { param($s) $s.values[$budgetId].properties.filter = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @('inference-only') } } },
        { param($s) $s.values[$budgetId].properties.notifications.forecast.enabled = $false },
        { param($s) $s.values[$budgetId].properties.notifications.actual.contactEmails = @('unapproved@example.invalid') },
        { param($s) $s.values[$budgetId].properties.currentSpend.unit = 'EUR' },
        { param($s) $s.values[$contactGroup].properties.enabled = $false },
        { param($s) $s.values.Remove("$($desired.requiredBuiltins.locations.id)/versions/$($desired.requiredBuiltins.locations.version)") }
    )
    foreach ($change in $liveFailures) {
        $reset = New-LiveGovernance
        $live.values = $reset.values
        & $change $live
        Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*not ready*'
    }
    $live.values = (New-LiveGovernance).values
    $cognitiveProvider = "/subscriptions/$($profile.azure.subscriptionId)/providers/Microsoft.CognitiveServices"
    $live.values[$cognitiveProvider].resourceTypes[0].aliases = @(@{ name = 'Microsoft.CognitiveServices/accounts/publicNetworkAccess' })
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*alias*'
    $live.values = (New-LiveGovernance).values
    $networkBuiltinId = "$($desired.requiredBuiltins.network.id)/versions/$($desired.requiredBuiltins.network.version)"
    $live.values[$networkBuiltinId].properties.parameters.Remove('effect')
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*parameter*'
    $live.values = (New-LiveGovernance).values
    $live.values[$networkBuiltinId].properties.parameters.effect.allowedValues = @('Deny')
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*parameter*'
    $live.values = (New-LiveGovernance).values
    $live.exemptions = @(@{ properties = @{ policyAssignmentId = $networkId; exemptionCategory = 'Waiver' } })
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*exemption*'
    $live.exemptions[0].properties.expiresOn = '2026-09-01T00:00:00Z'
    Assert-True ((Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock).controlPlaneVerified) 'An expired exemption was treated as active.'
    $live.exemptions = @()
    $live.failCode = 403
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*403*'
    $live.failCode = 0
    Assert-Throws { Assert-GovernanceReadiness -Profile $profile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime ([datetimeoffset]'2026-10-02T00:00:00Z') } '*not ready*'
    $disabledProfile = New-Profile
    $disabledProfile.governance.policyEffect = 'Disabled'
    Assert-Throws { Assert-GovernanceReadiness -Profile $disabledProfile -BillingCurrency USD -Request $liveRead -AllowSynthetic -AtTime $clock } '*Disabled*'
    Assert-Throws { Assert-GovernanceDeploymentReadiness -Profile $profile -BillingCurrency USD -Request $request -AllowSynthetic } '*not ready*'
    $originalDesired = $desired
    $currentProfile = Copy-JsonValue $profile
    $currentMonth = [datetimeoffset]::UtcNow
    $currentProfile.governance.budget.startDate = $currentMonth.ToString('yyyy-MM-01')
    $currentProfile.governance.budget.endDate = $currentMonth.AddMonths(1).ToString('yyyy-MM-01')
    $currentProfile.governance.budget.contactEmails += 'second-owner@example.invalid'
    $desired = Get-GovernanceDesiredState -Profile $currentProfile -BillingCurrency USD -AllowSynthetic
    $live.values = (New-LiveGovernance).values
    foreach ($notice in $live.values[$budgetId].properties.notifications.Values) {
        [array]::Reverse($notice.contactEmails)
    }
    $booleanResult = @(Assert-GovernanceDeploymentReadiness -Profile $currentProfile -BillingCurrency USD -Request $liveRead -AllowSynthetic)
    Assert-True ($booleanResult.Count -eq 1 -and $booleanResult[0] -is [bool] -and $booleanResult[0]) 'The P2 readiness API must return exactly Boolean true and treat recipients as sets.'
    $live.values[$budgetId].properties.Remove('currentSpend')
    Assert-Throws { Assert-GovernanceDeploymentReadiness -Profile $currentProfile -BillingCurrency USD -Request $liveRead -AllowSynthetic } '*currency*'
    $desired = $originalDesired

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $scratch 'governance.template.json'
        & bicep build (Join-Path $root 'platform\governance.bicep') --outfile $TemplatePath
        if ($LASTEXITCODE -ne 0) { throw 'Governance Bicep compilation failed.' }
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($template.'$schema' -match 'subscriptionDeploymentTemplate') 'Definitions require a separate subscription deployment boundary.'
    Assert-True ($template.parameters.enabled.defaultValue -eq $false) 'Governance must default off.'
    $definitionDeployment = @($template.resources | Where-Object { $_.name -match '-definitions' })[0]
    if ($null -eq $definitionDeployment) { $definitionDeployment = @($template.resources | Where-Object { $_.properties.template.parameters.Contains('assessmentApproved') })[0] }
    foreach ($guard in @('assessmentApproved', 'billingCurrencyConfirmed', 'scopeConfirmed')) {
        Assert-True ($definitionDeployment.properties.template.parameters[$guard].allowedValues.Count -eq 1 -and $definitionDeployment.properties.template.parameters[$guard].allowedValues[0] -eq $true) 'An ARM approval/scope guard does not fail closed.'
    }
    $definitionJson = $definitionDeployment.properties.template | ConvertTo-Json -Depth 100
    Assert-True ($definitionJson.Contains("[[parameters('allowedModels')]") -and $definitionJson.Contains("[[parameters('effect')]")) 'Policy expressions were interpreted as deployment-template expressions.'
    $governanceSource = Get-Content -LiteralPath (Join-Path $root 'platform\governance.bicep') -Raw
    Assert-True ($governanceSource -match "enabled\s*\?\s*configuration\.assignmentPrefix\s*:" -and $governanceSource -match 'definitionIds:\s*enabled\s*\?') 'The disabled path must not eagerly evaluate absent configuration or conditional module outputs.'
    $definitions = Get-Content -LiteralPath (Join-Path $root 'platform\policy\definitions.bicep') -Raw
    Assert-True ($definitions -match '@allowed\(\[\s*true\s*\]\)') 'Deny assessment must have an ARM parameter guard, not just a status output.'
    $assignments = Get-Content -LiteralPath (Join-Path $root 'platform\policy\assignments.bicep') -Raw
    Assert-True ($assignments -match "targetScope\s*=\s*'resourceGroup'") 'Assignments and budget need the exact RG deployment scope.'
    Assert-True ($assignments -match 'budgetProperties\(configuration\.budget\)') 'The deployed budget differs from the tested generated properties.'
    Assert-True ($assignments -notmatch 'allowedPublishers.*OpenAI|policyExemptions|remediations') 'Publisher-wide allowance or unrelated estate mutation.'
    $contractSource = Get-Content -LiteralPath (Join-Path $root 'platform\policy\contracts.bicep') -Raw
    Assert-True ($assignments -match 'baselineAssignmentContracts' -and $contractSource -match 'DoNotEnforce' -and $contractSource -match 'notScopes') 'Deployment and readiness must share the non-disruptive Audit/Disabled assignment contracts.'
    $sources = Get-Content -LiteralPath (Join-Path $root 'platform\policy\builtins.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($sources.sourceCommit -ceq '7b0fa25ac055d8c3001d5205cd009cd119a289a5') 'Policy source revision drifted without verification.'
    foreach ($builtin in $sources.definitions.Values) {
        Assert-True ($builtin.id -match '^/providers/Microsoft.Authorization/policyDefinitions/[0-9a-f-]{36}$') 'Invalid built-in definition ID.'
        Assert-True ($builtin.source -match 'https://raw.githubusercontent.com/Azure/azure-policy/') 'Missing primary policy source.'
        Assert-True ($builtin.version -notmatch 'deprecated|preview') 'Deprecated/eligibility-preview policy must not be required by this baseline.'
    }
    Write-Host "Governance: $script:assertions assertions passed. Policy availability, billing currency and notification delivery still require approved live evidence."
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Get-ChildItem -LiteralPath $scratch -File | Remove-Item
        Remove-Item -LiteralPath $scratch
    }
}
