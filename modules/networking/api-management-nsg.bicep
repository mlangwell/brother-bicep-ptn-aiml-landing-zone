targetScope = 'resourceGroup'

// Landing-zone entry point for the API Management injection-subnet NSG
// (ADR-001, ADR-002). It keeps ADR-001's fail-closed contract: at least one hub
// firewall source CIDR is required, so a gateway created by this landing zone
// never runs behind an NSG that admits the whole VirtualNetwork service tag.
// The rules come from the shared module that platform/api-management/network.bicep
// also uses, so the two gateway paths cannot drift.

@description('Name of the network security group for the API Management subnet.')
param name string

@description('Azure region for the network security group.')
param location string = resourceGroup().location

@minLength(1)
@description('Hub firewall source CIDRs allowed to reach the internal API Management gateway on TCP 443. For Azure Firewall this is the AzureFirewallSubnet prefix, because the firewall source-NATs to a back-end instance IP, not to its frontend private IP.')
param ingressSourceAddressPrefixes string[]

@description('Subnet CIDRs inside this spoke that may call the gateway on TCP 443 directly, without traversing the hub firewall.')
param directCallerAddressPrefixes string[] = []

@description('Address prefix of the API Management subnet. Scopes the rate-limit counter sync rule.')
@minLength(1)
param subnetAddressPrefix string

@description('Tags to apply to the network security group.')
param tags object = {}

module rules 'api-management-injection-nsg.bicep' = {
  name: take('${name}-rules', 64)
  params: {
    name: name
    location: location
    tags: tags
    ingressSourceAddressPrefixes: ingressSourceAddressPrefixes
    directCallerAddressPrefixes: directCallerAddressPrefixes
    subnetAddressPrefix: subnetAddressPrefix
  }
}

@description('Resource ID of the API Management subnet network security group.')
output resourceId string = rules.outputs.id

@description('Rule names deployed on the network security group, in declaration order.')
output ruleNames array = rules.outputs.ruleNames