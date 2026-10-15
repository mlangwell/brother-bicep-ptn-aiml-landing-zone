# AI Guardrails — post-deployment playbook

Runs **after** the AI Landing Zone is deployed. Closes the gaps the Bicep template
deliberately leaves open, verifies what the template already owns, and creates the
cost-bounded access model.

Companion to [ADR-004](../../docs/adr/004-gateway-streaming-and-rate-backstop.md), which
covers the gateway-side half of these controls. The two are deliberately split: anything
that must survive a redeploy lives in `modules/api-management/`; anything that configures
subscription-level cost and governance surfaces lives here.

---

## The one thing to understand first

Azure has no native hard spend cap for AI. Microsoft says so in writing:

> "While OpenAI has an option for hard limits that prevent you from going over your
> budget, Azure OpenAI doesn't currently provide this functionality."

So this script does not create a spend cap, because there is none to create. The only
real-time hard stop is the **APIM token limit**, which the landing zone already deploys
and which this script verifies rather than rewrites.

Everything else here is one of three things: a deployment gate (Azure Policy), a
throughput ceiling (Foundry quota), or a smoke detector (budgets, anomaly alerts, daily
cap). Useful, necessary, and none of it stops spend.

---

## Quick start

One command, from a clean checkout:

```powershell
az login
az account set --subscription <the target subscription>

pwsh ./scripts/guardrails/Invoke-AiGuardrails.ps1 -Bootstrap `
     -CostAlertEmails ai-platform-alerts@contoso.com `
     -SubscriptionBudgetAmount 2500
```

That generates `.env` and then dry runs every plane against it. **Nothing is written
to Azure.** Read the output, then repeat the command with `-Apply`.

`-Bootstrap` fills `.env` in from `.env.example`, keeping every comment, and resolves
each setting through one ladder — first non-empty wins:

| | Rung | |
|---|---|---|
| 1 | explicit parameter | `-SubscriptionId`, `-ResourceGroup`, … |
| 2 | environment variable | `AZ_SUBSCRIPTION_ID`, or the azd-set `AZURE_SUBSCRIPTION_ID` |
| 3 | the value already in `.env` | |
| 4 | discovery from the signed-in `az` context | |
| 5 | a prompt | interactive runs only |

Tenant, subscription, resource group, region, assignment prefix, APIM instance, Log
Analytics workspace and Foundry account are all **discovered**, so you are not asked for
them. Only three values are decisions rather than facts about the estate, and those are
the three above: who hears about spend, what "too much" means here, and who gets the
role (`-RoleAssignPrincipalIds`, where blank — the default — creates the definition
without handing it out, which is the recommended first run).

An existing `.env` is **never overwritten** without `-Force`; it is reported and reused.
`-Force` regenerates it and carries over every value the old file had, including settings
the bootstrap does not manage, so a hand-tuned ceiling is not reset to the template
default.

### In CI

```powershell
pwsh ./scripts/guardrails/Invoke-AiGuardrails.ps1 -Bootstrap -NonInteractive -Apply
```

Rung 5 needs a human, and CI has none. Redirected stdin and the usual CI variables are
detected automatically, and a required value with nothing to supply it becomes a **named
failure** — naming the setting, its parameter and its environment variable — rather than
a hang.

### Restricting a run

```powershell
./Invoke-AiGuardrails.ps1 -Plane Cost,Gateway
./Invoke-AiGuardrails.ps1 -Apply -Plane Policy
```

**Dry run is the default.** Without `-Apply` the script makes **no change to Azure** — it
reports exactly what it would do and why. It does write one local file per run: a
timestamped JSON evidence record under `./evidence/` (gitignored). That is the only write
a dry run performs.

---

## Running automatically after `azd provision`

`azure.yaml` declares a `postprovision` hook that runs this playbook against the landing
zone it just deployed, so the governance position is reported rather than remembered.

It is deliberately conservative:

- **Dry run by default.** Applying subscription-scope governance as a side effect of a
  provision, before anyone has read what it would do, is exactly the surprise the rest of
  this playbook refuses to create. Set `GUARDRAILS_AUTO_APPLY=true` to opt in.
- **A no-op when it cannot proceed honestly.** With no `.env` and no supplied decisions it
  skips, prints the command to run, and exits 0. It never fails a provision that
  succeeded, and `continueOnError` in `azure.yaml` backs that up.
- **It bootstraps from the azd environment** when the two required decisions are set
  there. azd already exports `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
  `AZURE_RESOURCE_GROUP`, `AZURE_LOCATION` and `AZURE_ENV_NAME`, so the estate never has
  to be restated:

```powershell
azd env set COST_ALERT_EMAILS ai-platform-alerts@contoso.com
azd env set SUBSCRIPTION_BUDGET_AMOUNT 2500
azd env set GUARDRAILS_AUTO_APPLY true     # optional; without it the hook only reports
```

| Variable | Default | Effect |
|---|---|---|
| `GUARDRAILS_ENABLED` | `true` | `false` skips the hook entirely |
| `GUARDRAILS_AUTO_APPLY` | `false` | `true` runs with `-Apply` instead of a dry run |
| `COST_ALERT_EMAILS` | — | required before the hook will bootstrap a missing `.env` |
| `SUBSCRIPTION_BUDGET_AMOUNT` | — | required before the hook will bootstrap a missing `.env` |
| `ROLE_ASSIGN_PRINCIPAL_IDS` | blank | blank creates the role definition without assigning it |

---

## What it does, by plane

Execution order is deliberate: **safest first, blocking last.**

| Order | Plane | Risk | What it does |
|---|---|---|---|
| 1 | **4 — Cost & logging** | none | Tag inheritance, cost anomaly alert, saved subscription-scope cost view, action group (+ delete lock), Log Analytics daily cap and pre-cap alert, budget verification |
| 2 | **3 — Gateway** | none — read-only | Verifies the token limit, emergency stop, `<base />` inheritance and Entra auth are still in the live policy; computes the metric-cardinality budget |
| 3 | **2 — Foundry** | low | Pins the quota tier upgrade policy; checks public access, local auth, dynamic quota, content logging and deployment sizes |
| 4 | **1 — Policy** | **can block deployments** | SKU and capacity ceilings, tag inheritance policies (with the role grant), location and resource-type gates |
| 5 | **0 — Access** | medium | The cost-bounded custom RBAC role |

---

## The access model: why it's two halves

This is the part most likely to be misunderstood, so it is worth being blunt about.

**Azure RBAC cannot express "not expensive."** A role definition is a list of
resource-provider *operations*. It cannot see the SKU, size, capacity, replica count or
throughput in a request body. There is no role — built-in or custom — that can say "may
create a Fabric capacity, but not an F2048."

Microsoft states the division of labour directly in the
[Azure Policy overview](https://learn.microsoft.com/azure/governance/policy/overview):
Policy evaluates *properties on resources*; RBAC manages *user actions*.

So the guardrail is a pair:

| | Mechanism | Decides |
|---|---|---|
| Half one | The custom role (plane 0) | **Which** resource types may be created |
| Half two | The SKU-ceiling policies (plane 1) | **How expensive** each one may be |

The script **refuses to run** `-Plane Access` without `Policy` for exactly this reason.
Shipping half of it is worse than shipping neither, because it looks finished.

### What the role allows

Allow-list, not deny-list. Anything not named is denied by omission — so a service Azure
ships next quarter is not silently admitted. Adding one is a deliberate, reviewable edit
to `ROLE_ALLOWED_PROVIDERS`.

Default: Foundry and Foundry IQ (`Microsoft.CognitiveServices` + `Microsoft.Search`),
Azure AI Search, Cosmos DB, Fabric, plus the supporting resources a Foundry workload
genuinely needs — storage, key vault, app config, Container Apps, ACR, monitoring,
managed identity, private endpoints and private DNS.

It explicitly cannot: grant itself access, alter budgets or cost alerts, create a
Cognitive Services commitment plan, or cancel the subscription.

### What the policies cap

The custom role decides **which** resource types may be created. These decide **how big
and how expensive** each one may be. Without them the role is unbounded — it can create a
Fabric F2048, an ND96 GPU cluster, or an uncapped Log Analytics workspace, and nothing
notices until the invoice.

Where a built-in already does the job, the built-in is used. Where none exists, there is a
custom definition in `policies/`, and every field alias in it was verified against the
live resource provider. Each definition's header records which built-ins were checked and
why none of them was a substitute.

**Custom definitions** — `policies/`:

| Ceiling | Default | Definition | Why it is custom |
|---|---|---|---|
| Foundry deployment capacity | 50 (≈50,000 TPM) | `foundry-deployment-capacity.json` | The template caps the deployment *SKU name* but not its *size* |
| Foundry account SKU | `S0`, `F0` | `foundry-account-sku.json` | No built-in constrains Cognitive Services account SKUs |
| Foundry dynamic quota | must be off | `foundry-dynamic-throttling.json` | Dynamic quota lets a Standard deployment exceed its TPM and bills the overage; Microsoft publishes no default state and no metric for it |
| AI Search SKU + replicas + partitions | `basic`/`standard`, 2×2 | `search-cost-ceiling.json` | Billed on search units = replicas × partitions, so all three are capped |
| Fabric capacity SKU | `F2`, `F4`, `F8` | `fabric-capacity-sku.json` | No Fabric built-in exists at all; F64 is a large step up |
| **Azure ML compute VM size** | CPU-only, 4 sizes | `aml-compute-sku.json` | **The biggest hole the role leaves open.** `Microsoft.MachineLearningServices/*` grants `workspaces/computes/write` — a GPU cluster at any size. None of the 30 ML built-ins reads `vmSize`. Uses `mode: All`, because `computes` is a child type and `Indexed` would match nothing |
| **Container registry SKU** | `Basic`, `Standard` | `acr-sku.json` | The only SKU-related ACR built-in pushes *up* to Premium for private link — the opposite of a cost ceiling |
| **Log Analytics daily cap** | ≤ 50 GB/day | `log-analytics-daily-cap.json` | No built-in reads `workspaceCapping`. Catches no cap, the `-1` unlimited sentinel, and anything above the ceiling |
| **Container Apps scale** | `Consumption`/`D4`/`D8`, 10 | `container-apps-ceiling.json` | All 11 Container Apps built-ins are HTTPS/auth/network/zone-redundancy. A dedicated workload profile bills per provisioned node whether or not anything runs on it |

**Built-ins** — resolved by GUID and verified against the expected display name before
assignment, so a GUID that silently binds to a different policy fails the run instead of
governing something unintended:

| Ceiling | Default | Built-in |
|---|---|---|
| Cosmos DB throughput | 4,000 RU/s | `0b7ef78e…` (`throughputMax`) — serverless accounts are unaffected |
| Storage account SKU | `Standard_LRS`, `Standard_ZRS`, `Standard_GRS` | `7433c107…` (`listOfAllowedSKUs`) — Premium excluded; the SKU is where replication cost is decided |
| Denied resource types | see `DENIED_RESOURCE_TYPES` | `6c112d4e…` — belt and braces behind the role. Includes `Microsoft.KeyVault/managedHSMs`, which the role does **not** deny by omission: `Microsoft.KeyVault/*` can create one, and a Managed HSM is dedicated hardware billed hourly from provisioning whether or not a key is used |

#### A note on the Log Analytics ceiling

It is an **absolute ceiling**, not a rule against raising the cap. Azure Policy is
stateless: it evaluates the requested end state and never sees the previous value, so
"must not be raised" is not expressible. The ceiling reaches the same outcome from the
other direction — a raise past it is simply a non-compliant end state.

Note also that `LOG_ANALYTICS_POLICY_MAX_DAILY_GB` (the policy ceiling, plane 1) and
`LOG_ANALYTICS_DAILY_CAP_GB` (the cap the script sets on one workspace, plane 4) are
different settings. Keep the ceiling at or above the cap.

---

## Things this script deliberately does not do

Each of these is a judgement, not an omission.

**It does not write APIM policy.** The gateway XML is owned by `modules/api-management/`, and
neither v2 tier supports backup or restore — source control is the only copy. Findings
here tell you what to fix in Bicep.

**It does not touch the budget.** The landing-zone Bicep owns the budget and its
`contactGroups`. The script creates the action group, verifies the budget, and prints the
action group's resource ID for you to paste into `governance.budget.contactGroups`. Two
owners for one resource is how drift starts.

**It does not wire the budget to the emergency stop.** That chain — budget → action group
→ automation → `-stop` named value → 503 — is real and documented in the guide, but a 503
kill switch is only safe once somebody has actually *rehearsed* turning it off. The script
reports this as a gap with the precondition attached.

**It does not create the Throttled Time Series alert.** The portal exposes the signal, but
Microsoft publishes no `metricNamespace`/`metricName` pair for it, and it is a
subscription+region scoped Azure Monitor self-monitoring metric rather than an APIM
resource metric. The script probes the live metric definitions and reports candidates
rather than hardcoding a plausible-looking string.

**It does not widen scope silently.** "Allowed locations for resource groups" cannot work
at resource-group scope. Rather than quietly promoting the assignment to subscription
scope, the script skips it and prints the exact command to run.

---

## Safety properties

**Fail-closed pre-flight.** Tenant, subscription and resource group are checked against
the live `az` context before anything is written. A mismatch aborts the run. This is the
cross-engagement guard — deploying one customer's governance into another's subscription
is not fixable by renaming.

**Discovery corroborates before it commits.** `-Bootstrap` will not accept a resource
group just because it happens to hold the subscription's only Foundry account — plenty of
subscriptions hold exactly one unrelated account. It accepts a discovered resource group
only when the azd environment tag matches, or when the group carries landing-zone policy
assignments stamped by the same template this playbook follows. Otherwise it names the
candidate and stops, because the resource group decides which estate the run governs and
a coin toss there is the same cross-engagement hazard.

**Idempotent.** Every action reads current state first and is skipped when the desired
state already holds. Reruns converge; they do not duplicate.

**Every policy object is stamped with its owner.** Definitions and assignments created here
carry `metadata['ailz-owner'] = 'ailz-guardrails:<subscription>:<prefix>'`, a distinct
namespace from the Bicep template's `ailz-governance:`. This is what makes removal possible
at all: the playbook reuses the template's `ASSIGNMENT_PREFIX`, so name alone cannot tell
the two apart. A missing or foreign stamp is treated as drift and repaired on the next run,
so nothing created before stamping existed stays unidentifiable.

**An apply records what it replaced.** Each result carries `PriorState` — the probe's
reading from *before* the change — alongside the evidence of the write itself. Three of
these changes are settings rather than resources (tag inheritance, the Log Analytics daily
cap, the Foundry tier-upgrade policy) and for those the pre-change value is the only way
back. Absence is recorded explicitly as `present: false` rather than left null, because
"it was off" and "we did not look" are different facts.

**GUID verification.** Every built-in policy is resolved by GUID and then checked against
its expected display name. A GUID that resolves to a different policy than you think is a
silent, expensive mistake, so a mismatch fails the run rather than assigning something
unknown. All eight were verified live during development.

**The SDK/Bicep role-grant trap is handled.** Portal-created policy assignments get their
managed identity's roles automatically; CLI, SDK and Bicep ones do not. Without the grant
a `Modify` assignment looks assigned, reports compliance, and fixes nothing. The script
creates the grant explicitly and reports failure loudly if it cannot.

**Status vocabulary distinguishes "verified correct" from "could not verify."**

| Status | Meaning |
|---|---|
| `Applied` | Written this run |
| `WouldApply` | Dry run — would be written with `-Apply` |
| `Compliant` | Already in the desired state; nothing done |
| `Skipped` | Turned off in config, or a prerequisite is absent |
| `Finding` | Needs a human decision or a fix elsewhere |
| `Unverifiable` | Could not be determined — reported, not guessed |
| `Failed` | Attempted and errored |

---

## Enforcement: Deny is the default

`POLICY_EFFECT=Deny` out of the box. The ceilings block non-compliant deployments from
the first `-Apply`, and there is no staged rollout to remember to finish.

That is a deliberate reversal of the usual advice, so it is worth saying why. **A soak
exists to discover which *existing* workloads a new ceiling would break.** This playbook
runs against a landing zone that was just deployed, which has none. Assigning in Audit
here would buy nothing and cost something real: a window in which the custom role is live
and the ceilings are inert — the "looks finished but isn't" state that the role/policy
pairing exists to prevent.

**Choose `POLICY_EFFECT=Audit` deliberately when retrofitting** these ceilings onto a
subscription that already has running workloads. That is the case a soak is for:

1. Assign in Audit. Everything lands as `enforcementMode=DoNotEnforce` — evaluates and
   reports, blocks nothing.
2. Read the compliance results after at least one full 24-hour evaluation cycle.
3. Fix or exempt whatever the ceilings would have blocked.
4. Set `POLICY_EFFECT=Deny` and rerun. One property change, no re-authoring.

You will also need `ROLE_REQUIRE_ENFORCING_CEILINGS=false` for the duration, because the
run otherwise refuses to create a role whose ceilings do not enforce — and the role *is*
unbounded until you flip. Microsoft publishes no soak duration, so pick one from your own
release rhythm and write down the date you will flip.

---

## Removing the guardrails

There is **no `Remove-AiGuardrails.ps1` yet** — that is deliberate, and this section is
what stands in for it. Removal is by hand, from this runbook.

Everything below is at **subscription** scope. `azd down` and
`scripts/Remove-AilzEnvironment.ps1` tear down the landing zone's *resource group* and do
not touch any of it. Removing the landing zone does not remove its guardrails.

### How to tell what is yours

Every policy definition and assignment this playbook creates carries
`metadata['ailz-owner'] = 'ailz-guardrails:<subscription-id>:<prefix>'`. The dry-run output
prints the exact value under **Ownership stamp**.

**Filter on that stamp. Never reconstruct names.** The landing-zone Bicep uses the *same*
`ASSIGNMENT_PREFIX` at the same scope and stamps its own objects
`ailz-governance:` — so name prefixes alone cannot tell the two apart, and
`Get-AssignmentName` SHA-256 truncates anything over 24 characters. A removal that
rebuilds names will, on the first hashed name, find nothing and report success over a live
enforcing `Deny` assignment.

```powershell
$stamp = 'ailz-guardrails:<subscription-id>:<prefix>'   # copy from the dry-run output
$sub   = '<subscription-id>'

# What this playbook owns, and nothing else:
az policy assignment list --scope "/subscriptions/$sub" --query "[?metadata.\"ailz-owner\"=='$stamp'].name" -o tsv
az policy definition list  --subscription $sub          --query "[?metadata.\"ailz-owner\"=='$stamp'].name" -o tsv
```

### Order matters

Dependencies, not planes, set the order. Each step fails while the one above it is undone.

**1. Revoke the policy identities' role grants — before deleting the assignments.**
Deleting an assignment destroys its system-assigned identity, which leaves an unresolvable
"Identity not found" grant that can no longer be looked up by principal.

Do **not** name the loop variable `$pid`. `$PID` is a PowerShell automatic variable holding
the current process ID; assigning to it does not take, and every revoke then runs against
the process ID and fails with `No matched assignments were found to delete` — silently
defeating this entire step. Verified the hard way on the first live teardown.

```powershell
foreach ($name in (az policy assignment list --scope "/subscriptions/$sub" --query "[?metadata.\"ailz-owner\"=='$stamp'].name" -o tsv)) {
  $principalId = az policy assignment show --name $name --scope "/subscriptions/$sub" --query identity.principalId -o tsv
  if ($principalId -and $principalId -ne 'null') { az role assignment delete --assignee-object-id $principalId --scope "/subscriptions/$sub" }
}
```

If the assignments were already deleted and the grants are orphaned, principal lookup can
no longer find them. Recover from the **evidence file**, which records the exact
`roleAssignmentId` of every grant the run created, and delete by id:

```powershell
$ev = Get-Content ./evidence/guardrails-apply-<stamp>.json -Raw | ConvertFrom-Json
$ev.Results |
  Where-Object { $_.Name -like '*Identity role grant*' -and $_.Evidence } |
  ForEach-Object { az role assignment delete --ids $_.Evidence.roleAssignmentId }
```

Do this rather than deleting every unresolved grant on the subscription. A shared
subscription can carry unrelated orphaned grants — the first live teardown found 16
unresolved principals, of which only 6 were the playbook's and 10 were pre-existing
`Owner` grants belonging to someone else.

Two more things a script here must get right, both found live:

- Under `Set-StrictMode`, `$_.metadata.'ailz-owner'` **throws** on any object whose
  `metadata` lacks the key. With `$ErrorActionPreference = 'Continue'` the pipeline keeps
  going and the filter still returns the right objects, so it looks like it worked while
  emitting an exception per non-matching object. Probe
  `$_.PSObject.Properties['ailz-owner']` explicitly.
- Reuse the api-versions the apply modules use. `DELETE` against
  `settings/taginheritance` with a stale api-version returns a bare `Bad Request` that
  reads like a permissions or payload problem.

**2. Delete the assignments.** Definitions will not delete while assigned.

**3. Delete the custom definitions** (filtered by the stamp, as above).

**4. Remove both `CanNotDelete` locks, then the resources they protect.** There are two —
the action group and the pre-cap alert rule — each named `<resource>-nodelete`.

```powershell
az lock delete --name "<resource>-nodelete" --resource-group <rg> --resource-name <resource> --resource-type <type>
```

**5. Delete the resources:** action group, cost anomaly alert, saved cost view,
subscription budget, pre-cap log search alert.

**6. Delete the custom role — enumerate its live assignments first.** Do not replay
`ROLE_ASSIGN_PRINCIPAL_IDS`; an operator may have added their own, and the role will not
delete while any assignment remains. Orphaned assignments whose principal no longer exists
must be deleted by assignment **id**, not by `--assignee-object-id`.

```powershell
az role assignment list --role "<ROLE_NAME>" --scope "/subscriptions/$sub" --query "[].id" -o tsv |
  ForEach-Object { az role assignment delete --ids $_ }
az role definition delete --name "<ROLE_NAME>"
```

### The three settings do not "delete"

These are settings, not resources. Their previous values are in the evidence file for the
run that changed them, under `PriorState` — but **the semantics differ per setting**, and a
uniform "restore the captured value" is wrong for two of the three.

| Setting | Prior state recorded | How to undo |
|---|---|---|
| **Log Analytics daily cap** | `dailyQuotaGb`, with `-1` meaning unlimited | Restorable. `az monitor log-analytics workspace update --quota <prior>`. Confirm `-1` genuinely clears it — Microsoft documents setting the cap but publishes no unset sentinel |
| **Cost Management tag inheritance** | `{ present: false }` when it was off | **Not a restore.** Microsoft documents only how to *enable* tag inheritance and publishes no unset operation. If `present` was `false`, the undo is a `DELETE` of the `taginheritance` setting — PUT-ing `preferContainerTags=false` leaves the feature **enabled** and silently changes billing-record tagging |
| **Foundry `tierUpgradePolicy`** | `tierUpgradePolicy`, plus `readable` and `wasUnset` | **Report, do not revert.** Preview surface, and PATCH-ing a captured `null` back is not a defined operation. If `wasUnset` was true, record it as not reverted rather than guessing |

`readable: false` on the Foundry record means the value could not be read at that
api-version — that is *unknown*, not *unset*. Do not restore from it.

### Why the script is deferred

The hard part of a removal tool is "identify only what we created", and that can only be
validated against real objects. The first `-Apply` produces the specification: real IDs,
real ordering failures, real error text. Writing it before then is building the difficult
half blind. The ownership stamp is the part that had to ship first, because an object
created **without** it can never be safely identified afterwards.

---

## Permissions needed

| Plane | Needs |
|---|---|
| 4 Cost | Cost Management Contributor + Contributor on the RG |
| 3 Gateway | Reader on the APIM instance |
| 2 Foundry | Contributor on the subscription |
| 1 Policy | Resource Policy Contributor **plus** User Access Administrator or Owner — the role grants in plane 1 need `Microsoft.Authorization/roleAssignments/write` |
| 0 Access | Owner or User Access Administrator |

If plane 1 reports that it could not grant the managed identity its role, that is almost
always this: the signed-in principal lacks `roleAssignments/write`. **Do not work around it
by widening the policy or skipping the identity** — the assignment will silently remediate
nothing.

---

## Files

```
scripts/guardrails/
├─ Invoke-AiGuardrails.ps1          orchestrator; dry run by default
├─ Invoke-GuardrailsAzdHook.ps1     azd postprovision hook; skips safely
├─ .env.example                     annotated configuration template
├─ modules/
│  ├─ Guardrails.Common.psm1        config, fail-closed pre-flight, ARM calls, evidence
│  ├─ Guardrails.Bootstrap.psm1     .env generation, discovery, resolution ladder
│  ├─ Guardrails.Cost.psm1          plane 4
│  ├─ Guardrails.Gateway.psm1       plane 3 (read-only)
│  ├─ Guardrails.Foundry.psm1       plane 2
│  ├─ Guardrails.Policy.psm1        plane 1
│  └─ Guardrails.Access.psm1        plane 0
├─ policies/                        custom policy definitions (no built-in exists)
├─ roles/ai-innovator.role.json     custom role template
├─ .env                             generated by -Bootstrap (gitignored)
└─ evidence/                        timestamped JSON, one per run (gitignored)
```

Linted by `scripts/github/Test-CodeStyle.ps1` alongside the rest of the repository.

---

## A caveat on the evidence file

ARM completion is not compliance. A policy assignment existing does not mean the estate is
compliant, and a budget existing does not mean spend is capped. The evidence file records
what was **configured** — nothing more. Compliance data arrives on the 24-hour evaluation
cycle, and spend is bounded by the gateway, not by anything in this directory.

