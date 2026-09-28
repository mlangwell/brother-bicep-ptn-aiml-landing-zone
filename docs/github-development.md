# GitHub development environments

**Status: local implementation; live validation pending.** No GitHub settings,
workflow dispatches, Azure resources, permissions or paid model probes are
authorized by this document. The original
[decision and work packages](adr/2026-09-16-github-dev-environment-plan.md)
remain the scope and acceptance criteria.

The new path is deliberately separate from the existing integrated wrapper and
Azure DevOps path. It prepares infrastructure, imports one tested application
artifact, completes private configuration and then collects developer-readiness
evidence. It does not deploy a business application or certify one for production.

## Contracts and ownership

| Surface | Contract |
| --- | --- |
| `environments/schema.json` | Closed, versioned nonsecret profile for `dev`, `test` and `prod`. Real inputs are operator supplied. |
| `Resolve-Environment.ps1` | Produces a full typed ARM parameter file and `resolved.json`; never reads or copies local `.azure` state. |
| `deployApiManagement`, `apiManagementConfiguration` | New default-off gateway flag and empty configuration object. Required gateway fields have no unlimited inference fallback. |
| `enableDeveloperExperience`, `developerExperience` | New default-off release-owned starter/completion contract. Existing consumers retain their behavior. |
| `containerAppsList` | Optional `image`, `registry`, `managedIdentity` and `environmentVariables` fields. The selected immutable image is present in infrastructure on the first and subsequent deployments. |
| `INFERENCE_GATEWAY_ENDPOINT`, `INFERENCE_GATEWAY_AUDIENCE` | Additive outputs, empty when disabled. The governed route is `/inference/v1/responses`; direct Foundry outputs are not a runtime fallback. |
| `DEVELOPER_COMPLETION` | Actual nonsecret resource/release/configuration bindings, including nested `gateway.accessMode`. Observability credentials are references, not output values. |
| `platform/` | Separately privileged identity, network, governance and access boundary; not ordinary workload deployment authority. |
| `samples/developer-smoke/` | Entra-authenticated, managed-identity-only text example. Health/readiness make no external or model calls. |
| `manifest.json` / CSE | Existing Microsoft upstream bootstrap pins are unchanged. Customer completion comes from the selected release, not an edited local installer that CSE never downloads. |

The first supported GitHub profile uses Azure public-cloud endpoints, IPv4,
a private Linux execution pool, an existing private ACR and a pre-created
workload UAI. Unsupported cloud/entitlement/identity combinations fail closed;
they are not replaced by public endpoints, client secrets or a privileged
long-lived runner.

### Configuration preparation

Copy a template to a private operator location and supply actual values:

```powershell
Copy-Item .\environments\dev.example.json "<private-profile-path>"
pwsh .\scripts\github\Resolve-Environment.ps1 `
  -ProfilePath "<completed-private-profile-path>" `
  -OutputDirectory "<new-local-output-directory>"
```

The three `.example.json` files are intentionally unresolved and cannot be
deployed. Only tests use synthetic identities, CIDRs, dates and amounts;
`-AllowSynthetic` is for offline resolution/tests and is rejected by execution
paths. Never turn a fixture into a deployment profile by changing one flag.

Profiles bind actual Bicep names for addresses/subnets, hub/DNS integration,
feature flags, tags and deployment lists. Lists remain arrays and flags remain
booleans. Conflicting overrides, unresolved values, unsupported environments,
missing limits, overlapping networks and incomplete production requirements
are errors. No VM password is fabricated: the starter path requires VM/jumpbox
provisioning off and supplies an unused empty secure parameter. Human work can
use an approved existing private workstation.

The governed GitHub entry point also requires explicit
`parameters.aiFoundryAccountName` and `gateway.name`, so backend routing and
encoded gateway configuration can be validated before resource creation.
Existing Bicep consumers retain their CAF/legacy generated-name behavior.

For GitHub delivery, publish only the completed **nonsecret** profile as
`environments/<environment>.json` and its closed supplemental platform input as
`environments/<environment>.platform.json` in the approved target repository.
Select their immutable commit SHA at dispatch; both files are checksum-bound to
selection and preview. Do not publish customer configuration in this
public working fork merely to satisfy a workflow. The target repository's
visibility, entitlement and access policy are separate required inputs.

## Bootstrap before scheduling private jobs

The bootstrap defaults to inspection/plan output, even when credentials exist.
It reads existing resources, detects incompatible ownership/protections and
records missing administrative dependencies. A blocked plan exits nonzero.

```powershell
pwsh .\scripts\github\Invoke-PlatformBootstrap.ps1 `
  -ProfilePath "<completed-profile.json>" `
  -PlatformInputsPath "<approved-platform-inputs.json>" `
  -Stage Environments -PlanPath "<new-plan.json>"
```

Stages separate `Foundation`, `Environments`, `Federation`, `Runner`, `Network`,
`Access`, `Governance` and resource-dependent `Completion`. Foundation obtains actual managed
identity IDs before a completed profile exists. Scope-specific platform inputs
are validated by `Read-PlatformInputs` / `Get-BootstrapPlatformInputSchema`;
they are not arbitrary scripts or a copy of a developer's Azure state.

The plan is not approval. After the responsible administrator explicitly
approves the exact saved plan and scope, the future execution form is:

```powershell
pwsh .\scripts\github\Invoke-PlatformBootstrap.ps1 `
  -ProfilePath "<completed-profile.json>" `
  -PlatformInputsPath "<same-platform-inputs.json>" `
  -PlanPath "<inspected-plan.json>" -Execute `
  -ApprovedPlanHash "<exact-inspected-sha256>"
```

Execution re-reads state and rejects a stale plan rather than silently merging
new authority into it. Existing compatible resources are reused; unrelated
settings, APIs, policy assignments, roles, DNS zones and worktrees are not
deleted to make a rerun succeed.

Before workload deployment, establish and verify:

- The intended repository, immutable IDs, approved refs and environment
  protections. `dev-preview`, `test-preview` and `prod-preview` are separate
  from `dev`, `test` and `prod`. Test/prod require independent reviewers,
  self-review prevention and administrator-bypass restrictions.
- Actual emitted OIDC claims for the intended environments. Capture nonsecret
  claims with the separately approved **Capture verified OIDC claims only**
  workflow (`oidc-probe.yml`): select environment, `preview`/`deploy` purpose and
  immutable configuration SHA. It checks existing protections before the
  claims-only job and invokes `Export-OidcClaims.ps1`; it never logs in to Azure.
  Never print or store the JWT. A copied legacy subject is not sufficient evidence.
- Separate constrained preview, workload deployment and privileged bootstrap
  identities. Normal humans/workloads must not receive direct Foundry inference
  privileges. The deployment identity remains a privileged control-plane actor,
  not a caller protected from its own administrative authority.
- An approved private runner group, repository/workflow restrictions, private
  networking configuration and available execution capacity. An organization
  administrator may need to supply a short-lived, read-only GitHub installation
  token for inventory not visible to the repository `GITHUB_TOKEN`.
- Prepared spoke/hub connectivity, reverse peering, private DNS links/resolution,
  approved egress and a dedicated gateway integration subnet. The private ACR
  and workload pull identity must work **before** the first Container App image
  pull. Do not wait for a failed full workload deployment to create the reverse
  route or the runner that was supposed to execute it.

Keep `POLICY_MANAGED_PRIVATE_DNS` false unless actual policies are assigned and
proven. BYO zones require explicit ownership/linking; peering is not DNS.
The gateway and runner must not share an application's exclusive delegation.

The initial automated path uses an administrator-prepared spoke:
`useExistingVNet=true`, `deploySubnets=false`,
`hubIntegrationCreateHubPeering=false`, and the actual existing VNet, hub and
route-table IDs. Omit `hubIntegrationEgressNextHopIp` when supplying the existing
route table; supplemental `network.egress.expectedNextHopIp` verifies its next
hop without violating the profile's routing mutex. Supply approved ACA/PE NSG
fingerprints in `network.preparedSubnetNsgs`, the dedicated gateway integration
subnet, private ACR DNS and all BYO zones needed by the enabled services.
Foundation remains identity-only; it does not invent or deploy this network.
The approved `Network` and pre-main `Access` stages precede
`Assert-PreparedDeploymentFoundation` and any image import/main deployment.

GitHub's published environment PUT contract does not expose every protection
setting. Where administrator-bypass configuration cannot be established through
that supported API, an administrator must configure it separately and provide
verifiable existing-state evidence. Test/prod remain blocked without the required
protection and explicit bootstrap ownership marker; no undocumented API field
or weakened protection is used.

### Policy, budgets and access

`platform/governance.bicep` is a separate subscription-scope entry point whose
definitions support **workload-RG-scoped** assignments and a whole-RG budget.
Its parameters include explicit `enabled`, workload RG, expected subscription
and tenant, validated governance configuration, observed billing currency and
any existing budget ETag. Do not use a guessed billing currency or manufacture
a match by copying the requested currency into an observation.

Preview and authorize governance separately under platform authority. Inspect
existing resources in audit mode before approving deny enforcement. Required
built-in definitions/aliases must exist in the tenant. Exact model identity and
deployment SKU controls must not turn into publisher-wide or prefix allowlists.
Allowed resource regions do not establish Global-model processing residency.

Use `Invoke-PlatformBootstrap.ps1 -Stage Governance` with
`governance.billingCurrency` in the immutable platform input, independently
observed by the platform/budget owner. Approve the **outer** `plan.planHash`.
The stage retains P3's parameter document and source hashes, reconciles only
owned definitions/assignments/budget, rejects stale plans and verifies actual
desired state even after a no-op. `All` includes this stage.

Before workload preview/create, the private job invokes
`Assert-GovernanceDeploymentReadiness` through the shared GET-only adapter.
Actual definitions, versions, aliases, exclusions/exemptions, active budget,
recipient sets and enabled action groups must conform. The budget's observed
`currentSpend.unit` must match the approved/observed currency; a copied argument
is insufficient. Preview/deploy identities need explicit read access to these
RG controls, relevant subscription definitions/provider catalogs, global pinned
built-ins and configured action groups. Missing access is a blocker, not a
reason to elevate preview to Contributor.

Budgets notify; they do not stop Azure resources. Test actual/forecast recipient
and action-group routing using an explicitly approved notification test. Such
a test does not prove an actual cost threshold was crossed. Retention,
availability, infrastructure capacity and dev-compute schedules remain approved
profile/platform operations, not a universal budget shutdown switch.

## Trusted release and deployment sequence

Credential-free PR/push checks extend the existing `bicep-validate.yml`.
Only its successful trusted push run on the approved ref may supply a release.
The image is built once for Linux amd64, tested without external networking
and stored as OCI content alongside the compiled infrastructure and selected
source files. Sources, run/attempt, checksums, infrastructure version,
configuration schema and image digest are bound in `bundle.json`.
The profile preserves the bundle's version literally, including the `v` prefix
from `manifest.json`; it does not strip or manufacture a version prefix.

The size-gate build emits compact UTF-8 JSON without changing JSON values.
It measures the exact artifact that is bundled and deployed. Existing thresholds
and the read-only `-SkipBuild` contract are unchanged; a raw pretty
`az bicep build` result is not substituted for the tested release artifact.

After bootstrap and publication approvals, dispatch **Deploy selected
environment** with:

| Input | Meaning |
| --- | --- |
| `environment` | `dev`, `test` or `prod` |
| `release_run_id` | Exact successful CI run recorded in the profile |
| `configuration_sha` | Approved immutable commit containing the completed profile and supplemental platform input |
| `prior_promotion_run_id` | Verified preceding-environment live-evidence run for test/prod |

The reusable workflow performs selection on an ordinary hosted runner before
scheduling private work. It verifies GitHub source/run identity before download,
the archive digest before extraction, and all listed file checksums before
privileged execution. Untrusted PR callers cannot reach the private pool.

```text
trusted CI bundle + immutable profile
  -> constrained private preview
  -> recorded input/What-If/gateway-state hashes
  -> protected deployment approval
  -> idempotent private OCI import (digest unchanged)
  -> infrastructure with the selected active image
  -> refreshed deployment login
  -> verified private gateway/configuration/application completion
  -> separately authorized human and enforcement observations
  -> protected recording of live evidence
  -> eligibility for that same release in the next environment
```

Preview uses `ProviderNoRbac`, not Contributor as a convenient substitute for a
read-only identity. The current documented Azure CLI minimum for that switch is
2.76.0; verify the actual custom-role operations in the live gate. The change
summary redacts property values; review its hashes together with the exact
compiled release and resolved nonsecret profile. Preview is evidence, not
authorization.

After approval, profiles, bundle identity, gateway state and owned child
configuration must still match. A stale initial gateway plan must never
re-enable an existing private service. APIM creation establishes its private
endpoint before public-disable completion; ordinary subsequent deployments
remain private. Failed or interrupted bootstrap/completion is not a ready state.
Persisted approval/selection/promotion records use the shared strict JSON reader
so ISO timestamps remain strings and approval hashes survive an unchanged disk
round trip. An already-running approved private worker is verified by its
current runner identity rather than requiring a second idle worker.

Image import does not rebuild the application. Existing identical release tags
are reused; conflicting tags and changed digests fail. The registry must already
be private. The pre-main `Access` stage explicitly prepares registry-scoped
deployment import access and workload pull access, including when the registry
is outside the workload RG; post-main completion is not the first grant of that
authority. If provider preflight requires an image to exist before What-If,
obtain a separate approval for importing that exact bundle/digest first; do not
grant write access to preview or weaken validation/public access.

Environment mutations are serialized and do not cancel an in-progress deploy.
Test cannot skip dev, and production cannot skip test or its independent
approval. Artifact expiration or missing prior evidence blocks promotion.
Set `AILZ_ARTIFACT_RETENTION_DAYS` to the approved repository retention policy;
the workflow fallback retains the existing validation path's 14-day convention.
Track runner/artifact/Actions billing separately from Azure RG budgets.

## Developer completion and live acceptance

See [the starter contract](../samples/developer-smoke/README.md) for exact HTTP,
JWT, dependency, completion, workspace and probe interfaces.

Completion consumes the existing Bicep configuration shaping, not a second
hand-maintained settings inventory. It reconciles owned key/label pairs using
Entra, private pinned HTTPS and ETags. Required failures stay failures. It checks
the active image/configuration instead of imperatively repairing a placeholder.
The infrastructure stage owns both image and environment variables.

Prepare a separate editable workspace outside CSE's disposable infrastructure
checkout. The developer performs their own interactive SSO. LocalSystem or
pipeline authentication never proves human access. Existing dirty/mismatched
worktrees are preserved and require a human decision; no reset/delete/clean is
used to make them look ready.

The normal deployment workflow makes no paid model calls. A separately approved
human-context probe requires the actual profile/output, exact environment and
source SHA, and explicit request and token ceilings:

```powershell
pwsh .\scripts\github\Invoke-LiveDevGate.ps1 `
  -ProfilePath "<profile.json>" -DeploymentOutputsPath "<actual-outputs.json>" `
  -ExecutePaidProbes -ApprovedEnvironment "<dev|test|prod>" `
  -ApprovedSourceSha "<selected-source-sha>" -IdentityContext human `
  -MaxRequests "<approved-request-ceiling>" -MaxTotalTokens "<approved-token-ceiling>" `
  -ReleaseFingerprint "<verified-bundle-fingerprint>" `
  -WorkflowRunId "<successful-deployment-workflow-run-id>" `
  -EvidencePath "<new-observed-evidence.json>"
```

This is not permission to exhaust a shared quota or mutate stop controls.
Runner-mode probes verify caller rejection rather than assuming the deployment
SP is an ordinary allowed developer. Partial observations stay pending.

| Gate | Required live observation |
| --- | --- |
| Private connectivity | Workspace and runner resolve/reach intended private endpoints; public bypass is rejected. |
| Identity isolation | Human, workload, preview and deployment access is distinct; normal callers cannot invoke the backend directly. |
| Application inference | A correlated authenticated model-backed request succeeds with the selected image; health consumes no tokens. |
| Gateway enforcement | Invalid/spoofed callers and unapproved models/routes fail; native rate/period quota rejection, caller isolation and stop control are observed using approved test limits. |
| Metering coverage | Nonstreaming text Responses are covered; unsupported routes are rejected. Streaming/concurrency behavior and overshoot limits are recorded, not assumed away. |
| Cost operations | Correct budget scope/currency/recipients and actual notification-test routing are observed; fixed costs and billing lag are acknowledged. |
| Promotion integrity | Actual protected preview/deploy approvals and exact release/configuration identities are recorded. |
| Recovery | A separately approved known-good digest/configuration rollback and non-destructive rerun are observed. |
| Developer workspace | The correct prepared workspace, required tools and the developer's own SSO work. |

APIM's token rate rejection is 429; period-quota exhaustion is 403. Preserve
their retry semantics. Counters are gateway-local, not a global account ledger.
Concurrent/in-flight requests and estimates can overshoot; stopping new requests
does not cancel backend work or stop gateway/Search/compute/provisioned charges.
Embeddings, batch, realtime/audio, image generation, tools and internal managed
agent calls are not implicitly governed by this text route.

Reviewed live observations are distinct from automated proof. The protected
evidence-recording path binds actual successful deployment artifacts and
sanitized, checksummed operator receipts to the release/configuration. A
handwritten `passed: true`, health-only result or unrelated successful run is
not a promotion record. Do not record a gate before observing it.

The manual `record-live-gates.yml` workflow accepts the environment,
configuration SHA, evidence commit SHA, release CI run and successful deployment
run. Its fixed evidence manifest is
`environments/evidence/<environment>/live-gates.json`; receipts are regular UTF-8
JSON under its `receipts/` directory and follow `live-evidence.schema.json`.
Each gate records the observer, timestamp, procedure, result, observations and
file hashes. Both preflight and the protected recording job verify immutable
GitHub bytes and the source deployment artifact. Failed automatic evidence
cannot be replaced with an attestation.

The resulting `promotion.json` is explicitly
`evidenceKind=reviewed-live-observations`, `automatedProof=false`. It establishes
provenance and consistency, not the truthfulness of an operator. Review the
actual receipts and the completed live procedures; independent test/prod
approval remains required. Use the successful recorder run ID for the next
environment's `prior_promotion_run_id`.

## Recovery and rollout

Start only in the newly approved dev scope. Re-plan after drift. Resume scoped
completion rather than deleting resources or rebuilding workspaces. Roll back
to a recorded known-good OCI digest and compatible configuration, with a fresh
preview and approval; preserve data and diagnostics.

Turning a feature flag off is not cleanup authorization. Inspect deletions,
RBAC revocation, policy changes and shared DNS effects separately. Restore
recorded owned gateway/policy settings rather than removing all controls.

Production requires explicit identity/data isolation, model availability and
residency, capacity, availability, backup/recovery, retention and approver
ownership. Preparing the queue does not authorize provisioning production.

## Required approvals and inputs

| Owner | Inputs and specific future authorization |
| --- | --- |
| GitHub administrator | Actual org/repo and immutable IDs, offering/visibility/entitlement, protected refs/reviewers, environment and OIDC configuration, approved private runner group/network and read-only inventory access; separate approval to push/publish configuration and run each workflow/probe. |
| Azure platform administrator | Tenant/subscription/RG, prepared network/address allocation, hub/DNS/egress ownership, private ACR, identities and application registrations/audiences; explicit scoped foundation/federation/RBAC/network/policy/budget operations and actual permissions evidence. |
| Development owner | Allowed developer identities/groups, approved repository/ref, private workspace and toolchain, their own SSO and observed application/bypass evidence. |
| Budget owner | Billing currency, environment budget, inference allowance, permitted models/types, dated pricing sources/units, explicit token rates/period quotas, recipients/response owner, probe request/token ceilings and notification-test approval. |
| Production owner | Production profile and availability/data/residency/recovery/retention requirements, independent approvers, reviewed live evidence and separate promotion/provisioning authorization. |

No actual values or approvals were supplied for those remote gates. The local
result is not a fully provisioned development environment.

## Local verification and release coordination

The supported local gate is `npm test`; `npm run lint` runs pinned PowerShell
analysis and workflow semantic validation. It requires PowerShell 7.4+, the
pinned Bicep/ORAS/actionlint tools, `powershell-yaml`, PSScriptAnalyzer and a
CPython 3.13 venv installed from the sample lock. Set `AILZ_TEST_PYTHON` to that
venv's interpreter. These commands do not authorize or execute Azure/model gates.
See [local evidence](github-development-local-evidence.md) for observed results
and unavailable checks.

This is an additive minor-release candidate. Existing manifest/bootstrap pins
remain `v2.6.1`; no release was published. Portal/Terraform parity review and a
public `Azure/AI-Landing-Zones` documentation companion are pending separate
publication approval. Prepared public guidance is in
[the companion draft](github-development-public-documentation.md).

## Primary contracts

Relevant primary sources were reopened during local implementation on
2026-09-16. Recheck tenant/organization availability before remote execution:

- [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub environment protections and entitlement](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [GitHub-hosted runners with Azure private networking](https://docs.github.com/en/organizations/managing-organization-settings/about-azure-private-networking-for-github-hosted-runners-in-your-organization)
- [Bicep What-If and ProviderNoRbac](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if)
- [APIM private networking and public-disable ordering](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts)
- [APIM client authorization and backend managed identity](https://learn.microsoft.com/en-us/azure/api-management/api-management-authenticate-authorize-ai-apis)
- [APIM native token limits and coverage](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
- [Foundry model deployment policies](https://learn.microsoft.com/en-us/azure/foundry/how-to/model-deployment-policy)
- [Azure budget behavior](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [ACR Entra/OCI authentication protocol](https://github.com/Azure/acr/blob/main/docs/AAD-OAuth.md)
