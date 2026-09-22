# Changelog

## Unreleased

### Added

- Opt-in GitHub development-environment profiles, typed parameter resolution
  and plan-first scoped platform bootstrap.
- Optional private APIM text-Responses gateway with Entra caller authorization,
  managed-identity backend access, per-caller/model token limits, a stop control
  and an environment-scoped policy/budget boundary.
- Customer-owned private completion and non-destructive workspace preparation,
  plus a digest-pinned authenticated text-inference starter.
- Trusted CI release bundles, constrained previews, protected manual deployment
  and cross-run live-evidence promotion gates.
- Deterministic profile, ownership, archive, image, completion and workflow
  checks; restored the existing workflow's pinned upstream regression fixtures.
- `platform/api-management/` — a per-subscription API Management gateway
  template (classic VNet injection, Internal mode) plus its undelegated
  injection subnet and rule-carrying NSG, so the gateway is deployed once per
  subscription and shared by every landing zone in it.
- `modules/networking/api-management-injection-nsg.bicep` — the single
  authoritative NSG rule set for an API Management injection subnet, shared by
  both gateway creation paths so they cannot drift.
- `tests/contracts/Test-ApiManagementClassicInjectionContract.ps1` — asserts
  Internal mode, an undelegated subnet, the required NSG rules, the absence of
  any private endpoint, and the classic-tier-only SKU contract.

### Changed

- **API Management now uses classic VNet injection in Internal mode** on the
  Developer (sandbox/dev/test) and Premium (production) tiers, replacing the
  earlier Standard v2 / Premium v2 outbound-integration plus inbound
  private-endpoint shape. One topology now serves every subscription, so
  non-production genuinely rehearses production. The gateway's injection subnet
  is **undelegated** and carries an explicit NSG rule set, and the gateway
  declares no private endpoint. `publicNetworkAccess` stays `Enabled` because
  Azure permits `Disabled` only on instances holding a private endpoint, which
  an injected instance cannot have; inbound privacy comes from Internal mode,
  where no API Management endpoint is registered on public DNS. See
  `docs/adr/2026-09-22-apim-classic-vnet-injection.md`.
- **Gateway profile contract:** `gateway.sku` accepts `Developer | Premium`
  instead of `StandardV2 | PremiumV2`, and `gateway.privateDnsZoneResourceId`
  must now be the service-scoped `<gateway-name>.azure-api.net` zone rather than
  `privatelink.azure-api.net`. A zone for the bare apex `azure-api.net` is
  rejected outright.
- **Gateway deployment states** are now `Absent | InterruptedProvisioning |
  Injected`, and `Complete-GatewayPrivateAccess` is replaced by
  `Complete-GatewayActivation`, which verifies the injected private topology and
  reconciles the owned stop control instead of performing a public-disable
  transition that this topology cannot reach.
- The governed inference route is
  `/inference/<workloadKey>/v1/responses`. Deployment order is **gateway once
  per subscription, then landing zone many times**.
- `modules/networking/subnets.bicep` now forwards every requested service
  endpoint rather than only the first.
- The size-gate build writes semantically identical compact UTF-8 JSON before
  measuring the actual deployment artifact. Existing thresholds and read-only
  `-SkipBuild` behavior are retained.
- Explicit per-app image/registry/managed-identity settings survive subsequent
  infrastructure deployments. Consumers omitting them retain the existing
  placeholder behavior.
- Foundry private endpoints use the shared PE-subnet binding, including an
  explicitly configured subnet name instead of a hardcoded legacy name.

### Compatibility and release status

Existing Bicep defaults, parameter bindings, output names, `azure.yaml`,
`Deploy-AilzIntegrated.ps1`, `install.ps1`, manifest pins and Azure DevOps assets
are preserved. Gateway/developer behavior is off by default.

This is an additive minor-release candidate, not a published release.
`manifest.json` remains pinned to `v2.6.1`; no new version, tag or GitHub Release
has been assigned. Portal/Terraform parity and the public documentation companion
remain required before a coordinated release. See
[the operator runbook](docs/github-development.md).
