# Reroute API Management to classic VNet injection (Developer + Premium)

**Status:** Accepted. Implemented in Bicep and validators; not yet deployed to Azure.
**Date:** 2026-09-22
**Customer:** Brother
**Supersedes:** the tier table, the "Architecture split" network bullets, and
Phase 1 of `docs/adr/2026-09-21-apim-platform-separation-plan.md`
**Companion:** `docs/apim-developer-sku-constraints.md`

## Decision

API Management uses **classic VNet injection in Internal mode** in every
subscription. The v2 tiers are rejected.

| Subscription | Tier | Network model | Zone redundancy |
| --- | --- | --- | --- |
| sandbox | Developer | classic VNet injection, **Internal** | n/a |
| dev | Developer | classic VNet injection, **Internal** | n/a |
| test | Developer | classic VNet injection, **Internal** | n/a |
| prod | **Premium (classic)** | classic VNet injection, **Internal** | automatic (empty zones list) |

The platform-separation decision from the previous ADR is unchanged: one gateway
per subscription, landing zones consume it. Both gateway creation paths — the
platform template and the landing zone's own opt-in path — now produce the same
Internal-mode injected topology, so there is no path that is not private.

## Why the reroute

### 1. Developer and Premium classic are one network model

Microsoft Learn documents them together. Both
[virtual-network-reference](https://learn.microsoft.com/azure/api-management/virtual-network-reference)
and
[virtual-network-injection-resources](https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources)
are headed **"APPLIES TO: Developer | Premium"**, with the same required-ports
table, the same undelegated subnet requirement, and the same internal mode. For
networking purposes Developer is a one-unit Premium.

With production on Premium classic, running Standard v2 in dev/test would have
left every non-production environment rehearsing a topology production never
uses. That is the defect this reroute removes.

### 2. Standard v2 cannot do what is required

Standard v2 supports outbound *integration*, not injection, plus an inbound
private endpoint. That was coherent under the previous plan. It is not the
production topology, and per
[virtual-network-concepts](https://learn.microsoft.com/azure/api-management/virtual-network-concepts)
its gateway, management plane and developer portal "remain publicly accessible
from the internet" unless a private endpoint is added.

Basic v2 was also considered and rejected: it supports neither VNet integration
nor inbound private endpoints, so it cannot reach a private-endpoint-only
Foundry account at all.

### 3. Classic injection and private endpoints are mutually exclusive

[private-endpoint#limitations](https://learn.microsoft.com/azure/api-management/private-endpoint):

> In the classic API Management tiers, private endpoints aren't supported in
> instances injected in an internal or external virtual network.

### 4. Therefore `publicNetworkAccess` can never be `Disabled`

This is the consequence that reshaped the implementation, and it was **not**
anticipated in the previous plan.
[private-endpoint#optionally-disable-public-network-access](https://learn.microsoft.com/azure/api-management/private-endpoint):

> You can disable public network access in API Management instances configured
> with a private endpoint, **not with other networking configurations**.

So `publicNetworkAccess: 'Enabled'` is the *only legal value* on an injected
instance. It is not a weakened posture and not a provisioning concession.

**Inbound privacy comes from Internal mode instead.**
[api-management-using-with-internal-vnet](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet):

> None of the API Management endpoints are registered on the public DNS. The
> endpoints remain inaccessible until you configure DNS for the VNet.

The instance does keep a public VIP, but that VIP is
"[used *only* for control plane traffic to the management endpoint over port
3443](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet#routing)",
and the injection NSG restricts even that to the `ApiManagement` service tag.
The data plane is not reachable from the internet.

### 5. Committing to classic is a one-way door

Learn's v2 FAQ states there is no automated migration from Consumption,
Developer, Basic, Standard or Premium to a v2 tier. This decision is
deliberately hard to reverse, which is why it is recorded here rather than left
implicit in code.

## What changed in the implementation

The private-endpoint consequence (§4) invalidated an entire state machine, not
just a SKU string. The previous design observed
`Absent → PublicPendingPrivateEndpoint → PublicPendingDisable → Private` and
"completed" a deployment by PATCHing `publicNetworkAccess` to `Disabled` after a
private endpoint was approved on both sides. **None of that is reachable on this
topology.**

It was replaced with assertions that are both satisfiable and meaningful:

| Removed (unsatisfiable here) | Replacement |
| --- | --- |
| 4-state public→private machine | `Absent → InterruptedProvisioning → Injected` |
| `Assert-GatewayPrivateEndpoint` | `Assert-GatewayInjection` |
| `Complete-GatewayPrivateAccess` | `Complete-GatewayActivation` |
| PE approved on both sides | `virtualNetworkType` is `Internal` |
| `publicNetworkAccess == 'Disabled'` | attached to the approved undelegated injection subnet |
| — | **no** private endpoint connection exists (negative assertion) |

`initialProvisioning` survives but was redefined. It no longer gates public
network access; it holds the owned stop control on so the gateway serves no
request until the operator has published the private DNS A record.

Other structural changes:

- **Undelegated subnet.** `main.bicep` hardcoded
  `delegation: 'Microsoft.Web/serverFarms'`, correct for v2 and fatal here:
  "The subnet used to connect to the API Management instance shouldn't have any
  delegations enabled."
- **A rule-carrying NSG.** `modules/networking/network-security-group.bicep`
  creates an NSG with **zero rules**, which blocks everything, because "the load
  balancer used internally by API Management is secure by default and rejects
  all inbound traffic." Learn is also explicit that the NSG itself is
  mandatory: "It is required to assign a Network Security Group to your VNet in
  order for the Azure Load Balancer to work." New shared module
  `modules/networking/api-management-injection-nsg.bicep` carries nine rules and
  is consumed by **both** gateway paths so they cannot drift. Those nine are not
  uniformly "required", and the module says so rather than flattening it: seven
  are bold *and* "External & Internal" in the Learn required-ports table
  (`ApiManagement:3443` in, `AzureLoadBalancer:6390` in, `Storage:443`,
  `Sql:1433`, `AzureKeyVault:443`, `AzureMonitor:1886+443`, `Internet:80`);
  `AzureActiveDirectory:443` is marked *optional* there and is required only
  because this workload's inbound policy is `validate-azure-ad-token`; and
  `DNS:53` is absent from the table entirely, coming instead from the separate
  "DNS access" section. The external-mode-only `Internet:80,443` and
  `AzureTrafficManager:443` inbound rules are deliberately absent.
- **Service endpoints on by default.** This landing zone force-tunnels
  `0.0.0.0/0` to a hub firewall, and Learn "strongly recommend[s] enabling
  service endpoints directly from the API Management subnet to dependent
  services such as Azure SQL and Azure Storage".
- **DNS contract changed shape.** From `privatelink.azure-api.net` to a
  service-scoped `<gateway-name>.azure-api.net` zone holding an apex `@` A
  record. A private zone for the bare apex `azure-api.net` is explicitly
  forbidden by Learn — it is a shared public Azure domain and an apex private
  zone breaks resolution for other Azure services.
- **Zone redundancy is explicit.** AVM `avm/res/api-management/service` 0.14.4
  defaults `availabilityZones` to `[1,2,3]`, which is *manual* zone selection and
  requires capacity to be an exact multiple of the zone count — so Premium at
  capacity 1 would fail. Both templates now pass `[]` explicitly, selecting
  automatic zone redundancy.
- **`subnets.bicep` forwarded only `serviceEndpoints[0]`.** Fixed to map all
  entries; the injection subnet needs four.

## Operator obligations this template cannot discharge

These are surfaced in the `facts.operatorObligations` output of both gateway
templates, because a deployment can be entirely healthy and still unreachable:

1. **Create the private DNS A record.** Internal mode registers nothing on
   public DNS. The private VIP is assigned dynamically and is "impossible to
   anticipate … prior to its deployment", so it is emitted as the
   `gatewayPrivateIpAddress` output rather than guessed.
2. **Never create a zone for the apex `azure-api.net`.**
3. **Configure custom VNet DNS servers *before* deploying**, or every later DNS
   change requires an Apply Network Configuration call.
4. **Add a UDR for the `ApiManagement` service tag with next hop `Internet`** if
   the subnet is force-tunnelled, or control-plane responses cannot map back
   symmetrically and deployment fails. Learn states this bypass "isn't
   considered a significant security risk".
5. **Open the outbound dependencies on the hub firewall** — an NSG rule alone is
   not sufficient when egress is tunnelled.
6. **Peer and resolve both directions** — the gateway must resolve each spoke's
   Foundry privatelink zones; each spoke must resolve the gateway hostname.

## Consequences

**Accepted:**

- Developer carries **no SLA**, is capped at one unit, and has no availability
  zones or autoscale. Acceptable for sandbox/dev/test, disqualifying for
  production — which is why production is Premium.
- Developer's gateway limit of **1,024 concurrent backend connections** per HTTP
  authority is the ceiling most likely to bite a streaming inference workload
  before any other.
- No migration path to v2 (§5).
- Production zone redundancy is only meaningful at **≥2 units**, which roughly
  doubles production cost. Unit count is still open — see below.

**Gained:**

- One topology across all four subscriptions; dev/test genuinely rehearse
  production.
- Roughly 1/14th the per-unit cost of Standard v2 in non-production.
- Private inbound *and* private egress to a private-endpoint-only Foundry
  account, which Basic v2 cannot do at all.

## Verification status

**Tier 1 (offline) only.** No Azure subscription was available. All of the
following are green:

- `az bicep build` / `az bicep lint` on `main.bicep` and both platform templates
- compiled size gate (2.963 MB against a 3.5 MB working budget)
- `Test-ApiManagementWorkloadIsolationContract.ps1`
- `Test-ApiManagementClassicInjectionContract.ps1` (new; mutation-verified —
  reverting to External mode produces 4 failures, reintroducing a private
  endpoint produces 1). The NSG assertions parse the **compiled ARM body** and
  bind tag, port and direction per rule, rather than grepping the Bicep source.
  That rewrite was forced by a failed mutation round: the original text-grep
  form survived widening the 3443 inbound source tag to `*`, flipping that rule
  to `Outbound`, and adding an inbound `*` → `VirtualNetwork:443` rule, because
  it could not bind a tag to the same rule as a port. All four of those
  mutations, plus deleting a required rule, now fail the contract. The public IP
  assertions are mutation-verified the same way (dropping the public IP from the
  gateway, `Standard`→`Basic`, `Static`→`Dynamic`, and dropping zone
  pass-through all fail).
- `Invoke-PreflightChecks.Tests.ps1` — 73 tests
- `Test-GitHubEnvironment.ps1` — 13 suites
- `Validate-CopilotAssets.ps1`

**A green local run proves the templates are well-formed. It proves nothing
about Azure behaviour.** Specifically unverified: that APIM actually provisions
on the undelegated subnet with these NSG rules; that the `ApiManagement` UDR
bypass is correctly configured on the hub route table; that private DNS resolves
from a spoke to the gateway; that the gateway reaches the Foundry private
endpoint; and that Premium automatic zone redundancy applies as expected.

### Known coverage gap: the NSG is not inspected at runtime

Worth stating plainly, because the previous design did not have this gap. Under
Standard v2 the public-access control was a **service property**
(`publicNetworkAccess: 'Disabled'`) that Azure enforced itself, regardless of
any NSG. Under classic injection the control of the public VIP **is the NSG** —
there is no service-level equivalent, since `publicNetworkAccess` cannot be
`Disabled` on an injected instance at all (§4).

`Assert-GatewayInjection` checks `virtualNetworkType`, subnet identity and the
absence of a private endpoint. **Nothing — offline or at runtime — reads the
injection subnet's NSG or its rules.** So a gateway whose subnet NSG was widened
out of band, or which was deployed onto an operator-owned subnet carrying the
wrong rules, passes every check this repository performs.

**Accepted, with the mitigation named rather than implied.** The
infrastructure-as-code path is covered: the rule set is a single shared module
consumed by both gateway paths, and the mutation-verified contract test above
fails on exactly the widenings that would matter. What is *not* covered is drift
introduced outside this template, and the `deploySubnets: false` BYO-subnet case
where the operator owns the NSG entirely — see the `injectionNsgManaged` gateway
fact, which reports which side owns it.

Closing this at runtime would mean adding subnet → NSG → rule ARM reads to
`Gateway.psm1`, widening its transport contract. That is deliberately deferred,
not overlooked. Until it is done, **Azure Policy or equivalent drift detection on
the injection subnet's NSG is the operator's control, not this template's.**

## Open items

1. **Production unit count.** Learn recommends ≥2 units for zone redundancy to
   be meaningful. Currently unpriced and undecided.
2. **Region capacity.** Confirm Developer and Premium classic availability and
   quota in the target regions before any deployment.
3. **Network path confirmation with Brother** — peering plus bidirectional DNS
   resolution between the platform VNet and each spoke.
4. **Two Developer-tier items remain unverified** (OpenAI v1 spec import,
   realtime/WebRTC). Neither is used by this landing zone's single
   `POST /v1/responses` operation, but they are no longer moot the way they were
   under Standard v2. See the companion doc.

## A note on AVM 0.14.4

The module's own `subnetResourceId` description claims the subnet "must be
delegated to the required service: `Microsoft.Web/serverFarms` for External
virtualNetworkType, `Microsoft.Web/hostingEnvironments` for Internal
virtualNetworkType."

**That description contradicts Learn for classic injection**, which requires
delegation to be `None`. It is a doc string only — the module emits no
delegation, it simply passes `subnetResourceId` into
`virtualNetworkConfiguration` — so it does not affect deployed behaviour. It is
recorded here because it will otherwise mislead the next engineer who reads the
AVM parameter reference.
