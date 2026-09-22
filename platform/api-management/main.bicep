targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Platform API Management gateway - classic VNet injection, Internal mode
// ---------------------------------------------------------------------------
// API Management is per-subscription platform infrastructure, deployed ONCE per
// subscription and shared by every AI Landing Zone in it. The landing zone
// template consumes this gateway through `existingApiManagementResourceId` and
// only ever creates its own per-workload children (API, backend, logger, named
// values) inside it, keyed by `apiManagementWorkloadKey`.
//
// This template owns the long-lived, service-level surface:
//   - the API Management service and its system-assigned identity
//   - the undelegated injection subnet and its rule-carrying NSG
//   - service-level diagnostics
//
// It deliberately owns NO per-workload resource. Anything keyed by a landing
// zone's workloadKey belongs to the landing zone, not here.
//
// ---------------------------------------------------------------------------
// WHY CLASSIC INJECTION, AND WHY THERE IS NO PRIVATE ENDPOINT HERE
// ---------------------------------------------------------------------------
// An earlier revision of this template implemented the Standard v2 shape:
// outbound VNet integration into a Microsoft.Web/serverFarms-delegated subnet,
// plus an inbound private endpoint, then publicNetworkAccess: 'Disabled'. That
// shape is NOT reachable from here, and the reasons are structural rather than
// stylistic. Verified against Microsoft Learn on 2026-09-22:
//
//  1. Production runs Premium (classic). Learn documents Developer and Premium
//     as ONE network model - both virtual-network-reference and
//     virtual-network-injection-resources are headed "APPLIES TO: Developer |
//     Premium", with the same port table, the same undelegated subnet and the
//     same internal mode. Running Standard v2 in dev/test would have left every
//     non-production environment rehearsing a topology production never uses.
//
//  2. Classic injection and private endpoints are mutually exclusive. Learn,
//     private-endpoint#limitations: "In the classic API Management tiers,
//     private endpoints aren't supported in instances injected in an internal
//     or external virtual network."
//
//  3. Therefore publicNetworkAccess CANNOT be disabled on this gateway. Learn,
//     private-endpoint#optionally-disable-public-network-access: "You can
//     disable public network access in API Management instances configured with
//     a private endpoint, not with other networking configurations."
//
//     This is the single most misread line in this template, so state it
//     plainly: publicNetworkAccess: 'Enabled' below is NOT a weakened posture
//     and NOT a temporary provisioning concession. It is the only legal value
//     for an injected instance, and it does not expose the data plane.
//     Inbound privacy is delivered by virtualNetworkType: 'Internal' instead -
//     Learn, virtual-network-concepts: "The API Management endpoints are
//     accessible only from within the virtual network via an internal load
//     balancer." The instance does still hold a public VIP, but Learn,
//     api-management-using-with-internal-vnet#routing, scopes it precisely:
//     it is "Used *only* for control plane traffic to the management endpoint
//     over port 3443", which the NSG in network.bicep locks to the
//     ApiManagement service tag.
//
//  4. Committing to classic is a one-way door. Learn's v2 FAQ: "Currently,
//     there's no automated tooling to migrate an existing API Management
//     instance (in the Consumption, Developer, Basic, Standard, or Premium
//     tier) to a new v2 tier instance."
//
// Do not reintroduce privateEndpoints, privateDnsZoneResourceId or an
// initialProvisioning/public-disable sequence here. On this topology they are
// not merely unnecessary; they are invalid.

import * as const from '../../constants/constants.bicep'

@description('API Management service name. Globally unique within azure-api.net.')
@minLength(1)
@maxLength(50)
param name string

@description('Region for the gateway and its injection subnet. Learn requires the service, virtual network and subnet to share a region and subscription.')
param location string = resourceGroup().location

@description('Free-form environment label for tagging and traceability, for example sandbox, dev, test or prod. This is deliberately NOT the dev|test|prod landing zone enum: sandbox is a supported gateway subscription but sits outside that enum and keeps its own isolated CI/CD. It gates no resource.')
@minLength(1)
param environmentTag string

// ---------------------------------------------------------------------------
// Tier
// ---------------------------------------------------------------------------
// Developer is, for networking purposes, a one-unit Premium: identical
// injection model, identical required ports, identical internal mode. That is
// exactly why non-production uses it - it rehearses the production topology at
// roughly 1/60th of the Premium unit price - while remaining explicitly
// unsuitable for production itself. Learn: "The Developer tier is for
// non-production use cases and evaluations. It doesn't offer SLA."
//
// The v2 tiers are rejected outright: Standard v2 cannot be injected at all,
// and Premium v2 uses a different, delegated-subnet injection model.
@description('Gateway tier. Developer for sandbox/dev/test, Premium for production. Both use the same classic VNet injection model, so one topology serves every subscription. Developer carries no SLA and is capped at a single unit.')
param sku 'Developer' | 'Premium' = 'Developer'

@description('Scale units. Ignored on Developer, which Learn caps at exactly one unit and which cannot add or remove units. On Premium, Learn recommends at least 2 units for zone redundancy to be meaningful.')
@minValue(1)
@maxValue(31)
param capacity int = 1

// ---------------------------------------------------------------------------
// Zone redundancy - READ THIS BEFORE CHANGING
// ---------------------------------------------------------------------------
// Verified against AVM avm/res/api-management/service 0.14.4, which emits:
//   zones: [if(contains(sku,'Premium'), map(availabilityZones, ...), [])]
//
// So on Developer this list is inert, and on Premium it selects between two
// DIFFERENT behaviours:
//
//   []        -> AUTOMATIC zone redundancy. Azure distributes units across the
//                zones available in the region. This is the recommended mode.
//   [1,2,3]   -> MANUAL zone selection. Learn: "the number of units that you
//                select must distribute evenly across the availability zones."
//                Premium with capacity: 1 and three zones therefore FAILS.
//
// The AVM default for this parameter is [1,2,3], not []. Leaving it unset would
// silently opt into manual mode and break a single-unit Premium deployment, so
// this template defaults it to [] explicitly and passes it through every time.
@description('Availability zones for Premium. Leave EMPTY (the default) to select automatic zone redundancy, which is the recommended mode. Supplying explicit zones switches to manual mode, where capacity MUST be an exact multiple of the number of zones - Premium at capacity 1 with [1,2,3] will fail to deploy. Inert on Developer.')
param availabilityZones int[] = []

@description('Publisher email recorded on the service.')
@minLength(1)
param publisherEmail string

@description('Publisher organization recorded on the service.')
@minLength(1)
param publisherName string

@description('Existing platform virtual network that hosts the gateway. May live in another resource group in this subscription; the injection subnet is created inside it.')
@minLength(1)
param platformVirtualNetworkResourceId string

@description('Name of the undelegated injection subnet in the platform virtual network. Dedicated to API Management; never shared with a landing zone application or agent subnet.')
@minLength(1)
param injectionSubnetName string

@description('Address prefix for the injection subnet. /27 is the standard for this landing zone and allows up to 13 Premium units; /29 is the Azure minimum but caps the instance at one unit.')
@minLength(1)
param injectionSubnetPrefix string

@description('Set false when the platform team owns the injection subnet and its NSG outside this template. The existing subnet must then be UNDELEGATED and carry the required NSG rules - see network.bicep for the authoritative rule set.')
param deployInjectionSubnet bool = true

@description('Optional route table for the injection subnet. When the platform forces tunnelling by routing 0.0.0.0/0 to a hub firewall - which is this landing zone default - the route table MUST carry a route for the ApiManagement service tag with next hop type Internet. See the operatorObligations output.')
param routeTableResourceId string = ''

@description('Enable service endpoints for Storage, SQL, Key Vault and Event Hubs on the injection subnet. Strongly recommended by Learn whenever the subnet is force tunnelled.')
param enableDependencyServiceEndpoints bool = true

@description('Existing Log Analytics workspace for service-level diagnostics.')
@minLength(1)
param logAnalyticsWorkspaceResourceId string

@description('Tags applied to the gateway and its owned network resources.')
param tags object = {}

var ownedTags = union(tags, {
  'ailz-managed-by': 'github-dev-environment'
  'ailz-environment': environmentTag
  'ailz-component': 'platform-api-management'
})

// Developer cannot scale. Forcing the value here rather than trusting the
// caller keeps a copy-pasted capacity: 3 from a Premium profile from producing
// a deployment error that reads as an unrelated quota failure.
var effectiveCapacity = sku == 'Developer' ? 1 : capacity

// Inert on Developer (AVM emits [] for any non-Premium SKU), but passed
// explicitly so the automatic-vs-manual choice is always deliberate.
var effectiveAvailabilityZones = sku == 'Premium' ? availabilityZones : []

var zoneRedundancyMode = sku != 'Premium'
  ? 'unavailable'
  : (empty(availabilityZones) ? 'automatic' : 'manual')

var virtualNetworkSegments = split(platformVirtualNetworkResourceId, '/')
var virtualNetworkSubscriptionId = virtualNetworkSegments[2]
var virtualNetworkResourceGroupName = virtualNetworkSegments[4]
var virtualNetworkName = last(virtualNetworkSegments)
var injectionSubnetResourceId = '${platformVirtualNetworkResourceId}/subnets/${injectionSubnetName}'

module injectionNetwork './network.bicep' = if (deployInjectionSubnet) {
  name: 'platformApimInjectionNetwork'
  scope: resourceGroup(virtualNetworkSubscriptionId, virtualNetworkResourceGroupName)
  params: {
    networkSecurityGroupName: '${const.abbrs.networking.networkSecurityGroup}${name}'
    location: location
    virtualNetworkName: virtualNetworkName
    subnetName: injectionSubnetName
    subnetAddressPrefix: injectionSubnetPrefix
    routeTableResourceId: routeTableResourceId
    enableDependencyServiceEndpoints: enableDependencyServiceEndpoints
    tags: ownedTags
  }
}

module gateway 'br/public:avm/res/api-management/service:0.14.4' = {
  name: 'platformApiManagementService'
  params: {
    name: name
    location: location
    tags: ownedTags
    sku: sku
    skuCapacity: effectiveCapacity
    publisherEmail: publisherEmail
    publisherName: publisherName
    managedIdentities: { systemAssigned: true }
    enableTelemetry: false
    enableDeveloperPortal: false
    availabilityZones: effectiveAvailabilityZones
    customProperties: {}
    // Internal mode IS the inbound privacy control on this topology. The
    // gateway, developer portal, management plane and Git endpoints are
    // reachable only through the internal load balancer inside the VNet.
    virtualNetworkType: 'Internal'
    subnetResourceId: injectionSubnetResourceId
    // Classic injection cannot hold a private endpoint, and Learn permits
    // disabling public network access ONLY on instances that have one. This is
    // the sole legal value here - see the header block. It does not expose the
    // data plane; the public VIP serves control-plane 3443 only, and the NSG
    // restricts even that to the ApiManagement service tag.
    publicNetworkAccess: 'Enabled'
    privateEndpoints: []
    diagnosticSettings: [
      {
        name: 'platform-api-management-monitor'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: []
        metricCategories: [{ category: 'AllMetrics' }]
      }
    ]
  }
  dependsOn: [
    injectionNetwork
  ]
}

// Read back the deployed instance purely to surface its dynamically assigned
// private VIP. Learn: "The private IP addresses of internal load balancer and
// API Management units are assigned dynamically. Therefore, it is impossible to
// anticipate the private IP of the API Management instance prior to its
// deployment." Operators need this value to create the DNS A record, which is
// why it is surfaced rather than left to a manual portal lookup.
resource deployedGateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: name
}

@description('Platform gateway resource ID. Pass this to the landing zone as existingApiManagementResourceId.')
output resourceId string = gateway.outputs.resourceId

@description('Platform gateway name.')
output name string = gateway.outputs.name

@description('System-assigned identity of the gateway. Pass this to the landing zone as existingApiManagementPrincipalId so it can grant the backend inference and telemetry roles without reading properties off a cross-resource-group existing reference.')
output principalId string = gateway.outputs.systemAssignedMIPrincipalId!

@description('Gateway service root. Landing zones append their own workload-scoped route; this is never itself a callable inference endpoint. In Internal mode this hostname does NOT resolve publicly - it must be resolved to the private VIP by customer-managed DNS.')
output gatewayUrl string = 'https://${name}.azure-api.net'

@description('Gateway hostname. This is the exact name the private DNS A record must serve, and the exact Host header callers must send: API Management responds only to requests addressed to its configured host names and does not listen on its private IP directly.')
output gatewayHostName string = '${name}.azure-api.net'

@description('Dynamically assigned private VIP of the internal load balancer. This is the address the DNS A record must point at. Empty until the instance finishes provisioning, and it can change if the instance is moved to a different subnet.')
output gatewayPrivateIpAddress string = length(deployedGateway.properties.?privateIPAddresses ?? []) > 0
  ? (deployedGateway.properties.?privateIPAddresses ?? [''])[0]
  : ''

@description('Undelegated injection subnet used by the gateway.')
output injectionSubnetResourceId string = injectionSubnetResourceId

@description('Nonsecret platform facts for operators and downstream automation.')
output facts object = {
  resourceId: gateway.outputs.resourceId
  name: gateway.outputs.name
  hostName: '${name}.azure-api.net'
  environmentTag: environmentTag
  sku: sku
  requestedCapacity: capacity
  effectiveCapacity: effectiveCapacity
  capacityClampedByTier: sku == 'Developer' && capacity != 1
  networkModel: 'classic-vnet-injection'
  virtualNetworkType: 'Internal'
  injectionSubnetResourceId: injectionSubnetResourceId
  subnetDelegated: false
  privateEndpointSupported: false
  publicNetworkAccess: 'Enabled'
  publicNetworkAccessRationale: 'Classic injected instances cannot hold a private endpoint, and Learn permits disabling public network access only on instances that have one. Enabled is the sole legal value. Inbound privacy comes from virtualNetworkType Internal; the public VIP serves control-plane 3443 only and the NSG restricts it to the ApiManagement service tag.'
  zoneRedundancyMode: zoneRedundancyMode
  zoneRedundancyNote: zoneRedundancyMode == 'manual'
    ? 'Manual zone selection is active. Capacity MUST be an exact multiple of the number of selected zones or the deployment fails. Prefer an empty availabilityZones list for automatic zone redundancy.'
    : (zoneRedundancyMode == 'automatic'
        ? 'Automatic zone redundancy. Learn recommends at least 2 units for zone redundancy to be meaningful; at capacity 1 there is no cross-zone unit distribution to protect.'
        : 'Zone redundancy is a Premium capability. Developer is single-unit with no SLA and is not production-eligible.')
  slaBackedTier: sku == 'Premium'
  migrationToV2Available: false
  avmVersion: '0.14.4'
  // Things this template CANNOT do for the operator, stated explicitly so they
  // are not mistaken for delivered behaviour.
  operatorObligations: [
    'DNS A record: create a private DNS zone named exactly "${name}.azure-api.net" holding an apex (@) A record that points at the gatewayPrivateIpAddress output, and link that zone to the platform VNet and to every landing zone spoke VNet that must reach the gateway. In Internal mode Learn requires customer-managed DNS: "you must provide your own DNS solution".'
    'NEVER create a private DNS zone for the apex domain "azure-api.net". Learn: "Do not create a Private DNS zone or forward lookup zone for azure-api.net." It is a shared public Azure domain; an apex private zone becomes authoritative inside the VNet and breaks resolution for other Azure services.'
    'DNS ordering: if the platform VNet uses custom DNS servers, configure them BEFORE deploying this gateway. Learn: otherwise "you\'ll need to update the API Management service each time you change the DNS server(s) by running the Apply Network Configuration Operation".'
    'Forced tunnelling: if the injection subnet routes 0.0.0.0/0 to a hub firewall, add a user-defined route for the ApiManagement service tag with next hop type Internet. Learn: when force tunnelled "the responses won\'t symmetrically map back to these inbound source IPs and connectivity to the management endpoint is lost". Learn also states this bypass "isn\'t considered a significant security risk" because inbound 3443 is already restricted to the ApiManagement service tag.'
    'Hub firewall egress: an NSG allow rule is not sufficient when egress is tunnelled. The firewall must also permit the gateway\'s outbound dependencies, or service endpoints must carry them off the tunnelled path (enableDependencyServiceEndpoints, on by default).'
    'Spoke reachability: peer each landing zone spoke to the platform VNet, and ensure the gateway can resolve each spoke\'s Foundry privatelink zones while each spoke can resolve this gateway hostname.'
  ]
  sources: [
    'https://learn.microsoft.com/azure/api-management/virtual-network-concepts'
    'https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources'
    'https://learn.microsoft.com/azure/api-management/virtual-network-reference'
    'https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet'
    'https://learn.microsoft.com/azure/api-management/private-endpoint'
    'https://learn.microsoft.com/azure/api-management/enable-availability-zone-support'
  ]
}
