# Private text inference gateway (P3)

This is an optional infrastructure module, not a deployed Foundry agent. The
parent must instantiate `main.bicep` only when `deployApiManagement` is true.
Existing consumers retain the parent's default `false`; this module does not
change legacy parameters or direct Foundry outputs.
GitHub environment profiles require an explicit `gateway.name` for state lookup
before preview. Direct Bicep consumers retain the parent's CAF/legacy generated
name fallback. P5 adds observed `initialProvisioning` to the resolved main API
configuration, not the operator profile; the parent passes it separately from
the module's sealed gateway configuration.

The authoritative service/PE ownership contract is the pair
`ailz-managed-by=github-dev-environment` and `ailz-environment=<environment>`,
on the exact approved resource IDs. Both are set by this module and required by
its readers, matching P5. The additional `ailz-owner=ailz-inference-<environment>`
namespace marker is retained; when present it must not contradict the pair.
API/backend descriptions and named-value ownership tags remain namespace-scoped,
so the common pair does not authorize overwriting unrelated child resources.

## Exact Bicep interface

Entry point: `modules\api-management\main.bicep`, resource-group scope.

| Input | Type / default | Contract |
| --- | --- | --- |
| `name` | string, required | Parent-resolved explicit/CAF/legacy APIM name; explicit profile name wins. |
| `location` | string, required | Approved gateway/integration VNet region. |
| `environmentName` | `dev \| test \| prod`, required | Ownership and counter isolation. |
| `tenantId` | string, required | Approved Entra tenant GUID. |
| `configuration` | exported `gatewayConfiguration`, required | Unchanged enabled P1 gateway object. `foundryIntegration=true` is unsupported and rejected. |
| `integrationSubnetResourceId` | string, required | Dedicated **undelegated** injection subnet with the API Management NSG rule set and approved egress/DNS. Never the app/agent subnet. Classic VNet injection forbids subnet delegation. |
| `backendAccountResourceId` | string, required | Verified Foundry account ID. |
| `backendEndpoint` | string, required | Verified account-named HTTPS root on `openai.azure.com` or `services.ai.azure.com`; no path, port, query, credentials or fragment. |
| `applicationInsightsResourceId` | string, required | Existing component; the connection string is read internally, never output. |
| `logAnalyticsWorkspaceResourceId` | string, required | Existing metrics destination; existing private monitoring topology is retained. |
| `tags` | object, `{}` | Merged with the reserved management/environment pair and namespace marker. |
| `initialProvisioning` | bool, `false` | True only for a first or interrupted creation. It does **not** gate public network access — see below — it holds the stop control on until the operator has published the private DNS A record. |

Outputs are `serviceResourceId:string`, `gatewayHostName:string`,
`gatewayPrivateIpAddress:string`, `principalId:string`,
`inferenceEndpoint:string`, `audience:string`, and `facts:object`. `facts` lists
owned IDs, source links, `operatorObligations` and pending operational
requirements, effective `stopNewRequests` and `approvedStopNewRequests`; it does
not assert readiness.

## Network topology: classic VNet injection, Internal mode

This module deploys the gateway with `virtualNetworkType: 'Internal'` into an
**undelegated** subnet, and declares **no private endpoint**. That combination
is required, not preferred:

- Injected classic instances cannot hold a private endpoint. Learn: *"In the
  classic API Management tiers, private endpoints aren't supported in instances
  injected in an internal or external virtual network."*
- Consequently `publicNetworkAccess` can never be `Disabled` here. Learn: *"You
  can disable public network access in API Management instances configured with
  a private endpoint, not with other networking configurations."* The module
  sets `'Enabled'`, which is the only legal value.
- Inbound privacy is delivered by Internal mode instead. Learn: *"None of the
  API Management endpoints are registered on the public DNS."* The instance
  keeps a public VIP, but it serves control-plane port 3443 only, restricted by
  NSG to the `ApiManagement` service tag.

The injection subnet's NSG must carry explicit rules — a rule-less NSG blocks
the gateway entirely, because *"the load balancer used internally by API
Management is secure by default and rejects all inbound traffic."* Use
`modules/networking/api-management-injection-nsg.bicep`, which is shared with
`platform/api-management/` so the two gateway paths cannot drift.

**Operator obligation:** Internal mode registers nothing on public DNS, so the
gateway is unreachable until a private DNS zone named exactly
`<name>.azure-api.net`, holding an apex `@` A record for the
`gatewayPrivateIpAddress` output, is created and linked to every calling VNet.
Never create a zone for the bare apex `azure-api.net`.

The endpoint is exactly
`https://<name>.azure-api.net/inference/<workloadKey>/v1/responses`. Backend
routing is fixed to `<backendEndpoint>/openai/v1/responses`. There is one `POST`
operation. The API policy is established **before** that callable operation.

The gateway system identity receives `CognitiveServicesOpenAIUser` only on the
provided account and `MonitoringMetricsPublisher` only on the provided Insights
component, through the existing security module and role constants. The parent
must not duplicate these assignments or give ordinary governed callers direct
backend inference/key access.

## Request and telemetry contract

The body must contain an exact configured deployment `model`, a nonblank text
`input` string, and positive integer `max_output_tokens` no larger than the
caller's configured rate and quota. Optional fields are boolean `stream` and
`store:false`; storage is explicitly forced off. The starter body-size contract
is 65,536 UTF-8 bytes. Arrays, images, embeddings, audio/realtime, tools, batch,
background, conversation/previous-response references and every other field are
rejected. Accepted JSON is serialized again before forwarding so duplicate JSON
keys cannot give the validator and backend different model selections.

Entra validation precedes identity lookup. Counters include the validated tenant
and OID, configured environment/project, and exact approved model. Caller
project/model/stop/routing headers do not control these values. The strict header
allow-list rejects unknown headers; known spoof/key headers are removed, backend
`Host` is forced, and correlation is generated by APIM. `X-Forwarded-For` is
normalized to APIM's observed client IP, never used for identity or counters.
APIM does not permit removing its own client-IP portion of that header.

Native `llm-token-limit` has explicit per-caller literals for rate, quota and
period, with prompt estimation enabled. Native and backend 429/403 statuses and
`Retry-After` are not translated. The protected owned named value
`ailz-inference-<environment>-stop` blocks new requests with 503 unless its value
is exactly `false`; no unauthenticated header can resume traffic.
Initial/recovery provisioning forces that named value to `true` regardless of
the profile. Restore the approved profile value only after private completion.
Authentication, exact authorization and native quota policies remain installed
while the stop is active.

Telemetry consists of explicit correlation/caller/project/approved-model,
status/rejection and token metadata traces, plus native `llm-emit-token-metric`
dimensions. There is no prompt/completion/auth-header logging in these policies.
API request/dependency sampling is zero and `alwaysLog` is explicitly null:
automatic URL/error telemetry could otherwise capture a secret in a malicious
query or validation error. Service diagnostics export metrics only. API body
bytes are explicitly zero, header capture is limited to correlation, and client
IP logging is off. Microsoft documents that `trace` is independent of sampling.
Custom token metrics require the existing Insights component's **custom metrics
with dimensions** setting; this separate operational prerequisite is output,
not falsely automated as native Foundry integration.

Privileged APIM debug tracing can expose content independently of these defaults.
Governed users/workloads/runners must not receive debug-credential, policy-write,
key-list or equivalent control-plane permissions.

## Parent orchestration and safe reruns

`scripts\github\Gateway.psm1` exports:

```text
Assert-GatewayConfiguration
  -Profile IDictionary -ServiceName string
  -BackendAccountResourceId string -BackendEndpoint string [-AllowSynthetic]
Get-GatewayDeploymentPlan
  -ServiceResourceId string -EnvironmentName dev|test|prod -WorkloadKey string
  -Request scriptblock [-InjectionSubnetResourceId string]
Assert-GatewayDeploymentPlan -Plan IDictionary -Request scriptblock
Complete-GatewayActivation
  -Plan IDictionary -Request scriptblock
  [-Apply] [-StopNewRequests bool] [-WhatIf]
  [-MaxAttempts 60] [-RetryDelaySeconds 10]
```

The mandatory parent-supplied authenticated ARM transport takes positional
`(method, absoluteUri, body, headers)` and returns an `IDictionary` containing
`StatusCode:int`, `Body:IDictionary`, and `Headers:IDictionary`. It must bound
network operations and never print credentials or raw response bodies. Preserve
JSON scalar types, including timestamp **strings**, rather than converting them
to PowerShell `DateTime` objects; P1's canonical hasher deliberately rejects
non-JSON types. GET
ETags must be retained: named-value GET deliberately omits values, and its ETag
detects a changed emergency stop without a secret-retrieval POST. No function
implicitly logs in, dispatches, provisions or invokes a model.

`Get-GatewayDeploymentPlan` returns `observedState` as `Absent`,
`InterruptedProvisioning`, or `Injected`. `initialProvisioning` is true only in
the first two states. P4 must require `Injected` and false.

There is **no public-then-private transition on this topology**: an injected
Internal-mode gateway is private from the moment it exists, and
`publicNetworkAccess` can never be `Disabled` because Azure permits that only on
instances holding a private endpoint. The plan therefore asserts the properties
that actually deliver privacy — `virtualNetworkType` is `Internal`, the instance
is attached to an injection subnet (and, when
`-InjectionSubnetResourceId` is supplied, to the *approved* one), and no private
endpoint connection exists.

P4's existing call without `-Apply` and without `-StopNewRequests` stays GET-only
and retains its `VerifiedControlPlane`/`changed=false` result shape, now
reporting `virtualNetworkType: 'Internal'` rather than a public-access state.
An explicitly requested stop reconciliation without `-Apply` returns `Planned`,
never false verification. With `-Apply -StopNewRequests <approved bool>`, the
helper first verifies the injected private topology, then reads and conditionally updates
only `.../namedValues/ailz-inference-<environment>-stop`.

**P5 transport requirement:** permit the documented, nonmutating
`POST <owned-stop-id>/listValue?api-version=2024-05-01` with a null body, only for
this owned nonsecret Boolean, as well as value-only `PATCH <owned-stop-id>` with
`If-Match`. The helper validates metadata before reading the value, compares the
GET/listValue ETags, rechecks private state, and verifies the actual stored
Boolean after updates. Do not broaden this to other named values or secret
references. No raw value/response is logged. Successful explicit reconciliation
adds `stopControlVerified=true` and the actual `stopNewRequests` Boolean; require
both when restoring the approved profile. P4 needs no POST permission.

**Audience contract:** P1 accepts a nonzero API client-ID GUID or an approved
identifier URI as the exact expected `aud` claim. P3 preserves that string
literally.
[Microsoft's token claim contract](https://learn.microsoft.com/entra/identity-platform/access-token-claims-reference)
states that a v2 access token's `aud` is the API client-ID GUID; a v1 token can use
the requested resource URI or client ID. Verify the actual issued claim and
coordinate P4 token acquisition separately; the audience is not itself a token
scope. Do not strip `api://`, invent a URI, normalize the configured audience, or
silently accept an unrelated audience. P3 does not modify the shared schema or
sample.

1. Validate P1 and call `Assert-GatewayConfiguration` with the exact resolved
   resource name/backend. This additionally checks the real APIM naming rules
   and the **4,096-character encoded named-value limit**. P1's shape is unchanged;
   the parent must call this guard rather than assume the schema imposes this
   aggregate limit.
2. Get the gateway plan with an explicit resource ID. New service creation
   requires both service and owned-name PE absence. An interrupted owned service
   already Enabled without an approved PE may preserve Enabled while retrying
   creation; it does not reopen a private service. Any existing Disabled service,
   or Enabled service with an approved PE, uses false. Conflicting ownership,
   unexpected APIs/operations, incomplete inventories or in-progress service
   operations fail closed. P4 readiness requires a stable private service and
   approval of the owned PE on both sides.
3. Bind the complete observed plan, its `initialProvisioning` value, and all
   concrete module inputs into the same preview/deploy parameter hash. Under the
   environment mutation lease, call `Assert-GatewayDeploymentPlan` immediately
   before the deployment. Any changed state invalidates approval.
4. Initial/recovery mode creates or preserves Enabled, establishes its PE, and
   forces new inference stopped. The API also rejects non-PE traffic throughout.
   After module completion, use the returned PE ID and explicit authorization
   for `-Apply -StopNewRequests $profile.gateway.stopNewRequests`.
5. Completion verifies approval on both resource sides and first PATCHes only
   `properties.publicNetworkAccess=Disabled`. It restores the approved stop
   Boolean only after a fresh private-state check, with conditional value-only
   PATCH and post-update value verification. Bounded retries never write Enabled.
   Without `-Apply`, or with `-WhatIf`, no resource is changed. These results are
   control-plane evidence, not functional inference readiness.
6. Re-observe private state and use `initialProvisioning=false` for every later
   deployment. Never reuse an old initial plan. Interrupted creation requires a
   fresh inspected/approved plan; only an owned service still Enabled without
   an approved PE may preserve that state. A newly approved PE or transition to
   Disabled invalidates an old initial=true plan. Do not delete resources,
   fabricate absence, or reopen Disabled to get past recovery.

The service PATCH API does **not** publish an `If-Match` parameter. The helper
does not pretend it has atomic compare-and-swap: parent serialization, immediate
rechecks and final reads are mandatory. A concurrent privileged administrator
remains a residual race. Resetting an emergency stop is a separate approved
configuration change; an intervening named-value ETag invalidates an old plan.

## Required authorized live matrix

No row below is claimed from compilation or local tests. Use separately approved
synthetic content and small explicit limits; this implementation session makes
no Azure changes or paid inference calls.

| Gate | Required live evidence |
| --- | --- |
| Provider/topology | Selected Developer/Premium classic tier is available with approved capacity/availability in the region. Classic VNet injection succeeds on an **undelegated** subnet with the required NSG rules and the `ApiManagement` service-tag UDR bypass. No SKU substitution. |
| Private ingress/backend | Developer, workload and runner resolve the gateway hostname to the internal load balancer private VIP through the operator-created `<name>.azure-api.net` zone, and the hostname does not resolve publicly. APIM reaches the private Foundry account through approved egress/DNS. |
| Identity | Resolve the URI/GUID audience decision against issued tokens. Valid tenant/audience/OID succeeds; missing/expired/wrong-signature/audience/tenant/unmapped tokens fail. Backend uses the gateway MI, not a key. |
| Authorization | Exact models only; case/prefix spoof, project/routing/key headers, unknown routes/methods and all excluded body modalities fail without inference. Inventory contains no unapproved callable API. |
| Enforcement | Measured configured rate -> 429; period quota -> 403; Retry-After survives. Different callers/models/projects/environments have distinct counters. |
| Stop/recovery | Owned stop prevents new inference; caller headers cannot resume. In-flight work is not cancelled. Initial activation, conflict retries, stale plans and reruns never change the injected network topology or move the gateway out of Internal mode. |
| Bypass | Ordinary developers/workload/runners cannot call the backend directly, list keys or acquire APIM debug privileges. Assess preexisting grants: omitting a Bicep assignment does not revoke it. |
| Metering/privacy | Correlate trace and native token metrics with no content/auth headers; verify metrics-with-dimensions delivery and cardinality. Exercise streaming interruption and concurrency overshoot. |
| Promotion | Parent-owned workflow freezes identical source/configuration/observed-state inputs and completes the independent approval/readiness gates. |

Native counters are gateway-local, not an aggregate across independent gateways.
Streaming uses estimates; concurrent/in-flight work can overshoot. Tokens are
not invoice currency. Blocking inference does not stop APIM, compute, Search,
retention, provisioned capacity, shared infrastructure or GitHub charges.
Production availability/zonal design is not certified by this starter's explicit
empty zone list; it needs the approved production profile and live review.

## Verified pins and local evidence

Primary contracts were reopened on 2026-09-16. APIM AVM is
`br/public:avm/res/api-management/service:0.14.4`, source commit
`e5823c10bdd9e83a8119d7e2ce40ac1c277fc195`, published OCI digest
`sha256:8df75309183c6dd846dbd577dbee974d66b262fd596a18580ec028a2c0a83c86`.
The upstream `version.json` minor `0.15` was not a published full version in the
opened registry listing. The pinned service source forwards `subnetResourceId`
and `virtualNetworkType` without a tier exclusion; the 2024-05-01 API
contracts and current classic-injection networking guidance were checked
independently of the AVM parameter's description, which incorrectly claims the
injection subnet must be delegated. Learn requires delegation `None` for classic
injection; AVM emits no delegation, so the description is misleading but inert.

Sources:

- [Pinned AVM source](https://github.com/Azure/bicep-registry-modules/tree/e5823c10bdd9e83a8119d7e2ce40ac1c277fc195/avm/res/api-management/service)
- [Network models and ordering](https://learn.microsoft.com/azure/api-management/virtual-network-concepts) and [v2 outbound integration](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound)
- [Client/backend identity](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis) and [Entra validation](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy)
- [Native token limits](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy), [token metrics](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy), [trace sampling](https://learn.microsoft.com/azure/api-management/trace-policy), and [Insights configuration](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights)
- [Policy expressions](https://learn.microsoft.com/azure/api-management/api-management-policy-expressions) and [immutable header limitations](https://learn.microsoft.com/azure/api-management/set-header-policy)
- [Service API/PATCH contract](https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/apimanagement/resource-manager/Microsoft.ApiManagement/ApiManagement/stable/2024-05-01/apimdeployment.json), [named-value GET ETags](https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/apimanagement/resource-manager/Microsoft.ApiManagement/ApiManagement/stable/2024-05-01/apimnamedvalues.json), and [named-value size](https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/apimanagement/resource-manager/Microsoft.ApiManagement/ApiManagement/stable/2024-05-01/definitions.json)

Use the session's isolated Bicep 0.42.1 on PATH:

```powershell
bicep build .\modules\api-management\main.bicep --outfile <session-gateway-template.json>
bicep lint .\modules\api-management\main.bicep
pwsh -NoProfile -File .\tests\github\Gateway.Tests.ps1
```

Tests render the production Bicep policy functions, compile the resulting C#
expressions and exercise their decisions, plus mock only native APIM policies
and ARM transport. They do not emulate JWT cryptography, native token accounting
or the Azure resource provider. Root README/changelog, main wiring and full
compatibility/size gates belong to the parent integration change.
