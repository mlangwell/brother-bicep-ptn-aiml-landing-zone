# ADR-005: Hub prerequisites are deployment prerequisites, not follow-up steps

- Status: Accepted
- Date: 2026-09-27
- Supersedes: nothing
- Amends: ADR-003 (deployment ordering), ADR-004 (live-proof status)

## Context

ADR-003 established a two-pass deployment for `ailz-integrated`: provision the spoke,
have the hub owner create the reverse peering, then rerun with `-DeployApiManagement`.
The stated reason for deferring the peering was API Management, which cannot activate
until its dependencies are reachable over the hub egress path.

A full pre-handoff validation run on 2026-09-27 (commit `6996ca8`, azd 1.34.2,
subscription `67e34e6c-…`, region eastus2) deployed that documented path against a
purpose-built simulated hub — a `10.100.0.0/24` VNet with `AzureFirewallSubnet` and
`AzureFirewallManagementSubnet`, and an `AZFW_VNet` Basic firewall. The run's real
objective was the guardrails playbook, which had never performed a live Azure write.

Pass 1 failed. Not on API Management, which was not enabled, but on the jumpbox:

```
VMExtensionProvisioningError: VM has reported a user failure when processing
extension 'cse' ... Error code: '58'. Error message: 'CustomScript failed to
download the blob https://raw.githubusercontent.com/Azure/bicep-ptn-aiml-landing-zone
/refs/tags/v2.6.1/install.ps1 because it was unable to connect to the remote server.'
```

Thirty-plus resources — Foundry, both model deployments, every private endpoint,
Container Apps, both Search services — had already succeeded. The failure landed on the
last operation, roughly 90 minutes in, and `azd provision` exited 1, so the whole run
reported as failed.

Two independent causes, both of which had to be fixed:

1. **The hub-to-spoke peering did not exist.** The spoke side read `Initiated`; the hub
   had no peering at all. A peering in `Initiated` carries no traffic. The spoke route
   table `rt-…` sends `0.0.0.0/0` to the hub firewall, and `jumpbox-subnet` is attached
   to it, so the download was black-holed.
2. **The hub firewall had no rules.** In `ailz-integrated` mode `deployAzureFirewall` is
   forced to `false`, so `modules/networking/azure-firewall.bicep` — which holds the
   landing zone's entire egress specification, 68 FQDNs across eight purpose-labelled
   sets plus platform network rules — is never deployed. An Azure Firewall with no
   matching rule denies by default.

Neither is a template defect. Both are unstated prerequisites that the documented
ordering actively encouraged an operator to defer.

## Decision

**Treat the reverse hub-to-spoke peering and the hub firewall allow-list as
prerequisites for the first provision, not as post-deployment integration.**

1. `README.md` opens the Deploy section with an explicit prerequisite note describing the
   dependency, the exact CSE error it produces, and the fact that it manifests during
   pass 1 whenever `deployJumpbox` is true.
2. "Complete hub integration" is reframed: the steps remain where the spoke resource IDs
   are available, but they are labelled prerequisites, with a note that a failed first
   pass converges on rerun in about ten minutes.
3. A new "Hub firewall egress requirements" section publishes the allow-list the hub owner
   must mirror, points at `modules/networking/azure-firewall.bicep` as the authoritative
   source, and adds the API Management dependency matrix from the Microsoft Learn
   virtual-network reference.
4. A troubleshooting entry maps CSE error 58 to peering and hub egress, and gives an
   `az vm run-command` probe to confirm the fix **before** paying for another provision
   cycle. The extension's own message blames the blob URI, which is misleading.

We deliberately did **not** make the jumpbox extension non-fatal. It failing loudly is
correct; the defect was that the prerequisite was undocumented, not that the check exists.

## Consequences

- An operator following the README in order now succeeds on the first pass, or fails in
  preflight rather than 90 minutes into a provision.
- The hub owner receives an explicit allow-list instead of inferring 68 FQDNs from a
  failed download.
- The two-pass structure from ADR-003 is unchanged. Only its framing changes: the peering
  moves from "between the passes" to "before the first pass".
- A residual gap remains: preflight enforces the peering requirement for API Management
  (`APIM_HUB_PEERING_MISSING`) but not for the jumpbox. Extending that check to fire when
  `deployJumpbox` is true and the spoke route table forces egress to a hub next hop would
  convert this from a documented prerequisite into an enforced one. Not done here because
  it changes preflight behaviour and deserves its own change.

## Live evidence, 2026-09-27

After both fixes, the documented path completed end to end.

| Claim | Result |
| --- | --- |
| Pass 1 converges after the peering fix | `SUCCESS ... provisioned in Azure in 11 minutes 28 seconds`, exit 0 |
| Egress proven before rerunning | `az vm run-command` from the jumpbox returned `OK STATUS=200 BYTES=41063` |
| Preflight passes the gateway gate once peered | `[INFO] APIM_HUB_PEERING_CONNECTED`, 0 fail |
| ADR-002 ingress resolution against a real hub | Wrapper logged `API Management ingress source: hub AzureFirewallSubnet 10.100.0.0/26.`; the NSG rule `AllowHttpsFromHubFirewall` was created with `sourceAddressPrefixes ["10.100.0.0/26"]`, the subnet prefix rather than the firewall frontend IP |
| Gateway activates | Developer, Internal, private VIP `192.168.3.132`, `provisioningState` Succeeded, no `ActivationFailed`; create took 29 m 38 s (ADR-003 recorded 28 m 44 s) |
| Network posture | Every data resource reported `publicNetworkAccess: Disabled`; both storage accounts `allowSharedKeyAccess: false`; Foundry `disableLocalAuth: true` |
| Teardown | `Remove-AilzEnvironment.ps1` completed in 37 m 48 s, exit 0. Deleted 4 Search shared private links and 2 Azure Monitor private-link scoped resources first, purged the Log Analytics workspace, deleted the resource group, then purged both Key Vaults, App Configuration, API Management and the Foundry account. No `NetworkInjections` failure and no manual purge |
| Teardown verified against a pre-run baseline | Exactly the five original resource groups remained; `az keyvault list-deleted`, `az cognitiveservices account list-deleted`, `az apim deletedservice list` and `az appconfig list-deleted` showed no new entries |

The teardown script also prints a hub follow-up noting that the hub-side peering to the
deleted spoke is now `Disconnected` and must be removed before the spoke is redeployed.
That is correct and was observed.

### Amends ADR-004

ADR-004's controls were **not** exercised by this run, and should not be described as
live-proven. `Deploy-AilzIntegrated.ps1` deploys the gateway service only:
`main.parameters.json` binds `apiManagementConfiguration` to a literal `{}` with no azd
substitution, and the script never sets it. The deployed gateway contained only the stock
`echo-api`, with no named values and no workload API, so the streaming refusal and
call-rate backstop were never deployed and no inference request traversed the gateway.

Only the environment-profile path (`scripts/github/Invoke-EnvironmentDeployment.ps1` with
an `environments/<env>.json` profile) supplies `gatewayConfiguration`. The README now
states this in the API Management section. Proving ADR-004 live requires a deployment
through that path plus a real inference call, and remains outstanding.

### Still not verified

- Gateway activation with the hub-side peering's `allowForwardedTraffic` set to `false`
  (carried over unresolved from ADR-003).
- ADR-002 phase 2: Entra audience app, token, and 401/200/429 checks.
- Any inference call through the gateway, and therefore the `llm-token-limit` behaviour.
- Azure Policy `Deny` actually blocking a non-compliant deployment; the assignments were
  created with `enforcementMode=Default` but no non-compliant resource was attempted.
- An azd environment name long enough to exercise `cafTrim` against the 24-character
  resource-name limits. This run used `ailzverify` deliberately, to match ADR-003's
  proven-good run and isolate the variables under test.
