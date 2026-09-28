# ADR-008: Gateway-level token defaults

- Status: Accepted
- Date: 2026-09-28
- Amends: ADR-004 (per-caller limits), ADR-007 (recorded this as follow-up)

## Context

ADR-007 made the gateway configuration reachable from the azd path, but left every
`callerMappings` entry required to restate six fields. Three of them — `tokensPerMinute`,
`tokenQuota` and `tokenQuotaPeriod` — are numbers the operator has no basis to choose and
no way to omit. `Read-GatewayConfiguration` refused a mapping without them, and
`responses-policy.xml` resolved such a mapping to `{}`, which the policy then refuses as
an unapproved caller.

The intended operator of this landing zone is not an Azure specialist. Six mandatory
fields per caller is the thing most likely to stop them turning the gateway on at all,
which is the failure ADR-007 set out to close.

ADR-007 originally argued against a default on the grounds that a caller-agnostic
fallback would share one counter and let the first abusive caller starve the rest. That
argument was withdrawn: `responses-policy.xml:107-112` builds `counter-key` as
`owner|environment|tid|caller-id|project|model` and sets it once before the branch
selection, so every branch gets a per-caller, per-model counter regardless.

### What Microsoft publishes

Nothing. The `llm-token-limit` reference lists `tokens-per-minute`, `token-quota` and
`token-quota-period` with **Default = N/A**, requiring only that a rate limit, a quota, or
both be supplied. There is no vendor-recommended value to cite, so the numbers below are
ours and are justified here rather than attributed.

The capacity-to-TPM ratio is also model-specific. Learn publishes 1 unit = 1,000 TPM for
chat-class models and states TPM is assigned in 1,000 increments, but explicitly warns the
ratio varies by model and that this matters for programmatic deployment. The landing
zone's default `chat` deployment is `gpt-5-nano` at `capacity: 40`, which that table does
not cover, so the assumed ~40,000 TPM is an assumption and is labelled as one everywhere
it is used.

## Decision

`callerMapping` makes `tokensPerMinute`, `tokenQuota` and `tokenQuotaPeriod` optional.
`gatewayConfiguration` gains `defaultTokensPerMinute`, `defaultTokenQuota` and
`defaultTokenQuotaPeriod`. Resolution is caller, then gateway, then module:

```
caller.?tokensPerMinute ?? configuration.?defaultTokensPerMinute ?? 10000
caller.?tokenQuota      ?? configuration.?defaultTokenQuota      ?? 5000000
caller.?tokenQuotaPeriod ?? configuration.?defaultTokenQuotaPeriod ?? 'Monthly'
```

A caller entry reduces to `objectId`, `project` and `models` — the three fields only the
operator can supply.

**The allow-list is unchanged.** A caller whose object ID is not listed is still refused
with `403 gateway_forbidden` at `responses-policy.xml:37-48`. Defaulting the numbers does
not admit a caller; it only spares the operator inventing limits for one already approved.
Serving an unlisted caller on a default was considered and rejected: the gateway validates
only audience and tenant, so any principal in the tenant would be served, with no `models`
allow-list to enforce and no `project` to attribute cost to.

### Where the defaults are resolved, and why it matters

In `gatewayNamedValues` (`policy.bicep`), not only in `renderPolicy`.

`responses-policy.xml` reads `tokensPerMinute` and `tokenQuota` back out of the
base64 configuration named value in two places: the `mapping` validator at `:30-33`, and
the `max_output_tokens` ceiling `Math.Min(tokensPerMinute, tokenQuota)` at `:84`. Had the
defaults been applied only to the rendered `<when>` branch, a defaulted caller would have
reached the policy with those fields absent and been refused as unapproved — a default
that causes the refusal it was meant to prevent, and only at runtime.

Materialising the resolved values into `callerMappings` before serialisation keeps the
policy's own validation intact rather than relaxing it. `Gateway.Tests.ps1` asserts this
directly, because it is the failure mode that would otherwise pass every offline gate.

### The chosen numbers

| Field | Default | Basis |
| --- | --- | --- |
| `defaultTokensPerMinute` | `10000` | Roughly four callers sharing the default `chat` deployment at `capacity: 40`, using the published chat-class 1 unit = 1,000 TPM ratio. A round number in the 1,000 increments Learn specifies. |
| `defaultTokenQuota` | `5000000` | A period budget, not a rate. Saturating 10,000 TPM for a month is three orders of magnitude larger; the quota is what catches a slow leak. |
| `defaultTokenQuotaPeriod` | `Monthly` | The only window that reads as a budget. |

Two consequences are documented in the example file rather than left to be discovered:

1. **These also cap each request.** The policy refuses any request whose
   `max_output_tokens` exceeds `min(tokensPerMinute, tokenQuota)` — 10,000 with these
   defaults. Azure charges the TPM rate limit on an estimate taken at request time that
   includes the declared output size, so this coupling is deliberate, not incidental. Set
   the rate too low and a caller gets a `403` that reads like a permissions failure.
2. **Per-caller limits do not compose.** Four callers at 10,000 TPM admit 40,000 TPM of
   demand against one deployment. Past the deployment's assignment the *model* refuses the
   excess, so the caller loses the `Retry-After` and remaining-quota signal a gateway
   refusal would have carried.

`Test-GatewayTokenOversubscription` in `Deploy-AilzIntegrated.ps1` warns when the callers
mapped to a model deployment sum past its assumed TPM. It warns and never fails, because
the ratio it assumes is model-specific and a wrong assumption must not block a deployment.

## Consequences

- Additive and backward compatible. An existing configuration that states all three
  fields per caller renders exactly as before; `Gateway.Tests.ps1` still asserts the
  explicit values are honoured.
- `environments/schema.json` drops the three from `callerMapping.required` and adds the
  three gateway-level defaults. A configuration valid before remains valid.
- Changing a module default changes the rendered policy for every caller that relies on
  it. The values are asserted in `Gateway.Tests.ps1` so a change cannot pass silently.
- An operator who changes the model or its capacity should revisit
  `defaultTokensPerMinute`. The oversubscription warning is the prompt, not a guarantee.

## Not verified

The rendered policy, the named-value materialisation and the resolution precedence are
proven offline by `Gateway.Tests.ps1` and by a `bicep build-params` fold. No inference
call has been made against a deployed gateway, so the runtime behaviour of
`llm-token-limit` under these defaults — including whether a defaulted caller is
throttled where expected — remains unproven. See ADR-005.
