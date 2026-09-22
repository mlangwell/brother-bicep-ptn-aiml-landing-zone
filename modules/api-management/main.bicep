targetScope = 'resourceGroup'

import * as const from '../../constants/constants.bicep'
import { gatewayConfiguration } from './types.bicep'
import { renderPolicy, gatewayNamedValues } from './policy.bicep'

@description('Resolved explicit, CAF or legacy gateway name. The parent gates this module with deployApiManagement=false by default.')
@minLength(1)
@maxLength(50)
param name string

@description('Approved gateway and integration VNet region.')
param location string

@description('Configured environment used in ownership markers and token counter isolation.')
param environmentName 'dev' | 'test' | 'prod'

@description('Landing-zone-scoped key that makes every per-workload gateway resource unique. One shared gateway hosts many landing zones, so the API name, API path, backend, logger and named values are all keyed by this value. Must be lowercase alphanumeric so it is valid as both an APIM resource name segment and a URL path segment; the shared environment resolver enforces the character contract.')
@minLength(3)
@maxLength(24)
param workloadKey string

@description('The approved Entra tenant, not organizations/common. Validate through the shared environment resolver.')
@minLength(36)
@maxLength(36)
param tenantId string

@description('Frozen, validated P1 gateway configuration. This module only accepts enabled, ordinary APIM integration.')
param configuration gatewayConfiguration

@description('Dedicated Microsoft.Web/serverFarms delegated subnet with approved NSG, routes, DNS and egress; never the app or agent subnet.')
param integrationSubnetResourceId string

@description('Separate private endpoint subnet. It must resolve the BYO privatelink.azure-api.net zone to the private clients.')
param privateEndpointSubnetResourceId string

@description('Foundry account resource ID; only the gateway identity receives the backend inference role here.')
param backendAccountResourceId string

@description('Verified Foundry account HTTPS root endpoint, without an API path, query, credentials or fragment.')
param backendEndpoint string

@description('Existing Application Insights component. Its resource properties are read internally; no connection string is output.')
param applicationInsightsResourceId string

@description('Existing Log Analytics workspace for owned service diagnostics. This does not create competing AMPLS/DNS topology.')
param logAnalyticsWorkspaceResourceId string

@description('Deployment tags, merged with the reserved gateway ownership marker.')
param tags object = {}

@description('True only for observed absence or an owned already-Enabled service without an approved PE, frozen and rechecked before deployment. This never reopens an existing Disabled service. Forces stop until PE/private completion restores the approved setting.')
param initialProvisioning bool = false

// One gateway is shared by many landing zones, so every per-workload resource
// name and the public route are keyed by workloadKey. Keying by environmentName
// alone collides the moment a second landing zone lands in the same
// subscription and environment — which is the whole point of the shared model.
var owner = 'ailz-inference-${environmentName}-${workloadKey}'
var apiPath = 'inference/${workloadKey}'
var marker = 'owner:${owner}'
var ownedTags = union(tags, {
  'ailz-managed-by': 'github-dev-environment'
  'ailz-environment': environmentName
  'ailz-owner': owner
})
var backendUrl = uri(backendEndpoint, 'openai')

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  scope: resourceGroup(split(applicationInsightsResourceId, '/')[2], split(applicationInsightsResourceId, '/')[4])
  name: last(split(applicationInsightsResourceId, '/'))
}

module gateway 'br/public:avm/res/api-management/service:0.14.4' = {
  name: '${owner}-service'
  params: {
    name: name
    location: location
    tags: ownedTags
    sku: configuration.sku
    skuCapacity: configuration.capacity
    publisherEmail: configuration.publisherEmail
    publisherName: configuration.publisherName
    managedIdentities: { systemAssigned: true }
    enableTelemetry: false
    enableDeveloperPortal: false
    availabilityZones: []
    customProperties: {}
    virtualNetworkType: 'External'
    subnetResourceId: integrationSubnetResourceId
    publicNetworkAccess: initialProvisioning ? 'Enabled' : 'Disabled'
    privateEndpoints: [
      {
        name: '${name}-inbound'
        location: location
        service: 'Gateway'
        subnetResourceId: privateEndpointSubnetResourceId
        tags: ownedTags
        privateDnsZoneGroup: {
          name: 'default'
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: configuration.privateDnsZoneResourceId }
          ]
        }
      }
    ]
    diagnosticSettings: [
      {
        name: '${owner}-monitor'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: []
        metricCategories: [{ category: 'AllMetrics' }]
      }
    ]
  }
}

resource service 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: name
}

module backendAndTelemetryRoles '../security/resource-role-assignment.bicep' = {
  name: '${owner}-roles'
  params: {
    name: owner
    roleAssignments: [
      {
        resourceId: backendAccountResourceId
        roleDefinitionId: subscriptionResourceId(split(backendAccountResourceId, '/')[2], 'Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesOpenAIUser.guid)
        principalId: gateway.outputs.systemAssignedMIPrincipalId!
        principalType: 'ServicePrincipal'
      }
      {
        resourceId: applicationInsightsResourceId
        roleDefinitionId: subscriptionResourceId(split(applicationInsightsResourceId, '/')[2], 'Microsoft.Authorization/roleDefinitions', const.roles.MonitoringMetricsPublisher.guid)
        principalId: gateway.outputs.systemAssignedMIPrincipalId!
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

resource namedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [
  for value in gatewayNamedValues(owner, environmentName, tenantId, configuration, backendEndpoint, initialProvisioning): {
    parent: service
    name: value.name
    properties: {
      displayName: value.displayName
      secret: value.secret
      tags: value.tags
      value: value.value
    }
    dependsOn: [gateway]
  }
]

resource backend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: service
  name: '${owner}-foundry'
  properties: {
    title: '${owner}-foundry'
    description: marker
    protocol: 'http'
    url: backendUrl
    resourceId: '${environment().resourceManager}${substring(backendAccountResourceId, 1)}'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [gateway]
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: service
  name: '${owner}-insights'
  properties: {
    loggerType: 'applicationInsights'
    description: marker
    resourceId: applicationInsightsResourceId
    isBuffered: true
    credentials: {
      connectionString: applicationInsights.properties.ConnectionString
      identityClientId: 'SystemAssigned'
    }
  }
  dependsOn: [backendAndTelemetryRoles]
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: service
  name: owner
  properties: {
    displayName: 'Governed text Responses (${environmentName})'
    description: marker
    apiType: 'http'
    path: apiPath
    protocols: ['https']
    subscriptionRequired: false
    serviceUrl: backendUrl
  }
  dependsOn: [gateway]
}

resource schema 'Microsoft.ApiManagement/service/apis/schemas@2024-05-01' = {
  parent: api
  name: 'responses'
  properties: {
    contentType: 'application/vnd.ms-azure-apim.swagger.definitions+json'
    document: { value: loadTextContent('./responses.schema.json') }
  }
}

resource operation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses'
  properties: {
    displayName: 'Create a governed text response'
    description: marker
    method: 'POST'
    urlTemplate: '/v1/responses'
    request: {
      representations: [{ contentType: 'application/json', schemaId: schema.name, typeName: 'ResponsesRequest' }]
    }
  }
  dependsOn: [apiPolicy]
}

var noBodyDiagnostic = {
  request: { headers: ['x-correlation-id'], body: { bytes: 0 } }
  response: { headers: ['x-correlation-id'], body: { bytes: 0 } }
}

resource diagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: api
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: null
    sampling: { samplingType: 'fixed', percentage: 0 }
    frontend: noBodyDiagnostic
    backend: noBodyDiagnostic
    httpCorrelationProtocol: 'None'
    logClientIp: false
    metrics: true
    verbosity: 'information'
    operationNameFormat: 'Name'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: renderPolicy(owner, apiPath, configuration.callerMappings)
  }
  dependsOn: [namedValues, backend, backendAndTelemetryRoles, diagnostic]
}

@description('Owned APIM service resource ID. Not evidence of private readiness.')
output serviceResourceId string = gateway.outputs.resourceId

@description('Owned inbound PE resource ID; completion must verify approval on both PE and APIM sides before disabling public access.')
output privateEndpointResourceId string = gateway.outputs.privateEndpoints[0].resourceId

@description('Backend and monitoring principal, with roles assigned only at the supplied resource scopes.')
output principalId string = gateway.outputs.systemAssignedMIPrincipalId!

@description('The only governed inference route; never a fallback to a direct backend endpoint. Workload-scoped so landing zones sharing this gateway each get a distinct route.')
output inferenceEndpoint string = 'https://${name}.azure-api.net/${apiPath}/v1/responses'

@description('Entra audience of the owned API.')
output audience string = configuration.audience

@description('Nonsecret resource ownership and operational prerequisites. The parent must reconcile only these resources, reject conflicts and preserve unrelated estates.')
output facts object = {
  owner: owner
  workloadKey: workloadKey
  apiPath: apiPath
  serviceResourceId: gateway.outputs.resourceId
  privateEndpointResourceId: gateway.outputs.privateEndpoints[0].resourceId
  apiResourceId: api.id
  operationResourceId: operation.id
  backendResourceId: backend.id
  loggerResourceId: logger.id
  diagnosticResourceId: diagnostic.id
  stopNamedValueResourceId: '${service.id}/namedValues/${owner}-stop'
  backendAccountResourceId: backendAccountResourceId
  initialProvisioning: initialProvisioning
  privateCompletionRequired: initialProvisioning
  stopNewRequests: initialProvisioning || configuration.stopNewRequests
  approvedStopNewRequests: configuration.stopNewRequests
  foundryIntegration: false
  appInsightsDimensionsEnablementRequired: true
  avmVersion: '0.14.4'
  sources: [
    'https://github.com/Azure/bicep-registry-modules/tree/e5823c10bdd9e83a8119d7e2ce40ac1c277fc195/avm/res/api-management/service'
    'https://learn.microsoft.com/azure/api-management/virtual-network-concepts'
    'https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound'
    'https://learn.microsoft.com/azure/api-management/llm-token-limit-policy'
    'https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy'
  ]
}
