#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach ($name in @('Environment', 'Delivery', 'Deployment', 'Oci', 'Gateway', 'Completion', 'Bootstrap')) {
    Import-Module (Join-Path $root "scripts\github\$name.psm1")
}
Import-Module (Join-Path $root 'platform\policy\Governance.psm1')

function ConvertTo-OfflineShape($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $Value.Keys) { $copy[$key] = ConvertTo-OfflineShape $Value[$key] }
        return ,$copy
    }
    if ($Value -is [Collections.IList]) { return ,@($Value | ForEach-Object { ConvertTo-OfflineShape $_ }) }
    if ($Value -is [string]) {
        return ($Value -replace 'synthetic', 'offline' -replace 'never-deploy', 'fixture' -replace 'example\.invalid', 'example.test').
            Replace('00000000-0000-4000-8000-', '10000000-0000-4000-8000-')
    }
    return $Value
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
$assertions = 0
$fixture = Join-Path ([IO.Path]::GetTempPath()) "ailz-phase-tests-$([guid]::NewGuid().ToString('N'))"
$stubDirectory = Join-Path $fixture 'bundle\payload\scripts'
[IO.Directory]::CreateDirectory($stubDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $stubDirectory 'Invoke-PreflightChecks.ps1'), 'exit 0')
[IO.File]::WriteAllText((Join-Path $fixture 'bundle\payload\main.json'), '{"resources":[]}')
$environmentProfile = ConvertTo-OfflineShape (& (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1'))
$environmentProfile.synthetic = $false
$environmentProfile.parameters.aiFoundryAccountName = 'offline-foundry'
$environmentProfile.release.infrastructureVersion = 'v2.6.1'
$environmentProfile.release.workflow = '.github/workflows/bicep-validate.yml'
$environmentProfile.release.artifactName = "ailz-release-$($environmentProfile.release.runId)-$($environmentProfile.release.runAttempt)"
$resolution = Resolve-EnvironmentProfile -Profile $environmentProfile
$platform = @{ schemaVersion=1; owner='offline-fixture'; governance=@{billingCurrency='USD'} }
$scope = "/subscriptions/$($environmentProfile.azure.subscriptionId)/resourceGroups/$($environmentProfile.azure.resourceGroup)"
$fingerprint = 'a' * 64
$output = @{
    schemaVersion=1; environment=$environmentProfile.environment
    tenantId=$environmentProfile.azure.tenantId; subscriptionId=$environmentProfile.azure.subscriptionId
    resourceGroup=$environmentProfile.azure.resourceGroup; release=$environmentProfile.release
    appConfiguration=@{endpoint='https://offline.azconfig.io';resourceId="$scope/providers/Microsoft.AppConfiguration/configurationStores/offline";settings=@()}
    applications=@(); workspace=@{repository=$environmentProfile.application.workspaceRepository;ref=$environmentProfile.application.workspaceRef}
    registryResourceId=$environmentProfile.application.registryResourceId; vnetResourceId="$scope/providers/Microsoft.Network/virtualNetworks/offline"
    gateway=@{
        accessMode='gateway'; resourceId="$scope/providers/Microsoft.ApiManagement/service/$($environmentProfile.gateway.name)"
        endpoint="https://$($environmentProfile.gateway.name).azure-api.net/inference/v1/responses"
        audience=$environmentProfile.gateway.audience
        backendResourceId="$scope/providers/Microsoft.CognitiveServices/accounts/offline-foundry"
        backendEndpoint='https://offline-foundry.openai.azure.com/'
    }
}
$context = @{
    phase='Preview'; imports=0; deployments=0; completions=0; gatewayCompletions=0; paidProbes=0
    profile=$environmentProfile; fingerprint=$fingerprint; output=$output
    state=@{gatewayExists=$false;resourceId=$output.gateway.resourceId;publicNetworkAccess='';privateEndpointIds=@()}
}
$selection = @{
    environment=$environmentProfile.environment; profileHash=Get-CanonicalHash $environmentProfile
    platformHash=Get-CanonicalHash $platform; bundleFingerprint=$fingerprint
}
Write-JsonFile (Join-Path $fixture 'profile.json') $environmentProfile
Write-JsonFile (Join-Path $fixture 'platform.json') $platform
Write-JsonFile (Join-Path $fixture 'selected.json') $selection

# Only external observations/effects are substituted. The actual phase script,
# resolver, serialized records, gateway plan and approval checks execute.
function Import-Module {
    param([string]$Name)
    if ((Split-Path $Name -Leaf) -cnotin @('Environment.psm1','Delivery.psm1','Deployment.psm1','Oci.psm1','Gateway.psm1','Completion.psm1','Bootstrap.psm1','Governance.psm1')) { throw 'Unexpected phase dependency.' }
}
function Invoke-GitHubJson([string]$Path) {
    $p = $context.profile
    if ($Path -ceq "repos/$($p.github.repository)") { return @{id=$p.github.repositoryId;full_name=$p.github.repository;owner=@{id=$p.github.ownerId}} }
    if ($Path.EndsWith('/actions/workflows/bicep-validate.yml')) { return @{id=10;path='.github/workflows/bicep-validate.yml'} }
    if ($Path -ceq "repos/$($p.github.repository)/actions/runs/$($p.release.runId)") {
        return @{id=$p.release.runId;run_attempt=$p.release.runAttempt;workflow_id=10;event='push';status='completed';conclusion='success';head_repository=@{id=$p.github.repositoryId;full_name=$p.github.repository};head_sha=$p.release.sourceSha;head_branch=$p.release.ref.Substring(11)}
    }
    throw 'Unmocked GitHub access is prohibited.'
}
function Test-ReleaseBundle { param($BundlePath,$ExpectedRelease,$ExpectedFingerprint) return @{fingerprint=$context.fingerprint} }
function Invoke-CheckedNative([string]$Command,[string[]]$Arguments) {
    if ($Command -cne 'az') { throw 'Unmocked native command is prohibited.' }
    $p = $context.profile
    if ($Arguments[0] -ceq 'account' -and $Arguments[1] -ceq 'show') {
        $identityPhase = if ($context.phase -ceq 'Preview') { 'preview' } else { 'deploy' }
        return ConvertTo-CanonicalJson @{id=$p.azure.subscriptionId;tenantId=$p.azure.tenantId;user=@{type='servicePrincipal';name=$p.identities[$identityPhase].clientId}}
    }
    if ($Arguments[0] -ceq 'version') { return '{"azure-cli":"2.76.0"}' }
    if ($Arguments[0] -ceq 'deployment' -and $Arguments[2] -ceq 'what-if') { return '{"status":"Succeeded","changes":[]}' }
    if ($Arguments[0] -ceq 'deployment' -and $Arguments[2] -ceq 'create') {
        $context.deployments++
        return ConvertTo-CanonicalJson @{properties=@{provisioningState='Succeeded';outputs=@{DEVELOPER_COMPLETION=@{value=$context.output}}}}
    }
    throw 'Unmocked Azure command is prohibited.'
}
function Assert-PreparedDeploymentFoundation { param($Profile,$PlatformInputs) return $true }
function New-BootstrapGovernanceRequest { param($Profile) return { throw 'Unexpected governance transport call.' } }
function Assert-GovernanceDeploymentReadiness { param($Profile,$BillingCurrency,$Request) return $true }
function New-EnvironmentArmRequest {
    param($Profile)
    return {
        param($Method,$Uri,$Body,$Headers)
        if ($Method -cne 'GET' -or $null -ne $Body) { throw 'Unexpected ARM mutation.' }
        return @{StatusCode=404;Body=@{error=@{code='ResourceNotFound'}};Headers=@{}}
    }
}
function Get-GatewayObservedState { param($Profile) return $context.state }
function Import-ReleaseImage {
    param($Resolved,$BundlePath,[switch]$Execute,[switch]$Confirm)
    if (-not $Execute) { throw 'Import was not explicitly requested.' }
    $context.imports++
    return @{digest=$Resolved.profile.release.imageDigest;executed=$true}
}
function Complete-GatewayActivation {
    param($Plan,$Request,[switch]$Apply,[bool]$StopNewRequests,[switch]$Confirm)
    if (-not $Apply) { throw 'Gateway completion was not explicitly requested.' }
    $context.gatewayCompletions++
    return @{status='VerifiedControlPlane';virtualNetworkType='Internal';networkModel='classic-vnet-injection';publicNetworkAccess='Enabled';stopControlVerified=$true;stopNewRequests=$StopNewRequests}
}
function Invoke-DeveloperCompletion {
    param($Resolution,$DeploymentOutput,[switch]$Execute)
    if (-not $Execute) { throw 'Completion was not explicitly requested.' }
    $context.completions++
    return @{runnerReady=$true;status='Verified'}
}
function Invoke-LiveDeveloperGate {
    param($Resolution,$DeploymentOutput,[switch]$ExecutePaidProbes,$ApprovedEnvironment,$ApprovedSourceSha,$MaxRequests,$MaxTotalTokens,$IdentityContext,$ReleaseFingerprint,$WorkflowRunId)
    if ($ExecutePaidProbes) { $context.paidProbes++; throw 'Paid calls are prohibited in this fixture.' }
    return @{promotionEligible=$false;checks=@{}}
}
function Invoke-WebRequest { throw 'External HTTP is prohibited.' }
function Invoke-RestMethod { throw 'External HTTP is prohibited.' }

try {
    $entry = Join-Path $root 'scripts\github\Invoke-EnvironmentDeployment.ps1'
    $arguments = @{ProfilePath=Join-Path $fixture 'profile.json';SelectionPath=Join-Path $fixture 'selected.json';PlatformInputsPath=Join-Path $fixture 'platform.json';BundlePath=Join-Path $fixture 'bundle'}
    $previewDirectory = Join-Path $fixture 'preview'
    & $entry @arguments -Phase Preview -OutputDirectory $previewDirectory
    $approved = Read-BootstrapJsonFile (Join-Path $previewDirectory 'preview.json')
    Assert-True ($approved.createdAt -is [string]) 'Preview timestamp did not remain a JSON string.'
    $context.phase = 'Deploy'
    $infrastructureDirectory = Join-Path $fixture 'infrastructure'
    & $entry @arguments -Phase Deploy -OutputDirectory $infrastructureDirectory -PreviewDirectory $previewDirectory -ApprovedPreviewHash $approved.hash -Execute
    Assert-True ($context.imports -eq 1 -and $context.deployments -eq 1) 'An unchanged persisted preview did not authorize the exact deployment.'
    Assert-True (Test-Path (Join-Path $infrastructureDirectory 'infrastructure.json')) 'Infrastructure evidence was not persisted.'
    $context.phase = 'Complete'
    $completeDirectory = Join-Path $fixture 'complete'
    & $entry @arguments -Phase Complete -OutputDirectory $completeDirectory -PreviewDirectory $previewDirectory -ApprovedPreviewHash $approved.hash -InfrastructureDirectory $infrastructureDirectory -Execute
    $record = Read-BootstrapJsonFile (Join-Path $completeDirectory 'deployment.json')
    Assert-True ($record.status -ceq 'InfrastructureAndPrivateCompletionVerified') 'Persisted approval did not survive private completion.'
    Assert-True ($context.completions -eq 1 -and $context.gatewayCompletions -eq 1 -and $context.paidProbes -eq 0) 'Completion effects or paid-call boundary differed.'
    $approved.createdAt = '2026-01-01T00:00:00.0000000Z'
    Write-JsonFile (Join-Path $previewDirectory 'preview.json') $approved
    $context.phase = 'Deploy'
    $rejected = $false
    try { & $entry @arguments -Phase Deploy -OutputDirectory (Join-Path $fixture 'tampered') -PreviewDirectory $previewDirectory -ApprovedPreviewHash $approved.hash -Execute }
    catch { $rejected = $true }
    Assert-True ($rejected -and $context.imports -eq 1 -and $context.deployments -eq 1) 'Changed persisted evidence reached a mutation.'
    Write-Host "Deployment entrypoint: $assertions assertions passed; all external operations were explicit offline adapters."
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
