targetScope = 'resourceGroup'

import * as const from '../../constants/constants.bicep'
import { gatewayConfiguration } from './types.bicep'

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

@description('Dedicated UNDELEGATED injection subnet with the API Management NSG rule set, routes, DNS and egress; never the app or agent subnet. Classic VNet injection forbids subnet delegation - Learn: "The subnet used to connect to the API Management instance shouldn\'t have any delegations enabled."')
param integrationSubnetResourceId string

@description('Foundry account resource ID; only the gateway identity receives the backend inference role here.')
param backendAccountResourceId string

@description('Verified Foundry account HTTPS root endpoint, without an API path, query, credentials or fragment.')
param backendEndpoint string

@description('Existing Application Insights component. Its resource properties are read internally; no connection string is output.')
param applicationInsightsResourceId string

@description('Existing Log Analytics workspace for owned service diagnostics. This does not create competing AMPLS/DNS topology.')
param logAnalyticsWorkspaceResourceId string

@description('Existing Standard SKU public IP to associate with the gateway. Azure REQUIRES one whenever availability zone support is enabled on an injected instance, which means whenever the tier is Premium. Leave empty on Premium to have a zone-redundant one created automatically. Ignored on Developer, which has no availability zones and, since May 2024, needs no public IP to be injected in internal mode. In Internal mode this address carries management operations only, NOT API requests, so it does not expose the data plane.')
param publicIpAddressResourceId string = ''

// Kept in step with platform/api-management/main.bicep, which exposes the same
// knob. A public IP carrying `zones` cannot deploy into a region that has no
// availability zones, so a hardcoded [1,2,3] would make Premium undeployable
// there. Set this to [] for such a region; the gateway is not zone redundant
// there either, so a regional address is the correct pairing.
@description('Availability zones for the automatically created public IP. Must match the zone redundancy of the gateway itself. Set to an empty list ONLY when deploying into a region with no availability zone support, where a zonal public IP cannot be created.')
param publicIpAvailabilityZones int[] = [1, 2, 3]

@description('Deployment tags, merged with the reserved gateway ownership marker.')
param tags object = {}

@description('True only during an observed initial or interrupted provisioning pass. On classic VNet injection this NO LONGER gates public network access - see the block above - it holds the workload stop control on so the gateway serves no request until the operator has created the private DNS A record and verified resolution.')
param initialProvisioning bool = false

// One gateway is shared by many landing zones, so every per-workload resource
// name and the public route are keyed by workloadKey. Keying by environmentName
// alone collides the moment a second landing zone lands in the same
// subscription and environment — which is the whole point of the shared model.
// The workload-scoped children themselves live in ./workload.bicep so the same
// code path serves a platform-owned gateway in another resource group.
var owner = 'ailz-inference-${environmentName}-${workloadKey}'
var ownedTags = union(tags, {
  'ailz-managed-by': 'github-dev-environment'
  'ailz-environment': environmentName
  'ailz-owner': owner
})

// Only Premium has availability zones, and Azure requires a public IP whenever
// zone support is enabled on an injected instance. See the comment block on the
// gateway module below.
var _needsPublicIp = configuration.sku == 'Premium'
var _createPublicIp = _needsPublicIp && empty(publicIpAddressResourceId)
var _effectivePublicIpResourceId = !empty(publicIpAddressResourceId)
  ? publicIpAddressResourceId
  : (_createPublicIp ? gatewayPublicIp!.outputs.resourceId : '')

module gatewayPublicIp '../networking/api-management-public-ip.bicep' = if (_createPublicIp) {
  name: '${owner}-pip'
  params: {
    name: '${const.abbrs.networking.publicIPAddress}${name}'
    location: location
    domainNameLabel: toLower(name)
    availabilityZones: publicIpAvailabilityZones
    tags: ownedTags
  }
}

// ---------------------------------------------------------------------------
// Network topology: classic VNet injection, Internal mode
// ---------------------------------------------------------------------------
// This module previously implemented the Standard v2 shape - outbound VNet
// integration into a Microsoft.Web/serverFarms-delegated subnet plus an inbound
// private endpoint, then publicNetworkAccess: 'Disabled'. That shape is not
// reachable on the Developer and Premium classic tiers this landing zone now
// targets, and the reasons are structural. Verified against Learn 2026-09-22:
//
//   - "In the classic API Management tiers, private endpoints aren't supported
//     in instances injected in an internal or external virtual network."
//   - "You can disable public network access in API Management instances
//     configured with a private endpoint, not with other networking
//     configurations."
//
// So publicNetworkAccess: 'Enabled' below is the ONLY legal value here. It is
// not a weakened posture. Inbound privacy comes from Internal mode instead -
// "None of the API Management endpoints are registered on the public DNS. The
// endpoints remain inaccessible until you configure DNS for the VNet." The
// instance keeps a public VIP, but it serves control-plane 3443 only, and the
// injection NSG restricts even that to the ApiManagement service tag.
//
// Do not reintroduce privateEndpoints or a public-disable sequence here: on
// this topology they are invalid, not merely redundant.
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
    // Empty selects AUTOMATIC zone redundancy on Premium and is inert on
    // Developer. The AVM default is [1,2,3], which is MANUAL mode and requires
    // capacity to be an exact multiple of the zone count, so it must be passed
    // explicitly rather than left to the default.
    availabilityZones: []
    customProperties: {}
    virtualNetworkType: 'Internal'
    subnetResourceId: integrationSubnetResourceId
    // Required by Azure for a zone-redundant injected instance. Learn:
    // "When you enable availability zone support on an API Management instance
    // that's deployed in an external or internal virtual network, you must
    // specify a public IP address resource for the instance to use. In an
    // internal virtual network, the public IP address is used only for
    // management operations, not for API requests."
    publicIpAddressResourceId: empty(_effectivePublicIpResourceId) ? null : _effectivePublicIpResourceId
    publicNetworkAccess: 'Enabled'
    privateEndpoints: []
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

// Per-workload children live in their own module so the same code path serves
// both a landing-zone-created gateway (this module, same resource group) and a
// shared platform gateway (main.bicep, scoped to the platform resource group).
module workload './workload.bicep' = {
  name: '${owner}-workload'
  params: {
    apiManagementName: name
    environmentName: environmentName
    workloadKey: workloadKey
    tenantId: tenantId
    configuration: configuration
    backendAccountResourceId: backendAccountResourceId
    backendEndpoint: backendEndpoint
    applicationInsightsResourceId: applicationInsightsResourceId
    initialProvisioning: initialProvisioning
  }
  dependsOn: [
    gateway
    backendAndTelemetryRoles
  ]
}

// Read back the deployed instance purely to surface its dynamically assigned
// private VIP. Learn: "it is impossible to anticipate the private IP of the API
// Management instance prior to its deployment." Operators need this value to
// create the DNS A record that makes the gateway reachable at all.
resource deployedGateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: name
}

@description('Owned APIM service resource ID. Not evidence of private readiness: on classic injection readiness also requires the private DNS A record described in facts.operatorObligations.')
output serviceResourceId string = gateway.outputs.resourceId

@description('Gateway hostname. This is the exact name the private DNS A record must serve and the exact Host header callers must send: API Management responds only to requests addressed to its configured host names and does not listen on its private IP directly.')
output gatewayHostName string = '${name}.azure-api.net'

@description('Dynamically assigned private VIP of the internal load balancer - the address the DNS A record must point at. Empty until provisioning completes, and it can change if the instance moves subnet.')
output gatewayPrivateIpAddress string = length(deployedGateway.properties.?privateIPAddresses ?? []) > 0
  ? (deployedGateway.properties.?privateIPAddresses ?? [''])[0]
  : ''

@description('Backend and monitoring principal, with roles assigned only at the supplied resource scopes.')
output principalId string = gateway.outputs.systemAssignedMIPrincipalId!

@description('The only governed inference route; never a fallback to a direct backend endpoint. Workload-scoped so landing zones sharing this gateway each get a distinct route.')
output inferenceEndpoint string = workload.outputs.inferenceEndpoint

@description('Entra audience of the owned API.')
output audience string = configuration.audience

@description('Nonsecret resource ownership and operational prerequisites. The parent must reconcile only these resources, reject conflicts and preserve unrelated estates.')
output facts object = union(workload.outputs.facts, {
  serviceResourceId: gateway.outputs.resourceId
  hostName: '${name}.azure-api.net'
  networkModel: 'classic-vnet-injection'
  virtualNetworkType: 'Internal'
  injectionSubnetResourceId: integrationSubnetResourceId
  subnetDelegated: false
  privateEndpointSupported: false
  publicNetworkAccess: 'Enabled'
  publicIpAddressResourceId: _effectivePublicIpResourceId
  publicIpAddressCreated: _createPublicIp
  publicIpRequiredForZoneRedundancy: _needsPublicIp
  publicNetworkAccessRationale: 'Classic injected instances cannot hold a private endpoint, and Learn permits disabling public network access only on instances that have one. Enabled is the sole legal value. Inbound privacy comes from virtualNetworkType Internal - no API Management endpoint is registered on public DNS - and the public VIP serves control-plane 3443 only, restricted by NSG to the ApiManagement service tag.'
  privateCompletionRequired: false
  foundryIntegration: false
  appInsightsDimensionsEnablementRequired: true
  avmVersion: '0.14.4'
  operatorObligations: [
    'DNS A record: create a private DNS zone named exactly "${name}.azure-api.net" holding an apex (@) A record pointing at the gatewayPrivateIpAddress output, linked to every VNet that must reach the gateway. Internal mode has no public DNS registration: "The endpoints remain inaccessible until you configure DNS for the VNet."'
    'Re-check that A record after ANY availability zone change on Premium. Learn: changing the availability zone configuration "changes the public virtual IP (VIP) address and, if the instance is deployed in internal virtual network mode, the private VIP address."'
    'NEVER create a private DNS zone for the apex domain "azure-api.net". Learn: "Do not create a Private DNS zone or forward lookup zone for azure-api.net." It is a shared public Azure domain and an apex private zone breaks resolution for other Azure services.'
    'Forced tunnelling: if the injection subnet routes 0.0.0.0/0 to a hub firewall, add a user-defined route for the ApiManagement service tag with next hop type Internet, or control-plane connectivity is lost and deployment fails.'
    'Backend resolution: the injection subnet must resolve the Foundry account privatelink zone so the gateway can reach the private-endpoint-only backend.'
  ]
  sources: [
    'https://github.com/Azure/bicep-registry-modules/tree/e5823c10bdd9e83a8119d7e2ce40ac1c277fc195/avm/res/api-management/service'
    'https://learn.microsoft.com/azure/api-management/virtual-network-concepts'
    'https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources'
    'https://learn.microsoft.com/azure/api-management/virtual-network-reference'
    'https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet'
    'https://learn.microsoft.com/azure/api-management/private-endpoint'
    'https://learn.microsoft.com/azure/api-management/llm-token-limit-policy'
    'https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy'
  ]
})
