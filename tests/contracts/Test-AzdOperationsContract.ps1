#Requires -Version 7.4
<#
.SYNOPSIS
    Offline contract tests for the azd operator paths: the azd version floor,
    the API Management hub-peering preflight gate, the full-preview preflight in
    Deploy-AilzIntegrated.ps1 and the Remove-AilzEnvironment.ps1 teardown.

.DESCRIPTION
    The real scripts run in-process. Only az, azd, pwsh, Read-Host, Start-Sleep
    and Get-Date are replaced by functions that record each call and return
    canned Azure responses, so nothing reaches Azure or the network.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$preflight = Join-Path $root 'scripts\Invoke-PreflightChecks.ps1'
$teardown = Join-Path $root 'scripts\Remove-AilzEnvironment.ps1'
$deploy = Join-Path $root 'Deploy-AilzIntegrated.ps1'
$parametersFile = Join-Path $root 'main.parameters.json'
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

function Reset-Stub {
    $global:StubCalls = [System.Collections.Generic.List[string]]::new()
    $global:StubAzdVersion = '1.34.2'
    $global:StubAzdEnv = [ordered]@{}
    $global:StubPeerings = @()
    $global:StubPeeringListFails = $false
    $global:StubPwshExitCode = 0
    $global:StubGroupExists = $true
    $global:StubGroupTags = @{ 'azd-env-name' = 'contract' }
    $global:StubLinks = [System.Collections.Generic.List[object]]::new()
    $global:StubStuckState = ''
    $global:StubReadHost = ''
    $global:StubNow = [datetime]'2026-01-01T00:00:00Z'
}

function New-Peering([string]$RemoteId, [string]$State, [string[]]$Prefixes = @('192.168.0.0/21'), [switch]$ArmShape) {
    $properties = [ordered]@{
        peeringState = $State
        peeringSyncLevel = 'FullyInSync'
        remoteVirtualNetwork = @{ id = $RemoteId }
        remoteAddressSpace = @{ addressPrefixes = $Prefixes }
    }
    if ($ArmShape) {
        return [ordered]@{ name = "to-$(Split-Path $RemoteId -Leaf)"; id = "$hubVnetId/virtualNetworkPeerings/to-$(Split-Path $RemoteId -Leaf)"; properties = $properties }
    }
    $flat = [ordered]@{ name = "to-$(Split-Path $RemoteId -Leaf)"; id = "$hubVnetId/virtualNetworkPeerings/to-$(Split-Path $RemoteId -Leaf)" }
    foreach ($key in $properties.Keys) { $flat[$key] = $properties[$key] }
    return $flat
}

function az {
    $joined = ($args | ForEach-Object { [string]$_ }) -join ' '
    $global:StubCalls.Add("az $joined")
    $global:LASTEXITCODE = 0
    switch -Regex ($joined) {
        '^account show' {
            if ($joined -match '--output none') { return }
            return "{`"id`":`"$spokeSubscription`",`"tenantId`":`"33333333-3333-4333-8333-333333333333`",`"user`":{`"name`":`"contract`"}}"
        }
        '^provider show' { return 'Registered' }
        '^network vnet peering list' {
            if ($global:StubPeeringListFails) { $global:LASTEXITCODE = 1; return }
            return (ConvertTo-Json -InputObject @($global:StubPeerings) -Depth 10 -AsArray)
        }
        '^network vnet show' { return "{`"id`":`"$hubVnetId`",`"name`":`"vnet-hub`",`"addressSpace`":{`"addressPrefixes`":[`"10.100.0.0/22`"]},`"subnets`":[]}" }
        '^group exists' { return ($(if ($global:StubGroupExists) { 'true' } else { 'false' })) }
        '^group show' { return (ConvertTo-Json -InputObject @{ name = 'rg-spoke'; tags = $global:StubGroupTags } -Depth 5) }
        '^resource list .*Microsoft\.Search/searchServices' {
            return (ConvertTo-Json -AsArray -InputObject @(@{ id = "/subscriptions/$spokeSubscription/resourceGroups/rg-spoke/providers/Microsoft.Search/searchServices/srch-contract"; name = 'srch-contract' }))
        }
        '^rest --method get --url .*/sharedPrivateLinkResources' {
            $value = @($global:StubLinks | ForEach-Object {
                    $state = if ($global:StubStuckState) { $global:StubStuckState } else { $_.state }
                    @{ name = $_.name; id = $_.id; properties = @{ provisioningState = $state; status = 'Disconnected' } }
                })
            return (ConvertTo-Json -InputObject @{ value = $value } -Depth 10)
        }
        '^rest --method delete --url (\S+)\?' {
            $target = $Matches[1]
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
    switch -Regex ($joined) {
        '^version --output json' {
            if (-not $global:StubAzdVersion) { $global:LASTEXITCODE = 1; return }
            return "{`"azd`":{`"version`":`"$($global:StubAzdVersion)`",`"commit`":`"0`"}}"
        }
        '^env get-values' {
            return @($global:StubAzdEnv.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, (ConvertTo-Json -InputObject ([string]$_.Value) -Compress) })
        }
        '^env get-value (\S+)' {
            $name = $Matches[1]
            if ($global:StubAzdEnv.Contains($name)) { return [string]$global:StubAzdEnv[$name] }
            $global:LASTEXITCODE = 1
            return
        }
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
    $arguments = @{ ParametersFile = $parametersFile; AzdEnv = 'contract'; SkipRegional = $true } + $Extra
    $text = & { Set-StrictMode -Off; & $preflight @arguments } 6>&1 | Out-String
    return [pscustomobject]@{ Text = $text; ExitCode = $LASTEXITCODE }
}

function Test-Finding($Result, [string]$Severity, [string]$Code) {
    return $Result.Text -match ('\[{0}\s*\]\s+{1}\b' -f $Severity, [regex]::Escape($Code))
}

# ---------------------------------------------------------------------------
# The azd floor is declared once, in azure.yaml, and documented.
# ---------------------------------------------------------------------------
$azureYaml = Get-Content -LiteralPath (Join-Path $root 'azure.yaml') -Raw
Assert-True ($azureYaml -match '(?m)^requiredVersions:\s*\r?\n\s+azd:\s*">= 1\.25\.5"') 'azure.yaml must declare requiredVersions.azd ">= 1.25.5".'
foreach ($document in @('README.md', 'docs\copilot-deploy-prompt.md', '.github\prompts\deploy-ailz-integrated-apim.prompt.md')) {
    $text = Get-Content -LiteralPath (Join-Path $root $document) -Raw
    Assert-True ($text -match '1\.25\.5') "$document must state the azd 1.25.5 minimum."
}
$parameterBindings = (Get-Content -LiteralPath $parametersFile -Raw | ConvertFrom-Json).parameters
Assert-True ($parameterBindings.apiManagementIngressSourceAddressPrefixes.value -ceq '${API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES=[]}') 'The ingress binding must stay the quoted token that azd 1.23.4+ parses as an array.'
Assert-True ($parameterBindings.apiManagementDirectCallerAddressPrefixes.value -ceq '${API_MANAGEMENT_DIRECT_CALLER_ADDRESS_PREFIXES=[]}') 'The direct-caller binding must stay the quoted token that azd 1.23.4+ parses as an array.'

# ---------------------------------------------------------------------------
# Preflight: azd version floor.
# ---------------------------------------------------------------------------
Reset-Stub; Set-ApiManagementEnvironment
$global:StubAzdVersion = '1.22.5'
$result = Invoke-Preflight
Assert-True (Test-Finding $result 'FAIL' 'AZD_VERSION_UNSUPPORTED') 'Preflight must fail azd 1.22.5.'
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

# ---------------------------------------------------------------------------
# Preflight: API Management needs a Connected hub-to-spoke peering first.
# ---------------------------------------------------------------------------
Reset-Stub; Set-ApiManagementEnvironment
$result = Invoke-Preflight
Assert-True (Test-Finding $result 'FAIL' 'APIM_HUB_PEERING_MISSING') 'A first deployment with API Management and no hub peering must fail.'
Assert-True ($result.Text -match 'DEPLOY_API_MANAGEMENT=false') 'The failure must give the two-pass remedy.'
Assert-True ($result.ExitCode -eq 1) 'A missing hub peering must make preflight exit 1.'

Reset-Stub; Set-ApiManagementEnvironment
$global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
$global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Connected')
$result = Invoke-Preflight
Assert-True (Test-Finding $result 'INFO' 'APIM_HUB_PEERING_CONNECTED') 'A Connected hub peering to the recorded spoke VNet must pass.'
Assert-True (-not ($result.Text -match 'APIM_HUB_PEERING_(MISSING|NOT_CONNECTED)')) 'A Connected hub peering must not be reported missing.'

Reset-Stub; Set-ApiManagementEnvironment
$global:StubAzdEnv.VNET_RESOURCE_ID = $spokeVnetId
$global:StubPeerings = @(New-Peering -RemoteId $spokeVnetId -State 'Connected' -ArmShape)
$result = Invoke-Preflight
Assert-True (Test-Finding $result 'INFO' 'APIM_HUB_PEERING_CONNECTED') 'The raw ARM peering shape must be read too.'

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

# ---------------------------------------------------------------------------
# Deploy-AilzIntegrated.ps1: the full preview runs preflight before What-If.
# ---------------------------------------------------------------------------
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
$order = @($global:StubCalls)
Assert-True ([array]::FindIndex($order, [Predicate[string]] { param($c) $c -like 'pwsh *' }) -lt [array]::FindIndex($order, [Predicate[string]] { param($c) $c -like 'az bicep build*' })) 'Preflight must run before the What-If compilation.'

# ---------------------------------------------------------------------------
# Remove-AilzEnvironment.ps1: safe ordering and refusals.
# ---------------------------------------------------------------------------
function Set-TeardownEnvironment {
    $global:StubAzdEnv = [ordered]@{
        AZURE_SUBSCRIPTION_ID = $spokeSubscription
        AZURE_RESOURCE_GROUP = 'rg-spoke'
        VNET_RESOURCE_ID = $spokeVnetId
        HUB_INTEGRATION_HUB_VNET_RESOURCE_ID = $hubVnetId
    }
    $searchId = "/subscriptions/$spokeSubscription/resourceGroups/rg-spoke/providers/Microsoft.Search/searchServices/srch-contract"
    foreach ($name in @('spl-srch-contract-blob-0', 'spl-srch-contract-openai_account-1')) {
        $global:StubLinks.Add([pscustomobject]@{ name = $name; id = "$searchId/sharedPrivateLinkResources/$name"; state = 'Succeeded' })
    }
}

function Invoke-Teardown([hashtable]$Arguments) {
    $message = ''
    Push-Location $root
    try { & $teardown -EnvironmentName 'contract' @Arguments 6>$null | Out-Null }
    catch { $message = $_.Exception.Message }
    finally { Pop-Location }
    return $message
}

function Get-DeleteCall { @($global:StubCalls | Where-Object { $_ -like 'az rest --method delete*' }) }
function Get-DownCall { @($global:StubCalls | Where-Object { $_ -like 'azd down*' }) }

Reset-Stub; Set-TeardownEnvironment
$global:StubAzdVersion = '1.22.5'
$message = Invoke-Teardown @{ Force = $true }
Assert-True ($message -match 'older than 1\.25\.5') 'Teardown must refuse an azd below the floor.'
Assert-True ((Get-DeleteCall).Count -eq 0 -and (Get-DownCall).Count -eq 0) 'Teardown must refuse before deleting anything.'

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
$order = @($global:StubCalls)
$lastDelete = [array]::FindLastIndex($order, [Predicate[string]] { param($c) $c -like 'az rest --method delete*' })
$downIndex = [array]::FindIndex($order, [Predicate[string]] { param($c) $c -like 'azd down*' })
Assert-True ($lastDelete -lt $downIndex) 'Every shared private link must be gone before azd down starts.'
Assert-True ($global:StubLinks.Count -eq 0) 'No shared private link may remain.'

Reset-Stub; Set-TeardownEnvironment
$global:StubStuckState = 'Updating'
$message = Invoke-Teardown @{ Force = $true; SharedPrivateLinkTimeoutMinutes = 20 }
Assert-True ($message -match "still 'Updating'") 'A link stuck in a nonterminal state must time out explicitly.'
Assert-True ((Get-DownCall).Count -eq 0) 'azd down must not run while a shared private link remains.'

Reset-Stub; Set-TeardownEnvironment
$global:StubGroupExists = $false
$message = Invoke-Teardown @{ Force = $true }
Assert-True ($message -eq '' -and (Get-DownCall).Count -eq 0) 'A missing resource group needs no azd down.'

Remove-Variable -Scope Global -Name Stub* -ErrorAction SilentlyContinue
Write-Host "azd operations contract: $($script:assertions) assertions passed."
