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
  join(map(configuration.callerMappings, caller => '<when condition="@((string)context.Variables[&quot;caller-id&quot;] == &quot;${toLower(caller.objectId)}&quot;)"><llm-token-limit counter-key="@((string)context.Variables[&quot;counter-key&quot;])" tokens-per-minute="${caller.tokensPerMinute}" token-quota="${caller.tokenQuota}" token-quota-period="${caller.tokenQuotaPeriod}" estimate-prompt-tokens="true" tokens-consumed-variable-name="consumed-tokens" remaining-quota-tokens-variable-name="remaining-quota" /><rate-limit-by-key calls="${caller.?callsPerMinute ?? configuration.?defaultCallsPerMinute ?? fallbackCallsPerMinute}" renewal-period="${rateLimitRenewalPeriod}" counter-key="@((string)context.Variables[&quot;counter-key&quot;] + &quot;|calls&quot;)" retry-after-header-name="Retry-After" remaining-calls-header-name="x-ratelimit-remaining-calls" /></when>'), '\n')
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
      callerMappings: configuration.callerMappings
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

