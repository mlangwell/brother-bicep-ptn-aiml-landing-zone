# Code Disclaimer

THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.

This sample is not supported under any Microsoft standard support program or service. 
 The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
 implied warranties including, without limitation, any implied warranties of merchantability
 or of fitness for a particular purpose. The entire risk arising out of the use or performance
 of the sample and documentation remains with you. In no event shall Microsoft, its authors,
 or anyone else involved in the creation, production, or delivery of the script be liable for 
 any damages whatsoever (including, without limitation, damages for loss of business profits, 
 business interruption, loss of business information, or other pecuniary loss) arising out of 
 the use of or inability to use the sample or documentation, even if Microsoft has been advised 
 of the possibility of such damages, rising out of the use of or inability to use the sample script, 
 even if Microsoft has been advised of the possibility of such damages.

# Azure AI Landing Zone integrated deployment

This repository deploys an Azure AI Landing Zone (AILZ) spoke into an existing
Azure Landing Zone hub. Use
[Deploy-AilzIntegrated.ps1](Deploy-AilzIntegrated.ps1) to configure the `azd`
environment, preview the infrastructure changes, and provision the deployment.

An additive, opt-in [GitHub development environment path](docs/github-development.md)
adds typed dev/test/prod profiles, protected artifact promotion, a private APIM
gateway and a small authenticated inference starter. Infrastructure success is
not developer readiness: private completion, human SSO and the live acceptance
gates are separate. The existing wrapper, `azd` hooks and Azure DevOps assets
remain supported and unchanged.

The APIM gateway can be created by the landing zone, or consumed from
**per-subscription platform infrastructure**. For the shared option, deploy
[`platform/api-management/`](platform/api-management/) **once per subscription**,
then deploy the landing zone **many times** against it via
`existingApiManagementResourceId`. The landing zone creates Developer by
default; the structured gateway configuration from the GitHub environment
profile selects Premium and adds the governed workload API.

Either way, the gateway uses classic VNet injection in Internal mode, so it is
reachable only from inside the virtual network. Its governed route is
`/inference/<workloadKey>/v1/responses`. Internal mode registers nothing on
public DNS, so an operator-created private DNS zone is required before the
gateway is reachable. See
[ADR-002](docs/adr/002-apim-merge-conformance.md) and
[the topology ADR](docs/adr/2026-09-22-apim-classic-vnet-injection.md).

The script configures this topology automatically:

- `DEPLOYMENT_MODE=ailz-integrated`
- `NETWORK_ISOLATION=true`
- `DEPLOY_AZURE_FIREWALL=false`
- Spoke-to-hub peering using the supplied hub VNet resource ID
- Spoke egress through the supplied hub firewall or NVA private IP
- Optional internal Developer-tier API Management in a dedicated spoke subnet

## Quickstart: let Copilot find your values and deploy

Assembling the deployment command by hand is the step most people get wrong. It
means collecting a dozen resource IDs across two or three subscriptions without
a typo. Two prompts in
[Deploy with GitHub Copilot](docs/copilot-deploy-prompt.md) do it for you:

1. **Discover.** Copilot uses the Azure CLI to find your hub VNet, firewall
   private IP, Private DNS zones and observability resources, then writes a
   filled-in `config.json`. It only reads from Azure and changes nothing.
2. **Deploy.** Copilot validates that file, checks your spoke range does not
   overlap the hub, builds the correct command, runs a preview, and stops for
   your approval before provisioning.

[config.json.example](config.json.example) is the template behind both. It is a
commented worksheet covering the four required values, subscription and resource
group targeting, hub observability reuse, Private DNS strategy for a
policy-managed landing zone, the spoke address range, and the optional feature
flags. You can fill it in by hand instead:

```powershell
Copy-Item config.json.example config.json
code config.json
```

`config.json` is git-ignored because it holds subscription and hub identifiers.
Commit changes to `config.json.example` only.

Prefer to drive the script directly? The rest of this document is the full
parameter reference, and it remains the authoritative description of the script.

## Prerequisites

Before running the script, confirm that you have:

1. [PowerShell 7 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
2. [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
3. [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
  1.25.5 or later. Check it with `azd version`, and upgrade with
  `winget upgrade Microsoft.Azd` or the install page. `azure.yaml` enforces
  this minimum. azd 1.23.4 was the first release to pass the JSON arrays in
  `main.parameters.json` to their array parameters, such as the API Management
  CIDR lists. Before it, provisioning fails or sends ARM a string. azd 1.25.5
  fixed `azd down --purge` for Foundry accounts.
4. Azure `Contributor` and `User Access Administrator` roles at the deployment
  scope.
5. Accepted the Responsible AI terms for Azure AI services.
6. The full Azure resource ID of the existing hub VNet.
7. The private IP address of the hub Azure Firewall or other next-hop NVA.
8. A non-overlapping address range available for the new spoke VNet. The
  default spoke range in this checkout is `192.168.0.0/21`.
9. Hub firewall policy rules that allow the spoke address range to reach the
  required Azure services.

Open PowerShell 7 in the repository root before following the steps below.

## Copilot Prompt
Instead of executing everything on your own, you can run the following copilot prompt by entering it into either the Copilot CLI or Copilot Chat.

`/Deploy-AILZ-with-APIM`

There will be questions that surface after running the prompt that must be answered to run the script. 

## Deployment script parameters

The script has four required parameters. The remaining parameters are optional.

| Parameter | Required | Description | Example |
| --- | --- | --- | --- |
| `EnvironmentName` | Yes | Name of the local `azd` environment to create or reuse. Use a short name that identifies the workload and lifecycle environment. Reusing a name also reuses values saved by earlier runs. | `ailz-dev` |
| `Location` | Yes | Primary Azure region for the deployment. Use an Azure region name without spaces. Resource availability and organizational policy may restrict the allowed regions. | `eastus2` |
| `HubVnetResourceId` | Yes | Full Azure resource ID of the existing hub virtual network. The deployment uses it to create the spoke-to-hub peering. | `/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet>` |
| `EgressNextHopIp` | Yes | Private IPv4 address of the hub Azure Firewall or network virtual appliance that receives the spoke's default route. Do not use its public IP. | `10.100.0.4` |
| `ExistingLogAnalyticsWorkspaceResourceId` | No | Full resource ID of a hub-managed Log Analytics workspace to reuse. Leave it out to deploy a new workspace. | `/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/<name>` |
| `ExistingApplicationInsightsResourceId` | No | Full resource ID of an existing Application Insights component to reuse. It must be supplied together with `ExistingApplicationInsightsConnectionString`. Leave both out to deploy a new component. | `/subscriptions/.../providers/Microsoft.Insights/components/<name>` |
| `ExistingApplicationInsightsConnectionString` | No | Connection string belonging to the reused Application Insights component. Store it in a PowerShell variable before invoking the script so it is not typed directly into the command. | `$applicationInsightsConnectionString` |
| `DeployApiManagement` | No | Deploy a Developer-tier API Management service with internal VNet injection into the AILZ spoke. Disabled by default. | `-DeployApiManagement` |
| `ApiManagementPublisherEmail` | Conditional | Publisher contact email. Required when `DeployApiManagement` is enabled. | `api-owners@contoso.com` |
| `ApiManagementPublisherName` | No | Publisher display name. Defaults to `AI Landing Zone`. | `Contoso API Team` |
| `ApiManagementIngressSourceAddressPrefixes` | No | Hub firewall source CIDRs allowed to reach the internal APIM gateway on TCP 443. Defaults to the hub VNet's `AzureFirewallSubnet` prefix, read after sign-in, because Azure Firewall source-NATs gateway traffic to a back-end instance IP in that subnet, not to its frontend IP. Falls back to `EgressNextHopIp/32` with a warning when the hub has no readable `AzureFirewallSubnet`, such as an NVA hub. | `@("10.100.0.0/26")` |
| `AdditionalEnvironmentVariables` | No | PowerShell hashtable containing additional `azd` environment values supported by `main.parameters.json`, such as subscription, resource group, private DNS zone IDs, or feature flags. Values persist in the selected local `azd` environment. | `@{ AZURE_SUBSCRIPTION_ID = "<id>" }` |
| `PreviewOutput` | No | Preview detail level. `Full` displays ARM What-If changes plus every nested compiled resource declaration. `Slim` (default) displays the original condensed `azd provision --preview` summary. | `Full` |
| `PreviewOnly` | No | Switch that stops after `azd provision --preview`. Without it, the script displays the preview and then asks you to type `DEPLOY` before provisioning. | `-PreviewOnly` |

### Find the required values

List the Azure regions available to your subscription:

```powershell
az account list-locations --query "[].name" --output table
```

Get the hub VNet resource ID:

```powershell
$hubVnetResourceId = az network vnet show `
  --resource-group "<hub-resource-group>" `
  --name "<hub-vnet-name>" `
  --query id `
  --output tsv
```

Get the private IP of an Azure Firewall in the hub:

```powershell
$egressNextHopIp = az network firewall show `
  --resource-group "<hub-resource-group>" `
  --name "<hub-firewall-name>" `
  --query "ipConfigurations[0].privateIPAddress" `
  --output tsv
```

Pass those variables directly to the script:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId $hubVnetResourceId `
  -EgressNextHopIp $egressNextHopIp `
  -PreviewOnly
```

If the hub uses a network virtual appliance instead of Azure Firewall, obtain
its private forwarding IP from the platform or networking team.

## Deploy

### 1. Preview the deployment

Replace the example values, then run:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId "/subscriptions/<subscription-id>/resourceGroups/<hub-resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet-name>" `
  -EgressNextHopIp "10.100.0.4" `
  -PreviewOnly
```

The script signs in when needed, creates or selects the named `azd`
environment, sets the integrated-topology values, runs the repository preflight,
and displays the preview. azd runs the preflight as its `preprovision` hook for
`-PreviewOutput Slim`, and the script runs it itself before `-PreviewOutput
Full`. A preflight `FAIL` stops the run before anything is deployed.
With the default `-PreviewOutput Slim` this is the condensed
`azd provision --preview` summary. With `-PreviewOutput Full` it displays two
preview sections:

- `ARM What-If resource changes` is Azure's evaluated change set for resources
  ARM expands during What-If.
- `Complete compiled nested resource inventory` recursively lists every
  resource declaration in the compiled template, including resources such as
  Microsoft Foundry accounts, projects, model deployments, capability hosts,
  and connections that ARM may omit when nested deployments exceed What-If's
  expansion depth. `INCLUDED` entries are unconditional; `CONDITIONAL` entries
  remain subject to their template or parent-module conditions.

`-PreviewOnly` guarantees that this invocation does not provision resources.
Pass `-PreviewOutput Full` to add the What-If change set and the compiled
inventory. Omitting `-PreviewOutput` uses `Slim`.

Review both sections for deleted or replaced resources, unexpected role
assignments, public network access, incorrect regions, and changes outside the
intended resource group. Treat ARM What-If as the authoritative evaluated
change set and the compiled inventory as the exhaustive declaration audit.

### 2. Provision the deployment

Run the same command without `-PreviewOnly`:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId "/subscriptions/<subscription-id>/resourceGroups/<hub-resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet-name>" `
  -EgressNextHopIp "10.100.0.4"
```

The script runs the preview again. Type exactly `DEPLOY` when prompted to start
provisioning. Any other response cancels the deployment.

### 3. Complete hub integration

After provisioning:

1. Create the reverse hub-to-spoke VNet peering. The template creates only the
  spoke-to-hub direction. API Management depends on this peering, so complete it
  before you enable the gateway; see [Deploy API Management](#deploy-api-management).
2. Link the hub-managed private DNS zones to the spoke VNet when Azure Policy
  does not manage those links.
3. Verify that the hub firewall permits the spoke source range and that its DNS
  configuration resolves the private endpoints.
4. Test access from a host with network connectivity to the spoke, such as a
  hub jumpbox reached through Azure Bastion.

See the [hub-and-spoke deployment walkthrough](https://azure.github.io/AI-Landing-Zones/bicep/hub-and-spoke/)
for the post-deployment network checks.

## Optional configuration

### Deploy API Management

API Management activates over the spoke's egress path. Its default route goes to
the hub firewall, so the gateway can reach its dependencies only after the
hub-to-spoke peering is `Connected`. Created before that, it fails with
`ActivationFailed`. Because the template creates only the spoke-to-hub
direction, deploy a new spoke in two passes:

1. Deploy the spoke without `-DeployApiManagement`, as in [Deploy](#deploy).
2. Have the hub owner create the hub-to-spoke peering. If you own the hub, run
  `pwsh ./tests/scripts/Add-HubSpokePeering.ps1 -HubVnetResourceId $hubVnetResourceId`.
  Confirm that both directions show `Connected`.
3. Rerun the script with `-DeployApiManagement` and the publisher contact email:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId $hubVnetResourceId `
  -EgressNextHopIp $egressNextHopIp `
  -DeployApiManagement `
  -ApiManagementPublisherEmail "api-owners@contoso.com" `
  -PreviewOnly
```

Preflight enforces the order. For a new spoke it fails with
`APIM_HUB_PEERING_MISSING` or `APIM_HUB_PEERING_NOT_CONNECTED` until the hub has a
`Connected` peering to the spoke. It warns instead when it cannot read the hub
VNet, or for a prepared spoke whose route table an operator owns.

The deployment uses the Developer SKU and internal VNet mode. It creates the
dedicated `api-management-subnet` at `192.168.3.128/27` and a dedicated route
table. The subnet has service endpoints for Storage, SQL, Key Vault and Event
Hubs.

Its NSG allows:
- Azure control-plane traffic and load-balancer probes;
- HTTPS from the approved hub firewall CIDRs;
- HTTPS from any in-spoke caller subnets you list;
- rate-limit counter sync within the subnet.

It denies all other inbound traffic. To let subnets inside the spoke call the
gateway directly, pass their CIDRs as
`API_MANAGEMENT_DIRECT_CALLER_ADDRESS_PREFIXES` through
`-AdditionalEnvironmentVariables`. Callers outside the spoke always go through
the hub firewall.

The default route sends workload and APIM dependency egress to the hub
firewall. The required `ApiManagement` service-tag route sends control-plane
responses directly to the Internet to keep TCP 3443 symmetric; this is the sole
intentional forced-tunneling exception. Set `-ApiManagementPublisherName` to
override the default publisher name. Premium and the governed workload API are
selected through the structured gateway configuration; see
[ADR-002](docs/adr/002-apim-merge-conformance.md).

The platform team must complete these hub-owned changes before the gateway is
usable:

1. Deliver gateway traffic through the hub firewall with source NAT, so it
  arrives from the `AzureFirewallSubnet` range that the APIM NSG admits. Use
  either of these patterns:
   - An application rule for the gateway FQDN. Application rules always
     source-NAT. Clients resolve the gateway host name to its private VIP and
     route the spoke range through the firewall.
   - A private-IP DNAT rule on the firewall, which the Azure Firewall FAQ still
     labels preview. Clients resolve the gateway host name to the firewall
     listener.

   Network-rule traffic to private addresses is not source-NATed. It keeps the
   client address, so the APIM NSG denies it.
2. Permit the documented APIM VNet dependency service tags, ports, and FQDNs
  in the hub firewall policy. See the [APIM VNet configuration
  reference](https://learn.microsoft.com/azure/api-management/virtual-network-reference).
3. Publish DNS for the gateway, management, portal, developer portal, and SCM
  host names that matches the pattern above. Point them at the private VIP for
  the application-rule pattern, or at the firewall listener for DNAT. Scope
  zones to the exact host names; never create a private zone for
  `azure-api.net`.
4. Validate that direct access to TCP 443 from other spoke subnets is denied,
  and that requests succeed through the hub firewall path.

Disabling `DeployApiManagement` does not delete existing resources because ARM
deployments are incremental. After exporting any APIM data-plane configuration,
delete the APIM service and its dedicated subnet, NSG, and route table through
an approved cleanup change.

### Select the subscription and resource group

Pass additional `azd` environment values in a PowerShell hashtable:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId "/subscriptions/<subscription-id>/resourceGroups/<hub-resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet-name>" `
  -EgressNextHopIp "10.100.0.4" `
  -AdditionalEnvironmentVariables @{
    AZURE_SUBSCRIPTION_ID = "<subscription-id>"
    AZURE_RESOURCE_GROUP  = "<spoke-resource-group-name>"
  } `
  -PreviewOnly
```

Without these values, `azd` uses the subscription and resource group associated
with the selected environment. Check them before deployment:

```powershell
azd env get-value AZURE_SUBSCRIPTION_ID
azd env get-value AZURE_RESOURCE_GROUP
az account show --query "{subscription:name, subscriptionId:id}" --output table
```

Use targeted `azd env get-value` commands instead of printing the entire
environment because it may contain the Application Insights connection string.

### Reuse hub observability

To reuse an existing Log Analytics workspace:

```powershell
-ExistingLogAnalyticsWorkspaceResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"
```

To reuse Application Insights, both its resource ID and connection string are
required:

```powershell
-ExistingApplicationInsightsResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/components/<component-name>" `
-ExistingApplicationInsightsConnectionString $applicationInsightsConnectionString
```

Obtain the connection string without placing it directly in the command:

```powershell
$applicationInsightsConnectionString = az monitor app-insights component show `
  --resource-group "<resource-group>" `
  --app "<component-name>" `
  --query connectionString `
  --output tsv
```

### Reuse private DNS zones or set other values

Use `-AdditionalEnvironmentVariables` for private DNS zone IDs and any other
environment-substituted setting supported by
[main.parameters.json](main.parameters.json):

```powershell
-AdditionalEnvironmentVariables @{
  EXISTING_PRIVATE_DNS_ZONE_BLOB_RESOURCE_ID     = "/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net"
  EXISTING_PRIVATE_DNS_ZONE_KEYVAULT_RESOURCE_ID = "/subscriptions/.../privateDnsZones/privatelink.vaultcore.azure.net"
  DNS_ZONE_LINK_SUFFIX                           = "spoke01"
}
```

Use the exact variable names from the
[AILZ parameter reference](https://azure.github.io/AI-Landing-Zones/bicep/parameterization/).
For hub integration in this checkout, the authoritative names are
`HUB_INTEGRATION_HUB_VNET_RESOURCE_ID` and
`HUB_INTEGRATION_EGRESS_NEXT_HOP_IP`.

These values persist in the local `azd` environment. Do not pass passwords,
tokens, or other application secrets through `-AdditionalEnvironmentVariables`;
store application secrets in Azure Key Vault.

## Tear down

Preview the teardown, then run it from the repository root:

```powershell
pwsh ./scripts/Remove-AilzEnvironment.ps1 -EnvironmentName "ailz-dev" -WhatIf
pwsh ./scripts/Remove-AilzEnvironment.ps1 -EnvironmentName "ailz-dev"
```

`azd down` cannot tear this template down alone, because Azure AI Search
refuses to delete a service that still has shared private links. The script:

1. Checks that azd is 1.25.5 or later, before it deletes anything.
2. Reads the subscription and resource group from the azd environment.
3. Refuses a resource group that is not tagged `azd-env-name=<environment>`,
  unless you pass `-AllowExternalResourceGroup`. `azd down --force` deletes
  every resource in the group, including resources this template did not create.
4. Shows the plan and asks you to type the resource group name. `-Force` skips
  this prompt.
5. Deletes each Search shared private link and waits until it is gone.
6. Runs `azd down --force --purge`. This deletes the resource group and purges
  its soft-deleted Key Vault, App Configuration, API Management, Foundry and Log
  Analytics resources, which cannot then be recovered.
7. Prints the hub-side peering that the hub owner must delete. The script never
  changes the hub, and a `Disconnected` peering cannot be reused when the spoke
  is redeployed.

To tear down by hand instead, run the same steps in order:

```powershell
az search shared-private-link-resource list --service-name "<search-service>" --resource-group "<spoke-resource-group>" --output table
az search shared-private-link-resource delete --name "<link-name>" --service-name "<search-service>" --resource-group "<spoke-resource-group>" --yes
azd down --force --purge
```

Then have the hub owner delete the hub-side peering to the deleted spoke.

## Troubleshooting

### `Required command '<name>' was not found`

Install the named prerequisite, open a new PowerShell 7 session, and verify it:

```powershell
pwsh --version
az version
azd version
```

### Script execution is disabled

Allow the script only for the current PowerShell process, then rerun it:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Do not weaken the machine-wide execution policy unless your organization has
approved that change.

### `this project requires a version of azd within the range '>= 1.25.5'`

The installed azd is older than this template's minimum; see the
[prerequisites](#prerequisites). Upgrade it and rerun:

```powershell
winget upgrade Microsoft.Azd
azd version
```

`error unmarshalling Bicep template parameters: invalid character ... after object
key:value pair` has the same cause: an azd older than 1.23.4 reading a project
whose `azure.yaml` does not declare the minimum. Preflight reports it as
`AZD_VERSION_UNSUPPORTED`.

### API Management fails with `ActivationFailed`

`Connectivity to Monitoring failed` or `Connectivity to MetricsExtension failed`
means the gateway could not reach its dependencies through the hub. The usual
cause is a missing hub-to-spoke peering, not the NSG, which already allows Azure
Monitor. A failed service must be deleted before it can be redeployed
(`ServiceInFailedProvisioningState`). Delete it, create the peering, confirm both
directions show `Connected`, and rerun with `-DeployApiManagement`. See
[Deploy API Management](#deploy-api-management).

### Preflight reports `APIM_HUB_PEERING_MISSING` or `APIM_HUB_PEERING_NOT_CONNECTED`

The hub has no `Connected` peering to the spoke, so the gateway would fail
activation. On a first deployment, deploy the spoke without
`-DeployApiManagement` and have the hub-to-spoke peering created first.
`Initiated` means one direction is missing. `Disconnected` means the spoke VNet
was deleted or recreated: delete the hub-side peering and create it again.

### Azure sign-in opens the wrong tenant

Sign in to the required tenant before running the script:

```powershell
az login --tenant "<tenant-id>"
azd auth login --tenant-id "<tenant-id>"
```

Then verify and select the intended subscription:

```powershell
az account set --subscription "<subscription-id>"
az account show --output table
```

Also pass `AZURE_SUBSCRIPTION_ID` through `-AdditionalEnvironmentVariables` so
the `azd` environment targets the same subscription.

### `azd env select` reports that the environment does not exist

This message is expected the first time an environment name is used. The script
creates it immediately afterward. Investigate only if the subsequent
`azd env new` command also fails.

### An existing environment uses unexpected settings

The script reuses an environment when `-EnvironmentName` already exists. It
updates the values supplied on the current run, but it does not remove unrelated
values saved by an earlier run. Inspect the relevant value directly:

```powershell
azd env get-value <VARIABLE_NAME>
```

Use a new, unique `-EnvironmentName` for a clean deployment environment, or
correct the stale value by passing it in `-AdditionalEnvironmentVariables`.

### `ExistingApplicationInsightsResourceId and ... must be supplied together`

Supply both Application Insights parameters shown in the observability example,
or remove both parameters to deploy a new Application Insights component.

### Preflight reports an invalid resource ID or missing resource

Confirm that every ID starts with `/subscriptions/`, uses the correct
subscription and resource group, and refers to a resource visible to the signed-
in identity. Test a resource ID with:

```powershell
az resource show --ids "<resource-id>" --output table
```

### Preflight reports overlapping CIDR ranges

The default spoke range in this checkout is `192.168.0.0/21`. Choose a range
that does not overlap the hub or any connected network. Changing only
`vnetAddressPrefixes` is not sufficient: every subnet prefix must remain inside
the new VNet range, must not overlap another subnet, and must meet the sizing
requirements of the Azure service that uses it.

The VNet and subnet parameters are not currently exposed as `azd` environment
variables. Add the complete address plan inside the `parameters` object in
[main.parameters.json](main.parameters.json). This example preserves the
default subnet sizes and relative allocations in a `10.200.0.0/21` spoke:

```json
"vnetAddressPrefixes": {
  "value": [
    "10.200.0.0/21"
  ]
},
"agentSubnetPrefix": {
  "value": "10.200.0.0/24"
},
"acaEnvironmentSubnetPrefix": {
  "value": "10.200.1.0/24"
},
"peSubnetPrefix": {
  "value": "10.200.2.0/26"
},
"azureBastionSubnetPrefix": {
  "value": "10.200.2.64/26"
},
"azureFirewallSubnetPrefix": {
  "value": "10.200.2.128/26"
},
"gatewaySubnetPrefix": {
  "value": "10.200.2.192/26"
},
"azureAppGatewaySubnetPrefix": {
  "value": "10.200.3.0/27"
},
"jumpboxSubnetPrefix": {
  "value": "10.200.3.64/27"
},
"devopsBuildAgentsSubnetPrefix": {
  "value": "10.200.3.96/27"
},
"apiManagementSubnetPrefix": {
  "value": "10.200.3.128/27"
},
```

The API Management subnet uses `/27` as this repository's conservative sizing
policy; its network address is not fixed and may be moved to any aligned,
non-overlapping block inside the spoke. Keep enough unused address space for
future subnets and service growth. Rerun with `-PreviewOnly`, confirm that
preflight accepts the complete address plan, and review the resulting VNet and
subnet changes before provisioning.

### Authorization or role-assignment failure

Confirm that the signed-in identity has both `Contributor` and `User Access
Administrator` at the target scope. Azure Policy may also deny resource types,
regions, SKUs, public access settings, or role assignments; review the detailed
deployment error and work with the landing-zone platform owner rather than
bypassing policy.

### Hub peering or private endpoint DNS does not work

The deployment creates only spoke-to-hub peering. Create the reverse peering and
confirm that hub Private DNS zones are linked to the spoke or managed by Azure
Policy. Verify that custom DNS servers can resolve Azure Private DNS and that
network security rules permit the traffic.

### Preview succeeds but provisioning fails

A preview validates the proposed control-plane changes but does not guarantee
quota, capacity, data-plane access, or eventual service availability. Read the
first Azure resource error, correct that condition, and rerun the same script.
The script returns a failing exit code when `azd` fails; it does not hide the
underlying deployment error.

## Related documentation

- [Deployment worksheet](config.json.example) and
  [Deploy with GitHub Copilot](docs/copilot-deploy-prompt.md)
- [How to deploy Azure AI Landing Zones](https://azure.github.io/AI-Landing-Zones/bicep/how-to-deploy/#ai-landing-zone-integrated-deployment)
- [AILZ parameter reference](https://azure.github.io/AI-Landing-Zones/bicep/parameterization/)
- [Hub-and-spoke topology](https://azure.github.io/AI-Landing-Zones/bicep/hub-and-spoke/)
- [Permissions](https://azure.github.io/AI-Landing-Zones/bicep/permissions/)
