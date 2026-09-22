# Pipelines

This folder holds the CI/CD pipeline assets for deploying the AI Landing Zone.
Azure DevOps pipelines, templates, and shared variables live under
`azuredevops/`.

For setup and usage (service connections, the `ailz-secrets` variable group,
environments and approval gates, and how to run the CI and CD pipelines), see the
official guide:

- [Deploy with Azure DevOps](https://azure.github.io/AI-Landing-Zones/bicep/deploy-with-azure-devops/)

That page is the source of truth. The files in this folder are the assets it
references.

## Optional GitHub delivery

The additive GitHub path is documented in
[GitHub development environments](../docs/github-development.md). Its
credential-free validation extends `bicep-validate.yml`; environment delivery is
manual and uses separate OIDC preview/deployment identities, an approved private
runner group, immutable release/configuration inputs and protected environments.
Azure DevOps files under `azuredevops/` are not replaced or modified.

A successful infrastructure job is not proof of human access, model inference,
gateway enforcement or production readiness. Promotion also requires recorded
live evidence for the same release in the preceding environment.
