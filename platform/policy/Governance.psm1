#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\github\Environment.psm1') -Scope Local

function New-GovernanceDeploymentParameters {
    <#
    .SYNOPSIS
    Compose exact platform parameters using the frozen shared P1 validator.
    .DESCRIPTION
    BillingCurrency is observed billing evidence, not a requested conversion.
    AllowSynthetic is offline-test-only; it is never deployment authorization.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{3}$')][string]$BillingCurrency,
        [switch]$AllowSynthetic
    )
    $resolved = Resolve-EnvironmentProfile -Profile $Profile -AllowSynthetic:$AllowSynthetic
    $configuration = $resolved.profile.governance
    if ($configuration.assignmentPrefix.Length -gt 40) { throw 'governance.assignmentPrefix exceeds the P3 ownership-prefix contract (40 characters).' }
    if ($configuration.budget.currency -cne $BillingCurrency -or $configuration.inferenceAllowance.currency -cne $BillingCurrency) {
        throw 'Governance currency does not match the observed workload billing currency; conversion is not supported.'
    }
    $start = [datetime]::ParseExact($configuration.budget.startDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if ($start.Day -ne 1) { throw 'governance.budget.startDate must be the first day of a month.' }
    if ($configuration.budget.actualThreshold -gt 1000 -or $configuration.budget.forecastThreshold -gt 1000) {
        throw 'Governance budget thresholds exceed the Consumption API percentage range.'
    }
    return [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            enabled = @{ value = $true }
            resourceGroupName = @{ value = $resolved.profile.azure.resourceGroup }
            expectedSubscriptionId = @{ value = $resolved.profile.azure.subscriptionId }
            expectedTenantId = @{ value = $resolved.profile.azure.tenantId }
            configuration = @{ value = $configuration }
            billingCurrency = @{ value = $BillingCurrency }
            budgetEtag = @{ value = '' }
        }
    }
}

function Invoke-GovernanceRead {
    param([scriptblock]$Request, [string]$ResourceId, [string]$ApiVersion, [string]$Query = '')
    $uri = "https://management.azure.com${ResourceId}?api-version=$ApiVersion"
    if ($Query) { $uri += "&$Query" }
    $response = & $Request GET $uri $null @{}
    if ($response -isnot [Collections.IDictionary] -or -not $response.Contains('StatusCode') -or -not $response.Contains('Body') -or
        -not $response.Contains('Headers') -or $response.Body -isnot [Collections.IDictionary]) {
        throw 'Governance ARM transport must return StatusCode, Body and Headers without logging credentials or response bodies.'
    }
    if ($response.StatusCode -eq 404 -and $response.Body.Contains('error') -and $response.Body.error -is [Collections.IDictionary] -and
        $response.Body.error['code'] -in @('ResourceNotFound', 'PolicyAssignmentNotFound', 'PolicyDefinitionNotFound', 'NotFound')) { return $null }
    if ($response.StatusCode -ne 200) { throw "Governance scoped read failed (HTTP $($response.StatusCode))." }
    return $response.Body
}

function Get-GovernanceDeploymentPlan {
    <#
    .SYNOPSIS
    Read-before-write ownership and budget-eTag plan. This function only GETs.
    .DESCRIPTION
    The parent freezes the returned resource hashes and parameters with preview,
    then obtains the same plan again under its environment mutation lease before
    executing Bicep. Definitions live at subscription scope; assignments/budget
    are exactly RG-scoped. Unrelated resources are never adopted.

    Budgets cannot store an ownership tag. Owned policy-assignment metadata
    explicitly references the budget ID; the template creates that anchor first.
    A preexisting budget without that anchor is an ownership conflict.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{3}$')][string]$BillingCurrency,
        [Parameter(Mandatory)][scriptblock]$Request,
        [switch]$AllowSynthetic
    )
    $parameters = New-GovernanceDeploymentParameters -Profile $Profile -BillingCurrency $BillingCurrency -AllowSynthetic:$AllowSynthetic
    $configuration = $parameters.parameters.configuration.value
    $prefix = $configuration.assignmentPrefix
    $subscriptionScope = "/subscriptions/$($Profile.azure.subscriptionId)"
    $scope = "$subscriptionScope/resourceGroups/$($Profile.azure.resourceGroup)"
    $owner = "ailz-governance:$($scope.ToLowerInvariant()):$prefix"
    $budgetId = "$scope/providers/Microsoft.Consumption/budgets/$prefix-environment"
    $resources = [Collections.Generic.List[object]]::new()
    foreach ($suffix in @('models', 'skus', 'private')) {
        $resources.Add(@{ kind = 'definition'; resourceId = "$subscriptionScope/providers/Microsoft.Authorization/policyDefinitions/$prefix-$suffix"; apiVersion = '2023-04-01' })
    }
    $assignmentSuffixes = @('network', 'local-auth', 'locations', 'private-link', 'diagnostics', 'models', 'skus', 'private')
    for ($i = 0; $i -lt $configuration.requiredTags.Count; $i++) { $assignmentSuffixes += "tag-$i" }
    foreach ($suffix in $assignmentSuffixes) {
        $resources.Add(@{ kind = 'assignment'; resourceId = "$scope/providers/Microsoft.Authorization/policyAssignments/$prefix-$suffix"; apiVersion = '2024-04-01' })
    }
    $budgetAnchorFound = $false
    foreach ($resource in $resources) {
        $existing = Invoke-GovernanceRead $Request $resource.resourceId $resource.apiVersion
        if ($null -ne $existing) {
            if ($existing['id'] -ine $resource.resourceId -or -not $existing.Contains('properties') -or -not $existing.properties.Contains('metadata') -or
                $existing.properties.metadata['ailz-owner'] -cne $owner) { throw 'Governance resource ownership conflict; existing policies must not be adopted or replaced.' }
            if ($resource.kind -eq 'assignment' -and $existing.properties.metadata.budgetResourceId -ieq $budgetId) { $budgetAnchorFound = $true }
        }
        $resource.observedStateHash = Get-CanonicalHash $existing
        $resource.exists = ($null -ne $existing)
    }
    $inventory = Invoke-GovernanceRead $Request "$scope/providers/Microsoft.Authorization/policyAssignments" '2024-04-01'
    if ($null -ne $inventory) {
        if (-not $inventory.Contains('value') -or $inventory.value -isnot [Collections.IList] -or ($inventory.Contains('nextLink') -and $inventory.nextLink)) {
            throw 'Governance assignment inventory is incomplete; no reconciliation can proceed.'
        }
        $expectedIds = @($resources | Where-Object kind -eq 'assignment' | Select-Object -ExpandProperty resourceId)
        foreach ($assignment in ($inventory.value | Sort-Object id)) {
            if (-not $assignment.properties.Contains('metadata') -or $assignment.properties.metadata['ailz-owner'] -cne $owner -or $assignment.id -iin $expectedIds) { continue }
            $excluded = $assignment.properties.Contains('notScopes') -and @($assignment.properties.notScopes) -icontains $scope
            $effectDisabled = $assignment.properties.Contains('parameters') -and $assignment.properties.parameters.Contains('effect') -and $assignment.properties.parameters.effect.value -ceq 'Disabled'
            if (-not $excluded -and -not $effectDisabled) {
                throw 'An active owned assignment was removed from configuration. First disable it with its prior owned configuration and approved preview; no automatic deletion is allowed.'
            }
            $resources.Add(@{ kind = 'preservedDisabledAssignment'; resourceId = $assignment.id; exists = $true; observedStateHash = Get-CanonicalHash $assignment })
        }
    }
    $existingBudget = Invoke-GovernanceRead $Request $budgetId '2024-08-01'
    if ($null -ne $existingBudget) {
        if (-not $budgetAnchorFound -or $existingBudget['id'] -ine $budgetId) { throw 'Governance budget ownership conflict: no matching owned budget and policy-assignment anchor exists.' }
        if (-not $existingBudget.Contains('eTag') -or [string]::IsNullOrWhiteSpace($existingBudget.eTag)) { throw 'Existing governance budget has no concurrency eTag.' }
        $parameters.parameters.budgetEtag.value = $existingBudget.eTag
    }
    $resources.Add(@{
        kind = 'budget'
        resourceId = $budgetId
        apiVersion = '2024-08-01'
        exists = ($null -ne $existingBudget)
        observedStateHash = Get-CanonicalHash $existingBudget
    })
    $sources = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'builtins.json') -Raw | ConvertFrom-Json -AsHashtable
    return [ordered]@{
        schemaVersion = 1
        scope = $scope
        owner = $owner
        parameters = $parameters
        resources = $resources.ToArray()
        requiredBuiltins = $sources.definitions
        sourceCommit = $sources.sourceCommit
        planHash = Get-CanonicalHash @{ parameters = $parameters; resources = $resources.ToArray() }
        remainingLiveEvidence = @('Built-in versions/parameters and aliases available in target subscription', 'Observed workload billing currency', 'Policy assessment and effective assignments', 'Actual/forecast email and action-group delivery')
    }
}

function ConvertFrom-GovernanceJsonElement {
    param([System.Text.Json.JsonElement]$Element, [int]$Depth = 0)
    if ($Depth -gt 90) { throw 'Governance JSON exceeds the supported nesting depth.' }
    switch ($Element.ValueKind.ToString()) {
        Object {
            $value = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($value.Contains($property.Name)) { throw 'Governance JSON has duplicate properties.' }
                $value[$property.Name] = ConvertFrom-GovernanceJsonElement $property.Value ($Depth + 1)
            }
            return $value
        }
        Array { return ,@($Element.EnumerateArray() | ForEach-Object { ConvertFrom-GovernanceJsonElement $_ ($Depth + 1) }) }
        String { return $Element.GetString() }
        Number {
            [long]$integer = 0
            [decimal]$number = 0
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            if ($Element.TryGetDecimal([ref]$number)) { return $number }
            throw 'Governance JSON contains a number outside the supported exact decimal range.'
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { throw 'Governance JSON contains an unsupported value.' }
    }
}

function Invoke-GovernanceContractCompiler {
    param([string]$InputPath, [string]$OutputPath)
    $executable = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $executable) { throw 'Governance desired-state rendering requires the approved Bicep compiler on PATH.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable.Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('build-params', $InputPath, '--outfile', $OutputPath)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Governance contract compiler did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Governance contract compilation exceeded its 120-second local execution bound.'
        }
        $null = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Governance contract compilation failed; no profile values or compiler output are logged.' }
    }
    finally { $process.Dispose() }
}

function Get-GovernanceDesiredState {
    <#
    .SYNOPSIS
    Render the same local Bicep functions consumed by the governance deployment.
    .DESCRIPTION
    No Azure calls. The approved local Bicep compiler is bounded to 120 seconds;
    this does not use the shared unbounded native wrapper. Generated artifacts
    are nonsecret, temporary and cleaned. This output is desired state, not proof
    that any policy or budget exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{3}$')][string]$BillingCurrency,
        [switch]$AllowSynthetic
    )
    $parameters = New-GovernanceDeploymentParameters -Profile $Profile -BillingCurrency $BillingCurrency -AllowSynthetic:$AllowSynthetic
    $scope = "/subscriptions/$($Profile.azure.subscriptionId)/resourceGroups/$($Profile.azure.resourceGroup)"
    $configuration = $parameters.parameters.configuration.value
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('ailz-governance-contract-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $configurationPath = Join-Path $scratch 'configuration.json'
    $inputPath = Join-Path $scratch 'contract.bicepparam'
    $outputPath = Join-Path $scratch 'contract.parameters.json'
    try {
        Write-JsonFile $configurationPath $configuration
        $contract = [IO.Path]::GetRelativePath($scratch, (Join-Path $PSScriptRoot 'contracts.bicep')).Replace('\', '/').Replace("'", "\'")
        $inputText = @"
using none
import { governanceResourceContracts } from '$contract'
param resources = governanceResourceContracts('$scope', loadJsonContent('./configuration.json'))
"@
        [IO.File]::WriteAllText($inputPath, $inputText, [Text.UTF8Encoding]::new($false))
        Invoke-GovernanceContractCompiler $inputPath $outputPath
        $document = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($outputPath))
        try { $rendered = ConvertFrom-GovernanceJsonElement $document.RootElement }
        finally { $document.Dispose() }
        $sources = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'builtins.json') -Raw | ConvertFrom-Json -AsHashtable
        return [ordered]@{
            schemaVersion = 1
            scope = $scope
            owner = "ailz-governance:$($scope.ToLowerInvariant()):$($configuration.assignmentPrefix)"
            parameters = $parameters
            resources = $rendered.parameters.resources.value
            requiredBuiltins = $sources.definitions
            sourceCommit = $sources.sourceCommit
            desiredStateHash = Get-CanonicalHash @{ parameters = $parameters; resources = $rendered.parameters.resources.value }
            readyForWorkloadDeployment = $false
        }
    }
    finally {
        foreach ($path in @($configurationPath, $inputPath, $outputPath)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
        [IO.Directory]::Delete($scratch)
    }
}

function Assert-GovernanceProperties {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [string]$Path)
    if ($Expected -is [Collections.IDictionary]) {
        if ($Actual -isnot [Collections.IDictionary]) { throw "Governance not ready: missing or invalid $Path." }
        if ($Path -match '\.(parameters|notifications|policyRule)$') {
            if ((Get-CanonicalHash @($Actual.Keys | Sort-Object)) -cne (Get-CanonicalHash @($Expected.Keys | Sort-Object))) {
                throw "Governance not ready: unexpected properties in $Path."
            }
        }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.Contains($key)) { throw "Governance not ready: missing $Path.$key." }
            Assert-GovernanceProperties $Actual[$key] $Expected[$key] "$Path.$key"
        }
        return
    }
    if ($Path -match '^budget\.notifications\.[^.]+\.(contactEmails|contactGroups|contactRoles)$') {
        if ($Actual -isnot [Collections.IList] -or $Expected -isnot [Collections.IList]) { throw "Governance not ready: invalid recipient set at $Path." }
        $comparer = if ($Path.EndsWith('.contactGroups', [StringComparison]::Ordinal)) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
        $actualSet = [Collections.Generic.HashSet[string]]::new($comparer)
        $expectedSet = [Collections.Generic.HashSet[string]]::new($comparer)
        foreach ($recipient in $Actual) {
            if ($recipient -isnot [string]) { throw "Governance not ready: invalid recipient at $Path." }
            $null = $actualSet.Add($recipient)
        }
        foreach ($recipient in $Expected) { $null = $expectedSet.Add($recipient) }
        if (-not $actualSet.SetEquals($expectedSet)) { throw "Governance not ready: recipient set differs at $Path." }
        return
    }
    if ($Path -match '\.timePeriod\.(startDate|endDate)$') {
        [datetimeoffset]$actualDate = [datetimeoffset]::MinValue
        [datetimeoffset]$expectedDate = [datetimeoffset]::MinValue
        if ($Actual -isnot [string] -or
            -not [datetimeoffset]::TryParse($Actual, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$actualDate) -or
            -not [datetimeoffset]::TryParse($Expected, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$expectedDate) -or
            $actualDate -ne $expectedDate) { throw "Governance not ready: budget date differs at $Path." }
        return
    }
    if ($Expected -is [string] -and $Expected.StartsWith('/subscriptions/', [StringComparison]::OrdinalIgnoreCase) -or
        $Expected -is [string] -and $Expected.StartsWith('/providers/', [StringComparison]::OrdinalIgnoreCase)) {
        if ($Actual -isnot [string] -or $Actual -ine $Expected) { throw "Governance not ready: scope/resource reference differs at $Path." }
        return
    }
    if ((Get-CanonicalHash $Actual) -cne (Get-CanonicalHash $Expected)) { throw "Governance not ready: observed value differs at $Path." }
}

function Assert-GovernanceBuiltinParameters {
    param([Collections.IDictionary]$Definition, [object[]]$Assignments)
    $id = $Definition.id
    if (-not $Definition.properties.Contains('parameters') -or $Definition.properties.parameters -isnot [Collections.IDictionary]) {
        throw "Governance not ready: dependency - built-in parameter schemas are unavailable for $id."
    }
    $schemas = $Definition.properties.parameters
    $requiredNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($assignment in $Assignments) {
        foreach ($name in $assignment.properties.parameters.Keys) {
            $null = $requiredNames.Add($name)
            if (-not $schemas.Contains($name) -or $schemas[$name] -isnot [Collections.IDictionary] -or
                -not $schemas[$name].Contains('type')) { throw "Governance not ready: dependency - missing built-in parameter schema $name in $id." }
            $schema = $schemas[$name]
            $value = $assignment.properties.parameters[$name].value
            $validType = switch ([string]$schema.type) {
                'String' { $value -is [string] }
                'Boolean' { $value -is [bool] }
                'Array' { $value -is [Collections.IList] }
                'Integer' { $value -is [int] -or $value -is [long] }
                'Float' { $value -is [int] -or $value -is [long] -or $value -is [decimal] -or $value -is [double] }
                'Object' { $value -is [Collections.IDictionary] -and -not $schema.Contains('schema') }
                default { $false }
            }
            if (-not $validType) { throw "Governance not ready: dependency - unsupported or mismatched built-in parameter type for $name in $id." }
            if ($schema.Contains('allowedValues')) {
                if ($schema.allowedValues -isnot [Collections.IList]) { throw "Governance not ready: invalid built-in parameter allowedValues for $name." }
                $allowedHashes = @($schema.allowedValues | ForEach-Object { Get-CanonicalHash $_ })
                $values = if ($value -is [Collections.IList]) { $value } else { ,$value }
                foreach ($entry in $values) {
                    if ((Get-CanonicalHash $entry) -cnotin $allowedHashes) { throw "Governance not ready: built-in parameter $name is not allowed by pinned definition $id." }
                }
            }
        }
    }
    if (-not $requiredNames.SetEquals([string[]]@($schemas.Keys))) {
        throw "Governance not ready: dependency - built-in parameter names differ from the explicitly bound baseline in $id."
    }
}

function Add-GovernancePolicyAliases {
    param([AllowNull()][object]$Value, [Collections.Generic.HashSet[string]]$Aliases)
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains('field') -and $Value.field -is [string] -and $Value.field -match '^Microsoft\.[A-Za-z0-9.]+/') {
            $null = $Aliases.Add($Value.field)
        }
        foreach ($item in $Value.Values) { Add-GovernancePolicyAliases $item $Aliases }
    }
    elseif ($Value -is [Collections.IList]) {
        foreach ($item in $Value) { Add-GovernancePolicyAliases $item $Aliases }
    }
}

function Assert-GovernanceProviderAliases {
    param([string]$SubscriptionId, [Collections.Generic.HashSet[string]]$Aliases, [scriptblock]$Request)
    $namespaces = @($Aliases | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    foreach ($namespace in $namespaces) {
        $provider = Invoke-GovernanceRead $Request "/subscriptions/$SubscriptionId/providers/$namespace" '2021-04-01' '$expand=resourceTypes/aliases'
        if ($null -eq $provider -or $provider['namespace'] -ine $namespace -or -not $provider.Contains('resourceTypes') -or $provider.resourceTypes -isnot [Collections.IList]) {
            throw "Governance not ready: dependency - expanded provider alias catalog is unavailable for $namespace."
        }
        $available = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($type in $provider.resourceTypes) {
            if ($type.Contains('aliases') -and $type.aliases -is [Collections.IList]) {
                foreach ($alias in $type.aliases) {
                    if ($alias -is [Collections.IDictionary] -and $alias['name'] -is [string]) { $null = $available.Add($alias.name) }
                }
            }
        }
        foreach ($alias in $Aliases) {
            if ($alias.StartsWith("$namespace/", [StringComparison]::OrdinalIgnoreCase) -and -not $available.Contains($alias)) {
                throw "Governance not ready: dependency - required Azure Policy alias is unavailable: $alias."
            }
        }
    }
}

function Assert-GovernanceReadiness {
    <#
    .SYNOPSIS
    Fail unless real GET observations match every owned policy and budget contract.
    .DESCRIPTION
    This is the P5 pre-workload gate and P2 post-governance check. No writes,
    policy scans, notifications or inference are invoked. The transport must
    bound its GETs and preserve JSON scalar types. Reads are a finite inventory;
    paginated/incomplete assignment inventories fail closed.

    Audit is valid installed assessment, not Deny enforcement. Disabled cannot
    pass a governed workload gate. AtTime is only accepted with synthetic offline
    fixtures. Even a matching snapshot does not prove policy propagation,
    inherited-policy compatibility, alert delivery or runtime enforcement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{3}$')][string]$BillingCurrency,
        [Parameter(Mandatory)][scriptblock]$Request,
        [switch]$AllowSynthetic,
        [datetimeoffset]$AtTime = [datetimeoffset]::UtcNow
    )
    if ($PSBoundParameters.ContainsKey('AtTime') -and (-not $AllowSynthetic -or -not $Profile.synthetic)) {
        throw 'Governance readiness clock overrides are restricted to explicit synthetic offline tests.'
    }
    $desired = Get-GovernanceDesiredState -Profile $Profile -BillingCurrency $BillingCurrency -AllowSynthetic:$AllowSynthetic
    $configuration = $desired.parameters.parameters.configuration.value
    if ($configuration.policyEffect -ceq 'Disabled') { throw 'Governance not ready: Disabled policies cannot authorize a governed workload deployment.' }
    $group = Invoke-GovernanceRead $Request $desired.scope '2025-04-01'
    if ($null -eq $group -or $group['id'] -ine $desired.scope) {
        throw 'Governance not ready: the exact workload RG must exist before the separately privileged governance deployment.'
    }
    $aliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($builtin in $desired.requiredBuiltins.Values) {
        $id = "$($builtin.id)/versions/$($builtin.version)"
        $definition = Invoke-GovernanceRead $Request $id '2023-04-01'
        if ($null -eq $definition -or $definition['id'] -ine $id -or -not $definition.Contains('properties') -or
            $definition.properties -isnot [Collections.IDictionary] -or -not $definition.properties.Contains('policyType') -or
            -not $definition.properties.Contains('version') -or $definition.properties.policyType -cne 'BuiltIn' -or $definition.properties.version -cne $builtin.version) {
            throw 'Governance not ready: a pinned built-in definition version is unavailable or mismatched.'
        }
        $bindings = @($desired.resources | Where-Object { $_.kind -ceq 'assignment' -and $_.properties.policyDefinitionId -ieq $builtin.id })
        Assert-GovernanceBuiltinParameters $definition $bindings
        if (-not $definition.properties.Contains('policyRule') -or $definition.properties.policyRule -isnot [Collections.IDictionary]) {
            throw "Governance not ready: dependency - pinned built-in policy rule is unavailable for $id."
        }
        Add-GovernancePolicyAliases $definition.properties.policyRule $aliases
    }
    foreach ($resource in $desired.resources) {
        if ($resource.kind -ceq 'definition') { Add-GovernancePolicyAliases $resource.properties.policyRule $aliases }
    }
    Assert-GovernanceProviderAliases $Profile.azure.subscriptionId $aliases $Request
    $observedHashes = @{}
    $budgetId = ''
    foreach ($resource in $desired.resources) {
        $actual = Invoke-GovernanceRead $Request $resource.resourceId $resource.apiVersion
        if ($null -eq $actual -or $actual['id'] -ine $resource.resourceId -or -not $actual.Contains('properties')) {
            throw "Governance not ready: missing or mismatched owned $($resource.kind). Run the privileged governance stage before workload creation."
        }
        Assert-GovernanceProperties $actual.properties $resource.properties $resource.kind
        if ($resource.kind -eq 'definition') {
            if ((Get-CanonicalHash $actual.properties.policyRule) -cne (Get-CanonicalHash $resource.properties.policyRule)) {
                throw 'Governance not ready: the installed custom policy rule is not the approved exact rule.'
            }
        }
        elseif ($resource.kind -eq 'assignment') {
            if ($actual.properties['scope'] -ine $desired.scope) { throw 'Governance not ready: assignment scope is not the exact workload RG.' }
            foreach ($extra in @('overrides', 'resourceSelectors')) {
                if ($actual.properties.Contains($extra) -and $null -ne $actual.properties[$extra] -and @($actual.properties[$extra]).Count -gt 0) {
                    throw "Governance not ready: unapproved assignment $extra can change coverage."
                }
            }
        }
        elseif ($resource.kind -eq 'budget') {
            $budgetId = $resource.resourceId
            if ($actual.properties.Contains('filter') -and $null -ne $actual.properties.filter -and
                ($actual.properties.filter -isnot [Collections.IDictionary] -or $actual.properties.filter.Count -ne 0)) {
                throw 'Governance not ready: the budget is filtered instead of covering the whole workload RG.'
            }
            if (-not $actual.properties.Contains('currentSpend') -or $null -eq $actual.properties.currentSpend -or
                $actual.properties.currentSpend['unit'] -cne $BillingCurrency) {
                throw 'Governance not ready: workload budget billing currency is unavailable or differs from the approved observed currency.'
            }
            $start = [datetimeoffset]::Parse($configuration.budget.startDate + 'T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            $end = [datetimeoffset]::Parse($configuration.budget.endDate + 'T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            if ($AtTime -lt $start -or $AtTime -ge $end) { throw 'Governance not ready: the budget is not active at the observation time.' }
        }
        $observedHashes[$resource.resourceId] = Get-CanonicalHash $actual
    }
    $exemptions = Invoke-GovernanceRead $Request "$($desired.scope)/providers/Microsoft.Authorization/policyExemptions" '2022-07-01-preview'
    if ($null -eq $exemptions -or -not $exemptions.Contains('value') -or $exemptions.value -isnot [Collections.IList] -or
        ($exemptions.Contains('nextLink') -and $exemptions.nextLink)) {
        throw 'Governance not ready: the applicable policy exemption inventory is unavailable or incomplete.'
    }
    $assignmentIds = @($desired.resources | Where-Object kind -eq assignment | ForEach-Object { $_.resourceId })
    foreach ($exemption in $exemptions.value) {
        if (-not $exemption.Contains('properties') -or -not $exemption.properties.Contains('policyAssignmentId')) {
            throw 'Governance not ready: malformed policy exemption observation.'
        }
        if ($assignmentIds -inotcontains $exemption.properties.policyAssignmentId) { continue }
        if ($exemption.properties.Contains('expiresOn') -and $null -ne $exemption.properties.expiresOn) {
            [datetimeoffset]$expires = [datetimeoffset]::MinValue
            if ($exemption.properties.expiresOn -isnot [string] -or
                -not [datetimeoffset]::TryParse($exemption.properties.expiresOn, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$expires)) {
                throw 'Governance not ready: invalid policy exemption expiration.'
            }
            if ($expires -le $AtTime) { continue }
        }
        throw 'Governance not ready: an active exemption reduces coverage of an owned policy assignment.'
    }
    foreach ($id in $configuration.budget.contactGroups) {
        $actionGroup = Invoke-GovernanceRead $Request $id '2023-01-01'
        if ($null -eq $actionGroup -or $actionGroup['id'] -ine $id -or $actionGroup.properties.enabled -ne $true) {
            throw 'Governance not ready: an explicitly configured budget action group is missing or disabled.'
        }
    }
    $plan = Get-GovernanceDeploymentPlan -Profile $Profile -BillingCurrency $BillingCurrency -Request $Request -AllowSynthetic:$AllowSynthetic
    foreach ($resource in $plan.resources) {
        if ($resource.kind -eq 'preservedDisabledAssignment') { continue }
        if (-not $resource.exists -or $resource.observedStateHash -cne $observedHashes[$resource.resourceId]) {
            throw 'Governance not ready: owned resource state changed during verification; re-observe under the environment mutation lease.'
        }
    }
    return [ordered]@{
        schemaVersion = 1
        mode = $(if ($Profile.synthetic) { 'offline-test' } else { 'observed' })
        scope = $desired.scope
        owner = $desired.owner
        readyForWorkloadDeployment = $true
        controlPlaneVerified = $true
        builtinParametersVerified = $true
        providerAliasesVerified = $true
        policyEffect = $configuration.policyEffect
        budgetResourceId = $budgetId
        billingCurrency = $BillingCurrency
        desiredStateHash = $desired.desiredStateHash
        planHash = $plan.planHash
        observedAtUtc = $AtTime.ToUniversalTime().ToString('o')
        observedResources = $plan.resources
        liveEnforcementVerified = $false
        notificationDeliveryVerified = $false
    }
}

function Assert-GovernanceDeploymentReadiness {
    <#
    .SYNOPSIS
    Boolean P2/P5 deployment gate over exact observed governance readiness.
    .DESCRIPTION
    Returns exactly true after the shared verifier passes; every missing,
    mismatched or unverifiable control/dependency throws. Supplied billing
    currency must also match the live budget currentSpend.unit. This does not
    mutate Azure or certify runtime enforcement/notification delivery.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{3}$')][string]$BillingCurrency,
        [Parameter(Mandatory)][scriptblock]$Request,
        [switch]$AllowSynthetic
    )
    $null = Assert-GovernanceReadiness -Profile $Profile -BillingCurrency $BillingCurrency -Request $Request -AllowSynthetic:$AllowSynthetic
    return $true
}

Export-ModuleMember -Function New-GovernanceDeploymentParameters, Get-GovernanceDesiredState, Get-GovernanceDeploymentPlan, Assert-GovernanceReadiness, Assert-GovernanceDeploymentReadiness
