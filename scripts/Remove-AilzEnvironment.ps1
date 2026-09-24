<#
.SYNOPSIS
    Tears down an AI Landing Zone azd environment, including the steps that
    azd down cannot complete on its own for this template.

.DESCRIPTION
    `azd down --purge` deletes the environment's resource group, then purges the
    soft-deleted Key Vault, App Configuration, API Management, Foundry and Log
    Analytics resources it held. Two conditions stop it on this template:

      * Azure AI Search refuses to delete a service that still has shared
        private link resources (LockedSPLResourceFound), which fails the
        resource group deletion. This script deletes those links first.
      * azd releases older than 1.25.5 cannot read Foundry accounts that report
        networkInjections, so `azd down` fails before deleting anything
        (azure-dev#8493).

    The script checks the azd version and that azd is signed in, resolves the
    target from the azd environment, refuses a resource group that azd did not
    create for this environment unless told otherwise, shows the plan, and asks
    you to type the resource group name. It then deletes the Search shared
    private links, waits until they are gone, and runs
    `azd down --force --purge`. Finally it prints the hub-side peering that the
    hub owner must remove. It never changes the hub. If azd down fails after the
    links are deleted, fix the reported error and rerun the script.

    Run it from the azd project root, where `azd down` finds azure.yaml.

.PARAMETER EnvironmentName
    Name of the azd environment to tear down.

.PARAMETER Force
    Skip the typed resource group confirmation.

.PARAMETER AllowExternalResourceGroup
    Proceed when the resource group is not tagged azd-env-name=<EnvironmentName>.
    `azd down --force` deletes every resource in the group, including resources
    this template did not create.

.PARAMETER SharedPrivateLinkTimeoutMinutes
    How long to wait for each shared private link to reach a deletable state and
    then disappear. Azure AI Search can hold a link in a nonterminal state for
    hours in rare cases.

.EXAMPLE
    pwsh ./scripts/Remove-AilzEnvironment.ps1 -EnvironmentName ailz-dev -WhatIf

    Shows what would be deleted without deleting anything.

.EXAMPLE
    pwsh ./scripts/Remove-AilzEnvironment.ps1 -EnvironmentName ailz-dev

    Deletes the environment after you type its resource group name.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EnvironmentName,

    [switch] $Force,

    [switch] $AllowExternalResourceGroup,

    [ValidateRange(1, 480)]
    [int] $SharedPrivateLinkTimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$searchApiVersion = '2025-05-01'
$pollSeconds = 15
# azd down purges Foundry accounts only from 1.25.5 (azure-dev#8493), whatever
# azure.yaml declares. azd down enforces a higher azure.yaml floor itself, so
# the larger of the two is checked before anything is deleted.
$teardownMinimumAzd = [version]'1.25.5'

function Get-OptionalProperty {
    param($InputObject, [Parameter(Mandatory)][string] $Name)

    if ($null -eq $InputObject -or -not $InputObject.PSObject.Properties[$Name]) {
        return $null
    }
    return $InputObject.$Name
}

function Get-LinkState {
    param([Parameter(Mandatory)] $Link, [Parameter(Mandatory)][string] $Name)

    return [string](Get-OptionalProperty -InputObject (Get-OptionalProperty -InputObject $Link -Name 'properties') -Name $Name)
}

function Get-AzdMinimumVersion {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $match = [regex]::Match((Get-Content -LiteralPath $Path -Raw), '(?m)^requiredVersions:[ \t]*\r?\n(?:[ \t]+.*\r?\n)*?[ \t]+azd:[ \t]*["'']?>=[ \t]*(\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        return $null
    }
    return [version]$match.Groups[1].Value
}

function Get-AzdVersion {
    $raw = & azd version --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw 'Unable to read the azd version.'
    }
    $match = [regex]::Match([string](($raw -join "`n" | ConvertFrom-Json).azd.version), '^\d+\.\d+\.\d+')
    if (-not $match.Success) {
        throw 'Unable to parse the azd version.'
    }
    return [version]$match.Value
}

function Assert-AzdSignedIn {
    # --check-status always exits 0, and its text output can name a cached
    # account whose token has expired, so read the JSON status instead.
    $raw = & azd auth login --check-status --output json 2>$null
    $status = ''
    if ($raw) {
        try {
            $status = [string](Get-OptionalProperty -InputObject ($raw -join "`n" | ConvertFrom-Json) -Name 'status')
        }
        catch {
            $status = ''
        }
    }
    if ($status -cne 'success') {
        throw ("azd is not signed in (azd auth login --check-status reports '$(if ($status) { $status } else { 'no status' })'), so azd down would fail after the shared private links were deleted. " +
            "Run 'azd auth login', then rerun this script.")
    }
}

function Get-AzdEnvironmentValue {
    param(
        [Parameter(Mandatory)][string] $Name,
        [switch] $Required
    )

    $value = & azd env get-value $Name --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$value)) {
        if ($Required) {
            throw "The azd environment '$EnvironmentName' does not define $Name."
        }
        return ''
    }
    return ([string]($value | Select-Object -First 1)).Trim()
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $raw = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0..1] -join ' ') failed with exit code $LASTEXITCODE."
    }
    if (-not $raw) {
        return $null
    }
    return ($raw -join "`n" | ConvertFrom-Json)
}

function Get-SharedPrivateLink {
    param([Parameter(Mandatory)][string] $SearchServiceId)

    $response = Invoke-AzJson -Arguments @('rest', '--method', 'get', '--url', "$SearchServiceId/sharedPrivateLinkResources?api-version=$searchApiVersion")
    return @(Get-OptionalProperty -InputObject $response -Name 'value')
}

function Remove-SharedPrivateLink {
    param(
        [Parameter(Mandatory)][string] $SearchServiceId,
        [Parameter(Mandatory)] $Link
    )

    # Azure AI Search deletes a shared private link only from a terminal state,
    # and the deletion itself is asynchronous.
    $deadline = (Get-Date).AddMinutes($SharedPrivateLinkTimeoutMinutes)
    $deleteRequested = $false
    while ($true) {
        $current = @(Get-SharedPrivateLink -SearchServiceId $SearchServiceId | Where-Object { $_.name -ceq $Link.name })
        if ($current.Count -eq 0) {
            Write-Host "  Deleted $($Link.name)."
            return
        }

        $state = Get-LinkState -Link $current[0] -Name 'provisioningState'
        if (-not $deleteRequested -and $state -in @('Succeeded', 'Failed')) {
            Write-Host "  Deleting $($Link.name) ($state, $(Get-LinkState -Link $current[0] -Name 'status'))..."
            & az rest --method delete --url "$($Link.id)?api-version=$searchApiVersion" --only-show-errors --output none
            if ($LASTEXITCODE -ne 0) {
                throw "Deleting shared private link '$($Link.name)' failed with exit code $LASTEXITCODE."
            }
            $deleteRequested = $true
            continue
        }

        if ((Get-Date) -ge $deadline) {
            throw "Shared private link '$($Link.name)' is still '$state' after $SharedPrivateLinkTimeoutMinutes minutes. See https://learn.microsoft.com/azure/search/troubleshoot-shared-private-link-resources#deleting-a-shared-private-link-resource and rerun."
        }
        Start-Sleep -Seconds $pollSeconds
    }
}

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found. Install it and try again."
    }
}
$projectFile = Join-Path -Path (Get-Location) -ChildPath 'azure.yaml'
if (-not (Test-Path -LiteralPath $projectFile)) {
    throw 'Run this script from the azd project root, where azd down finds azure.yaml.'
}

# Check what azd down needs before this script deletes the shared private links.
$minimumAzd = $teardownMinimumAzd
$declaredAzd = Get-AzdMinimumVersion -Path $projectFile
if ($declaredAzd -and $declaredAzd -gt $minimumAzd) {
    $minimumAzd = $declaredAzd
}
$currentAzd = Get-AzdVersion
if ($currentAzd -lt $minimumAzd) {
    throw "azd $currentAzd is older than $minimumAzd. azd down needs 1.25.5 or later to purge Foundry accounts, and azure.yaml can require a later release. Upgrade azd (https://aka.ms/azure-dev/install) and rerun."
}
Assert-AzdSignedIn

$subscriptionId = Get-AzdEnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID' -Required
$resourceGroupName = Get-AzdEnvironmentValue -Name 'AZURE_RESOURCE_GROUP' -Required
$spokeVnetResourceId = Get-AzdEnvironmentValue -Name 'VNET_RESOURCE_ID'
$hubVnetResourceId = Get-AzdEnvironmentValue -Name 'HUB_INTEGRATION_HUB_VNET_RESOURCE_ID'

$groupExists = (Invoke-AzJson -Arguments @('group', 'exists', '--name', $resourceGroupName, '--subscription', $subscriptionId)) -eq $true
if (-not $groupExists) {
    Write-Host "Resource group '$resourceGroupName' does not exist in subscription '$subscriptionId'. Nothing to delete."
    Write-Host 'If a soft-deleted Key Vault, Foundry account or API Management service remains, purge it with az keyvault purge,'
    Write-Host 'az cognitiveservices account purge or az apim deletedservice purge.'
    return
}

$group = Invoke-AzJson -Arguments @('group', 'show', '--name', $resourceGroupName, '--subscription', $subscriptionId)
$ownerTag = [string](Get-OptionalProperty -InputObject (Get-OptionalProperty -InputObject $group -Name 'tags') -Name 'azd-env-name')
if ($ownerTag -cne $EnvironmentName -and -not $AllowExternalResourceGroup) {
    throw ("Resource group '$resourceGroupName' is not tagged azd-env-name=$EnvironmentName (found '$ownerTag'), so azd did not create it for this environment. " +
        "azd down --force deletes every resource in it, including resources this template did not create. Rerun with -AllowExternalResourceGroup if that is intended.")
}

$links = @()
$searchServices = @(Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $resourceGroupName, '--subscription', $subscriptionId, '--resource-type', 'Microsoft.Search/searchServices'))
foreach ($service in $searchServices) {
    foreach ($link in @(Get-SharedPrivateLink -SearchServiceId ([string]$service.id))) {
        $links += [pscustomobject]@{ SearchServiceId = [string]$service.id; SearchServiceName = [string]$service.name; Link = $link }
    }
}

Write-Host ''
Write-Host "Teardown plan for azd environment '$EnvironmentName'"
Write-Host "  Subscription   : $subscriptionId"
Write-Host "  Resource group : $resourceGroupName$(if ($ownerTag -cne $EnvironmentName) { ' (NOT created by azd for this environment)' })"
Write-Host "  Search shared private links deleted first: $($links.Count)"
foreach ($entry in $links) {
    Write-Host ("    - {0}/{1} ({2}, {3})" -f $entry.SearchServiceName, $entry.Link.name, (Get-LinkState -Link $entry.Link -Name 'provisioningState'), (Get-LinkState -Link $entry.Link -Name 'status'))
}
Write-Host '  Then azd down --force --purge deletes the resource group and purges its soft-deleted'
Write-Host '  Key Vault, App Configuration, API Management, Foundry and Log Analytics resources.'
Write-Host '  Purged resources cannot be recovered.'
Write-Host ''

if (-not $PSCmdlet.ShouldProcess("resource group '$resourceGroupName' in subscription '$subscriptionId'", 'Delete Search shared private links, then azd down --force --purge')) {
    return
}
if (-not $Force -and (Read-Host "Type the resource group name '$resourceGroupName' to continue") -cne $resourceGroupName) {
    Write-Host 'Teardown cancelled.'
    return
}

foreach ($entry in $links) {
    Remove-SharedPrivateLink -SearchServiceId $entry.SearchServiceId -Link $entry.Link
}

& azd down --force --purge --environment $EnvironmentName
if ($LASTEXITCODE -ne 0) {
    throw "azd down failed with exit code $LASTEXITCODE. No Search shared private links remain, so fix the error above and rerun this script to finish the teardown."
}

if ($hubVnetResourceId) {
    Write-Host ''
    Write-Host 'Hub follow-up: azd down does not change the hub. Its peering to the deleted spoke is now'
    Write-Host 'Disconnected and cannot be reused, so the hub owner must delete it before the spoke is'
    Write-Host 'redeployed and peered again:'
    $hubSegments = $hubVnetResourceId.Trim('/').Split('/')
    $peeringId = ''
    if ($spokeVnetResourceId -and $hubSegments.Count -ge 8) {
        try {
            $raw = & az network vnet peering list --subscription $hubSegments[1] --resource-group $hubSegments[3] --vnet-name $hubSegments[7] --output json --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $match = @(($raw -join "`n" | ConvertFrom-Json) | Where-Object {
                        [string](Get-OptionalProperty -InputObject (Get-OptionalProperty -InputObject $_ -Name 'remoteVirtualNetwork') -Name 'id') -ieq $spokeVnetResourceId
                    } | Select-Object -First 1)
                if ($match.Count -gt 0) {
                    $peeringId = [string]$match[0].id
                }
            }
        }
        catch {
            $peeringId = ''
        }
    }
    if ($peeringId) {
        Write-Host "  az network vnet peering delete --ids `"$peeringId`""
    }
    else {
        Write-Host "  Delete the peering on hub VNet '$hubVnetResourceId' whose remote VNet was '$spokeVnetResourceId'."
    }
}
