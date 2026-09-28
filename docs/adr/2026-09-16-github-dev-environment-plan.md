# GitHub-first development environment: decision and implementation plan

- Status: proposed implementation plan; documentation only.
- Date: 2026-09-16.
- Customer: Brother.
- Repository: `mlangwell/brother-bicep-ptn-aiml-landing-zone`.
- Working directory: `C:\Users\johnhain\Documents\brother\brother-bicep-ptn-aiml-landing-zone`.
- Inspected branch and commit: `main`, `98505e685de460e385c15bcb6c1e0a47e33ffdf0`.
- Microsoft accelerator reference: `Azure/bicep-ptn-aiml-landing-zone`, release `v2.6.1`, commit `64195c01b70974fa7256c2f54a0035fb06804139`.
- Decision provenance: the user requested a usable development environment, a path to queue test/production, Azure Policy and cost controls, then a GitHub-first plan for additive changes. GitHub adoption is planned, not reported as complete.

## 1. Outcome and authorization boundary

The outcome is a developer who can sign in, open the correct prepared workspace,
run an authenticated model-backed starter over the intended private network,
observe the request, and queue a protected deployment of the same release to
test or production. Successful infrastructure provisioning alone is not this
outcome. Test and production need not be provisioned during initial dev setup.

This document authorizes no execution. A future user instruction to implement
this plan permits local implementation within its scope. It does not authorize
Azure changes, GitHub administration, workflow dispatch, publishing, pushes,
pull requests, releases, or changes to customer access.

Keep these boundaries throughout implementation:

- Read `AGENTS.md` and applicable scoped instructions before editing.
- Use the existing Bicep accelerator and Azure Verified Modules. Do not replace
  the landing zone with newly generated infrastructure.
- Preserve existing Azure DevOps assets and the existing deployment entry points.
  GitHub becomes the new path, not a reason to remove the old one.
- Keep new gateway, governance and developer-completion behavior opt-in.
  Existing parameter files must retain their current behavior.
- Local scripts, examples, tests and workflows can be built without real
  subscription IDs, budget amounts or credentials. Require those inputs before
  remote execution instead of inventing them.
- Finish local implementation and report its evidence before requesting
  approval for any specific remote action. Do not set authorization-bypass
  environment variables or infer approval from this document.
- Do not expand this into a full enterprise platform landing zone, a business
  application, a bespoke runner autoscaler, or an invoice-dollar accounting
  service.

## 2. Decisions and alternatives

| Decision | Selected direction | Reason and trade-off |
| --- | --- | --- |
| CI/CD platform | GitHub Actions for the new path; retain Azure DevOps | Changes delivery integration, not the core workload architecture. |
| Deployment mode | Preserve the Brother hub-integrated, private design | The current wrapper already establishes this intent. Complete hub-side work rather than opening public endpoints. |
| CI/CD authentication | GitHub OIDC and scoped Azure identities | No long-lived Azure client secret in GitHub. Separate preview, deployment and privileged bootstrap access. |
| Private execution | Prefer GitHub-hosted larger Linux runners with Azure private networking | Reuses GitHub-managed runners. Support an existing approved private Linux runner group as a configured reuse path. Do not build a new autoscaling platform. |
| Inference enforcement | Ordinary APIM policies as the baseline | Provides runtime token/rate enforcement without making Foundry's preview integration a production prerequisite. |
| Gateway topology | Private APIM per new environment; Standard v2 is the dev reference | Private inbound endpoint plus outbound VNet integration is documented. Production SKU, availability and capacity require an approved production profile. |
| Foundry portal integration | Optional, off by default | Native project-token controls are APIM-backed, but the Foundry-integrated gateway experience is still documented as preview. |
| Starter workload | Small text-inference example, not a full RAG application | Establishes a useful end-to-end development path without inventing a customer use case. |
| Triggers | Automatic credential-free CI; opt-in CD dispatch | Avoids creating resources or incurring deployment costs merely by pushing the new workflow files. |

Alternatives considered:

- **Keep manual setup:** least engineering, but leaves networking, runtime
  configuration and pipeline registration manual. Does not meet the stated
  ready-to-develop outcome.
- **Require a full platform ALZ rollout first:** useful for broader subscription
  vending and organization-wide governance, but disproportionate for this task.
- **Make the new Foundry gateway experience mandatory:** attractive portal UX,
  but adds preview/support constraints that are unnecessary for baseline APIM
  enforcement.
- **Treat Azure budgets as a spending switch:** rejected; budgets notify and do
  not stop resources.

Priorities, in order: preserve existing behavior; protect deployment authority;
make readiness observable; make promotion reproducible; contain and attribute
cost without claiming an unsupported hard financial cap.

## 3. Verified starting state

These are observations from the inspected commit, not assumptions about live
Azure resources or the future customer GitHub organization.

| Surface | Finding | Implementation consequence |
| --- | --- | --- |
| `Deploy-AilzIntegrated.ps1` and `README.md` | Wrapper sets integrated mode, network isolation and hub egress. Reverse peering, shared DNS links and firewall verification remain operator steps. | Add an explicitly authorized platform-completion path and verify connectivity. |
| `azure.yaml` | Bicep infrastructure and preprovision hook only; no application service or postprovision hook. | Add an opt-in application/completion path. Do not imply `azd provision` already deploys a usable application. |
| `main.bicep`, around line 3824 | Main App Configuration population is skipped under network isolation. | Populate required runtime configuration from a network-connected completion stage. |
| `main.bicep`, around lines 1226 and 2848 | Container Apps uses a pinned .NET sample placeholder image. | Deploy the selected application artifact after infrastructure. Do not leave or restore the placeholder as the running workload. |
| `main.bicep`, around lines 1891-1919; `install.ps1`; `manifest.json` | CSE downloads the Microsoft upstream installer at `ailz_tag`; installer clones upstream. Components are empty. Some tools and extra clones are optional. | Editing the local installer alone does not change what CSE downloads. Add a customer-owned completion stage from the selected artifact. |
| `install.ps1` | Bootstrap runs as LocalSystem and can delete/reclone its infrastructure checkout on rerun. | Do not equate bootstrap authentication with the developer's login. Keep editable developer work outside that checkout and preserve dirty worktrees. |
| `main.parameters.json` | Address/subnet parameters are not bound; tags are an empty literal; several deployment lists are fixed. | Resolve real per-environment values with typed bindings. Do not set unused environment variables and claim parameterization. |
| `main.bicep` executor assignments | Grants target `principalId`, which becomes the CI/CD identity when run from a pipeline. | Human onboarding and governed runtime permissions must be separate from executor permissions. |
| `pipelines\azuredevops\` | Useful scaffold, but does not create service connections/environments. CD downloads an artifact but deploys from checkout; preview template is unused; Brother hub values are not supplied. | Reuse the intended stages, not these implementation defects. Leave ADO behavior unchanged in this scope. |
| `.github\workflows\bicep-validate.yml` | References tests under `tests\scripts` and `tests\contracts` that are missing from this checkout. | Restore/reconcile the required validation before relying on the GitHub CI gate. |
| Source Bicep/JSON/PowerShell/YAML | No Azure Policy assignments, Cost Management budgets or APIM resources were found. | These are additive capabilities, not configuration of an existing implementation. |

`POLICY_MANAGED_PRIVATE_DNS` is not a general Azure Policy enablement flag.
Keep it false until actual DNS-management policies are assigned and proven.
With BYO hub zones, explicitly own their links and resolution path; do not
create competing zones or assume peering alone supplies DNS resolution.

## 4. What APIM does and does not control

APIM is the runtime enforcement point for supported inference traffic that
passes through it. It can reject additional requests based on authenticated
caller limits, model access rules, token rates and period-token quotas.
That is materially stronger than a budget notification.

| Layer | Required responsibility | Boundary |
| --- | --- | --- |
| Azure Policy | Approved models/deployment types/regions, intended networking, disabled local keys, ownership tags and diagnostics | Controls configuration. It is not a cumulative invoice-dollar counter. |
| APIM | Authenticate, authorize, route, apply token/rate quotas and provide a controlled stop-new-requests switch | Only covers its governed routes and supported metering. It does not stop every Azure charge. |
| Foundry Control Plane | Optional project/model gateway management and operational visibility | Native token enforcement requires gateway onboarding. Do not treat portal visibility as proof every request traverses APIM. |
| Cost Management | Whole-environment actual/forecast budgets, alerts, named recipients and reconciliation | Reporting is delayed; resources continue running when budgets are exceeded. |
| Resource lifecycle | Approved capacity/autoscale limits, retention and dev-compute schedules | Fixed charges such as gateway, Search, compute and provisioned capacity can continue after inference is blocked. |
| GitHub billing | Track runner, artifact and Actions usage separately | GitHub charges are not included in an Azure resource-group budget. |

### Enforcement contract

1. Validate client Entra tokens and authorize the caller before forwarding.
   Use APIM managed identity for the Foundry backend, not shared backend keys.
2. Derive counter keys from validated identities and configured environment,
   project and model mappings. Do not trust a caller-supplied project header or
   use source IP as the primary identity boundary.
3. Apply explicit token rates and fixed-period quotas. Missing required limits
   must fail the governed profile, not become unlimited access.
4. Native `llm-token-limit` returns 429 for rate limits and 403 for exhausted
   period-token quotas. Preserve these errors and their retry semantics.
5. Counters are gateway-local. Do not claim an aggregate ceiling across
   independent regional, workspace or other gateways. Multiple scopes using a
   shared key need consistent rate configuration and tested accounting.
6. Prompt/completion tokens are not a dollar measure. Streaming estimates and
   concurrent/in-flight requests can overshoot a threshold before subsequent
   requests are blocked. A stop-new-requests switch does not cancel in-flight
   backend processing.
7. Record a coverage matrix. The initial governed sample uses the Responses
   API. Embeddings, asynchronous batch, realtime/audio, image generation, tools
   and managed-agent internal calls are not automatically covered by that
   route or token policy. Disable unapproved routes for the starter; add wider
   coverage only with supported routing, metering and evidence.
8. Test gateway bypass from the developer, workload and runner contexts. Normal
   governed callers must not have direct backend keys or inference privileges.
   Explicitly separate privileged deployment/break-glass access, which is not
   subject to the same runtime cap.
9. Preserve required managed-service access to Storage, Search and Cosmos.
   Gateway-only inference must not remove unrelated data-plane dependencies.
10. Emit request correlation, caller/project/model, token and rejection metrics.
    Do not log prompts, completions, authorization headers or secrets by default.

For budgeting, obtain current prices for the selected models, deployment types,
billable token categories and supporting services. Record the pricing date and
units. Allocate an inference allowance separately from infrastructure costs,
translate it conservatively into configured token allowances, and reconcile
against billed meters. Do not invent prices or default financial thresholds.

The initial scope does **not** include a custom currency ledger, distributed
reservation system or invoice-accurate hard dollar cap. An estimated-currency
enforcer would be additional application engineering, not a native APIM switch,
and would still need an explicit coverage and overshoot model.

## 5. GitHub-specific requirements

### Identities and approvals

- Use OIDC with exact repository/environment trust and the supported Azure
  audience. Give `id-token: write` only to trusted jobs that need Azure access.
- Use separate preview and deployment identities. Preview permissions must
  include the actual What-If operations required; plain Reader is not assumed
  sufficient. Preview identities must not have ordinary resource-write access.
- Create `dev-preview`, `test-preview` and `prod-preview` GitHub environments
  for constrained preview jobs, and `dev`, `test` and `prod` for deployment.
  This lets reviewers see the preview before the protected deployment begins.
- Require independent approval for test/prod deployment, prevent self-review,
  restrict eligible branches explicitly, and disable administrator bypass
  where the approved GitHub configuration supports it.
- Manual workflow dispatch is not a substitute for an independent approval.
  Fail bootstrap/readiness if the required protections cannot be established.
- Keep privileged platform/bootstrap identities separate from all of these.
  Do not grant an ordinary developer subscription-wide access administration.

**Licensing gate:** GitHub documents required environment reviewers on
Free/Pro/Team as public-repository-only. Verify entitlement for the actual
customer repository before promising native protected private-repository
promotion. This working repository is public; do not infer customer entitlement
from it or make a customer repository public as a workaround.

**OIDC format gate:** repositories created after 2026-07-15, and later
renames/transfers, use immutable default subjects containing owner and repository
IDs. Older repositories can retain legacy or customized subjects. This working
repository was created on 2026-09-11. Query the actual target configuration and
verify its emitted claims without logging a JWT; never blindly copy a legacy
`repo:name/name` federation example or reuse this fork's trust for another repo.

### Runners and artifacts

- Credential-free PR validation runs on ordinary hosted runners. Untrusted PR
  code must not run on the private deployment pool or receive Azure credentials.
- Prefer GitHub-hosted larger Linux runners connected to Azure private
  networking. Standard `ubuntu-latest` is not that networking configuration.
  Verify organization support, region, runner-group restrictions and billing.
- An existing approved private Linux runner group is a supported input.
  Do not silently substitute public access or a long-lived privileged runner.
- Reserve the necessary subnet and routing/DNS/egress integration before using
  the private runner. Do not assume a subnet named for build agents is already
  configured for GitHub or can share another service's exclusive delegation.
- Restrict inbound runner access and allow only the egress required for GitHub,
  Azure authentication/control-plane operations and approved dependencies.
- Only a successful trusted CI run from the approved repository/ref may supply
  a release bundle. A successful fork PR or arbitrary artifact ID is insufficient.
- Bind the bundle to its source SHA, workflow/run identity, contents checksum,
  infrastructure version, application image digest and configuration schema.
  Verify those facts before privileged code execution.
- Build application images once. For private registries, import the selected
  OCI artifact from a private runner and verify the image digest is preserved.
  Do not rebuild independently for test and production.
- Preview and deploy must resolve identical artifact and configuration inputs.
  Record the resolved nonsecret configuration hash. If inputs change after
  approval, invalidate the approval rather than deploying a different plan.
- Serialize mutation per environment and do not cancel an in-progress deploy.
  Require successful promotion evidence for the selected release, not merely
  the absence of a failed job in the current workflow.

## 6. Additive contracts and ownership

The following are planned surfaces, not claims about parameters that already
exist. Follow existing naming and types when implementing their public bindings.

| Surface | Ownership and required behavior |
| --- | --- |
| `main.bicep` | Remains the resource-group orchestrator. Add only opt-in module wiring, described parameters and necessary outputs. |
| `modules\api-management\` | New AVM-backed gateway resource/configuration boundary, with private networking and backend managed identity. Default disabled for existing consumers. |
| `platform\` | Separate privileged bootstrap deployment boundary for scoped policy/budget/identity and hub/runner integration. No tenant-wide policy rollout by default. |
| `environments\` | Shared schema and sanitized dev/test/prod examples. Actual deployment configuration is operator supplied; do not commit customer secrets or silently copy local `.azure` state. |
| Shared PowerShell resolver | Converts validated profile inputs into typed Bicep/azd inputs used identically by local preview, GitHub preview and deployment. |
| Shared completion scripts | Populate private runtime configuration, initialize approved data-plane objects, deploy the selected app and produce readiness evidence. |
| `samples\developer-smoke\` | Minimal model-backed starter with a health endpoint that makes no model calls and an authenticated text-inference path. Not a customer business application. |
| `.github\workflows\` | Reuse/extend existing validation; add manual environment CD and a reusable deployment workflow. No automatic Azure provisioning on push. |
| Customer workspace | Separate from CSE's disposable infrastructure checkout. Preserve existing files, branch state, authentication boundaries and local edits. |

The environment schema must cover Azure scope/region, integrated topology and
nonoverlapping address allocation, explicit feature flags, model/deployment
settings, approved identity mappings, gateway configuration, budgets/alerts,
runner group, and references to the immutable release. Missing deployment-only
inputs are validation errors before remote execution. Offline fixtures must be
clearly synthetic and must never be deployment defaults.

Bind new Bicep inputs through `main.parameters.json` where azd needs them,
including list/object types and safe empty-substitution handling. Preserve
existing names, defaults, outputs, CAF/legacy naming and `infra` submodule
consumers. New gateway endpoint/audience/access-mode settings are additive;
existing direct Foundry outputs remain available for compatibility and
administration, not as an automatic governed-runtime fallback.

Reuse the existing runtime-configuration shaping when exposing values to the
private completion stage; do not maintain a second hand-copied list of settings.
Keep secrets out of any new deployment output or release artifact. Allocate
gateway-integration and runner networking explicitly; do not repurpose an
existing delegated application or agent subnet to make the additions fit.

Policy and APIM writes must be scoped to owned assignments/APIs/backends. Read
before writing, reconcile idempotently, preserve unrelated settings and fail on
conflicting ownership. Do not replace a shared gateway's global policy or a
subscription's existing policy estate.

## 7. Work packages

### P0 - Establish the executable baseline

Start by reading this plan and `AGENTS.md`, then inspect current branch, worktree
and integration-branch ancestry. Preserve user changes. The inspected commit is
an evidence anchor, not permission to reset a newer checkout.

Restore/reconcile the tests referenced by `bicep-validate.yml` from the pinned
Microsoft release where available. Inventory all referenced scripts, including
the deterministic preflight, size and Copilot validator tests and contract
tests. Do not make CI green by silently deleting useful checks.

Load `coding-rigor`, `engineering-principles` and `iac-validation` for local
implementation. Add failing tests before changed logic. Keep unrelated baseline
defects separate, but fix blockers tightly coupled to the new CI path.

**Exit:** the existing applicable local validation can actually run, and an
intentional validation failure propagates as a failed CI command.

### P1 - Implement the shared environment contract

Add the environment schema, sanitized examples and a PowerShell 7 resolver.
Use the resolver for both preview and deployment; do not duplicate shell
substitution logic in workflow YAML.

Cover address/subnet bindings, hub integration, tags, deployment lists and
feature flags. Reject conflicting inputs, unknown environments, malformed
values, unresolved required fields and missing governed-inference limits.
Exclude secrets from generated artifacts, summaries and logs.

**Exit:** fixtures demonstrate typed resolution, equivalent local/CI inputs,
missing-input failures and unchanged legacy parameter behavior.

### P2 - Add plan-first GitHub and platform bootstrap

Add a bootstrap script whose default is inspection/plan output. It must never
write merely because credentials are present. Implement execution behind
explicit operator selection and the repository's authorization rules.

The plan describes the exact GitHub repository/environments/protections,
federated identities and scopes, runner/network configuration, policy
assignments, budgets and hub-side operations it would create or reconcile.
Use supported GitHub/Azure APIs, not browser automation.

Read existing configuration before planning changes. Reuse compatible owned
resources; report conflicts and insufficient privileges explicitly. If an
organization-owned runner/network setting must be supplied by an administrator,
record that dependency and verify it before declaring bootstrap complete.

Complete reverse peering, DNS linking/resolution and approved egress as
platform-owned operations. Solve runner bootstrap before scheduling private
jobs; do not wait for a nonexistent runner to create itself.

**Exit:** mocked API tests prove plan mode makes no writes, reruns do not
duplicate resources, scopes are explicit, and incompatible protection/OIDC
configurations fail closed.

### P3 - Add optional APIM and governance

Implement the gateway with current supported AVM/resource contracts. For the
dev reference, establish private ingress and private backend connectivity;
disable public gateway access only after its private endpoint is established.
Keep production SKU/availability settings explicit.

Add Entra client authorization, backend managed identity, approved API/model
routes, token-rate/period quotas and a protected stop-new-requests control.
Implement the coverage and bypass requirements in section 4. Keep the optional
Foundry portal integration independently gated and disabled by default.

Add a small environment-scoped Azure Policy baseline and whole-environment
budgets/alerts. Assess existing resources before disruptive enforcement.
Use current built-ins where applicable; model deployment SKU restrictions need
the documented custom-policy pattern. Do not confuse allowed resource regions
with the processing residency of Global model deployments.

Exact model allow-lists must not accidentally allow an entire publisher or
unintended model-name prefixes. Verify the current definition and tenant
availability. The eligibility policy has conflicting GA documentation and
preview metadata; it is not required for the first baseline.

**Exit:** default-off compatibility, parameter/schema checks, generated policy
checks and deterministic gateway tests pass. No runtime-enforcement claim is
made until the approved live gate.

### P4 - Complete the private developer environment

Add a customer-owned completion stage from the selected release bundle.
Populate App Configuration and other required data-plane settings from actual
outputs. Do not temporarily enable public access to make initialization work.

Prepare the correct workspace, tools and dependencies. Keep developer code
outside the installer's disposable checkout; never delete or reset a dirty
worktree. Do not put credentials in repository URLs, manifests or transcripts.
The developer completes their own interactive SSO; do not reuse LocalSystem
authentication as the human identity.

Deploy the small text-inference starter from the selected image digest.
Use Entra authentication and managed identity; select the governed gateway
endpoint in the new profile. Health checks must not consume model tokens.
Do not add RAG ingestion, business data or agent tool actions to this package.

An infrastructure update must not reset an existing workload to its placeholder
image as normal promotion behavior. Carry the selected image into the relevant
infrastructure contract or preserve application ownership through a supported
pattern; do not rely on a later job repairing a placeholder reset. Establish
explicit ownership of the active image and runtime configuration between stages,
with a regression test for a second deployment.

**Exit:** deterministic completion tests cover retries, existing configuration,
partial failure, preservation of user work and required-tool failures. Required
steps cannot be downgraded to warnings followed by a ready status.

### P5 - Wire GitHub CI/CD and promotion

Extend the existing GitHub validation path rather than duplicating its checks.
Include relevant script, environment, sample, policy and workflow changes in
trigger coverage. Pin actions and release tools to verified versions/SHAs.
Keep PR checks credential-free.

Publish a trusted release bundle with reproducible infrastructure inputs and
the tested OCI image. Add manual CD selecting a known environment and a
specific trusted release run. Validate provenance before downloading or
executing deployment content with Azure access.

Use a reusable workflow and the shared resolver/completion scripts:

```text
Trusted CI release bundle
  -> selected environment preview with constrained identity
  -> recorded preview and resolved configuration hash
  -> protected deployment approval
  -> infrastructure deployment
  -> private configuration and application deployment
  -> readiness and enforcement evidence
  -> eligibility to promote that release to the next environment
```

Dev has no independent reviewer requirement in the default plan; test and prod
do. All CD remains opt-in. Preserve prior-environment success evidence for the
same release across workflow runs. A direct production selection cannot bypass
that evidence or the production approval.

**Exit:** workflow/static tests cover trusted source selection, no fork
privileges, protected environment mappings, preview/deploy consistency,
artifact digest preservation, promotion ordering and failure propagation.

### P6 - Document and perform the authorized live dev gate

Add operator instructions for bootstrap, configuration, queueing, approvals,
cost controls, credential/identity ownership and recovery. Update the README
and pipeline documentation to distinguish infrastructure completion from
developer readiness.

Stop after local evidence until the user explicitly approves the exact dev
scope and any GitHub-side actions. Then an authorized operations session can
execute the plan and the live acceptance matrix below.

**Exit:** either recorded live dev evidence, or an explicit local-complete,
live-validation-pending result. Do not label the latter fully provisioned.

### P7 - Prepare production promotion without premature provisioning

Require an approved production profile for identity/data isolation, model
availability and residency, capacity, backup/recovery, retention, availability
and approvers. Configure the protected path; do not deploy production to prove
that its queue button exists.

Review semantic-version and Portal/Terraform parity obligations when public
contracts change. Prepare any required public documentation updates, but do not
publish, tag or open companion PRs without specific approval.

**Exit:** a protected, documented promotion path with explicit production
requirements. This is not certification of a business application's production
readiness.

## 8. Dependency order and expected evidence

Implement P0, then P1. P2 and P3 depend on P1. P4 needs the P1/P3 contracts.
P5 consumes P0-P4. P6 follows the complete local path and explicit remote
authorization. P7 can be prepared locally, but remote promotion remains gated.

| Gate | Required evidence | Must not be mistaken for |
| --- | --- | --- |
| Local compatibility | Existing parameter paths and new opt-in profiles compile; targeted tests exercise standard/private and disabled/enabled features | Proof Azure networking or permissions work |
| Bootstrap safety | Plan-only makes no writes; scoped reconciliation is idempotent; existing approvals/settings survive | Authority to execute the generated plan |
| Private connectivity | Workspace and runner resolve/reach intended private endpoints; public bypass is rejected | A successful ARM deployment |
| Identity | Human, workload, preview and deploy identities have their intended distinct access; invalid caller tokens fail | LocalSystem or deployment-SP access proving human access |
| Application | A correlated model-backed request works; health makes no model calls; a second deploy preserves the active workload | A placeholder container returning HTTP 200 |
| APIM enforcement | Configured rate/quota rejection, valid caller isolation, spoofed counter metadata rejection, stop-new-requests and direct-backend rejection | A zero-overshoot financial cap |
| Metering coverage | Streaming/concurrency behavior and supported API coverage are recorded; excluded routes are disabled or explicitly outside the governed scope | Assuming every Foundry/agent billable activity uses one route |
| Cost operations | Correctly scoped budget/recipients exist; action-group routing is exercised; fixed costs and billing lag are documented | A simulated notification proving a real budget threshold was crossed |
| Promotion | Exact release/configuration identity, prior-environment success, preview and independent approval are evidenced | A manual dispatch form or YAML-only approval comment |
| Recovery | Known-good image/configuration rollback and non-destructive rerun work in approved dev | Permission to delete resources or disable security controls |

Use the repository's narrowest applicable commands after restoring missing
tests: `pwsh .\.github\scripts\Validate-CopilotAssets.ps1`,
`pwsh .\tests\scripts\Validate-CopilotAssets.Tests.ps1`,
`az bicep build --file main.bicep`, `az bicep lint --file main.bicep`,
`pwsh .\scripts\Measure-MainJsonSize.ps1`, and
`pwsh .\tests\scripts\Invoke-PreflightChecks.Tests.ps1`.
Include new focused tests and any separate platform entry-point compilation.

Azure-aware preflight, deployment What-If and live probes require the selected
scope and appropriate access. Provisioning, paid model calls, resource changes
and remote workflow runs require explicit approval. Run quota tests against
small, expressly approved test limits; do not exhaust a shared production quota.

## 9. Deployment inputs and accountable owners

These are deployment prerequisites, not blockers to local implementation.
The bootstrap must require them before the relevant remote operation and name
missing values explicitly. No real values were supplied in this conversation.

| Accountable owner | Required input or authorization |
| --- | --- |
| Brother GitHub administrator | Target organization/repository and cloud offering, repository visibility, Actions entitlement, reviewer identities, protected refs and approved runner group/network configuration |
| Brother Azure platform administrator | Tenant/subscription/resource-group scopes, hub ownership, address allocation, private DNS model, permitted egress, identity/role-assignment and policy authority |
| Brother development owner | Developer identity/group, approved repository access and workstation/toolchain requirements |
| Brother budget owner | Currency, environment budget, inference allowance/token limits, permitted models/types, alert recipients and response owner |
| Brother production owner | Production availability/data/residency/recovery requirements, approval ownership and promotion authorization |

Assign named people when those inputs are supplied. Do not invent names,
budget amounts, dates, CIDRs or subscription IDs. For missing entitlements or
incompatible infrastructure, finish local work and report the exact blocked
remote gate rather than weakening the design.

## 10. Rollout, rollback and review

Roll out only to a newly approved dev scope first. Compare the plan with actual
resources, establish private networking and governance, run completion, then
exercise the acceptance gates and a safe rerun. Enable enforced policies on
broader existing scopes only after compatibility assessment and authorization.

Rollback application releases to a recorded known-good digest and compatible
configuration. Reconcile gateway/policy changes from their recorded prior
configuration; do not simply remove all controls. Preserve databases and user
workspaces. Feature flags are not an automatic cleanup mechanism; inspect
What-If and obtain approval for any resource deletion or access revocation.

Review this decision when GitHub changes OIDC/protection/runner contracts,
APIM/Foundry integration availability changes, new API modalities or gateways
are introduced, measured cost differs materially from the budget model, or
production requirements exceed the dev reference topology.

This planning change requires no version bump and changes no shipped behavior.
Implementation must update directly affected documentation and assess release
impact from the actual diff.

## 11. Primary evidence

Primary pages were opened on 2026-09-16. Reopen the relevant contract before
implementation when its content or availability may have changed.

| Source | Verified point |
| --- | --- |
| [GitHub OIDC in Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure) and [OIDC reference](https://docs.github.com/en/actions/reference/security/oidc) | Short-lived Azure authentication, trust conditions and the immutable-subject rollout |
| [GitHub deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments) | Environment approval/protection semantics and private-repository licensing restrictions |
| [GitHub Azure private networking](https://docs.github.com/en/organizations/managing-organization-settings/about-azure-private-networking-for-github-hosted-runners-in-your-organization) | Larger-runner VNet connectivity, region and network requirements |
| [APIM token-limit policy](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy), updated 2026-06-26 | Token scopes/windows, 429/403, supported APIs, gateway-local counters and estimation/concurrency limitations |
| [APIM authentication for AI APIs](https://learn.microsoft.com/en-us/azure/api-management/api-management-authenticate-authorize-ai-apis), updated 2026-06-25 | Client Entra authorization and backend managed identity |
| [APIM virtual networking](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts), updated 2026-06-26 | Standard v2 private inbound plus VNet outbound design and public-access ordering |
| [Foundry token enforcement](https://learn.microsoft.com/en-us/azure/foundry/control-plane/how-to-enforce-limits-models), updated 2026-08-13 | Project-scoped model-token enforcement through gateway integration |
| [APIM AI gateway capabilities](https://learn.microsoft.com/en-us/azure/api-management/genai-gateway-capabilities), updated 2026-06-25 | Foundry-integrated experience is documented as preview; ordinary APIM capabilities are separate |
| [Foundry costs](https://learn.microsoft.com/en-us/azure/foundry/concepts/manage-costs), updated 2026-09-10, and [Azure budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets), updated 2025-09-26 | Estimates versus billed costs, no Azure OpenAI hard budget limit, and budgets not stopping resources |
| [Foundry deployment policies](https://learn.microsoft.com/en-us/azure/foundry/how-to/model-deployment-policy), updated 2026-08-18 | Deployment-time model governance and exact allow-list considerations |
| [Model deployment types](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/deployment-types) | Deployment-type policy pattern and Global deployment residency distinction |

## 12. Future-session kickoff

Paste the following into a fresh session in this repository:

````text
Implement the local, additive changes in:
C:\Users\johnhain\Documents\brother\brother-bicep-ptn-aiml-landing-zone\docs\adr\2026-09-16-github-dev-environment-plan.md

Read the complete plan and AGENTS.md first. Use the applicable repository
instructions and coding-rigor, engineering-principles, architecture-decision,
iac-validation and documentation-consistency skills. Follow the plan's work
packages and acceptance criteria, not the obsolete assumption that Azure
DevOps is the new CI/CD target.

Preserve existing Bicep defaults, parameter/output/manifest contracts, private
networking, the existing deployment entry points and Azure DevOps assets.
Build the GitHub-first path, optional APIM/governance controls, private
completion, starter workload and local evidence. APIM governs supported
inference traffic; do not claim an invoice-dollar cap or all-Azure shutdown.

This instruction permits local implementation only. Do not push, create PRs,
change GitHub settings, dispatch workflows, assign Azure permissions, provision,
delete resources, publish releases or make paid model calls. Stop before those
actions and report the exact approval and deployment inputs required.

Verify the local result and report changed contracts, commands/results,
documentation, rollback and residual risk. A locally passing implementation
is not a fully provisioned dev environment until the separately authorized
live readiness gates in the plan have been observed.
````
