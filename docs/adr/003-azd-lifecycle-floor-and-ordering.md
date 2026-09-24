# ADR-003: azd floor, two-pass API Management activation and ordered teardown

- Status: proposed (review with ADR-002 in PR #1)
- Date: 2026-09-24
- Owners: AI Landing Zone maintainers
- Related issue or pull request: PR #1 (`feature/apim-platform-separation`),
  [ADR-002](002-apim-merge-conformance.md), the ADR-002 live proof of
  2026-09-23

## Context

The ADR-002 live proof deployed a throwaway hub and spoke on 2026-09-23 with
azd 1.22.5. Build, lint and the full local gate were green, yet three lifecycle
failures appeared that no offline check could see.

1. **Array parameters.** `main.parameters.json` binds the `array` parameters
   `apiManagementIngressSourceAddressPrefixes` and
   `apiManagementDirectCallerAddressPrefixes` as quoted tokens, for example
   `"${API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES=[]}"`. The ingress
   binding shipped on `main` and is pinned by
   `tests/github/fixtures/legacy-contract.json`. With the variable set to
   `["10.100.0.0/26"]`, azd failed with `error unmarshalling Bicep template
   parameters: invalid character '1' after object key:value pair`. Unquoting
   the token satisfies azd but makes the file invalid JSON for the script
   preview, the preflight and the tests, which all parse it first.
2. **API Management activation.** The gateway failed with `ActivationFailed`
   ("Connectivity to Monitoring failed ..."). The spoke-to-hub peering was
   `Initiated`, no hub-to-spoke peering existed, and `AZFWNetworkRule` held no
   rows. The injection subnet routes 0.0.0.0/0 to the hub next hop, which is
   unreachable until both directions exist, so every dependency call was
   dropped. Creating the reverse peering let the gateway activate. The template
   creates only the spoke-to-hub direction, and the README placed the reverse
   peering after provisioning.
3. **Teardown.** `az group delete` failed with `LockedSPLResourceFound` until
   the four Azure AI Search shared private links were deleted. `azd down
   --force --purge` failed before deleting anything with `struct field
   NetworkInjections: json: cannot unmarshal array`, so the soft-deleted API
   Management service, Foundry account and two Key Vaults were purged by hand.

Affected contracts: `azure.yaml` and `Deploy-AilzIntegrated.ps1` (preserved
files), `scripts/Invoke-PreflightChecks.ps1`, the README and the Copilot deploy
prompts. No Bicep resource, parameter, output or binding changes.

### Evidence gathered without Azure writes

- **azd source.** azd 1.22.5 re-serializes each `{ "value": "..." }` and
  substitutes inside the JSON string literal. azd 1.23.4 added a path that, for
  a template parameter typed `array` or `object` whose file value is a string,
  substitutes the string alone and parses the result as JSON
  ([azure-dev#6694](https://github.com/Azure/azure-dev/pull/6694), changelog
  entry "Fix environment variable substitution for array and object Bicep
  parameters"). Bisecting the release tags places it first in 1.23.4.
  [azure-dev#8493](https://github.com/Azure/azure-dev/pull/8493), released in
  1.25.5, moves azd to `armcognitiveservices/v2`, whose `NetworkInjections` is an
  array. azd 1.22.5 pins `armcognitiveservices v1.8.0`.
- **Offline harness.** A test placed in azd's own `bicep` package called its real
  `loadParameters` with this repository's `main.parameters.json` and compiled
  `main.json`, at both tags:

  | Environment value | azd 1.22.5 | azd 1.34.2 |
  | --- | --- | --- |
  | ingress `["10.100.0.0/26"]` | `invalid character '1' after object key:value pair` | array `["10.100.0.0/26"]` |
  | both variables unset | the **string** `"[]"` for both array parameters | array `[]` |
  | two ingress CIDRs, one direct caller | same error | both arrays |
  | ingress set to `""` | not run | array `[]` |
  | ingress `"10.100.0.0/26"`, a JSON string | not run | a string, not an array |

  The 1.22.5 error is identical to the live one. The unset row means an older
  azd sends a string to both array parameters on every deployment, with or
  without API Management. That was not observed live, because the proof used
  native literals. The last row is why the shape guard in `9d4349d` remains
  necessary.
- **Version gate.** With `requiredVersions.azd: ">= 1.25.5"`, azd 1.22.5 exits 1
  with "this project requires a version of azd within the range '>= 1.25.5'",
  and azd 1.34.2 continues. `azd env list` does not load `azure.yaml` and was not
  gated, so environment commands can still run on an older azd.
- **Hook coverage.** In the azd 1.34.2 source the hooks middleware wraps the
  `provision` command, so the `preprovision` preflight also runs for
  `azd provision --preview`. `Deploy-AilzIntegrated.ps1 -PreviewOutput Full`
  calls ARM What-If itself and bypasses the hook.
- **`azd down`.** For a resource-group-scoped template, azd deletes
  `AZURE_RESOURCE_GROUP`, the same call `az group delete` makes, so it meets the
  same lock. With `--force` it skips its warning for a resource group it did not
  create. Azure AI Search deletes a shared private link only from a terminal
  state, asynchronously
  ([Learn](https://learn.microsoft.com/azure/search/troubleshoot-shared-private-link-resources#deleting-a-shared-private-link-resource)).
  Learn does not document `LockedSPLResourceFound` itself; the proof error text
  is the evidence for it.

## Prioritized characteristics

| Characteristic | Priority | Measure |
| --- | --- | --- |
| Compatibility | 1 | `main.parameters.json` and every pinned binding unchanged; `Compatibility.Tests.ps1` passes |
| Deployability | 2 | Array parameters reach ARM as arrays (harness); a gateway is never created before its egress path works |
| Fail early | 3 | Each failure is reported before any Azure write, with its remedy |
| Safe teardown | 4 | Nothing is deleted before the version check, ownership check and confirmation; links are gone before the group is deleted |
| Operability | 5 | One documented command per lifecycle step |

## Alternatives considered

### Array parameters

- **A. Require an azd that parses the pinned binding (selected).** The quoted
  token is the form azure-dev#6694 supports and tests. No contract change, and
  the file stays valid JSON. Cost: operators upgrade azd. Reversible by editing
  one line.
- **B. Native literals** (`"value": []`, as `allowedIpRanges` uses). The file
  stays parseable, but the environment variable is ignored, so the script's
  default never reaches Bicep. It changes a pinned binding.
- **C. A string-typed companion parameter**, split or parsed in Bicep, as
  `foundryIqIngestionPermissionOptionsJson` does. A comma-separated form works
  on any azd, but it adds parameters and changes the binding. The JSON form
  breaks once the value contains quotes, which is a latent defect in that
  precedent: it works only at its default.
- **D. `main.bicepparam`** with `readEnvironmentVariable()` and `json()`.
  Correct, but it replaces the file that consumers overlay.
- **Do not change.** Every azd older than 1.23.4 fails or sends strings to array
  parameters.

### Gateway activation order

- **A. Two passes, enforced by preflight (selected).** The first pass creates
  the spoke. The hub owner then peers it, and the second pass adds the gateway.
  Preflight blocks the second pass until the hub has a Connected peering to the
  spoke.
- **B. The template creates the hub-to-spoke peering** through a module scoped
  to the hub resource group. The spoke deployer would need write access to the
  hub VNet, which platform-owned, AVNM- or policy-managed hubs usually withhold.
  A possible future opt-in.
- **C. Route the dependency service tags from the injection subnet to the
  Internet.** This bypasses the hub firewall that ADR-002 makes the egress path,
  as a workaround for an ordering problem.
- **D. A deployment script that waits for the peering.** It adds a storage
  account and an identity, and still needs the peering created externally
  mid-deployment. It delays the failure rather than preventing it.
- **Do not change.** A first `-DeployApiManagement` run never activates. The
  failure appears only after the service has provisioned, and the failed service
  must be deleted before a redeploy (`ServiceInFailedProvisioningState`).

### Teardown

- **A. A teardown script (selected)** that checks the azd version and resource
  group ownership, confirms, deletes the links, runs `azd down --force --purge`
  and reports the hub-side peering.
- **B. An azd `predown` hook.** Native to azd, but hooks run before azd's own
  delete prompt and cannot see `--force`. Declining the prompt would leave a
  running environment without its Search private links.
- **C. Documentation only.** Explicit, but the operator must sequence the steps.
  Deleting the links and then meeting the version refusal leaves a
  half-disabled environment.
- **Do not change.** Teardown needs hand-holding and manual purges.

## Decision

1. **azd 1.25.5 is the minimum.** 1.23.4 is the floor for provisioning, and
   1.25.5 for `azd down --purge` of Foundry accounts. One floor covers the whole
   lifecycle.
   - `azure.yaml` declares `requiredVersions.azd: ">= 1.25.5"`, which azd
     enforces itself.
   - Preflight mirrors it as `AZD_VERSION_UNSUPPORTED` when Azure lookups run,
     for paths azd does not gate: the full preview, standalone runs and consumer
     projects with their own `azure.yaml`. Deterministic CI runs
     (`-SkipAzureLookups`) do not depend on the runner's azd.
   - The pinned bindings stay as they are.
2. **API Management activates in a second pass.**
   - `Test-ApiManagementHubPeering` lists the hub VNet's peerings when the
     template will create a gateway. It matches the spoke by its recorded
     `VNET_RESOURCE_ID` or, for a prepared spoke, `existingVnetResourceId`.
     Otherwise it matches a peering to a VNet in the target resource group whose
     address space holds the gateway subnet.
   - A new spoke fails with `APIM_HUB_PEERING_MISSING` or
     `APIM_HUB_PEERING_NOT_CONNECTED`. A prepared spoke warns, because an
     operator owns its route table. An unreadable hub warns with
     `APIM_HUB_PEERING_UNVERIFIED`. An unsynchronized peering warns with
     `APIM_HUB_PEERING_NOT_SYNCED`.
   - `Deploy-AilzIntegrated.ps1 -PreviewOutput Full` runs the preflight before
     its What-If.
3. **Teardown is ordered.** `scripts/Remove-AilzEnvironment.ps1` implements
   option A. It refuses a resource group without `azd-env-name=<environment>`
   unless `-AllowExternalResourceGroup` is passed, and it never changes the hub.

## Consequences

- Positive:
  - The pinned contract works as shipped once azd is current.
  - Missing peerings are reported before any Azure write.
  - Teardown completes in one command.
- Negative:
  - Operators on azd 1.23.4 to 1.25.4 must upgrade even to provision. Lowering
    the floor to 1.23.4 would allow that at the cost of `azd down --purge`.
  - A new spoke with API Management takes two passes and a hub-owner step.
  - Preflight makes one extra read-only `az` call when the gateway is enabled,
    and needs Reader on the hub VNet to verify it.
- Neutral:
  - No resource, parameter, output or cost change.

## Compatibility and migration

- `main.parameters.json` and all pinned bindings are unchanged.
- `azure.yaml` and `Deploy-AilzIntegrated.ps1` are preserved files. Their pins
  are updated in `legacy-contract.json` with approved-change notes for the
  script owner to review.
- Consumers who mount this repository at `infra/` keep their own `azure.yaml`.
  They should add the same `requiredVersions` entry or rely on the preflight
  mirror.
- Migration: upgrade azd (`winget upgrade Microsoft.Azd`, or
  <https://aka.ms/azure-dev/install>).
- Semantic-version impact: minor. It adds an operator requirement and a script,
  and changes no template contract.

## Security and identity

- Preflight stays read-only.
- The teardown runs as the operator's `az` and `azd` identities. It deletes
  only in the environment's resource group, only after confirmation, and
  refuses a group azd did not create unless told otherwise.
- No secrets, keys or public access change.

## Adoption and rollback

- **Order:** version floor, preflight gate, preview ordering, teardown script,
  documentation. All are local.
- **Rollback:** revert the commit. Nothing is deployed by this change.

## Compliance verification

- Offline: the azd harness above; the `requiredVersions` probe against azd
  1.22.5 and 1.34.2; `tests/contracts/Test-AzdOperationsContract.ps1`, which runs
  the real preflight, deploy and teardown scripts against recorded stand-ins for
  `az` and `azd`; the local gate.
- **Needs a live run:** a two-pass `-DeployApiManagement` deployment with
  `APIM_HUB_PEERING_CONNECTED` before pass 2; `Remove-AilzEnvironment.ps1`
  against a real environment with Search shared private links; azd 1.34.2
  provisioning the quoted array bindings against ARM.

## Documentation impact

- `README.md`: prerequisites, the preview, API Management, teardown and
  troubleshooting.
- `docs/copilot-deploy-prompt.md` and
  `.github/prompts/deploy-ailz-integrated-apim.prompt.md`.
- ADR-002: live-proof addendum.
- `tests/scripts/Add-HubSpokePeering.ps1`: synopsis.
- `main.bicep`: the `deployApiManagement` description.
- The public `Azure/AI-Landing-Zones` documentation needs a coordinated update
  if this fork's operator flow is published upstream.

## Review trigger

Review when azd changes array-parameter substitution or `requiredVersions`, when
Azure AI Search deletes services that still hold shared private links, when the
template creates the hub-to-spoke peering itself, or at the next live run.
