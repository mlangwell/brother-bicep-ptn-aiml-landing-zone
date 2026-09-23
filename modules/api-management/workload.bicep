targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Per-workload API Management children
// ---------------------------------------------------------------------------
// These resources belong to ONE landing zone inside a gateway that may be
// shared by many. They are deployed at the GATEWAY's resource group scope,
// which is not necessarily the landing zone's resource group, so the caller
// must supply `scope: resourceGroup(<apimSubscriptionId>, <apimResourceGroup>)`
// when the gateway is platform-owned.
//
// Every resource here is keyed by `workloadKey`. Nothing in this module may be
// named by environment alone: that is precisely the collision this split
// exists to prevent.
//
// Role assignments are deliberately NOT here. They target the landing zone's
// own Foundry account and Application Insights, so they belong at the landing
// zone's scope, not the gateway's.

import { gatewayConfiguration } from './types.bicep'
import { renderPolicy, gatewayNamedValues } from './policy.bicep'

@description('Name of the API Management gateway that hosts these children. Resolved in THIS deployment scope, which is the gateway resource group.')
@minLength(1)
@maxLength(50)
param apiManagementName string

@description('Environment name used in ownership markers and token counter isolation. The GitHub environment pipeline passes dev, test or prod; the azd path passes the azd environment name.')
@minLength(1)
param environmentName string

@description('Landing-zone-scoped key that makes every resource in this module unique within a shared gateway.')
@minLength(3)
@maxLength(24)
param workloadKey string

@description('The approved Entra tenant, not organizations/common.')
@minLength(36)
@maxLength(36)
param tenantId string

@description('Frozen, validated P1 gateway configuration.')
param configuration gatewayConfiguration

@description('Foundry account resource ID backing this landing zone.')
param backendAccountResourceId string

@description('Verified Foundry account HTTPS root endpoint, without an API path, query, credentials or fragment.')
param backendEndpoint string

@description('Existing Application Insights component in the landing zone. Its connection string is read here; it is never emitted as an output.')
param applicationInsightsResourceId string

@description('True only during an observed initial or interrupted provisioning pass. Forces the stop control on until private completion restores the approved setting.')
param initialProvisioning bool = false

var owner = 'ailz-inference-${environmentName}-${workloadKey}'
var apiPath = 'inference/${workloadKey}'
var marker = 'owner:${owner}'
var backendUrl = uri(backendEndpoint, 'openai')

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  scope: resourceGroup(split(applicationInsightsResourceId, '/')[2], split(applicationInsightsResourceId, '/')[4])
  name: last(split(applicationInsightsResourceId, '/'))
}

// Resolves in THIS scope. When the caller supplies the gateway's resource group
// the reference is correct; the previous current-resource-group-only lookup is
// exactly what broke once the gateway moved to platform infrastructure.
resource service 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
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
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: service
  name: owner
  properties: {
    displayName: 'Governed text Responses (${environmentName}/${workloadKey})'
    description: marker
    apiType: 'http'
    path: apiPath
    protocols: ['https']
    subscriptionRequired: false
    serviceUrl: backendUrl
  }
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
  dependsOn: [namedValues, backend, diagnostic]
}

@description('Workload-scoped ownership marker for every resource in this module.')
output owner string = owner

@description('Workload-scoped API path. Distinct per landing zone on a shared gateway.')
output apiPath string = apiPath

@description('The only governed inference route for this landing zone.')
output inferenceEndpoint string = 'https://${apiManagementName}.azure-api.net/${apiPath}/v1/responses'

@description('Nonsecret resource identifiers for reconciliation. The parent must reconcile only these and preserve unrelated estates.')
output facts object = {
  owner: owner
  workloadKey: workloadKey
  apiPath: apiPath
  apiResourceId: api.id
  operationResourceId: operation.id
  backendResourceId: backend.id
  loggerResourceId: logger.id
  diagnosticResourceId: diagnostic.id
  stopNamedValueResourceId: '${service.id}/namedValues/${owner}-stop'
  backendAccountResourceId: backendAccountResourceId
  initialProvisioning: initialProvisioning
  stopNewRequests: initialProvisioning || configuration.stopNewRequests
  approvedStopNewRequests: configuration.stopNewRequests
}
