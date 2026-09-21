# Plan — separate API Management from the AI Landing Zone lifecycle

**Status:** Draft for handoff. Not implemented. No Azure changes made.
**Date:** 2026-09-21
**Customer:** Brother
**CI/CD target:** GitHub Actions
**Companion doc:** `docs/apim-developer-sku-constraints.md` (SKU analysis and
why Developer tier was rejected)

## Decision

API Management becomes **per-subscription platform infrastructure** with its own
IaC and deployment pipeline. The AI Landing Zone **consumes an existing
gateway** instead of creating one.

Tier by subscription:

| Subscription | APIM tier | Zone redundancy |
| --- | --- | --- |
| dev | Standard v2 | no |
| test | Standard v2 | no |
| prod | Premium v2 | **yes** |

Sandbox is out of scope for this configuration — it runs its own isolated
CI/CD and is not represented in the `dev|test|prod` environment enum.

### Why

Deploying a landing zone currently creates a gateway. Lifecycles differ by an
order of magnitude: the gateway is long-lived, subscription-scoped, and
expensive; landing zones are redeployed often. Coupling them means every LZ
redeploy touches shared infrastructure, and multiple landing zones in one
subscription each get a redundant ~$700–$2,800/month gateway.

Developer tier was considered and **rejected**. It is technically workable via
internal VNet injection, but it is a workaround for a platform gap, carries no
SLA, cannot scale past one unit, and this customer would hold onto it
indefinitely. See the companion doc.

## Architecture split

**Platform template — once per subscription, rarely changed**

- APIM service: SKU, capacity, availability zones, system-assigned MI
- Integration subnet (delegated `Microsoft.Web/serverFarms`) + NSG
- Inbound private endpoint + `privatelink.azure-api.net` DNS zone group
- Service-level diagnostics to Log Analytics
- Service-level posture: `publicNetworkAccess`, `stopNewRequests`
- Outputs: `resourceId`, `name`, `principalId`, `gatewayUrl`

**Landing zone — every deployment**

- Backend pointing at *this* deployment's Foundry account
- API + schema + operation + policy + API diagnostic
- Named values (configuration, tenant, audience, stop)
- Application Insights logger
- Role assignments: APIM principal → `Cognitive Services OpenAI User` on this
  Foundry account; → `Monitoring Metrics Publisher` on this App Insights

## Work breakdown

### Phase 1 — Platform template

1. New `platform/api-management/main.bicep` carrying the service-level resources
   listed above.
2. Parameterise `sku` (`StandardV2` | `PremiumV2`) and `capacity`.
3. **Wire zone redundancy.** `modules/api-management/main.bicep:77` currently
   hardcodes `availabilityZones: []`. `useZoneRedundancy` is already threaded
   through Bastion, public IP, Container Apps environment, ACR, Cosmos and
   Application Gateway — APIM is the sole resource ignoring it. Left as-is,
   prod on Premium v2 deploys non-zonal, which defeats the reason for the tier.
4. New `scripts/Deploy-ApiManagement.ps1` wrapper (PowerShell 7, consistent with
   existing script conventions).

### Phase 2 — Landing zone consumes the gateway

5. Add `existingApiManagementResourceId` following the established BYO pattern
   (`existingLogAnalyticsWorkspaceResourceId` → `_hasExistingLaw` →
   `_createLogAnalytics` → `_lawResourceId`).
6. **Stop creating the integration subnet and NSG** (`main.bicep` ~1480–1496)
   when consuming an existing gateway. That subnet belongs to the platform VNet.
7. **Pass the APIM principal ID as a parameter** rather than reading it. The
   repo rule is explicit: *"Cross-RG-safe: we never call `.id` / `.properties`
   against `existing` resources here."*
8. **Move per-workload APIM children into a module scoped to the gateway's
   resource group.** `resource service '...' existing = { name: name }` resolves
   in the *current* resource group only; with APIM in a platform RG every child
   needs `scope: resourceGroup(apimSubscriptionId, apimResourceGroup)`.

### Phase 3 — Name collision (blocking correctness issue)

9. `owner = 'ailz-inference-${environmentName}'` names the API, and the API path
   is the fixed literal `'inference'`. Two landing zones sharing one gateway in
   the same subscription and environment **collide on both**. Since the entire
   point is multiple landing zones per subscription, per-workload resources must
   be keyed by something landing-zone-specific (`resourceToken` or workload
   name), not by environment. Applies to the API name, the API path, the backend
   name, and the named values.

### Phase 4 — Profiles, validators, pipelines, docs

10. `gateway` profile block flips from *create* (sku, capacity, publisher,
    subnets) to *reference* (resource ID, name, principal ID, audience, caller
    mappings). Update `environments/schema.json`, the three example profiles,
    and `tests/github/New-SyntheticProfile.ps1`.
11. Update `scripts/github/Environment.psm1` and `scripts/github/Gateway.psm1`
    validators to match the new shape.
12. Fill `test.example.json` and `prod.example.json` — both currently ship
    `"sku": null, "capacity": null`.
13. **GitHub Actions:** a new platform-APIM workflow (manual dispatch,
    per-subscription, infrequent) alongside the existing landing zone
    `deploy-environment.yml` / `deploy-environment-reusable.yml`. OIDC
    federated credentials, no service principal secrets. `oidc-probe.yml`
    already exists as a connectivity check.
14. Docs: deployment order is now **gateway once per subscription, then landing
    zone many times**. Update `README.md`, `CHANGELOG.md`, and the relevant
    `docs/` runbook.

## Local verification strategy

The existing `bicep-validate.yml` harness already runs offline and should be
extended rather than replaced: Copilot asset validation, `bicep build` + size
gate, `bicep lint`, six contract tests, deterministic preflight tests,
PowerShell code style, and `Test-GitHubEnvironment.ps1` covering environment,
bootstrap, gateway, completion and delivery.

### Tier 1 — fully offline, no Azure, no credentials

Everything here can and should be green before handoff.

| Check | Command |
| --- | --- |
| Compile both templates | `az bicep build --file main.bicep` and the new platform template |
| Lint | `az bicep lint --file <template>` |
| Compiled size gate | `pwsh ./scripts/Measure-MainJsonSize.ps1` + its test |
| Contract tests | `pwsh ./tests/contracts/Test-*.ps1` |
| Preflight logic | `pwsh ./tests/scripts/Invoke-PreflightChecks.Tests.ps1` |
| Profile/validator/gateway tests | `pwsh ./scripts/github/Test-GitHubEnvironment.ps1 -TemplatePath ./main.json` |
| Synthetic profiles | `tests/github/New-SyntheticProfile.ps1` (offline fixtures) |
| Copilot assets | `pwsh ./.github/scripts/Validate-CopilotAssets.ps1` |

**New tests to add in this work:**

- A contract test asserting the landing zone creates **no** APIM service when
  `existingApiManagementResourceId` is supplied.
- A contract test asserting the integration subnet and NSG are **not** created
  on the BYO path.
- A collision test asserting two different landing-zone identities produce
  distinct API names, paths, backend names and named values (Phase 3).
- A cross-RG scope test asserting APIM children target the gateway's resource
  group.

**Workflow testing (new tooling to add):**

- `actionlint` — static analysis of workflow YAML. Fast, offline, no Docker.
  Not currently in the repo; `tests/github/Workflows.Tests.ps1` exists and can
  call it.
- `act` (nektos/act) — runs workflows locally in Docker. **Note: as of
  September 2026 there is no official GitHub-native local runner.** `act` is
  community tooling and is the standard option; `gh extension install
  nektos/gh-act` wraps it in the GitHub CLI.

  `act` validates the workflow *plumbing* — job graph, inputs, matrix,
  conditionals, step wiring. It **cannot** authenticate to Azure, so deployment
  jobs will fail at the login step. That is expected and still useful.

### Tier 2 — requires Azure auth, creates nothing

`az deployment group what-if` and `azd provision --preview` are read-only: they
perform no writes and create no resources, but they are **not offline** — they
need an authenticated session, an existing resource group, and read access.

If a subscription with read access can be obtained, this is the highest-value
check available before handoff, because it is the only thing that exercises the
real ARM resource graph. Treat the output as directional: ARM what-if has known
fidelity limits on some resource types, and it is evidence, never authorization
to deploy.

### Tier 3 — cannot be verified without a real deployment

State these plainly to the customer rather than implying coverage:

- APIM provisioning actually succeeding on the delegated subnet
- Private DNS resolution from a spoke to the shared gateway
- Cross-RG child-resource deployment into the platform gateway
- Managed-identity role assignments actually working end to end, including
  RBAC propagation delay
- Zone redundancy actually applied on Premium v2
- The network path from the platform VNet to each spoke's Foundry private
  endpoint

This last group is where classic deployment failures live. A green compile
proves the template is well-formed; it proves nothing about Azure behaviour.

## Risks and open items

1. **Name collision (Phase 3)** — a correctness bug, not a nice-to-have. Must
   land before any multi-landing-zone subscription.
2. **Network path** — the shared gateway's outbound subnet sits in the platform
   VNet; each Foundry private endpoint sits in its spoke. This requires peering
   plus resolution of the spoke's privatelink zones from the platform VNet. The
   customer's existing hub variables and BYO private DNS zone IDs should cover
   it — **confirm explicitly, do not assume**.
3. **Region capacity** — confirm Standard v2 and Premium v2 availability and
   quota in the target regions before deploying.
4. **Cost** — ~$700/month per Standard v2 gateway, ~$2,800/month per Premium v2
   unit at public retail. Customer has been briefed and expects this.
5. **Two unverified Developer-tier items** carried over from the companion doc
   (OpenAI v1 spec import, realtime/WebRTC). Both are moot under Standard v2 /
   Premium v2, so they no longer block anything.
6. **WorkIQ was unavailable** during analysis (MSAL token-cache identity
   mismatch), so Teams/mail history was not searched for prior art.

## Explicitly out of scope

- Sandbox environment configuration (isolated CI/CD, separate effort)
- Developer SKU support
- Any remote write: no `git push`, no PR, no Azure resource creation
