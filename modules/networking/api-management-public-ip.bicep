targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Public IP for a zone-redundant, VNet-injected API Management instance
// ---------------------------------------------------------------------------
// This exists for exactly one reason, and it is easy to misread as a privacy
// regression, so state it plainly.
//
// Azure REQUIRES a public IP resource when availability zone support is enabled
// on an injected instance. Learn, reliability-api-management (Premium pivot):
//
//   "IP address requirements: When you enable availability zone support on an
//    API Management instance that's deployed in an external or internal virtual
//    network, you must specify a public IP address resource for the instance to
//    use. In an internal virtual network, the public IP address is used only for
//    management operations, NOT for API requests."
//
// That final clause is the important one: in Internal mode this address carries
// control-plane traffic only. It does not expose the gateway data plane, and it
// does not change the fact that no API Management endpoint is registered on
// public DNS.
//
// It is NOT needed for a non-zone-redundant injected instance. Learn,
// api-management-using-with-internal-vnet: "Starting May 2024, a public IP
// address resource is no longer needed when deploying (injecting) an API
// Management instance in a VNet in internal mode." So this module is deployed
// only for Premium, which is the only classic tier with availability zones.
//
// Sources (read 2026-09-22):
//   https://learn.microsoft.com/azure/reliability/reliability-api-management
//   https://learn.microsoft.com/azure/api-management/enable-availability-zone-support
//   https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet

@description('Name of the public IP address resource.')
@minLength(1)
@maxLength(80)
param name string

@description('Region. Must match the API Management instance, its virtual network and its injection subnet.')
param location string = resourceGroup().location

// Learn, api-management-using-with-internal-vnet: "When creating a public IP
// address resource, ensure you assign a DNS name label to it. In general, you
// should use the same DNS name as your API Management instance. If you change
// it, redeploy your instance so that the new DNS label is applied."
@description('DNS name label for the public IP. Learn recommends using the same name as the API Management instance. Azure requires 3-63 characters, lowercase alphanumeric and hyphens, unique within the region.')
@minLength(1)
@maxLength(63)
param domainNameLabel string

// Learn, same page: "When creating a public IP address in a region where you
// plan to enable zone redundancy for your API Management instance, configure
// the Zone-redundant setting." An empty list yields a non-zonal (regional) IP,
// which is correct only where the region has no zones.
@description('Availability zones for the public IP. Supply [1,2,3] for a zone-redundant address, which is required wherever the API Management instance is itself zone redundant. Leave empty ONLY in regions without availability zone support.')
param availabilityZones int[] = [1, 2, 3]

@description('Tags applied to the public IP address.')
param tags object = {}

// Standard SKU and Static allocation are both mandatory for API Management
// virtual network deployments on the stv2 compute platform.
resource publicIpAddress 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: map(availabilityZones, zone => string(zone))
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: domainNameLabel
    }
  }
}

@description('Public IP resource ID. Pass to the gateway as publicIpAddressResourceId.')
output resourceId string = publicIpAddress.id

@description('Public IP name.')
output name string = publicIpAddress.name

@description('Whether this address is zone redundant. A zone-redundant API Management instance requires a zone-redundant public IP.')
output zoneRedundant bool = !empty(availabilityZones)
