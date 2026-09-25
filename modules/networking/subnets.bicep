targetScope = 'resourceGroup'

param vnetName string
param location string
param resourceGroupName string
param subscriptionId string = subscription().subscriptionId
param tags object = {}
param subnets array = []
param addressPrefixes array
param useExistingVNet bool = false
param deploySubnets bool = true
param deployNsgs bool = true
param prefix string = 'nsg-'
param virtualNetworkResourceId string

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.0' = if (!useExistingVNet && deploySubnets) {
  name: 'virtualNetworkDeployment'
  scope: resourceGroup(subscriptionId, resourceGroupName)
  params: {
    addressPrefixes: addressPrefixes
    name: vnetName
    location: location
    tags: tags
    subnets: subnets
  }
}

module nsgsM 'network-security-group.bicep' = [
  for subnet in subnets : if (deploySubnets && deployNsgs) {
    name: '${prefix}${vnetName}-${subnet.name}'
    scope: resourceGroup(subscriptionId, resourceGroupName)
    params : {
      name: '${prefix}${vnetName}-${subnet.name}'
      location: location
    }
  }
]

var invalidNsgSubnets = ['AzureFirewallSubnet','AppGatewaySubnet']

@batchSize(1)
module subnetsM 'subnet.bicep' = [
  for i in range(0,  length(subnets)) : if (useExistingVNet && deploySubnets) {
      name: '${subnets[i].name}'
      scope: resourceGroup(subscriptionId, resourceGroupName)
      params: {
        name: '${vnetName}/${subnets[i].name}'
        addressPrefix: subnets[i].addressPrefix
        delegations: empty(subnets[i].delegation) ? [] : [
          {
            name: subnets[i].delegation
            properties: {
              serviceName: subnets[i].delegation
            }
          }
        ]
        // Map EVERY requested service endpoint, not just the first. The API
        // Management injection subnet needs four (Storage, Sql, KeyVault,
        // EventHub) because Learn strongly recommends service endpoints for
        // those dependencies whenever the subnet is force tunnelled, and this
        // landing zone routes 0.0.0.0/0 to the hub firewall by default.
        serviceEndpoints: map(subnets[i].serviceEndpoints, endpoint => {
          service: endpoint
        })
        networkSecurityGroupId: !empty(subnets[i].?networkSecurityGroupResourceId ?? '')
          ? string(subnets[i].networkSecurityGroupResourceId)
          : (deployNsgs && !contains(invalidNsgSubnets, subnets[i].name) ? nsgsM[i]!.outputs.id : '')
        routeTableId: string(subnets[i].?routeTableResourceId ?? '')
        natGatewayId: string(subnets[i].?natGatewayResourceId ?? '')
    }
  }
]

var subnetResourceIds = [for i in range(0,  length(subnets)): {
    id : '${virtualNetworkResourceId}/subnets/${subnets[i].name}'
  }
]
