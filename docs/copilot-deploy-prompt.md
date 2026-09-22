# Deploy with GitHub Copilot

This page gives you two prompts to paste into GitHub Copilot.

1. **Prompt 1** uses the Azure CLI to go and find your hub VNet, firewall IP,
   Private DNS zones and observability resources, then writes a filled-in
   `config.json` for you. It only reads from Azure; it changes nothing.
2. **Prompt 2** takes that `config.json`, checks it, builds the correct
   `Deploy-AilzIntegrated.ps1` command, previews the deployment, and stops for
   your approval before provisioning.

They exist because the hardest part of this deployment is not running the
script. It is finding a dozen resource IDs across two or three subscriptions and
assembling them into a long PowerShell command without a typo.

## Before you start

1. Install [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell),
   the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), and
   the [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd).
2. Sign in to the correct tenant. Discovery can only find what your identity can
   see, so sign in as the account that has visibility of the platform/
   connectivity subscription:

   ```powershell
   az login --tenant "<tenant-id>"
   ```

3. Open GitHub Copilot in this repository and run Prompt 1.

## Prompt 1 — Discover my environment and write config.json

Copy everything inside the box.

````text
You are helping me prepare an Azure AI Landing Zone spoke deployment in this
repository. Your job in this task is DISCOVERY ONLY.

Read `config.json.example` in the repository root. It is the template and it
documents every value I need. Your goal is to produce a filled-in `config.json`
next to it, using the Azure CLI to find the real values.

ABSOLUTE RULES
  - Read-only. You may ONLY run `az ... list`, `az ... show`, `az account ...`
    and `az graph query`. You must NOT run create, update, delete, deploy,
    provision, `az deployment`, or `azd` anything in this task.
  - Never guess or invent a resource ID, IP address or subscription ID. If you
    cannot find something, leave it empty and add it to an "unresolved" list.
  - When more than one candidate exists, STOP and show me the options with
    enough detail to choose. Do not pick for me.
  - Preserve the exact key names and structure of config.json.example. Do not
    rename keys. Keep the underscore-prefixed documentation keys.

STEP 1 - Check tooling.
  Run `az version`. Then check which of these extensions are installed with
  `az extension list --query "[].name" -o tsv`:
    azure-firewall        - needed for `az network firewall`
    application-insights  - needed for `az monitor app-insights`
    resource-graph        - needed for `az graph query`
  Tell me which are missing and let me decide whether to install them. Where an
  extension is missing, use the core-CLI fallbacks noted in the steps below
  rather than stopping.

STEP 2 - Pick the subscriptions.
  Run `az account list --query "[].{name:name, id:id, tenant:tenantId, default:isDefault}" -o table`.
  Ask me two things, because they are often NOT the same subscription:
    - which subscription the SPOKE will deploy into  -> AZURE_SUBSCRIPTION_ID
    - which subscription holds the HUB / connectivity resources
  If there is only one subscription, say so and use it for both.

STEP 3 - Find the hub VNet.
  In the hub subscription, list candidates:
    az network vnet list --subscription "<hub-sub>" --query "[].{name:name, rg:resourceGroup, location:location, prefixes:addressSpace.addressPrefixes, subnets:subnets[].name, peerings:length(virtualNetworkPeerings)}" -o json

  Rank the candidates. A VNet containing a subnet named `AzureFirewallSubnet` or
  `GatewaySubnet` is almost certainly the hub; so is one with several peerings or
  a name containing "hub" or "conn". Show me the ranked list with address space,
  subnets and peering count, and ask me to confirm.

  Once I confirm, capture the full resource ID:
    az network vnet show --subscription "<hub-sub>" -g "<rg>" -n "<vnet>" --query id -o tsv
  -> deployment.hubVnetResourceId

STEP 4 - Find the egress next hop (this is a REQUIRED value).
  Preferred, if the azure-firewall extension is present:
    az network firewall list --subscription "<hub-sub>" --query "[].{name:name, rg:resourceGroup, privateIp:ipConfigurations[0].privateIPAddress}" -o table

  Core-CLI fallback if that extension is missing - note the different, nested
  property path, because this returns the raw ARM shape:
    az resource list --subscription "<hub-sub>" --resource-type Microsoft.Network/azureFirewalls --query "[].{name:name, rg:resourceGroup, id:id}" -o table
    az resource show --ids "<firewall-id>" --query "properties.ipConfigurations[0].properties.privateIPAddress" -o tsv

  -> deployment.egressNextHopIp

  Validate it is a private address (10.x, 172.16-31.x, 192.168.x). If it is
  public, that is the wrong value - stop and tell me.

  If there is no Azure Firewall, the hub uses a network virtual appliance. Tell
  me so, leave the value empty, and add it to the unresolved list: I have to get
  that forwarding IP from the networking team.

STEP 5 - Choose a non-overlapping spoke range.
  Collect every address space already in use that the spoke could collide with:
  the hub VNet prefixes from STEP 3, plus every VNet peered to the hub:
    az network vnet peering list --subscription "<hub-sub>" -g "<hub-rg>" --vnet-name "<hub-vnet>" --query "[].{name:name, remotePrefixes:remoteAddressSpace.addressPrefixes}" -o json

  The template default is 192.168.0.0/21 and it needs at least a /21. Check
  whether 192.168.0.0/21 overlaps anything you found.
    - No overlap: leave spokeNetwork.vnetAddressPrefixes as the default.
    - Overlap: propose two or three free /21 ranges that do not collide with
      anything above, show me your overlap arithmetic, and let me pick.
  Record the choice in spokeNetwork.vnetAddressPrefixes. Remind me that this one
  value is NOT an azd environment variable and has to be edited into
  main.parameters.json at deploy time - Prompt 2 handles that.

STEP 6 - Work out the Private DNS strategy. Ask me; do not assume.
  First look for existing private link zones across the hub subscription:
    az network private-dns zone list --subscription "<hub-sub>" --query "[?starts_with(name,'privatelink')].{name:name, rg:resourceGroup, links:numberOfVirtualNetworkLinks, id:id}" -o table

  If the resource-graph extension is available, search every subscription at
  once, since platform zones often live outside the hub subscription:
    az graph query -q "resources | where type =~ 'microsoft.network/privatednszones' | where name startswith 'privatelink' | project name, resourceGroup, subscriptionId, id" -o table

  Then check whether Azure Policy manages private endpoint DNS:
    az policy assignment list --scope "/subscriptions/<hub-sub>" --query "[].{name:name, displayName:displayName}" -o table
  Look for assignments mentioning private DNS, privatelink, or DINE/deployIfNotExists.

  Present what you found and ask me to choose ONE strategy:
    A. Azure Policy links private endpoints automatically (common in a CAF or
       Enterprise-Scale platform landing zone).
       -> set landingZoneDns.POLICY_MANAGED_PRIVATE_DNS = "true"
       -> leave the whole existingPrivateDnsZones section empty
    B. The hub owns the zones and policy does NOT link them.
       -> set landingZoneDns.POLICY_MANAGED_PRIVATE_DNS = "false"
       -> fill in existingPrivateDnsZones by matching each zone you found to the
          key whose documentation names that exact zone, for example
          privatelink.openai.azure.com -> EXISTING_PRIVATE_DNS_ZONE_OPENAI_RESOURCE_ID
       -> leave a key empty if that zone does not exist; the deployment will
          create it locally
    C. Neither - this is a greenfield hub with no zones yet.
       -> leave both sections empty and tell me the deployment will create its
          own zones

  If more than one spoke will link to the same shared zones, also set
  landingZoneDns.DNS_ZONE_LINK_SUFFIX to a short unique token such as "spoke01",
  because otherwise the VNet link name collides and the second deployment fails.

STEP 7 - Find observability to reuse. Optional.
    az monitor log-analytics workspace list --subscription "<hub-sub>" --query "[].{name:name, rg:resourceGroup, location:location, id:id}" -o table

  Ask whether I want to reuse a hub workspace or deploy a new one. If I pick
  one, set existingObservability.logAnalyticsWorkspaceResourceId.

  For Application Insights (needs the application-insights extension; the core
  fallback is `az resource list --resource-type Microsoft.Insights/components`):
    az monitor app-insights component show --subscription "<hub-sub>" -g "<rg>" --app "<name>" --query "{id:id}" -o tsv

  If I reuse Application Insights, set the resource ID but LEAVE
  applicationInsightsConnectionString EMPTY in the file. Never write a
  connection string into config.json and never print one to the terminal.
  Instead tell me to run this in my own shell before deploying:
    $env:AILZ_APPINSIGHTS_CONNECTION_STRING = az monitor app-insights component show -g "<rg>" --app "<name>" --query connectionString -o tsv

STEP 8 - Fill in the rest.
  deployment.environmentName : ask me, suggest something like "ailz-dev"
  deployment.location        : ask me, and confirm it is valid for the spoke
                               subscription with
                               `az account list-locations --subscription "<spoke-sub>" --query "[].name" -o tsv`
  deployment.previewOnly     : set to true
  azureTarget.AZURE_RESOURCE_GROUP : ask me for the spoke resource group name;
                               tell me whether it already exists with
                               `az group exists -n "<name>" --subscription "<spoke-sub>"`
  optionalFeatures           : leave the defaults from the example. If the hub
                               already provides Bastion or a jumpbox, confirm
                               DEPLOY_BASTION and DEPLOY_JUMPBOX stay "false".

STEP 9 - Write the file and report.
  Write `config.json` in the repository root, based on config.json.example, with
  everything you discovered filled in. Requirements:
    - valid strict JSON: no comments, no trailing commas
    - no remaining angle-bracket placeholders in any value you claim to have
      resolved
    - delete sections I told you I do not need
    - the Application Insights connection string stays empty

  Then show me a summary table of every value you set, with the az command you
  got it from, so I can spot-check you. Follow it with:
    - UNRESOLVED: values you could not find and what I need to do about each
    - ASSUMPTIONS: anything you inferred rather than confirmed

  Finally, verify your own output by running:
    Get-Content config.json -Raw | ConvertFrom-Json | Out-Null
  and tell me it parsed. Then tell me to run Prompt 2 to deploy.
````

## Prompt 2 — Validate and deploy

Copy everything inside the box.


````text
You are helping me deploy the Azure AI Landing Zone spoke in this repository.

Read `config.json` in the repository root. It was either produced by Prompt 1 or
filled in by hand from `config.json.example`. Use it as the single source of
truth for my environment.
Ignore every key whose name begins with an underscore; those are documentation.

Work through these steps in order. Stop and tell me if any step fails.

STEP 1 - Validate my config before touching Azure.
  a. Confirm `config.json` parses as strict JSON.
  b. Report any value still containing angle brackets, like <subscription-id>.
     These are unreplaced placeholders. List them and stop.
  c. Confirm `deployment.environmentName`, `deployment.location`,
     `deployment.hubVnetResourceId` and `deployment.egressNextHopIp` are all
     present and non-empty. These four are required.
  d. Confirm `hubVnetResourceId` starts with `/subscriptions/` and contains
     `/providers/Microsoft.Network/virtualNetworks/`.
  e. Confirm `egressNextHopIp` is a private IPv4 address (10.x, 172.16-31.x or
     192.168.x). A public IP here is a configuration error - stop and tell me.
  f. Confirm that `existingObservability.applicationInsightsResourceId` and
     `existingObservability.applicationInsightsConnectionString` are either both
     set or both empty. The script throws if only one is supplied. If the
     resource ID is set but the connection string is empty, use the environment
     variable $env:AILZ_APPINSIGHTS_CONNECTION_STRING instead, and tell me if
     that is also empty.

STEP 2 - Check my tools and Azure context.
  Run `pwsh --version`, `az version` and `azd version` and confirm each exists.
  Run `az account show --output json`. If I am not signed in, tell me to run
  `az login --tenant "<tenant-id>"` rather than signing me in to the wrong
  tenant. Compare the signed-in subscription against
  `azureTarget.AZURE_SUBSCRIPTION_ID` and warn me loudly if they differ.

STEP 3 - Verify the hub resources actually exist and I can see them.
  Run `az resource show --ids "<hubVnetResourceId>" --output table`.
  If it fails, the ID is wrong or my identity cannot see it. Report which.
  Then show me the hub VNet address space so I can compare it against the spoke
  range in `spokeNetwork.vnetAddressPrefixes`:
  `az network vnet show --ids "<hubVnetResourceId>" --query "addressSpace.addressPrefixes" -o tsv`

STEP 4 - Handle the spoke address range.
  `vnetAddressPrefixes` is NOT settable through an azd environment variable. If
  `spokeNetwork.vnetAddressPrefixes` differs from the default `192.168.0.0/21`,
  or if it overlaps the hub range you just retrieved, then edit
  `main.parameters.json` and add or update this entry inside the `parameters`
  object, preserving the rest of the file exactly:

      "vnetAddressPrefixes": { "value": [ "<my-range>" ] }

  Show me the diff before you save it. Do not change any other parameter.

STEP 5 - Build the command. Do not invent parameter names.
  Map my config to `Deploy-AilzIntegrated.ps1` exactly like this:
    deployment.environmentName    -> -EnvironmentName
    deployment.location           -> -Location
    deployment.hubVnetResourceId  -> -HubVnetResourceId
    deployment.egressNextHopIp    -> -EgressNextHopIp
    existingObservability.logAnalyticsWorkspaceResourceId
                                  -> -ExistingLogAnalyticsWorkspaceResourceId
    existingObservability.applicationInsightsResourceId
                                  -> -ExistingApplicationInsightsResourceId
    existingObservability.applicationInsightsConnectionString
                                  -> -ExistingApplicationInsightsConnectionString

  Every remaining UPPER_SNAKE_CASE key - from `azureTarget`, `landingZoneDns`,
  `existingPrivateDnsZones`, `optionalFeatures` and
  `additionalEnvironmentVariables` - becomes one entry in a single
  `-AdditionalEnvironmentVariables` hashtable.

  Omit any parameter or hashtable entry whose value is empty. Do not pass empty
  strings. Do not pass keys beginning with an underscore.

  Do NOT set DEPLOYMENT_MODE, NETWORK_ISOLATION, DEPLOY_AZURE_FIREWALL,
  AZURE_LOCATION, HUB_INTEGRATION_HUB_VNET_RESOURCE_ID or
  HUB_INTEGRATION_EGRESS_NEXT_HOP_IP yourself. The script already sets all six.

  Show me the finished command before running it. Mask the Application Insights
  connection string as ***** when you display it.

STEP 6 - Preview only. Change nothing in Azure.
  Run the command with `-PreviewOnly`, regardless of what
  `deployment.previewOnly` says. This runs the repository preflight hook and
  `azd provision --preview`.

  Then summarise the preview for me in plain language:
    - resources to be created, modified, or DELETED
    - any role assignments
    - anything with public network access enabled
    - anything outside my intended resource group or region
  Call out deletions and replacements first and explicitly.

  If preflight fails, explain the specific finding and which config.json value
  fixes it. Common ones: overlapping CIDR (STEP 4), a resource ID I cannot see,
  or missing Contributor / User Access Administrator rights.

STEP 7 - Stop and ask.
  Do not provision. Show me the preview summary and ask whether to proceed.
  Only if I reply "yes, provision" do you re-run the same command WITHOUT
  `-PreviewOnly`. The script will then ask me to type DEPLOY myself - that
  prompt is mine to answer, not yours.

STEP 8 - After a successful provision, remind me of the manual hub steps:
  1. Create the reverse hub-to-spoke VNet peering. This deployment only creates
     the spoke-to-hub direction.
  2. Link hub Private DNS zones to the spoke VNet where Azure Policy does not.
  3. Confirm the hub firewall permits my spoke range.
  4. Test from a host that can reach the spoke, such as a hub jumpbox.

Rules for you: never print the Application Insights connection string, never run
`azd env get-values` (it dumps secrets - use `azd env get-value <NAME>` for a
single value), never edit files other than `config.json` and
`main.parameters.json`, and never provision without my explicit approval.
````

## If you would rather not use Copilot

Find the values by hand. Everything below is read-only:

```powershell
# Subscriptions
az account list --query "[].{name:name, id:id, default:isDefault}" -o table

# Hub VNet candidates - a hub usually has AzureFirewallSubnet or GatewaySubnet
az network vnet list --subscription "<hub-sub>" `
  --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes, subnets:subnets[].name}" -o json

# Hub VNet resource ID
az network vnet show --subscription "<hub-sub>" -g "<hub-rg>" -n "<hub-vnet>" --query id -o tsv

# Firewall private IP (needs the azure-firewall extension)
az network firewall list --subscription "<hub-sub>" `
  --query "[].{name:name, privateIp:ipConfigurations[0].privateIPAddress}" -o table

# Same value without that extension - note the nested ARM property path
az resource list --subscription "<hub-sub>" --resource-type Microsoft.Network/azureFirewalls --query "[].id" -o tsv
az resource show --ids "<firewall-id>" --query "properties.ipConfigurations[0].properties.privateIPAddress" -o tsv

# Existing private link DNS zones
az network private-dns zone list --subscription "<hub-sub>" `
  --query "[?starts_with(name,'privatelink')].{name:name, rg:resourceGroup, id:id}" -o table

# Log Analytics workspaces
az monitor log-analytics workspace list --subscription "<hub-sub>" `
  --query "[].{name:name, rg:resourceGroup, id:id}" -o table
```

Then copy `config.json.example` to `config.json`, paste the values in, and
translate it using the `_mapsTo` note on each section. A minimal run is:

```powershell
$cfg = Get-Content config.json -Raw | ConvertFrom-Json

./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName $cfg.deployment.environmentName `
  -Location $cfg.deployment.location `
  -HubVnetResourceId $cfg.deployment.hubVnetResourceId `
  -EgressNextHopIp $cfg.deployment.egressNextHopIp `
  -AdditionalEnvironmentVariables @{
      AZURE_SUBSCRIPTION_ID = $cfg.azureTarget.AZURE_SUBSCRIPTION_ID
      AZURE_RESOURCE_GROUP  = $cfg.azureTarget.AZURE_RESOURCE_GROUP
  } `
  -PreviewOnly
```

Add further `-AdditionalEnvironmentVariables` entries as you need them. Keep
`-PreviewOnly` until the preview looks correct.

## Related documentation

- [Deployment script reference and troubleshooting](../README.md)
- [AILZ parameter reference](https://azure.github.io/AI-Landing-Zones/bicep/parameterization/)
- [Hub-and-spoke topology](https://azure.github.io/AI-Landing-Zones/bicep/hub-and-spoke/)
- [Permissions](https://azure.github.io/AI-Landing-Zones/bicep/permissions/)
