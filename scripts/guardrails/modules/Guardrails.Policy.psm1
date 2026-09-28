#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Plane 1 - Azure Policy: the deployment gate and the SKU/capacity ceilings.

.DESCRIPTION
    Azure Policy does not control spend. It gates deployment SHAPE. A fully
    compliant, approved, private-only Foundry deployment can still burn
    unlimited tokens. Its value here is threefold:

      1. tag enforcement            -> cost attribution and chargeback
      2. SKU and capacity ceilings  -> the half of the guardrail RBAC cannot do
      3. private-only + no local auth -> keeps the APIM gateway authoritative,
                                         which is what makes the gateway a real
                                         spend control rather than a suggestion

    TWO THINGS THIS MODULE DOES THAT ARE EASY TO GET WRONG:

    * It resolves every built-in by GUID and then VERIFIES the display name
      matches what we expect. A GUID that resolves to a different policy than
      you think is a silent, expensive mistake. If the binding does not match,
      this module fails rather than assigning something unknown.

    * It grants the managed identity its role explicitly. Portal-created
      assignments get this automatically; SDK and CLI ones do NOT. Microsoft:
      "When you use an Azure software development kit (SDK), the roles must
      manually be granted." Without it a Modify assignment looks assigned,
      reports compliance, and fixes nothing.
#>

$ErrorActionPreference = 'Stop'

$script:PolicyApiVersion = '2025-11-01'
$script:ContributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

# Set once per run by Invoke-PolicyGuardrails. Module state rather than a
# threaded parameter on purpose: every writer reads it from one place, so a new
# call site cannot silently create an object without it. An unstamped object is
# one that teardown can never safely identify, so the writers fail closed rather
# than create one.
$script:OwnerStamp = ''

function Assert-OwnerStamp {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:OwnerStamp)) {
        throw 'Internal error: the guardrail ownership stamp was not set before a policy object was created. Refusing to create an object that teardown could not identify.'
    }
    return $script:OwnerStamp
}

# GUID hints. Each is verified against its expected display name at runtime
# before it is ever assigned - the hint is a lookup shortcut, never the
# authority. See Resolve-BuiltInPolicy.
$script:BuiltIns = @{
    InheritTagFromResourceGroup = @{
        Guid        = 'ea3f2387-9b95-492a-a190-fcdc54f7b070'
        DisplayName = 'Inherit a tag from the resource group if missing'
        Effect      = 'modify'
        NeedsIdentity = $true
        RequiresSubscriptionScope = $false
    }
    InheritTagFromSubscription = @{
        Guid        = '40df99da-1232-49b1-a39a-6da8d878f469'
        DisplayName = 'Inherit a tag from the subscription if missing'
        Effect      = 'modify'
        NeedsIdentity = $true
        RequiresSubscriptionScope = $false
    }
    ApimBasePolicy = @{
        Guid        = 'd5448c98-e503-4fdd-bcd2-784960c00d04'
        DisplayName = 'API Management policies should inherit parent scope policies using <base />'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        RequiresSubscriptionScope = $false
    }
    AllowedLocationsForResourceGroups = @{
        Guid        = 'e765b5de-1225-4ba3-bd56-1ac6695af988'
        DisplayName = 'Allowed locations for resource groups'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        # Evaluates Microsoft.Resources/subscriptions/resourceGroups, which a
        # resource-group-scoped assignment can never see.
        RequiresSubscriptionScope = $true
    }
    NotAllowedResourceTypes = @{
        Guid        = '6c112d4e-5bc7-47ae-a041-ea2d9dccd749'
        DisplayName = 'Not allowed resource types'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        RequiresSubscriptionScope = $false
    }
    ApprovedFoundryModels = @{
        Guid        = 'aafe3651-cb78-4f68-9f81-e7e41509110f'
        DisplayName = 'Foundry model deployments should only use approved models'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        RequiresSubscriptionScope = $false
    }
    CosmosThroughputLimit = @{
        Guid        = '0b7ef78e-a035-4f23-b9bd-aff122a1b1cf'
        DisplayName = 'Azure Cosmos DB throughput should be limited'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        RequiresSubscriptionScope = $false
    }
    SearchDisablePublicAccess = @{
        Guid        = 'ee980b6d-0eca-4501-8d54-f6290fd512c3'
        DisplayName = 'Azure AI Search services should disable public network access'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        RequiresSubscriptionScope = $false
    }
    StorageAllowedSkus = @{
        Guid        = '7433c107-6db4-4ad1-b57a-a76dce0154a1'
        DisplayName = 'Storage accounts should be limited by allowed SKUs'
        Effect      = 'parameterised'
        NeedsIdentity = $false
        RequiresSubscriptionScope = $false
    }
}

function Resolve-BuiltInPolicy {
    <#
    .SYNOPSIS
        Resolve a built-in policy definition and verify its GUID binds to the
        display name we expect.

    .DESCRIPTION
        Never assign a policy on the strength of a GUID alone. Pasting an
        unverified GUID into a customer environment is the difference between a
        working assignment and a support ticket, and the failure is silent: the
        assignment succeeds and governs something else entirely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Guid,
        [Parameter(Mandatory)][string]$ExpectedDisplayName
    )

    $definition = Invoke-AzCli -AllowNotFound -Arguments @(
        'policy', 'definition', 'show', '--name', $Guid, '-o', 'json'
    )

    if (-not $definition) {
        throw "Built-in policy '$Guid' ('$ExpectedDisplayName') was not found in this tenant. Search by display name in Policy > Definitions and read the GUID off the portal."
    }

    $actual = [string]$definition.displayName
    if ($actual -ne $ExpectedDisplayName) {
        throw @"
POLICY GUID MISMATCH - refusing to assign.
  GUID                  : $Guid
  Expected display name : $ExpectedDisplayName
  Actual display name   : $actual
The GUID resolves to a different policy than this playbook expects. Verify in
Policy > Definitions before changing anything here.
"@
    }

    return [pscustomobject]@{
        Id          = [string]$definition.id
        Name        = [string]$definition.name
        DisplayName = $actual
        Parameters  = $definition.parameters
    }
}

function Get-AssignmentName {
    <#
    .SYNOPSIS
        Deterministic, length-safe assignment name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Key
    )

    $name = ("$Prefix-$Key").ToLowerInvariant() -replace '[^a-z0-9\-]', '-'
    $name = $name -replace '-{2,}', '-'

    # Assignment names are capped at 24 characters when the scope is a
    # management group. Staying inside 24 everywhere keeps one naming scheme.
    if ($name.Length -gt 24) {
        $hash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::HashData(
                [System.Text.Encoding]::UTF8.GetBytes($name))).Replace('-', '').Substring(0, 6).ToLowerInvariant()
        $name = $name.Substring(0, 17).TrimEnd('-') + '-' + $hash
    }

    return $name
}

function Set-CustomPolicyDefinition {
    <#
    .SYNOPSIS
        Create or update a custom policy definition at subscription scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DefinitionPath
    )

    if (-not (Test-Path -LiteralPath $DefinitionPath)) {
        throw "Custom policy definition file not found: '$DefinitionPath'."
    }

    $raw = Get-Content -LiteralPath $DefinitionPath -Raw | ConvertFrom-Json -Depth 40

    # Strip the review comments; ARM rejects unknown top-level members.
    $body = @{ properties = $raw.properties }

    # Stamp ownership without discarding the definition's own metadata, which
    # carries category, version and the source citation each policy documents.
    $stamp = Assert-OwnerStamp
    $metadata = [ordered]@{}
    if ($raw.properties.PSObject.Properties.Name -contains 'metadata' -and $raw.properties.metadata) {
        foreach ($property in $raw.properties.metadata.PSObject.Properties) {
            $metadata[$property.Name] = $property.Value
        }
    }
    $metadata['ailz-owner'] = $stamp
    $body.properties = [ordered]@{}
    foreach ($property in $raw.properties.PSObject.Properties) {
        if ($property.Name -eq 'metadata') { continue }
        $body.properties[$property.Name] = $property.Value
    }
    $body.properties['metadata'] = $metadata

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyDefinitions/$Name" +
           "?api-version=$script:PolicyApiVersion"

    return Invoke-AzRestJson -Method put -Url $url -Body $body
}

function Set-PolicyAssignment {
    <#
    .SYNOPSIS
        Create or update a policy assignment, including its managed identity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$PolicyDefinitionId,
        [Parameter(Mandatory)][ValidateSet('Default', 'DoNotEnforce')][string]$EnforcementMode,
        [hashtable]$Parameters = @{},
        [switch]$WithIdentity,
        [string]$Location,
        [string]$NonComplianceMessage
    )

    $properties = [ordered]@{
        displayName        = $DisplayName
        policyDefinitionId = $PolicyDefinitionId
        enforcementMode    = $EnforcementMode
        # Written on every assignment so removal can enumerate and filter on
        # ownership instead of reconstructing names through Get-AssignmentName's
        # SHA-256 truncation. See Get-GuardrailOwnerStamp.
        metadata           = @{ 'ailz-owner' = (Assert-OwnerStamp) }
    }

    if ($Parameters.Count -gt 0) {
        $wrapped = [ordered]@{}
        foreach ($key in $Parameters.Keys) { $wrapped[$key] = @{ value = $Parameters[$key] } }
        $properties['parameters'] = $wrapped
    }

    if ($NonComplianceMessage) {
        $properties['nonComplianceMessages'] = @(@{ message = $NonComplianceMessage })
    }

    $body = [ordered]@{ properties = $properties }

    if ($WithIdentity) {
        if ([string]::IsNullOrWhiteSpace($Location) -or $Location -ieq 'global') {
            throw "A system-assigned identity requires a top-level location that is not 'global'. Assignment: $Name"
        }
        # Location cannot be changed after creation, so it is pinned to the
        # resource group's region and left alone.
        $body['identity'] = @{ type = 'SystemAssigned' }
        $body['location'] = $Location
    }

    $url = "https://management.azure.com$Scope/providers/Microsoft.Authorization/policyAssignments/$Name" +
           "?api-version=$script:PolicyApiVersion"

    return Invoke-AzRestJson -Method put -Url $url -Body $body
}

function Grant-PolicyIdentityRole {
    <#
    .SYNOPSIS
        Grant a policy assignment's managed identity the role it needs.

    .DESCRIPTION
        THE BICEP / SDK TRAP. Portal-created assignments get their role grants
        automatically. Assignments created by an SDK, the CLI, or Bicep do not.
        The assignment looks correct and remediates nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$RoleDefinitionId,
        [Parameter(Mandatory)][string]$AssignmentName
    )

    $existing = Invoke-AzCli -AllowNotFound -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', $PrincipalId,
        '--scope', $Scope,
        '-o', 'json'
    )

    if ($existing) {
        foreach ($item in @($existing)) {
            if ([string]$item.roleDefinitionId -match "$RoleDefinitionId$") {
                return @{ alreadyGranted = $true; roleAssignmentId = [string]$item.id }
            }
        }
    }

    try {
        $result = Invoke-AzCli -Arguments @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $PrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $RoleDefinitionId,
            '--scope', $Scope,
            '-o', 'json'
        )
        return @{ alreadyGranted = $false; roleAssignmentId = [string]$result.id }
    }
    catch {
        throw "Could not grant role '$RoleDefinitionId' to the managed identity of assignment '$AssignmentName'. This usually means the signed-in principal lacks Microsoft.Authorization/roleAssignments/write (Owner or User Access Administrator). Without this grant the assignment will report compliance and remediate nothing. Underlying error: $($_.Exception.Message)"
    }
}

function Invoke-PolicyGuardrails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$RootPath
    )

    $plane = '1-Policy'
    $subscriptionScope = "/subscriptions/$($Target.SubscriptionId)"
    $assignScope = if ($Config.PolicyScope -eq 'subscription') { $subscriptionScope } else { $Target.ResourceGroupId }
    $prefix = $Config.AssignmentPrefix
    $enforcement = if ($Config.PolicyEffect -eq 'Deny') { 'Default' } else { 'DoNotEnforce' }
    $effectValue = $Config.PolicyEffect

    # Must be set before anything in this plane writes. Every definition and
    # assignment created below carries it, and it is the only thing that lets a
    # later teardown tell this playbook's objects apart from the Bicep-owned
    # ones that share the same prefix at the same scope.
    $script:OwnerStamp = Get-GuardrailOwnerStamp -SubscriptionId $Target.SubscriptionId -Prefix $prefix

    Add-GuardrailResult -Plane $plane -Name 'Ownership stamp' -Status 'Compliant' `
        -Detail "Every definition and assignment this plane creates is tagged metadata['ailz-owner']='$script:OwnerStamp'. Removal filters on this; it never reconstructs names." `
        -Evidence @{ ailzOwner = $script:OwnerStamp } | Out-Null

    # Report the honest status. DoNotEnforce is not a compliant end state - it is
    # a soak phase. Calling it Compliant makes the one line an operator scans to
    # see whether the ceilings are live say "yes" when the answer is "no".
    if ($enforcement -eq 'Default') {
        Add-GuardrailResult -Plane $plane -Name 'Enforcement mode' -Status 'Compliant' `
            -Detail "POLICY_EFFECT=$effectValue -> enforcementMode=Default at $assignScope. Non-compliant deployments are blocked." `
            -Evidence @{ scope = $assignScope; enforcementMode = $enforcement } | Out-Null
    }
    else {
        Add-GuardrailResult -Plane $plane -Name 'Enforcement mode' -Status 'Finding' `
            -Detail "POLICY_EFFECT=$effectValue -> enforcementMode=DoNotEnforce at $assignScope. The ceilings evaluate and report but BLOCK NOTHING. This is a soak phase, not a control." `
            -Remediation 'Deny is the default, so this was overridden. Set POLICY_EFFECT=Deny - or, if you are deliberately soaking a retrofit onto an existing subscription, record the date you will flip. Until then the custom role is unbounded, which is why ROLE_REQUIRE_ENFORCING_CEILINGS refuses to create it at this effect.' `
            -Evidence @{ scope = $assignScope; enforcementMode = $enforcement } | Out-Null
    }

    # ---------------------------------------------------------------- custom
    # Custom definitions first: nothing can assign them until they exist.
    $customDefinitions = @(
        @{ Key = 'foundry-capacity';  File = 'foundry-deployment-capacity.json'
           Display = 'Foundry deployment capacity ceiling'
           Params = @{ effect = $effectValue; maxCapacity = $Config.FoundryMaxDeploymentCapacity } }

        @{ Key = 'foundry-acct-sku';  File = 'foundry-account-sku.json'
           Display = 'Foundry account SKU allow-list'
           Params = @{ effect = $effectValue; allowedSkus = $Config.FoundryAllowedAccountSkus } }

        @{ Key = 'search-ceiling';    File = 'search-cost-ceiling.json'
           Display = 'AI Search SKU and scale ceiling'
           Params = @{ effect = $effectValue; allowedSkus = $Config.SearchAllowedSkus
                       maxReplicas = $Config.SearchMaxReplicas; maxPartitions = $Config.SearchMaxPartitions } }

        @{ Key = 'fabric-sku';        File = 'fabric-capacity-sku.json'
           Display = 'Fabric capacity SKU allow-list'
           Params = @{ effect = $effectValue; allowedSkus = $Config.FabricAllowedSkus } }

        @{ Key = 'aml-compute-sku';   File = 'aml-compute-sku.json'
           Display = 'Azure ML compute VM size allow-list'
           Params = @{ effect = $effectValue; allowedVmSizes = $Config.AmlAllowedVmSizes } }

        @{ Key = 'acr-sku';           File = 'acr-sku.json'
           Display = 'Container registry SKU allow-list'
           Params = @{ effect = $effectValue; allowedSkus = $Config.AcrAllowedSkus } }

        @{ Key = 'la-daily-cap';      File = 'log-analytics-daily-cap.json'
           Display = 'Log Analytics daily ingestion cap ceiling'
           Params = @{ effect = $effectValue; maxDailyQuotaGb = $Config.LogAnalyticsPolicyMaxDailyGb } }

        @{ Key = 'aca-ceiling';       File = 'container-apps-ceiling.json'
           Display = 'Container Apps scale ceiling'
           Params = @{ effect = $effectValue
                       allowedWorkloadProfileTypes = $Config.AcaAllowedWorkloadProfileTypes
                       maxReplicas = $Config.AcaMaxReplicas } }
    )

    if ($Config.FoundryDenyDynamicThrottling) {
        $customDefinitions += @{
            Key = 'foundry-dynquota'; File = 'foundry-dynamic-throttling.json'
            Display = 'Foundry dynamic quota must be off'
            Params = @{ effect = $effectValue }
        }
    }

    foreach ($custom in $customDefinitions) {
        $definitionName = "$prefix-$($custom.Key)"
        $definitionPath = Join-Path $RootPath "policies/$($custom.File)"

        $definitionId = "$subscriptionScope/providers/Microsoft.Authorization/policyDefinitions/$definitionName"

        Invoke-GuardrailAction -Plane $plane -Name "Definition: $($custom.Display)" `
            -WouldDo "Create or update custom definition '$definitionName' at subscription scope" `
            -Probe {
                $existing = Invoke-AzCli -AllowNotFound -Arguments @(
                    'policy', 'definition', 'show', '--name', $definitionName,
                    '--subscription', $Target.SubscriptionId, '-o', 'json'
                )
                if (-not $existing) { return @{ Compliant = $false; Detail = 'definition does not exist'; Evidence = @{ present = $false } } }

                $desired = (Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json -Depth 40).properties
                if ($existing.PSObject.Properties.Name -notcontains 'policyRule') {
                    return @{ Compliant = $false; Detail = 'existing definition has no readable policyRule'; Evidence = @{ present = $true; id = [string]$existing.id } }
                }
                $liveRule = $existing.policyRule | ConvertTo-Json -Depth 40 -Compress
                $wantRule = $desired.policyRule  | ConvertTo-Json -Depth 40 -Compress

                # Same reasoning as the assignment probe: a definition without
                # our stamp cannot be safely claimed by a teardown, so a missing
                # or foreign stamp is drift to repair rather than a state to
                # report compliant.
                $liveOwner = ''
                if (($existing.PSObject.Properties.Name -contains 'metadata') -and $existing.metadata -and
                    ($existing.metadata.PSObject.Properties.Name -contains 'ailz-owner')) {
                    $liveOwner = [string]$existing.metadata.'ailz-owner'
                }

                $evidence = @{ id = [string]$existing.id; ailzOwner = $liveOwner }

                if ($liveRule -ne $wantRule) {
                    return @{ Compliant = $false; Detail = 'policy rule differs from the file'; Evidence = $evidence }
                }
                if ($liveOwner -ne $script:OwnerStamp) {
                    $detail = if ($liveOwner) { "ailz-owner is '$liveOwner', want '$script:OwnerStamp'" } else { 'no ailz-owner stamp' }
                    return @{ Compliant = $false; Detail = $detail; Evidence = $evidence }
                }
                return @{ Compliant = $true; Detail = 'definition already current'; Evidence = $evidence }
            } `
            -Action {
                $result = Set-CustomPolicyDefinition -SubscriptionId $Target.SubscriptionId `
                    -Name $definitionName -DefinitionPath $definitionPath
                return @{ id = [string]$result.id }
            } | Out-Null

        New-GuardrailAssignment -Plane $plane -Scope $assignScope -Prefix $prefix `
            -Key $custom.Key -DisplayName $custom.Display -DefinitionId $definitionId `
            -EnforcementMode $enforcement -Parameters $custom.Params `
            -NonComplianceMessage "Blocked by the AI cost guardrails: $($custom.Display). Raise a change request if this workload genuinely needs a larger size."
    }

    # -------------------------------------------------------------- built-ins
    # Tag inheritance (modify -> needs a managed identity AND an explicit role).
    foreach ($tag in $Config.RequiredTags) {
        foreach ($source in @('InheritTagFromResourceGroup', 'InheritTagFromSubscription')) {
            $meta = $script:BuiltIns[$source]
            $shortSource = if ($source -like '*ResourceGroup') { 'rg' } else { 'sub' }
            $key = "tag-$shortSource-$tag"

            $resolved = $null
            try {
                $resolved = Resolve-BuiltInPolicy -Guid $meta.Guid -ExpectedDisplayName $meta.DisplayName
            }
            catch {
                Add-GuardrailResult -Plane $plane -Name "Tag inherit ($shortSource): $tag" -Status 'Failed' `
                    -Detail $_.Exception.Message | Out-Null
                continue
            }

            New-GuardrailAssignment -Plane $plane -Scope $assignScope -Prefix $prefix `
                -Key $key -DisplayName "Inherit tag '$tag' from $shortSource if missing" `
                -DefinitionId $resolved.Id -EnforcementMode $enforcement `
                -Parameters @{ tagName = $tag } `
                -WithIdentity -Location $Target.Location `
                -IdentityRoleId $script:ContributorRoleId `
                -Reference 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists'
        }
    }

    # Foundry approved models. Assigning this with both arrays empty matches
    # every deployment, so it is refused rather than assigned blind.
    if ($Config.FoundryAllowedPublishers.Count -eq 0 -and $Config.FoundryAllowedAssetIds.Count -eq 0) {
        Add-GuardrailResult -Plane $plane -Name 'Approved Foundry models' -Status 'Skipped' `
            -Detail 'FOUNDRY_ALLOWED_PUBLISHERS and FOUNDRY_ALLOWED_ASSET_IDS are both empty. With both empty this policy rule matches EVERY model deployment, so assigning it would flag or block everything.' `
            -Remediation 'Populate at least one before enabling this guardrail.' | Out-Null
    }
    else {
        $meta = $script:BuiltIns['ApprovedFoundryModels']
        try {
            $resolved = Resolve-BuiltInPolicy -Guid $meta.Guid -ExpectedDisplayName $meta.DisplayName
            New-GuardrailAssignment -Plane $plane -Scope $assignScope -Prefix $prefix `
                -Key 'approved-models' -DisplayName 'Approved Foundry models only' `
                -DefinitionId $resolved.Id -EnforcementMode $enforcement `
                -Parameters @{
                    effect            = $effectValue
                    allowedPublishers = $Config.FoundryAllowedPublishers
                    allowedAssetIds   = $Config.FoundryAllowedAssetIds
                }
        }
        catch {
            Add-GuardrailResult -Plane $plane -Name 'Approved Foundry models' -Status 'Failed' -Detail $_.Exception.Message | Out-Null
        }
    }

    # Straightforward parameterised built-ins.
    $simple = @(
        @{ Key = 'apim-base'; Source = 'ApimBasePolicy'
           Display = 'APIM policies must inherit parent scope via <base />'
           Params = @{ effect = $effectValue }
           Note = 'This is the policy that protects the token limit itself. A narrower-scope APIM policy that omits <base /> silently drops the inherited gateway auth AND the inherited llm-token-limit.' }

        @{ Key = 'denied-types'; Source = 'NotAllowedResourceTypes'
           Display = 'Denied expensive resource types'
           Params = @{ effect = $effectValue; listOfResourceTypesNotAllowed = $Config.DeniedResourceTypes }
           Note = 'Belt and braces behind the custom role: denies these at the resource layer so an unrelated Contributor grant does not reopen the door.' }

        @{ Key = 'cosmos-ru'; Source = 'CosmosThroughputLimit'
           Display = 'Cosmos DB throughput ceiling'
           Params = @{ effect = $effectValue; throughputMax = $Config.CosmosMaxThroughputRu }
           Note = 'Serverless Cosmos accounts are unaffected by this policy.' }

        @{ Key = 'storage-sku'; Source = 'StorageAllowedSkus'
           Display = 'Storage account SKU allow-list'
           Params = @{ effect = $effectValue; listOfAllowedSKUs = $Config.StorageAllowedSkus }
           Note = 'A built-in already does this well, so there is no custom definition for it. The role grants Microsoft.Storage/* and therefore storageAccounts/write; the SKU is where replication and premium media cost is decided. Premium_LRS and the geo-zone-redundant tiers are excluded by default.' }

        @{ Key = 'search-private'; Source = 'SearchDisablePublicAccess'
           Display = 'AI Search must disable public network access'
           Params = @{ effect = $effectValue }
           Note = 'Part of keeping the gateway authoritative over spend.' }

        @{ Key = 'rg-locations'; Source = 'AllowedLocationsForResourceGroups'
           Display = 'Allowed locations for resource groups'
           Params = @{ effect = $effectValue; listOfAllowedLocations = $Config.AllowedLocations }
           Note = '"Allowed locations" excludes resource groups, so this companion policy is needed or there is a hole.' }
    )

    foreach ($item in $simple) {
        $meta = $script:BuiltIns[$item.Source]

        if ($meta.RequiresSubscriptionScope -and $Config.PolicyScope -ne 'subscription') {
            Add-GuardrailResult -Plane $plane -Name $item.Display -Status 'Finding' `
                -Detail "This policy evaluates Microsoft.Resources/subscriptions/resourceGroups, which a resource-group-scoped assignment cannot see. Skipped rather than silently widening POLICY_SCOPE." `
                -Remediation "Either set POLICY_SCOPE=subscription, or assign it manually: az policy assignment create --name $(Get-AssignmentName -Prefix $prefix -Key $item.Key) --policy $($meta.Guid) --scope $subscriptionScope --enforcement-mode $enforcement" | Out-Null
            continue
        }

        try {
            $resolved = Resolve-BuiltInPolicy -Guid $meta.Guid -ExpectedDisplayName $meta.DisplayName
        }
        catch {
            Add-GuardrailResult -Plane $plane -Name $item.Display -Status 'Failed' -Detail $_.Exception.Message | Out-Null
            continue
        }

        New-GuardrailAssignment -Plane $plane -Scope $assignScope -Prefix $prefix `
            -Key $item.Key -DisplayName $item.Display -DefinitionId $resolved.Id `
            -EnforcementMode $enforcement -Parameters $item.Params `
            -NonComplianceMessage "Blocked by the AI cost guardrails: $($item.Display)." `
            -Note $item.Note
    }

    Add-GuardrailResult -Plane $plane -Name 'Evaluation timing notice' -Status 'Finding' `
        -Detail 'A new assignment applies to its scope in about 5 minutes; a resource is evaluated about 15 minutes after it is deployed; the standard full compliance cycle is every 24 hours. Microsoft publishes no expectation for when a full cycle completes over a large scope.' `
        -Remediation 'Do not conclude an assignment failed because the compliance blade is empty an hour later. These timings are also why a retrofit onto a subscription with existing workloads reads its Audit results after a full 24-hour cycle rather than after an hour. Microsoft publishes no soak duration, so if you are soaking, set your own flip date and write it down.' `
        -Reference 'https://learn.microsoft.com/azure/governance/policy/how-to/get-compliance-data' | Out-Null
}

function New-GuardrailAssignment {
    <#
    .SYNOPSIS
        Create one assignment and, when the policy has a modify or DINE effect,
        grant its managed identity the role it needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Plane,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$DefinitionId,
        [Parameter(Mandatory)][string]$EnforcementMode,
        [hashtable]$Parameters = @{},
        [switch]$WithIdentity,
        [string]$Location,
        [string]$IdentityRoleId,
        [string]$NonComplianceMessage,
        [string]$Note,
        [string]$Reference
    )

    $name = Get-AssignmentName -Prefix $Prefix -Key $Key
    $assignmentId = "$Scope/providers/Microsoft.Authorization/policyAssignments/$name"

    $record = Invoke-GuardrailAction -Plane $Plane -Name "Assignment: $DisplayName" -Reference $Reference `
        -WouldDo "Create or update assignment '$name' (enforcementMode=$EnforcementMode)$(if ($WithIdentity) { ' with a system-assigned identity' })" `
        -Probe {
            $url = "https://management.azure.com$assignmentId" + "?api-version=$script:PolicyApiVersion"
            $existing = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if (-not $existing) { return @{ Compliant = $false; Detail = 'assignment does not exist'; Evidence = @{ present = $false } } }

            $drift = @()
            $liveProperties = $existing.properties
            $livePropertyNames = $liveProperties.PSObject.Properties.Name

            $liveEnforcement = if ($livePropertyNames -contains 'enforcementMode') { [string]$liveProperties.enforcementMode } else { 'Default' }
            if ($liveEnforcement -ne $EnforcementMode) {
                $drift += "enforcementMode is $liveEnforcement, want $EnforcementMode"
            }

            $liveDefinitionId = if ($livePropertyNames -contains 'policyDefinitionId') { [string]$liveProperties.policyDefinitionId } else { '' }
            if ($liveDefinitionId -ne $DefinitionId) {
                $drift += 'points at a different definition'
            }

            # An assignment without our stamp is one a teardown could not
            # safely claim. Treat a missing or foreign stamp as drift so a
            # rerun repairs anything created before stamping existed, rather
            # than reporting it compliant and leaving it unidentifiable.
            $liveOwner = ''
            if (($livePropertyNames -contains 'metadata') -and $liveProperties.metadata -and
                ($liveProperties.metadata.PSObject.Properties.Name -contains 'ailz-owner')) {
                $liveOwner = [string]$liveProperties.metadata.'ailz-owner'
            }
            if ($liveOwner -ne $script:OwnerStamp) {
                $drift += if ($liveOwner) { "ailz-owner is '$liveOwner', want '$script:OwnerStamp'" }
                          else { 'no ailz-owner stamp' }
            }

            foreach ($parameterName in $Parameters.Keys) {
                $live = $null
                if (($livePropertyNames -contains 'parameters') -and $liveProperties.parameters -and
                    ($liveProperties.parameters.PSObject.Properties.Name -contains $parameterName)) {
                    $live = $liveProperties.parameters.$parameterName.value
                }
                $want = $Parameters[$parameterName]
                $liveJson = $live | ConvertTo-Json -Depth 10 -Compress
                $wantJson = $want | ConvertTo-Json -Depth 10 -Compress
                if ($liveJson -ne $wantJson) { $drift += "parameter '$parameterName' differs" }
            }

            $livePrincipal = $null
            if (($existing.PSObject.Properties.Name -contains 'identity') -and $existing.identity) {
                $livePrincipal = [string]$existing.identity.principalId
            }

            if ($drift.Count -eq 0) {
                return @{
                    Compliant = $true
                    Detail    = "already current (enforcementMode=$EnforcementMode)"
                    Evidence  = @{ present = $true; id = $assignmentId; principalId = $livePrincipal; ailzOwner = $liveOwner }
                }
            }

            return @{
                Compliant = $false
                Detail    = ($drift -join '; ')
                Evidence  = @{ present = $true; id = $assignmentId; principalId = $livePrincipal; ailzOwner = $liveOwner }
            }
        } `
        -Action {
            $splat = @{
                Scope                = $Scope
                Name                 = $name
                DisplayName          = $DisplayName
                PolicyDefinitionId   = $DefinitionId
                EnforcementMode      = $EnforcementMode
                Parameters           = $Parameters
                NonComplianceMessage = $NonComplianceMessage
            }
            if ($WithIdentity) {
                $splat['WithIdentity'] = $true
                $splat['Location'] = $Location
            }
            $result = Set-PolicyAssignment @splat
            $principal = $null
            if ($result -and ($result.PSObject.Properties.Name -contains 'identity') -and $result.identity) {
                $principal = [string]$result.identity.principalId
            }
            return @{ id = [string]$result.id; principalId = $principal }
        }

    if ($Note) {
        Add-GuardrailResult -Plane $Plane -Name "$DisplayName (rationale)" -Status 'Compliant' -Detail $Note | Out-Null
    }

    if (-not $WithIdentity) { return }

    # ---- the SDK/Bicep trap ----
    if (-not (Test-GuardrailApplyMode)) {
        Add-GuardrailResult -Plane $Plane -Name "Identity role grant: $DisplayName" -Status 'WouldApply' `
            -Detail "Would grant Contributor ($IdentityRoleId) to the assignment's system-assigned identity at $Scope. Portal-created assignments get this automatically; CLI, SDK and Bicep ones do NOT - without it the assignment reports compliance and remediates nothing." `
            -Reference 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists' | Out-Null
        return
    }

    $principalId = Get-EvidenceValue -Evidence $record.Evidence -Key 'principalId'

    if ([string]::IsNullOrWhiteSpace($principalId)) {
        # A freshly created assignment can take a moment to surface its identity.
        for ($attempt = 1; $attempt -le 6 -and [string]::IsNullOrWhiteSpace($principalId); $attempt++) {
            Start-Sleep -Seconds 5
            $url = "https://management.azure.com$assignmentId" + "?api-version=$script:PolicyApiVersion"
            $live = Invoke-AzRestJson -Method get -Url $url -AllowNotFound
            if ($live -and $live.PSObject.Properties.Name -contains 'identity' -and $live.identity) {
                $principalId = [string]$live.identity.principalId
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Add-GuardrailResult -Plane $Plane -Name "Identity role grant: $DisplayName" -Status 'Failed' `
            -Detail "The assignment has no readable system-assigned identity principalId, so its role could not be granted. The assignment will report compliance and remediate nothing." `
            -Remediation "Check Policy > Assignments > $name > Edit assignment > Remediation." | Out-Null
        return
    }

    try {
        $grant = Grant-PolicyIdentityRole -PrincipalId $principalId -Scope $Scope `
            -RoleDefinitionId $IdentityRoleId -AssignmentName $name

        $detail = if ($grant.alreadyGranted) {
            "Contributor already granted to the assignment identity at $Scope."
        }
        else {
            "Granted Contributor to the assignment identity at $Scope. Note: managed-identity role changes can take up to 10 minutes, and group-membership changes several hours - this grant is direct to the principal specifically to avoid the latter."
        }

        Add-GuardrailResult -Plane $Plane -Name "Identity role grant: $DisplayName" -Status 'Applied' `
            -Detail $detail -Evidence $grant `
            -Reference 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists' | Out-Null
    }
    catch {
        Add-GuardrailResult -Plane $Plane -Name "Identity role grant: $DisplayName" -Status 'Failed' `
            -Detail $_.Exception.Message `
            -Remediation "Verify with: Policy > Assignments > $name > Edit assignment > Remediation tab." | Out-Null
    }
}

Export-ModuleMember -Function @(
    'Invoke-PolicyGuardrails'
    'Resolve-BuiltInPolicy'
    'Get-AssignmentName'
    'Set-CustomPolicyDefinition'
    'Set-PolicyAssignment'
    'Grant-PolicyIdentityRole'
    'New-GuardrailAssignment'
)
