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
4. Confirm that `pwsh`, `az`, and `azd` are available. Stop and report the
   missing prerequisite if any command is unavailable.
5. Sign in interactively if required, select the requested Azure subscription,
   and show the subscription name, subscription ID, target resource group,
   location, hub VNet ID, and egress next-hop IP for confirmation. Do not print
   the complete `azd` environment.
6. Explain that the script will configure the `ailz-integrated` network-isolated
   topology, route spoke egress through the supplied next hop, and deploy an
   internal Developer-tier API Management service. State that existing
   resources may be modified by the resulting incremental ARM deployment.
7. From the repository root, run the script once with these parameters:
   - Pass the collected environment name, location, hub VNet resource ID,
     egress next-hop IP, and publisher email.
   - Always pass `-DeployApiManagement`.
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
8. When the script displays `Preview complete. Type DEPLOY to continue`, do not
   answer automatically. Summarize any deletes, replacements, role assignments,
   public network access, policy effects, and changes outside the target resource
    group found in the saved preview. Report the preview file path, then ask for
    explicit approval to provision this exact subscription and resource group.
    Send `DEPLOY` only after approval; otherwise send a different response to
    cancel.
9. Do not retry a non-transient failure. Report the failed phase and first Azure
   resource error. On success, report the environment, subscription, resource
   group, deployment status, and Azure portal resource-group URL.