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
  tokensPerMinute: int
  @minValue(1)
  tokenQuota: int
  tokenQuotaPeriod: 'Hourly' | 'Daily' | 'Weekly' | 'Monthly' | 'Yearly'
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
  @minLength(1)
  callerMappings: callerMapping[]
}
