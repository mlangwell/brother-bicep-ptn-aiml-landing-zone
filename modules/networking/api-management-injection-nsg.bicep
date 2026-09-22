targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// API Management classic VNet-injection network security group
// ---------------------------------------------------------------------------
// This is the SINGLE authoritative rule set for an API Management injection
// subnet. Both gateway creation paths consume it:
//
//   - platform/api-management/network.bicep  (shared per-subscription gateway)
//   - main.bicep                             (landing-zone-created gateway)
//
// It exists as a shared module specifically so those two paths cannot drift. A
// rule that is present on one path and missing on the other would produce a
// gateway that deploys in dev and fails in production, or vice versa, which is
// exactly the class of defect this landing zone must not model.
//
// Why not modules/networking/network-security-group.bicep: that module creates
// an NSG with NO security rules. That is correct for the v2 outbound-integration
// model and FATAL for classic injection. Learn, virtual-network-injection-resources:
// "A network security group (NSG) is required to explicitly allow inbound
// connectivity, because the load balancer used internally by API Management is
// secure by default and rejects all inbound traffic."
//
// Rule provenance, stated precisely, because "required" is not uniform across
// this set and flattening it would misrepresent Learn. The required-ports table
// bolds the Purpose cell of every configuration "required for successful
// deployment and operation of the API Management service"; entries "labeled
// 'optional' enable specific features ... They are not required for the overall
// health of the service."
//
//   - SEVEN of the nine rules below are bold AND marked "External & Internal",
//     so they are genuinely required for an Internal-mode instance:
//     ApiManagement:3443 in, AzureLoadBalancer:6390 in, Storage:443,
//     Sql:1433, AzureKeyVault:443, AzureMonitor:1886+443, Internet:80.
//     (Learn separately notes 6390 is not required on Developer, where a single
//     compute unit sits behind the LB, but "becomes critical" on Premium.)
//   - AllowMicrosoftEntraIdOutbound is marked "(optional)" in that table. It is
//     required by THIS workload, because the inbound API policy is
//     validate-azure-ad-token. That is a workload decision, not a Learn one.
//   - AllowDnsOutbound does not appear in the table at all. It comes from the
//     separate "DNS access" section: "Outbound access on port 53 is required
//     for communication with DNS servers."
//
// The two bold External-ONLY rules are deliberately ABSENT, because this
// gateway is always injected in Internal mode and adding either would expose the
// data plane to the internet:
//
//   - Inbound Internet -> VirtualNetwork :80,443   ("Client communication")
//   - Inbound AzureTrafficManager -> VirtualNetwork :443 (multi-region routing)
//
// Sources (re-read 2026-09-22):
//   https://learn.microsoft.com/azure/api-management/virtual-network-reference
//   https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources

@description('Name of the network security group.')
@minLength(1)
@maxLength(80)
param name string

@description('Region of the NSG. Must match the API Management instance, virtual network and subnet.')
param location string = resourceGroup().location

@description('Tags applied to the network security group.')
param tags object = {}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // REQUIRED. Without this the service cannot be created or managed, and
        // an existing instance drops off the Azure portal and PowerShell.
        // This is the ONLY inbound path from outside the VNet, it is
        // control-plane only, and it is restricted to Azure's own API
        // Management control-plane addresses via the service tag.
        name: 'AllowApiManagementControlPlaneInbound'
        properties: {
          description: 'Required: API Management management endpoint (3443) from the ApiManagement service tag. Control plane only - this is not a data-plane path.'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
        }
      }
      {
        // Learn marks this optional on Developer (a single compute unit sits
        // behind the LB) but CRITICAL on Premium: "failure of the health probe
        // from load balancer then blocks all inbound access to the control
        // plane and data plane." Always present so dev/test rehearse prod.
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          description: 'Required on Premium, harmless on Developer: Azure infrastructure load balancer health probe (6390). If this probe fails on Premium, ALL inbound control-plane and data-plane access is blocked.'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
        }
      }
      {
        name: 'AllowStorageOutbound'
        properties: {
          description: 'Required: hard dependency on Azure Storage (443).'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowSqlOutbound'
        properties: {
          description: 'Required: hard dependency on Azure SQL endpoints (1433).'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Sql'
          destinationPortRange: '1433'
        }
      }
      {
        name: 'AllowKeyVaultOutbound'
        properties: {
          description: 'Required: hard dependency on Azure Key Vault (443).'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureMonitorOutbound'
        properties: {
          description: 'Required: publish diagnostics, metrics, Resource Health and Application Insights telemetry (1886, 443).'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRanges: [
            '1886'
            '443'
          ]
        }
      }
      {
        // Port 80 only, and deliberately so: this is CRL/OCSP certificate chain
        // validation (mscrl.microsoft.com, crl.microsoft.com, oneocsp.microsoft.com,
        // cacerts.digicert.com, crl3.digicert.com, csp.digicert.com), which is
        // plain HTTP by design. This is NOT general internet egress.
        name: 'AllowCertificateValidationOutbound'
        properties: {
          description: 'Required: validation and management of Microsoft-managed and customer-managed certificates (CRL/OCSP over HTTP, port 80). Not a general internet egress rule.'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          priority: 140
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
      {
        // Learn marks this "(optional)" because it is only needed for Entra ID,
        // Microsoft Graph and Key Vault integration. This gateway's inbound
        // policy is validate-azure-ad-token, so for this workload it is REQUIRED.
        name: 'AllowMicrosoftEntraIdOutbound'
        properties: {
          description: 'Required by this workload: the inbound API policy uses validate-azure-ad-token, which needs Microsoft Entra ID and Microsoft Graph (443). Learn lists this as optional only because gateways that do not authenticate callers against Entra do not need it.'
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          priority: 150
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
        }
      }
      {
        // Learn, "DNS access": "Outbound access on port 53 is required for
        // communication with DNS servers." Protocol is '*' because DNS uses both
        // UDP and TCP; destination is '*' because the resolver may be the Azure
        // platform resolver, a custom DNS server in a peered VNet, or an
        // on-premises forwarder reached over ExpressRoute.
        name: 'AllowDnsOutbound'
        properties: {
          description: 'Required: DNS resolution (53, UDP and TCP). Internal mode has no Azure-provided public name resolution for the gateway, and the gateway must resolve the backend Foundry private endpoint, so a working resolver path is mandatory.'
          protocol: '*'
          access: 'Allow'
          direction: 'Outbound'
          priority: 160
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '53'
        }
      }
    ]
  }
}

@description('Network security group resource ID.')
output id string = networkSecurityGroup.id

@description('Network security group name.')
output name string = networkSecurityGroup.name

@description('Rule names emitted by this module, in declaration order. Contract tests assert against this list so a silently dropped rule fails the build rather than the deployment.')
output ruleNames array = [
  'AllowApiManagementControlPlaneInbound'
  'AllowAzureLoadBalancerInbound'
  'AllowStorageOutbound'
  'AllowSqlOutbound'
  'AllowKeyVaultOutbound'
  'AllowAzureMonitorOutbound'
  'AllowCertificateValidationOutbound'
  'AllowMicrosoftEntraIdOutbound'
  'AllowDnsOutbound'
]
