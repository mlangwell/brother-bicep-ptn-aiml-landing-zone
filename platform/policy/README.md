# Workload governance (P3)

`platform\governance.bicep` is a separate privileged **subscription** entry point,
not part of the ordinary resource-group orchestrator. Custom definitions are
subscription resources because Azure requires that boundary. Every assignment
and the Cost budget are scoped to the exact existing workload RG.

## Exact interface

| Input | Type / default |
| --- | --- |
| `enabled` | bool, `false`; does not remove existing governance |
| `resourceGroupName` | string, required |
| `expectedSubscriptionId` | string, `''`; required/matched when enabled |
| `expectedTenantId` | string, `''`; required/matched when enabled |
| `configuration` | object, `{}`; the unchanged validated P1 `governance` object |
| `billingCurrency` | string, `''`; observed billing evidence, required when enabled |
| `budgetEtag` | string, `''`; empty only for observed budget absence |

Output `facts:object` is empty when disabled. When enabled it contains owner,
scope, custom definition IDs, owned assignment IDs and built-in versions,
budget ID/scope/amount/requested currency, inference allowance, source links and
pending tenant-availability verification. It is not a compliance/readiness verdict.

`Governance.psm1` exports:

```text
New-GovernanceDeploymentParameters
  -Profile IDictionary -BillingCurrency string [-AllowSynthetic]
Get-GovernanceDesiredState
  -Profile IDictionary -BillingCurrency string [-AllowSynthetic]
Get-GovernanceDeploymentPlan
  -Profile IDictionary -BillingCurrency string -Request scriptblock
  [-AllowSynthetic]
Assert-GovernanceReadiness
  -Profile IDictionary -BillingCurrency string -Request scriptblock
  [-AllowSynthetic] [-AtTime datetimeoffset]
Assert-GovernanceDeploymentReadiness
  -Profile IDictionary -BillingCurrency string -Request scriptblock
  [-AllowSynthetic]
```

These reuse `Resolve-EnvironmentProfile` from P1 instead of maintaining a second
profile validator. The parameter helper returns a standard ARM parameter
document. The plan returns `schemaVersion`, `scope`, `owner`, `parameters`, per-resource
existence/state hashes, `requiredBuiltins`, `sourceCommit`, `planHash`, and
`remainingLiveEvidence`. The injected ARM transport has the same
`(method, absoluteUri, body, headers) -> {StatusCode; Body; Headers}` dictionary
contract as the gateway helper. Governance planning only issues GET requests.
Transport bodies must preserve JSON scalar types (in particular, timestamp
strings rather than PowerShell `DateTime` objects) for canonical state hashing.

The parent must obtain real billing-currency evidence, confirm target
subscription/tenant, check built-in versions/parameters and alias availability,
and freeze the complete governance plan and returned parameters with preview.
Immediately before execution, under the environment mutation lease, obtain the
same plan again and reject a changed `planHash`. Use the profile's explicit
subscription, not an incidental CLI default. `AllowSynthetic` is for offline
tests only and is not execution permission.

`Get-GovernanceDesiredState` renders the exact exported functions in
`contracts.bicep` that `definitions.bicep` and `assignments.bicep` also deploy.
It returns scope/owner, the parameter document, complete expected resource
properties, pinned built-ins and `desiredStateHash`. It performs no Azure calls
and always returns `readyForWorkloadDeployment=false`. It requires the approved
Bicep compiler on PATH, bounds that process to 120 seconds, and cleans the
temporary configuration and parameter files. This local timeout is necessary
because the shared native helper has no timeout argument.

## Exact P2/P5 integration and the standalone boundary

`Invoke-PlatformBootstrap.ps1` implements a separate `Governance` stage, also
included in `All`. It binds the P3 resource contracts, scoped desired-state plan
and observed billing currency to the outer bootstrap `plan.planHash`, reconciles
only owned resources, and requires the readiness assertion even after a no-op.
A successful Foundation/Network stage or a validated P1 profile alone is not
governance readiness. The independent Bicep boundary below is also supported;
it does not move privileged governance into ordinary main deployment.

The empty workload RG and required platform foundation must exist first. A
missing RG/definition/assignment/budget is a blocker naming the separately
privileged governance deployment, **not** permission to let workload creation
run first. P2's execution identity needs definition authority at the approved
subscription and assignment/budget authority at the exact workload RG. P5's
readiness identity only needs the corresponding reads.

Illustrative parent orchestration; these Azure commands require explicit scope
authorization and are not performed by local tests:

```powershell
Import-Module .\scripts\github\Environment.psm1
Import-Module .\platform\policy\Governance.psm1
$profile = Read-EnvironmentProfile -Path $profilePath

# P2: read-only plan, with independently observed billing currency.
$plan = Get-GovernanceDeploymentPlan -Profile $profile `
    -BillingCurrency $observedBillingCurrency -Request $governanceArmRequest
Write-JsonFile $planPath $plan
Write-JsonFile $parametersPath $plan.parameters
az deployment sub what-if --subscription $profile.azure.subscriptionId `
    --location $profile.azure.location --template-file .\platform\governance.bicep `
    --parameters "@$parametersPath"
if ($LASTEXITCODE -ne 0) { throw 'Governance preview failed.' }

# Separate privileged P2 step, only after approval of the saved plan/source.
# Hold the environment mutation lease and do not replace the approved plan.
$fresh = Get-GovernanceDeploymentPlan -Profile $profile `
    -BillingCurrency $observedBillingCurrency -Request $governanceArmRequest
if ($fresh.planHash -cne $approvedPlanHash -or $plan.planHash -cne $approvedPlanHash) {
    throw 'Governance state or configuration changed; new preview/approval required.'
}
Write-JsonFile $parametersPath $fresh.parameters
az deployment sub create --subscription $profile.azure.subscriptionId `
    --location $profile.azure.location --template-file .\platform\governance.bicep `
    --parameters "@$parametersPath"
if ($LASTEXITCODE -ne 0) { throw 'Governance deployment failed.' }

# P2 postcheck AND mandatory P5 gate before preview/main creates workload resources.
$evidence = Assert-GovernanceReadiness -Profile $profile `
    -BillingCurrency $observedBillingCurrency -Request $governanceArmRequest
if ($evidence.mode -cne 'observed' -or -not $evidence.readyForWorkloadDeployment) {
    throw 'Observed governance readiness is required before workload deployment.'
}
```

P2's Boolean postcondition API is exactly
`Assert-GovernanceDeploymentReadiness -Profile $profile -BillingCurrency
$observedBillingCurrency -Request $governanceArmRequest`. It returns exactly
`$true` after the same checks pass, or throws; it has no mutation/Execute switch.
Use it where Bootstrap expects a Boolean predicate. The rich
`Assert-GovernanceReadiness` API remains available for persisted evidence.
Do not pass `AllowSynthetic` in real P2/P5 execution.

Bind the immutable source/configuration SHA, saved parameter document and plan
hash into approval. Use `plan.parameters`, not parameter-only conversion, for
execution: only the observed plan supplies an existing budget's eTag. The
wrapper above is a wiring example, not an alternate authorization mechanism.
For the integrated bootstrap CLI, select `-Stage Governance`, provide
`governance.billingCurrency` in the immutable platform input, and approve the
outer `plan.planHash` rather than the nested `plan.governance.planHash`.

The GET-only transport must allow only these required read surfaces:

- Exact workload RG (`2025-04-01`).
- Exact subscription custom definition IDs (`2023-04-01`).
- Exact RG assignments and the RG assignment inventory (`2024-04-01`).
- Exact workload budget (`2024-08-01`).
- Pinned global built-in definition version IDs:
  `<definition-id>/versions/<version>` (`2023-04-01`).
- Subscription resource-provider alias catalogs (`2021-04-01`):
  `/subscriptions/<id>/providers/<namespace>?api-version=2021-04-01&$expand=resourceTypes/aliases`.
  Namespaces are derived from the actual pinned built-in and shared custom
  policy rules (currently Cognitive Services, Search and Insights).
- Applicable RG policy exemption inventory (`2022-07-01-preview`), including
  inherited and child-scope exemptions returned by that API.
- Explicitly configured action-group IDs (`2023-01-01`), which may be outside
  the workload RG.

P5's existing RG-only deployment transport is insufficient for the subscription
definitions/global built-ins; adapt a separately constrained reader rather than
grant ordinary P5 deployment identities subscription-wide write access.

## Readiness evidence and failure semantics

`Assert-GovernanceReadiness` throws unless GET observations establish the RG,
every pinned built-in version, exact owned custom definitions/rules/parameters,
and all exact owned assignments with their expected scope, effect,
`enforcementMode`, parameters and exclusions. Unexpected selectors/overrides,
active exemptions for owned assignments and removed-but-active owned assignments
block readiness. Unrelated policy estate is not mutated.

Built-in parameter names, types and case-sensitive allowed values are checked
against the explicitly bound assignment values. Every provider alias referenced
by the actual built-in and shared custom policy rules must appear in the expanded
subscription provider catalog. Missing schemas, an unsupported parameter/schema
shape or a missing alias throws a specific dependency failure; existence/version
alone cannot pass. Standard `type`, `location` and computed `tags[...]` fields
are not resource-provider aliases.

The budget must actually exist, retain its ownership anchor/eTag, have the exact
amount/monthly dates and Actual/Forecasted notification recipients/thresholds,
have no filter, be active now, and expose a `currentSpend.unit` matching the
approved observed currency. Missing currency observation is a blocker, not a
default. Referenced action groups must exist and be enabled. A second owned
inventory detects configuration changes during verification. No policy scans,
notifications, inference, resource creation or permission changes are invoked.
Recipient arrays are compared as sets, not by API response ordering. Action-group
resource IDs compare case-insensitively; email strings retain their exact values.
Supplying `BillingCurrency` is not sufficient evidence: the live budget's
`properties.currentSpend.unit` must independently expose the same unit. No
profile-only fallback or guessed currency is permitted if that observation is
missing.

Audit can pass **installed assessment configuration**, not Deny enforcement.
Disabled cannot pass the governed workload gate. Success returns:

```text
schemaVersion = 1
mode = observed | offline-test
scope, owner, policyEffect, budgetResourceId, billingCurrency
readyForWorkloadDeployment = true
controlPlaneVerified = true
builtinParametersVerified = true
providerAliasesVerified = true
desiredStateHash, planHash, observedAtUtc, observedResources
liveEnforcementVerified = false
notificationDeliveryVerified = false
```

`AllowSynthetic` produces explicitly labeled offline-test evidence, never
acceptable to production/P5. `AtTime` is accepted only for those synthetic
fixtures; real checks use the current UTC time. Actual policy propagation,
inherited-policy compatibility, enforcement probes and notification delivery
remain separate live gates. Persisting a desired-state file or a profile cannot
produce this successful observed result.

## Baseline and exact matching

Current official built-ins are pinned by definition ID/version in `builtins.json`
at Azure/azure-policy commit
`7b0fa25ac055d8c3001d5205cd009cd119a289a5`, opened on 2026-09-16:

| Control | Version / behavior |
| --- | --- |
| Restricted AI network access | `3.3.0`; Cognitive Services and Search |
| Disabled local authentication | `1.1.0`; Cognitive Services and Search |
| Allowed resource locations | `1.1.0`; its documented global/RG/type exclusions remain |
| Approved AI private endpoints | `1.0.0`; Audit/Disabled only |
| Required resource tags | `1.0.1`; fixed Deny definition |
| Diagnostic settings | `2.0.1`; fixed AuditIfNotExists, selected Cognitive Services/Search types |

No deprecated public-network definition or eligibility-preview policy is
required. API Management has deliberately content-free API-level Insights
diagnostics and service metrics, so it is not falsely marked compliant by the
separate generic resource-logs audit.

Custom `All`-mode policies enforce exact OpenAI model format/name/version and
approved deployment `sku.name`, following the documented deployment-type
pattern. A small custom Indexed policy tightens the current network built-in:
Foundry and Search must have `publicNetworkAccess=Disabled`, not just an IP
allow-list. It does not block APIM's required initial public-to-private transition.

P1's `azureml://registries/azure-openai/models/<name>/` syntax means **all
versions of that exact model name**. Its `/versions/<model.version>` form means
that exact deployment model version. Names and versions are compared using
equality, not `contains`, prefix matching or a publisher allowance. Version `1`
does not allow `10`; model `gpt-5` does not allow `gpt-5.2`.

The current approved-models built-in
`aafe3651-cb78-4f68-9f81-e7e41509110f` (`1.0.2`) was inspected: it uses publisher
OR asset-ID `contains`. It is intentionally **not assigned as an exact-version
guard**, and `allowedPublishers=["OpenAI"]` is never emitted. The custom policy
protects ARM deployment resources; this is not a promise of Foundry catalog
filtering or native portal integration. Verify every authorized deployment flow
and alias in the live gate. P1 version identifiers denote `model.version`, not an
inferred translation of an opaque catalog artifact version; broader publisher/
registry semantics require an explicit contract change.

Resource location restrictions and Global model processing residency are
different controls. Approving a resource region does not approve or constrain a
Global deployment's processing location. The approved deployment SKU/residency
decision must be supplied independently.

## Audit, ownership and budgets

Audit is the initial profile effect. Deny requires `assessmentApproved=true`.
Compiled nested ARM parameters accept only `true` for assessment, currency and
execution-scope guards, before custom policy/budget resource writes. The three
small Bicep `any()` uses defer dynamic boolean assertions to those strict ARM
guards; they do not weaken the guard. Disabled paths use lazy fallbacks rather
than reading missing configuration/conditional outputs.

Parameterized policies receive Audit/Deny/Disabled directly. Fixed-Deny tag
assignments use `DoNotEnforce` in Audit. Fixed-effect policies are excluded at the
exact workload RG when Disabled; they are not deleted. Diagnostic/private-link
audits do not magically become Deny. Required-tag built-ins do not enforce RG
tags themselves; P1 validates supplied deployment tags, and the parent/live
assessment must verify the actual RG and supported resource tags.

The explicit ownership prefix is limited to **40 characters** by this module.
P1's current generic name schema is broader: the parent must use these P3 guards
(or coordinate a later P1 validation tightening), not edit the shared schema
implicitly. Different workload RGs must use distinct prefixes for subscription
definition names. Conflicting definitions/assignments are rejected, never
adopted. Unrelated assignments are untouched.

Required-tag assignment indices are deterministic for the approved ordered
profile. Removing entries must not silently leave old active controls behind.
The plan detects removed owned assignments and refuses reconciliation unless
they were explicitly disabled with the prior owned configuration. Disabled
orphans are recorded and preserved; no automatic deletion is implemented.

The budget is a **whole-workload-RG monthly Cost budget with no resource/tag
filter**, named `<assignmentPrefix>-environment`. Both Actual and Forecasted
thresholds copy the configured email/action-group arrays; there are no guessed
amounts, thresholds, recipients, start/end dates or currency conversions.
Fractional numeric values are retained. Consumption's writable budget contract
has no currency selector: supplied currency must match observed workload billing
currency, and the requested/verified values are recorded separately.

Budgets cannot carry this ownership tag. Owned assignment metadata anchors the
exact budget ID, and Bicep establishes those assignments before creating the
budget. A preexisting budget without that owned anchor is rejected. Existing
budget eTags are captured for optimistic concurrency and included in the frozen
parameters. A partial deployment or conflicting anchor needs an inspected
recovery plan, not implicit takeover.

Budgets **notify; they do not stop consumption**. Cost reporting and notifications
lag. Inference allowance, pricing date/sources and allocated tokens are retained
as explicit planning evidence, not converted into invoice dollars by this code.
Fixed gateway/compute/Search/provisioned-capacity costs continue after inference
is blocked. Shared resources outside the workload RG and GitHub billing require
separate accounting.

## Required live evidence and recovery

Before any approved deployment, verify the workload RG exists, the privileged
identity has only the intended definition/assignment/budget authority, the
opened built-in versions and custom aliases are available, and the observed
billing currency and budget dates are valid for that billing scope.

After deployment, independently observe effective inherited and owned policies,
existing-resource assessment, and successful approved versus rejected model/
version/SKU/region/network/key/tag cases. Test Deny only after explicit assessment
approval. Verify both actual and forecast email/action-group routing without
claiming a real budget threshold was crossed merely because a notification was
simulated. Confirm the budget has no filter and covers the intended RG.

Rollback means reconcile a recorded known-good owned configuration with preview
and approval. It does not mean remove all governance, delete a budget or reuse an
old eTag. A false feature flag is not cleanup. Root documentation/version/parity
assessment and complete integration gates belong to the parent change.

Primary references:

- Exact built-in source JSON: `builtins.json`
- [Approved-models built-in source](https://raw.githubusercontent.com/Azure/azure-policy/7b0fa25ac055d8c3001d5205cd009cd119a289a5/built-in-policies/policyDefinitions/Cognitive%20Services/AllowDeployRegistryModels_Audit.json)
- [Model deployment governance](https://learn.microsoft.com/azure/foundry/how-to/model-deployment-policy)
- [Deployment SKU policy pattern and residency](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types)
- [Budget resource contract](https://learn.microsoft.com/azure/templates/microsoft.consumption/2024-08-01/budgets)
- [Budget notification behavior](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Built-in version GET contract](https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/resources/resource-manager/Microsoft.Authorization/policy/stable/2023-04-01/policyDefinitionVersions.json)
- [Applicable exemption inventory contract](https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/resources/resource-manager/Microsoft.Authorization/policy/preview/2022-07-01-preview/policyExemptions.json)
- [Budget GET and observed currency](https://learn.microsoft.com/rest/api/consumption/budgets/get?view=rest-consumption-2024-08-01)
- [Action-group enabled behavior](https://learn.microsoft.com/azure/templates/microsoft.insights/2023-01-01/actiongroups)
- [Subscription provider alias expansion](https://learn.microsoft.com/rest/api/resources/providers/get?view=rest-resources-2021-04-01)
- [Azure Policy aliases](https://learn.microsoft.com/azure/governance/policy/concepts/definition-structure-alias)
- [Parameter type and allowed-values semantics](https://learn.microsoft.com/azure/governance/policy/concepts/definition-structure-parameters)

With the isolated Bicep 0.42.1 toolchain on PATH:

```powershell
bicep build .\platform\governance.bicep --outfile <session-governance-template.json>
bicep lint .\platform\governance.bicep
pwsh -NoProfile -File .\tests\github\Governance.Tests.ps1
```

The local tests evaluate the actual rendered budget and policy conditions,
including exact-name/version negatives, fractional financial inputs, scope and
approval guards and mock ownership conflicts. They do not prove Azure policy
evaluation, tenant availability, billing accuracy or alert delivery.
