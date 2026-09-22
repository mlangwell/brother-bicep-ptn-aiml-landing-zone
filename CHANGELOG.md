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

### Changed

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
