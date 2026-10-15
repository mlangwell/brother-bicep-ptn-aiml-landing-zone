import { gatewayConfiguration } from './types.bicep'

var template = loadTextContent('./responses-policy.xml')

// Call-rate backstop used when neither the caller nor the gateway sets one.
// Token limits bound CONSUMPTION but only after tokens have been counted; one
// request can be a hundred tokens or a hundred thousand. This bounds VOLUME,
// so abuse and runaway retry loops are refused before they are metered.
var fallbackCallsPerMinute = 600

// The platform caps rate-limit-by-key renewal-period at 300 seconds, so the
// backstop is necessarily expressed per minute. It cannot be widened to an hour.
var rateLimitRenewalPeriod = 60

// Token backstops used when neither the caller nor the gateway sets one.
//
// Microsoft publishes NO default for llm-token-limit: the reference lists
// tokens-per-minute, token-quota and token-quota-period with Default = N/A and
// requires only that a rate limit, a quota, or both be supplied. These values
// are therefore ours, and are chosen rather than cited.
//
// 10,000 TPM assumes roughly four callers sharing the landing zone's default
// `chat` deployment, which ships at capacity 40. Learn publishes 1 unit =
// 1,000 TPM for chat-class models and states TPM moves in 1,000 increments, so
// four callers at this value sum to that deployment's assignment. It warns the
// ratio varies by model, so an operator who changes the model or the capacity
// should revisit this rather than inherit it.
//
// Sizing matters more than it looks. Azure charges the TPM rate limit on an
// estimate taken when the request arrives, and that estimate includes the
// declared max output size even when the real response is far shorter. Set this
// too low and callers are throttled on tokens they never consumed; the template
// also refuses any request whose max_output_tokens exceeds min(tokensPerMinute,
// tokenQuota), so too low a value surfaces as a 403 rather than a 429.
var fallbackTokensPerMinute = 10000

// A budget, not a rate. Saturating 10,000 TPM for a month would be three orders
// of magnitude past this; the quota is what stops a slow leak going unnoticed.
var fallbackTokenQuota = 5000000
var fallbackTokenQuotaPeriod = 'Monthly'

// Injected when allowStreaming is false. Ordering matters: the template's own
// line has already rejected a non-boolean `stream`, so by the time this runs
// the value is known to be a boolean or absent.
//
// Why this exists. Microsoft documents that when `stream: true`, llm-token-limit
// ALWAYS estimates prompt tokens regardless of estimate-prompt-tokens, and
// estimates completion tokens as well. That is categorical - a property of the
// policy, with no documented setting that changes it.
//
// Note the obvious inference is wrong: usage data is NOT missing from a streamed
// Responses call. `response.completed` carries a required `usage` object with no
// opt-in. Microsoft's published remedy (`include_usage`) is a Chat Completions
// parameter that does not exist on the Responses API, and it is not needed there.
// The gap is that llm-token-limit estimates regardless of what the response
// reports, and Microsoft publishes no way to make it consume that usage.
//
// So a streaming caller is enforced on estimates, and nothing request-side can
// correct it. See ADR-004.
var streamingForbiddenCheck = 'if (body[&quot;stream&quot;] != null &amp;&amp; (bool)body[&quot;stream&quot;]) { return &quot;streaming-forbidden&quot;; }'

@export()
@description('Render only the owned API policy. Native rates/quotas and the call-rate backstop are literals, not caller-supplied expressions. apiPath is the workload-scoped route prefix the policy pins the inbound request to. Streaming is refused unless the configuration opts in, because streamed requests are enforced on estimated token counts.')
func renderPolicy(owner string, apiPath string, configuration gatewayConfiguration) string => replace(
  replace(
    replace(
      replace(template, '__OWNER__', owner),
      '__API_PATH__',
      apiPath
    ),
    '__STREAM_CHECK__',
    (configuration.?allowStreaming ?? false) ? '' : streamingForbiddenCheck
  ),
  '__TOKEN_LIMITS__',
  join(map(configuration.callerMappings, caller => '<when condition="@((string)context.Variables[&quot;caller-id&quot;] == &quot;${toLower(caller.objectId)}&quot;)"><llm-token-limit counter-key="@((string)context.Variables[&quot;counter-key&quot;])" tokens-per-minute="${caller.?tokensPerMinute ?? configuration.?defaultTokensPerMinute ?? fallbackTokensPerMinute}" token-quota="${caller.?tokenQuota ?? configuration.?defaultTokenQuota ?? fallbackTokenQuota}" token-quota-period="${caller.?tokenQuotaPeriod ?? configuration.?defaultTokenQuotaPeriod ?? fallbackTokenQuotaPeriod}" estimate-prompt-tokens="true" tokens-consumed-variable-name="consumed-tokens" remaining-quota-tokens-variable-name="remaining-quota" /><rate-limit-by-key calls="${caller.?callsPerMinute ?? configuration.?defaultCallsPerMinute ?? fallbackCallsPerMinute}" renewal-period="${rateLimitRenewalPeriod}" counter-key="@((string)context.Variables[&quot;counter-key&quot;] + &quot;|calls&quot;)" retry-after-header-name="Retry-After" remaining-calls-header-name="x-ratelimit-remaining-calls" /></when>'), '\n')
)

@export()
@description('Nonsecret, ownership-tagged named values. Names and tags are keyed by the workload-scoped owner so landing zones sharing one gateway never collide. Initial/recovery provisioning forces stop until private completion. Base64 is encoding, not encryption.')
func gatewayNamedValues(owner string, environmentName string, tenantId string, configuration gatewayConfiguration, backendEndpoint string, initialProvisioning bool) array => [
  {
    name: '${owner}-configuration'
    displayName: '${owner}-configuration'
    secret: false
    tags: [owner]
    value: base64(string({
      environment: environmentName
      tenantId: toLower(tenantId)
      backendHost: toLower(split(backendEndpoint, '/')[2])
      // Resolved here, not only in renderPolicy. responses-policy.xml reads these
      // three back out of THIS named value twice - the `mapping` validator, and
      // the max_output_tokens ceiling min(tokensPerMinute, tokenQuota) - so a
      // mapping that reached the policy without them would be refused as
      // unapproved rather than defaulted. Materialising them here keeps the
      // policy's own validation intact instead of relaxing it.
      callerMappings: map(configuration.callerMappings, caller => union(caller, {
        tokensPerMinute: caller.?tokensPerMinute ?? configuration.?defaultTokensPerMinute ?? fallbackTokensPerMinute
        tokenQuota: caller.?tokenQuota ?? configuration.?defaultTokenQuota ?? fallbackTokenQuota
        tokenQuotaPeriod: caller.?tokenQuotaPeriod ?? configuration.?defaultTokenQuotaPeriod ?? fallbackTokenQuotaPeriod
      }))
    }))
  }
  {
    name: '${owner}-tenant'
    displayName: '${owner}-tenant'
    secret: false
    tags: [owner]
    value: toLower(tenantId)
  }
  {
    name: '${owner}-audience'
    displayName: '${owner}-audience'
    secret: false
    tags: [owner]
    value: configuration.audience
  }
  {
    name: '${owner}-stop'
    displayName: '${owner}-stop'
    secret: false
    tags: [owner]
    value: (initialProvisioning || configuration.stopNewRequests) ? 'true' : 'false'
  }
]

