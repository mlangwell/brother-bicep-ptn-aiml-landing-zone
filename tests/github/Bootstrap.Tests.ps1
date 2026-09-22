#Requires -Version 7.0
<#
.SYNOPSIS
Offline bootstrap reconciliation tests. All remote effects use an in-memory API.
.DESCRIPTION
The identifiers below belong only to this mock. No fixture is a deployment
profile, and this suite must never invoke the live bootstrap transport.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $root 'scripts\github\Environment.psm1') -Force
Import-Module (Join-Path $root 'scripts\github\Bootstrap.psm1') -Force
$script:passed = 0
$script:failed = 0

function Assert-Bootstrap {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    $script:passed++
    Write-Host "[PASS] $Name"
}

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    if ($null -ne $caught -and $caught.Exception.Message -notmatch $Pattern) {
        throw "Unexpected failure for '$Name': $($caught.Exception.Message)"
    }
    Assert-Bootstrap $Name ($null -ne $caught -and $caught.Exception.Message -match $Pattern)
}

function Copy-Json {
    param($Value)
    ConvertFrom-BootstrapJson -Json (ConvertTo-CanonicalJson -Value $Value)
}

function New-MockContext {
    param([string]$Environment = 'dev')
    $subscription = '11111111-1111-4111-8111-111111111111'
    $tenant = '22222222-2222-4222-8222-222222222222'
    $scope = "/subscriptions/$subscription/resourceGroups/rg-bootstrap-test"
    $profile = @{
        schemaVersion = 1; synthetic = $false; environment = $Environment
        azure = @{ tenantId = $tenant; subscriptionId = $subscription; resourceGroup = 'rg-bootstrap-test'; location = 'eastus2' }
        github = @{
            repository = 'bootstrap-tests/landing-zone'; repositoryId = 123456; ownerId = 654321
            protectedRef = 'refs/heads/main'; offering = 'enterprise-cloud'; visibility = 'private'
            environmentReviewers = @(@{ type = 'Team'; id = 700 })
            oidc = @{
                issuer = 'https://token.actions.githubusercontent.com'; audience = 'api://AzureADTokenExchange'
                subjectFormat = 'immutable'
                previewSubject = "repo:bootstrap-tests@654321/landing-zone@123456:environment:$Environment-preview"
                deploySubject = "repo:bootstrap-tests@654321/landing-zone@123456:environment:$Environment"
            }
            runner = @{
                mode = 'github-hosted-private'; group = 'private-linux'; labels = @('private-linux')
                subnetResourceId = "$scope/providers/Microsoft.Network/virtualNetworks/runner/subnets/actions"
                networkConfigurationId = 'configuration-1'
            }
        }
        identities = @{
            preview = @{ clientId = '33333333-3333-4333-8333-333333333333'; principalId = '44444444-4444-4444-8444-444444444444'; resourceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/preview" }
            deploy = @{ clientId = '55555555-5555-4555-8555-555555555555'; principalId = '66666666-6666-4666-8666-666666666666'; resourceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/deploy" }
            workload = @{ clientId = '77777777-7777-4777-8777-777777777777'; principalId = '88888888-8888-4888-8888-888888888888'; resourceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/workload" }
            developerObjectIds = @(); developerGroupObjectIds = @()
        }
        parameters = @{
            hubIntegrationHubVnetResourceId = "$scope/providers/Microsoft.Network/virtualNetworks/hub"
            hubIntegrationEgressNextHopIp = '10.250.0.4'
            networkIsolation = $true; aiFoundryDisableLocalAuth = $true
        }
        network = @{ hubAddressPrefixes = @('10.250.0.0/24'); runnerSubnetPrefix = '10.251.0.0/24'; reservedAddressPrefixes = @() }
        application = @{ registryResourceId = "$scope/providers/Microsoft.ContainerRegistry/registries/bootstraptest"; name = 'developer-smoke' }
        gateway = @{ name = 'gateway'; workloadKey = 'bootstraplz01'; audience = 'api://gateway' }
        release = @{ sourceSha = ('a' * 40); workflow = 'oidc-probe.yml'; ref = 'refs/heads/main' }
    }
    $resolved = @{ schemaVersion = 1; environment = $Environment; profile = $profile; parameters = @{ parameters = @{} } }
    $resolved.configurationHash = Get-CanonicalHash $resolved
    $inputs = @{
        schemaVersion = 1; owner = 'bootstrap-tests'
        github = @{ serverUrl = 'https://github.com'; apiUrl = 'https://api.github.com' }
        runner = @{
            groupId = 42; approvedRepositoryIds = @(123456)
            approvedWorkflowRefs = @('bootstrap-tests/landing-zone/.github/workflows/deploy.yml@refs/heads/main')
            adminLogin = 'platform-admin'; adminId = 900
            nsgResourceId = "$scope/providers/Microsoft.Network/networkSecurityGroups/runner"
        }
        access = @{ deploymentRoleNames = @('AppConfigurationDataReader', 'AcrPull', 'CognitiveServicesOpenAIUser') }
        ownership = @()
    }
    $state = @{}
    $state['GitHub:/repos/bootstrap-tests/landing-zone'] = @{
        id = 123456; full_name = 'bootstrap-tests/landing-zone'; visibility = 'private'
        owner = @{ id = 654321; login = 'bootstrap-tests'; type = 'Organization' }
        permissions = @{ admin = $true }
    }
    $state['GitHub:/meta'] = @{}
    $state['GitHub:/user'] = @{ id = 900; login = 'platform-admin' }
    $state['GitHub:/repos/bootstrap-tests/landing-zone/git/ref/heads/main'] = @{ ref = 'refs/heads/main'; object = @{ type = 'commit'; sha = ('a' * 40) } }
    $state['GitHub:/orgs/bootstrap-tests'] = @{ id = 654321; login = 'bootstrap-tests'; plan = @{ name = 'enterprise' } }
    $state['GitHub:/orgs/bootstrap-tests/memberships/platform-admin'] = @{
        state = 'active'; role = 'admin'; user = @{ id = 900; login = 'platform-admin' }; organization = @{ id = 654321 }
    }
    $state['GitHub:/repos/bootstrap-tests/landing-zone/actions/oidc/customization/sub'] = @{
        use_default = $true; use_immutable_subject = $true
    }
    $state['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'] = @{
        id = 42; name = 'private-linux'; visibility = 'selected'; network_configuration_id = 'configuration-1'
        restricted_to_workflows = $true
        selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy.yml@refs/heads/main')
    }
    $state['GitHub:/orgs/bootstrap-tests/actions/runner-groups'] = @{
        total_count = 1; runner_groups = @($state['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'])
    }
    $state['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/repositories'] = @{ total_count = 1; repositories = @(@{ id = 123456 }) }
    $state['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/hosted-runners'] = @{
        total_count = 1; runners = @(@{ id = 99; name = 'private-linux'; platform = 'linux-x64'; status = 'Ready'; maximum_runners = 1; public_ip_enabled = $false })
    }
    $state['GitHub:/orgs/bootstrap-tests/settings/network-configurations/configuration-1'] = @{
        id = 'configuration-1'; compute_service = 'actions'; network_settings_ids = @('settings-1')
    }
    $state['GitHub:/orgs/bootstrap-tests/settings/network-settings/settings-1'] = @{
        id = 'settings-1'; subnet_id = $profile.github.runner.subnetResourceId; region = 'eastus2'
    }
    $state["Azure:$($profile.github.runner.subnetResourceId)"] = @{
        id = $profile.github.runner.subnetResourceId
        properties = @{
            addressPrefix = '10.251.0.0/24'
            networkSecurityGroup = @{ id = $inputs.runner.nsgResourceId }
            delegations = @(@{ properties = @{ serviceName = 'GitHub.Network/networkSettings' } })
        }
    }
    $state["Azure:$($inputs.runner.nsgResourceId)"] = @{ id = $inputs.runner.nsgResourceId; properties = @{ securityRules = @() } }
    $inputs.runner.approvedNsgFingerprint = Get-CanonicalHash $state["Azure:$($inputs.runner.nsgResourceId)"].properties
    foreach ($identity in $profile.identities.preview, $profile.identities.deploy, $profile.identities.workload) {
        $state["Azure:$($identity.resourceId)"] = @{
            id = $identity.resourceId
            properties = @{ clientId = $identity.clientId; principalId = $identity.principalId; tenantId = $tenant }
        }
        $state["Azure:$($identity.resourceId)/federatedIdentityCredentials"] = @{ value = @() }
    }
    $state["Azure:$($profile.application.registryResourceId)"] = @{
        id = $profile.application.registryResourceId
        properties = @{
            loginServer = 'bootstraptest.azurecr.io'; publicNetworkAccess = 'Disabled'; adminUserEnabled = $false
            roleAssignmentMode = 'LegacyRegistryPermissions'
            policies = @{ azureADAuthenticationAsArmPolicy = @{ status = 'enabled' } }
        }
    }
    $state["Azure:$($profile.application.registryResourceId)/providers/Microsoft.Authorization/roleAssignments"] = @{ value = @() }
    $state["Azure:$scope"] = @{ id = $scope; location = 'eastus2'; properties = @{ provisioningState = 'Succeeded' } }
    $state["Azure:$scope/providers/Microsoft.Authorization/roleAssignments"] = @{ value = @() }
    $context = @{
        Resolved = $resolved; Inputs = $inputs; State = $state
        Writes = [Collections.Generic.List[object]]::new(); Reads = [Collections.Generic.List[string]]::new()
        Overrides = @{}; Scope = $scope; FailWriteSuffix = ''; FailProvisioning = $false
    }
    $transport = {
        param($Request)
        $path = ($Request.path -split '\?', 2)[0]
        $key = "$($Request.provider):$path"
        if ($context.Overrides.ContainsKey($key)) { return $context.Overrides[$key] }
        if ($Request.method -eq 'GET') {
            $context.Reads.Add($key)
            if ($path.EndsWith('/providers/Microsoft.Authorization/permissions')) {
                return @{ status = 200; body = @{ value = @(@{ actions = @('*'); notActions = @() }) }; etag = '' }
            }
            if (-not $context.State.ContainsKey($key)) { return @{ status = 404; body = $null; etag = '' } }
            $value = Copy-Json $context.State[$key]
            return @{ status = 200; body = $value; etag = (Get-CanonicalHash $value) }
        }
        $context.Writes.Add((Copy-Json $Request))
        if ($context.FailWriteSuffix -and $path.EndsWith($context.FailWriteSuffix)) { return @{ status = 403; body = @{}; etag = '' } }
        if ($path -match '/environments/[^/]+$' -and $Request.method -eq 'PUT') {
            $previous = $context.State[$key]
            $rules = @()
            if (@($Request.body.reviewers).Count -gt 0) {
                $rules += @{ type = 'required_reviewers'; prevent_self_review = $Request.body.prevent_self_review; reviewers = @($Request.body.reviewers | ForEach-Object { @{ type = $_.type; reviewer = @{ id = $_.id } } }) }
            }
            if ($Request.body.wait_timer -gt 0) { $rules += @{ type = 'wait_timer'; wait_timer = $Request.body.wait_timer } }
            $context.State[$key] = @{
                name = ($path -split '/')[-1]; id = 101
                protection_rules = $rules; deployment_branch_policy = $Request.body.deployment_branch_policy
                can_admins_bypass = if ($null -ne $previous -and $previous.ContainsKey('can_admins_bypass')) { $previous.can_admins_bypass } else { $true }
            }
            if (-not $context.State.ContainsKey("${key}/deployment-branch-policies")) {
                $context.State["${key}/deployment-branch-policies"] = @{ total_count = 0; branch_policies = @() }
            }
        }
        elseif ($path.EndsWith('/variables') -and $Request.method -eq 'POST') {
            $context.State["$key/$($Request.body.name)"] = Copy-Json $Request.body
        }
        elseif ($path.EndsWith('/deployment-branch-policies') -and $Request.method -eq 'POST') {
            $collection = $context.State[$key]
            $collection.branch_policies += @{ id = 200 + $collection.total_count; name = $Request.body.name; type = $Request.body.type }
            $collection.total_count++
        }
        else {
            $context.State[$key] = Copy-Json $Request.body
            $context.State[$key].id = $path
            if ($path -match '/userAssignedIdentities/[^/]+$') {
                $context.State[$key].properties = @{
                    tenantId = $context.Resolved.profile.azure.tenantId
                    clientId = ([guid]::ParseExact((Get-CanonicalHash "${path}:client").Substring(0, 32), 'N')).ToString('D')
                    principalId = ([guid]::ParseExact((Get-CanonicalHash "${path}:principal").Substring(0, 32), 'N')).ToString('D')
                }
            }
            if ($path -match '/virtualNetworkPeerings/[^/]+$') { $context.State[$key].properties.peeringState = 'Connected'; $context.State[$key].properties.provisioningState = 'Succeeded' }
            if ($path -match '/virtualNetworkLinks/[^/]+$') { $context.State[$key].properties.virtualNetworkLinkState = 'Completed'; $context.State[$key].properties.provisioningState = 'Succeeded' }
            if ($context.FailProvisioning) { $context.State[$key].properties.provisioningState = 'Failed' }
            if ($path -match '/(roleAssignments|federatedIdentityCredentials|virtualNetworkPeerings|virtualNetworkLinks)/[^/]+$') {
                $parentKey = "$($Request.provider):$($path.Substring(0, $path.LastIndexOf('/')))"
                if (-not $context.State.ContainsKey($parentKey)) { $context.State[$parentKey] = @{ value = @() } }
                $context.State[$parentKey].value = @($context.State[$parentKey].value | Where-Object { $_.id -ne $path }) + @($context.State[$key])
            }
        }
        return @{ status = 200; body = $context.State[$key]; etag = '' }
    }.GetNewClosure()
    $context.Transport = $transport
    return $context
}

function Rehash-Resolved {
    param($Context)
    $Context.Resolved.Remove('configurationHash')
    $Context.Resolved.configurationHash = Get-CanonicalHash $Context.Resolved
}

function Set-OwnedEnvironment {
    param($Context, [string]$Name, [bool]$Protected = $false)
    $key = "GitHub:/repos/bootstrap-tests/landing-zone/environments/$Name"
    $Context.State[$key] = @{
        id = 101; name = $Name; can_admins_bypass = $false
        protection_rules = @(if ($Protected) { @{ type = 'required_reviewers'; prevent_self_review = $true; reviewers = @(@{ type = 'Team'; reviewer = @{ id = 700 } }) } })
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
    }
    $Context.State["$key/variables/AILZ_BOOTSTRAP_OWNER"] = @{ name = 'AILZ_BOOTSTRAP_OWNER'; value = "bootstrap-tests:123456:$($Context.Resolved.environment)" }
    $Context.State["$key/deployment-branch-policies"] = @{ total_count = 1; branch_policies = @(@{ id = 201; name = 'main'; type = 'branch' }) }
}

function Add-OidcEvidence {
    param($Context)
    $profile = $Context.Resolved.profile
    $Context.Inputs.oidcEvidence = @{}
    foreach ($purpose in 'preview', 'deploy') {
        $name = if ($purpose -eq 'preview') { "$($profile.environment)-preview" } else { $profile.environment }
        $runId = if ($purpose -eq 'preview') { 81 } else { 82 }
        $Context.Inputs.oidcEvidence[$purpose] = @{
            schemaVersion = 1; serverUrl = 'https://github.com'
            claims = @{
                iss = $profile.github.oidc.issuer; aud = $profile.github.oidc.audience; sub = $profile.github.oidc["${purpose}Subject"]
                repository = $profile.github.repository; repository_id = '123456'; repository_owner_id = '654321'
                environment = $name; ref = 'refs/heads/main'; run_id = "$runId"; run_attempt = '1'
                workflow_ref = 'bootstrap-tests/landing-zone/.github/workflows/oidc-probe.yml@refs/heads/main'
                workflow_sha = ('a' * 40); event_name = 'workflow_dispatch'
            }
        }
        $Context.State["GitHub:/repos/bootstrap-tests/landing-zone/actions/runs/$runId/attempts/1"] = @{
            id = $runId; run_attempt = 1; repository = @{ id = 123456; full_name = $profile.github.repository; owner = @{ id = 654321 } }
            head_sha = ('a' * 40); head_branch = 'main'; event = 'workflow_dispatch'
            path = '.github/workflows/oidc-probe.yml'; status = 'completed'; conclusion = 'success'
        }
    }
}

function Add-MockNetwork {
    param($Context)
    $scope = $Context.Scope
    $spoke = "$scope/providers/Microsoft.Network/virtualNetworks/spoke"
    $hub = $Context.Resolved.profile.parameters.hubIntegrationHubVnetResourceId
    $route = "$scope/providers/Microsoft.Network/routeTables/spoke"
    $resolver = "$scope/providers/Microsoft.Network/dnsResolvers/hub"
    $zone = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
    $Context.Resolved.profile.parameters.useExistingVNet = $true
    $Context.Resolved.profile.parameters.existingVnetResourceId = $spoke
    $Context.Resolved.profile.parameters.deploySubnets = $false
    $Context.Resolved.profile.parameters.hubIntegrationCreateHubPeering = $false
    $Context.Resolved.profile.parameters.hubIntegrationExistingRouteTableResourceId = $route
    $Context.Resolved.profile.parameters.Remove('hubIntegrationEgressNextHopIp')
    Rehash-Resolved $Context
    $Context.Inputs.network = @{
        spokeVnetResourceId = $spoke; allowForwardedTraffic = $true; privateDnsZoneResourceIds = @($zone)
        egress = @{ routeTableResourceId = $route; expectedNextHopIp = '10.250.0.4'; dnsResolverResourceId = $resolver; expectedDnsServers = @('10.250.0.5'); approvedResolverFingerprint = ''; subnetResourceIds = @("$spoke/subnets/applications") }
    }
    $Context.State["Azure:$hub"] = @{ id = $hub; properties = @{ addressSpace = @{ addressPrefixes = @('10.250.0.0/24') } } }
    $Context.State["Azure:$hub/virtualNetworkPeerings"] = @{ value = @() }
    $Context.State["Azure:$spoke"] = @{
        id = $spoke
        properties = @{
            dhcpOptions = @{ dnsServers = @('10.250.0.5') }
            subnets = @(@{ properties = @{ routeTable = @{ id = $route } } })
        }
    }
    $Context.State["Azure:$spoke/subnets/applications"] = @{ id = "$spoke/subnets/applications"; properties = @{ routeTable = @{ id = $route } } }
    $Context.State["Azure:$spoke/virtualNetworkPeerings"] = @{ value = @(@{
        id = "$spoke/virtualNetworkPeerings/to-hub"
        properties = @{ remoteVirtualNetwork = @{ id = $hub }; allowVirtualNetworkAccess = $true; allowForwardedTraffic = $true }
    }) }
    $Context.State["Azure:$route"] = @{
        id = $route; properties = @{ routes = @(@{ name = 'default'; properties = @{ addressPrefix = '0.0.0.0/0'; nextHopType = 'VirtualAppliance'; nextHopIpAddress = '10.250.0.4' } }) }
    }
    $Context.State["Azure:$resolver"] = @{ id = $resolver; properties = @{ virtualNetwork = @{ id = $hub }; provisioningState = 'Succeeded' } }
    $Context.Inputs.network.egress.approvedResolverFingerprint = Get-CanonicalHash $Context.State["Azure:$resolver"].properties
    $Context.State["Azure:$zone"] = @{ id = $zone; location = 'global'; properties = @{} }
    $Context.State["Azure:$zone/virtualNetworkLinks"] = @{ value = @() }
}

function Add-PreparedFoundation {
    param($Context)
    Add-MockNetwork $Context
    $p = $Context.Resolved.profile
    $spoke = $p.parameters.existingVnetResourceId
    $hub = $p.parameters.hubIntegrationHubVnetResourceId
    $route = $p.parameters.hubIntegrationExistingRouteTableResourceId
    $p.parameters.acaEnvironmentSubnetName = 'applications'
    $p.parameters.acaEnvironmentSubnetPrefix = '10.252.1.0/24'
    $p.parameters.peSubnetName = 'pe-subnet'
    $p.parameters.peSubnetPrefix = '10.252.2.0/26'
    $p.parameters.existingPrivateDnsZoneAcrResourceId = "$($Context.Scope)/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
    $Context.Inputs.network.privateDnsZoneResourceIds = @($p.parameters.existingPrivateDnsZoneAcrResourceId)
    $Context.State["Azure:$spoke/subnets/applications"] = @{
        id = "$spoke/subnets/applications"
        properties = @{
            addressPrefix = $p.parameters.acaEnvironmentSubnetPrefix; routeTable = @{ id = $route }
            networkSecurityGroup = @{ id = "$($Context.Scope)/providers/Microsoft.Network/networkSecurityGroups/apps" }
            delegations = @(@{ properties = @{ serviceName = 'Microsoft.App/environments' } })
        }
    }
    $Context.State["Azure:$spoke/subnets/pe-subnet"] = @{
        id = "$spoke/subnets/pe-subnet"
        properties = @{ addressPrefix = $p.parameters.peSubnetPrefix; networkSecurityGroup = @{ id = "$($Context.Scope)/providers/Microsoft.Network/networkSecurityGroups/pe" }; delegations = @() }
    }
    $Context.Inputs.network.preparedSubnetNsgs = @()
    foreach ($name in 'applications', 'pe-subnet') {
        $subnetId = "$spoke/subnets/$name"
        $nsgId = $Context.State["Azure:$subnetId"].properties.networkSecurityGroup.id
        $Context.State["Azure:$nsgId"] = @{ id = $nsgId; properties = @{ securityRules = @() } }
        $Context.Inputs.network.preparedSubnetNsgs += @{
            subnetResourceId = $subnetId; nsgResourceId = $nsgId
            approvedNsgFingerprint = Get-CanonicalHash $Context.State["Azure:$nsgId"].properties
        }
    }
    $Context.State["Azure:$spoke/virtualNetworkPeerings"].value[0].properties.peeringState = 'Connected'
    $Context.State["Azure:$hub/virtualNetworkPeerings"] = @{ value = @(@{
        id = "$hub/virtualNetworkPeerings/to-spoke"
        properties = @{
            remoteVirtualNetwork = @{ id = $spoke }; allowVirtualNetworkAccess = $true; allowForwardedTraffic = $true
            allowGatewayTransit = $false; useRemoteGateways = $false; peeringState = 'Connected'
        }
    }) }
    $zone = $p.parameters.existingPrivateDnsZoneAcrResourceId
    $Context.State["Azure:$zone"] = @{ id = $zone; name = 'privatelink.azurecr.io'; properties = @{} }
    $Context.State["Azure:$zone/virtualNetworkLinks"] = @{ value = @(
        @{ properties = @{ virtualNetwork = @{ id = $spoke }; registrationEnabled = $false; virtualNetworkLinkState = 'Completed'; provisioningState = 'Succeeded' } },
        @{ properties = @{ virtualNetwork = @{ id = $hub }; registrationEnabled = $false; virtualNetworkLinkState = 'Completed'; provisioningState = 'Succeeded' } }
    ) }
    $registryId = $p.application.registryResourceId
    $pe = "$($Context.Scope)/providers/Microsoft.Network/privateEndpoints/registry"
    $Context.State["Azure:$registryId"].properties.privateEndpointConnections = @(@{
        properties = @{ privateEndpoint = @{ id = $pe }; privateLinkServiceConnectionState = @{ status = 'Approved' } }
    })
    $Context.State["Azure:$registryId"].properties.dataEndpointHostNames = @('bootstraptest.eastus2.data.azurecr.io')
    $Context.State["Azure:$pe"] = @{
        id = $pe; properties = @{
            provisioningState = 'Succeeded'; subnet = @{ id = "$spoke/subnets/pe-subnet" }
            customDnsConfigs = @(
                @{ fqdn = 'bootstraptest.azurecr.io'; ipAddresses = @('10.252.2.4') },
                @{ fqdn = 'bootstraptest.eastus2.data.azurecr.io'; ipAddresses = @('10.252.2.5') }
            )
        }
    }
    $roles = Get-Content -LiteralPath (Join-Path $root 'constants\roles.json') -Raw | ConvertFrom-Json -AsHashtable
    $Context.State["Azure:$registryId/providers/Microsoft.Authorization/roleAssignments"] = @{ value = @(@{
        id = "$registryId/providers/Microsoft.Authorization/roleAssignments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        properties = @{
            scope = $registryId; principalId = $p.identities.workload.principalId; principalType = 'ServicePrincipal'
            roleDefinitionId = "/subscriptions/$($p.azure.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($roles.AcrPull.guid)"
        }
    }, @{
        id = "$registryId/providers/Microsoft.Authorization/roleAssignments/cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        properties = @{
            scope = $registryId; principalId = $p.identities.deploy.principalId; principalType = 'ServicePrincipal'
            roleDefinitionId = "/subscriptions/$(($registryId -split '/')[2])/providers/Microsoft.Authorization/roleDefinitions/$($roles.AcrPush.guid)"
        }
    }) }
    Rehash-Resolved $Context
}

function New-MockCompletion {
    param($Context)
    $scope = $Context.Scope
    $config = "$scope/providers/Microsoft.AppConfiguration/configurationStores/config"
    $gateway = "$scope/providers/Microsoft.ApiManagement/service/gateway"
    $backend = "$scope/providers/Microsoft.CognitiveServices/accounts/foundry"
    $gatewayPrincipal = '99999999-9999-4999-8999-999999999999'
    $completion = @{
        schemaVersion = 1; environment = $Context.Resolved.environment
        tenantId = $Context.Resolved.profile.azure.tenantId; subscriptionId = $Context.Resolved.profile.azure.subscriptionId
        resourceGroup = $Context.Resolved.profile.azure.resourceGroup; release = Copy-Json $Context.Resolved.profile.release
        appConfiguration = @{ endpoint = 'https://config.azconfig.io'; resourceId = $config; settings = @() }
        applications = @(@{ name = 'developer-smoke'; principalId = $Context.Resolved.profile.identities.workload.principalId; identityResourceId = $Context.Resolved.profile.identities.workload.resourceId; resourceId = "$scope/providers/Microsoft.App/containerApps/developer-smoke"; fqdn = 'private.example.invalid'; image = 'image@sha256:mock' })
        gateway = @{ accessMode = 'gateway'; resourceId = $gateway; endpoint = 'https://gateway.azure-api.net/inference/bootstraplz01/v1/responses'; audience = 'api://gateway'; backendResourceId = $backend; backendEndpoint = 'https://foundry.openai.azure.com' }
        registryResourceId = $Context.Resolved.profile.application.registryResourceId
        workspace = @{ repository = 'bootstrap-tests/workspace'; ref = 'refs/heads/main' }
        vnetResourceId = "$scope/providers/Microsoft.Network/virtualNetworks/spoke"
    }
    $Context.Inputs.access.gatewayBackendRoleName = 'CognitiveServicesOpenAIUser'
    $Context.State["Azure:$config"] = @{ id = $config; properties = @{ endpoint = $completion.appConfiguration.endpoint; publicNetworkAccess = 'Disabled' } }
    $Context.State["Azure:$gateway"] = @{ id = $gateway; identity = @{ type = 'SystemAssigned'; principalId = $gatewayPrincipal; tenantId = $completion.tenantId }; properties = @{ gatewayUrl = 'https://gateway.azure-api.net'; publicNetworkAccess = 'Disabled' } }
    $Context.State["Azure:$backend"] = @{ id = $backend; properties = @{ publicNetworkAccess = 'Disabled'; disableLocalAuth = $true } }
    $Context.State["Azure:$($completion.registryResourceId)"] = @{ id = $completion.registryResourceId; properties = @{ loginServer = 'bootstraptest.azurecr.io'; adminUserEnabled = $false; publicNetworkAccess = 'Disabled' } }
    foreach ($resource in $config, $gateway, $backend, $completion.registryResourceId) {
        $Context.State["Azure:$resource/providers/Microsoft.Authorization/roleAssignments"] = @{ value = @() }
    }
    $roles = Get-Content -LiteralPath (Join-Path $root 'constants\roles.json') -Raw | ConvertFrom-Json -AsHashtable
    $Context.State["Azure:$($completion.registryResourceId)"].properties.roleAssignmentMode = 'LegacyRegistryPermissions'
    $Context.State["Azure:$($completion.registryResourceId)"].properties.policies = @{ azureADAuthenticationAsArmPolicy = @{ status = 'enabled' } }
    $Context.State["Azure:$($completion.registryResourceId)/providers/Microsoft.Authorization/roleAssignments"].value = @(@{
        id = "$($completion.registryResourceId)/providers/Microsoft.Authorization/roleAssignments/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        properties = @{
            principalId = $Context.Resolved.profile.identities.workload.principalId; principalType = 'ServicePrincipal'
            scope = $completion.registryResourceId
            roleDefinitionId = "/subscriptions/$($Context.Resolved.profile.azure.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($roles.AcrPull.guid)"
        }
    }, @{
        id = "$($completion.registryResourceId)/providers/Microsoft.Authorization/roleAssignments/dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        properties = @{
            principalId = $Context.Resolved.profile.identities.deploy.principalId; principalType = 'ServicePrincipal'
            scope = $completion.registryResourceId
            roleDefinitionId = "/subscriptions/$(($completion.registryResourceId -split '/')[2])/providers/Microsoft.Authorization/roleDefinitions/$($roles.AcrPush.guid)"
        }
    })
    return $completion
}

function Set-MockExistingPrivateRunner {
    param($Context)
    $Context.Resolved.profile.github.runner.mode = 'existing-private'
    $Context.Resolved.profile.github.runner.Remove('networkConfigurationId')
    $Context.Resolved.profile.github.runner.labels = @('self-hosted', 'Linux', 'X64')
    $Context.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].Remove('network_configuration_id')
    $Context.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/runners'] = @{ total_count = 1; runners = @(@{
        id = 99; name = 'private-agent'; os = 'linux'; status = 'online'; busy = $false
        labels = @(@{ name = 'self-hosted' }, @{ name = 'Linux' }, @{ name = 'X64' })
    }) }
    $Context.State["Azure:$($Context.Resolved.profile.github.runner.subnetResourceId)"].properties.delegations = @()
    $vm = "$($Context.Scope)/providers/Microsoft.Compute/virtualMachines/private-agent"
    $nic = "$($Context.Scope)/providers/Microsoft.Network/networkInterfaces/private-agent"
    $Context.Inputs.runner.machineBindings = @(@{ runnerId = 99; runnerName = 'private-agent'; virtualMachineResourceId = $vm; networkInterfaceResourceId = $nic })
    $Context.State["Azure:$vm"] = @{ id = $vm; properties = @{ storageProfile = @{ osDisk = @{ osType = 'Linux' } }; networkProfile = @{ networkInterfaces = @(@{ id = $nic }) } } }
    $Context.State["Azure:$nic"] = @{ id = $nic; properties = @{ ipConfigurations = @(@{ properties = @{ subnet = @{ id = $Context.Resolved.profile.github.runner.subnetResourceId } } }) } }
    Rehash-Resolved $Context
}

function ConvertTo-TestBase64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-SignedTestToken {
    param($Key, $Claims, [string]$Algorithm = 'RS256')
    $header = ConvertTo-TestBase64Url ([Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonicalJson @{ alg = $Algorithm; kid = 'test-key'; typ = 'JWT' })))
    $payload = ConvertTo-TestBase64Url ([Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonicalJson $Claims)))
    $message = "$header.$payload"
    $signature = $Key.SignData([Text.Encoding]::UTF8.GetBytes($message), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return "$message.$(ConvertTo-TestBase64Url $signature)"
}

function ConvertTo-ApprovedShapeMockValue {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-ApprovedShapeMockValue $Value[$key] }
        return ,$result
    }
    if ($Value -is [Collections.IList]) { return ,@($Value | ForEach-Object { ConvertTo-ApprovedShapeMockValue $_ }) }
    if ($Value -is [string]) {
        return ($Value -replace '(?i)synthetic', 'fixture' -replace '(?i)never-deploy', 'offline-fixture' -replace '(?i)example\.invalid', 'example.test').Replace('00000000-0000-4000-8000-', '10000000-0000-4000-8000-')
    }
    return $Value
}

function New-GovernanceMockContext {
    # Real P1/P3 conversion with approved-shaped, exclusively in-memory fixture IDs.
    Import-Module (Join-Path $root 'platform\policy\Governance.psm1')
    $profile = ConvertTo-ApprovedShapeMockValue (& (Join-Path $root 'tests\github\New-SyntheticProfile.ps1') -Environment dev)
    $profile.synthetic = $false
    $profile.governance.budget.startDate = [DateTime]::UtcNow.ToString('yyyy-MM-01')
    $profile.governance.budget.endDate = [DateTime]::UtcNow.AddYears(1).ToString('yyyy-MM-01')
    $resolved = Resolve-EnvironmentProfile -Profile $profile
    $currency = $profile.governance.budget.currency
    $desired = Get-GovernanceDesiredState -Profile $profile -BillingCurrency $currency
    $scope = $desired.scope
    $state = @{}
    $state[$scope] = @{ id = $scope; location = $profile.azure.location }
    $state["$scope/providers/Microsoft.Authorization/policyAssignments"] = @{ value = @() }
    $state["$scope/providers/Microsoft.Authorization/policyExemptions"] = @{ value = @() }
    foreach ($builtin in $desired.requiredBuiltins.Values) {
        $schemas = @{}
        foreach ($assignment in @($desired.resources | Where-Object { $_.kind -eq 'assignment' -and $_.properties.policyDefinitionId -eq $builtin.id })) {
            foreach ($name in $assignment.properties.parameters.Keys) {
                $value = $assignment.properties.parameters[$name].value
                $type = if ($value -is [bool]) { 'Boolean' } elseif ($value -is [Collections.IList]) { 'Array' } elseif ($value -is [string]) { 'String' } else { throw 'Unexpected fixture built-in parameter type.' }
                $schemas[$name] = @{ type = $type }
            }
        }
        $id = "$($builtin.id)/versions/$($builtin.version)"
        $state[$id] = @{
            id = $id; properties = @{
                policyType = 'BuiltIn'; version = $builtin.version; parameters = $schemas
                policyRule = @{ 'if' = @{ field = 'type'; equals = 'Microsoft.CognitiveServices/accounts' }; then = @{ effect = 'Audit' } }
            }
        }
    }
    $aliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-FixtureAliases {
        param($Value)
        if ($Value -is [Collections.IDictionary]) {
            if ($Value.Contains('field') -and $Value.field -is [string] -and $Value.field -match '^Microsoft\.') { $null = $aliases.Add($Value.field) }
            foreach ($item in $Value.Values) { Add-FixtureAliases $item }
        }
        elseif ($Value -is [Collections.IList]) { foreach ($item in $Value) { Add-FixtureAliases $item } }
    }
    foreach ($resource in @($desired.resources | Where-Object kind -eq 'definition')) { Add-FixtureAliases $resource.properties.policyRule }
    foreach ($namespace in @($aliases | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)) {
        $entries = @($aliases | Where-Object { $_.StartsWith("$namespace/", [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { @{ name = $_ } })
        $state["/subscriptions/$($profile.azure.subscriptionId)/providers/$namespace"] = @{ namespace = $namespace; resourceTypes = @(@{ aliases = $entries }) }
    }
    foreach ($id in $profile.governance.budget.contactGroups) { $state[$id] = @{ id = $id; properties = @{ enabled = $true } } }
    $context = @{
        Resolved = $resolved; Desired = $desired
        Inputs = @{ schemaVersion = 1; owner = 'bootstrap-governance'; governance = @{ billingCurrency = $currency } }
        State = $state; Writes = [Collections.Generic.List[object]]::new(); Reads = [Collections.Generic.List[string]]::new()
        WriteStatus = 200; DropCurrency = $false
    }
    $transport = {
        param($Request)
        if ($Request.provider -ne 'Azure') { throw 'Governance fixture must not query GitHub.' }
        $path = ($Request.path -split '\?', 2)[0]
        if ($Request.method -eq 'GET') {
            $context.Reads.Add($path)
            if ($path.EndsWith('/providers/Microsoft.Authorization/permissions')) {
                return @{ status = 200; body = @{ value = @(@{ actions = @('*'); notActions = @() }) }; etag = '' }
            }
            if (-not $context.State.ContainsKey($path)) { return @{ status = 404; body = @{ error = @{ code = 'ResourceNotFound' } }; etag = '' } }
            $body = Copy-Json $context.State[$path]
            return @{ status = 200; body = $body; etag = if ($body.Contains('eTag')) { $body.eTag } else { Get-CanonicalHash $body } }
        }
        $context.Writes.Add((Copy-Json $Request))
        if ($context.WriteStatus -ne 200) { return @{ status = $context.WriteStatus; body = @{ error = @{ code = 'Forbidden' } }; etag = '' } }
        $value = Copy-Json $Request.body
        $value.id = $path
        if ($path -match '/policyAssignments/') {
            $value.properties.scope = $context.Desired.scope
            $inventory = $context.State["$($context.Desired.scope)/providers/Microsoft.Authorization/policyAssignments"]
            $inventory.value = @($inventory.value | Where-Object { $_.id -ne $path }) + @($value)
        }
        if ($path -match '/budgets/') {
            $value.eTag = "budget-version-$($context.Writes.Count)"
            if (-not $context.DropCurrency) { $value.properties.currentSpend = @{ amount = 0; unit = $context.Inputs.governance.billingCurrency } }
        }
        $context.State[$path] = $value
        return @{ status = 200; body = Copy-Json $value; etag = '' }
    }.GetNewClosure()
    $context.Transport = $transport
    return $context
}

function New-ExternalRegistryAccessContext {
    $context = New-MockContext
    $profile = ConvertTo-ApprovedShapeMockValue (& (Join-Path $root 'tests\github\New-SyntheticProfile.ps1') -Environment dev)
    $profile.synthetic = $false
    $subscription = $profile.azure.subscriptionId
    $registry = "/subscriptions/$subscription/resourceGroups/rg-fixture-shared-registry/providers/Microsoft.ContainerRegistry/registries/fixtureexternalregistry"
    $profile.application.registryResourceId = $registry
    $context.Resolved = Resolve-EnvironmentProfile -Profile $profile
    $context.Scope = "/subscriptions/$subscription/resourceGroups/$($profile.azure.resourceGroup)"
    $context.State = @{}
    $repo = $profile.github.repository
    $owner = $repo.Split('/')[0]
    $context.State['GitHub:/meta'] = @{}
    $context.State["GitHub:/repos/$repo"] = @{
        id = $profile.github.repositoryId; full_name = $repo; visibility = $profile.github.visibility
        owner = @{ id = $profile.github.ownerId; login = $owner; type = 'Organization' }
        permissions = @{ admin = $true }
    }
    $context.State["GitHub:/orgs/$owner"] = @{ id = $profile.github.ownerId; login = $owner; plan = @{ name = 'enterprise' } }
    $ref = $profile.github.protectedRef.Substring(5)
    $context.State["GitHub:/repos/$repo/git/ref/$ref"] = @{ ref = $profile.github.protectedRef; object = @{ type = 'commit'; sha = $profile.release.sourceSha } }
    foreach ($identity in $profile.identities.preview, $profile.identities.deploy, $profile.identities.workload) {
        $context.State["Azure:$($identity.resourceId)"] = @{
            id = $identity.resourceId
            properties = @{ clientId = $identity.clientId; principalId = $identity.principalId; tenantId = $profile.azure.tenantId }
        }
    }
    $context.State["Azure:$registry"] = @{
        id = $registry; properties = @{
            loginServer = 'fixtureexternalregistry.azurecr.io'; publicNetworkAccess = 'Disabled'; adminUserEnabled = $false
            roleAssignmentMode = 'LegacyRegistryPermissions'; policies = @{ azureADAuthenticationAsArmPolicy = @{ status = 'enabled' } }
        }
    }
    $context.State["Azure:$registry/providers/Microsoft.Authorization/roleAssignments"] = @{ value = @() }
    $context.State["Azure:$($context.Scope)/providers/Microsoft.Authorization/roleAssignments"] = @{ value = @() }
    return $context
}

try {
    $f3 = New-MockContext
    Set-OwnedEnvironment $f3 'dev-preview'
    Set-OwnedEnvironment $f3 'dev'
    Set-MockExistingPrivateRunner $f3
    $workflow = 'bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main'
    $f3.Inputs.runner.approvedWorkflowRefs = @($workflow)
    $f3.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @($workflow)
    $selected = Assert-GitHubBootstrapReadiness -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -Transport $f3.Transport
    Assert-Bootstrap 'F3: one approved idle runner passes ordinary selection' ($selected -eq $true)
    $registered = $f3.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/runners'].runners[0]
    $registered.busy = $true
    $verified = Assert-GitHubBootstrapReadiness -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -CurrentRunnerName 'private-agent' -Transport $f3.Transport
    Assert-Bootstrap 'F3: that same single runner passes private-job verification after becoming busy' ($verified -eq $true -and $f3.Writes.Count -eq 0 -and @($f3.Reads | Where-Object { $_ -like 'Azure:*' }).Count -eq 0)
    Assert-Throws 'F3: ordinary selection still requires idle capacity' { Assert-GitHubBootstrapReadiness -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -Transport $f3.Transport } 'RUNNER_CAPACITY_UNAVAILABLE'
    Assert-Throws 'F3: an unrelated current-runner name cannot use a busy approved worker' { Assert-GitHubBootstrapReadiness -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -CurrentRunnerName 'unapproved-worker' -Transport $f3.Transport } 'RUNNER_CAPACITY_UNAVAILABLE'
    $registered.status = 'offline'
    Assert-Throws 'F3: the current-runner override does not accept an offline worker' { Assert-GitHubBootstrapReadiness -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -CurrentRunnerName 'private-agent' -Transport $f3.Transport } 'RUNNER_CAPACITY_UNAVAILABLE'
    $registered.status = 'online'
    $f3.Inputs.runner.machineBindings[0].runnerName = 'different-approved-name'
    Assert-Throws 'F3: current online runner still needs its exact approved binding' { Assert-GitHubBootstrapReadiness -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -CurrentRunnerName 'private-agent' -Transport $f3.Transport } 'RUNNER_MACHINE_BINDING_REQUIRED'
    $f3.Inputs.runner.machineBindings[0].runnerName = 'private-agent'
    Add-PreparedFoundation $f3
    $foundationReady = Assert-PreparedDeploymentFoundation -Profile $f3.Resolved.profile -PlatformInputs $f3.Inputs -CurrentRunnerName 'private-agent' -Transport $f3.Transport -NetworkProbe { param($Hostname, $ExpectedAddresses) @{ addresses = $ExpectedAddresses; tls = $true } }
    Assert-Bootstrap 'F3: the busy current worker still passes its actual mocked Azure VM/NIC foundation checks' ($foundationReady -eq $true -and $registered.busy)

    $f4 = New-MockContext
    $completion = New-MockCompletion $f4
    $completionPlan = New-PlatformBootstrapPlan -ResolvedEnvironment $f4.Resolved -PlatformInputs $f4.Inputs -Stage Completion -Completion $completion -Transport $f4.Transport
    Assert-Bootstrap 'F4: actual Bicep full-route output matches the separately observed APIM service root' ($completionPlan.status -eq 'planned' -and $completion.gateway.endpoint -eq 'https://gateway.azure-api.net/inference/bootstraplz01/v1/responses')
    $f4.State["Azure:$($completion.gateway.resourceId)"].properties.gatewayUrl = 'https://gateway.azure-api.net/'
    $trailingRoot = New-PlatformBootstrapPlan -ResolvedEnvironment $f4.Resolved -PlatformInputs $f4.Inputs -Stage Completion -Completion $completion -Transport $f4.Transport
    Assert-Bootstrap 'F4: a service-root trailing slash does not change the governed route' ($trailingRoot.status -eq 'planned')
    $f4.State["Azure:$($completion.gateway.resourceId)"].properties.gatewayUrl = 'https://gateway.azure-api.net'
    foreach ($invalidEndpoint in @(
        'https://gateway.azure-api.net',
        'https://gateway.azure-api.net/inference/bootstraplz01/v1/responses/extra',
        'https://gateway.azure-api.net/other/v1/responses',
        # A different landing zone's workload key on this shared gateway. This is
        # the collision case: before the route was workload-scoped, this string
        # was indistinguishable from our own and silently validated.
        'https://gateway.azure-api.net/inference/otherlz02/v1/responses',
        'https://gateway.azure-api.net/inference/v1/responses',
        'https://gateway.azure-api.net/inference/bootstraplz01/v1/../v1/responses',
        'https://gateway.azure-api.net/inference/bootstraplz01/v1/responses?redirect=elsewhere',
        'https://gateway.azure-api.net/inference/bootstraplz01/v1/responses#fragment',
        'https://gateway.azure-api.net.evil.test/inference/bootstraplz01/v1/responses',
        'https://someone@gateway.azure-api.net/inference/bootstraplz01/v1/responses',
        'http://gateway.azure-api.net/inference/bootstraplz01/v1/responses'
    )) {
        $invalid = Copy-Json $completion
        $invalid.gateway.endpoint = $invalidEndpoint
        $rejected = New-PlatformBootstrapPlan -ResolvedEnvironment $f4.Resolved -PlatformInputs $f4.Inputs -Stage Completion -Completion $invalid -Transport $f4.Transport
        Assert-Bootstrap "F4: reject endpoint spoof $invalidEndpoint" ($rejected.status -eq 'blocked' -and $rejected.blockers.code -contains 'COMPLETION_RESOURCE_STATE_INVALID')
    }
    $f4.State["Azure:$($completion.gateway.resourceId)"].id = "$($f4.Scope)/providers/Microsoft.ApiManagement/service/another"
    $wrongResource = New-PlatformBootstrapPlan -ResolvedEnvironment $f4.Resolved -PlatformInputs $f4.Inputs -Stage Completion -Completion $completion -Transport $f4.Transport
    Assert-Bootstrap 'F4: an observed APIM resource-ID mismatch cannot pass on URL alone' ($wrongResource.status -eq 'blocked')

    $f5 = New-ExternalRegistryAccessContext
    $profile = $f5.Resolved.profile
    $registry = $profile.application.registryResourceId
    Assert-Bootstrap 'F5: the real P1 resolver accepts the full external-registry fixture' ($f5.Resolved.configurationHash -match '^[a-f0-9]{64}$' -and -not $registry.StartsWith("$($f5.Scope)/", [StringComparison]::OrdinalIgnoreCase))
    $access = New-PlatformBootstrapPlan -ResolvedEnvironment $f5.Resolved -PlatformInputs $f5.Inputs -Stage Access -Transport $f5.Transport
    $push = @($access.operations | Where-Object kind -eq 'deploymentRegistryPushAssignment')
    $pull = @($access.operations | Where-Object kind -eq 'workloadRegistryPullAssignment')
    $roles = Get-Content -LiteralPath (Join-Path $root 'constants\roles.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Bootstrap 'F5: pre-main Access includes exact deployment AcrPush and workload AcrPull registry grants' (
        $access.status -eq 'planned' -and $push.Count -eq 1 -and $pull.Count -eq 1 -and
        $push[0].scope -eq $registry -and $pull[0].scope -eq $registry -and
        $push[0].body.properties.principalId -eq $profile.identities.deploy.principalId -and
        ($push[0].body.properties.roleDefinitionId -split '/')[-1] -eq $roles.AcrPush.guid -and
        ($pull[0].body.properties.roleDefinitionId -split '/')[-1] -eq $roles.AcrPull.guid
    )
    $null = Invoke-PlatformBootstrapPlan -Plan $access -ResolvedEnvironment $f5.Resolved -PlatformInputs $f5.Inputs -Execute -ApprovedPlanHash $access.planHash -Transport $f5.Transport -Confirm:$false
    $writeCount = $f5.Writes.Count
    $again = New-PlatformBootstrapPlan -ResolvedEnvironment $f5.Resolved -PlatformInputs $f5.Inputs -Stage Access -Transport $f5.Transport
    $null = Invoke-PlatformBootstrapPlan -Plan $again -ResolvedEnvironment $f5.Resolved -PlatformInputs $f5.Inputs -Execute -ApprovedPlanHash $again.planHash -Transport $f5.Transport -Confirm:$false
    Assert-Bootstrap 'F5: external-registry grants persist and approved reruns perform no extra writes' ($again.operations.Count -eq 0 -and $f5.Writes.Count -eq $writeCount -and @($f5.Writes | Where-Object { $_.path.StartsWith("$registry/providers/Microsoft.Authorization/roleAssignments/") }).Count -eq 2)
    $foundation = New-MockContext
    Add-PreparedFoundation $foundation
    $registryId = $foundation.Resolved.profile.application.registryResourceId
    $registryAssignments = "Azure:$registryId/providers/Microsoft.Authorization/roleAssignments"
    $foundation.State[$registryAssignments].value = @($foundation.State[$registryAssignments].value | Where-Object { $_.properties.principalId -ne $foundation.Resolved.profile.identities.deploy.principalId })
    Assert-Throws 'F5: foundation refuses image-import readiness without pre-main deployment AcrPush' {
        Assert-PreparedDeploymentFoundation -Profile $foundation.Resolved.profile -PlatformInputs $foundation.Inputs -Transport $foundation.Transport -NetworkProbe { param($Hostname, $ExpectedAddresses) @{ addresses = $ExpectedAddresses; tls = $true } }
    } 'AcrPush'
    $post = New-MockContext
    $postOutput = New-MockCompletion $post
    $postPlan = New-PlatformBootstrapPlan -ResolvedEnvironment $post.Resolved -PlatformInputs $post.Inputs -Stage Completion -Completion $postOutput -Transport $post.Transport
    Assert-Bootstrap 'F5: post-main Completion no longer creates deployment registry import authority' ($postPlan.status -eq 'planned' -and @($postPlan.operations | Where-Object kind -eq 'deploymentRegistryPushAssignment').Count -eq 0)
    $postRegistry = $post.Resolved.profile.application.registryResourceId
    $post.State["Azure:$postRegistry/providers/Microsoft.Authorization/roleAssignments"].value = @($post.State["Azure:$postRegistry/providers/Microsoft.Authorization/roleAssignments"].value | Where-Object { $_.properties.principalId -ne $post.Resolved.profile.identities.deploy.principalId })
    Assert-Throws 'F5: Completion cannot hide missing pre-main import authority by creating it late' { New-PlatformBootstrapPlan -ResolvedEnvironment $post.Resolved -PlatformInputs $post.Inputs -Stage Completion -Completion $postOutput -Transport $post.Transport } 'AcrPush'

    $json = ConvertFrom-BootstrapJson -Json '{"observedAt":"2026-09-16T00:00:00Z","amount":1.25}'
    Assert-Bootstrap 'Exported shared parser preserves ISO date strings and exact decimal values' ($json.observedAt -is [string] -and $json.amount -eq [decimal]1.25)
    $g = New-GovernanceMockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Stage Governance -Transport $g.Transport
    Assert-Bootstrap 'Governance planning uses P3 parameters and performs zero writes' ($g.Writes.Count -eq 0 -and $plan.governance.parameters.parameters.configuration.value.assignmentPrefix -eq $g.Resolved.profile.governance.assignmentPrefix)
    Assert-Bootstrap 'Governance plans exact subscription definitions and RG assignments/budget' ($plan.operations.Count -eq $g.Desired.resources.Count -and @($plan.operations | Where-Object { $_.kind -ne 'governanceResource' }).Count -eq 0)
    Assert-Throws 'Governance execution needs the exact inspected plan hash' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash ('0' * 64) -Transport $g.Transport -Confirm:$false } 'hash'
    $null = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $g.Transport -WhatIf
    Assert-Bootstrap 'Governance WhatIf never writes' ($g.Writes.Count -eq 0)
    $result = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $g.Transport -Confirm:$false
    Assert-Bootstrap 'Governance executes owned effects then passes the actual P3 readiness assertion' ($result.governanceReady -eq $true -and $g.Writes.Count -eq $g.Desired.resources.Count)
    $again = New-PlatformBootstrapPlan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Stage Governance -Transport $g.Transport
    Assert-Bootstrap 'Conforming installed governance is an idempotent no-op' ($again.operations.Count -eq 0)
    $budget = @($g.Desired.resources | Where-Object kind -eq 'budget')[0]
    $g.State[$budget.resourceId].properties.amount += 1
    Assert-Throws 'Governance drift invalidates a previously approved plan' { Invoke-PlatformBootstrapPlan -Plan $again -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $again.planHash -Transport $g.Transport -Confirm:$false } 'stale'
    $repair = New-PlatformBootstrapPlan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Stage Governance -Transport $g.Transport
    Assert-Bootstrap 'Budget drift produces only the exact owned repair and captured eTag' ($repair.operations.Count -eq 1 -and $repair.operations[0].governanceKind -eq 'budget' -and $repair.operations[0].body.eTag -eq $g.State[$budget.resourceId].eTag)
    $g.WriteStatus = 403
    Assert-Throws 'Governance API failures cannot become successful readiness' { Invoke-PlatformBootstrapPlan -Plan $repair -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $repair.planHash -Transport $g.Transport -Confirm:$false } '403'
    $g.WriteStatus = 200
    $g.DropCurrency = $true
    Assert-Throws 'Post-deployment missing observed billing currency fails the governance gate' { Invoke-PlatformBootstrapPlan -Plan $repair -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $repair.planHash -Transport $g.Transport -Confirm:$false } 'currency'
    $g.DropCurrency = $false
    $noCurrency = New-PlatformBootstrapPlan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Stage Governance -Transport $g.Transport
    Assert-Bootstrap 'A no-op plan is not a claim that live governance is ready' ($noCurrency.operations.Count -eq 0 -and -not $noCurrency.liveReady)
    Assert-Throws 'Even no-op Governance execution requires the P3 observed-currency gate' { Invoke-PlatformBootstrapPlan -Plan $noCurrency -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $noCurrency.planHash -Transport $g.Transport -Confirm:$false } 'currency'
    $g.State[$budget.resourceId].properties.currentSpend = @{ amount = 0; unit = $g.Inputs.governance.billingCurrency }
    $bound = New-PlatformBootstrapPlan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Stage Governance -Transport $g.Transport
    $bound.governance.sourceHash = '0' * 64
    $bound.Remove('planHash')
    $bound.planHash = Get-CanonicalHash $bound
    Assert-Throws 'Rehashed governance source substitution cannot bypass the inspected source binding' { Invoke-PlatformBootstrapPlan -Plan $bound -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Execute -ApprovedPlanHash $bound.planHash -Transport $g.Transport -Confirm:$false } 'stale'
    $request = New-BootstrapGovernanceRequest -Profile $g.Resolved.profile -Transport $g.Transport
    Assert-Throws 'Published P3 adapter prohibits writes even with valid credentials' { & $request PUT "https://management.azure.com$($g.Desired.scope)?api-version=2025-04-01" @{} @{} } 'GET'
    Assert-Throws 'Published P3 adapter rejects unrelated subscriptions' { & $request GET 'https://management.azure.com/subscriptions/ffffffff-ffff-4fff-8fff-ffffffffffff/resourceGroups/other?api-version=2025-04-01' $null @{} } 'scope'
    $assignment = @($g.Desired.resources | Where-Object kind -eq 'assignment')[0]
    $g.State[$assignment.resourceId].properties.metadata['ailz-owner'] = 'foreign-owner'
    Assert-Throws 'P3 ownership conflicts stop Governance planning before mutation' { New-PlatformBootstrapPlan -ResolvedEnvironment $g.Resolved -PlatformInputs $g.Inputs -Stage Governance -Transport $g.Transport } 'ownership'

    $c = New-MockContext
    Add-PreparedFoundation $c
    $probes = [Collections.Generic.List[string]]::new()
    $probe = {
        param($Hostname, $ExpectedAddresses)
        $probes.Add($Hostname)
        return @{ addresses = $ExpectedAddresses; tls = $true }
    }.GetNewClosure()
    $ready = Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport -NetworkProbe $probe
    Assert-Bootstrap 'A prepared spoke and registry are verified before any main deployment' ($ready -eq $true -and $c.Writes.Count -eq 0 -and $probes.Count -eq 2)
    Assert-Bootstrap 'Prepared profiles preserve the P1 existing-route/next-hop parameter mutex' (-not $c.Resolved.profile.parameters.ContainsKey('hubIntegrationEgressNextHopIp') -and $c.Inputs.network.egress.expectedNextHopIp -eq '10.250.0.4')
    Assert-Bootstrap 'Both registry login and data endpoints are probed' ($probes -contains 'bootstraptest.azurecr.io' -and $probes -contains 'bootstraptest.eastus2.data.azurecr.io')
    $c.Resolved.profile.parameters.useExistingVNet = $false
    Assert-Throws 'First deployment cannot create its own image-pull network in main' { Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport -NetworkProbe $probe } 'prepared|ExistingVNet'
    $c.Resolved.profile.parameters.useExistingVNet = $true
    $c.State["Azure:$($c.Resolved.profile.parameters.hubIntegrationHubVnetResourceId)/virtualNetworkPeerings"].value = @()
    Assert-Throws 'Missing reverse peering blocks before full provisioning' { Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport -NetworkProbe $probe } 'peering'
    Add-PreparedFoundation $c
    $c.State["Azure:$($c.Resolved.profile.application.registryResourceId)/providers/Microsoft.Authorization/roleAssignments"].value = @()
    Assert-Throws 'Missing workload AcrPull is a pre-main failure, not a completion TODO' { Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport -NetworkProbe $probe } 'AcrPull'
    Add-PreparedFoundation $c
    Assert-Throws 'Public or unrelated DNS resolution fails the prepared network gate' {
        Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport -NetworkProbe { param($Hostname, $ExpectedAddresses) @{ addresses = @('203.0.113.99'); tls = $true } }
    } 'DNS|private endpoint'
    Add-PreparedFoundation $c
    $nsgId = $c.Inputs.network.preparedSubnetNsgs[0].nsgResourceId
    $c.State["Azure:$nsgId"].properties.securityRules = @(@{ name = 'unapproved-change' })
    Assert-Throws 'Changed ACA subnet NSG policy blocks even when the runner can reach ACR' {
        Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport -NetworkProbe $probe
    } 'NSG'
    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Access -Transport $c.Transport
    $pull = @($plan.operations | Where-Object kind -eq 'workloadRegistryPullAssignment')
    Assert-Bootstrap 'Pre-main Access preparation assigns workload AcrPull at the existing registry' ($pull.Count -eq 1 -and $pull[0].scope -eq $c.Resolved.profile.application.registryResourceId)

    foreach ($environment in 'dev', 'test', 'prod') {
        $c = New-MockContext $environment
        Set-OwnedEnvironment $c "$environment-preview"
        Set-OwnedEnvironment $c $environment ($environment -ne 'dev')
        $c.State['GitHub:/repos/bootstrap-tests/landing-zone'].permissions.admin = $false
        $c.State.Remove('GitHub:/user')
        $c.State.Remove('GitHub:/orgs/bootstrap-tests/memberships/platform-admin')
        $c.State["GitHub:/repos/bootstrap-tests/landing-zone/environments/$environment/variables/AILZ_BOOTSTRAP_OWNER"].value = 'foreign-managed'
        $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main')
        $result = Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport
        Assert-Bootstrap "$environment selection returns only success using GitHub reads" ($result -is [bool] -and $result -and $c.Writes.Count -eq 0 -and @($c.Reads | Where-Object { $_ -notlike 'GitHub:*' }).Count -eq 0)
        Assert-Bootstrap "$environment selection does not require privileged operator/ownership reads" (@($c.Reads | Where-Object { $_ -match '/memberships/|/variables/|^GitHub:/user$' }).Count -eq 0)
    }
    $c = New-MockContext 'prod'
    Set-OwnedEnvironment $c 'prod-preview'
    Set-OwnedEnvironment $c 'prod' $true
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main')
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].protection_rules[0].prevent_self_review = $false
    Assert-Throws 'GitHub select gate rejects missing self-review protection instead of planning a fix' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport } 'ENVIRONMENT_NOT_READY'
    Assert-Bootstrap 'Failed select gate still has zero writes and Azure reads' ($c.Writes.Count -eq 0 -and @($c.Reads | Where-Object { $_ -like 'Azure:*' }).Count -eq 0)
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].protection_rules[0].prevent_self_review = $true
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].can_admins_bypass = $true
    Assert-Throws 'GitHub select gate rejects administrator bypass' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport } 'ADMIN_BYPASS_UNVERIFIED'
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].can_admins_bypass = $false
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment.yml@refs/heads/main')
    Assert-Throws 'Private-job restriction must name the reusable workflow, not the entry workflow' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport } 'RUNNER_WORKFLOW_RESTRICTION_INVALID'
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main')
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].network_configuration_id = 'unapproved-network'
    Assert-Throws 'GitHub select gate rejects an unapproved private-network binding' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport } 'RUNNER_NETWORK_INVALID'
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].network_configuration_id = 'configuration-1'
    $c.Overrides['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'] = @{ status = 403; body = @{}; etag = '' }
    Assert-Throws 'Missing GitHub org read permissions fail before scheduling the private pool' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport } '403'
    $c = New-MockContext
    Set-OwnedEnvironment $c 'dev-preview'
    Set-OwnedEnvironment $c 'dev'
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main')
    $c.Resolved.profile.github.runner.mode = 'existing-private'
    Assert-Throws 'Existing-private selection requires supplied admin-approved platform inputs' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $c.Transport } 'RUNNER_APPROVAL_REQUIRED'
    Assert-Bootstrap 'Missing self-hosted approval is rejected without calling Azure' (@($c.Reads | Where-Object { $_ -like 'Azure:*' }).Count -eq 0)
    Set-MockExistingPrivateRunner $c
    $c.Inputs.runner.approvedWorkflowRefs = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main')
    $success = Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport
    Assert-Bootstrap 'Approved existing-private pools pass GitHub scheduling without Azure proof claims' ($success -eq $true -and $c.Writes.Count -eq 0 -and @($c.Reads | Where-Object { $_ -like 'Azure:*' }).Count -eq 0)
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/runners'].runners[0].status = 'offline'
    Assert-Throws 'Offline existing-private pools cannot be scheduled' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport } 'RUNNER_CAPACITY_UNAVAILABLE'
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/runners'].runners[0].status = 'online'
    $c.Inputs.runner.machineBindings[0].runnerName = 'another-runner'
    Assert-Throws 'Approved machine evidence must bind the actual registered runner name and ID' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -Transport $c.Transport } 'RUNNER_MACHINE_BINDING_REQUIRED'
    $c = New-MockContext
    Add-PreparedFoundation $c
    Set-MockExistingPrivateRunner $c
    $success = Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -CurrentRunnerName 'private-agent' -Transport $c.Transport -NetworkProbe $probe
    Assert-Bootstrap 'Private foundation gate verifies the executing runner VM/NIC in Azure' ($success -eq $true -and $c.Reads -contains "Azure:$($c.Inputs.runner.machineBindings[0].virtualMachineResourceId)" -and $c.Reads -contains "Azure:$($c.Inputs.runner.machineBindings[0].networkInterfaceResourceId)")
    Assert-Throws 'A different executing runner cannot reuse another machine approval' { Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -CurrentRunnerName 'unapproved-runner' -Transport $c.Transport -NetworkProbe $probe } 'current runner|executing runner'
    $c.State["Azure:$($c.Inputs.runner.machineBindings[0].networkInterfaceResourceId)"].properties.ipConfigurations[0].properties.subnet.id = "$($c.Scope)/providers/Microsoft.Network/virtualNetworks/public/subnets/default"
    Assert-Throws 'Actual Azure NIC drift blocks before What-If even after GitHub scheduling passed' { Assert-PreparedDeploymentFoundation -Profile $c.Resolved.profile -PlatformInputs $c.Inputs -CurrentRunnerName 'private-agent' -Transport $c.Transport -NetworkProbe $probe } 'RUNNER_NETWORK_INVALID'

    $c = New-MockContext
    $env:BOOTSTRAP_TEST_CREDENTIAL_PRESENT = 'not-a-credential'
    try {
        $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
        Assert-Bootstrap 'Planning with credentials makes zero API writes' ($c.Writes.Count -eq 0)
        Assert-Bootstrap 'A dev plan creates separate preview and deployment environments' (@($plan.operations | Where-Object kind -eq 'environment').Count -eq 2)
        $result = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Transport $c.Transport
        Assert-Bootstrap 'Executor without Execute remains read-only' ($c.Writes.Count -eq 0 -and $result.status -eq 'notExecuted')
        Assert-Throws 'Execute requires the exact inspected hash' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash ('0' * 64) -Transport $c.Transport -Confirm:$false } 'hash'
        $null = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -WhatIf -Transport $c.Transport
        Assert-Bootstrap 'WhatIf never writes' ($c.Writes.Count -eq 0)
        $result = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
        Assert-Bootstrap 'Approved execution creates exact branch allowlists and ownership markers' ($c.Writes.Count -eq 6 -and $result.status -eq 'applied')
        $again = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
        Assert-Bootstrap 'Replanning after application produces no duplicate operations' ($again.operations.Count -eq 0)
        $null = Invoke-PlatformBootstrapPlan -Plan $again -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $again.planHash -Transport $c.Transport -Confirm:$false
        Assert-Bootstrap 'A second application makes no additional writes' ($c.Writes.Count -eq 6)
    }
    finally { Remove-Item Env:BOOTSTRAP_TEST_CREDENTIAL_PRESENT -ErrorAction SilentlyContinue }

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone'].visibility = 'public'
    Assert-Throws 'Changed remote state rejects the inspected plan before writes' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false } 'stale|changed|hash'
    Assert-Bootstrap 'Stale-plan rejection has no side effects' ($c.Writes.Count -eq 0)

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    $key = 'GitHub:/repos/bootstrap-tests/landing-zone'
    $c.Overrides[$key] = @{ status = 200; body = Copy-Json $c.State[$key]; etag = 'changed-etag-only' }
    Assert-Throws 'An ETag-only change invalidates approval before any write' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false } 'stale'
    Assert-Bootstrap 'ETag rejection makes zero writes' ($c.Writes.Count -eq 0)
    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    $plan.operations[0].body.wait_timer = 60
    $plan.Remove('planHash')
    $plan.planHash = Get-CanonicalHash $plan
    Assert-Throws 'A rehashed hand-edited operation cannot bypass regeneration from approved inputs' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false } 'stale'

    $c = New-MockContext
    $c.Resolved.profile.synthetic = $true
    Rehash-Resolved $c
    Assert-Throws 'Synthetic planning cannot fall through to live credential/network discovery' { New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -AllowSynthetic } 'mock transport'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport -AllowSynthetic
    Assert-Throws 'Synthetic plans cannot execute, even with their approved hash' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false } 'synthetic'

    $c = New-MockContext
    Set-OwnedEnvironment $c 'dev'
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/dev/variables/AILZ_BOOTSTRAP_OWNER'].value = 'another-owner'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'Foreign-owned environment is a blocking conflict' ($plan.status -eq 'blocked' -and ($plan.blockers.code -contains 'OWNERSHIP_CONFLICT'))
    Assert-Throws 'Blocked plans cannot apply otherwise valid operations' { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false } 'blocked'

    $c = New-MockContext 'prod'
    Set-OwnedEnvironment $c 'prod-preview'
    Set-OwnedEnvironment $c 'prod' $true
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].protection_rules[0].reviewers += @{ type = 'User'; reviewer = @{ id = 701 } }
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'Existing independent reviewers and protections are preserved' ($plan.status -eq 'planned' -and $plan.operations.Count -eq 0)
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].Remove('can_admins_bypass')
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'Unsupported admin-bypass API evidence blocks production readiness' ($plan.blockers.code -contains 'ADMIN_BYPASS_UNVERIFIED')
    $c = New-MockContext 'test'
    $c.Resolved.profile.github.environmentReviewers = @()
    Rehash-Resolved $c
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'Missing independent reviewers blocks test deployment' ($plan.blockers.code -contains 'REVIEWERS_REQUIRED')
    $c = New-MockContext 'prod'
    $c.State['GitHub:/orgs/bootstrap-tests'].plan.name = 'team'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'Actual private-repository entitlement must support required protections' ($plan.blockers.code -contains 'ENTITLEMENT_UNVERIFIED')

    $c = New-MockContext 'prod'
    Set-OwnedEnvironment $c 'prod-preview'
    Set-OwnedEnvironment $c 'prod' $true
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].protection_rules[0].prevent_self_review = $false
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'An owned protected environment is tightened to prevent self-review' ($plan.operations.Count -eq 1 -and $plan.operations[0].body.prevent_self_review)
    $null = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
    Assert-Bootstrap 'Protection tightening changes the actual environment, not only the plan' ($c.State['GitHub:/repos/bootstrap-tests/landing-zone/environments/prod'].protection_rules[0].prevent_self_review)

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    $c.FailWriteSuffix = '/variables'
    $partial = $null
    try { Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false | Out-Null }
    catch { $partial = $_ }
    Assert-Bootstrap 'A partial native/API failure stops execution and records possible effects' ($null -ne $partial -and $partial.Exception.Data['BootstrapEvidence'].partialEffectsPossible -and $partial.Exception.Data['BootstrapEvidence'].status -eq 'failed' -and $c.Writes.Count -eq 2)

    $c = New-MockContext
    $c.Overrides['GitHub:/repos/bootstrap-tests/landing-zone'] = @{ status = 403; body = @{}; etag = '' }
    Assert-Throws 'Privilege failures are explicit, never treated as an absent resource' { New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport } '403'

    $c = New-MockContext
    $c.State.Remove('GitHub:/repos/bootstrap-tests/landing-zone/git/ref/heads/main')
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Environments -Transport $c.Transport
    Assert-Bootstrap 'A nonexistent approved ref blocks readiness rather than creating an unusable allowlist' (@($plan.blockers | ForEach-Object { $_.code }) -contains 'PROTECTED_REF_UNVERIFIED')

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Federation -Transport $c.Transport
    Assert-Bootstrap 'Missing emitted OIDC evidence blocks all federation writes' ($plan.status -eq 'blocked' -and $plan.operations.Count -eq 0)
    Add-OidcEvidence $c
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Federation -Transport $c.Transport
    Assert-Bootstrap 'Observed immutable subjects bind two separate identity resources' ($plan.status -eq 'planned' -and $plan.operations.Count -eq 2 -and @($plan.operations.path | Sort-Object -Unique).Count -eq 2)
    $null = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
    $again = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Federation -Transport $c.Transport
    Assert-Bootstrap 'Federation execution persists exact trusts and reruns add none' ($again.operations.Count -eq 0 -and $c.Writes.Count -eq 2)
    $c.Inputs.oidcEvidence.preview.claims.sub = 'repo:bootstrap-tests/landing-zone:environment:dev-preview'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Federation -Transport $c.Transport
    Assert-Bootstrap 'Immutable subject missing numeric IDs blocks federation' ($plan.blockers.code -contains 'OIDC_EVIDENCE_INVALID')
    Add-OidcEvidence $c
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone/actions/oidc/customization/sub'] = @{ use_default = $false; include_claim_keys = @('repo') }
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Federation -Transport $c.Transport
    Assert-Bootstrap 'Observed custom template outside the frozen P1 contract is blocked, not rewritten' ($plan.blockers.code -contains 'OIDC_CUSTOM_TEMPLATE_UNSUPPORTED')

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Runner -Transport $c.Transport
    Assert-Bootstrap 'A verified private Linux group is reusable without mutation' ($plan.status -eq 'planned' -and $plan.operations.Count -eq 0 -and $c.Writes.Count -eq 0)
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].network_configuration_id = 'wrong-network'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Runner -Transport $c.Transport
    Assert-Bootstrap 'Unverified runner network blocks readiness' ($plan.blockers.code -contains 'RUNNER_NETWORK_INVALID')
    $c = New-MockContext
    $c.State['GitHub:/orgs/bootstrap-tests/memberships/platform-admin'].role = 'member'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Runner -Transport $c.Transport
    Assert-Bootstrap 'A non-admin attestation cannot approve an existing runner group' ($plan.blockers.code -contains 'RUNNER_ADMIN_UNVERIFIED')

    $c = New-MockContext
    $c.Resolved.profile.github.runner.mode = 'existing-private'
    $c.Resolved.profile.github.runner.Remove('networkConfigurationId')
    $c.Resolved.profile.github.runner.labels = @('self-hosted', 'Linux', 'X64')
    Rehash-Resolved $c
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].Remove('network_configuration_id')
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42/runners'] = @{ total_count = 1; runners = @(@{
        id = 99; name = 'private-agent'; os = 'linux'; status = 'online'; busy = $false
        labels = @(@{ name = 'self-hosted' }, @{ name = 'Linux' }, @{ name = 'X64' })
    }) }
    $c.State["Azure:$($c.Resolved.profile.github.runner.subnetResourceId)"].properties.delegations = @()
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Runner -Transport $c.Transport
    Assert-Bootstrap 'An unrelated private subnet does not prove a self-hosted group is private' (@($plan.blockers | ForEach-Object { $_.code }) -contains 'RUNNER_MACHINE_BINDING_REQUIRED')
    $vmId = "$($c.Scope)/providers/Microsoft.Compute/virtualMachines/private-agent"
    $nicId = "$($c.Scope)/providers/Microsoft.Network/networkInterfaces/private-agent"
    $c.Inputs.runner.machineBindings = @(@{ runnerId = 99; runnerName = 'private-agent'; virtualMachineResourceId = $vmId; networkInterfaceResourceId = $nicId })
    $c.State["Azure:$vmId"] = @{ id = $vmId; properties = @{ storageProfile = @{ osDisk = @{ osType = 'Linux' } }; networkProfile = @{ networkInterfaces = @(@{ id = $nicId }) } } }
    $c.State["Azure:$nicId"] = @{ id = $nicId; properties = @{ ipConfigurations = @(@{ properties = @{ subnet = @{ id = $c.Resolved.profile.github.runner.subnetResourceId } } }) } }
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Runner -Transport $c.Transport
    Assert-Bootstrap 'Existing private runners require real VM/NIC/subnet bindings and org-admin approval' ($plan.status -eq 'planned' -and $plan.operations.Count -eq 0)

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Access -Transport $c.Transport
    $preview = @($plan.operations | Where-Object kind -eq 'previewRole')[0]
    $actions = $preview.body.properties.permissions[0].actions
    Assert-Bootstrap 'Preview has What-If and validation actions but no ordinary write' ($actions -contains 'Microsoft.Resources/deployments/whatIf/action' -and $actions -contains 'Microsoft.Resources/deployments/validate/action' -and @($actions | Where-Object { $_ -match '/write$|^\*$' }).Count -eq 0)
    Assert-Bootstrap 'Preview role is assignable only at the workload resource group' ($preview.body.properties.assignableScopes.Count -eq 1 -and $preview.body.properties.assignableScopes[0] -eq $c.Scope)
    $delegation = @($plan.operations | Where-Object kind -eq 'deploymentRoleDelegation')[0]
    Assert-Bootstrap 'Role delegation constrains both assignment and deletion to approved roles' ($delegation.body.properties.condition -match '@Request.*RoleDefinitionId' -and $delegation.body.properties.condition -match '@Resource.*RoleDefinitionId' -and $delegation.body.properties.conditionVersion -eq '2.0')
    Assert-Bootstrap 'Deployment access never grants subscription-wide administration' (@($plan.operations | Where-Object {
        $_.kind -match 'Assignment|Delegation' -and
        $_.body.properties.principalId -in @($c.Resolved.profile.identities.preview.principalId, $c.Resolved.profile.identities.deploy.principalId) -and
        $_.scope -ne $c.Scope -and
        -not ($_.kind -eq 'deploymentRegistryPushAssignment' -and $_.scope -eq $c.Resolved.profile.application.registryResourceId -and
            $_.body.properties.principalId -eq $c.Resolved.profile.identities.deploy.principalId -and
            ($_.body.properties.roleDefinitionId -split '/')[-1] -eq $roles.AcrPush.guid)
    }).Count -eq 0)
    $null = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
    $again = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Access -Transport $c.Transport
    Assert-Bootstrap 'Scoped role creation/assignments are idempotent after actual mocked writes' ($again.operations.Count -eq 0 -and $c.Writes.Count -eq 6)

    $c = New-MockContext
    Add-MockNetwork $c
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Network -Transport $c.Transport
    Assert-Bootstrap 'Network plan creates only a scoped reverse peering and BYO DNS link' ($plan.status -eq 'planned' -and $plan.operations.Count -eq 2 -and @($plan.operations | Where-Object kind -notin @('reversePeering', 'dnsLink')).Count -eq 0)
    $peering = @($plan.operations | Where-Object kind -eq 'reversePeering')[0]
    $link = @($plan.operations | Where-Object kind -eq 'dnsLink')[0]
    Assert-Bootstrap 'Reverse peering points to the exact spoke and allows approved forwarded traffic' ($peering.body.properties.remoteVirtualNetwork.id -eq $c.Inputs.network.spokeVnetResourceId -and $peering.body.properties.allowForwardedTraffic)
    Assert-Bootstrap 'BYO DNS link disables registration and never creates a competing zone' (-not $link.body.properties.registrationEnabled -and $link.path -match '/privateDnsZones/[^/]+/virtualNetworkLinks/')
    $result = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
    $again = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Network -Transport $c.Transport
    Assert-Bootstrap 'Connected peering and completed DNS link are observed before success' ($result.status -eq 'applied' -and $again.operations.Count -eq 0)
    Assert-Bootstrap 'DNS creation uses the supported create-only precondition' (@($c.Writes | Where-Object { $_.path -match '/virtualNetworkLinks/' -and $_.headers['If-None-Match'] -eq '*' }).Count -eq 1)
    $c = New-MockContext
    Add-MockNetwork $c
    $c.State["Azure:$($c.Inputs.network.egress.routeTableResourceId)"].properties.routes[0].properties.nextHopIpAddress = '10.250.0.99'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Network -Transport $c.Transport
    Assert-Bootstrap 'Unapproved egress state blocks network changes' ($plan.blockers.code -contains 'EGRESS_INVALID' -and $c.Writes.Count -eq 0)
    $c = New-MockContext
    Add-MockNetwork $c
    $c.State["Azure:$($c.Inputs.network.egress.subnetResourceIds[0])"].properties.routeTable.id = "$($c.Scope)/providers/Microsoft.Network/routeTables/other"
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Network -Transport $c.Transport
    Assert-Bootstrap 'Each explicitly approved subnet must actually use its approved egress route table' ($plan.blockers.code -contains 'EGRESS_INVALID')

    $c = New-MockContext
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Completion -Transport $c.Transport
    Assert-Bootstrap 'Completion RBAC is an explicit blocked stage until actual outputs exist' ($plan.blockers.code -contains 'COMPLETION_OUTPUT_REQUIRED')
    $completion = New-MockCompletion $c
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Completion -Completion $completion -Transport $c.Transport
    Assert-Bootstrap 'Actual completion resource bindings produce scoped RBAC operations' ($plan.status -eq 'planned' -and $plan.operations.Count -gt 0)
    $inference = @($plan.operations | Where-Object kind -eq 'gatewayInferenceAssignment')
    Assert-Bootstrap 'Only the observed gateway identity receives normal backend inference access' ($inference.Count -eq 1 -and $inference[0].body.properties.principalId -eq '99999999-9999-4999-8999-999999999999' -and $inference[0].scope -eq $completion.gateway.backendResourceId)
    $normalGrants = @($plan.operations | Where-Object { $_.body.properties.principalId -eq $c.Resolved.profile.identities.workload.principalId })
    $roles = Get-Content -LiteralPath (Join-Path $root 'constants\roles.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Bootstrap 'Workload grants are limited to App Configuration reader and ACR pull' (@($normalGrants | Where-Object { ($_.body.properties.roleDefinitionId -split '/')[-1] -notin @($roles.AppConfigurationDataReader.guid, $roles.AcrPull.guid) }).Count -eq 0)
    $null = Invoke-PlatformBootstrapPlan -Plan $plan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Completion $completion -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
    $again = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Completion -Completion $completion -Transport $c.Transport
    Assert-Bootstrap 'Resource-bound completion RBAC reruns without duplicate grants' ($again.operations.Count -eq 0)
    $completion.gateway.backendResourceId = '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/foreign/providers/Microsoft.CognitiveServices/accounts/foreign'
    Assert-Throws 'Completion cannot redirect RBAC into a foreign subscription' { New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Completion -Completion $completion -Transport $c.Transport } 'scope|binding|Completion'
    $c = New-MockContext
    $completion = New-MockCompletion $c
    $c.State["Azure:$($completion.gateway.resourceId)"].identity.type = 'SystemAssigned, UserAssigned'
    $plan = New-PlatformBootstrapPlan -ResolvedEnvironment $c.Resolved -PlatformInputs $c.Inputs -Stage Completion -Completion $completion -Transport $c.Transport
    Assert-Bootstrap 'An ambiguous multi-identity gateway is not guessed to use its system identity' (@($plan.blockers | ForEach-Object { $_.code }) -contains 'GATEWAY_IDENTITY_UNVERIFIED')

    $c = New-MockContext
    $c.Inputs.foundation = @{ environment = 'dev'; azure = Copy-Json $c.Resolved.profile.azure; identityNames = @{ preview = 'new-preview'; deploy = 'new-deploy'; workload = 'new-workload' } }
    $plan = New-BootstrapFoundationPlan -PlatformInputs $c.Inputs -Transport $c.Transport
    Assert-Bootstrap 'Foundation can be planned before a completed environment profile exists' ($plan.status -eq 'planned' -and $plan.operations.Count -eq 3 -and $c.Writes.Count -eq 0)
    Assert-Bootstrap 'Foundation never invents deployed client or principal IDs' (@($plan.operations | Where-Object { (ConvertTo-CanonicalJson $_.body) -match 'clientId|principalId' }).Count -eq 0)
    $result = Invoke-PlatformBootstrapPlan -Plan $plan -PlatformInputs $c.Inputs -Execute -ApprovedPlanHash $plan.planHash -Transport $c.Transport -Confirm:$false
    Assert-Bootstrap 'Foundation outputs contain only IDs returned by the resource API' ($result.outputs.identities.preview.clientId -eq $c.State["Azure:$($result.outputs.identities.preview.resourceId)"].properties.clientId -and $result.outputs.identities.preview.principalId -ne $result.outputs.identities.deploy.principalId)
    $again = New-BootstrapFoundationPlan -PlatformInputs $c.Inputs -Transport $c.Transport
    Assert-Bootstrap 'A repeated foundation plan does not recreate identities' ($again.operations.Count -eq 0)

    $c = New-MockContext
    Add-OidcEvidence $c
    $claims = Copy-Json $c.Inputs.oidcEvidence.preview.claims
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $claims.iat = $now; $claims.nbf = $now; $claims.exp = $now + 300
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $publicKey = $rsa.ExportParameters($false)
        $jwks = @{ keys = @(@{ kty = 'RSA'; kid = 'test-key'; alg = 'RS256'; use = 'sig'; n = ConvertTo-TestBase64Url $publicKey.Modulus; e = ConvertTo-TestBase64Url $publicKey.Exponent }) }
        $expected = $c.Inputs.oidcEvidence.preview.claims
        $token = New-SignedTestToken $rsa $claims
        $safe = ConvertFrom-VerifiedGitHubOidcToken -Token $token -Jwks $jwks -ExpectedClaims $expected -Now $now
        Assert-Bootstrap 'Verified OIDC extraction returns only approved nonsecret claims' ($safe.sub -eq $expected.sub -and (ConvertTo-CanonicalJson $safe) -notmatch [regex]::Escape($token))
        $parts = $token.Split('.')
        $replacement = if ($parts[2][0] -ceq 'A') { 'B' } else { 'A' }
        $tampered = "$($parts[0]).$($parts[1]).$replacement$($parts[2].Substring(1))"
        Assert-Throws 'OIDC signature failure is rejected' { ConvertFrom-VerifiedGitHubOidcToken -Token $tampered -Jwks $jwks -ExpectedClaims $expected -Now $now } 'signature'
        $wrongContext = Copy-Json $expected
        $wrongContext.repository_id = '999'
        Assert-Throws 'A valid signature does not excuse a wrong repository/run context' { ConvertFrom-VerifiedGitHubOidcToken -Token $token -Jwks $jwks -ExpectedClaims $wrongContext -Now $now } 'claim|context'
        $claims.exp = $now - 1
        $expired = New-SignedTestToken $rsa $claims
        Assert-Throws 'Expired OIDC credentials are never accepted as evidence' { ConvertFrom-VerifiedGitHubOidcToken -Token $expired -Jwks $jwks -ExpectedClaims $expected -Now $now } 'expir|valid'
    }
    finally { $rsa.Dispose() }

    $c = New-MockContext
    Add-OidcEvidence $c
    $claims = Copy-Json $c.Inputs.oidcEvidence.preview.claims
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $claims.iat = $now; $claims.nbf = $now; $claims.exp = $now + 300
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $captureRoot = Join-Path ([IO.Path]::GetTempPath()) ("bootstrap-oidc-capture-{0}" -f [guid]::NewGuid())
    [IO.Directory]::CreateDirectory($captureRoot) | Out-Null
    $captureFile = Join-Path $captureRoot 'claims.json'
    $captureLog = Join-Path $captureRoot 'capture.log'
    $environment = @{
        GITHUB_ACTIONS = 'true'; GITHUB_SERVER_URL = 'https://github.com'; GITHUB_EVENT_NAME = 'workflow_dispatch'
        GITHUB_REPOSITORY = $claims.repository; GITHUB_REPOSITORY_ID = $claims.repository_id; GITHUB_REPOSITORY_OWNER_ID = $claims.repository_owner_id
        GITHUB_REF = $claims.ref; GITHUB_WORKFLOW_REF = $claims.workflow_ref; GITHUB_WORKFLOW_SHA = $claims.workflow_sha
        GITHUB_RUN_ID = $claims.run_id; GITHUB_RUN_ATTEMPT = $claims.run_attempt
        ACTIONS_ID_TOKEN_REQUEST_URL = 'https://pipelines.actions.githubusercontent.com/fixture/oidctoken?api-version=2.0'
        ACTIONS_ID_TOKEN_REQUEST_TOKEN = "fixture-request-$([guid]::NewGuid().ToString('N'))"
    }
    $previousEnvironment = @{}
    try {
        $key = $rsa.ExportParameters($false)
        $capture = @{
            Profile = $c.Resolved.profile; Credential = $environment.ACTIONS_ID_TOKEN_REQUEST_TOKEN
            Token = New-SignedTestToken $rsa $claims
            Jwks = @{ keys = @(@{ kty = 'RSA'; kid = 'test-key'; alg = 'RS256'; use = 'sig'; n = ConvertTo-TestBase64Url $key.Modulus; e = ConvertTo-TestBase64Url $key.Exponent }) }
            Requests = 0; TokenRequests = 0; HeaderMatched = $false; AudienceMatched = $false
        }
        foreach ($name in $environment.Keys) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
        }
        & {
            param($Capture, $ScriptPath, $OutputPath, $LogPath)
            function Import-Module {
                [CmdletBinding()] param([string]$Name)
                if ((Split-Path $Name -Leaf) -notin @('Environment.psm1', 'Bootstrap.psm1')) { throw 'Unexpected module in capture fixture.' }
            }
            function Read-EnvironmentProfile { param([string]$Path) return $Capture.Profile }
            function Invoke-CheckedNative { throw 'Native commands are forbidden in the OIDC capture fixture.' }
            function Invoke-WebRequest { throw 'Unmocked HTTP is forbidden in the OIDC capture fixture.' }
            function Invoke-RestMethod {
                [CmdletBinding()]
                param([uri]$Uri, [string]$Method, $Headers, [int]$MaximumRedirection, [int]$TimeoutSec)
                $Capture.Requests++
                if ($Method -ine 'Get') { throw 'Only GET is permitted in the OIDC capture fixture.' }
                if ($Uri.AbsoluteUri -eq 'https://token.actions.githubusercontent.com/.well-known/openid-configuration') {
                    return @{ issuer = 'https://token.actions.githubusercontent.com'; jwks_uri = 'https://token.actions.githubusercontent.com/.well-known/jwks' }
                }
                if ($Uri.AbsoluteUri -eq 'https://token.actions.githubusercontent.com/.well-known/jwks') { return $Capture.Jwks }
                if ($Uri.Host -eq 'pipelines.actions.githubusercontent.com' -and $Uri.AbsolutePath -eq '/fixture/oidctoken') {
                    $Capture.TokenRequests++
                    $Capture.HeaderMatched = [string]::Equals([string]$Headers['Authorization'], ('Bearer ' + $Capture.Credential), [StringComparison]::Ordinal)
                    $Capture.AudienceMatched = [uri]::UnescapeDataString($Uri.Query) -match 'audience=api://AzureADTokenExchange'
                    if (-not $Capture.HeaderMatched -or -not $Capture.AudienceMatched) { throw 'The capture request did not match its in-memory authorization/audience contract.' }
                    return @{ value = $Capture.Token }
                }
                throw 'Unexpected HTTP target in the OIDC capture fixture.'
            }
            $global:LASTEXITCODE = 0
            & $ScriptPath -ProfilePath 'mock-profile-not-read.json' -Purpose preview -ExpectedWorkflowRef $env:GITHUB_WORKFLOW_REF -ExpectedWorkflowSha $env:GITHUB_WORKFLOW_SHA -OutputPath $OutputPath *> $LogPath
        } $capture (Join-Path $root 'scripts\github\Export-OidcClaims.ps1') $captureFile $captureLog
        Assert-Bootstrap 'Actual capture constructs Authorization from its in-memory request credential' ($capture.Requests -eq 3 -and $capture.TokenRequests -eq 1 -and $capture.HeaderMatched -and $capture.AudienceMatched)
        Assert-Bootstrap 'Actual capture produces verified claim evidence rather than the JWT' ((Test-Path -LiteralPath $captureFile) -and (Read-BootstrapJsonFile $captureFile).claims.sub -eq $claims.sub)
        $persisted = [IO.File]::ReadAllText($captureFile) + [IO.File]::ReadAllText($captureLog)
        Assert-Bootstrap 'Capture output and log never contain the bearer credential or JWT' (-not $persisted.Contains($capture.Credential) -and -not $persisted.Contains($capture.Token))
    }
    finally {
        foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
        $rsa.Dispose()
        foreach ($file in @($captureFile, $captureLog)) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
        [IO.Directory]::Delete($captureRoot)
    }

    $c = New-MockContext 'prod'
    Set-OwnedEnvironment $c 'prod-preview'
    Set-OwnedEnvironment $c 'prod' $true
    $c.State['GitHub:/repos/bootstrap-tests/landing-zone'].Remove('permissions')
    $c.State.Remove('GitHub:/user')
    $c.State.Remove('GitHub:/orgs/bootstrap-tests/memberships/platform-admin')
    $c.State['GitHub:/orgs/bootstrap-tests/actions/runner-groups/42'].selected_workflows = @('bootstrap-tests/landing-zone/.github/workflows/deploy-environment-reusable.yml@refs/heads/main')
    $app = @{ Token = "fixture-installation-$([guid]::NewGuid().ToString('N'))"; Commands = [Collections.Generic.List[string]]::new(); HeaderMatched = $true }
    $appNative = {
        param($Command, $Arguments)
        $app.Commands.Add($Command)
        if ($Command -ne 'gh' -or ($Arguments -join ' ') -ne 'auth token --hostname github.com') { throw 'The installation-token fixture permits no human login or Azure command.' }
        return $app.Token
    }.GetNewClosure()
    $appHttp = {
        param($Arguments)
        $app.HeaderMatched = $app.HeaderMatched -and [string]::Equals([string]$Arguments.Headers.Authorization, ('Bearer ' + $app.Token), [StringComparison]::Ordinal)
        $uri = [uri]$Arguments.Uri
        $response = & $c.Transport @{ provider = 'GitHub'; method = $Arguments.Method; path = $uri.PathAndQuery; body = $null; headers = @{} }
        return @{ StatusCode = $response.status; Headers = @{}; Content = ConvertTo-CanonicalJson $response.body }
    }.GetNewClosure()
    $appTransport = & (Get-Module Bootstrap) {
        param($GitHub, $Native, $Http)
        New-BootstrapTransport -Azure @{} -GitHub $GitHub -Native $Native -Http $Http
    } $c.Inputs.github $appNative $appHttp
    $success = Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $appTransport
    Assert-Bootstrap 'Read-only installation-token semantics need no human user or admin-membership API' ($success -eq $true -and $app.HeaderMatched -and $app.Commands.Count -eq 1 -and $app.Commands[0] -eq 'gh' -and @($c.Reads | Where-Object { $_ -match '/memberships/|^GitHub:/user$|^Azure:' }).Count -eq 0 -and $c.Writes.Count -eq 0)
    $c.Overrides['GitHub:/orgs/bootstrap-tests'] = @{ status = 403; body = @{}; etag = '' }
    Assert-Throws 'Insufficient installation-token org visibility fails closed' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $appTransport } '403'
    $c.Overrides.Remove('GitHub:/orgs/bootstrap-tests')
    $c.State['GitHub:/orgs/bootstrap-tests'].Remove('plan')
    Assert-Throws 'An installation token without real entitlement evidence cannot pass on declarations' { Assert-GitHubBootstrapReadiness -Profile $c.Resolved.profile -Transport $appTransport } 'ENTITLEMENT_UNVERIFIED'

    $c = New-MockContext
    $nativeCalls = [Collections.Generic.List[object]]::new()
    $httpCalls = [Collections.Generic.List[object]]::new()
    $native = {
        param($Command, $Arguments)
        $nativeCalls.Add(@{ command = $Command; arguments = $Arguments })
        if ($Command -eq 'gh') { return 'mock-gh-authentication-value' }
        if (($Arguments -join ' ') -match '^account show ') { return ConvertTo-CanonicalJson @{ id = $c.Resolved.profile.azure.subscriptionId; tenantId = $c.Resolved.profile.azure.tenantId } }
        if (($Arguments -join ' ') -match '^account get-access-token ') { return 'mock-azure-authentication-value' }
        throw 'Unexpected mock native command.'
    }.GetNewClosure()
    $http = {
        param($Arguments)
        $httpCalls.Add(@{ method = $Arguments.Method; uri = [string]$Arguments.Uri; authorizationPresent = $Arguments.Headers.ContainsKey('Authorization') })
        return @{ StatusCode = 200; Headers = @{}; Content = '{"id":123456,"created_at":"2026-09-16T00:00:00Z"}' }
    }.GetNewClosure()
    $adapter = & (Get-Module Bootstrap) {
        param($Azure, $GitHub, $Native, $Http)
        New-BootstrapTransport -Azure $Azure -GitHub $GitHub -Native $Native -Http $Http
    } $c.Resolved.profile.azure $c.Inputs.github $native $http
    $response = & $adapter @{ provider = 'GitHub'; method = 'GET'; path = '/repos/bootstrap-tests/landing-zone'; body = $null; headers = @{} }
    $null = & $adapter @{ provider = 'Azure'; method = 'GET'; path = "$($c.Scope)?api-version=2022-09-01"; body = $null; headers = @{} }
    Assert-Bootstrap 'Native HTTP adapter is executable with isolated auth and never returns credentials' ($nativeCalls.Count -eq 3 -and $httpCalls.Count -eq 2 -and @($httpCalls | Where-Object method -ne 'GET').Count -eq 0 -and (ConvertTo-CanonicalJson $response) -notmatch 'mock-.*authentication')
    Assert-Bootstrap 'HTTP JSON dates remain canonical strings, not runtime DateTime objects' ($response.body.created_at -is [string])
    Assert-Throws 'Native adapter rejects a foreign API host before using credentials' { & $adapter @{ provider = 'Azure'; method = 'GET'; path = 'https://untrusted.invalid'; body = $null; headers = @{} } } 'target'
    if ($IsWindows) {
        $batch = Join-Path ([IO.Path]::GetTempPath()) ("bootstrap native {0}.cmd" -f [guid]::NewGuid())
        try {
            [IO.File]::WriteAllText($batch, "@echo off`r`nif not `"%~1`"==`"safe argument`" exit /b 19`r`nexit /b 23`r`n")
            Assert-Throws 'Windows batch CLI nonzero is propagated through checked native execution' {
                & (Get-Module Bootstrap) { param($Path) Invoke-BootstrapNative -Command $Path -Arguments @('safe argument') } $batch
            } '23'
            Assert-Throws 'Windows batch expansion metacharacters are rejected before invocation' {
                & (Get-Module Bootstrap) { param($Path) Invoke-BootstrapNative -Command $Path -Arguments @('%UNTRUSTED%') } $batch
            } 'metacharacter'
        }
        finally { [IO.File]::Delete($batch) }
    }

    Assert-Throws 'Checked native nonzero is propagated without stderr secrets' { Invoke-CheckedNative -Command pwsh -Arguments @('-NoProfile', '-Command', '[Console]::Error.WriteLine("private-test-output"); exit 23') } '23'
    Assert-Throws 'Unknown platform input fields fail closed' { Read-PlatformInputs -Json '{"schemaVersion":1,"owner":"test","unknown":true}' } 'unknown|schema|Unsupported'
    $artifact = Join-Path ([IO.Path]::GetTempPath()) ("bootstrap-artifact-{0}.json" -f [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($artifact, '{"schemaVersion":1,"password":"fixture-private-value"}')
        Assert-Throws 'Credential-bearing saved artifacts are rejected before prompts or output' { Read-BootstrapJsonFile -Path $artifact } 'credential|secret'
    }
    finally { [IO.File]::Delete($artifact) }
    $c = New-MockContext
    $c.Inputs.foundation = @{ environment = 'dev'; azure = Copy-Json $c.Resolved.profile.azure; identityNames = @{ preview = 'new-preview'; deploy = 'new-deploy'; workload = 'new-workload' } }
    $identityId = "$($c.Scope)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/new-preview"
    $c.State["Azure:$identityId"] = @{
        id = $identityId; location = 'eastus2'
        tags = @{ 'ailz-bootstrap-owner' = 'bootstrap-tests:foundation:dev'; 'ailz-bootstrap-purpose' = 'wrong'; clientSecret = 'fixture-private-value' }
    }
    Assert-Throws 'Remote credential-like tags cannot leak into a persisted mutation plan' { New-BootstrapFoundationPlan -PlatformInputs $c.Inputs -Transport $c.Transport } 'credential|secret'
}
catch {
    $script:failed++
    Write-Error $_ -ErrorAction Continue
    Write-Host $_.ScriptStackTrace
}
Write-Host "Bootstrap assertions passed: $script:passed; failures: $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
