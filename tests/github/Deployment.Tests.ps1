#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts\github\Bootstrap.psm1')
Import-Module (Join-Path $root 'scripts\github\Deployment.psm1') -Force
$count = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}
$profile = @{
    environment='dev'; azure=@{tenantId='11111111-1111-1111-1111-111111111111';subscriptionId='22222222-2222-2222-2222-222222222222';resourceGroup='synthetic'}
    gateway=@{name='synthetic-gateway';workloadKey='syntheticlz01';stopNewRequests=$false}
    governance=@{assignmentPrefix='synthetic';budget=@{contactGroups=@()}}
    identities=@{preview=@{clientId='33333333-3333-3333-3333-333333333333'};deploy=@{clientId='44444444-4444-4444-4444-444444444444'}}
}
$gatewayId = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/synthetic/providers/Microsoft.ApiManagement/service/synthetic-gateway"
$state = @{ exists=$false; owned=$true; public='Enabled'; connected=$false; provisioning='Succeeded'; calls=[Collections.Generic.List[string]]::new() }
$native = {
    param($Command, $Arguments)
    $state.calls.Add("$Command $($Arguments[0]) $($Arguments[1])")
    if ($Command -cne 'az' -or $Arguments[0] -cne 'resource') { throw 'Unexpected mutation in read-only deployment planning.' }
    if ($Arguments[1] -ceq 'list') {
        if ($state.exists) { return (ConvertTo-Json -InputObject @(@{id=$gatewayId;name='synthetic-gateway'}) -Compress) }
        return '[]'
    }
    if ($Arguments[1] -ceq 'show') {
        $connections = @()
        if ($state.connected) { $connections = @(@{properties=@{privateEndpoint=@{id="$gatewayId/synthetic-private-endpoint"};privateLinkServiceConnectionState=@{status='Approved'}}}) }
        return (@{
            id=$gatewayId
            tags=@{'ailz-managed-by'=$(if($state.owned){'github-dev-environment'}else{'someone-else'});'ailz-environment'='dev'}
            properties=@{publicNetworkAccess=$state.public;provisioningState=$state.provisioning;privateEndpointConnections=$connections}
        } | ConvertTo-Json -Depth 12 -Compress)
    }
    throw 'Unexpected Azure operation.'
}.GetNewClosure()
$absent = Get-GatewayObservedState -Profile $profile -Native $native
Assert-True (-not $absent.gatewayExists -and $state.calls.Count -eq 1) 'Absent gateway inspection was not read-only.'
$resolved = @{parameters=@{parameters=@{deployApiManagement=@{value=$true};apiManagementConfiguration=@{value=@{name='synthetic-gateway'}}}}}
$initial = Get-DeploymentParameters -Resolved $resolved -ObservedState $absent
Assert-True ($initial.parameters.apiManagementConfiguration.value.initialProvisioning -eq $true) 'New service creation did not select the explicit initial phase.'
Assert-True (-not $resolved.parameters.parameters.apiManagementConfiguration.value.Contains('initialProvisioning')) 'State resolution mutated the shared profile result.'
# The only settled shape on classic VNet injection: publicNetworkAccess Enabled,
# no private endpoint, provisioning Succeeded. It must not re-engage the initial
# stop on every redeploy, and it must agree with Get-GatewayDeploymentPlan,
# which Invoke-EnvironmentDeployment enforces.
$state.exists = $true
$settled = Get-GatewayObservedState -Profile $profile -Native $native
$steady = Get-DeploymentParameters -Resolved $resolved -ObservedState $settled
Assert-True ($settled.provisioningState -ceq 'Succeeded' -and $steady.parameters.apiManagementConfiguration.value.initialProvisioning -eq $false) 'A settled injected gateway re-entered initial provisioning, which disagrees with the gateway planner and stops the gateway on every redeploy.'
$state.owned = $false
Assert-Rejected { Get-GatewayObservedState -Profile $profile -Native $native } 'An existing unowned gateway was adopted.'
$state.owned = $true
$state.public = 'Disabled'
$state.connected = $false
Assert-Rejected { Get-GatewayObservedState -Profile $profile -Native $native } 'A private gateway without an approved endpoint was treated as ready.'
$state.public = 'Enabled'
$state.provisioning = 'Updating'
Assert-Rejected { Get-GatewayObservedState -Profile $profile -Native $native } 'A gateway still provisioning was planned instead of re-observed.'
$state.provisioning = 'Failed'
$partial = Get-GatewayObservedState -Profile $profile -Native $native
$repair = Get-DeploymentParameters -Resolved $resolved -ObservedState $partial
Assert-True ($repair.parameters.apiManagementConfiguration.value.initialProvisioning -eq $true) 'An interrupted initial creation was not resumed as initial provisioning.'
$account = @{ id=$profile.azure.subscriptionId;tenantId=$profile.azure.tenantId;user=@{type='servicePrincipal';name=$profile.identities.preview.clientId} }
Assert-AzureDeploymentIdentity -Profile $profile -Phase Preview -Account $account
$count++
$account.user.name = $profile.identities.deploy.clientId
Assert-Rejected { Assert-AzureDeploymentIdentity -Profile $profile -Phase Preview -Account $account } 'The deploy identity was accepted for constrained preview.'
$account.tenantId = '55555555-5555-5555-5555-555555555555'
Assert-Rejected { Assert-AzureDeploymentIdentity -Profile $profile -Phase Deploy -Account $account } 'A different tenant reached deployment.'
$request = New-EnvironmentArmRequest -Profile $profile
Assert-Rejected { & $request 'PATCH' "https://management.azure.com${gatewayId}?api-version=2024-05-01" @{properties=@{publicNetworkAccess='Enabled'}} @{} } 'Completion could enable public access.'
Assert-Rejected { & $request 'GET' "https://untrusted.invalid${gatewayId}?api-version=2024-05-01" $null @{} } 'ARM credentials could be sent to another origin.'
Assert-Rejected { & $request 'GET' 'https://management.azure.com/subscriptions/other/resourceGroups/other/providers/Microsoft.ApiManagement/service/other?api-version=2024-05-01' $null @{} } 'ARM completion could cross its scope.'
Assert-Rejected { & $request 'GET' "https://management.azure.com${gatewayId}?api-version=2024-05-01" $null @{Authorization='untrusted'} } 'Caller could replace transport authentication.'
Assert-Rejected { & $request 'PUT' "https://management.azure.com${gatewayId}/namedValues/ailz-inference-dev-syntheticlz01-stop?api-version=2024-05-01" @{properties=@{value='false';keyVault=@{secretIdentifier='untrusted'}}} @{} } 'Stop control could introduce a secret reference.'
$readOnly = New-BootstrapGovernanceRequest -Profile $profile -Transport { throw 'An invalid governance request reached a transport.' }
Assert-Rejected { & $readOnly 'PUT' "https://management.azure.com${gatewayId}?api-version=2024-05-01" @{properties=@{}} @{} } 'Governance readiness could write resources.'
Assert-Rejected { & $readOnly 'GET' 'https://management.azure.com/subscriptions/other/providers/Microsoft.Authorization/policyDefinitions/other?api-version=2021-06-01' $null @{} } 'Governance readiness could read another unapproved subscription.'
Write-Host "Deployment: $count assertions passed."
