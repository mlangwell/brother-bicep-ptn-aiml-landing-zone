# Governed developer smoke service

A small, stateless **text-inference** example, not RAG or a business application.
The application authenticates the caller with Entra, then uses only
`ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)` to call the configured
APIM Responses route. There is no direct Foundry fallback, subscription/API key,
developer-credential chain, conversation store, ingestion or tool execution.

## HTTP contract

| Route | Behavior |
| --- | --- |
| `GET /health` | Reports `{service:"developer-smoke",version:<source SHA>,status:"ok"}`. No model, credential, metadata/JWKS, DNS or other network call, including startup. An unbuilt source checkout reports `version:"unbuilt"`. |
| `GET /ready` | Validates local settings and the immutable build version, without external calls. Returns 503 for missing/invalid configuration. This does not prove identity, network, gateway or model readiness. |
| `POST /infer` | Requires one Entra bearer token and UTF-8 JSON exactly `{"input":"text"}`. Returns the supported nonstreaming Responses JSON and request correlation. |

The caller cannot select a model, token cap, project, identity, tools, modalities,
streaming/background mode, previous response or conversation. Unsupported
properties/identity headers, malformed/duplicate JSON keys, empty/nontext input
and non-UTF-8 input are rejected. The sample's local request-size bound is 65,536
bytes, and its response-size bound is 2 MiB; these are implementation choices,
not vendor recommendations. The configured output-token cap is always explicit.

JWT validation fixes the algorithm to RS256 and fetches only tenant-scoped
Microsoft metadata with an allow-listed Microsoft JWKS URL. It verifies the
signature, token-version-specific issuer, exact tenant/audience, expiry,
not-before and object ID. A signed allowed object ID or signed group membership
authorizes the caller. Group overage does not grant access and does not trigger
a Graph lookup. Configure the API audience to **match the emitted access-token
`aud` exactly**, including the distinction between an App ID URI and an
application/client ID. Both Entra v1 and v2 token issuers are supported.
Audience strings are not silently trimmed or case-normalized. The gateway scope
is the exact audience followed by `/.default`, preserving a resource URI's
significant trailing slash.

Gateway routing requires an HTTPS `<name>.azure-api.net` endpoint with the exact
`/inference/v1/responses` path and no credentials/query/fragment. Inference
resolves the gateway to private addresses and pins the TCP connection to a
validated address, retaining its hostname for TLS/SNI. Redirects and environment
HTTP proxies are disabled. An invalid/missing/public gateway fails closed before
obtaining the workload token. Completion additionally checks the addresses
against the **approved profile's CIDRs**, not merely an RFC1918 classification.

The upstream body contains only the input, configured model,
`max_output_tokens`, `stream:false` and `store:false`. Billable POSTs are never
automatically retried. Gateway 403/429 and other error status codes, `Retry-After`
and safe gateway request IDs are preserved; raw error bodies are not exposed.
Failed, malformed or unsupported success-shaped upstream responses become 502,
not empty successful answers. Legitimate `incomplete` Responses remain explicitly
incomplete; refusal text remains a refusal rather than a fabricated answer.

Use `x-correlation-id` with a UUID, or let the service generate one. The service
forwards it and `x-ms-client-request-id` to APIM. The normal JSON log contains only
correlation, validated identity, configured model, input/output/total tokens and
HTTP status. Prompts, completions, authorization, raw requests/responses and
credentials are not logged. Access/SDK HTTP logs are disabled by the entry point.

## Runtime environment

Bicep owns these settings and supplies the same shaped values to the Container
App and App Configuration. The service does not fetch App Configuration per call.

| Variable | Required meaning |
| --- | --- |
| `AZURE_TENANT_ID` | Approved tenant UUID |
| `AZURE_CLIENT_ID` | External workload user-assigned managed identity client UUID |
| `INFERENCE_ACCESS_MODE` | Exactly `gateway` |
| `INFERENCE_GATEWAY_ENDPOINT` | Full private APIM Responses URL |
| `INFERENCE_GATEWAY_AUDIENCE` | Gateway application audience; the credential requests its `/.default` scope |
| `SMOKE_API_AUDIENCE` | Exact incoming access-token audience |
| `SMOKE_ALLOWED_OBJECT_IDS` | JSON array of allowed caller object UUIDs |
| `SMOKE_ALLOWED_GROUP_IDS` | JSON array of allowed group UUIDs; at least one of the two allowlists must be nonempty |
| `SMOKE_MODEL_DEPLOYMENT` | Configured deployment name; never caller supplied |
| `SMOKE_MAX_OUTPUT_TOKENS` | Positive integer output cap, with no financial-cap claim |
| `APP_CONFIG_ENDPOINT` | HTTPS App Configuration endpoint |

The image build requires `--build-arg SOURCE_COMMIT=<40-character-release-SHA>`.
It records that value in a read-only `BUILD_VERSION` file, not a mutable runtime
version environment variable. P5 builds once and imports the same immutable OCI
image into the pre-created private ACR before infrastructure deployment.
Infrastructure owns the image on the **first and every subsequent deployment**.
The P5 OCI builder must select a single `linux/amd64` image manifest with
`--provenance=false --sbom=false`. The multi-architecture base digest is resolved
to that target by the builder; the release artifact must not become a
multi-platform or attestation index. Artifact copy/digest verification belongs
to P5, not this test entry point.

## Local checks: no Azure or paid inference

**CI Python pin: `3.13.14`**, recorded in `.python-version`. This matches the
locally exercised interpreter. The official
[setup-python release manifest](https://github.com/actions/python-versions/blob/main/versions-manifest.json)
lists the stable
[3.13.14 release](https://github.com/actions/python-versions/releases/tag/3.13.14-27320626148)
with Linux x64 artifacts, including Ubuntu 24.04 (checked 2026-09-16).
CPython 3.13 is the supported family; the separately pinned container base is
3.13.15 and still requires the trusted CI OCI build/run checks.

The exact **test dependency lock** is `requirements-test.lock`; it includes
the runtime `requirements.lock`. Use **pytest**, not unittest discovery.
Use a separate venv; a session directory or `$env:RUNNER_TEMP` is suitable.
The following PowerShell 7 commands work on Windows and Linux after selecting
the pinned Python interpreter:

```powershell
$venv = Join-Path ([IO.Path]::GetTempPath()) ('developer-smoke-venv-' + [guid]::NewGuid().ToString('N'))
python -m venv $venv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$bin = if ($IsWindows) { 'Scripts' } else { 'bin' }
$executable = if ($IsWindows) { 'python.exe' } else { 'python' }
$py = Join-Path (Join-Path $venv $bin) $executable
& $py -m pip install --require-virtualenv --require-hashes --only-binary=:all: -r .\samples\developer-smoke\requirements-test.lock
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
pwsh -NoProfile -File .\samples\developer-smoke\Test-Smoke.ps1 -PythonExecutable $py
```

Once the locked venv exists, the last line is the **single test command**.
`Test-Smoke.ps1` installs nothing, works independently of the caller's current
directory, invokes pytest with the sample's explicit configuration/test
directory, propagates pytest's nonzero exit codes, and requires a JUnit report
with nonzero executed tests, not merely collected or skipped tests. It removes
its temporary report on success and failure. The success line reports the
observed executed count and interpreter version; a zero-test run cannot succeed.

The equivalent underlying test invocation is:

```powershell
& $py -m pytest -c .\samples\developer-smoke\pyproject.toml --strict-config --strict-markers .\samples\developer-smoke\tests -q
```

The separate completion/workspace/gateway-adapter suite remains:

```powershell
pwsh -NoProfile -File .\tests\github\Completion.Tests.ps1
```

The Python tests start the actual service on an ephemeral loopback port and
inject fake JWKS, managed identity, DNS and gateway transports. An additional
test exercises the real `ManagedIdentityCredential` SDK against an injected
identity HTTP transport. A test-wide socket/DNS guard rejects external
networking. The tests still generate/sign/verify real RSA JWTs. There is no environment-enabled test-auth
bypass. Tests inspect the forwarded request and provider call counts, including
zero calls for health, invalid callers, unsupported input and unavailable
gateways. They do **not** establish live Entra/APIM/model behavior or answer
quality.

`requirements.in` and `requirements-test.in` pin direct dependencies. The lock
files also pin every transitive dependency with official PyPI wheel hashes;
installation disallows source builds and unhashed dependencies. Public package
metadata may show newer releases than the configured package mirror supports:
the checked-in lock is the reproducible source of truth, not a "latest" promise.
The Docker base uses the verified official Python image index digest. No OS
package installation or update is run during the image build; pip installs only
the hash-locked Python dependencies. Local OCI build/run verification is
unavailable while the Docker Desktop Linux engine is stopped. Trusted CI image
build verification remains pending; this script does not start services or
change OS settings.

## Completion and workspace entry points

These scripts default to **plan only**. A credential's presence never authorizes
an operation. `-Execute` is a future operator action requiring separate approval;
it is not part of the local test commands above.

```powershell
pwsh .\scripts\github\Complete-DeveloperEnvironment.ps1 -ProfilePath <profile.json> -DeploymentOutputsPath <actual-outputs.json> -EvidencePath <completion.json>
pwsh .\scripts\github\Prepare-DeveloperWorkspace.ps1 -ProfilePath <profile.json> -WorkspacePath <absolute-customer-workspace> -BootstrapCheckoutPath <absolute-disposable-checkout> -EvidencePath <workspace.json>
pwsh .\scripts\github\Invoke-LiveDevGate.ps1 -ProfilePath <profile.json> -DeploymentOutputsPath <actual-outputs.json>
```

Completion reads `DEVELOPER_COMPLETION` from an ARM deployment envelope, an
outputs object or its direct value. It verifies the profile/release/scope,
private App Configuration/PNA, P3 gateway verification, actual VNet CIDRs,
active healthy revision, immutable digest, workload identity, required deployed
settings, and this starter's health/readiness identity and source SHA. It never
calls `az containerapp update`, deploys an image, or creates a public exception.
The P3 integration calls `Get-GatewayDeploymentPlan` and
`Complete-GatewayActivation` **without `-Apply`**, requires
`VerifiedControlPlane` with `virtualNetworkType: 'Internal'` and no change, and
supplies a GET-only management transport. The gateway uses classic VNet
injection, so there is no private endpoint to approve and no public-access flag
to disable; the verified invariants are Internal mode, the approved injection
subnet, and the absence of any private endpoint connection. Authenticated
management reads retain server ETags for
P3's owned-entity observations. Backend public access and local-key
authentication must also be disabled.

Every supplied setting descriptor is consumed with its exact key/label/content
type, including optional existing runtime settings. The completion stage resolves
only declared App Insights credential descriptors through authenticated management
reads; values do not enter output evidence. App Configuration uses an Azure-login
Entra token and private pinned HTTPS. New keys use `If-None-Match:*`; changed owned
keys use their ETag. Unrelated keys/tags survive. Conflicting unowned/locked keys,
412 races, insufficient access and persistence mismatches are fatal. Only
429/5xx are retried, within a bounded retry budget. Partial failures are failures;
reruns reconcile remaining settings without deleting or rolling back other data.

Workspace preparation requires an explicit immutable workspace SHA and HTTPS
repository URL. It rejects the disposable checkout or paths overlapping it,
including symlink/junction aliases. Existing worktrees are inspected without
fetch/reset/clean/checkout/branch changes and require a manual decision if dirty
or mismatched. Only an absent workspace is cloned and checked out at the approved
SHA. Required tools are Git, PowerShell 7, Python 3.13, Azure CLI and azd.
Dependencies go into that workspace's venv using the pinned lock.
LocalSystem and pipeline-SP authentication cannot establish a human workspace;
the developer must perform their own interactive SSO. The scripts never run
`az login`. Prepared workspace/runner configuration and **human ready** are
separate outcomes.

## Live gate: deliberately incomplete until observed

Paid probes are disabled unless `-ExecutePaidProbes` is explicitly supplied with
`-ApprovedEnvironment`, `-ApprovedSourceSha`, positive `-MaxRequests` and
`-MaxTotalTokens`, `-ReleaseFingerprint` and a positive `-WorkflowRunId`.
No numerical budget default or currency-cap recommendation is supplied.
`-IdentityContext human|runner` determines which available context is checked.
The current human probe set performs four inference-route attempts: missing
bearer, invalid bearer, one positive application request whose text must be
`READY`, and one negative direct-backend attempt. Runner context instead
requires the valid runner token to be rejected by the developer API with 403;
it cannot claim the separately authorized developer's positive inference.
The direct-backend attempt can cost tokens if bypass protection is
broken, so the preflight reserves for both potentially successful requests.
The UTF-8-byte input reservation is conservative bookkeeping, not model billing
or a distributed/in-flight token reservation system.

Evidence contains `schemaVersion`, `environment`, `release`, `configurationHash`,
`releaseFingerprint`, `workflowRunId`, `observedAt`, `mode`, `checks`, `probes`,
`pending` and `promotionEligible`. `checks` matches the P5 gate names:
`privateConnectivity`, `identityIsolation`, `applicationInference`,
`gatewayEnforcement`, `meteringCoverage`, `costOperations`, `promotionIntegrity`,
`recovery`, `developerWorkspace`. `probes` records actual correlations/statuses
and token totals, never request/completion text or bearer tokens.
Every required check has a nonempty evidence description, including an explicit
explanation when pending. Plan and offline-test records have no live
`observedAt` timestamp and no passed required-live checks. `-EvidencePath` is
accepted only after actual authorized live probes have been observed; a plan
prints to stdout and cannot create or replace an observed-evidence file.

This entry point **always leaves `promotionEligible:false`**. It cannot pretend
that health or its single-context observations establish the full plan:
human/workload/runner direct-backend denial, native APIM rate/period rejection,
stop-new-requests, spoofed metadata/caller separation, concurrency/in-flight
behavior, notifications, protected release promotion, developer onboarding and
rollback require separately approved controls/contexts and owned observations.
Streaming and nontext routes are explicitly excluded by the starter contract,
not claimed as metered. Arbitrary operator booleans or evidence files are not
accepted as proof.

## Answer-quality scope and sources

Question-set `text-smoke-v1` uses the UTF-8 synthetic greeting and the prospective
live instruction "Reply with the word READY." The observed boundary is text input
-> exact fake gateway payload -> fake Responses JSON -> delivered HTTP JSON.
Extraction/chunks/index/retrieval/citations are **not applicable**: this is not
RAG. Transport preservation and authorization/refusal behavior are tested;
generation correctness/completeness, attribution, groundedness and live-model
refusal quality remain **unassessed**. A sufficient-context model control is
**not run** because paid calls are not authorized. No fake response is a model
quality verdict. `quality-scope.json` records those distinctions.

Primary contracts opened for this implementation on 2026-09-16:

- [Entra access-token validation](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens#validate-tokens)
- [ManagedIdentityCredential](https://learn.microsoft.com/en-us/python/api/azure-identity/azure.identity.managedidentitycredential?view=azure-python)
- [Responses REST contract](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses)
- [App Configuration conditional key writes](https://learn.microsoft.com/en-us/azure/azure-app-configuration/rest-api-key-value)
- [HTTPX pinned-address TLS/SNI extension](https://www.python-httpx.org/advanced/extensions/#sni_hostname)
- [Official Python image definition](https://github.com/docker-library/official-images/blob/master/library/python)
