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
  @minLength(1)
  callerMappings: callerMapping[]
}
