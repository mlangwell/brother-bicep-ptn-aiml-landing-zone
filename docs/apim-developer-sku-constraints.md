# APIM Developer SKU — what works, what does not, and what it costs

Reference notes for the opt-in inference gateway (`deployApiManagement`). This
records why the gateway module pins `sku` to a closed set, what changes if the
Developer tier is added, and which claims are verified against Microsoft Learn
versus still unproven.

All Learn citations were re-read on **2026-09-21**. Public retail prices are
estimates, not a quote.

## Why Developer tier comes up at all

Cost. Public retail, `eastus`, USD, fetched 2026-09-21 from the Azure Retail
Prices API:

| Tier | Unit price | ≈ Monthly (730 h) |
| --- | --- | --- |
| Developer | $0.0658 / h | **~$48** |
| Basic v2 | $0.20548 / h | ~$150 |
| Standard v2 | $0.9589 / h | **~$700** |
| Premium v2 | $3.83562 / h | ~$2,800 |

Developer is roughly **1/14th** the cost of Standard v2.

## The topology constraint

The module originally implemented the **Standard v2** shape: outbound VNet
integration into a `Microsoft.Web/serverFarms`-delegated subnet, plus an inbound
private endpoint, then `publicNetworkAccess: 'Disabled'`. **That shape has since
been replaced** by classic VNet injection in Internal mode — see
`docs/adr/2026-09-22-apim-classic-vnet-injection.md`. The analysis below is what
drove that reroute.

Developer cannot do that shape. From the
[tier feature comparison](https://learn.microsoft.com/azure/api-management/api-management-features):

| Capability | Developer | Standard v2 | Premium v2 |
| --- | --- | --- | --- |
| Deploy (inject) service in virtual network | ✔️ | ❌ | ✔️ |
| Connect to backends isolated in virtual network | ✔️ | ✔️ | ✔️ |
| Private endpoint support for inbound connections | ✔️ | ✔️ | ✔️ |

Developer supports injection *and* private endpoints — but
[not both at once](https://learn.microsoft.com/azure/api-management/private-endpoint):

> In the classic API Management tiers, private endpoints aren't supported in
> instances injected in an internal or external virtual network.

and, in the prerequisites:

> When using an instance in the classic Developer or Premium tier, don't deploy
> (inject) the instance into an external or internal virtual network.

So the Developer options are mutually exclusive:

- **Private endpoint, no injection** — private inbound, but the gateway has no
  VNet egress and therefore cannot reach a private-endpoint-only Foundry
  account. Not viable here.
- **Internal VNet injection, no private endpoint** — private inbound via the
  internal load balancer and private egress to Foundry. **This is the only
  viable Developer topology for this landing zone.**

Two consequences of choosing internal injection:

- The injection subnet **must not be delegated**
  ([network resource requirements](https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources)):
  "The subnet … shouldn't have any delegations enabled." `main.bicep` currently
  hardcodes `delegation: 'Microsoft.Web/serverFarms'`.
- The subnet NSG **must explicitly allow inbound**, because "the load balancer
  used internally by API Management is secure by default and rejects all inbound
  traffic." The shared `modules/networking/network-security-group.bicep` creates
  an NSG with **no rules**, which is fine for v2 integration and fatal for
  injection. Injection needs at minimum `3443` inbound from the `ApiManagement`
  service tag, `6390` inbound from `AzureLoadBalancer`, and outbound to
  `Storage`, `Sql`, `AzureKeyVault` and `AzureMonitor`.
- `publicNetworkAccess` **cannot** be set to `Disabled`, because disabling it
  requires a private endpoint. Privacy comes from the ILB instead: in internal
  mode "none of the API Management endpoints are registered on the public DNS."
  A public IP resource is no longer required for internal mode (since May 2024).

## ⚠️ Do not copy the apex DNS pattern from `ai-foundry-deployment-options`

`options-infra/modules/apim/apim-dns.bicep` in that repo creates a Private DNS
zone for the **apex** domain `azure-api.net`. Microsoft Learn explicitly calls
this out as unsupported
([internal VNet mode](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet)):

> Creating a Private DNS zone or authoritative forward lookup zone for the apex
> domain (`azure-api.net`) is not supported and can introduce unintended
> resolution failures.
>
> **Do not create a Private DNS zone or forward lookup zone for `azure-api.net`.**

Because `azure-api.net` is a publicly owned Azure domain shared by multiple
services, an apex private zone becomes authoritative inside the VNet, Azure's
public records stop resolving, and other services depending on
`*.azure-api.net` can fail.

**Supported approach** — scope the zone to the exact service FQDN:

> Create DNS records for the full FQDNs only … If you use Azure Private DNS,
> create a zone that's scoped to the specific service FQDN, not the apex public
> domain.

For this landing zone only the gateway hostname is needed, so the correct shape
is a private DNS zone named `<apim-name>.azure-api.net` holding an apex (`@`) A
record pointing at the APIM private VIP. The private VIP is assigned
dynamically and "impossible to anticipate … prior to its deployment", but it is
readable from the deployed resource as
`properties.privateIPAddresses[0]`, so it can be wired in the same deployment.

Note also: APIM "responds only to requests addressed to its configured host
names and does not listen directly on its private IP address" — so a correct
Host header / FQDN is mandatory; an IP-literal call will not work.

## What Developer cannot do — full list

From the [tier feature comparison](https://learn.microsoft.com/azure/api-management/api-management-features)
(the tier table is authoritative; ❌ = unavailable on Developer):

| Feature | Developer |
| --- | --- |
| Multi-region deployment | ❌ (Premium only) |
| Availability zones | ❌ (Premium / Premium v2 only) |
| Autoscaling | ❌ |
| Workspaces | ❌ |
| Scale units | **1** — cannot add or remove units |
| Built-in cache | **10 MB** (Standard v2 1 GB, Premium 5 GB) |
| SLA | **None** |

Learn states plainly: "The Developer tier is for non-production use cases and
evaluations. It doesn't offer SLA," and "The Developer tier should be used to
evaluate the service; it shouldn't be used for production."

Resource limits (post-March-2026 limits, per service instance —
[service limits](https://learn.microsoft.com/azure/api-management/service-limits)):

| Entity | Developer | Standard v2 | Premium v2 |
| --- | --- | --- | --- |
| API operations | 3,000 | 50,000 | 75,000 |
| Named values | 5,000 | 10,000 | 18,000 |
| Loggers | 100 | 200 | 400 |
| Products | 100 | 500 | 2,000 |
| Subscriptions | 10,000 | 25,000 | 75,000 |

Gateway runtime limits: concurrent backend connections per HTTP authority are
**1,024 in the Developer tier**, versus 2,048 per unit elsewhere. For a gateway
fanning out long-lived streaming completions to Foundry this is the ceiling most
likely to bite before any other.

## AI / OpenAI-specific capability check

| Capability | Developer | Evidence |
| --- | --- | --- |
| `llm-token-limit` policy | ✔️ Supported | "APPLIES TO: Developer \| Basic \| Basic v2 \| Standard \| Standard v2 \| Premium \| Premium v2" |
| `llm-emit-token-metric` policy | ✔️ Supported | same applies-to banner |
| `llm-semantic-cache-lookup` / `-store` | ✔️ "All API Management tiers" — **but requires an external cache** (Redis). The 10 MB built-in cache is not usable for this. |
| Entra token validation (`validate-azure-ad-token`) | ✔️ Microsoft Entra integration is ✔️ on Developer |
| Application Insights + Log Analytics request logs | ✔️ Both ✔️ on Developer |
| Backup and restore | ✔️ (✔️ on Developer; ❌ on Standard v2 / Premium v2) |
| Static IP | ✔️ (❌ on Standard v2 / Premium v2) |
| Full OpenAI **v1** API spec import | ⚠️ **Unverified — see below** |
| Realtime WebRTC / WebSocket API | ⚠️ **Unverified — see below** |

### The two unverified items

`ai-foundry-deployment-options` gates both the full OpenAI v1 API and the
realtime WebRTC API to `Premium` / `StandardV2` / `Premiumv2`, with this comment:

> OpenAI v1 API has more than 100 Operations and requires Premium, Premiumv2, or
> StandardV2 SKU

That gate appears to **predate the March 2026 limits change**. In the current
published limits there is no per-API operation cap in the classic/v2 tier table
at all — the only remaining `Operations per API | 100` row sits in the
**workspaces** table, which does not apply here. Developer's service-wide cap is
3,000 API operations.

**Treat this as unresolved.** The gate may simply be stale, or there may be an
undocumented per-API cap still enforced. It has not been tested on a live
Developer instance, and the linked Learn anchor
(`#limits---api-management-v2-tiers`) no longer exists under that name. Verify
empirically before relying on either capability on Developer.

Unrelated but worth flagging upstream: that repo's SKU gate is
`contains(['Premium', 'StandardV2', 'Premiumv2'], apimSku)` while its own
`@allowed` list spells the value `Standardv2` (lowercase `v`). Bicep string
comparison in `contains` is case-sensitive, so the gate looks like it never
matches on Standard v2.

## Impact on *this* landing zone specifically

The shipped gateway defines **one** API with **one** operation
(`POST /v1/responses`), uses `llm-token-limit`, an Application Insights logger,
and a system-assigned managed identity against Foundry.

Against that surface, most Developer limits are irrelevant:

- 3,000 API operations — not a constraint at one operation.
- 10 MB built-in cache — no caching policy is configured.
- OpenAI v1 spec / realtime — neither is imported.
- `llm-token-limit` — supported.

What **does** matter:

- **No SLA, one unit, no availability zones, no autoscale.** Acceptable for a
  dev environment; disqualifying for production. Any promotion path must move to
  Standard v2 or Premium v2.
- **`publicNetworkAccess` stays `Enabled`.** This is now implemented. The
  `initialProvisioning` / private-completion sequence asserted a
  PE-then-disable transition that has no meaning on the injected path; it has
  been replaced by `Complete-GatewayActivation`, which verifies Internal mode,
  the approved undelegated injection subnet, and the absence of any private
  endpoint. `initialProvisioning` now only holds the stop control on until the
  operator publishes the DNS A record.
- **1,024 concurrent backend connections.**
- **Profile validators** previously hard-required `privatelink.azure-api.net`
  (`scripts/github/Environment.psm1`, `scripts/github/Gateway.psm1`). They now
  require the service-scoped `<gateway-name>.azure-api.net` zone and reject both
  a privatelink zone and the shared apex `azure-api.net` zone.

The gateway endpoint URL is
`https://<name>.azure-api.net/inference/<workloadKey>/v1/responses`, and in
Internal mode that hostname resolves only inside the VNet, via the private DNS
zone the operator creates.

> **Implementation status (2026-09-22):** the reroute to Developer + Premium
> classic injection is implemented. See
> `docs/adr/2026-09-22-apim-classic-vnet-injection.md`.

## Not checked

Teams chat and mail were **not** searched.

The WorkIQ MCP server is connected but every tool call fails (`ask_work_iq`,
`accept_eula` and `get_debug_link` alike). Running the CLI directly surfaces the
underlying cause:

```
Error: Returned user identifier does not match the sent user identifier
       when saving the token to the cache.
```

This is an MSAL token-cache identity mismatch, not a missing sign-in — client
config is healthy (`defaultAccount=johnhain@microsoft.com`,
`I-accept-EULA=true`, `isMSITTenant=true`), so nothing prompts for credentials;
the failure happens on cache write. Recovery is `workiq logout` followed by a
fresh interactive `workiq ask`.

If the MFG / AI Landing Zone chat contains a worked answer on the two unverified
items above, it is not reflected here.
