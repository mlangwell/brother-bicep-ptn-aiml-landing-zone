# ADR-006: Guardrails hook visibility, and why auto-apply stays off

- Status: Accepted
- Date: 2026-09-28
- Relates to: ADR-005 (live validation), `scripts/guardrails/`

## Context

The `postprovision` hook in `azure.yaml` runs the post-deployment governance
playbook. Its purpose is to tell the operator, at the end of a provision, that the
landing zone is deployed and governance has **not** been applied, and to give them the
exact command to apply it.

The live run on 2026-09-27 (ADR-005) showed it never reaches them. The hook executed and
exited 0, but its output did not appear. The same hook printed correctly under
`azd hooks run postprovision`, and `preprovision` — configured `interactive: true` in the
same file — printed its full preflight table during the same provision.

azd captures non-interactive hook output and discards it on success. So the one message
the hook exists to deliver was reliably invisible at the one moment it mattered.

Separately, the question arose of whether the playbook should simply apply governance by
default, so that a customer running the deploy script gets it without a second step.

## Decision

### 1. `postprovision` moves to `interactive: true`

This is azd's documented default. Microsoft Learn ("Customize your Azure Developer CLI
workflows using command and event hooks") shows `interactive: false # Default is true`.
The repository had explicitly opted out.

It is safe in CI, on three independent grounds:

- `pipelines/azuredevops/templates/deploy-bicep.yml` runs `azd provision --no-prompt`,
  and `preprovision` — already `interactive: true` — executes in that pipeline today.
  This is an in-repo precedent, not an inference from documentation.
- Neither `scripts/guardrails/Invoke-GuardrailsAzdHook.ps1` nor
  `scripts/guardrails/Invoke-AiGuardrails.ps1` contains `Read-Host`, `Get-Credential` or
  `$Host.UI`. The hook passes `-NonInteractive` unconditionally, and the playbook reports
  "Non-interactive: nothing will be prompted for."
- `interactive` governs stdio attachment; `continueOnError` governs azd's reaction to a
  nonzero exit. They do not interact. Verified by running the hook with redirected stdin:
  it printed its findings and exited 0.

### 2. `GUARDRAILS_AUTO_APPLY` stays `false`

Considered and rejected. The request that prompted it was for the **API Management**
policies — the `llm-token-limit` and the ADR-004 controls — to apply by default. That is
a different subsystem from this flag, which governs Azure Policy, a custom RBAC role and
budgets. Flipping it would over-deliver on that request and create blast radius nobody
asked for. The gateway request is addressed separately, in ADR-007.

On its own merits the flag should stay off:

- **Scope mismatch.** The landing zone deploys into a *resource group*. The playbook
  applies policy at *subscription* scope with `POLICY_EFFECT=Deny` by default. On a
  shared subscription, one team running `azd provision` would silently begin blocking
  every other team's non-compliant deployments, with no signal connecting the two.
- **It would act before anyone read the dry run.** The playbook's value is that its
  findings are read. Applying first inverts that.
- **`continueOnError: true` would swallow a partial apply.** The hook deliberately
  returns the playbook's exit code when applying, so a failure is visible; `azure.yaml`
  discards it. A half-applied governance state (policy created, budget failed) would be
  reported and then ignored. That inconsistency must be resolved before auto-apply could
  ever be considered.
- **It would be a no-op for most callers anyway.** Without `COST_ALERT_EMAILS` and
  `SUBSCRIPTION_BUDGET_AMOUNT` the hook skips regardless of the flag. So flipping it does
  nothing for the majority and creates a sharp edge for the minority who set cost
  variables expecting reporting.

The correct remedy for "the customer does not see governance" is decision 1: make the dry
run visible. Applying stays an explicit opt-in,
`azd env set GUARDRAILS_AUTO_APPLY true`.

If more is wanted later, the right next step is narrowing the playbook's default scope
from the subscription to the deployed resource group. That is a separate change with its
own ADR, not a default flip.

## Consequences

- An operator running `azd provision` or `Deploy-AilzIntegrated.ps1` now sees the
  guardrails result, including the exact command to apply it.
- CI output grows by a few lines per provision. No pipeline behaviour changes.
- `azure.yaml` is a preserved file pinned by `tests/github/fixtures/legacy-contract.json`.
  The pin is refreshed and the change recorded in `approvedChanges`.
- Governance still requires a deliberate act. Nothing is applied to a subscription
  because someone deployed a landing zone.

## Compliance verification

- `pwsh ./scripts/github/Test-GitHubEnvironment.ps1 -TemplatePath ./main.json` —
  13 required suites passed.
- Hook executed with redirected stdin: printed findings, exit 0.
- `azd hooks run postprovision` — output surfaced, "Successfully executed hook".

## Note on the preceding baseline

`dd9453f` added this hook without refreshing the `azure.yaml` pin, so
`Compatibility.Tests.ps1` had been failing since that commit, on `origin`. It was missed
because the individual suites were run directly rather than through
`Test-GitHubEnvironment.ps1`, which is where that test executes. Fixed in `98dcd66`,
with the hook addition recorded in `approvedChanges` rather than blessed silently.
Running the individual suites is not equivalent to running the gate.
