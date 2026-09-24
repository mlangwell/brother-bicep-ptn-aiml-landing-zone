#Requires -Version 7.4
<#
.SYNOPSIS
    Offline contract tests for the azd operator paths: the azd version floor,
    the API Management hub-peering preflight gate, the full-preview preflight in
    Deploy-AilzIntegrated.ps1 and the Remove-AilzEnvironment.ps1 teardown.

.DESCRIPTION
    The real scripts run in-process. Only az, azd, pwsh, Read-Host, Start-Sleep
    and Get-Date are replaced by functions that record each call and return
    canned Azure responses. The az and azd stand-ins answer only the exact
    subscription, resource group, VNet and azd environment they expect, so a
    script that targets the wrong scope fails here. Nothing reaches Azure or the
    network.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$preflight = Join-Path $root 'scripts/Invoke-PreflightChecks.ps1'
$teardown = Join-Path $root 'scripts/Remove-AilzEnvironment.ps1'
$deploy = Join-Path $root 'Deploy-AilzIntegrated.ps1'
$parametersFile = Join-Path $root 'main.parameters.json'
$scratch = Join-Path ([IO.Path]::GetTempPath()) "ailz-azd-contract-$([guid]::NewGuid().ToString('N'))"
$script:assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Contract failed: $Message" }
    $script:assertions++
}

$hubSubscription = '11111111-1111-4111-8111-111111111111'
$spokeSubscription = '22222222-2222-4222-8222-222222222222'
$hubVnetId = "/subscriptions/$hubSubscription/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"
$spokeVnetId = "/subscriptions/$spokeSubscription/resourceGroups/rg-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
$otherVnetId = "/subscriptions/$spokeSubscription/resourceGroups/rg-other/providers/Microsoft.Network/virtualNetworks/vnet-other"
$searchId = "/subscriptions/$spokeSubscription/resourceGroups/rg-spoke/providers/Microsoft.Search/searchServices/srch-contract"

function Reset-Stub {
    $global:StubCalls = [System.Collections.Generic.List[string]]::new()
    $global:StubAzdVersion = '1.34.2'
    $global:StubAzdAuthStatus = 'success'
    $global:StubAzdDownExitCode = 0
    $global:StubAzdEnv = [ordered]@{}
    $global:StubPeerings = @()
    $global:StubPeeringListFails = $false
    $global:StubPwshExitCode = 0
    $global:StubGroupExists = $true
    $global:StubGroupTags = @{ 'azd-env-name' = 'contract' }
    $global:StubLinks = [System.Collections.Generic.List[object]]::new()
    $global:StubStuckState = ''
    $global:StubDeleteFails = $false
    $global:StubReadHost = ''
    $global:StubNow = [datetime]'2026-01-01T00:00:00Z'
}

function New-Peering([string]$RemoteId, [string]$State, [string[]]$Prefixes = @('192.168.0.0/21'), [bool]$AllowAccess = $true, [switch]$ArmShape) {
    $name = "to-$(Split-Path $RemoteId -Leaf)"
    $properties = [ordered]@{
        peeringState = $State
        peeringSyncLevel = 'FullyInSync'
        allowVirtualNetworkAccess = $AllowAccess
        allowForwardedTraffic = $true
        remoteVirtualNetwork = @{ id = $RemoteId }
        remoteAddressSpace = @{ addressPrefixes = $Prefixes }
    }
    if ($ArmShape) {
        return [ordered]@{ name = $name; id = "$hubVnetId/virtualNetworkPeerings/$name"; properties = $properties }
    }
    $flat = [ordered]@{ name = $name; id = "$hubVnetId/virtualNetworkPeerings/$name" }
    foreach ($key in $properties.Keys) { $flat[$key] = $properties[$key] }
    return $flat
}

function Test-Argument([string]$Joined, [string]$Name, [string]$Value) {
    return $Joined -match ('(^|\s){0}\s+{1}(\s|$)' -f [regex]::Escape($Name), [regex]::Escape($Value))
}

function az {
    $joined = ($args | ForEach-Object { [string]$_ }) -join ' '
    $global:StubCalls.Add("az $joined")
    $global:LASTEXITCODE = 0
    $spokeScope = Test-Argument $joined '--subscription' $spokeSubscription
    switch -Regex ($joined) {
        '^account show' {
            if ($joined -match '--output none') { return }
            return "{`"id`":`"$spokeSubscription`",`"tenantId`":`"33333333-3333-4333-8333-333333333333`",`"user`":{`"name`":`"contract`"}}"
        }
        '^provider show' { return 'Registered' }
        '^network vnet peering list' {
            $hubScope = (Test-Argument $joined '--subscription' $hubSubscription) -and
                (Test-Argument $joined '--resource-group' 'rg-hub') -and (Test-Argument $joined '--vnet-name' 'vnet-hub')
            if ($global:StubPeeringListFails -or -not $hubScope) { $global:LASTEXITCODE = 1; return }
            return (ConvertTo-Json -InputObject @($global:StubPeerings) -Depth 10 -AsArray)
        }
        '^network vnet show' { return "{`"id`":`"$hubVnetId`",`"name`":`"vnet-hub`",`"addressSpace`":{`"addressPrefixes`":[`"10.100.0.0/22`"]},`"subnets`":[]}" }
        '^group exists' {
            if (-not ($spokeScope -and (Test-Argument $joined '--name' 'rg-spoke'))) { $global:LASTEXITCODE = 1; return }
            return ($(if ($global:StubGroupExists) { 'true' } else { 'false' }))
        }
        '^group show' {
            if (-not ($spokeScope -and (Test-Argument $joined '--name' 'rg-spoke'))) { $global:LASTEXITCODE = 1; return }
            return (ConvertTo-Json -InputObject @{ name = 'rg-spoke'; tags = $global:StubGroupTags } -Depth 5)
        }
        '^resource list .*Microsoft\.Search/searchServices' {
            if (-not ($spokeScope -and (Test-Argument $joined '--resource-group' 'rg-spoke'))) { $global:LASTEXITCODE = 1; return }
            return (ConvertTo-Json -AsArray -InputObject @(@{ id = $searchId; name = 'srch-contract' }))
        }
        '^rest --method get --url (\S+)/sharedPrivateLinkResources\?' {
            if ($Matches[1] -ne $searchId) { $global:LASTEXITCODE = 1; return }
            $value = @($global:StubLinks | ForEach-Object {
                    $state = if ($global:StubStuckState) { $global:StubStuckState } else { $_.state }
                    @{ name = $_.name; id = $_.id; properties = @{ provisioningState = $state; status = 'Disconnected' } }
                })
            return (ConvertTo-Json -InputObject @{ value = $value } -Depth 10)
        }
        '^rest --method delete --url (\S+)\?' {
            $target = $Matches[1]
            if ($global:StubDeleteFails) { $global:LASTEXITCODE = 1; return }
            $global:StubLinks.RemoveAll({ param($link) $link.id -eq $target }) | Out-Null
            return
        }
        default { $global:LASTEXITCODE = 1; return }
    }
}

function azd {
    $joined = ($args | ForEach-Object { [string]$_ }) -join ' '
    $global:StubCalls.Add("azd $joined")
    $global:LASTEXITCODE = 0
    $contractEnvironment = Test-Argument $joined '--environment' 'contract'
    switch -Regex ($joined) {
        '^version --output json' {
            if (-not $global:StubAzdVersion) { $global:LASTEXITCODE = 1; return }
            return "{`"azd`":{`"version`":`"$($global:StubAzdVersion)`",`"commit`":`"0`"}}"
        }
        # azd always exits 0 for --check-status; only the JSON status tells.
        '^auth login --check-status --output json' { return "{`"status`": `"$($global:StubAzdAuthStatus)`"}" }
        '^env get-values' {
            if (-not $contractEnvironment) { $global:LASTEXITCODE = 1; return }
            return @($global:StubAzdEnv.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, (ConvertTo-Json -InputObject ([string]$_.Value) -Compress) })
        }
        '^env get-value (\S+)' {
            $name = $Matches[1]
            if ($contractEnvironment -and $global:StubAzdEnv.Contains($name)) { return [string]$global:StubAzdEnv[$name] }
            $global:LASTEXITCODE = 1
            return
        }
        '^down ' { $global:LASTEXITCODE = $global:StubAzdDownExitCode; return }
        default { return }
    }
}

function pwsh {
    $joined = ($args | ForEach-Object { [string]$_ }) -join ' '
    $global:StubCalls.Add("pwsh $joined")
    $global:LASTEXITCODE = $global:StubPwshExitCode
}

function Read-Host { param([Parameter(ValueFromRemainingArguments)]$Prompt) return $global:StubReadHost }
function Start-Sleep { param([Parameter(ValueFromRemainingArguments)]$Arguments) }
function Get-Date {
    $global:StubNow = $global:StubNow.AddMinutes(7)
    return $global:StubNow
}

function Set-ApiManagementEnvironment([switch]$PreparedSpoke) {
    $global:StubAzdEnv = [ordered]@{
        AZURE_ENV_NAME = 'contract'
        AZURE_LOCATION = 'eastus2'
        AZURE_SUBSCRIPTION_ID = $spokeSubscription
        AZURE_RESOURCE_GROUP = 'rg-spoke'
        NETWORK_ISOLATION = 'true'
        DEPLOYMENT_MODE = 'ailz-integrated'
        DEPLOY_AZURE_FIREWALL = 'false'
        DEPLOY_NSGS = 'true'
        USE_EXISTING_VNET = 'false'
        DEPLOY_API_MANAGEMENT = 'true'
        API_MANAGEMENT_PUBLISHER_EMAIL = 'ops@contoso.test'
        API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES = '["10.100.0.0/26"]'
        HUB_INTEGRATION_HUB_VNET_RESOURCE_ID = $hubVnetId
        HUB_INTEGRATION_EGRESS_NEXT_HOP_IP = '10.100.0.4'
    }
    if ($PreparedSpoke) {
        $global:StubAzdEnv.USE_EXISTING_VNET = 'true'
        $global:StubAzdEnv.DEPLOY_SUBNETS = 'false'
        $global:StubAzdEnv.EXISTING_VNET_RESOURCE_ID = $spokeVnetId
    }
}

function Invoke-Preflight([hashtable]$Extra = @{}) {
    $arguments = @{ ParametersFile = $parametersFile; AzdEnv = 'contract'; SkipRegional = $true }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    $text = & { Set-StrictMode -Off; & $preflight @arguments } 6>&1 | Out-String
    return [pscustomobject]@{ Text = $text; ExitCode = $LASTEXITCODE }
}

function Test-Finding($Result, [string]$Severity, [string]$Code) {
    return $Result.Text -match ('\[{0}\s*\]\s+{1}\b' -f $Severity, [regex]::Escape($Code))
}

function Set-TeardownEnvironment {
    $global:StubAzdEnv = [ordered]@{
        AZURE_SUBSCRIPTION_ID = $spokeSubscription
        AZURE_RESOURCE_GROUP = 'rg-spoke'
        VNET_RESOURCE_ID = $spokeVnetId
        HUB_INTEGRATION_HUB_VNET_RESOURCE_ID = $hubVnetId
    }
    foreach ($name in @('spl-srch-contract-blob-0', 'spl-srch-contract-openai_account-1')) {
        $global:StubLinks.Add([pscustomobject]@{ name = $name; id = "$searchId/sharedPrivateLinkResources/$name"; state = 'Succeeded' })
    }
}

function Invoke-Teardown([hashtable]$Arguments, [string]$WorkingDirectory = $root) {
    $message = ''
    Push-Location $WorkingDirectory
    try { & $teardown -EnvironmentName 'contract' @Arguments 6>$null | Out-Null }
    catch { $message = $_.Exception.Message }
    finally { Pop-Location }
    return $message
}

function Get-CallIndex([string]$Pattern, [switch]$Last) {
    $calls = @($global:StubCalls)
    $predicate = [Predicate[string]] { param($call) $call -like $Pattern }
    if ($Last) { return [array]::FindLastIndex($calls, $predicate) }
    return [array]::FindIndex($calls, $predicate)
}
function Get-DeleteCall { @($global:StubCalls | Where-Object { $_ -like 'az rest --method delete*' }) }
function Get-DownCall { @($global:StubCalls | Where-Object { $_ -like 'azd down*' }) }

function New-ProjectDirectory([string]$Name, [string]$AzureYaml) {
    $directory = Join-Path $scratch $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    Set-Content -LiteralPath (Join-Path $directory 'azure.yaml') -Value $AzureYaml
    return $directory
}

New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    # -----------------------------------------------------------------------
    # The azd floor is declared once, in azure.yaml, and documented.
    # -----------------------------------------------------------------------
    $azureYaml = Get-Content -LiteralPath (Join-Path $root 'azure.yaml') -Raw
    Assert-True ($azureYaml -match '(?m)^requiredVersions:\s*\r?\n\s+azd:\s*">= 1\.25\.5"') 'azure.yaml must declare requiredVersions.azd ">= 1.25.5".'
    foreach ($document in @('README.md', 'docs/copilot-deploy-prompt.md', '.github/prompts/deploy-ailz-integrated-apim.prompt.md')) {
        $text = Get-Content -LiteralPath (Join-Path $root $document) -Raw
        Assert-True ($text -match '1\.25\.5') "$document must state the azd 1.25.5 minimum."
    }
    $parameterBindings = (Get-Content -LiteralPath $parametersFile -Raw | ConvertFrom-Json).parameters
    Assert-True ($parameterBindings.apiManagementIngressSourceAddressPrefixes.value -ceq '${API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES=[]}') 'The ingress binding must stay the quoted token that azd 1.23.4+ parses as an array.'
    Assert-True ($parameterBindings.apiManagementDirectCallerAddressPrefixes.value -ceq '${API_MANAGEMENT_DIRECT_CALLER_ADDRESS_PREFIXES=[]}') 'The direct-caller binding must stay the quoted token that azd 1.23.4+ parses as an array.'

    # -----------------------------------------------------------------------
    # Preflight: azd version floor.
    # -----------------------------------------------------------------------
    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdVersion = '1.22.5'
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'FAIL' 'AZD_VERSION_UNSUPPORTED') 'Preflight must fail azd 1.22.5.'
    Assert-True ($result.Text -match 'The azd on PATH is 1\.22\.5') 'The failure must say which azd it read.'
    Assert-True ($result.ExitCode -eq 1) 'An unsupported azd must make preflight exit 1.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdVersion = '1.25.5'
    $result = Invoke-Preflight
    Assert-True (-not ($result.Text -match 'AZD_VERSION_')) 'azd 1.25.5 meets the floor.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdVersion = ''
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'WARN' 'AZD_VERSION_UNKNOWN') 'An unreadable azd version must warn.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdVersion = '1.22.5'
    $result = Invoke-Preflight -Extra @{ SkipAzureLookups = $true }
    Assert-True (-not ($result.Text -match 'AZD_VERSION_')) 'Deterministic CI runs must not depend on the runner azd version.'
    Assert-True (Test-Finding $result 'INFO' 'APIM_HUB_PEERING_UNVERIFIED') 'Skipped lookups must still name the peering prerequisite.'
    Assert-True (-not ($global:StubCalls -match '^az network vnet peering list')) 'Skipped lookups must not call az.'

    # The GitHub protected-delivery path deploys the resolver's literal
    # parameters with az deployment and never runs azd.
    Import-Module (Join-Path $root 'scripts/github/Environment.psm1') -Force
    $resolved = Resolve-EnvironmentProfile -Profile (& (Join-Path $root 'tests/github/New-SyntheticProfile.ps1')) -AllowSynthetic
    $literalParameters = Join-Path $scratch 'resolved.parameters.json'
    Set-Content -LiteralPath $literalParameters -Value (ConvertTo-Json -InputObject $resolved.parameters -Depth 100)
    Assert-True (-not ((Get-Content -LiteralPath $literalParameters -Raw) -match '\$\{')) 'The resolver must emit literal parameters.'
    Reset-Stub
    $global:StubAzdVersion = '1.22.5'
    $result = Invoke-Preflight -Extra @{ ParametersFile = $literalParameters; AzdEnv = ''; SubscriptionId = $spokeSubscription }
    Assert-True (-not ($result.Text -match 'AZD_VERSION_')) 'A literal parameters file is not substituted by azd, so the runner azd must not block it.'
    Assert-True (-not ($global:StubCalls -match '^azd version')) 'The azd version is not read for a literal parameters file.'

    # -----------------------------------------------------------------------
    # Preflight: API Management needs a usable hub-to-spoke peering first.
    # -----------------------------------------------------------------------
    Reset-Stub; Set-ApiManagementEnvironment
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_MISSING') 'A first deployment with API Management and no hub peering must fail.'
    Assert-True ($result.Text -match 'DEPLOY_API_MANAGEMENT=false') 'The failure must give the two-pass remedy.'
    Assert-True ($result.ExitCode -eq 1) 'A missing hub peering must make preflight exit 1.'
    Assert-True (@($global:StubCalls -match "^az network vnet peering list --subscription $hubSubscription --resource-group rg-hub --vnet-name vnet-hub").Count -eq 1) 'The hub peerings must be listed in the hub subscription, resource group and VNet.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
    $global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Connected')
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'INFO' 'APIM_HUB_PEERING_CONNECTED') 'A Connected hub peering to the recorded spoke VNet must pass.'
    Assert-True ($result.Text -match 'also needs the hub firewall') 'A Connected peering is necessary, not sufficient: the message must point at the firewall rules.'
    Assert-True (-not ($result.Text -match 'APIM_HUB_PEERING_(MISSING|NOT_CONNECTED|ACCESS_BLOCKED)')) 'A usable hub peering must not be reported as a problem.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
    $global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Connected' -ArmShape)
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'INFO' 'APIM_HUB_PEERING_CONNECTED') 'The raw ARM peering shape must be read too.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
    $global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Connected' -AllowAccess $false)
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_ACCESS_BLOCKED') 'A Connected peering that blocks virtual network access must fail.'
    Assert-True ($result.Text -match '--allow-vnet-access true') 'The failure must give the remedy.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
    $global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Disconnected')
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_NOT_CONNECTED') 'A Disconnected hub peering must fail.'
    Assert-True ($result.Text -match 'Disconnected') 'The failure must name the peering state.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
    $unsynced = New-Peering -RemoteId $spokeVnetId -State 'Connected'
    $unsynced.peeringSyncLevel = 'RemoteNotInSync'
    $global:StubPeerings = @($unsynced)
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'WARN' 'APIM_HUB_PEERING_NOT_SYNCED') 'A Connected but unsynchronized peering must warn.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Connected')
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'INFO' 'APIM_HUB_PEERING_CONNECTED') 'Without a recorded VNet ID, a Connected peering to the target resource group holding the gateway subnet must pass.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubPeerings = @(New-Peering -RemoteId $otherVnetId -State 'Connected')
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_MISSING') 'A peering to a VNet in another resource group must not satisfy the gate.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.Remove('AZURE_RESOURCE_GROUP')
    $global:StubPeerings = @(New-Peering -RemoteId $otherVnetId -State 'Connected')
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'WARN' 'APIM_HUB_PEERING_UNVERIFIED') 'With no target resource group, a matching Connected peering may be another spoke, so it must warn.'
    Assert-True (-not ($result.Text -match 'APIM_HUB_PEERING_CONNECTED')) 'An unidentified spoke must not be reported Connected.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.Remove('AZURE_RESOURCE_GROUP')
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_MISSING') 'With no peering holding the gateway subnet, no peering to this spoke exists either.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubPeeringListFails = $true
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'WARN' 'APIM_HUB_PEERING_UNVERIFIED') 'An unreadable hub must warn rather than claim the peering is missing.'
    Assert-True (-not ($result.Text -match 'APIM_HUB_PEERING_MISSING')) 'An unreadable hub is not evidence of a missing peering.'

    Reset-Stub; Set-ApiManagementEnvironment -PreparedSpoke
    $result = Invoke-Preflight
    Assert-True (Test-Finding $result 'WARN' 'APIM_HUB_PEERING_MISSING') 'A prepared spoke owns its route table, so a missing peering warns.'
    Assert-True (-not (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_MISSING')) 'A prepared spoke must not fail on the peering.'

    Reset-Stub; Set-ApiManagementEnvironment
    $global:StubAzdEnv.DEPLOY_API_MANAGEMENT = 'false'
    $result = Invoke-Preflight
    Assert-True (-not ($result.Text -match 'APIM_HUB_PEERING_')) 'The gate must not run when API Management is disabled.'

    # -----------------------------------------------------------------------
    # Deploy-AilzIntegrated.ps1: the full preview runs preflight before What-If.
    # -----------------------------------------------------------------------
    $deployArguments = @{
        EnvironmentName = 'contract'; Location = 'eastus2'; HubVnetResourceId = $hubVnetId
        EgressNextHopIp = '10.100.0.4'; PreviewOutput = 'Full'; PreviewOnly = $true
    }

    Reset-Stub
    $global:StubPwshExitCode = 1
    $message = ''
    try { & $deploy @deployArguments 6>$null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'Preflight failed with exit code 1') 'A failing preflight must stop the full preview.'
    $preflightCall = @($global:StubCalls | Where-Object { $_ -like 'pwsh *' })
    Assert-True ($preflightCall.Count -eq 1 -and $preflightCall[0] -match 'Invoke-PreflightChecks\.ps1 -AzdEnv contract$') 'The full preview must run the repository preflight for the selected environment.'
    Assert-True (Test-Path -LiteralPath (($preflightCall[0] -split ' -File ')[1] -replace ' -AzdEnv contract$', '')) 'The preflight path passed to pwsh must exist.'
    Assert-True (-not ($global:StubCalls -match '^az (bicep build|deployment group what-if)')) 'No What-If may run after a failing preflight.'

    Reset-Stub
    $global:StubAzdEnv = [ordered]@{ AZURE_SUBSCRIPTION_ID = $spokeSubscription; AZURE_RESOURCE_GROUP = 'rg-spoke' }
    $message = ''
    try { & $deploy @deployArguments 6>$null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'Bicep compilation failed') "A passing preflight must continue to the full preview (got: $message)."
    Assert-True ((Get-CallIndex 'pwsh *') -lt (Get-CallIndex 'az bicep build*')) 'Preflight must run before the What-If compilation.'

    # -----------------------------------------------------------------------
    # Remove-AilzEnvironment.ps1: nothing is deleted before every check passes.
    # -----------------------------------------------------------------------
    Reset-Stub; Set-TeardownEnvironment
    $global:StubAzdVersion = '1.22.5'
    $message = Invoke-Teardown @{ Force = $true }
    Assert-True ($message -match 'older than 1\.25\.5') 'Teardown must refuse an azd below the floor.'
    Assert-True ((Get-DeleteCall).Count -eq 0 -and (Get-DownCall).Count -eq 0) 'Teardown must refuse before deleting anything.'

    # The teardown needs 1.25.5 even where azure.yaml declares less, and honours
    # a higher floor that azd down itself would enforce.
    $project = New-ProjectDirectory -Name 'low-floor' -AzureYaml "name: consumer`nrequiredVersions:`n  azd: `">= 1.23.4`"`n"
    Reset-Stub; Set-TeardownEnvironment
    $global:StubAzdVersion = '1.24.0'
    $message = Invoke-Teardown @{ Force = $true } -WorkingDirectory $project
    Assert-True ($message -match 'older than 1\.25\.5') 'A lower azure.yaml floor must not lower the teardown minimum.'
    Assert-True ((Get-DeleteCall).Count -eq 0) 'A lower azure.yaml floor must not let links be deleted.'

    $project = New-ProjectDirectory -Name 'no-floor' -AzureYaml "name: consumer`n"
    Reset-Stub; Set-TeardownEnvironment
    $global:StubAzdVersion = '1.24.0'
    $message = Invoke-Teardown @{ Force = $true } -WorkingDirectory $project
    Assert-True ($message -match 'older than 1\.25\.5') 'A project without a floor still needs azd 1.25.5 for the teardown.'

    $project = New-ProjectDirectory -Name 'high-floor' -AzureYaml "name: consumer`nrequiredVersions:`n  azd: `">= 1.40.0`"`n"
    Reset-Stub; Set-TeardownEnvironment
    $message = Invoke-Teardown @{ Force = $true } -WorkingDirectory $project
    Assert-True ($message -match 'older than 1\.40\.0') 'A higher azure.yaml floor must be honoured before anything is deleted.'
    Assert-True ((Get-DeleteCall).Count -eq 0) 'A higher azure.yaml floor must stop the teardown before deletion.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubAzdAuthStatus = 'unauthenticated'
    $message = Invoke-Teardown @{ Force = $true }
    Assert-True ($message -match "azd is not signed in \(azd auth login --check-status reports 'unauthenticated'\)") 'Teardown must refuse when azd is not signed in.'
    Assert-True ((Get-DeleteCall).Count -eq 0 -and (Get-DownCall).Count -eq 0) 'An expired azd sign-in must be caught before any deletion.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubGroupTags = @{}
    $message = Invoke-Teardown @{ Force = $true }
    Assert-True ($message -match 'is not tagged azd-env-name=contract') 'Teardown must refuse a resource group azd did not create.'
    Assert-True ((Get-DeleteCall).Count -eq 0 -and (Get-DownCall).Count -eq 0) 'An external resource group must be refused before any deletion.'

    Reset-Stub; Set-TeardownEnvironment
    $message = Invoke-Teardown @{ WhatIf = $true }
    Assert-True ($message -eq '') "WhatIf must not throw: $message"
    Assert-True ((Get-DeleteCall).Count -eq 0 -and (Get-DownCall).Count -eq 0) 'WhatIf must not delete anything.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubReadHost = 'rg-wrong'
    $message = Invoke-Teardown @{}
    Assert-True ((Get-DeleteCall).Count -eq 0 -and (Get-DownCall).Count -eq 0) 'A mistyped confirmation must cancel.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubReadHost = 'rg-spoke'
    $message = Invoke-Teardown @{}
    Assert-True ($message -eq '') "A typed confirmation must proceed: $message"
    Assert-True ((Get-DeleteCall).Count -eq 2) 'Both Search shared private links must be deleted.'
    $down = @(Get-DownCall)
    Assert-True ($down.Count -eq 1 -and $down[0] -eq 'azd down --force --purge --environment contract') 'azd down must run once with --force --purge for the environment.'
    Assert-True ((Get-CallIndex 'azd auth login --check-status --output json') -lt (Get-CallIndex 'az rest --method delete*')) 'The azd sign-in must be checked before any deletion.'
    Assert-True ((Get-CallIndex 'az rest --method delete*' -Last) -lt (Get-CallIndex 'azd down*')) 'Every shared private link must be gone before azd down starts.'
    Assert-True ($global:StubLinks.Count -eq 0) 'No shared private link may remain.'
    Assert-True (@($global:StubCalls -match "^az network vnet peering list --subscription $hubSubscription --resource-group rg-hub --vnet-name vnet-hub").Count -eq 1) 'The hub follow-up must read the hub peerings in the hub scope.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubDeleteFails = $true
    $message = Invoke-Teardown @{ Force = $true }
    Assert-True ($message -match "Deleting shared private link 'spl-srch-contract-blob-0' failed") "A failed link deletion must stop the teardown at once (got: $message)."
    Assert-True ((Get-DownCall).Count -eq 0) 'azd down must not run after a failed link deletion.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubStuckState = 'Updating'
    $message = Invoke-Teardown @{ Force = $true; SharedPrivateLinkTimeoutMinutes = 20 }
    Assert-True ($message -match "still 'Updating'") 'A link stuck in a nonterminal state must time out explicitly.'
    Assert-True ((Get-DownCall).Count -eq 0) 'azd down must not run while a shared private link remains.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubAzdDownExitCode = 1
    $message = Invoke-Teardown @{ Force = $true }
    Assert-True ($message -match 'azd down failed with exit code 1\. No Search shared private links remain') 'A failed azd down must say the links are gone and a rerun is safe.'
    Assert-True ($global:StubLinks.Count -eq 0) 'The links deleted before a failed azd down stay deleted.'

    Reset-Stub; Set-TeardownEnvironment
    $global:StubGroupExists = $false
    $message = Invoke-Teardown @{ Force = $true }
    Assert-True ($message -eq '' -and (Get-DownCall).Count -eq 0) 'A missing resource group needs no azd down.'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name Stub* -ErrorAction SilentlyContinue
}

Write-Host "azd operations contract: $($script:assertions) assertions passed."
