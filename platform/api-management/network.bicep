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

@description('Optional route table for the injection subnet. When the platform forces tunnelling by routing 0.0.0.0/0 to a hub firewall, this route table MUST carry a route for the ApiManagement service tag with next hop type Internet, or the gateway loses control-plane connectivity and deployment fails.')
param routeTableResourceId string = ''

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
    routeTable: empty(routeTableResourceId) ? null : {
      id: routeTableResourceId
    }
    serviceEndpoints: dependencyServiceEndpoints
  }
}

@description('Injection subnet resource ID. Pass this to the gateway as subnetResourceId.')
output subnetResourceId string = injectionSubnet.id

@description('Network security group protecting the injection subnet.')
output networkSecurityGroupResourceId string = injectionNsg.outputs.id

@description('Nonsecret network facts for operators and downstream automation.')
output facts object = {
  subnetResourceId: injectionSubnet.id
  subnetAddressPrefix: subnetAddressPrefix
  networkSecurityGroupResourceId: injectionNsg.outputs.id
  networkSecurityGroupRules: injectionNsg.outputs.ruleNames
  delegated: false
  serviceEndpointsEnabled: enableDependencyServiceEndpoints
  routeTableAttached: !empty(routeTableResourceId)
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
