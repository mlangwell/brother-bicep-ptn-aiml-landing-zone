# ADR-004: Streaming is refused by default, and the gateway gains a call-rate backstop

- **Status:** Accepted
- **Date:** 2026-09-25
- **Supersedes:** nothing
- **Related:** [ADR-002](002-apim-merge-conformance.md) (APIM merge conformance),
  [2026-09-21 APIM platform separation plan](2026-09-21-apim-platform-separation-plan.md)

## Context

The gateway's `llm-token-limit` policy is the only real-time hard stop on AI spend
available to this landing zone. Azure publishes no native spend cap:

> "While OpenAI has an option for hard limits that prevent you from going over your
> budget, Azure OpenAI doesn't currently provide this functionality."
> — [Plan and manage costs for Azure OpenAI](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/manage-costs)

Three defects were found while preparing customer cost-control guidance. All three were
verified against Microsoft Learn and the OpenAI API specification rather than inferred.

### 1. Streaming silently downgrades the token limit to estimates

[`llm-token-limit`](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy)
states:

> "**Streaming**: When streaming is enabled in the API request (`stream: true`), prompt
> tokens are always estimated regardless of the `estimate-prompt-tokens` setting.
> Completion tokens are also estimated when responses are streamed."

That statement is categorical. It is a property of the policy, not of the request, and
Microsoft documents no setting that changes it.

The remedy Microsoft does publish is on a different page, for a different policy —
[`llm-emit-token-metric`](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy):

> "Certain OpenAI models, especially when streaming, don't include token counts in the
> response by default. To receive the token counts, set the `include_usage` parameter to
> `true` in the API request."

**That remedy cannot be applied to the Responses API, because the parameter does not exist
there.** In the OpenAI specification, `ResponseStreamOptions` carries exactly one property,
`include_obfuscation`; `include_usage` appears only on `ChatCompletionStreamOptions`. The
Azure REST reference for `/v1/responses` types `stream_options` as
`OpenAI.ResponseStreamOptions`, confirming it. The guidance is Chat-Completions advice
stranded on a page that now also claims Responses API support.

**Be precise about why that matters, because the obvious inference is wrong.** Usage data
is *not* missing from a streamed Responses call. The terminal `response.completed` event
carries a required `usage` object unconditionally, with no opt-in — `include_usage` is
absent from the Responses API because it is unnecessary there, not because usage is
unavailable. So the problem is not a gap in the wire protocol. The problem is that
`llm-token-limit` estimates when streaming *regardless* of what the response later reports,
and Microsoft publishes no way to make the policy consume the usage that is already there.

Two consequences follow, and only the second is ours to fix:

- Microsoft's documented remedy is inapplicable to this API. That is a defect in their
  guidance, not something we can configure around.
- Our request contract permitted `stream` as an optional boolean. A caller who set it was
  therefore enforced entirely on estimates, with no mechanism available to correct it — and
  nothing in the policy, the schema or the documentation said so.

Microsoft also does not quantify the resulting under-count, and separately documents that
streaming forces image inputs to be counted at a flat maximum of 1,200 tokens each.

### 2. No call-rate backstop

The gateway bounded token consumption per caller but not request volume. Token limits are
the right primary control precisely because call counts are a poor proxy for AI cost — one
request can be a hundred tokens or a hundred thousand. But that same property means a token
limit only engages *after* tokens have been counted and estimated. A retry storm or a
credential leak generates load that is bounded only by the backend.

### 3. The `caller` metric dimension carried a raw Entra object ID

`llm-emit-token-metric` emitted `context.Variables["caller-id"]`, which is the caller's
Entra `oid`. Two consequences:

- A GUID is useless as a chargeback dimension. Cost Analysis and Metrics Explorer show an
  opaque identifier, and somebody has to maintain an out-of-band mapping to read it.
- It places a directory object identifier into telemetry that is retained for at least
  31 days.

Cardinality itself was **not** the problem here, contrary to our initial assessment. The
policy returns 403 before the metric is emitted unless the caller matches exactly one
configured `callerMappings` entry, so the dimension's value set is already bounded by
configuration. The binding constraint is the documented 100-unique-values-per-dimension
cap, not the 1,000-active-time-series namespace cap.

## Decision

### Streaming is refused unless explicitly enabled

A new optional `gatewayConfiguration.allowStreaming` flag, **defaulting to `false`**.
When false the policy rejects `stream: true` with the existing 403 contract and the
reason `streaming-forbidden`, alongside the existing `storage-forbidden`.

This is a **deliberate tightening of existing behaviour**, not an additive change. It is
the one breaking element of this ADR and the reason the ADR exists.

We chose the tightened default over preserving current behaviour because the current
behaviour is a silent failure of the control the whole architecture rests on. A customer
holding this configuration unchanged for years should not discover, from an invoice, that
their spend ceiling was advisory for streaming traffic. Enabling streaming remains a
one-line, per-environment decision — but it is now a *recorded* decision.

### A per-caller call-rate backstop

`rate-limit-by-key` is emitted inside the same per-caller `<when>` branch as
`llm-token-limit`, using a distinct counter key (`<counter-key>|calls`) so the two
counters cannot interfere.

- `callerMapping.callsPerMinute` — optional per-caller override
- `gatewayConfiguration.defaultCallsPerMinute` — optional gateway-wide default
- Module fallback — 600 calls per minute

The platform caps `renewal-period` at 300 seconds, so this is necessarily expressed per
minute and cannot be widened to an hour.

### An optional billing label for the caller dimension

`callerMapping.label` — optional, 1–40 characters. When present it is emitted as the
`caller` metric dimension; when absent the object ID is used, so existing profiles are
unaffected. Trace metadata deliberately continues to carry the object ID, because
operational correlation needs the real identity and traces are metadata-only.

## Consequences

### Breaking

- **Any caller currently sending `stream: true` receives a 403 after this change** unless
  the environment sets `allowStreaming: true`. Environments that stream must set the flag
  in the same change that adopts this version.

### Additive

- `callerMapping.label`, `callerMapping.callsPerMinute`,
  `gatewayConfiguration.allowStreaming`, `gatewayConfiguration.defaultCallsPerMinute` are
  all optional. Profiles that omit them stay valid.
- `renderPolicy` now takes the whole `gatewayConfiguration` rather than just
  `callerMappings[]`. This is an internal module contract with three call sites, all
  updated in this change.

### Operational

- **`label` consumes named-value budget.** `callerMappings` is serialised into the
  base64 `<owner>-configuration` named value, which `Assert-GatewayConfiguration` caps at
  4,096 characters. Measured against the synthetic profile, `label` plus `callsPerMinute`
  costs **68 base64 characters per caller**, which lowers the ceiling from **16 callers to
  12** — a 25% reduction against a budget that was already tight. Profiles that omit both
  fields serialise byte-identically to before, so existing deployments are unaffected.
  Overflow is not silent: it throws on `*named-value*` before any deployment. Beyond about
  a dozen callers this configuration layout needs replacing, not trimming.
  `callsPerMinute` is rendered as a policy literal and is not read at runtime, but it is
  carried in the same payload so that the Bicep and PowerShell views of the configuration
  cannot drift.
- **Rate limiting is approximate.** Microsoft: "Because of the distributed nature of
  throttling architecture, rate limiting is never completely accurate." Counters are also
  per-gateway and are not aggregated across the instance.
- **Sandbox throttling is directional only.** Developer is a classic tier and uses a
  sliding window; Standard v2 and Premium v2 use a token bucket. Microsoft documents the
  algorithm split but makes no statement about comparability, so sandbox results should
  not be read as predictive of production.

## Risks accepted, and one left open

- **Estimate-based enforcement remains available.** `allowStreaming: true` is a supported
  configuration. The ADR does not forbid it; it forces the trade-off to be stated.
- **Custom metrics are public preview and will not reach GA.** Microsoft: "This feature
  won't be made generally available, because an improved generally available feature
  achieves the same functionality and more: Application Insights with OpenTelemetry."
  Chargeback built on `llm-emit-token-metric` rests on a preview surface with a named
  successor. Out of scope here; it needs its own decision.
- **Open — prompt estimation against a hand-built API is unverified.** `llm-token-limit`
  documents that with `estimate-prompt-tokens="true"` it "estimates prompt tokens from the
  prompt schema in the API definition". This API is hand-built (route pin plus
  `rewrite-uri`) rather than imported through the LLM API wizard. Microsoft does not
  document the behaviour when the expected schema is absent. **This needs a live test
  against a deployed gateway.** If estimation silently degrades, the pre-flight rejection
  of over-limit callers degrades with it.

## Alternatives considered

| Alternative | Rejected because |
|---|---|
| Keep streaming permitted, document the caveat only | The failure is silent and the document is not in the request path. A customer holding this for years never reads it. |
| Remove `stream` from the contract entirely | Forecloses a legitimate use case that some environments will accept the trade-off for. |
| Rate limit at the API scope rather than per caller | One noisy caller would consume the shared budget and throttle everyone else. |
| Replace the `caller` dimension outright | Breaks existing dashboards. The optional label with object-ID fallback is additive. |
| Apply the rate limit via a second `<choose>` block | A second chooser duplicates the caller-matching logic and can drift from the first. |
