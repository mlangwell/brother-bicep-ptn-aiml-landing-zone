targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Platform API Management injection subnet and its mandatory NSG
// ---------------------------------------------------------------------------
// Classic VNet injection (Developer and Premium) is a fundamentally different
// network model from v2 integration, and the two shared networking helpers
// cannot express it:
//
//   - modules/networking/network-security-group.bicep creates an NSG with NO
//     rules. Harmless for v2 outbound integration, FATAL here: Learn states
//     "A network security group (NSG) is required to explicitly allow inbound
//     connectivity, because the load balancer used internally by API Management
//     is secure by default and rejects all inbound traffic."
//   - The injection subnet must NOT be delegated. Learn: "The subnet used to
//     connect to the API Management instance shouldn't have any delegations
//     enabled."
//
// The rule set itself lives in modules/networking/api-management-injection-nsg.bicep
// so this platform path and the landing-zone-created path in main.bicep share
// one authoritative definition and cannot drift apart.
//
// Deploy this at the scope of the resource group that owns the platform VNet.
//
// Sources (re-read 2026-09-22):
//   https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources
//   https://learn.microsoft.com/azure/api-management/virtual-network-reference
//   https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet

@description('Name of the network security group created for the injection subnet.')
@minLength(1)
@maxLength(80)
param networkSecurityGroupName string

@description('Region of the NSG. Must match the API Management instance, the virtual network and the subnet.')
param location string = resourceGroup().location

@description('Existing platform virtual network that hosts the injection subnet. Must be in the same region and subscription as the gateway.')
@minLength(1)
param virtualNetworkName string

@description('Name of the injection subnet created in the platform virtual network. Dedicated to API Management; never shared with a landing zone application or agent subnet.')
@minLength(1)
param subnetName string

// ---------------------------------------------------------------------------
// Subnet sizing - verified against the Learn sizing table
// ---------------------------------------------------------------------------
// | CIDR | Total | Azure reserved | Instance | ILB | Max total units |
// | /29  |   8   |       5        |    2     |  1  |        1        |
// | /28  |  16   |       5        |    2     |  1  |        5        |
// | /27  |  32   |       5        |    2     |  1  |       13        |
//
// Developer consumes one instance IP and cannot scale past a single unit, so
// /29 would technically fit it. This landing zone standardises on /27 in every
// subscription so the IaC is identical across sandbox/dev/test/prod and the
// Premium production gateway has real headroom. Learn: "When considering a
// subnet size, it is advisable to err on the side of caution due to the
// integral role that API Management typically holds."
@description('Address prefix for the injection subnet. /27 is the standard for this landing zone (13 max units). /29 is the documented Azure minimum but caps the instance at a single unit with no scale-out room.')
@minLength(1)
param subnetAddressPrefix string

// ---------------------------------------------------------------------------
// Egress routing - the ApiManagement service tag route is NOT optional
// ---------------------------------------------------------------------------
// Learn, api-management-using-with-internal-vnet, "Force tunnel traffic to
// on-premises firewall using ExpressRoute or network virtual appliance":
//
//   "All the control plane traffic from the internet to the management endpoint
//    of your API Management service is routed through a specific set of inbound
//    IPs, hosted by API Management, encompassed by the ApiManagement service
//    tag. When the traffic is force tunneled, the responses won't symmetrically
//    map back to these inbound source IPs and connectivity to the management
//    endpoint is lost. To overcome this limitation, configure a user-defined
//    route (UDR) for the ApiManagement service tag with next hop type set to
//    'Internet', to steer traffic back to Azure."
//
// A force tunnelled injection subnet without that route yields a gateway that
// fails to provision, or provisions and then loses management connectivity. It
// is therefore a hard requirement of this topology, not an operator nicety.
//
// This contract was previously a single optional `routeTableResourceId`, which
// let the caller create a force tunnelled subnet with NO route table and no
// route at all - the failure mode above, expressed silently by omission. It is
// now a discriminated union so the broken combination cannot be written down:
// every mode either carries the mandatory route or explicitly declares that the
// subnet is not force tunnelled. It also makes "route table AND next hop"
// unrepresentable, which on the landing zone path needs a preflight check.
@export()
@discriminator('mode')
@description('Who owns egress routing for the injection subnet, and therefore who carries the mandatory ApiManagement -> Internet route.')
type injectionEgressRouting = managedEgressRouting | operatorEgressRouting | unroutedEgress

@sealed()
@description('This module owns a dedicated route table carrying BOTH mandatory routes: ApiManagement -> Internet, and 0.0.0.0/0 -> the hub firewall or NVA. Use this whenever the platform force tunnels and has not already built a route table for the subnet.')
type managedEgressRouting = {
  mode: 'managed'

  @description('Private IP of the hub firewall or network virtual appliance that receives the 0.0.0.0/0 default route.')
  @minLength(7)
  nextHopIpAddress: string
}

@sealed()
@description('The platform team owns the route table. This module attaches it and writes nothing into it, matching main.bicep, which likewise declines to write into a route table it does not own. The ApiManagement -> Internet obligation transfers to the operator and is restated in the operatorObligations output.')
type operatorEgressRouting = {
  mode: 'operator'

  @description('Existing route table to attach to the injection subnet. It MUST already carry a route for the ApiManagement service tag with next hop type Internet whenever it sends 0.0.0.0/0 to a firewall or NVA.')
  @minLength(1)
  routeTableResourceId: string
}

@sealed()
@description('Deliberate declaration that the injection subnet is NOT force tunnelled, so Azure default system routes apply and no route table is attached. Choose this only after confirming the platform VNet has no 0.0.0.0/0 override - including one learned over BGP from an ExpressRoute or VPN gateway, which force tunnels a subnet that has no route table of its own and is the silent version of this failure.')
type unroutedEgress = {
  mode: 'none'
}

@description('Egress routing contract for the injection subnet. See injectionEgressRouting: managed (this module builds the route table and both mandatory routes), operator (attach a platform-owned route table), or none (explicitly not force tunnelled).')
param egressRouting injectionEgressRouting

@description('Name of the route table created when egressRouting.mode is managed. Ignored in every other mode.')
@minLength(1)
@maxLength(80)
param routeTableName string

// ---------------------------------------------------------------------------
// Service endpoints and forced tunnelling
// ---------------------------------------------------------------------------
// Learn, "Force tunnel traffic to on-premises firewall": "We strongly recommend
// enabling service endpoints directly from the API Management subnet to
// dependent services such as Azure SQL and Azure Storage that support them."
// With service endpoints this traffic uses the Azure backbone and is NOT force
// tunnelled, so a hub firewall cannot silently break the gateway's hard
// dependencies. Without them the firewall must allow the complete, moving IP
// range of every dependent service and keep it current.
@description('Enable service endpoints for the API Management hard dependencies (Storage, SQL, Key Vault, Event Hubs). Strongly recommended by Learn whenever the subnet is force tunnelled through a hub firewall, which is this landing zone default. Disable only when the platform team has explicitly opened the equivalent egress on the firewall.')
param enableDependencyServiceEndpoints bool = true

@description('Tags applied to the network security group. Subnets are child resources and cannot carry tags.')
param tags object = {}

var dependencyServiceEndpoints = enableDependencyServiceEndpoints
  ? [
      { service: 'Microsoft.Storage' }
      { service: 'Microsoft.Sql' }
      { service: 'Microsoft.KeyVault' }
      { service: 'Microsoft.EventHub' }
    ]
  : []

var _managedEgress = egressRouting.mode == 'managed'
var _operatorRouteTableId = string(egressRouting.?routeTableResourceId ?? '')

// The two routes are declared inline on the parent rather than as child
// resources so the table can never exist in a half-built state: ARM creates it
// with both routes or not at all. The gateway depends on the subnet, the subnet
// depends on this table, so the mandatory route is in place before the ~30
// minute gateway create begins - which matters, because the control plane needs
// it DURING provisioning, not afterwards.
resource injectionRouteTable 'Microsoft.Network/routeTables@2024-07-01' = if (_managedEgress) {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    // The gateway's control-plane exception must not be undone by a hub route
    // learned over BGP, so propagation is disabled here exactly as it is on the
    // landing zone's dedicated API Management route table.
    disableBgpRoutePropagation: true
    routes: [
      {
        // The sole forced-tunnelling exception. Learn: this bypass "isn't
        // considered a significant security risk" because inbound 3443 is
        // already restricted to the ApiManagement service tag by the NSG, and
        // the UDR covers only the return path of that Azure traffic.
        name: 'api-management-control-plane'
        properties: {
          addressPrefix: 'ApiManagement'
          nextHopType: 'Internet'
        }
      }
      {
        name: 'default-to-egress'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: string(egressRouting.?nextHopIpAddress ?? '')
        }
      }
    ]
  }
}

#disable-next-line BCP318
var _effectiveRouteTableId = _managedEgress ? injectionRouteTable.id : _operatorRouteTableId

module injectionNsg '../../modules/networking/api-management-injection-nsg.bicep' = {
  name: 'platformApimInjectionNsg'
  params: {
    name: networkSecurityGroupName
    location: location
    tags: tags
  }
}

// The injection subnet is declared inline rather than through
// modules/networking/subnet.bicep so the no-delegation invariant is visible and
// enforceable at the point of declaration. `delegations` is an empty array and
// must stay that way: a delegated subnet cannot host an injected instance.
resource injectionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  name: '${virtualNetworkName}/${subnetName}'
  properties: {
    addressPrefix: subnetAddressPrefix
    // MUST remain empty. Learn: "The subnet used to connect to the API
    // Management instance shouldn't have any delegations enabled."
    delegations: []
    networkSecurityGroup: {
      id: injectionNsg.outputs.id
    }
    routeTable: empty(_effectiveRouteTableId) ? null : {
      id: _effectiveRouteTableId
    }
    serviceEndpoints: dependencyServiceEndpoints
  }
}

@description('Injection subnet resource ID. Pass this to the gateway as subnetResourceId.')
output subnetResourceId string = injectionSubnet.id

@description('Network security group protecting the injection subnet.')
output networkSecurityGroupResourceId string = injectionNsg.outputs.id

@description('Route table attached to the injection subnet. Empty only when egressRouting.mode is none, which declares the subnet is not force tunnelled.')
output routeTableResourceId string = _effectiveRouteTableId

@description('Nonsecret network facts for operators and downstream automation.')
output facts object = {
  subnetResourceId: injectionSubnet.id
  subnetAddressPrefix: subnetAddressPrefix
  networkSecurityGroupResourceId: injectionNsg.outputs.id
  networkSecurityGroupRules: injectionNsg.outputs.ruleNames
  delegated: false
  serviceEndpointsEnabled: enableDependencyServiceEndpoints
  egressRoutingMode: egressRouting.mode
  routeTableResourceId: _effectiveRouteTableId
  routeTableAttached: !empty(_effectiveRouteTableId)
  routeTableManagedHere: _managedEgress
  // The single fact that says whether the Learn-mandated control-plane
  // exception actually exists, as opposed to having been asked for in prose.
  apiManagementServiceTagRouteGuaranteed: _managedEgress
  apiManagementServiceTagRouteNote: _managedEgress
    ? 'This module created the ApiManagement -> Internet route and the 0.0.0.0/0 route to ${string(egressRouting.?nextHopIpAddress ?? '')} on route table ${routeTableName}.'
    : (egressRouting.mode == 'operator'
        ? 'OPERATOR OBLIGATION: this module attached a route table it does not own and wrote no routes into it. Confirm it carries addressPrefix "ApiManagement" with nextHopType "Internet" before provisioning, or the gateway loses control-plane connectivity.'
        : 'The caller declared this subnet is NOT force tunnelled, so Azure default system routes apply. Re-check if a 0.0.0.0/0 override is ever introduced, including one learned over BGP from an ExpressRoute or VPN gateway.')
  externalModeRulesDeliberatelyAbsent: [
    'Internet:80,443 inbound - external mode only; adding it would expose the data plane'
    'AzureTrafficManager:443 inbound - external multi-region only'
  ]
  sources: [
    'https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources'
    'https://learn.microsoft.com/azure/api-management/virtual-network-reference'
    'https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet'
  ]
}
