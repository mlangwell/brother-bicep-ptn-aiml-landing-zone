# ADR-002: One API Management gateway, two input surfaces, firewall-bounded ingress

- Status: proposed (review by the owners of both merged changes in PR #1)
- Date: 2026-09-23
- Owners: AI Landing Zone maintainers
- Related issue or pull request: PR #1 (`feature/apim-platform-separation`),
  PR #2 (merged), [ADR-001](001-api-management-in-spoke.md),
  [classic VNet injection](2026-09-22-apim-classic-vnet-injection.md)

## Context

Two independently written API Management (APIM) gateways met when `main` was
merged into `feature/apim-platform-separation`.

- **`main` (PR #2, ADR-001)** added an opt-in Developer gateway. It uses a local
  module, a firewall-only NSG and a dedicated route table that carries the
  required `ApiManagement -> Internet` route. It is driven by flat
  `apiManagement*` parameters, `Deploy-AilzIntegrated.ps1` switches and
  preflight checks.
- **The branch** added the Azure Verified Module (AVM) wrapper. It supports
  Developer and Premium, a per-landing-zone workload API with token limits, an
  optional shared platform gateway, and a GitHub environment pipeline driven by
  a structured `apiManagementConfiguration` object.

Git reported only two conflicts. The automatic merge also produced duplicate
declarations that fail compilation, and several defects that compile cleanly
but fail at deployment or runtime:

1. The branch put the injection subnet on the shared spoke route table. That
   table sends 0.0.0.0/0 to the hub firewall with no `ApiManagement` exception.
   Learn: "When the traffic is force tunneled, the responses won't symmetrically
   map back ... connectivity to the management endpoint is lost."
2. The branch module typed `environmentName` as `'dev' | 'test' | 'prod'`.
   ARM would reject any other azd environment name, for example `ailz-dev`.
3. The workload policy rejected every request whose
   `context.Request.PrivateEndpointConnection` was null. Learn documents that
   value as "`null` if request doesn't come from a private endpoint connection".
   Classic injected tiers cannot have a private endpoint, so every request
   returned 403.
4. `Deployment.psm1` derived `initialProvisioning` from private endpoint state,
   while `Gateway.psm1` derived it from `provisioningState`.
   `Invoke-EnvironmentDeployment.ps1` rejects any disagreement between the two,
   so every pipeline redeploy after the first would fail.
5. The default hub-firewall allow-list was `EgressNextHopIp/32`, the firewall's
   frontend IP. After DNAT, Azure Firewall presents a *back-end instance* IP.
   The Architecture Center Firewall-only walkthrough shows a source of
   `192.168.100.7`, and the Firewall FAQ says SNAT uses "one of the firewall
   private IP addresses in AzureFirewallSubnet". Network rules to RFC 1918
   destinations are not SNAT'd at all, while application rules always are.

The GitHub pipeline's enforced first-deployment contract is also relevant. It
uses an administrator-prepared spoke: `useExistingVNet=true` and
`deploySubnets=false`, with an existing route table and no egress next hop.

## Prioritized characteristics

| Characteristic | Priority | Measure |
| --- | --- | --- |
| Deployability | 1 | `Deploy-AilzIntegrated.ps1 -DeployApiManagement` and the structured gateway configuration both deploy and serve traffic in a live, throwaway hub/spoke proof |
| Compatibility | 2 | `tests/github/Compatibility.Tests.ps1` passes against a baseline regenerated from `origin/main` (99c048e); the flat parameters and script switches keep their names and meaning |
| Network isolation | 3 | Gateway ingress enters the spoke only through the hub firewall or from named in-spoke subnets; the injection-subnet NSG rules are asserted structurally |
| No drift | 4 | One gateway module and one NSG rule set serve every creation path; both contract tests pass |
| Azure limits and cost | 5 | 64 outputs (the ARM cap) with none added; compacted `main.json` 2.978 MB against the 4 MB template limit; Developer remains the default tier |

## Alternatives considered

### A. The AVM wrapper serves both input surfaces (selected)

Keep the branch module and put `main`'s network pieces in front of it:
- the dedicated route table and routes;
- the subnet name and prefix parameters;
- the explicit name override;
- the topology gate;
- the preflight checks.

The flat parameters deploy the gateway alone. The structured object adds the
workload API. This keeps every capability from both changes and needs one
module interface change, covered below.

ADR-001 chose a local module because the AVM expansion failed the
*uncompacted* 5 MB size gate. The size gate now measures the compacted
deployment artifact, which is 2.978 MB, so that reason no longer holds.

### B. Port the workload API into `main`'s local module

This keeps ADR-001's module, but it re-implements Premium, the public IP for
zone redundancy, the shared platform gateway and the workload children in a
second module family. Two implementations of one resource would drift.

### C. Keep both implementations side by side

This does not compile: both declare the same symbolic names. Renaming one to
work around that would deploy two gateways, or none, depending on which flags
are set.

### Do not change

The merge result does not compile. Even the branch alone has the forced
tunnelling deploy blocker and the 403 policy defect.

## Decision

Adopt option A with these rules.

1. **Implementation.** `modules/api-management/main.bicep`, the AVM wrapper
   `br/public:avm/res/api-management/service:0.14.4`, is the only gateway
   module. The service is configured by `sku`, `capacity`, `publisherEmail` and
   `publisherName`. `workloadConfiguration` (a `gatewayConfiguration`, or null)
   adds the workload API and the backend and telemetry role assignments. When
   it is null the gateway is deployed alone. `environmentName` is a plain
   string.
2. **Input precedence.** A non-empty `apiManagementConfiguration` selects the
   SKU and capacity, adds the workload API, and its publisher and
   integration-subnet fields take precedence over the flat parameters. An empty
   object deploys the gateway from the flat parameters only.
3. **Topology gate (hybrid).** The template creates a gateway only in the
   ailz-integrated, network-isolated topology with a hub VNet and no local
   firewall, and in one of two shapes:
   - **New spoke.** The template owns the injection subnet, its NSG and a
     dedicated route table. This requires a hub egress next hop and no
     platform-owned route table. It is the `Deploy-AilzIntegrated.ps1` path.
   - **Prepared spoke:** `useExistingVNet=true` with `deploySubnets=false`. An
     operator owns the subnet, its NSG and its route table. The rule set in
     `modules/networking/api-management-injection-nsg.bicep` and the
     `ApiManagement -> Internet` route are documented obligations. This is the
     GitHub pipeline path.

   Updating subnets in an existing VNet (`useExistingVNet=true` with
   `deploySubnets=true`) is not supported for API Management. Preflight mirrors
   the gate. `existingApiManagementResourceId` still binds to a platform-owned
   gateway, and the workload children then deploy only when a configuration is
   supplied.
4. **Ingress (model B: firewall at the spoke boundary, NSG inside it).** The
   shared rule set keeps its nine base rules. When hub firewall sources are
   supplied it adds:
   - `AllowHttpsFromHubFirewall`: TCP 443 from the supplied CIDRs;
   - `AllowHttpsFromLandingZoneCallers`: TCP 443 from named in-spoke subnets;
   - `AllowRateLimitSyncInbound`: UDP 4290 within the injection subnet;
   - `DenyAllInbound` at priority 4096.

   The landing-zone entry point `modules/networking/api-management-nsg.bicep`
   requires at least one firewall source, keeping ADR-001's fail-closed
   contract. When `enableDeveloperExperience` is true, the Container Apps
   environment subnet is added automatically as a direct caller. The platform
   gateway path passes no sources and keeps its current rules for now.
   - Learn recommends NSGs for segmentation inside a VNet: "The recommended
     method for internal network segmentation is to use Network Security Groups,
     which don't require UDRs."
   - `DenyAllInbound` overrides AllowVnetInBound. Learn lists
     `VirtualNetwork <-> VirtualNetwork` UDP 4290 for syncing rate-limit
     counters between units, so the sync rule restores it for multi-unit
     Premium.
5. **Default ingress sources.** `Deploy-AilzIntegrated.ps1 -DeployApiManagement`
   without explicit sources now defaults to the hub VNet's AzureFirewallSubnet
   prefix. It falls back to `EgressNextHopIp/32` with a warning when no
   AzureFirewallSubnet is readable, for example with an NVA. Explicit
   `-ApiManagementIngressSourceAddressPrefixes` and
   `AdditionalEnvironmentVariables` still take precedence.
6. **Routing.** The new-spoke injection subnet uses `main`'s dedicated route
   table: 0.0.0.0/0 to the hub egress next hop, plus `ApiManagement -> Internet`.
   It also carries service endpoints for Storage, Sql, KeyVault and EventHub,
   which Learn strongly recommends for force-tunnelled injection subnets. The
   gateway waits for both routes before injecting.
7. **Ownership marker.** The `ailz-managed-by` tag is `github-dev-environment`
   only when a structured configuration is supplied, and `ai-landing-zone`
   otherwise. This preserves the pipeline's refusal to adopt gateways it did not
   create.
8. **Defect fixes.** The policy no longer requires a private endpoint
   connection; it admits only mapped callers. Both pipeline planners derive
   `initialProvisioning` from `provisioningState`.

## Consequences

- Positive:
  - Both shipped entry points deploy the same gateway.
  - The branch's deploy blocker and the two runtime and pipeline defects are
    removed.
  - Ingress is bounded by the hub firewall, with an explicit and reviewable
    in-spoke exception.
- Negative:
  - The hub platform team must deliver SNAT'd gateway traffic, through an
    application rule on the gateway FQDN or private-IP DNAT, which the Firewall
    FAQ still labels "(preview)".
  - The hub team must also publish DNS consistent with the chosen pattern:
    clients resolve the VIP for routed traffic, or the firewall listener for
    DNAT.
  - Routed network-rule traffic keeps the client source and is denied by
    design.
- Neutral:
  - The template still adds no outputs; the root template stays at the 64-output
    cap.
  - Premium, the shared platform gateway, the developer application and the
    GitHub pipeline itself are not covered by the live proof.

## Compatibility and migration

- **Flat contract unchanged:**
  - `deployApiManagement`, `apiManagementPublisherEmail`,
    `apiManagementPublisherName`, `apiManagementIngressSourceAddressPrefixes`,
    `apiManagementSubnetName`, `apiManagementSubnetPrefix`,
    `apiManagementName` and their azd bindings;
  - the script switches.
- **Additive:** `apiManagementDirectCallerAddressPrefixes`
  (`API_MANAGEMENT_DIRECT_CALLER_ADDRESS_PREFIXES`), with a default of none.
- **Default change:** the script's ingress default changes from
  `EgressNextHopIp/32` to the hub AzureFirewallSubnet prefix. The owner of the
  script should review this in PR #1.
- **Existing gateways created from `main` (ADR-001)** are updated in place on
  their next deployment:
  - two NSG rule renames (`AllowApiManagementControlPlane` becomes
    `AllowApiManagementControlPlaneInbound`, and
    `AllowAzureLoadBalancerHealthProbe` becomes
    `AllowAzureLoadBalancerInbound`);
  - seven explicit outbound allows and the UDP 4290 rule are added;
  - service endpoints are added to the injection subnet;
  - tags change;
  - a new diagnostic setting is created. The ADR-001 setting
    `send-to-log-analytics` is left in place; delete it after the update to
    avoid duplicate ingestion.
- **Branch-internal changes:**
  - the module interface changes (`configuration` is replaced by service
    settings plus a nullable `workloadConfiguration`);
  - the BYO VNet with `deploySubnets=true` path for a created gateway is
    dropped;
  - the gateway outputs are now empty unless a gateway is bound and the
    workload API is configured.

## Security and identity

- The gateway keeps its system-assigned identity. It receives the backend
  inference and telemetry roles only when it serves the workload API.
- `publicNetworkAccess` stays `Enabled`, the only value Azure permits on an
  injected instance. The public VIP serves control plane 3443, restricted by
  the NSG to the `ApiManagement` service tag.
- Data-plane privacy comes from Internal mode and the NSG, not from a private
  endpoint. The policy therefore authenticates with Entra through
  `validate-azure-ad-token` and admits only mapped callers.
- DNS uses a service-scoped `<name>.azure-api.net` zone. Learn: "Do not create a
  Private DNS zone or forward lookup zone for `azure-api.net`."
- No secrets are added.

## Adoption and rollback

- **Order:**
  1. Merge `origin/main` (79ac338).
  2. Apply the script and preflight alignment.
  3. Apply the defect fixes.
  4. Remove the assets `main` removed.
  5. Update the documentation.
  6. Run local validation.
  7. Run the live proof.
- **Rollback:** revert the commits, or return the branch to `304fc54`. A
  deployed gateway stays deployed after rollback, because ARM incremental mode
  does not delete. Remove it through an approved cleanup: export any
  data-plane configuration, delete the service, purge the soft-deleted instance,
  then remove the subnet, NSG and route table.

## Compliance verification

- `az bicep build` and `az bicep lint` with Bicep 0.42.1. No new warnings
  against either baseline.
- `pwsh ./scripts/Measure-MainJsonSize.ps1`: compacted 2.978 MB.
- `pwsh ./tests/contracts/Test-ApiManagementClassicInjectionContract.ps1`:
  structural NSG rules, fail-closed entry point, dedicated route table,
  service endpoints.
- `pwsh ./tests/contracts/Test-ApiManagementWorkloadIsolationContract.ps1`.
- `pwsh ./scripts/github/Test-GitHubEnvironment.ps1 -TemplatePath ./main.json`:
  13 suites. These include the regenerated compatibility baseline, the classic
  settled planner state and a policy guard against private endpoint coupling.
- `npm test`, the full local gate.
- Preflight run offline across four scenarios: new spoke, prepared spoke, BYO
  VNet with subnets, and invalid lists.
- The live proof in a throwaway hub/spoke, deleted immediately afterwards:
  - control-plane network status;
  - direct in-spoke access denied;
  - firewall-path access allowed;
  - the post-SNAT source observed in GatewayLogs;
  - the workload API returning 401, 200 and 429.

## Documentation impact

- `README.md`: the API Management section, hub obligations and the preview
  default.
- ADR-001: status.
- `AGENTS.md`: repository map and validation list.
- The PR template and two skill references, which previously pointed at
  `CHANGELOG.md`.
- The public `Azure/AI-Landing-Zones` documentation needs a coordinated update
  if this fork's behaviour is published upstream.

## Addendum: live proof, 2026-09-23

The proof ran its first phase only: the gateway alone, from the flat
parameters, with Developer x1 in a throwaway hub and spoke that were deleted
afterwards. Its phases are not the two deployment passes of
[ADR-003](003-azd-lifecycle-floor-and-ordering.md).

- **Ingress source (decision 4 and 5).** This was settled by changing only the
  source of `AllowHttpsFromHubFirewall`. A jumpbox reached the gateway through
  firewall DNAT with the whole AzureFirewallSubnet (`10.100.0.0/26`), got HTTP
  000 with the frontend IP (`10.100.0.4/32`), and got 200 again once `/26` was
  restored. Azure Firewall presents a back-end instance IP, so the default holds
  and the `EgressNextHopIp/32` fallback cannot work behind Azure Firewall. NSG
  changes took about three minutes to apply.
- **Not verified.** GatewayLogs never showed the post-SNAT source: a gateway
  with no API writes no rows, and the module's own diagnostic setting passes
  `logCategoriesAndGroups: []`, which enables no log category. That setting is
  unchanged and remains an open finding. The second phase, the workload API from
  `apiManagementConfiguration`, was not run, so the Entra audience and the 401,
  200 and 429 checks are still unverified, as are Premium, the shared platform
  gateway, the developer application and the GitHub pipeline.
- **Defects found and their disposition:**
  - The script serialized a single ingress prefix as a JSON string, which
    corrupted the azd environment. Fixed in `9d4349d`.
  - Five NSG rule descriptions exceeded the 140-character ARM limit. Fixed in
    `9d4349d`.
  - azd 1.22.5 cannot carry an array through the quoted `${VAR}` bindings.
    Resolved by an azd floor, with the bindings unchanged
    ([ADR-003](003-azd-lifecycle-floor-and-ordering.md)).
  - The gateway needs the hub-to-spoke peering before it is created. Resolved by
    a two-pass flow that preflight enforces (ADR-003).
  - Teardown was blocked by Search shared private links and an azd crash.
    Resolved by an ordered teardown script and the azd floor (ADR-003).

## Change notes

This repository has no `CHANGELOG.md`; these notes record the change.

- Merged `origin/main` (PR #2) and unified the two gateways. See the Decision
  section.
- Removed the assets `main` removed:
  - seven contract tests and their two fixtures;
  - three `tests/scripts` suites;
  - `CHANGELOG.md`.
- Removed the Terraform parity workflows, `scripts/parity/`, the
  `terraform-parity` agent and skill, and their `package.json` and
  `.gitignore` leftovers.
- CI: removed the steps for deleted tests, added `Deploy-AilzIntegrated.ps1` to
  the path filters, and kept the release bundle and workflow invariants.
- Fixed the policy 403 on classic injection and the pipeline redeploy planner
  disagreement.

## Review trigger

Review this decision:
- when Azure Firewall private-IP DNAT reaches general availability;
- when APIM classic-tier network requirements change;
- when the landing zone adopts a v2 tier;
- when a second in-spoke caller subnet is requested;
- when the platform gateway path adopts firewall-bounded ingress;
- when the compacted template approaches 3.5 MB or the output cap blocks a
  required output.
