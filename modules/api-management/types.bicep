@export()
@sealed()
@description('One authenticated Entra object, one configured project, and exact model deployment names.')
type callerMapping = {
  @minLength(36)
  @maxLength(36)
  objectId: string
  @minLength(1)
  project: string
  @minLength(1)
  models: string[]
  @minValue(1)
  @description('Optional per-caller token rate limit. Absent falls back to the gateway `defaultTokensPerMinute`, then to the module default. This also caps the caller\'s request: responses-policy.xml refuses a request whose `max_output_tokens` exceeds min(tokensPerMinute, tokenQuota), because Azure charges the rate limit on an estimate taken at request time that includes the declared output size.')
  tokensPerMinute: int?
  @minValue(1)
  @description('Optional per-caller token budget for one `tokenQuotaPeriod`. Absent falls back to the gateway `defaultTokenQuota`, then to the module default. This is a budget, not a rate: `tokensPerMinute` bounds the burst.')
  tokenQuota: int?
  @description('Optional window after which `tokenQuota` resets. Absent falls back to the gateway `defaultTokenQuotaPeriod`, then to the module default.')
  tokenQuotaPeriod: ('Hourly' | 'Daily' | 'Weekly' | 'Monthly' | 'Yearly')?
  @minLength(1)
  @maxLength(40)
  @description('Optional stable, human-readable billing label emitted as the `caller` metric dimension instead of the raw Entra object ID. An object ID is unreadable in a cost dashboard and puts a directory identifier into telemetry. Absent falls back to the object ID, so this is additive. Keep the set of distinct labels under the documented 100-unique-values-per-dimension cap: past it, API Management silently discards the metric data.')
  label: string?
  @minValue(1)
  @description('Optional per-caller call-rate backstop in calls per minute, enforced by `rate-limit-by-key`. Absent falls back to the gateway `defaultCallsPerMinute`. This bounds request VOLUME; `tokensPerMinute` bounds token CONSUMPTION. Both are needed, because one request can be a hundred tokens or a hundred thousand, so a token limit only bites after the tokens have been counted.')
  callsPerMinute: int?
}

@export()
@sealed()
@description('Validated P1 gateway configuration. Native Foundry portal integration is deliberately unsupported. The gateway uses classic VNet injection in Internal mode on every tier, so `privateDnsZoneResourceId` names the service-scoped `<apim-name>.azure-api.net` zone, NOT a `privatelink.azure-api.net` zone: classic injected instances cannot hold a private endpoint, and Learn forbids a private zone for the shared apex domain `azure-api.net`.')
type gatewayConfiguration = {
  enabled: true
  name: string?
  sku: 'Developer' | 'Premium'
  @minValue(1)
  capacity: int
  @minLength(1)
  publisherEmail: string
  @minLength(1)
  publisherName: string
  @minLength(1)
  audience: string
  @minLength(1)
  integrationSubnetName: string
  @minLength(1)
  integrationSubnetPrefix: string
  @minLength(1)
  privateDnsZoneResourceId: string
  stopNewRequests: bool
  foundryIntegration: false?
  @description('Whether callers may set `stream: true`. Defaults to FALSE, which is a deliberate tightening - see ADR-004. Microsoft documents that when streaming is enabled, `llm-token-limit` ALWAYS estimates prompt tokens regardless of `estimate-prompt-tokens`, and estimates completion tokens too - categorically, with no setting that changes it. Note that streamed Responses calls DO report usage (`response.completed` carries a required `usage` object); the `include_usage` remedy Microsoft publishes is a Chat Completions parameter that does not exist on the Responses API and is unnecessary there. The gap is that the policy estimates regardless, and Microsoft documents no way to make it consume that usage. So a streaming caller is enforced on estimates and nothing request-side corrects it. Enable this only where estimate-based enforcement is an accepted, recorded trade-off.')
  allowStreaming: bool?
  @minValue(1)
  @description('Gateway-wide default call-rate backstop in calls per minute, used for any caller without its own `callsPerMinute`. Absent uses the module default of 600.')
  defaultCallsPerMinute: int?
  @minValue(1)
  @description('Gateway-wide default token rate limit, used for any caller without its own `tokensPerMinute`. Absent uses the module default. Size this against the TPM actually assigned to the model deployments the callers use: per-caller limits do NOT compose, so N callers at this value admit N times this much demand against one shared deployment, and the excess is refused by the model rather than by the gateway.')
  defaultTokensPerMinute: int?
  @minValue(1)
  @description('Gateway-wide default token budget per `tokenQuotaPeriod`, used for any caller without its own `tokenQuota`. Absent uses the module default.')
  defaultTokenQuota: int?
  @description('Gateway-wide default quota window, used for any caller without its own `tokenQuotaPeriod`. Absent uses the module default.')
  defaultTokenQuotaPeriod: ('Hourly' | 'Daily' | 'Weekly' | 'Monthly' | 'Yearly')?
  @minLength(1)
  callerMappings: callerMapping[]
}
