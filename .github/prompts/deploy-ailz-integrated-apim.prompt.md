---
name: "Deploy AILZ with APIM"
description: "Collect required values, preview, and deploy the integrated Azure AI Landing Zone with API Management enabled."
agent: "agent"
---

Run the integrated Azure AI Landing Zone deployment defined by
[Deploy-AilzIntegrated.ps1](../../Deploy-AilzIntegrated.ps1), following the
operator guidance in the [README](../../README.md).

1. Use the question tool to collect all of these values in one interaction:
   - Azure Developer CLI environment name.
   - Azure subscription ID.
   - Target spoke resource group name.
   - Azure location.
   - Full resource ID of the existing hub virtual network.
   - Private IPv4 address of the hub firewall or next-hop NVA.
   - API Management publisher email address.
2. Do not request credentials, tokens, connection strings, or other secrets.
3. Validate the collected values before running anything:
   - Require non-empty values.
   - Require the subscription ID to be a GUID.
   - Require the hub VNet ID to be a complete
     `/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/...`
     resource ID.
   - Require a valid private IPv4 address for the egress next hop.
   - Require a syntactically valid email address.
   If validation fails, explain the invalid field and collect only its replacement.
4. Confirm that `pwsh`, `az`, and `azd` are available, and that `azd version`
   reports 1.25.5 or later; the template's `azure.yaml` rejects older releases.
   Stop and report the missing prerequisite or the upgrade command
   `winget upgrade Microsoft.Azd` if a check fails.
5. Sign in interactively if required, select the requested Azure subscription,
   and show the subscription name, subscription ID, target resource group,
   location, hub VNet ID, and egress next-hop IP for confirmation. Do not print
   the complete `azd` environment.
6. Decide which pass this run is. API Management activates over the hub egress
   path, so it needs a Connected hub-to-spoke peering before the gateway is
   created, and the template creates only the spoke-to-hub direction. Using
   read-only commands only, list the hub VNet peerings with
   `az network vnet peering list --subscription <hub-subscription> --resource-group <hub-resource-group> --vnet-name <hub-vnet> --output json`.
   - If a peering whose `remoteVirtualNetwork.id` is in the target spoke
     resource group has `peeringState` `Connected`, this is the second pass:
     deploy with API Management.
   - Otherwise this is the first pass: deploy the spoke without API Management.
     Explain why before running anything.
   Explain that the script will configure the `ailz-integrated` network-isolated
   topology, route spoke egress through the supplied next hop, and, on the
   second pass, deploy an internal Developer-tier API Management service. State
   that existing resources may be modified by the resulting incremental ARM
   deployment.
7. From the repository root, run the script once with these parameters:
   - Pass the collected environment name, location, hub VNet resource ID,
     egress next-hop IP, and publisher email.
   - Pass `-DeployApiManagement` on the second pass only.
   - Pass `-PreviewOutput Full`.
   - Pass the subscription ID and resource group through
     `-AdditionalEnvironmentVariables` as `AZURE_SUBSCRIPTION_ID` and
     `AZURE_RESOURCE_GROUP`.
   - Do not pass `-PreviewOnly`; the script performs preflight and preview
     before reaching its built-in approval gate.
    Before invoking the script, create a `run-output` directory under the
    repository root and start a PowerShell transcript to a timestamped text file
    named `deploy-ailz-integrated-apim-preview-<timestamp>.txt` in that directory.
    Keep standard input attached to the script so its approval prompt remains
    interactive. Use PowerShell splatting and safely quote every user-provided
    value. Preserve the command output and exit code, and stop the transcript
    when the script completes or fails. Before continuing to step 8, verify that
    the transcript file exists, is non-empty, and contains the completed preview.
    If preflight fails with `APIM_HUB_PEERING_MISSING` or
    `APIM_HUB_PEERING_NOT_CONNECTED`, explain the finding and return to step 6.
8. When the script displays `Preview complete. Type DEPLOY to continue`, do not
   answer automatically. Summarize any deletes, replacements, role assignments,
   public network access, policy effects, and changes outside the target resource
    group found in the saved preview. Report the preview file path, then ask for
    explicit approval to provision this exact subscription and resource group.
    Send `DEPLOY` only after approval; otherwise send a different response to
    cancel.
9. After a successful first pass, stop. Tell me the hub owner must create the
   hub-to-spoke peering. If I own the hub, offer
   `pwsh ./tests/scripts/Add-HubSpokePeering.ps1 -HubVnetResourceId <hub-vnet-id>`,
   but run it only after my explicit approval because it changes the hub. When I
   confirm the peering exists, recheck it with the read-only command from
   step 6, and run the second pass from step 7 only when it shows `Connected`.
10. Do not retry a non-transient failure. Report the failed phase and first Azure
   resource error. On success, report the environment, subscription, resource
   group, deployment status, and Azure portal resource-group URL.