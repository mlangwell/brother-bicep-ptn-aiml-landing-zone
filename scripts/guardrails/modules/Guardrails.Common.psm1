#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Shared engine for the AI guardrails playbook: configuration, fail-closed
    pre-flight, ARM invocation, and evidence recording.

.NOTES
    Azure writes in this playbook are gated on apply mode in two places, and a
    reviewer should know both rather than trusting a single-gate claim:

      1. Invoke-GuardrailAction - the -Action scriptblock. This is the gate for
         all but one of the mutating calls, and it is the one to add new writes to.
      2. Grant-PolicyIdentityRole (Guardrails.Policy.psm1) - guards its own
         `az role assignment create` with an explicit Test-GuardrailApplyMode
         check, because it runs inside the assignment flow rather than as a
         discrete action.

    Both fail closed. If you add a third, add it here too - an inventory that
    claims to be exhaustive and is not is worse than no inventory.

    Note the orchestrator does NOT declare SupportsShouldProcess. -WhatIf cannot
    reach `az` (an external process), so advertising it would suppress the
    evidence file while the Azure writes still happened. -Apply is the only gate.
#>

$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()
$script:ApplyMode = $false
$script:FailFast = $false

# Status vocabulary. Deliberately distinguishes "we changed nothing because it
# was already right" from "we could not determine whether it is right" - the
# second is a finding, the first is not.
$script:StatusOrder = @{
    Failed       = 0
    Finding      = 1
    Unverifiable = 2
    WouldApply   = 3
    Applied      = 4
    Compliant    = 5
    Skipped      = 6
}

function Import-GuardrailEnvironment {
    <#
    .SYNOPSIS
        Parse a KEY=VALUE .env file into a hashtable. No interpolation, no
        command substitution - a config file is not a script.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Environment file not found: '$Path'. Copy .env.example to .env and fill it in."
    }

    $map = @{}
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) {
            throw "Malformed line $lineNumber in '$Path': expected KEY=VALUE, got '$trimmed'."
        }

        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()

        # Strip a trailing inline comment only when the value is unquoted.
        if ($value -notmatch '^["'']') {
            $hash = $value.IndexOf('#')
            if ($hash -ge 0) { $value = $value.Substring(0, $hash).Trim() }
        }

        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $map[$key] = $value
    }

    return $map
}

function Get-EnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default,
        [switch]$Required
    )

    $value = $null
    if ($Map.ContainsKey($Key)) { $value = $Map[$Key] }

    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            throw "Required setting '$Key' is missing or empty in the environment file."
        }
        return $Default
    }

    return $value
}

function Get-EnvList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][string]$Key,
        [string[]]$Default = @()
    )

    $raw = Get-EnvValue -Map $Map -Key $Key
    if ([string]::IsNullOrWhiteSpace($raw)) { return , $Default }

    $items = @(
        $raw -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
    )
    return , $items
}

function Get-EnvBool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][string]$Key,
        [bool]$Default = $false
    )

    $raw = Get-EnvValue -Map $Map -Key $Key
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

    switch ($raw.ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'yes'   { return $true }
        'false' { return $false }
        '0'     { return $false }
        'no'    { return $false }
        default { throw "Setting '$Key' must be a boolean (true/false), got '$raw'." }
    }
}

function Get-EnvInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][string]$Key,
        [int]$Default = 0,
        [int]$Minimum = [int]::MinValue
    )

    $raw = Get-EnvValue -Map $Map -Key $Key
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed)) {
        throw "Setting '$Key' must be an integer, got '$raw'."
    }
    if ($parsed -lt $Minimum) {
        throw "Setting '$Key' must be >= $Minimum, got $parsed."
    }
    return $parsed
}

function Initialize-GuardrailRun {
    [CmdletBinding()]
    param(
        [bool]$Apply,
        [bool]$FailFast
    )

    $script:Results.Clear()
    $script:ApplyMode = $Apply
    $script:FailFast = $FailFast
}

function Test-GuardrailApplyMode {
    [CmdletBinding()]
    param()
    return $script:ApplyMode
}

function Assert-GuardrailTarget {
    <#
    .SYNOPSIS
        Fail-closed pre-flight. Refuses to continue when the live Azure context
        does not match the declared target.

    .DESCRIPTION
        This is the wrong-subscription and cross-engagement guard. It runs
        before any write, every time. Deploying one customer's governance into
        another customer's subscription is not recoverable by renaming.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpectedTenantId,
        [Parameter(Mandatory)][string]$ExpectedSubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup
    )

    $azCommand = Get-Command -Name az -CommandType Application -ErrorAction SilentlyContinue
    if (-not $azCommand) {
        throw "Azure CLI ('az') was not found on PATH. Install it, or run this from a shell that has it."
    }

    $accountJson = & az account show -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Not signed in to Azure, or the CLI could not read the account context. Run 'az login' first.`n$accountJson"
    }

    $account = $accountJson | ConvertFrom-Json

    $actualTenant = [string]$account.tenantId
    $actualSub = [string]$account.id

    if ($actualTenant -ine $ExpectedTenantId) {
        throw @"
TENANT MISMATCH - refusing to continue.
  Expected tenant : $ExpectedTenantId
  Signed in to    : $actualTenant ($($account.name))
Fix AZ_TENANT_ID, or run 'az login --tenant $ExpectedTenantId'.
"@
    }

    if ($actualSub -ine $ExpectedSubscriptionId) {
        throw @"
SUBSCRIPTION MISMATCH - refusing to continue.
  Expected subscription : $ExpectedSubscriptionId
  Signed in to          : $actualSub ($($account.name))
Fix AZ_SUBSCRIPTION_ID, or run 'az account set --subscription $ExpectedSubscriptionId'.
"@
    }

    $rgJson = & az group show --name $ResourceGroup -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Resource group '$ResourceGroup' was not found in subscription '$actualSub'. This playbook runs AFTER the landing zone is deployed.`n$rgJson"
    }
    $rg = $rgJson | ConvertFrom-Json

    return [pscustomobject]@{
        TenantId          = $actualTenant
        SubscriptionId    = $actualSub
        SubscriptionName  = [string]$account.name
        User              = [string]$account.user.name
        ResourceGroup     = [string]$rg.name
        ResourceGroupId   = [string]$rg.id
        Location          = [string]$rg.location
    }
}

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Run an az CLI command and return parsed JSON, or $null on a
        "not found" style failure.

    .PARAMETER AllowNotFound
        Treat a non-zero exit as an absence rather than an error. Used for
        read-before-write probes, which is how this playbook stays idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowNotFound,
        [switch]$Raw
    )

    $output = & az @Arguments 2>&1
    $exit = $LASTEXITCODE

    if ($exit -ne 0) {
        if ($AllowNotFound) { return $null }
        throw "az $($Arguments -join ' ') failed with exit code $exit.`n$($output -join [Environment]::NewLine)"
    }

    if ($Raw) { return ($output -join [Environment]::NewLine) }

    $text = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try {
        return $text | ConvertFrom-Json
    }
    catch {
        throw "Could not parse JSON from 'az $($Arguments -join ' ')'. Raw output:`n$text"
    }
}

function Invoke-AzRestJson {
    <#
    .SYNOPSIS
        az rest with a JSON body, passed via a temp file.

    .DESCRIPTION
        Inline JSON bodies on the command line are a quoting minefield across
        shells. Writing the body to a file and using az's '@file' form removes
        the entire class of problem. The temp file is always removed, including
        on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('get', 'put', 'patch', 'post', 'delete')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [object]$Body,
        [switch]$AllowNotFound
    )

    $bodyFile = $null
    try {
        $arguments = @('rest', '--method', $Method, '--url', $Url)

        if ($null -ne $Body) {
            $bodyFile = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                "guardrail-body-$([guid]::NewGuid().ToString('N')).json")
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 }
            Set-Content -LiteralPath $bodyFile -Value $json -Encoding utf8NoBOM
            $arguments += @('--body', "@$bodyFile")
        }

        # Cost Management and some control-plane endpoints reject an
        # unsolicited Content-Type on GET.
        if ($Method -ne 'get' -and $null -ne $Body) {
            $arguments += @('--headers', 'Content-Type=application/json')
        }

        return Invoke-AzCli -Arguments $arguments -AllowNotFound:$AllowNotFound
    }
    finally {
        if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) {
            Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-ProbeState {
    <#
    .SYNOPSIS
        Normalise a probe scriptblock's return value.

    .DESCRIPTION
        Probes return a hashtable with Compliant and Detail, and optionally
        Evidence. Under StrictMode, reading an absent key throws, so the shape
        is filled in here once instead of being defended at every call site.
    #>
    [CmdletBinding()]
    param([object]$Raw)

    if ($null -eq $Raw) {
        throw 'Probe returned nothing. A probe must return a hashtable with at least a Compliant key.'
    }

    # A scriptblock that emits more than one object yields an array; the state
    # is the last emitted object.
    if ($Raw -is [System.Array]) {
        $Raw = @($Raw)[-1]
    }

    $compliant = $false
    $detail = 'unknown'
    $evidence = $null

    if ($Raw -is [hashtable] -or $Raw -is [System.Collections.IDictionary]) {
        if ($Raw.Contains('Compliant')) { $compliant = [bool]$Raw['Compliant'] }
        if ($Raw.Contains('Detail'))    { $detail = [string]$Raw['Detail'] }
        if ($Raw.Contains('Evidence'))  { $evidence = $Raw['Evidence'] }
    }
    elseif ($Raw -is [pscustomobject]) {
        $names = $Raw.PSObject.Properties.Name
        if ($names -contains 'Compliant') { $compliant = [bool]$Raw.Compliant }
        if ($names -contains 'Detail')    { $detail = [string]$Raw.Detail }
        if ($names -contains 'Evidence')  { $evidence = $Raw.Evidence }
    }
    else {
        throw "Probe returned a $($Raw.GetType().Name); expected a hashtable with a Compliant key."
    }

    return [pscustomobject]@{
        Compliant = $compliant
        Detail    = $detail
        Evidence  = $evidence
    }
}

function Get-EvidenceValue {
    <#
    .SYNOPSIS
        Read one key out of a result's Evidence without tripping StrictMode.
    #>
    [CmdletBinding()]
    param(
        [object]$Evidence,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Evidence) { return $null }

    if ($Evidence -is [hashtable] -or $Evidence -is [System.Collections.IDictionary]) {
        if ($Evidence.Contains($Key)) { return $Evidence[$Key] }
        return $null
    }

    if ($Evidence -is [pscustomobject] -and ($Evidence.PSObject.Properties.Name -contains $Key)) {
        return $Evidence.$Key
    }

    return $null
}

function Add-GuardrailResult {
    <#
    .SYNOPSIS
        Record one guardrail outcome. Everything the run reports comes from here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Plane,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Applied', 'WouldApply', 'Compliant', 'Skipped', 'Finding', 'Unverifiable', 'Failed')]
        [string]$Status,
        [Parameter(Mandatory)][string]$Detail,
        [object]$Evidence,
        [string]$Remediation,
        [string]$Reference
    )

    $record = [pscustomobject]@{
        Timestamp   = (Get-Date).ToUniversalTime().ToString('o')
        Plane       = $Plane
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
        Reference   = $Reference
        Evidence    = $Evidence
    }

    $script:Results.Add($record)

    $colour = switch ($Status) {
        'Applied'      { 'Green' }
        'Compliant'    { 'DarkGreen' }
        'WouldApply'   { 'Cyan' }
        'Skipped'      { 'DarkGray' }
        'Finding'      { 'Yellow' }
        'Unverifiable' { 'Magenta' }
        'Failed'       { 'Red' }
        default        { 'White' }
    }

    Write-Host ("  [{0,-12}] {1}" -f $Status, $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host ("               {0}" -f $Detail) -ForegroundColor DarkGray }

    if ($Status -eq 'Failed' -and $script:FailFast) {
        throw "FAIL_FAST is set and '$Name' failed: $Detail"
    }

    return $record
}

function Invoke-GuardrailAction {
    <#
    .SYNOPSIS
        The single gate through which every state-changing operation passes.

    .DESCRIPTION
        Pattern: Probe decides the current state; Action performs the write.
        If Probe reports compliance, Action is never invoked - that is what
        makes reruns idempotent. If not in Apply mode, Action is never invoked
        either, and the outcome is recorded as WouldApply.

    .PARAMETER Probe
        Scriptblock returning a hashtable with keys:
          Compliant = [bool]     whether the desired state already holds
          Detail    = [string]   human-readable current state
          Evidence  = [object]   optional structured current state
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Plane,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$WouldDo,
        [string]$Reference
    )

    try {
        # Probes are allowed to omit Evidence, so the result is normalised here
        # rather than requiring every call site to populate every key. Under
        # StrictMode, reading an absent hashtable key throws.
        $state = Resolve-ProbeState -Raw (& $Probe)
    }
    catch {
        return Add-GuardrailResult -Plane $Plane -Name $Name -Status 'Failed' `
            -Detail "Could not determine current state: $($_.Exception.Message)" -Reference $Reference
    }

    if ($state.Compliant) {
        return Add-GuardrailResult -Plane $Plane -Name $Name -Status 'Compliant' `
            -Detail $state.Detail -Evidence $state.Evidence -Reference $Reference
    }

    if (-not $script:ApplyMode) {
        return Add-GuardrailResult -Plane $Plane -Name $Name -Status 'WouldApply' `
            -Detail "$WouldDo (current: $($state.Detail))" -Evidence $state.Evidence -Reference $Reference
    }

    try {
        $result = & $Action
        return Add-GuardrailResult -Plane $Plane -Name $Name -Status 'Applied' `
            -Detail $WouldDo -Evidence $result -Reference $Reference
    }
    catch {
        return Add-GuardrailResult -Plane $Plane -Name $Name -Status 'Failed' `
            -Detail $_.Exception.Message -Reference $Reference
    }
}

function Get-GuardrailResults {
    [CmdletBinding()]
    param()
    return , @($script:Results)
}

function Write-GuardrailReport {
    <#
    .SYNOPSIS
        Print the run summary and persist a JSON evidence file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][bool]$Applied
    )

    $results = @($script:Results)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ' RUN SUMMARY' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ("  Mode          : {0}" -f $(if ($Applied) { 'APPLY (writes were performed)' } else { 'DRY RUN (nothing was written)' }))
    Write-Host ("  Subscription  : {0} ({1})" -f $Target.SubscriptionName, $Target.SubscriptionId)
    Write-Host ("  Tenant        : {0}" -f $Target.TenantId)
    Write-Host ("  ResourceGroup : {0}" -f $Target.ResourceGroup)
    Write-Host ''

    $counts = $results | Group-Object -Property Status | Sort-Object {
        if ($script:StatusOrder.ContainsKey($_.Name)) { $script:StatusOrder[$_.Name] } else { 99 }
    }

    foreach ($group in $counts) {
        Write-Host ("  {0,-14} {1}" -f $group.Name, $group.Count)
    }
    Write-Host ''

    $attention = @($results | Where-Object { $_.Status -in @('Failed', 'Finding', 'Unverifiable') })
    if ($attention.Count -gt 0) {
        Write-Host ' NEEDS ATTENTION' -ForegroundColor Yellow
        Write-Host ('-' * 78) -ForegroundColor DarkGray
        foreach ($item in $attention) {
            Write-Host ("  [{0}] {1} :: {2}" -f $item.Status, $item.Plane, $item.Name) -ForegroundColor Yellow
            Write-Host ("      {0}" -f $item.Detail) -ForegroundColor Gray
            if ($item.Remediation) { Write-Host ("      -> {0}" -f $item.Remediation) -ForegroundColor Gray }
            if ($item.Reference)   { Write-Host ("      ref: {0}" -f $item.Reference) -ForegroundColor DarkGray }
        }
        Write-Host ''
    }

    if (-not (Test-Path -LiteralPath $EvidencePath)) {
        New-Item -ItemType Directory -Path $EvidencePath -Force | Out-Null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $mode = if ($Applied) { 'apply' } else { 'dryrun' }
    $file = Join-Path -Path $EvidencePath -ChildPath "guardrails-$mode-$stamp.json"

    $envelope = [pscustomobject]@{
        schemaVersion = 1
        generatedAt   = (Get-Date).ToUniversalTime().ToString('o')
        mode          = $mode
        target        = $Target
        # ARM completion is not compliance. A policy assignment existing does not
        # mean the estate is compliant; a budget existing does not mean spend is
        # capped. This file records what was configured, nothing more.
        caveat        = 'Configuration evidence only. Not a compliance attestation and not a financial hard cap.'
        results       = $results
    }

    $envelope | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    Write-Host ("  Evidence written: {0}" -f $file) -ForegroundColor DarkCyan
    Write-Host ''

    return $file
}

Export-ModuleMember -Function @(
    'Import-GuardrailEnvironment'
    'Get-EnvValue'
    'Get-EnvList'
    'Get-EnvBool'
    'Get-EnvInt'
    'Initialize-GuardrailRun'
    'Test-GuardrailApplyMode'
    'Assert-GuardrailTarget'
    'Invoke-AzCli'
    'Invoke-AzRestJson'
    'Resolve-ProbeState'
    'Get-EvidenceValue'
    'Add-GuardrailResult'
    'Invoke-GuardrailAction'
    'Get-GuardrailResults'
    'Write-GuardrailReport'
)

