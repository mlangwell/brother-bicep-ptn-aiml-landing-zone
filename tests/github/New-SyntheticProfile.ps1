#Requires -Version 7.0
<#
.SYNOPSIS
Creates an unmistakably synthetic, offline-only environment profile.
.DESCRIPTION
The returned dictionary always has synthetic=true. Its identities, addresses,
owners, prices and release provenance are test data, never deployment defaults.
Use -Path to also write the fixture as JSON. No external commands are invoked.
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment = 'dev',
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$subscription = '00000000-0000-4000-8000-000000000001'
$scope = "/subscriptions/$subscription/resourceGroups/rg-synthetic-$Environment-never-deploy"
$hubScope = "/subscriptions/$subscription/resourceGroups/rg-synthetic-hub-never-deploy"
$profile = @{
    schemaVersion = 1
    environment = $Environment
    synthetic = $true
    azure = @{
        tenantId = '00000000-0000-4000-8000-000000000002'
        subscriptionId = $subscription
        resourceGroup = "rg-synthetic-$Environment-never-deploy"
        location = 'eastus2'
    }
    github = @{
        repository = 'synthetic-never-deploy/synthetic-landing-zone'
        repositoryId = 123456789
        ownerId = 987654321
        protectedRef = 'refs/heads/synthetic-protected'
        offering = 'enterprise-cloud'
        visibility = 'private'
        environmentReviewers = @(@{ type = 'Team'; id = 12345 })
        oidc = @{
            issuer = 'https://token.actions.githubusercontent.com'
            audience = 'api://AzureADTokenExchange'
            subjectFormat = 'immutable'
            previewSubject = "repo:synthetic-never-deploy@987654321/synthetic-landing-zone@123456789:environment:$Environment-preview"
            deploySubject = "repo:synthetic-never-deploy@987654321/synthetic-landing-zone@123456789:environment:$Environment"
        }
        runner = @{
            mode = 'github-hosted-private'
            group = 'synthetic-private-runners'
            labels = @('synthetic-private-linux')
            subnetResourceId = "$hubScope/providers/Microsoft.Network/virtualNetworks/synthetic-hub/subnets/synthetic-github-runners"
            networkConfigurationId = 'synthetic-network-configuration'
        }
    }
    identities = @{
        preview = @{
            clientId = '00000000-0000-4000-8000-000000000011'
            principalId = '00000000-0000-4000-8000-000000000012'
            resourceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-preview"
        }
        deploy = @{
            clientId = '00000000-0000-4000-8000-000000000021'
            principalId = '00000000-0000-4000-8000-000000000022'
            resourceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-deploy"
        }
        workload = @{
            clientId = '00000000-0000-4000-8000-000000000031'
            principalId = '00000000-0000-4000-8000-000000000032'
            resourceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-workload"
        }
        developerObjectIds = @('00000000-0000-4000-8000-000000000041')
        developerGroupObjectIds = @('00000000-0000-4000-8000-000000000042')
    }
    parameters = @{
        deploymentMode = 'ailz-integrated'
        deploymentTags = @{ environment = $Environment; owner = 'synthetic-owner'; purpose = 'offline-test-only' }
        networkIsolation = $true
        allowedIpRanges = @()
        policyManagedPrivateDns = $false
        useExistingVNet = $false
        sideBySideDeploy = $true
        deploySubnets = $true
        deployNsgs = $true
        deployAzureFirewall = $false
        deployAiFoundry = $true
        deployAfProject = $true
        deployAiFoundrySubnet = $false
        deployAAfAgentSvc = $false
        aiFoundryDisableLocalAuth = $true
        deployGroundingWithBing = $false
        prepareHostedAgent = $false
        deployHostedAgent = $false
        enableAgenticRetrieval = $false
        deployAppConfig = $true
        appRuntimeConfigurationMode = 'appConfig'
        deployKeyVault = $false
        deployVmKeyVault = $false
        deployLogAnalytics = $true
        deployAppInsights = $true
        enablePrivateLogAnalytics = $true
        deploySearchService = $false
        deploySpeechService = $false
        deployStorageAccount = $false
        deployCosmosDb = $false
        enableCosmosAnalyticalStorage = $false
        deployContainerApps = $true
        deployContainerEnv = $true
        deployContainerRegistry = $false
        deployAcrTaskAgentPool = $false
        deployVM = $false
        deployJumpbox = $false
        deployBastion = $false
        deployNatGateway = $false
        deploySoftware = $false
        useUAI = $false
        useCAppAPIKey = $false
        useZoneRedundancy = $false
        publicIngress = @{ enabled = $false }
        aiFoundryProjectName = 'synthetic-project'
        vnetName = 'synthetic-spoke'
        vnetAddressPrefixes = @('10.220.0.0/16')
        agentSubnetName = 'synthetic-agents'
        agentSubnetPrefix = '10.220.0.0/24'
        acaEnvironmentSubnetName = 'synthetic-apps'
        acaEnvironmentSubnetPrefix = '10.220.1.0/24'
        peSubnetName = 'synthetic-private-endpoints'
        peSubnetPrefix = '10.220.2.0/26'
        azureBastionSubnetName = 'AzureBastionSubnet'
        azureBastionSubnetPrefix = '10.220.2.64/26'
        azureFirewallSubnetName = 'AzureFirewallSubnet'
        azureFirewallSubnetPrefix = '10.220.2.128/26'
        gatewaySubnetName = 'synthetic-network-gateway'
        gatewaySubnetPrefix = '10.220.2.192/26'
        azureAppGatewaySubnetName = 'synthetic-app-gateway'
        azureAppGatewaySubnetPrefix = '10.220.3.0/27'
        jumpboxSubnetName = 'synthetic-jumpbox'
        jumpboxSubnetPrefix = '10.220.3.64/27'
        devopsBuildAgentsSubnetName = 'synthetic-build-agents'
        devopsBuildAgentsSubnetPrefix = '10.220.3.96/27'
        hubIntegrationHubVnetResourceId = "$hubScope/providers/Microsoft.Network/virtualNetworks/synthetic-hub"
        hubIntegrationEgressNextHopIp = '10.221.0.4'
        hubIntegrationCreateHubPeering = $true
        hubIntegrationPeeringAllowGatewayTransit = $false
        hubIntegrationPeeringUseRemoteGateways = $false
        existingPrivateDnsZoneCogSvcsResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
        existingPrivateDnsZoneOpenAiResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
        existingPrivateDnsZoneAiServicesResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com"
        existingPrivateDnsZoneAppConfigResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.azconfig.io"
        existingPrivateDnsZoneContainerAppsResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.eastus2.azurecontainerapps.io"
        existingPrivateDnsZoneAcrResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
        existingPrivateDnsZoneAzureMonitorResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.monitor.azure.com"
        existingPrivateDnsZoneOmsOpsInsightsResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.oms.opinsights.azure.com"
        existingPrivateDnsZoneOdsOpsInsightsResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.ods.opinsights.azure.com"
        existingPrivateDnsZoneAzureAutomationResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.agentsvc.azure.automation.net"
        existingPrivateDnsZoneAppInsightsResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/privatelink.applicationinsights.io"
        modelDeploymentList = @(@{
            name = 'synthetic-chat'
            model = @{ format = 'OpenAI'; name = 'gpt-5-nano'; version = '2025-08-07' }
            sku = @{ name = 'GlobalStandard'; capacity = 1 }
            canonical_name = 'CHAT_DEPLOYMENT_NAME'
            apiVersion = '2025-12-01-preview'
        })
        workloadProfiles = @(@{ name = 'Consumption'; workloadProfileType = 'Consumption' })
        databaseContainersList = @()
        storageAccountContainersList = @()
    }
    gateway = @{
        enabled = $true
        name = 'synthetic-governed-gateway'
        workloadKey = 'syntheticlz01'
        sku = 'Developer'
        capacity = 1
        publisherEmail = 'synthetic-owner@example.invalid'
        publisherName = 'SYNTHETIC OFFLINE TEST OWNER'
        audience = 'api://synthetic-governed-inference'
        integrationSubnetName = 'synthetic-apim-integration'
        integrationSubnetPrefix = '10.220.4.0/27'
        # Service-scoped zone, not privatelink: classic VNet injection cannot
        # hold a private endpoint, and Learn forbids a zone for the shared apex
        # azure-api.net domain.
        privateDnsZoneResourceId = "$hubScope/providers/Microsoft.Network/privateDnsZones/synthetic-governed-gateway.azure-api.net"
        stopNewRequests = $false
        foundryIntegration = $false
        callerMappings = @(
            @{
                objectId = '00000000-0000-4000-8000-000000000032'
                project = 'synthetic-project'
                models = @('synthetic-chat')
                tokensPerMinute = 100
                tokenQuota = 1000
                tokenQuotaPeriod = 'Daily'
            }
            @{
                objectId = '00000000-0000-4000-8000-000000000041'
                project = 'synthetic-project'
                models = @('synthetic-chat')
                tokensPerMinute = 100
                tokenQuota = 1000
                tokenQuotaPeriod = 'Daily'
            }
        )
    }
    application = @{
        name = 'synthetic-developer-smoke'
        registryResourceId = "$scope/providers/Microsoft.ContainerRegistry/registries/syntheticneverdeployacr"
        imageRepository = 'synthetic/developer-smoke'
        audience = 'api://synthetic-developer-smoke'
        modelDeployment = 'synthetic-chat'
        maxOutputTokens = 64
        workspaceRepository = 'https://github.com/synthetic-never-deploy/synthetic-workspace'
        workspaceRef = '1111111111111111111111111111111111111111'
    }
    release = @{
        repository = 'synthetic-never-deploy/synthetic-landing-zone'
        runId = 123456789
        runAttempt = 1
        sourceSha = '2222222222222222222222222222222222222222'
        workflow = '.github/workflows/synthetic-ci.yml'
        ref = 'refs/heads/synthetic-protected'
        infrastructureVersion = '0.0.0-synthetic'
        imageDigest = 'sha256:' + ('a' * 64)
        artifactName = 'synthetic-release-bundle'
    }
    governance = @{
        assignmentPrefix = "synthetic-$Environment"
        policyEffect = 'Audit'
        assessmentApproved = $false
        allowedLocations = @('eastus2')
        allowedModelAssetIds = @('azureml://registries/azure-openai/models/gpt-5-nano/')
        allowedDeploymentSkus = @('GlobalStandard')
        requiredTags = @('environment', 'owner', 'purpose')
        budget = @{
            amount = 10
            currency = 'USD'
            startDate = '2026-09-01'
            endDate = '2026-10-01'
            actualThreshold = 50
            forecastThreshold = 75
            contactEmails = @('synthetic-owner@example.invalid')
            contactGroups = @()
        }
        inferenceAllowance = @{
            amount = 1
            currency = 'USD'
            pricingDate = '2026-09-16'
            pricingSources = @('https://example.invalid/synthetic-pricing-not-a-real-price')
            allocatedTokens = 2000
        }
    }
    network = @{
        hubAddressPrefixes = @('10.221.0.0/16')
        runnerSubnetPrefix = '10.221.1.0/27'
        reservedAddressPrefixes = @('10.222.0.0/16')
    }
    production = @{
        approved = ($Environment -eq 'prod')
        identityIsolation = 'SYNTHETIC OFFLINE TEST - distinct identities'
        dataIsolation = 'SYNTHETIC OFFLINE TEST - distinct data'
        residency = 'SYNTHETIC OFFLINE TEST - approved processing residency'
        capacity = 'SYNTHETIC OFFLINE TEST - bounded capacity'
        backupRecovery = 'SYNTHETIC OFFLINE TEST - recovery policy'
        retention = 'SYNTHETIC OFFLINE TEST - retention policy'
        availability = 'SYNTHETIC OFFLINE TEST - availability policy'
        approverOwnership = 'SYNTHETIC OFFLINE TEST OWNER'
    }
}

if ($Path) {
    $profile | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
return ,$profile
