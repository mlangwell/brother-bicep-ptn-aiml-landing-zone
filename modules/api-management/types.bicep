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
@description('Validated P1 gateway configuration. Native Foundry portal integration is deliberately unsupported.')
type gatewayConfiguration = {
  enabled: true
  name: string?
  sku: 'StandardV2' | 'PremiumV2'
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
