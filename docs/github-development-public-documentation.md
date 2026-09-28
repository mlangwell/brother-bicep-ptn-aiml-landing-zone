# Prepared public documentation companion

**Draft only; not published or represented as a shipped upstream feature.**
Target the maintained MkDocs source on `Azure/AI-Landing-Zones` `main`, never
generated `gh-pages`. A maintainer must approve the exact companion change and
coordinate its release/Portal/Terraform parity.

## Proposed Bicep deployment-guide addition

The Bicep accelerator can expose an optional GitHub-first development path
without replacing `azd`, the integrated PowerShell wrapper or Azure DevOps.
Its environment profiles carry typed infrastructure/model/network inputs.
Credential-free CI produces an immutable infrastructure/application bundle;
manual delivery uses constrained OIDC preview and separately protected private
deployment jobs. Test and production consume recorded preceding-environment
live evidence for that same release.

Private APIM is optional and disabled for existing consumers. It authenticates
Entra callers, uses managed identity to the model backend, and applies explicit
token limits to its supported text Responses route. It is not an invoice-dollar
cap, a multi-gateway aggregate counter or an all-Azure shutdown control.
Azure Policy controls configuration; Cost Management budgets notify.

Infrastructure deployment and developer readiness are different outcomes.
Customer-owned completion populates private runtime configuration and verifies
the selected image; developers use a separate editable workspace and their own
SSO. Human access, model inference, gateway enforcement, costs, recovery and
promotion must be observed in an explicitly approved environment.

Link the versioned operator runbook and starter contract only after the
coordinated release exists. Document actual GitHub entitlement, immutable OIDC
subjects and private-runner prerequisites; do not make a customer repository
public or enable public Azure endpoints as a workaround.

## Companion review scope

Update the Bicep deployment navigation, GitHub delivery guide, optional gateway
parameter/output reference, private-completion guidance and the existing Azure
DevOps page's compatibility note. Preserve the Azure DevOps guide and deployment
entry points. Link the approved semantic release and parity review when those
exist; no companion PR or release URL is invented here.
