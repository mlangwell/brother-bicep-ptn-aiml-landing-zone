targetScope = 'resourceGroup'

@description('Environment for this separately authorized identity foundation. A prepared spoke and private ACR are separate administrator prerequisites, verified before main by Assert-PreparedDeploymentFoundation.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environment string

@description('Explicit bootstrap ownership namespace. Must match PlatformInputs.owner.')
@minLength(3)
@maxLength(40)
param owner string

@description('Approved Azure region. There is no generated deployment location.')
param location string

type identityNamesType = {
  preview: string
  deploy: string
  workload: string
}

@description('Three distinct approved identity names. Existing foreign identities must not be overwritten.')
param identityNames identityNamesType

var identityDefinitions = [
  {
    purpose: 'preview'
    name: identityNames.preview
  }
  {
    purpose: 'deploy'
    name: identityNames.deploy
  }
  {
    purpose: 'workload'
    name: identityNames.workload
  }
]

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = [for definition in identityDefinitions: {
  name: definition.name
  location: location
  tags: {
    'ailz-bootstrap-owner': '${owner}:foundation:${environment}'
    'ailz-bootstrap-purpose': definition.purpose
  }
}]

@description('Actual generated IDs for completing a P1 profile. No federation, role assignment, registry, or network is deployed by this foundation.')
output FOUNDATION object = {
  schemaVersion: 1
  environment: environment
  azure: {
    tenantId: tenant().tenantId
    subscriptionId: subscription().subscriptionId
    resourceGroup: resourceGroup().name
    location: location
  }
  identities: {
    preview: {
      resourceId: identities[0].id
      clientId: identities[0].properties.clientId
      principalId: identities[0].properties.principalId
    }
    deploy: {
      resourceId: identities[1].id
      clientId: identities[1].properties.clientId
      principalId: identities[1].properties.principalId
    }
    workload: {
      resourceId: identities[2].id
      clientId: identities[2].properties.clientId
      principalId: identities[2].properties.principalId
    }
  }
}
