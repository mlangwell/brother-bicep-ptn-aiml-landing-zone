# ADR-007: The azd path can configure the gateway

- Status: Accepted
- Date: 2026-09-28
- Amends: ADR-002 (two input surfaces), ADR-004 (live-proof status), ADR-005 (gateway gap)

## Context

ADR-005 recorded that a successful `Deploy-AilzIntegrated.ps1 -DeployApiManagement` run
produced an API Management instance containing only the stock `echo-api`. Enumerated on
the live deployment: no named values, no workload API, no `llm-token-limit`.

The cause is a single unreachable parameter. `main.bicep:1313` gated the entire workload
— API, backend, named values and policy — on
`_apiManagementWorkloadEnabled = !empty(apiManagementConfiguration)`, and
`main.parameters.json` bound `apiManagementConfiguration` to a **literal `{}` with no
`${...}` substitution**. `Deploy-AilzIntegrated.ps1` never set it. Only
`scripts/github/Environment.psm1` supplied it, by building its own parameter file.

The binding could not simply be changed to a substitution: `Expand-ParamValue` in
`scripts/Invoke-PreflightChecks.ps1` resolves `${VAR}` with a `[^}]*` default group, so a
substitution carrying a JSON object terminates at the first `}`.

The consequence is worse than "governance defaults are wrong". Nothing existed to govern:
the customer paid for a Developer or Premium gateway that served no inference route at
all, while the guardrails playbook's gateway plane correctly reported `Unverifiable` and
the run otherwise looked green.

### Why a default token limit is not the answer

`llm-token-limit` is enforced per caller. `modules/api-management/policy.bicep` emits one
`<when condition="caller-id == '<objectId>'">` branch per `callerMapping`, and the
`<otherwise>` in `responses-policy.xml` returns `403 gateway_mapping_missing`. The
template cannot synthesise caller mappings, because it cannot know the Entra object IDs
of the callers.

A caller-agnostic fallback limit was considered and rejected. `llm-token-limit` counts
against `counter-key`; a shared fallback bucket would put every unmapped caller in one
counter, so the first abusive caller would deny service to all the others. That trades a
precise 403 for shared-fate exhaustion. Refusing an unmapped caller is the correct
behaviour and is already what the policy does.

So the goal — "the policies apply whether it goes through the pipeline or not" — is met
by making the configuration **reachable** from the azd path, not by inventing a default.

## Decision

1. **`apiManagementConfigurationJson`** — a new `string` parameter carrying the same
   `gatewayConfiguration` as JSON, bound to `${API_MANAGEMENT_CONFIGURATION=}`. This
   follows the repository's existing precedent for JSON through azd,
   `foundryIqIngestionPermissionOptionsJson`, and avoids the `[^}]*` truncation because
   the substituted value lands in a string.

2. **Object precedence, with a loud conflict check.** `main.bicep` resolves
   `_apiManagementConfiguration` as: the object when non-empty, otherwise the parsed
   JSON, otherwise `{}`. The object winning is safe by construction — the GitHub path
   cannot be overridden by a stale azd variable, which matters because
   `scripts/github/Deployment.psm1` mutates `initialProvisioning`, the field that governs
   whether the gateway stops during initial provisioning. Silently ignoring an operator's
   input is its own failure, so preflight fails with `APIM_CONFIGURATION_CONFLICT` when
   both are set. Bicep has no throw; the loud error belongs at the layer that can produce
   a useful message.

3. **`apiManagementManagedBy`** — a new parameter defaulting to `ai-landing-zone`, which
   replaces `managedBy: _apiManagementWorkloadEnabled ? 'github-dev-environment' : ...`.
   That expression used "has a workload configuration" as a proxy for "was deployed by
   the pipeline". Once the azd path can supply a configuration the proxy is wrong, and an
   azd-built gateway would have stamped the pipeline's marker and become adoptable by it
   (`Gateway.Tests.ps1:587` throws `*ownership*` on a foreign marker, so the marker is an
   adoption gate, not a label). Both paths run the same `main.bicep`, so there is no
   deploying path the template can observe; the discriminator has to be explicit.
   `scripts/github/Environment.psm1` opts in; every other caller gets the safe default.

4. **`-GatewayConfigurationPath`** on `Deploy-AilzIntegrated.ps1`, which reads, validates
   and publishes the document. Validation lives in the script because `main.bicep`
   rebuilds the configuration field by field: an unknown key is silently dropped and a
   missing required key becomes an opaque evaluation failure inside a nested deployment,
   minutes into a 30-minute gateway create. The GitHub path has `environments/schema.json`
   for this; the azd path had nothing.

5. **Preflight resolves the configuration the same way `main.bicep` does.**
   `Get-ApiManagementSubnetPrefix` previously read only the object, so with a
   JSON-supplied configuration every CIDR overlap and containment check would have run
   against the default prefix instead of the deployed one — in the one component whose job
   is to catch this before a long deploy.

6. **`APIM_GATEWAY_WITHOUT_WORKLOAD`** — a warning when a gateway is deployed with no
   configuration at all. That remains a supported choice (the gateway is per-subscription
   platform infrastructure with a longer lifecycle than any landing zone), but it should
   be a decision rather than a surprise discovered by enumerating APIs.

`apiManagementConfiguration` keeps its `{}` default and its literal binding, so the
GitHub path and the compatibility baseline are untouched.

## Consequences

- A customer running the deploy script with `-GatewayConfigurationPath` gets the workload
  API, the named values, the `llm-token-limit`, and the ADR-004 controls — the same
  gateway the pipeline produces.
- Without that switch the behaviour is unchanged, but now warned about.
- `Deploy-AilzIntegrated.ps1` is a preserved file; its pin is refreshed with an
  `approvedChanges` entry.
- Two parameters are added. Both are additive with safe defaults, and
  `Compatibility.Tests.ps1` iterates only baseline keys, so the parameter contract holds.
- `environments/gateway-configuration.example.json` is the customer-facing starting point.
  It is an example and is read by no deployment.

## Amends ADR-004

ADR-005 recorded that ADR-004's controls were never exercised because the gateway was
never configured. Two changes since then bear on that:

- `2c76a4e` fixed a separate defect: `main.bicep` declared neither `allowStreaming` nor
  `defaultCallsPerMinute` in either of its `gatewayConfiguration` compositions, so the
  orchestrator silently dropped both. ADR-004's documented `allowStreaming` opt-in had no
  effect through `main.bicep`, and was only ever proven by `Gateway.Tests.ps1` calling
  `renderPolicy` directly. The module was correct; the orchestrator was not.
- This ADR makes the configuration reachable from the azd path at all.

ADR-004 is now *reachable and unit-proven*, but still **not live-proven**: no inference
request has traversed a configured gateway. That requires a deployment with a real Entra
audience app and caller, and a 401/200/429 matrix. It remains outstanding, along with
ADR-002 phase 2.

## Compliance verification

- `az bicep build` / `az bicep lint` — clean.
- `pwsh ./scripts/github/Test-GitHubEnvironment.ps1 -TemplatePath ./main.json` —
  13 required suites passed.
- `Read-GatewayConfiguration` exercised against five inputs: the example (passes, and
  `$`-prefixed annotation keys are stripped), a missing required field, an `objectId`
  that is an application ID URI rather than a GUID, an empty `callerMappings`, and
  malformed JSON. All four invalid cases threw with a specific message.
- `Get-ApiManagementSubnetPrefix` verified for three cases: JSON-only resolves the
  JSON-supplied prefix, a supplied object takes precedence over JSON, and malformed JSON
  raises `APIM_CONFIGURATION_UNPARSEABLE` and falls back rather than guessing.
- Preflight verified to emit `APIM_GATEWAY_WITHOUT_WORKLOAD` with a gateway and no
  configuration, and to stop emitting it once a configuration is supplied.

Not verified live: no Azure deployment was made with a JSON-supplied configuration. The
resolution, validation and preflight paths are proven offline; the resulting gateway
contents are not.
