# Local implementation evidence

**LOCAL READY - local implementation and independent delta review passed on
2026-09-17. Live deployment gates remain unverified.**

The source plan is
[the 2026-09-16 GitHub development environment plan](adr/2026-09-16-github-dev-environment-plan.md).
Local work started from `98505e685de460e385c15bcb6c1e0a47e33ffdf0` on
`main`, with the user's untracked planning document preserved. Implementation
is on `feature/github-dev-environment`.

## Evidence gathered

| Scope | Observed local result |
| --- | --- |
| Existing CI baseline | Missing tests restored from Microsoft `v2.6.1`, commit `64195c01b70974fa7256c2f54a0035fb06804139`; original validator, preflight and resource checks are executable. |
| Hosted-agent snapshot | The original unrelated resource hashes remain unchanged. Six named additive graph mutations are explicitly associated with focused GitHub environment contracts; the fixture was not wholesale regenerated. |
| Legacy compatibility | Existing parameter defaults/bindings, outputs, installer, manifest, azd entry point, wrapper and Azure DevOps assets are guarded. New gateway resources default off and legacy base subnet definitions are unchanged. |
| Template payload | The freshly built JSON is compacted without changing values or numeric precision. Existing size thresholds and `-SkipBuild` semantics remain enforced. |
| Starter | Actual loopback HTTP/RSA/JWKS/managed-identity-transport tests run with external sockets blocked; no model calls. |
| Artifact handling | Source/run/ref/digest checks, archive traversal/link rejection, preview hash invalidation, promotion ordering and real local ORAS OCI-to-OCI digest preservation exercised. |
| Private completion | Mocked persistence, ETags, retries, ownership, workspace preservation and active-image checks exercised; the final service/PE ownership contract is aligned across packages. |
| Workflows | Pinned actionlint and deterministic workflow checks cover credential-free CI, private-runner selection, OIDC separation, verification before Azure login and manual protected deployment. |

## Reproducible local entry points

Use the pinned tools recorded in `scripts/github/release-tools.json`,
`powershell-yaml` 0.4.12, PSScriptAnalyzer 1.25.0 and a CPython 3.13 venv installed
from `samples/developer-smoke/requirements-test.lock`.

```powershell
$env:AILZ_TEST_PYTHON = "<locked-venv-python-executable>"
npm test
npm run lint
```

`npm test` includes the original baseline suites, new deterministic contracts,
Bicep compilation/lint/size and the sample's executed-test-count gate.
`npm run lint` records all PowerShell diagnostics and checks workflow semantics;
warnings are retained in its report rather than described as absent.

## Observed local results

| Command / suite | Result |
| --- | --- |
| `npm test` | Passed the existing validator/preflight/resource suites, all 13 additive PowerShell suites and the starter tests. |
| `npm run lint` | PSScriptAnalyzer 1.25.0: 42 PowerShell files, 0 errors, 261 retained warnings, including governance/size helpers; actionlint 1.7.12: all 5 workflows passed. |
| `Compatibility.Tests.ps1` | 1,168 assertions passed, including compiled resolver bindings and unchanged legacy contracts. |
| `Bootstrap.Tests.ps1` | 149 mocked assertions passed, including active-runner revalidation, actual Bicep gateway routes and pre-main external-registry import grants. |
| `Environment.Tests.ps1` | 168 tests passed. |
| `Gateway.Tests.ps1` / `Governance.Tests.ps1` | 173 / 176 assertions passed. |
| `Completion.Tests.ps1` / `LiveEvidence.Tests.ps1` | 22 / 94 cases passed. |
| `Delivery.Tests.ps1` / `Deployment.Tests.ps1` | 39 / 17 assertions passed. |
| `Oci.Tests.ps1` / `CompactTemplate.Tests.ps1` | 18 / 7 assertions passed, including actual builder-version/profile compatibility, real local ORAS transfer and exact JSON-value preservation. |
| `DeploymentEntrypoint.Tests.ps1` | 6 assertions passed through the actual Preview -> disk -> Deploy -> Complete entry point, with only external observations/effects substituted; tampering cannot reach a mutation. |
| `Workflows.Tests.ps1` | 67 assertions passed. |
| `Test-Smoke.ps1 -PythonExecutable <locked-venv>` | 85 executed pytest tests, 0 skipped; CPython 3.13.14; external sockets blocked. |
| Locked-venv `pip check` and Python `ruff check` | Passed. |
| Bicep build/lint | Passed using pinned 0.42.1; six pre-existing diagnostics remain. |
| `Measure-MainJsonSize.ps1 -SkipBuild` after tests | Passed: 3,044,963-byte actual compact artifact, with unchanged size thresholds. |
| `git diff --check` | Passed; preserved deployment entry points and Azure DevOps files have no diff. |

PowerShell analysis initially exposed a PSScriptAnalyzer command-metadata
initialization failure under captured npm execution. The linter now initializes
`Export-ModuleMember` parameter metadata before its parallel rules and reports
analyzer exceptions as failures. The exact captured npm lint command was rerun
successfully; no rule or finding was silently removed.

The required mechanical wrapper was run with its default baseline and exited
successfully. Its language detector does not discover this repository's
PowerShell/Bicep npm lint entry point or nested Python project. Consequently its
lint field is **NOT RUN**, not a lint pass; the explicit pinned PowerShell,
actionlint and Python lint results above supply that missing coverage.

```text
=== GATE EVIDENCE ===
repo   : brother-bicep-ptn-aiml-landing-zone
base   : origin/main
lint   : NOT RUN
tests  : green
note   : NO LINTER RAN - this is not a pass

MECHANICAL GATE: PASS
```

The first independent review reproduced five integration defects despite the
initial green suites: release-version prefix compatibility, persisted-preview
scalar types, active private-runner validation, gateway root/route comparison
and pre-import external-registry permissions. All five were corrected with
real producer/consumer and state-transition regressions. The independent
delta-only re-review checked the corrections against the preserved first-review
snapshot and original plan, confirmed all five fixes and the documentation
corrections, and reported no new blocking delta regression.

Final verdict: **JUDGE VERDICT: PASS - LOCAL READY**. The review independently
exercised persisted-record attacks, active-runner transitions, actual gateway
route shapes and pre-import grant ordering. All repository files remained
unchanged during the review; this evidence-page closeout is documentation only.

## Not executed

- No pushes, PRs, GitHub environment/settings changes, workflow dispatches,
  releases or Azure resource/permission changes.
- No Azure-aware preflight, What-If, private endpoint/DNS/identity probes,
  policy/budget deployment or notification test.
- No paid model requests, native quota exhaustion or stop-control tests.
- No human onboarding or production provisioning.
- No local Docker image build/run: the Docker client is available, but its
  Linux engine is stopped. No service or OS setting was changed to bypass that
  prerequisite. The trusted CI packaged-image test remains a separate gate.

The [operator runbook](github-development.md) lists the exact responsible owners,
inputs, approvals, limitations and recovery requirements for live validation.
