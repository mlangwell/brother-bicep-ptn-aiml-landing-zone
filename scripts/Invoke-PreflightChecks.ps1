<#
.SYNOPSIS
    Pre-flight validation for AI Landing Zone deployments.

.DESCRIPTION
    Validates the effective parameter set (azd env + main.parameters.json) BEFORE
    `azd provision` reaches Azure Resource Manager. Catches the common topology
    mistakes that otherwise surface as deep, late, hard-to-debug ARM errors:

      * Conflicting Private DNS settings (policy-managed + BYO overrides at the
        same time)
      * Mutually-exclusive hub-integration parameters
      * Invalid IP allow-list shape
      * Subnet prefixes that overflow the VNet address space or overlap each
        other
      * Subnets too small for the services that consume them
      * Observability parameters that would produce telemetry split-brain
      * BYO resources (VNet, Private DNS zones, Log Analytics, App Insights,
        route table) that the operator promised but that don't actually exist
      * An azd older than the `requiredVersions.azd` floor in azure.yaml, when
        azd substitutes the parameters file
      * An API Management gateway requested before the hub-to-spoke peering
        it activates through is Connected

    The script is **read-only**: it never modifies Azure state. It is safe to
    run from a `preprovision` hook, from CI, or interactively at any time.

.PARAMETER SubscriptionId
    Subscription to perform Azure lookups against. Defaults to the current
    `az account show` subscription.

.PARAMETER AzdEnv
    Name of the azd environment to read values from. Defaults to
    `$env:AZURE_ENV_NAME` (which azd sets), then to the current default env.

.PARAMETER ParametersFile
    Path to `main.parameters.json`. Defaults to the file at the repo root
    relative to this script.

.PARAMETER Strict
    Treat warnings as failures (exit 2 instead of 0 when only warnings are
    reported).

.PARAMETER SkipAzureLookups
    Skip every check that requires an `az` call. Use for offline testing.

.PARAMETER Skip
    Skip all checks. Equivalent to setting `$env:PREFLIGHT_SKIP='true'`.
    Provided as an emergency escape hatch for the `azd` preprovision hook.

.PARAMETER SkipRegional
    Skip only the regional-readiness block (provider/location support,
    jumpbox VM SKU availability, AI model quota, transient capacity warnings).
    Equivalent to setting `$env:LZ_PREFLIGHT_REGIONAL_SKIP='true'`. All other
    deterministic checks still run.

.EXAMPLE
    pwsh ./scripts/Invoke-PreflightChecks.ps1

    Run the default pre-flight against the current azd env.

.EXAMPLE
    pwsh ./scripts/Invoke-PreflightChecks.ps1 -Strict -SkipAzureLookups

    CI mode: only the deterministic parameter checks, fail on warnings.

.NOTES
    Exit codes
        0 — pass (possibly with warnings; warnings non-fatal unless -Strict)
        1 — fatal: at least one FAIL finding
        2 — warnings only, but -Strict was set
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$AzdEnv = $env:AZURE_ENV_NAME,
    [string]$ParametersFile,
    [switch]$Strict,
    [switch]$SkipAzureLookups,
    [switch]$Skip,
    [switch]$SkipRegional
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Emergency bypass
# --------------------------------------------------------------------------
if ($Skip -or $env:PREFLIGHT_SKIP -eq 'true' -or $env:PREFLIGHT_SKIP -eq '1') {
    Write-Host "[preflight] Skipped (PREFLIGHT_SKIP=true)." -ForegroundColor Yellow
    exit 0
}

# --------------------------------------------------------------------------
# Findings accumulator
# --------------------------------------------------------------------------
$script:Findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'INFO', 'WARN', 'FAIL')] [string]$Severity,
        [Parameter(Mandatory)] [string]$Code,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Hint
    )
    $script:Findings.Add([pscustomobject]@{
            Severity = $Severity
            Code     = $Code
            Message  = $Message
            Hint     = $Hint
        }) | Out-Null
}

# --------------------------------------------------------------------------
# CIDR helpers (pure PowerShell, no external dependencies)
# --------------------------------------------------------------------------

function ConvertTo-IpUint32 {
    param([string]$Ip)
    $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    if ($bytes.Length -ne 4) { throw "Only IPv4 supported; got '$Ip'." }
    [Array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function Get-CidrRange {
    param([Parameter(Mandatory)] [string]$Cidr)
    $parts = $Cidr -split '/', 2
    $ip = $parts[0]
    $prefix = if ($parts.Count -eq 2) { [int]$parts[1] } else { 32 }
    if ($prefix -lt 0 -or $prefix -gt 32) { throw "Invalid prefix length '$prefix' in '$Cidr'." }
    $ipVal = ConvertTo-IpUint32 -Ip $ip
    if ($prefix -eq 0) {
        $maskVal = [uint32]0
        $size = [uint64]4294967296
    }
    else {
        $hostBitCount = 32 - $prefix
        $hostMax = [uint32]([math]::Pow(2, $hostBitCount) - 1)
        $maskVal = [uint32]([uint64][uint32]::MaxValue - $hostMax)
        $size = [uint64]($hostMax + 1)
    }
    $start = [uint32]($ipVal -band $maskVal)
    $end = [uint32]($start + ($size - 1))
    [pscustomobject]@{ Start = [uint32]$start; End = $end; Prefix = $prefix; Cidr = $Cidr }
}

function Test-CidrOverlap {
    param([string]$A, [string]$B)
    $ra = Get-CidrRange -Cidr $A
    $rb = Get-CidrRange -Cidr $B
    return ($ra.Start -le $rb.End) -and ($rb.Start -le $ra.End)
}

function Test-CidrContains {
    param([string]$Outer, [string]$Inner)
    $ro = Get-CidrRange -Cidr $Outer
    $ri = Get-CidrRange -Cidr $Inner
    return ($ri.Start -ge $ro.Start) -and ($ri.End -le $ro.End)
}

# --------------------------------------------------------------------------
# Parameter resolution: read azd env values, layer over ${VAR=default} substitutions
# --------------------------------------------------------------------------

function Get-AzdEnvValues {
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) { return @{} }
    try {
        $azdArgs = @('env', 'get-values')
        if ($AzdEnv) { $azdArgs += @('--environment', $AzdEnv) }
        $raw = & azd @azdArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return @{} }
        $h = @{}
        foreach ($line in $raw) {
            if ($line -notmatch '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') {
                continue
            }

            $name = $matches[1]
            $serializedValue = $matches[2].Trim()
            if ($serializedValue.StartsWith('"') -and $serializedValue.EndsWith('"')) {
                $h[$name] = [string]($serializedValue | ConvertFrom-Json)
            }
            else {
                $h[$name] = $serializedValue
            }
        }
        return $h
    }
    catch {
        return @{}
    }
}

function Expand-ParamValue {
    param(
        $Raw,
        [hashtable]$EnvValues
    )
    if ($null -eq $Raw) { return $null }
    if ($Raw -isnot [string]) { return $Raw }
    # Match ${NAME} or ${NAME=default}
    $regex = [regex]'\$\{([A-Z0-9_]+)(?:=([^}]*))?\}'
    return $regex.Replace($Raw, {
            param($m)
            $name = $m.Groups[1].Value
            $def = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { '' }
            if ($EnvValues.ContainsKey($name)) {
                return $EnvValues[$name]
            }
            return $def
        })
}

function Get-EffectiveParameters {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Add-Finding -Severity FAIL -Code 'PARAMS_FILE_MISSING' -Message "Parameters file '$Path' not found."
        return @{}
    }
    $jsonRaw = Get-Content -Path $Path -Raw
    try {
        $parsed = $jsonRaw | ConvertFrom-Json
    }
    catch {
        Add-Finding -Severity FAIL -Code 'PARAMS_FILE_INVALID' -Message "Parameters file '$Path' is not valid JSON: $_"
        return @{}
    }
    if (-not $parsed.parameters) {
        Add-Finding -Severity FAIL -Code 'PARAMS_FILE_NO_PARAMETERS' -Message "Parameters file '$Path' has no 'parameters' key."
        return @{}
    }

    $envValues = Get-AzdEnvValues
    $effective = @{}
    $unresolvedRegex = [regex]'\$\{[A-Z0-9_]+\}'

    foreach ($prop in $parsed.parameters.PSObject.Properties) {
        $name = $prop.Name
        $rawVal = $prop.Value.value
        $expanded = Expand-ParamValue -Raw $rawVal -EnvValues $envValues
        if ($expanded -is [string] -and $unresolvedRegex.IsMatch($expanded)) {
            Add-Finding -Severity WARN -Code 'PARAM_UNRESOLVED' `
                -Message "Parameter '$name' still has unresolved environment tokens after substitution: '$expanded'." `
                -Hint "Set the missing env vars via 'azd env set <NAME> <VALUE>', or supply a default in main.parameters.json."
        }
        $effective[$name] = $expanded
    }
    return $effective
}

function ConvertTo-Bool {
    param($V)
    if ($null -eq $V) { return $false }
    if ($V -is [bool]) { return $V }
    if ($V -is [string]) {
        switch ($V.Trim().ToLowerInvariant()) {
            'true' { return $true }
            '1' { return $true }
            'yes' { return $true }
            default { return $false }
        }
    }
    return [bool]$V
}

function Get-StringValue {
    param($V)
    if ($null -eq $V) { return '' }
    if ($V -is [string]) { return $V }
    return [string]$V
}

function Get-ArrayValue {
    param($V)
    if ($null -eq $V) { return @() }
    if ($V -is [System.Collections.IEnumerable] -and $V -isnot [string]) { return @($V) }
    if ($V -is [string]) {
        $s = $V.Trim()
        if ([string]::IsNullOrEmpty($s)) { return @() }
        if ($s.StartsWith('[')) {
            try { return @(($s | ConvertFrom-Json)) } catch { }
        }
        return @($s)
    }
    return @($V)
}

function Resolve-DeployJumpbox {
    # Mirror main.bicep `_deployJumpbox`:
    #   deployJumpbox ?? deployVM ?? (networkIsolation && !existingJumpboxResourceId)
    # main.parameters.json substitutes unset env vars as the literal string 'null'
    # (e.g. "${DEPLOY_JUMPBOX=null}"), which ConvertTo-Bool would silently turn
    # into $false and mask the Bicep default. Honor explicit true/false here and
    # otherwise fall through to the same default-derivation Bicep uses.
    param([hashtable]$P)
    foreach ($key in 'deployJumpbox', 'deployVM') {
        $raw = (Get-StringValue $P[$key]).Trim().ToLowerInvariant()
        if ($raw -in 'true', '1', 'yes')  { return $true }
        if ($raw -in 'false', '0', 'no')  { return $false }
    }
    $hasExisting = -not [string]::IsNullOrWhiteSpace((Get-StringValue $P['existingJumpboxResourceId']))
    return (ConvertTo-Bool $P['networkIsolation']) -and -not $hasExisting
}

function Resolve-DeployFlag {
    # Resolve a feature-flag parameter to a bool, honoring an explicit value and
    # falling back to $Default when the parameter is null, empty, or still an
    # unresolved '${VAR}' token. Mirrors the default-on/off semantics expressed
    # in main.parameters.json (e.g. "${DEPLOY_SEARCH_SERVICE=true}").
    param(
        [hashtable]$P,
        [Parameter(Mandatory)] [string]$Key,
        [bool]$Default
    )
    $raw = Get-StringValue $P[$Key]
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    if ($raw -match '^\$\{') { return $Default }
    return [bool](ConvertTo-Bool $raw)
}

function Get-ApiManagementTopologyShape {
    # The two network shapes in which this template creates a gateway, mirroring
    # _apiManagementTopologySupported in main.bicep (ADR-001, ADR-002). Returns
    # 'NewSpoke' when this deployment owns the injection subnet, its NSG and its
    # route table; 'PreparedSpoke' when an operator owns them (useExistingVNet
    # with deploySubnets=false); otherwise ''.
    param([hashtable]$P)

    $apimCommon = (ConvertTo-Bool $P['networkIsolation']) -and
        (Get-StringValue $P['deploymentMode']) -eq 'ailz-integrated' -and
        -not (ConvertTo-Bool $P['deployAzureFirewall']) -and
        -not [string]::IsNullOrWhiteSpace((Get-StringValue $P['hubIntegrationHubVnetResourceId']))
    if (-not $apimCommon) { return '' }

    $useExistingVNet = ConvertTo-Bool $P['useExistingVNet']
    if (-not $useExistingVNet -and
        (Resolve-DeployFlag -P $P -Key 'deployNsgs' -Default $true) -and
        -not [string]::IsNullOrWhiteSpace((Get-StringValue $P['hubIntegrationEgressNextHopIp'])) -and
        [string]::IsNullOrWhiteSpace((Get-StringValue $P['hubIntegrationExistingRouteTableResourceId']))) {
        return 'NewSpoke'
    }
    if ($useExistingVNet -and -not (Resolve-DeployFlag -P $P -Key 'deploySubnets' -Default $true)) {
        return 'PreparedSpoke'
    }
    return ''
}

function Test-BooleanParameterValues {
    param([hashtable]$P)

    $booleanParameters = [ordered]@{
        deployCosmosDb             = 'DEPLOY_COSMOS_DB'
        deployContainerApps        = 'DEPLOY_CONTAINER_APPS'
        deployContainerRegistry    = 'DEPLOY_CONTAINER_REGISTRY'
        deployContainerEnv         = 'DEPLOY_CONTAINER_ENV'
        deployApiManagement        = 'DEPLOY_API_MANAGEMENT'
        deployNsgs                 = 'DEPLOY_NSGS'
        aiFoundryDisableLocalAuth  = 'AI_FOUNDRY_DISABLE_LOCAL_AUTH'
    }

    foreach ($entry in $booleanParameters.GetEnumerator()) {
        if (-not $P.ContainsKey($entry.Key)) { continue }

        $value = $P[$entry.Key]
        if ($value -is [bool]) { continue }

        $normalized = (Get-StringValue $value).Trim().ToLowerInvariant()
        if ($normalized -notin 'true', 'false') {
            Add-Finding -Severity FAIL -Code 'BOOL_VALUE_INVALID' `
                -Message "Parameter '$($entry.Key)' from $($entry.Value) must be 'true' or 'false'; received '$value'." `
                -Hint "Run 'azd env set $($entry.Value) true' or 'azd env set $($entry.Value) false'. Values such as yes/no and 1/0 are not accepted."
        }
    }
}

# --------------------------------------------------------------------------
# Deterministic topology checks (no Azure calls)
# --------------------------------------------------------------------------

function Get-AzdMinimumVersion {
    # azd enforces requiredVersions.azd itself whenever it loads azure.yaml.
    # This mirrors that floor for runs azd does not gate: a standalone
    # preflight, the script's full What-If preview, or a consumer project whose
    # own azure.yaml wires this script as its preprovision hook.
    $path = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'azure.yaml'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $match = [regex]::Match((Get-Content -LiteralPath $path -Raw), '(?m)^requiredVersions:[ \t]*\r?\n(?:[ \t]+.*\r?\n)*?[ \t]+azd:[ \t]*["'']?>=[ \t]*(\d+\.\d+\.\d+)')
    if (-not $match.Success) { return $null }
    return [version]$match.Groups[1].Value
}

function Get-AzdVersion {
    try {
        $raw = & azd version --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $match = [regex]::Match([string](($raw -join "`n" | ConvertFrom-Json).azd.version), '^\d+\.\d+\.\d+')
        if (-not $match.Success) { return $null }
        return [version]$match.Value
    }
    catch {
        return $null
    }
}

function Test-Tooling {
    param([string]$ParametersPath)

    foreach ($t in 'pwsh', 'az') {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            Add-Finding -Severity FAIL -Code 'TOOL_MISSING' -Message "'$t' is not on PATH." `
                -Hint "Install Azure CLI (https://aka.ms/installazcli) and PowerShell 7 (https://aka.ms/install-pwsh)."
        }
    }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        Add-Finding -Severity WARN -Code 'AZD_MISSING' -Message "'azd' is not on PATH — env-var values cannot be sourced from the azd environment." `
            -Hint "Install Azure Developer CLI (https://aka.ms/azd-install)."
    }
    elseif (-not $SkipAzureLookups) {
        # The floor matters only when azd substitutes this parameters file. The
        # GitHub protected-delivery path deploys a resolved, literal file with
        # az deployment and never runs azd, so its runner's azd is irrelevant.
        $usesAzdSubstitution = $ParametersPath -and (Test-Path -LiteralPath $ParametersPath) -and
            ((Get-Content -LiteralPath $ParametersPath -Raw) -match '\$\{[A-Za-z_][A-Za-z0-9_]*')
        $minimumAzd = if ($usesAzdSubstitution) { Get-AzdMinimumVersion } else { $null }
        if ($minimumAzd) {
            $currentAzd = Get-AzdVersion
            if (-not $currentAzd) {
                Add-Finding -Severity WARN -Code 'AZD_VERSION_UNKNOWN' `
                    -Message "Could not read the version of the azd on PATH. This template requires azd $minimumAzd or later." `
                    -Hint "Run 'azd version' and upgrade if it reports an older release (https://aka.ms/azure-dev/install)."
            }
            elseif ($currentAzd -lt $minimumAzd) {
                Add-Finding -Severity FAIL -Code 'AZD_VERSION_UNSUPPORTED' `
                    -Message "The azd on PATH is $currentAzd, older than $minimumAzd, the minimum in azure.yaml requiredVersions. Older releases substitute a JSON array such as API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES into main.parameters.json as a string, so provisioning fails, and 'azd down --purge' cannot read Foundry accounts." `
                    -Hint 'Upgrade azd, for example with winget upgrade Microsoft.Azd (https://aka.ms/azure-dev/install), then rerun. If you run a newer azd from another location, put it first on PATH.'
            }
        }
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Add-Finding -Severity WARN -Code 'PWSH_OLD' -Message "Running on PowerShell $($PSVersionTable.PSVersion). pwsh 7+ is recommended."
    }
}

function Test-Topology {
    param([hashtable]$P)

    $deployContainerApps = Resolve-DeployFlag -P $P -Key 'deployContainerApps' -Default $true
    $deployContainerEnv = Resolve-DeployFlag -P $P -Key 'deployContainerEnv' -Default $true
    $deployKeyVault = Resolve-DeployFlag -P $P -Key 'deployKeyVault' -Default $true
    $deployAppConfig = Resolve-DeployFlag -P $P -Key 'deployAppConfig' -Default $true
    $deployNsgs = Resolve-DeployFlag -P $P -Key 'deployNsgs' -Default $true
    $useContainerAppApiKey = Resolve-DeployFlag -P $P -Key 'useCAppAPIKey' -Default $false
    $runtimeConfigMode = (Get-StringValue $P['appRuntimeConfigurationMode']).Trim()

    $deployApiManagement = Resolve-DeployFlag -P $P -Key 'deployApiManagement' -Default $false

    if ($deployContainerApps -and -not $deployContainerEnv) {
        Add-Finding -Severity FAIL -Code 'ACA_APPS_REQUIRE_ENV' `
            -Message 'deployContainerApps=true requires deployContainerEnv=true.' `
            -Hint 'Enable DEPLOY_CONTAINER_ENV or disable DEPLOY_CONTAINER_APPS.'
    }
    elseif ($deployContainerEnv -and -not $deployContainerApps) {
        Add-Finding -Severity INFO -Code 'ACA_ENVIRONMENT_ONLY' `
            -Message 'The Container Apps environment will be deployed without any Container Apps.'
    }

    if ($useContainerAppApiKey -and -not (
            $deployContainerApps -and
            $deployKeyVault -and
            $deployAppConfig -and
            $runtimeConfigMode -eq 'appConfig'
        )) {
        Add-Finding -Severity FAIL -Code 'CAPP_API_KEY_PREREQUISITES' `
            -Message 'useCAppAPIKey=true requires Container Apps, Key Vault, App Configuration, and appRuntimeConfigurationMode=appConfig.' `
            -Hint 'Enable all API-key prerequisites or set useCAppAPIKey=false.'
    }

    # Private DNS conflict: policy-managed + BYO overrides
    $policyMgr = ConvertTo-Bool $P['policyManagedPrivateDns']
    $byoDnsParams = $P.Keys | Where-Object { $_ -like 'existingPrivateDnsZone*ResourceId' }
    $byoDnsSet = @($byoDnsParams | Where-Object { -not [string]::IsNullOrEmpty((Get-StringValue $P[$_])) })
    if ($policyMgr -and $byoDnsSet.Count -gt 0) {
        Add-Finding -Severity FAIL -Code 'DNS_POLICY_VS_BYO' `
            -Message "policyManagedPrivateDns=true conflicts with BYO Private DNS overrides: $($byoDnsSet -join ', ')." `
            -Hint "Pick one: either let policy manage Private DNS (clear all existingPrivateDnsZone*ResourceId), or supply BYO zones explicitly (set policyManagedPrivateDns=false)."
    }

    # Egress mutex
    $egressIp = Get-StringValue $P['hubIntegrationEgressNextHopIp']
    $existingRt = Get-StringValue $P['hubIntegrationExistingRouteTableResourceId']
    if (-not [string]::IsNullOrEmpty($egressIp) -and -not [string]::IsNullOrEmpty($existingRt)) {
        Add-Finding -Severity FAIL -Code 'EGRESS_MUTEX' `
            -Message "hubIntegrationEgressNextHopIp and hubIntegrationExistingRouteTableResourceId are mutually exclusive." `
            -Hint "Either let the spoke deploy its own route table pointing at the hub next-hop IP, OR bring an existing route table — not both."
    }

    # Local firewall + external egress
    $deployFw = ConvertTo-Bool $P['deployAzureFirewall']
    if ($deployFw -and -not [string]::IsNullOrEmpty($egressIp)) {
        Add-Finding -Severity WARN -Code 'FW_AND_EXTERNAL_EGRESS' `
            -Message "deployAzureFirewall=true with hubIntegrationEgressNextHopIp set: a local spoke firewall AND an external egress IP are both configured." `
            -Hint "In ailz-integrated topologies the hub firewall is typically the only egress point — consider deployAzureFirewall=false."
    }

    # deploymentMode = ailz-integrated declared but no hub integration
    $mode = Get-StringValue $P['deploymentMode']
    if ($mode -eq 'ailz-integrated') {
        $hubSignals = @(
            (Get-StringValue $P['hubIntegrationHubVnetResourceId']),
            (Get-StringValue $P['hubIntegrationEgressNextHopIp']),
            (Get-StringValue $P['hubIntegrationExistingRouteTableResourceId'])
        ) | Where-Object { -not [string]::IsNullOrEmpty($_) }
        if ($hubSignals.Count -eq 0) {
            Add-Finding -Severity WARN -Code 'AILZ_NO_HUB_PARAMS' `
                -Message "deploymentMode=ailz-integrated but none of (hubIntegrationHubVnetResourceId, hubIntegrationEgressNextHopIp, hubIntegrationExistingRouteTableResourceId) are set." `
                -Hint "Either set the hub integration parameters or change deploymentMode to 'standalone'."
        }
    }

    # Observability: existing App Insights without connection string
    $hasExistAppI = -not [string]::IsNullOrEmpty((Get-StringValue $P['existingApplicationInsightsResourceId']))
    $hasExistLaw = -not [string]::IsNullOrEmpty((Get-StringValue $P['existingLogAnalyticsWorkspaceResourceId']))
    $hasExistConn = -not [string]::IsNullOrEmpty((Get-StringValue $P['existingApplicationInsightsConnectionString']))
    $allowMixed = ConvertTo-Bool $P['allowMixedObservabilityWorkspaces']

    if ($hasExistAppI -and -not $hasExistConn) {
        Add-Finding -Severity FAIL -Code 'APPI_NO_CONNSTR' `
            -Message "existingApplicationInsightsResourceId is set but existingApplicationInsightsConnectionString is empty." `
            -Hint "Run 'az monitor app-insights component show -g <rg> -a <name> --query connectionString -o tsv' and set EXISTING_APPLICATION_INSIGHTS_CONNECTION_STRING."
    }
    if ($hasExistAppI -and -not $hasExistLaw -and -not $allowMixed) {
        Add-Finding -Severity FAIL -Code 'APPI_NO_LAW' `
            -Message "existingApplicationInsightsResourceId is set without a matching existingLogAnalyticsWorkspaceResourceId." `
            -Hint "Either also set EXISTING_LOG_ANALYTICS_WORKSPACE_RESOURCE_ID to the LAW that backs your App Insights, or set ALLOW_MIXED_OBSERVABILITY_WORKSPACES=true if the split is intentional."
    }

    # Network isolation without any access path
    $netIso = ConvertTo-Bool $P['networkIsolation']
    $useExistingVNet = ConvertTo-Bool $P['useExistingVNet']
    $deploySubnets = Resolve-DeployFlag -P $P -Key 'deploySubnets' -Default $true

    if ($deployApiManagement) {
        $publisherEmail = (Get-StringValue $P['apiManagementPublisherEmail']).Trim()
        $ingressPrefixes = Get-ArrayValue $P['apiManagementIngressSourceAddressPrefixes']
        $directCallerPrefixes = Get-ArrayValue $P['apiManagementDirectCallerAddressPrefixes']

        if ($publisherEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Add-Finding -Severity FAIL -Code 'APIM_PUBLISHER_EMAIL_INVALID' `
                -Message 'deployApiManagement=true requires a valid apiManagementPublisherEmail.' `
                -Hint 'Set API_MANAGEMENT_PUBLISHER_EMAIL to the operational owner of the API Management instance.'
        }

        # Two supported network shapes (ADR-002): a new spoke whose injection
        # subnet, NSG and route table this deployment owns, or a prepared spoke
        # whose injection subnet an operator owns.
        $apimShape = Get-ApiManagementTopologyShape -P $P
        $apimNewSpoke = $apimShape -eq 'NewSpoke'
        $apimPreparedSpoke = $apimShape -eq 'PreparedSpoke'

        if (-not $apimNewSpoke -and -not $apimPreparedSpoke) {
            Add-Finding -Severity FAIL -Code 'APIM_TOPOLOGY_UNSUPPORTED' `
                -Message 'API Management requires networkIsolation=true, deploymentMode=ailz-integrated, a hub VNet resource ID and no local firewall. It also needs either a new spoke with managed NSGs, a hub firewall next-hop IP and no platform-owned route table, or a prepared spoke (useExistingVNet=true, deploySubnets=false) whose injection subnet an operator owns.' `
                -Hint 'Use Deploy-AilzIntegrated.ps1 for a new spoke. API Management does not support updating subnets in an existing VNet (useExistingVNet=true with deploySubnets=true).'
        }

        if ($apimPreparedSpoke) {
            Add-Finding -Severity WARN -Code 'APIM_PREPARED_SUBNET_OBLIGATION' `
                -Message 'API Management will be injected into an operator-prepared subnet. This deployment does not manage that subnet, its NSG or its route table.' `
                -Hint 'Before provisioning, confirm the subnet is undelegated and carries the rule set in modules/networking/api-management-injection-nsg.bicep, including the hub-firewall-only ingress rules. It must also route the ApiManagement service tag to Internet whenever 0.0.0.0/0 goes to a firewall.'
        }
        else {
            try {
                if ($ingressPrefixes.Count -eq 0) {
                    throw 'At least one CIDR is required.'
                }

                foreach ($entry in $ingressPrefixes) {
                    $cidr = (Get-StringValue $entry).Trim()
                    if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
                        throw "'$cidr' is not an IPv4 CIDR."
                    }
                    Get-CidrRange -Cidr $cidr | Out-Null
                    if ($cidr -eq '0.0.0.0/0') {
                        throw '0.0.0.0/0 cannot enforce hub-firewall-only ingress.'
                    }
                }
            }
            catch {
                Add-Finding -Severity FAIL -Code 'APIM_INGRESS_PREFIXES_INVALID' `
                    -Message "apiManagementIngressSourceAddressPrefixes must be a non-empty array of restricted IPv4 CIDRs: $_" `
                    -Hint 'Set API_MANAGEMENT_INGRESS_SOURCE_ADDRESS_PREFIXES to the hub AzureFirewallSubnet prefix. Azure Firewall source-NATs gateway traffic to a back-end instance IP in that subnet, not to its frontend IP. Deploy-AilzIntegrated.ps1 looks it up by default.'
            }
        }

        try {
            foreach ($entry in $directCallerPrefixes) {
                $cidr = (Get-StringValue $entry).Trim()
                if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
                    throw "'$cidr' is not an IPv4 CIDR."
                }
                Get-CidrRange -Cidr $cidr | Out-Null
                if ($cidr -eq '0.0.0.0/0') {
                    throw '0.0.0.0/0 would bypass the hub firewall for every caller.'
                }
            }
        }
        catch {
            Add-Finding -Severity FAIL -Code 'APIM_DIRECT_CALLER_PREFIXES_INVALID' `
                -Message "apiManagementDirectCallerAddressPrefixes must contain only restricted IPv4 CIDRs of subnets inside this spoke: $_" `
                -Hint 'List only in-spoke caller subnets. Callers outside the spoke must reach the gateway through the hub firewall.'
        }
    }

    if ($netIso -and $useExistingVNet -and $deploySubnets -and -not $deployNsgs) {
        Add-Finding -Severity FAIL -Code 'BYO_SUBNET_NSG_DETACH' `
            -Message 'A network-isolated deployment cannot update subnets in an existing VNet while deployNsgs=false because existing NSG associations would be removed.' `
            -Hint 'Set DEPLOY_NSGS=true, or set deploySubnets=false and manage the existing subnets and NSG associations outside this deployment.'
    }
    elseif (-not $deployNsgs) {
        Add-Finding -Severity WARN -Code 'NSGS_DISABLED' `
            -Message 'Network security group deployment is disabled. Verify that every workload subnet retains equivalent controls.'
    }

    $disableFoundryLocalAuth = Resolve-DeployFlag -P $P -Key 'aiFoundryDisableLocalAuth' -Default $true
    if (-not $disableFoundryLocalAuth) {
        Add-Finding -Severity WARN -Code 'AI_FOUNDRY_LOCAL_AUTH_ENABLED' `
            -Message 'AI Foundry local API-key authentication is enabled.' `
            -Hint 'Keep AI_FOUNDRY_DISABLE_LOCAL_AUTH=true unless API-key authentication is an explicit requirement.'
    }

    $deployJump = Resolve-DeployJumpbox $P
    $allowedIps = Get-ArrayValue $P['allowedIpRanges']
    if ($netIso -and -not $deployJump -and $allowedIps.Count -eq 0) {
        Add-Finding -Severity WARN -Code 'ISO_NO_INGRESS' `
            -Message "networkIsolation=true but no jumpbox/VM is deployed and allowedIpRanges is empty." `
            -Hint "You will not have any way to reach the workload after deployment. Set DEPLOY_JUMPBOX=true, ALLOWED_IP_RANGES=<your-ip>, or plan to use an existing hub jumpbox via EXISTING_JUMPBOX_RESOURCE_ID."
    }
}

function Test-HostedAgentConfiguration {
    param([hashtable]$P)

    $prepareHostedAgent = Resolve-DeployFlag -P $P -Key 'prepareHostedAgent' -Default $false
    $deployHostedAgent = Resolve-DeployFlag -P $P -Key 'deployHostedAgent' -Default $false
    if (-not ($prepareHostedAgent -or $deployHostedAgent)) { return }

    $deployAiFoundry = Resolve-DeployFlag -P $P -Key 'deployAiFoundry' -Default $true
    if (-not $deployAiFoundry) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_FOUNDRY_REQUIRED' `
            -Message 'Hosted-agent preparation or deployment requires deployAiFoundry=true.' `
            -Hint 'Enable the shared Foundry account/project or disable hosted-agent prerequisites.'
    }

    $deployRegistry = Resolve-DeployFlag -P $P -Key 'deployContainerRegistry' -Default $true
    $existingRegistryId = (Get-StringValue $P['hostedAgentContainerRegistryResourceId']).Trim()
    $existingRegistryEndpoint = (Get-StringValue $P['hostedAgentContainerRegistryEndpoint']).Trim()
    $registryRoleAssignmentMode = (Get-StringValue $P['hostedAgentContainerRegistryRoleAssignmentMode']).Trim()
    if ([string]::IsNullOrWhiteSpace($registryRoleAssignmentMode)) {
        $registryRoleAssignmentMode = 'rbac'
    }
    if ($registryRoleAssignmentMode -notin @('rbac', 'rbac-abac')) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_REGISTRY_ROLE_MODE_INVALID' `
            -Message 'hostedAgentContainerRegistryRoleAssignmentMode must be rbac or rbac-abac.' `
            -Hint 'Use rbac for RBAC Registry Permissions or rbac-abac for RBAC Registry + ABAC Repository Permissions.'
    }
    if (-not $deployRegistry -and ([string]::IsNullOrWhiteSpace($existingRegistryId) -or [string]::IsNullOrWhiteSpace($existingRegistryEndpoint))) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_REGISTRY_REQUIRED' `
            -Message 'Hosted-agent preparation or deployment requires the landing-zone registry or both existing registry inputs.' `
            -Hint 'Enable DEPLOY_CONTAINER_REGISTRY, or set HOSTED_AGENT_CONTAINER_REGISTRY_RESOURCE_ID and HOSTED_AGENT_CONTAINER_REGISTRY_ENDPOINT.'
    }

    if ((ConvertTo-Bool $P['networkIsolation'])) {
        Add-Finding -Severity INFO -Code 'HOSTED_AGENT_PRIVATE_BUILD_REQUIRED' `
            -Message 'The hosted-agent registry is private. Build and push from a VNet-connected runner/agent or the jumpbox fallback; shared ACR Tasks do not bypass private endpoint access.'
    }

    if (-not $deployHostedAgent) { return }

    $agent = $P['hostedAgent']
    if ($null -eq $agent) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_CONFIG_REQUIRED' -Message 'deployHostedAgent=true requires the typed hostedAgent object.'
        return
    }

    if (@($agent.PSObject.Properties.Name) -contains 'roles') {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_ROLES_UNSUPPORTED' `
            -Message 'hostedAgent.roles is not supported because the hosted-agent identity is created by downstream azd deploy.' `
            -Hint 'After deployment, use the emitted agent identity and explicit Azure role definition IDs to assign least-privilege access to external resources.'
    }

    $envValues = Get-AzdEnvValues
    $name = (Get-StringValue (Expand-ParamValue -Raw $agent.name -EnvValues $envValues)).Trim()
    $image = (Get-StringValue (Expand-ParamValue -Raw $agent.image -EnvValues $envValues)).Trim()
    $version = Get-StringValue (Expand-ParamValue -Raw $agent.version -EnvValues $envValues)
    $startupCommand = (Get-StringValue (Expand-ParamValue -Raw $agent.startupCommand -EnvValues $envValues)).Trim()
    $cpu = (Get-StringValue (Expand-ParamValue -Raw $agent.runtime.cpu -EnvValues $envValues)).Trim()
    $memory = (Get-StringValue (Expand-ParamValue -Raw $agent.runtime.memory -EnvValues $envValues)).Trim()

    foreach ($required in @(
            @{ Name = 'name'; Value = $name },
            @{ Name = 'image'; Value = $image },
            @{ Name = 'runtime.cpu'; Value = $cpu },
            @{ Name = 'runtime.memory'; Value = $memory }
        )) {
        if ([string]::IsNullOrWhiteSpace($required.Value)) {
            Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_CONFIG_REQUIRED' `
                -Message "hostedAgent.$($required.Name) is required when deployHostedAgent=true."
        }
    }

    if ($version -cnotmatch '\Asha256:[0-9a-f]{64}\z') {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_IMAGE_NOT_IMMUTABLE' `
            -Message 'hostedAgent.version must use the exact immutable OCI digest syntax sha256:<64 lowercase hex characters>, without surrounding whitespace.' `
            -Hint 'Build and push the image first, then pin the digest rather than using a mutable tag.'
    }

    [double]$cpuValue = 0
    $cpuIsValid = [double]::TryParse(
        $cpu,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$cpuValue
    ) -and $cpuValue -ge 0.25 -and $cpuValue -le 4.0
    if (-not $cpuIsValid) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_CPU_INVALID' `
            -Message 'hostedAgent.runtime.cpu must be a number from 0.25 through 4.0.' `
            -Hint 'Use a value supported by the current azure.ai.agent container.resources contract, for example 0.5 or 1.'
    }

    $memoryMatch = [regex]::Match($memory, '^(?<value>\d+(?:\.\d+)?)Gi$')
    [double]$memoryValue = 0
    $memoryIsValid = $memoryMatch.Success -and [double]::TryParse(
        $memoryMatch.Groups['value'].Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$memoryValue
    ) -and $memoryValue -ge 0.5 -and $memoryValue -le 8.0
    if (-not $memoryIsValid) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_MEMORY_INVALID' `
            -Message 'hostedAgent.runtime.memory must use Gi units with a value from 0.5Gi through 8Gi.' `
            -Hint 'Use a value supported by the current azure.ai.agent container.resources contract, for example 0.5Gi or 1Gi.'
    }

    $protocols = @($agent.protocols)
    if ($protocols.Count -eq 0) {
        Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_PROTOCOL_REQUIRED' `
            -Message 'hostedAgent.protocols must contain at least one supported invocation protocol.'
    }
    foreach ($protocol in $protocols) {
        $protocolName = (Get-StringValue (Expand-ParamValue -Raw $protocol.protocol -EnvValues $envValues)).Trim()
        if ($protocolName -notin @('responses', 'invocations', 'invocations_ws', 'a2a')) {
            Add-Finding -Severity FAIL -Code 'HOSTED_AGENT_PROTOCOL_INVALID' `
                -Message "Hosted-agent protocol '$protocolName' is not supported by the current Microsoft Foundry contract."
        }
    }

}

function Test-AllowedIpRanges {
    param([hashtable]$P)
    $list = Get-ArrayValue $P['allowedIpRanges']
    if ($list.Count -eq 0) { return }
    foreach ($entry in $list) {
        $cidr = (Get-StringValue $entry).Trim()
        if ([string]::IsNullOrEmpty($cidr)) { continue }
        if ($cidr -eq '0.0.0.0/0' -or $cidr -eq '0.0.0.0') {
            Add-Finding -Severity WARN -Code 'IP_ANY' `
                -Message "allowedIpRanges contains '$cidr' — this is equivalent to no restriction." `
                -Hint "Tighten the allow-list to specific developer or runner CIDRs."
            continue
        }
        if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$') {
            Add-Finding -Severity FAIL -Code 'IP_FORMAT' `
                -Message "allowedIpRanges entry '$cidr' is not a valid IPv4 CIDR." `
                -Hint "Use X.X.X.X or X.X.X.X/Y format."
            continue
        }
        try { Get-CidrRange -Cidr $cidr | Out-Null }
        catch {
            Add-Finding -Severity FAIL -Code 'IP_PARSE' -Message "allowedIpRanges entry '$cidr' did not parse: $_"
        }
    }
}

function Test-LocalCidrSanity {
    param([hashtable]$P)

    $vnetPrefixes = Get-ArrayValue $P['vnetAddressPrefixes'] | ForEach-Object { Get-StringValue $_ } | Where-Object { -not [string]::IsNullOrEmpty($_) }
    if ($vnetPrefixes.Count -eq 0) { return }

    # Validate VNet prefixes themselves
    foreach ($vp in $vnetPrefixes) {
        try { Get-CidrRange -Cidr $vp | Out-Null }
        catch {
            Add-Finding -Severity FAIL -Code 'VNET_CIDR_BAD' -Message "vnetAddressPrefixes entry '$vp' is not a valid CIDR: $_"
            return
        }
    }

    # Collect declared subnet prefixes
    $subnetKeys = @(
        'agentSubnetPrefix',
        'apiManagementSubnetPrefix',
        'peSubnetPrefix',
        'acaEnvironmentSubnetPrefix',
        'azureBastionSubnetPrefix',
        'azureFirewallSubnetPrefix',
        'jumpboxSubnetPrefix',
        'devopsBuildAgentsSubnetPrefix'
    )
    $subnets = @()
    foreach ($k in $subnetKeys) {
        $v = Get-StringValue $P[$k]
        if ([string]::IsNullOrEmpty($v)) { continue }
        if ($v -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
            Add-Finding -Severity FAIL -Code 'SUBNET_CIDR_BAD' -Message "Subnet '$k' value '$v' is not a valid CIDR."
            continue
        }
        try {
            $r = Get-CidrRange -Cidr $v
            $subnets += [pscustomobject]@{ Name = $k; Cidr = $v; Range = $r }
        }
        catch {
            Add-Finding -Severity FAIL -Code 'SUBNET_CIDR_BAD' -Message "Subnet '$k' value '$v' did not parse: $_"
        }
    }

    # Each subnet contained in a vnet prefix
    foreach ($s in $subnets) {
        $contained = $false
        foreach ($vp in $vnetPrefixes) {
            if (Test-CidrContains -Outer $vp -Inner $s.Cidr) { $contained = $true; break }
        }
        if (-not $contained) {
            Add-Finding -Severity FAIL -Code 'SUBNET_OUTSIDE_VNET' `
                -Message "Subnet '$($s.Name)' ($($s.Cidr)) is not contained in any vnetAddressPrefixes entry: $($vnetPrefixes -join ', ')." `
                -Hint "Either widen vnetAddressPrefixes to include this range, or adjust the subnet prefix to fit inside one of the configured VNet ranges."
        }
    }

    # Subnets do not overlap each other
    for ($i = 0; $i -lt $subnets.Count; $i++) {
        for ($j = $i + 1; $j -lt $subnets.Count; $j++) {
            if (Test-CidrOverlap -A $subnets[$i].Cidr -B $subnets[$j].Cidr) {
                Add-Finding -Severity FAIL -Code 'SUBNET_OVERLAP' `
                    -Message "Subnet overlap: '$($subnets[$i].Name)' ($($subnets[$i].Cidr)) overlaps '$($subnets[$j].Name)' ($($subnets[$j].Cidr))." `
                    -Hint "Re-partition the spoke VNet so each subnet has a unique range."
            }
        }
    }

    # Subnet minimum sizes (Azure platform requirements)
    $minPrefix = @{
        'azureBastionSubnetPrefix'      = 26   # Azure Bastion requires /26 or larger
        'azureFirewallSubnetPrefix'     = 26   # Azure Firewall requires /26 or larger
        'apiManagementSubnetPrefix'     = 27   # API Management requires /27 or larger
        'peSubnetPrefix'                = 28   # AVM PE requirement; we recommend /27
        'jumpboxSubnetPrefix'           = 29   # one NIC needs only a few addresses
        'devopsBuildAgentsSubnetPrefix' = 28   # build agents typically a handful of VMs
    }
    foreach ($s in $subnets) {
        $req = $minPrefix[$s.Name]
        if ($req -and $s.Range.Prefix -gt $req) {
            Add-Finding -Severity FAIL -Code 'SUBNET_TOO_SMALL' `
                -Message "Subnet '$($s.Name)' ($($s.Cidr)) is /$($s.Range.Prefix); Azure requires at least /$req for this purpose." `
                -Hint "Widen the prefix in main.parameters.json (or via the matching env var)."
        }
    }

    # ACA env subnet sizing — depends on workloadProfiles
    $aca = $subnets | Where-Object { $_.Name -eq 'acaEnvironmentSubnetPrefix' }
    if ($aca) {
        $wpRaw = $P['workloadProfiles']
        $hasWorkloadProfile = $false
        if ($null -ne $wpRaw) {
            $wpArr = @()
            try {
                if ($wpRaw -is [string]) {
                    $s = ($wpRaw -as [string]).Trim()
                    if ($s.StartsWith('[')) { $wpArr = $s | ConvertFrom-Json }
                }
                else { $wpArr = $wpRaw }
            }
            catch {}
            $hasWorkloadProfile = @($wpArr | Where-Object { $_ -and $_.workloadProfileType -and $_.workloadProfileType -ne 'Consumption' }).Count -gt 0
        }
        $required = if ($hasWorkloadProfile) { 27 } else { 27 }  # /27 minimum either way
        $recommended = if ($hasWorkloadProfile) { 23 } else { 27 }
        if ($aca.Range.Prefix -gt $required) {
            Add-Finding -Severity FAIL -Code 'ACA_SUBNET_TOO_SMALL' `
                -Message "acaEnvironmentSubnetPrefix is /$($aca.Range.Prefix); Container Apps environments require at least /$required." `
                -Hint "Widen the prefix."
        }
        elseif ($hasWorkloadProfile -and $aca.Range.Prefix -gt $recommended) {
            Add-Finding -Severity WARN -Code 'ACA_SUBNET_BELOW_RECOMMENDED' `
                -Message "acaEnvironmentSubnetPrefix is /$($aca.Range.Prefix) with workload-profile mode declared; Microsoft recommends /$recommended for workload-profile ACA." `
                -Hint "Consider widening to /$recommended; see https://aka.ms/aca/networking-subnet-size."
        }
    }
}

function Test-FoundryIqConfiguration {
    param([hashtable]$P)

    $backend = (Get-StringValue $P['retrievalBackend']).Trim()
    if ([string]::IsNullOrWhiteSpace($backend)) { $backend = 'ai_search' }
    if ($backend -notin @('ai_search', 'foundry_iq')) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_BACKEND_INVALID' `
            -Message "retrievalBackend must be 'ai_search' or 'foundry_iq'; got '$backend'." `
            -Hint "Set RETRIEVAL_BACKEND to ai_search for existing deployments or foundry_iq for Foundry IQ-backed deployments."
        return
    }
    if ($backend -ne 'foundry_iq') { return }

    $deployAiFoundry = ConvertTo-Bool $P['deployAiFoundry']
    $deploySearchRaw = Get-StringValue $P['deploySearchService']
    $deploySearch = if ([string]::IsNullOrWhiteSpace($deploySearchRaw)) { $true } else { ConvertTo-Bool $deploySearchRaw }
    if (-not $deployAiFoundry) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_FOUNDRY_REQUIRED' `
            -Message "retrievalBackend is foundry_iq but deployAiFoundry is false." `
            -Hint "Enable deployAiFoundry or keep RETRIEVAL_BACKEND=ai_search until a Foundry project and knowledge base exist."
    }
    if (-not $deploySearch) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_SEARCH_REQUIRED' `
            -Message "retrievalBackend is foundry_iq but deploySearchService is false." `
            -Hint "Pattern B requires the GPT-RAG Azure AI Search service. If you use an external knowledge base, stamp KNOWLEDGE_BASE_* values outside this landing-zone module."
    }

    $pattern = (Get-StringValue $P['foundryIqPattern']).Trim()
    if ([string]::IsNullOrWhiteSpace($pattern)) { $pattern = 'azureBlob' }
    if ($pattern -notin @('azureBlob', 'managed', 'searchIndex')) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_PATTERN_INVALID' `
            -Message "foundryIqPattern must be 'azureBlob', 'managed', or 'searchIndex'; got '$pattern'."
    }

    $sourceKind = (Get-StringValue $P['foundryIqKnowledgeSourceKind']).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceKind)) { $sourceKind = if ($pattern -eq 'searchIndex') { 'searchIndex' } else { 'azureBlob' } }
    if ($sourceKind -notin @('azureBlob', 'searchIndex')) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_SOURCE_KIND_INVALID' `
            -Message "foundryIqKnowledgeSourceKind must be 'azureBlob' or 'searchIndex'; got '$sourceKind'."
    }
    elseif (($pattern -eq 'searchIndex' -and $sourceKind -ne 'searchIndex') -or ($pattern -ne 'searchIndex' -and $sourceKind -ne 'azureBlob')) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_SOURCE_KIND_CONFLICT' `
            -Message "foundryIqKnowledgeSourceKind '$sourceKind' conflicts with foundryIqPattern '$pattern'." `
            -Hint "Use FOUNDRY_IQ_PATTERN=azureBlob with FOUNDRY_IQ_KNOWLEDGE_SOURCE_KIND=azureBlob for native Blob, or set both to searchIndex for Pattern B."
    }

    $permissionOptionsJson = (Get-StringValue $P['foundryIqIngestionPermissionOptionsJson']).Trim()
    if (-not [string]::IsNullOrWhiteSpace($permissionOptionsJson)) {
        try {
            $permissionOptions = $permissionOptionsJson | ConvertFrom-Json -NoEnumerate
            if ($null -eq $permissionOptions -or $permissionOptions -isnot [array]) {
                Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_PERMISSION_OPTIONS_INVALID' `
                    -Message "foundryIqIngestionPermissionOptionsJson must be a JSON array; got '$permissionOptionsJson'."
            }
        }
        catch {
            Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_PERMISSION_OPTIONS_INVALID' `
                -Message "foundryIqIngestionPermissionOptionsJson must be valid JSON; got '$permissionOptionsJson'."
        }
    }

    $apiVersion = (Get-StringValue $P['foundryIqApiVersion']).Trim()
    $filterAddOn = ConvertTo-Bool $P['foundryIqFilterAddOnEnabled']
    if ($filterAddOn -and $apiVersion -ne '2026-05-01-preview') {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_FILTERADDON_API_VERSION' `
            -Message "FOUNDRY_IQ_FILTER_ADD_ON_ENABLED requires foundryIqApiVersion 2026-05-01-preview; got '$apiVersion'." `
            -Hint "Use 2026-05-01-preview when Pattern B query-time security trimming is enabled."
    }

    $billingPlan = (Get-StringValue $P['foundryIqKnowledgeRetrievalBillingPlan']).Trim()
    if ([string]::IsNullOrWhiteSpace($billingPlan)) { $billingPlan = 'free' }
    if ($billingPlan -notin @('free', 'standard')) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_BILLING_PLAN_INVALID' `
            -Message "foundryIqKnowledgeRetrievalBillingPlan must be 'free' or 'standard'; got '$billingPlan'."
    }
    elseif ($billingPlan -eq 'free') {
        Add-Finding -Severity INFO -Code 'FOUNDRYIQ_BILLING_FREE' `
            -Message "Foundry IQ knowledgeRetrieval billing plan is free. Retrieval calls can fail after the included monthly allowance is exhausted." `
            -Hint "Set FOUNDRY_IQ_KNOWLEDGE_RETRIEVAL_BILLING_PLAN=standard to opt in to pay-as-you-go agentic retrieval billing."
    }

    $knowledgeBaseName = (Get-StringValue $P['knowledgeBaseName']).Trim()
    if ([string]::IsNullOrWhiteSpace($knowledgeBaseName)) {
        Add-Finding -Severity FAIL -Code 'FOUNDRYIQ_KB_NAME_REQUIRED' `
            -Message "retrievalBackend is foundry_iq but knowledgeBaseName is empty."
    }

    if ($pattern -eq 'searchIndex') {
        foreach ($requiredName in @('foundryIqKnowledgeSourceName', 'foundryIqSearchIndexName', 'foundryIqSemanticConfigurationName', 'foundryIqSecurityFieldName')) {
            $value = (Get-StringValue $P[$requiredName]).Trim()
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-Finding -Severity FAIL -Code "FOUNDRYIQ_$($requiredName.ToUpperInvariant())_REQUIRED" `
                    -Message "Pattern B requires parameter '$requiredName' to be set."
            }
        }
        Add-Finding -Severity INFO -Code 'FOUNDRYIQ_PATTERN_B_SELECTED' `
            -Message "Foundry IQ Pattern B selected: the existing GPT-RAG Azure AI Search index will be used as a searchIndex knowledge source." `
            -Hint "Create or update the knowledge source/knowledge base after provisioning with scripts/Configure-FoundryIQKnowledgeBase.ps1; Bicep stamps runtime config and the dedicated connection ID."
    }
    else {
        Add-Finding -Severity WARN -Code 'FOUNDRYIQ_PATTERN_A_NATIVE_LIMITATION' `
            -Message "Foundry IQ Pattern A selected. Plain Blob sources provide container-level RBAC only; per-document trimming requires ADLS Gen2 ACLs, Purview, SharePoint, OneLake/Fabric, or Pattern B." `
            -Hint "Do not claim per-document security for plain Blob managed ingestion."
    }
}

# --------------------------------------------------------------------------
# Azure lookups (live, optional)
# --------------------------------------------------------------------------

function Invoke-AzCli {
    param([string[]]$Arguments)
    try {
        $out = & az @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ($out -join "`n" | ConvertFrom-Json)
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-AzureContext {
    if ($SkipAzureLookups) { return $null }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $ctx = Invoke-AzCli -Arguments @('account', 'show', '-o', 'json')
    if (-not $ctx) {
        Add-Finding -Severity WARN -Code 'AZ_NOT_LOGGED_IN' `
            -Message "Could not determine the current Azure context — Azure resource lookups will be skipped." `
            -Hint "Run 'az login' before deploying."
        return $null
    }
    if ($SubscriptionId -and $ctx.id -ne $SubscriptionId) {
        Add-Finding -Severity WARN -Code 'AZ_SUB_MISMATCH' `
            -Message "Pre-flight is using subscription '$SubscriptionId' but the default az context is '$($ctx.id)'." `
            -Hint "Run 'az account set --subscription $SubscriptionId'."
    }
    return $ctx
}

function Test-AzureResources {
    param([hashtable]$P)

    if ($SkipAzureLookups) {
        Add-Finding -Severity INFO -Code 'AZURE_SKIPPED' -Message "Azure resource lookups skipped (-SkipAzureLookups)."
        return
    }
    $ctx = Test-AzureContext
    if (-not $ctx) { return }

    # BYO VNet (only when useExistingVNet=true)
    $useExistingVNet = ConvertTo-Bool $P['useExistingVNet']
    $deploySubnets = ConvertTo-Bool $P['deploySubnets']
    $existingVnetRid = Get-StringValue $P['existingVnetResourceId']
    if ($useExistingVNet) {
        if ([string]::IsNullOrEmpty($existingVnetRid)) {
            Add-Finding -Severity FAIL -Code 'BYO_VNET_NO_ID' `
                -Message "useExistingVNet=true but existingVnetResourceId is empty." `
                -Hint "Set EXISTING_VNET_RESOURCE_ID to the full ARM resource ID of the spoke VNet."
        }
        else {
            $vnet = Invoke-AzCli -Arguments @('network', 'vnet', 'show', '--ids', $existingVnetRid, '-o', 'json')
            if (-not $vnet) {
                Add-Finding -Severity WARN -Code 'BYO_VNET_LOOKUP_FAILED' `
                    -Message "Could not read existing VNet '$existingVnetRid' — verify the ID is correct and the current identity has Reader on it."
            }
            else {
                # Validate subnets present when deploySubnets=false
                if (-not $deploySubnets) {
                    $requiredSubnets = @{
                        'agentSubnetName'             = (Get-StringValue $P['agentSubnetName'])
                        'peSubnetName'                = (Get-StringValue $P['peSubnetName'])
                        'acaEnvironmentSubnetName'    = (Get-StringValue $P['acaEnvironmentSubnetName'])
                        'jumpboxSubnetName'           = (Get-StringValue $P['jumpboxSubnetName'])
                        'devopsBuildAgentsSubnetName' = (Get-StringValue $P['devopsBuildAgentsSubnetName'])
                    }
                    $deployBastion = ConvertTo-Bool $P['deployBastion']
                    $deployFw = ConvertTo-Bool $P['deployAzureFirewall']
                    if ($deployBastion) { $requiredSubnets['AzureBastionSubnet'] = 'AzureBastionSubnet' }
                    if ($deployFw) { $requiredSubnets['AzureFirewallSubnet'] = 'AzureFirewallSubnet' }

                    $existingNames = @($vnet.subnets | ForEach-Object { $_.name })
                    foreach ($req in $requiredSubnets.GetEnumerator()) {
                        if ([string]::IsNullOrEmpty($req.Value)) { continue }
                        if ($existingNames -notcontains $req.Value) {
                            Add-Finding -Severity FAIL -Code 'BYO_SUBNET_MISSING' `
                                -Message "Subnet '$($req.Value)' (parameter '$($req.Key)') not found in BYO VNet '$($vnet.name)'." `
                                -Hint "Either create the subnet, set DEPLOY_SUBNETS=true to let the deployment create it, or correct the *SubnetName parameter."
                        }
                    }
                    # ACA delegation check
                    $acaName = Get-StringValue $P['acaEnvironmentSubnetName']
                    $deployContainerEnv = ConvertTo-Bool $P['deployContainerEnv']
                    $netIso = ConvertTo-Bool $P['networkIsolation']
                    if ($deployContainerEnv -and $netIso -and (-not [string]::IsNullOrEmpty($acaName))) {
                        $acaSubnet = $vnet.subnets | Where-Object { $_.name -eq $acaName }
                        if ($acaSubnet) {
                            $delegation = $acaSubnet.delegations | Where-Object { $_.serviceName -eq 'Microsoft.App/environments' }
                            if (-not $delegation) {
                                Add-Finding -Severity FAIL -Code 'ACA_SUBNET_NO_DELEGATION' `
                                    -Message "BYO ACA environment subnet '$acaName' is missing delegation 'Microsoft.App/environments'." `
                                    -Hint "Run: az network vnet subnet update --ids <subnetId> --delegations Microsoft.App/environments"
                            }
                            if ($acaSubnet.serviceEndpoints -and @($acaSubnet.serviceEndpoints).Count -gt 0) {
                                Add-Finding -Severity WARN -Code 'ACA_SUBNET_HAS_SE' `
                                    -Message "BYO ACA environment subnet '$acaName' has service endpoints configured. Container Apps does not require any and they can interfere with private-endpoint routing." `
                                    -Hint "Remove service endpoints from this subnet unless you have a deliberate reason to keep them."
                            }
                        }
                    }
                }
            }
        }
    }

    # BYO Private DNS zones — validate naming
    $expectedZoneName = @{
        'existingPrivateDnsZoneCogSvcsResourceId'         = 'privatelink.cognitiveservices.azure.com'
        'existingPrivateDnsZoneOpenAiResourceId'          = 'privatelink.openai.azure.com'
        'existingPrivateDnsZoneAiServicesResourceId'      = 'privatelink.services.ai.azure.com'
        'existingPrivateDnsZoneSearchResourceId'          = 'privatelink.search.windows.net'
        'existingPrivateDnsZoneCosmosResourceId'          = 'privatelink.documents.azure.com'
        # blob/containerApps/acr zones include region/suffix tokens — match by prefix
        'existingPrivateDnsZoneBlobResourceId'            = 'privatelink.blob.'
        'existingPrivateDnsZoneKeyVaultResourceId'        = 'privatelink.vaultcore.azure.net'
        'existingPrivateDnsZoneAppConfigResourceId'       = 'privatelink.azconfig.io'
        'existingPrivateDnsZoneContainerAppsResourceId'   = 'privatelink.'
        'existingPrivateDnsZoneAcrResourceId'             = 'privatelink.'
        'existingPrivateDnsZoneAzureMonitorResourceId'    = 'privatelink.monitor.azure.com'
        'existingPrivateDnsZoneOmsOpsInsightsResourceId'  = 'privatelink.oms.opinsights.azure.com'
        'existingPrivateDnsZoneOdsOpsInsightsResourceId'  = 'privatelink.ods.opinsights.azure.com'
        'existingPrivateDnsZoneAzureAutomationResourceId' = 'privatelink.agentsvc.azure.automation.net'
        'existingPrivateDnsZoneAppInsightsResourceId'     = 'privatelink.applicationinsights.io'
    }
    foreach ($entry in $expectedZoneName.GetEnumerator()) {
        $rid = Get-StringValue $P[$entry.Key]
        if ([string]::IsNullOrEmpty($rid)) { continue }
        $segs = $rid.Trim('/').Split('/')
        if ($segs.Count -lt 8) {
            Add-Finding -Severity FAIL -Code 'DNS_ZONE_RID_BAD' -Message "'$($entry.Key)' value '$rid' is not a valid Private DNS zone resource ID."
            continue
        }
        $zoneName = $segs[-1]
        $expected = $entry.Value
        if ($expected.EndsWith('.')) {
            if (-not $zoneName.StartsWith($expected)) {
                Add-Finding -Severity FAIL -Code 'DNS_ZONE_NAME_MISMATCH' `
                    -Message "'$($entry.Key)' points at zone '$zoneName' but the parameter expects a zone whose name starts with '$expected'." `
                    -Hint "Verify the resource ID points at the correct Private DNS zone."
            }
        }
        else {
            if ($zoneName -ne $expected) {
                Add-Finding -Severity FAIL -Code 'DNS_ZONE_NAME_MISMATCH' `
                    -Message "'$($entry.Key)' points at zone '$zoneName' but the parameter expects '$expected'." `
                    -Hint "Verify the resource ID points at the correct Private DNS zone."
            }
        }
        # Existence check (read-only)
        $zone = Invoke-AzCli -Arguments @('network', 'private-dns', 'zone', 'show', '--ids', $rid, '-o', 'json')
        if (-not $zone) {
            Add-Finding -Severity WARN -Code 'DNS_ZONE_LOOKUP_FAILED' `
                -Message "Could not read Private DNS zone '$rid' — the deployment will fail later if this zone does not exist." `
                -Hint "Verify the ID and that the current identity has Reader on the zone."
        }
    }

    # Existing LAW / App Insights / Route Table / Hub VNet
    foreach ($pair in @(
            @{ Key = 'existingLogAnalyticsWorkspaceResourceId'; Code = 'LAW_LOOKUP_FAILED'; Kind = 'Log Analytics workspace' },
            @{ Key = 'existingApplicationInsightsResourceId'; Code = 'APPI_LOOKUP_FAILED'; Kind = 'Application Insights' },
            @{ Key = 'hubIntegrationExistingRouteTableResourceId'; Code = 'RT_LOOKUP_FAILED'; Kind = 'route table' },
            @{ Key = 'existingBastionResourceId'; Code = 'BASTION_LOOKUP_FAILED'; Kind = 'Bastion host' },
            @{ Key = 'existingNatGatewayResourceId'; Code = 'NATGW_LOOKUP_FAILED'; Kind = 'NAT Gateway' }
        )) {
        $rid = Get-StringValue $P[$pair.Key]
        if ([string]::IsNullOrEmpty($rid)) { continue }
        $resource = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $rid, '-o', 'json')
        if (-not $resource) {
            Add-Finding -Severity WARN -Code $pair.Code `
                -Message "Could not read existing $($pair.Kind) at '$rid' — the deployment will fail later if it does not exist." `
                -Hint "Verify the ID and that the current identity has Reader on the resource."
        }
    }

    # Hub VNet address-space overlap
    $hubRid = Get-StringValue $P['hubIntegrationHubVnetResourceId']
    if (-not [string]::IsNullOrEmpty($hubRid)) {
        $hubVnet = Invoke-AzCli -Arguments @('network', 'vnet', 'show', '--ids', $hubRid, '-o', 'json')
        if (-not $hubVnet) {
            Add-Finding -Severity WARN -Code 'HUB_VNET_LOOKUP_FAILED' `
                -Message "Could not read hub VNet '$hubRid' — address-space overlap detection will be skipped." `
                -Hint "Verify the ID and that the current identity has Reader on the hub VNet's resource group."
        }
        else {
            $spokePrefixes = @(Get-ArrayValue $P['vnetAddressPrefixes'] | ForEach-Object { Get-StringValue $_ } | Where-Object { -not [string]::IsNullOrEmpty($_) })
            $hubPrefixes = @($hubVnet.addressSpace.addressPrefixes)
            foreach ($sp in $spokePrefixes) {
                foreach ($hp in $hubPrefixes) {
                    try {
                        if (Test-CidrOverlap -A $sp -B $hp) {
                            Add-Finding -Severity FAIL -Code 'HUB_SPOKE_OVERLAP' `
                                -Message "Spoke VNet prefix '$sp' overlaps hub VNet prefix '$hp'. Peering will fail." `
                                -Hint "Pick a non-overlapping VNET_ADDRESS_PREFIXES range for the spoke."
                        }
                    }
                    catch { }
                }
            }
        }
    }
}

function Get-PeeringProperty {
    # az emits peering properties flattened; also accept the raw ARM shape.
    param($Peering, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Peering) { return $null }
    $value = $Peering.$Name
    if ($null -eq $value -and $null -ne $Peering.properties) { $value = $Peering.properties.$Name }
    return $value
}

function Get-ApiManagementSubnetPrefix {
    # Mirrors main.bicep: apiManagementConfiguration.integrationSubnetPrefix
    # takes precedence over apiManagementSubnetPrefix, whose Bicep default is
    # read from main.bicep when the parameters file leaves it unset.
    param([hashtable]$P)
    $configuration = $P['apiManagementConfiguration']
    if ($null -ne $configuration -and -not [string]::IsNullOrWhiteSpace([string]$configuration.integrationSubnetPrefix)) {
        return ([string]$configuration.integrationSubnetPrefix).Trim()
    }
    $explicit = (Get-StringValue $P['apiManagementSubnetPrefix']).Trim()
    if ($explicit) { return $explicit }
    $bicepPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'main.bicep'
    if (Test-Path -LiteralPath $bicepPath) {
        $match = [regex]::Match((Get-Content -LiteralPath $bicepPath -Raw), "(?m)^param apiManagementSubnetPrefix string = '([^']+)'")
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return ''
}

function Test-ApiManagementHubPeering {
    # API Management activates over the spoke's egress path. In the new-spoke
    # shape the template routes the injection subnet's 0.0.0.0/0 to the hub next
    # hop, which is reachable only once the hub-to-spoke peering exists. Created
    # before that peering, the gateway blackholes its dependency traffic and
    # fails with ActivationFailed (ADR-002). The template creates only the
    # spoke-to-hub direction, so a first deployment cannot include the gateway.
    param([hashtable]$P)

    if (-not (Resolve-DeployFlag -P $P -Key 'deployApiManagement' -Default $false)) { return }
    if (-not [string]::IsNullOrWhiteSpace((Get-StringValue $P['existingApiManagementResourceId']))) { return }
    $shape = Get-ApiManagementTopologyShape -P $P
    if (-not $shape) { return }

    $hubRid = (Get-StringValue $P['hubIntegrationHubVnetResourceId']).Trim()
    $twoPassHint = 'Provision the spoke first with DEPLOY_API_MANAGEMENT=false (Deploy-AilzIntegrated.ps1 without -DeployApiManagement). Then have the hub owner create the hub-to-spoke peering, or run tests/scripts/Add-HubSpokePeering.ps1 where you own the hub. Confirm both directions show Connected, then rerun with API Management enabled.'

    if ($SkipAzureLookups) {
        Add-Finding -Severity INFO -Code 'APIM_HUB_PEERING_UNVERIFIED' `
            -Message 'API Management needs a Connected hub-to-spoke peering before the gateway is created. Not verified because Azure lookups were skipped.' `
            -Hint $twoPassHint
        return
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return }

    # The template owns the new spoke's default route to the hub, so a missing
    # peering there always fails activation. An operator owns a prepared
    # spoke's route table, whose default route may not use the hub.
    $severity = if ($shape -eq 'NewSpoke') { 'FAIL' } else { 'WARN' }
    $hubSegments = $hubRid.Trim('/').Split('/')
    $peerings = @()
    $listed = $false
    if ($hubSegments.Count -ge 8) {
        try {
            $raw = & az network vnet peering list --subscription $hubSegments[1] --resource-group $hubSegments[3] --vnet-name $hubSegments[7] -o json 2>$null
            if ($LASTEXITCODE -eq 0) {
                $listed = $true
                if ($raw) { $peerings = @(($raw -join "`n") | ConvertFrom-Json) }
            }
        }
        catch {
            $listed = $false
        }
    }
    if (-not $listed) {
        Add-Finding -Severity WARN -Code 'APIM_HUB_PEERING_UNVERIFIED' `
            -Message "Could not list the peerings of hub VNet '$hubRid'. API Management needs a Connected hub-to-spoke peering before the gateway is created." `
            -Hint "Grant the deploying identity Reader on the hub VNet, or confirm the peering state with the hub owner. $twoPassHint"
        return
    }

    $envValues = Get-AzdEnvValues
    $spokeVnetId = if ($shape -eq 'PreparedSpoke') {
        (Get-StringValue $P['existingVnetResourceId']).Trim()
    }
    elseif ($envValues.ContainsKey('VNET_RESOURCE_ID')) {
        ([string]$envValues['VNET_RESOURCE_ID']).Trim()
    }
    else { '' }

    if ($spokeVnetId) {
        $spokeLabel = "spoke VNet '$spokeVnetId'"
        $spokeIdentified = $true
        $candidates = @($peerings | Where-Object { [string](Get-PeeringProperty (Get-PeeringProperty $_ 'remoteVirtualNetwork') 'id') -ieq $spokeVnetId })
    }
    else {
        # No spoke VNet ID is recorded yet, as on a first deployment. Match a
        # peering whose remote address space holds the gateway subnet and, when
        # the target is known, whose remote VNet is in the target resource group.
        $apimPrefix = Get-ApiManagementSubnetPrefix -P $P
        $subscriptionId = if ($envValues.ContainsKey('AZURE_SUBSCRIPTION_ID')) { [string]$envValues['AZURE_SUBSCRIPTION_ID'] } else { '' }
        $resourceGroup = if ($envValues.ContainsKey('AZURE_RESOURCE_GROUP')) { [string]$envValues['AZURE_RESOURCE_GROUP'] } else { '' }
        $groupScope = if ($subscriptionId -and $resourceGroup) { "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/" } else { '' }
        $spokeIdentified = [bool]$groupScope
        $spokeLabel = if ($groupScope) { "a VNet in resource group '$resourceGroup' containing $apimPrefix" } else { "a VNet containing $apimPrefix" }
        $candidates = @($peerings | Where-Object {
                $remoteId = [string](Get-PeeringProperty (Get-PeeringProperty $_ 'remoteVirtualNetwork') 'id')
                $remotePrefixes = @(
                    (Get-PeeringProperty (Get-PeeringProperty $_ 'remoteAddressSpace') 'addressPrefixes')
                    (Get-PeeringProperty (Get-PeeringProperty $_ 'remoteVirtualNetworkAddressSpace') 'addressPrefixes')
                ) | Where-Object { $_ }
                $holdsSubnet = @($remotePrefixes | Where-Object {
                        try { $apimPrefix -and (Test-CidrContains -Outer ([string]$_) -Inner $apimPrefix) } catch { $false }
                    }).Count -gt 0
                $holdsSubnet -and (-not $groupScope -or $remoteId.StartsWith($groupScope, [StringComparison]::OrdinalIgnoreCase))
            })
    }

    $hubName = if ($hubSegments.Count -ge 8) { $hubSegments[7] } else { $hubRid }
    $connected = @($candidates | Where-Object { [string](Get-PeeringProperty $_ 'peeringState') -eq 'Connected' })
    if ($connected.Count -gt 0) {
        if (-not $spokeIdentified) {
            # Without a spoke VNet ID or target resource group, a Connected
            # peering to an address space holding the gateway subnet may belong
            # to another spoke, so it is not evidence about this one.
            Add-Finding -Severity WARN -Code 'APIM_HUB_PEERING_UNVERIFIED' `
                -Message "Hub VNet '$hubName' peering '$($connected[0].name)' to $spokeLabel is Connected, but the target resource group is not known yet, so it may belong to another spoke." `
                -Hint "Set AZURE_SUBSCRIPTION_ID and AZURE_RESOURCE_GROUP in the azd environment, for example through -AdditionalEnvironmentVariables, so preflight can match this spoke. $twoPassHint"
            return
        }

        # Hub-to-spoke traffic, including the firewall's replies to the gateway,
        # needs 'Allow access to remote virtual network' on the hub-side peering.
        $usable = @($connected | Where-Object { (Get-PeeringProperty $_ 'allowVirtualNetworkAccess') -ne $false })
        if ($usable.Count -eq 0) {
            Add-Finding -Severity $severity -Code 'APIM_HUB_PEERING_ACCESS_BLOCKED' `
                -Message "Hub VNet '$hubName' peering '$($connected[0].name)' to $spokeLabel is Connected, but allowVirtualNetworkAccess is false, so traffic from the hub to the spoke is blocked and the gateway fails activation." `
                -Hint "Have the hub owner allow access on the hub-side peering: az network vnet peering update --ids `"$($connected[0].id)`" --allow-vnet-access true."
            return
        }

        # The template sets the flags on a new spoke's spoke-to-hub peering.
        # Where an operator owns that peering, it must also let the spoke reach
        # the hub and accept the replies the hub firewall forwards. Without a
        # recorded spoke VNet ID, the matched hub-side peering names the spoke.
        $templateOwnsSpokePeering = $shape -eq 'NewSpoke' -and (Resolve-DeployFlag -P $P -Key 'hubIntegrationCreateHubPeering' -Default $true)
        if (-not $templateOwnsSpokePeering) {
            $spokeVnetForCheck = if ($spokeVnetId) { $spokeVnetId } else { [string](Get-PeeringProperty (Get-PeeringProperty $usable[0] 'remoteVirtualNetwork') 'id') }
            $spokeSegments = $spokeVnetForCheck.Trim('/').Split('/')
            $toHub = $null
            if ($spokeSegments.Count -ge 8) {
                try {
                    $spokeRaw = & az network vnet peering list --subscription $spokeSegments[1] --resource-group $spokeSegments[3] --vnet-name $spokeSegments[7] -o json 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $spokePeerings = @(if ($spokeRaw) { ($spokeRaw -join "`n") | ConvertFrom-Json })
                        $toHub = @($spokePeerings | Where-Object { $_ -and [string](Get-PeeringProperty (Get-PeeringProperty $_ 'remoteVirtualNetwork') 'id') -ieq $hubRid })
                    }
                }
                catch {
                    $toHub = $null
                }
            }

            if ($null -eq $toHub -or $toHub.Count -eq 0) {
                $spokeName = if ($spokeVnetForCheck) { "spoke VNet '$spokeVnetForCheck'" } else { 'the spoke VNet' }
                Add-Finding -Severity WARN -Code 'APIM_SPOKE_PEERING_UNVERIFIED' `
                    -Message "Could not read the peering from $spokeName to hub VNet '$hubName'. You own that peering, and the gateway needs it to allow virtual network access and forwarded traffic." `
                    -Hint 'Grant the deploying identity Reader on the spoke VNet so preflight can check it, or confirm both flags on the spoke-side peering with az network vnet peering show.'
            }
            else {
                $spokeBlocked = @($toHub | Where-Object {
                        (Get-PeeringProperty $_ 'allowVirtualNetworkAccess') -eq $false -or (Get-PeeringProperty $_ 'allowForwardedTraffic') -eq $false
                    })
                if ($spokeBlocked.Count -eq $toHub.Count) {
                    Add-Finding -Severity $severity -Code 'APIM_SPOKE_PEERING_BLOCKED' `
                        -Message "Spoke VNet peering '$($spokeBlocked[0].name)' to hub VNet '$hubName' disallows virtual network access or forwarded traffic, so the gateway cannot reach the hub firewall or receive the replies it forwards, and activation fails." `
                        -Hint "Allow both on the spoke-side peering: az network vnet peering update --ids `"$($spokeBlocked[0].id)`" --allow-vnet-access true --allow-forwarded-traffic true."
                    return
                }
            }
        }

        $unsynced = @($usable | Where-Object {
                $sync = [string](Get-PeeringProperty $_ 'peeringSyncLevel')
                $sync -and $sync -ne 'FullyInSync'
            })
        if ($unsynced.Count -gt 0) {
            Add-Finding -Severity WARN -Code 'APIM_HUB_PEERING_NOT_SYNCED' `
                -Message "Hub VNet '$hubName' peering '$($unsynced[0].name)' to $spokeLabel is Connected but '$(Get-PeeringProperty $unsynced[0] 'peeringSyncLevel')'. Address space added since the peering was created is not routed through the hub yet." `
                -Hint "Resynchronize both directions, for example: az network vnet peering sync --resource-group <rg> --vnet-name <vnet> --name <peering>."
        }
        else {
            Add-Finding -Severity INFO -Code 'APIM_HUB_PEERING_CONNECTED' `
                -Message "Hub VNet '$hubName' peering '$($usable[0].name)' to $spokeLabel is Connected. The gateway also needs the hub firewall to allow its dependencies; see the API Management section of the README."
        }
        return
    }

    if ($candidates.Count -gt 0) {
        $states = ($candidates | ForEach-Object { '{0}={1}' -f $_.name, (Get-PeeringProperty $_ 'peeringState') }) -join ', '
        Add-Finding -Severity $severity -Code 'APIM_HUB_PEERING_NOT_CONNECTED' `
            -Message "Hub VNet '$hubName' has a peering to $spokeLabel, but it is not Connected ($states). Until it is, the gateway's dependency traffic through the hub is dropped and activation fails." `
            -Hint "Initiated means the other direction is missing, so create it. Disconnected means the spoke VNet was deleted or recreated, so delete the hub-side peering and create it again once the spoke VNet exists. $twoPassHint"
        return
    }

    $impact = if ($shape -eq 'NewSpoke') {
        "The template routes the gateway subnet's 0.0.0.0/0 to $(Get-StringValue $P['hubIntegrationEgressNextHopIp']) in the hub, so without the hub-to-spoke peering every dependency call is dropped and the gateway fails with ActivationFailed."
    }
    else {
        'If the prepared injection subnet routes 0.0.0.0/0 to the hub, the gateway fails with ActivationFailed until that peering is Connected.'
    }
    Add-Finding -Severity $severity -Code 'APIM_HUB_PEERING_MISSING' `
        -Message "Hub VNet '$hubName' has no peering to $spokeLabel. $impact" `
        -Hint $twoPassHint
}

# --------------------------------------------------------------------------
# Resource-provider registration check. Discovers the Azure resource provider
# namespaces referenced by `resource 'Microsoft.X/...'` declarations across all
# of the repo's *.bicep files (excluding tests/), then verifies each is
# Registered. Providers are classified as "selected" or "optional" against the
# effective feature flags: an unregistered provider only FAILs preflight when
# its resource is actually selected by the current parameters; providers for
# feature-flagged-off resources are reported as a non-blocking WARN. Read-only —
# does not attempt to register providers.
# --------------------------------------------------------------------------

function Get-RequiredResourceProviders {
    # Friendly descriptions for known namespaces. The actual *list* of
    # namespaces is derived from the Bicep tree below so it stays in sync with
    # main.bicep / modules as resources are added or removed. Unknown
    # namespaces (e.g. a future addition) still get checked — they just show
    # a generic reason and are treated as optional (WARN, never FAIL).
    param([hashtable]$P = @{})
    $reasonByNamespace = @{
        'Microsoft.Resources'            = 'Always required (resource group, deployments)'
        'Microsoft.Authorization'        = 'Role assignments and role definitions'
        'Microsoft.Network'              = 'VNet, NSGs, Private DNS, Private Endpoints, Bastion, NAT Gateway, Firewall, App Gateway'
        'Microsoft.ManagedIdentity'      = 'User-assigned managed identities'
        'Microsoft.Compute'              = 'Jumpbox VM and VM extensions'
        'Microsoft.Storage'              = 'Storage accounts (workload + AI Foundry)'
        'Microsoft.KeyVault'             = 'Key Vault'
        'Microsoft.AppConfiguration'     = 'App Configuration store'
        'Microsoft.OperationalInsights'  = 'Log Analytics workspace'
        'Microsoft.Insights'             = 'Application Insights, diagnostic settings, AMPLS'
        'Microsoft.OperationsManagement' = 'Log Analytics solutions'
        'Microsoft.AlertsManagement'     = 'Smart detector alerts on Application Insights'
        'Microsoft.App'                  = 'Container Apps + managed environment'
        'Microsoft.ContainerRegistry'    = 'Azure Container Registry + ACR Tasks agent pool'
        'Microsoft.CognitiveServices'    = 'AI Foundry account/project, AI Services, Speech'
        'Microsoft.Search'               = 'Azure AI Search'
        'Microsoft.DocumentDB'           = 'Cosmos DB workload account + AI Foundry-bundled Cosmos'
        'Microsoft.Bing'                 = 'Bing grounding'
        'Microsoft.ApiManagement'        = 'Azure API Management'
    }

    # Always-required providers used implicitly at deploy time (LA workspace
    # solutions, smart-detector alerts attached to App Insights, the resource
    # group/deployment plumbing itself). These never appear as `resource`
    # declarations in the Bicep tree so we add them unconditionally.
    $implicitNamespaces = @('Microsoft.Resources', 'Microsoft.OperationsManagement', 'Microsoft.AlertsManagement')

    # Discover provider namespaces from `resource 'Microsoft.X/...'` declarations
    # across the repo's Bicep files. Skips tests/ (not part of azd provision).
    $repoRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { '' } else { Split-Path -Parent $PSScriptRoot }
    $discovered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $resourceRegex = [regex]::new("^\s*resource\s+\w+\s+'(Microsoft\.[^/']+)/", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if (-not [string]::IsNullOrWhiteSpace($repoRoot) -and (Test-Path -LiteralPath $repoRoot)) {
        Get-ChildItem -Path $repoRoot -Recurse -Filter *.bicep -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
            ForEach-Object {
                foreach ($line in (Get-Content -Path $_.FullName -ErrorAction SilentlyContinue)) {
                    $m = $resourceRegex.Match($line)
                    if ($m.Success) { [void]$discovered.Add($m.Groups[1].Value) }
                }
            }
    }

    # Canonicalize casing against the known-namespace map (Bicep accepts
    # 'microsoft.insights' lowercase too; az provider expects the canonical
    # 'Microsoft.Insights').
    $canonical = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($ns in $discovered) {
        $known = @($reasonByNamespace.Keys | Where-Object { $_ -ieq $ns } | Select-Object -First 1)
        if ($known.Count -gt 0) { [void]$canonical.Add($known[0]) } else { [void]$canonical.Add($ns) }
    }
    foreach ($ns in $implicitNamespaces) { [void]$canonical.Add($ns) }

    # Fallback: if Bicep discovery returned nothing (e.g. script run from an
    # unusual location), fall back to the full known-namespace list so the
    # check still has coverage.
    if ($canonical.Count -le $implicitNamespaces.Count) {
        foreach ($ns in $reasonByNamespace.Keys) { [void]$canonical.Add($ns) }
    }

    # Map each namespace to whether the current parameters actually select it.
    # Mirrors the feature-flag resolution used elsewhere (Test-RegionalReadiness)
    # and the default-on/off semantics in main.parameters.json. Providers not in
    # this map default to optional ($false) so unknown discoveries never hard-fail.
    $deployAiFoundry         = Resolve-DeployFlag -P $P -Key 'deployAiFoundry'         -Default $true
    $deploySpeech            = Resolve-DeployFlag -P $P -Key 'deploySpeechService'     -Default $false
    $deployCosmos            = Resolve-DeployFlag -P $P -Key 'deployCosmosDb'          -Default $true
    $deploySearch            = Resolve-DeployFlag -P $P -Key 'deploySearchService'     -Default $true
    $deployBing              = Resolve-DeployFlag -P $P -Key 'deployGroundingWithBing' -Default $false
    $deployKeyVault          = Resolve-DeployFlag -P $P -Key 'deployKeyVault'          -Default $true
    $deployStorage           = Resolve-DeployFlag -P $P -Key 'deployStorageAccount'    -Default $true
    $deployAppConfig         = Resolve-DeployFlag -P $P -Key 'deployAppConfig'         -Default $true
    $deployContainerApps     = Resolve-DeployFlag -P $P -Key 'deployContainerApps'     -Default $true
    $deployContainerEnv      = Resolve-DeployFlag -P $P -Key 'deployContainerEnv'      -Default $true
    $deployContainerRegistry = Resolve-DeployFlag -P $P -Key 'deployContainerRegistry' -Default $true
    $deployLogAnalytics      = Resolve-DeployFlag -P $P -Key 'deployLogAnalytics'      -Default $true
    $deployApiManagement     = Resolve-DeployFlag -P $P -Key 'deployApiManagement'     -Default $false
    $deployJump              = Resolve-DeployJumpbox $P

    $selectionByNamespace = @{
        'Microsoft.Resources'            = $true
        'Microsoft.Authorization'        = $true
        'Microsoft.ManagedIdentity'      = $true
        'Microsoft.Insights'             = $true
        'Microsoft.OperationsManagement' = $true
        'Microsoft.AlertsManagement'     = $true
        'Microsoft.Network'              = $true
        'Microsoft.OperationalInsights'  = $deployLogAnalytics
        'Microsoft.Compute'              = $deployJump
        'Microsoft.Storage'              = ($deployStorage -or $deployAiFoundry)
        'Microsoft.KeyVault'             = $deployKeyVault
        'Microsoft.AppConfiguration'     = $deployAppConfig
        'Microsoft.App'                  = ($deployContainerApps -or $deployContainerEnv)
        'Microsoft.ContainerRegistry'    = $deployContainerRegistry
        'Microsoft.CognitiveServices'    = ($deployAiFoundry -or $deploySpeech)
        'Microsoft.Search'               = $deploySearch
        'Microsoft.DocumentDB'           = ($deployCosmos -or $deployAiFoundry)
        'Microsoft.Bing'                 = $deployBing
        'Microsoft.ApiManagement'        = $deployApiManagement
    }

    $canonical | Sort-Object | ForEach-Object {
        $ns = $_
        $reason = if ($reasonByNamespace.ContainsKey($ns)) { $reasonByNamespace[$ns] } else { 'Discovered in repository Bicep files' }
        $selected = if ($selectionByNamespace.ContainsKey($ns)) { [bool]$selectionByNamespace[$ns] } else { $false }
        @{ Namespace = $ns; Reason = $reason; Selected = $selected }
    }
}

function Get-VmSkuInfo {
    # Single source of truth for VM-SKU facts: queries Azure for the SKU's
    # availability, vCPU count, family (quota counter), and any restrictions
    # active in the target region/subscription. Returns $null when the SKU is
    # not offered in the region.
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$VmSize
    )
    if ([string]::IsNullOrWhiteSpace($Location) -or [string]::IsNullOrWhiteSpace($VmSize)) { return $null }
    $skus = Invoke-AzCliRaw -Arguments @('vm', 'list-skus', '--location', $Location, '--size', $VmSize, '--all', '-o', 'json')
    if (-not $skus) { return $null }
    $match = @($skus | Where-Object { $_.name -eq $VmSize -and $_.resourceType -eq 'virtualMachines' } | Select-Object -First 1)
    if (-not $match) { return $null }

    $vCpus = 0
    if ($match.capabilities) {
        $cap = @($match.capabilities | Where-Object { $_.name -eq 'vCPUs' -or $_.name -eq 'vCPUsAvailable' } | Select-Object -First 1)
        if ($cap) { $vCpus = [int]$cap.value }
    }
    $restrictions = @()
    if ($match.PSObject.Properties.Name -contains 'restrictions' -and $match.restrictions) {
        $restrictions = @($match.restrictions | Where-Object { $_ })
    }
    [pscustomobject]@{
        Name         = [string]$match.name
        Family       = [string]$match.family
        VCpus        = $vCpus
        Restrictions = $restrictions
    }
}

function Test-ResourceProviders {
    param([hashtable]$P = @{})
    if ($SkipAzureLookups) { return }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return }

    # Silent context check — avoids emitting a duplicate AZ_NOT_LOGGED_IN
    # warning (Test-AzureResources already covers that path).
    & az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    foreach ($entry in (Get-RequiredResourceProviders -P $P)) {
        $ns = $entry.Namespace
        $state = & az provider show --namespace $ns --query 'registrationState' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($state)) {
            Add-Finding -Severity WARN -Code 'RP_LOOKUP_FAILED' `
                -Message "Could not read registration state for provider '$ns' ($($entry.Reason))." `
                -Hint "Run: az provider show --namespace $ns --query registrationState -o tsv"
            continue
        }
        $state = $state.Trim()
        if ($state -eq 'Registered') { continue }
        if ($state -eq 'Registering') {
            Add-Finding -Severity WARN -Code 'RP_REGISTERING' `
                -Message "Provider '$ns' is currently '$state' — wait until it reaches 'Registered' before deploying." `
                -Hint "Re-run preflight in a minute, or block on it with: az provider register --namespace $ns --wait"
        }
        elseif ($entry.Selected) {
            Add-Finding -Severity FAIL -Code 'RP_NOT_REGISTERED' `
                -Message "Provider '$ns' is '$state', not 'Registered'. Used for: $($entry.Reason)." `
                -Hint "Run: az provider register --namespace $ns --wait"
        }
        else {
            # Provider is referenced somewhere in the Bicep tree but the resource
            # is not selected by the current parameters (feature-flagged off, or a
            # namespace this script doesn't map). Surface it as advisory only so
            # minimal/subset deployments (e.g. gpt-rag with Search/Cosmos/Bing
            # disabled) don't fail preflight on providers they never deploy.
            Add-Finding -Severity WARN -Code 'RP_NOT_REGISTERED_OPTIONAL' `
                -Message "Provider '$ns' is '$state', not 'Registered'. Only needed if you enable: $($entry.Reason). Not selected by the current parameters, so not blocking." `
                -Hint "If you plan to enable this feature, run: az provider register --namespace $ns --wait"
        }
    }
}

# --------------------------------------------------------------------------
# Regional readiness (live, optional) — issue #72
# --------------------------------------------------------------------------
#
# Validates that the target region(s) and subscription can actually host the
# resources the landing zone is about to provision. Catches the "azd up returns
# an opaque ARM error 25 minutes in" class of failures by surfacing them as
# pre-flight findings:
#
#   * Subscription drift — `az` CLI default subscription does not match the
#     subscription recorded in the azd environment. Only fires when run from a
#     `preprovision` hook (i.e. an azd env is present).
#   * Provider/location support — for each resource type the landing zone
#     provisions, confirm the provider lists the chosen region as supported.
#   * Jumpbox VM SKU availability — when a jumpbox is requested, confirm the
#     requested VM size is offered (and not restricted) in the region for the
#     current subscription.
#   * AI model quota — for each entry in `modelDeploymentList`, call
#     `az cognitiveservices usage list --location <region>` and verify the
#     requested capacity fits in the available quota.
#
# Everything in this block is **read-only** and **non-blocking on WARN**. The
# whole block is skipped when `-SkipRegional`, `-SkipAzureLookups`, or
# `$env:LZ_PREFLIGHT_REGIONAL_SKIP=true` is set.
# --------------------------------------------------------------------------

function Get-NormalizedLocation {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '' }
    return (($Location -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}

function Invoke-AzCliRaw {
    # Like Invoke-AzCli, but accepts callers that append their own '-o json' and
    # tolerates az subcommands that print warnings to stderr.
    param([string[]]$Arguments)
    try {
        $out = & az @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ($out -join "`n" | ConvertFrom-Json)
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-ProviderLocation {
    param(
        [Parameter(Mandatory)] [string]$ProviderNamespace,
        [Parameter(Mandatory)] [string]$ResourceType,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$CodePrefix
    )
    if ([string]::IsNullOrWhiteSpace($Location)) {
        Add-Finding -Severity WARN -Code "${CodePrefix}_NO_LOCATION" `
            -Message "$DisplayName provider/location check skipped: no location resolved from parameters."
        return
    }
    $provider = Invoke-AzCliRaw -Arguments @('provider', 'show', '--namespace', $ProviderNamespace, '-o', 'json')
    if (-not $provider) {
        Add-Finding -Severity WARN -Code "${CodePrefix}_PROVIDER_LOOKUP" `
            -Message "Could not query provider $ProviderNamespace for $DisplayName." `
            -Hint "Ensure 'az' is logged in and the provider is registered (az provider register --namespace $ProviderNamespace)."
        return
    }
    if ($provider.registrationState -and $provider.registrationState -ne 'Registered') {
        Add-Finding -Severity FAIL -Code "${CodePrefix}_PROVIDER_UNREG" `
            -Message "Provider $ProviderNamespace ($DisplayName) is '$($provider.registrationState)', not 'Registered'." `
            -Hint "Run: az provider register --namespace $ProviderNamespace"
        return
    }
    $rt = @($provider.resourceTypes | Where-Object { $_.resourceType -eq $ResourceType } | Select-Object -First 1)
    if (-not $rt) {
        Add-Finding -Severity WARN -Code "${CodePrefix}_RT_MISSING" `
            -Message "Provider $ProviderNamespace did not report resource type $ResourceType."
        return
    }
    $target = Get-NormalizedLocation $Location
    $supported = @($rt.locations | ForEach-Object { Get-NormalizedLocation $_ }) -contains $target
    if (-not $supported) {
        Add-Finding -Severity FAIL -Code "${CodePrefix}_NOT_IN_REGION" `
            -Message "$DisplayName is not listed as supported in region '$Location' for this subscription." `
            -Hint "Pick a supported region or remove this resource from the deployment."
    }
}

function Test-VmSku {
    # Validates SKU availability + restrictions for the target region. Accepts
    # a pre-fetched VmSkuInfo (from Get-VmSkuInfo) to avoid a second
    # `az vm list-skus` round-trip when Test-RegionalVcpuQuota also needs it.
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$VmSize,
        $VmSkuInfo
    )
    if ([string]::IsNullOrWhiteSpace($Location) -or [string]::IsNullOrWhiteSpace($VmSize)) { return }
    if (-not $VmSkuInfo) { $VmSkuInfo = Get-VmSkuInfo -Location $Location -VmSize $VmSize }
    if (-not $VmSkuInfo) {
        Add-Finding -Severity FAIL -Code 'JUMPBOX_VM_NOT_FOUND' `
            -Message "Jumpbox VM size '$VmSize' is not offered in region '$Location'." `
            -Hint "Pick a different vmSize (AZURE_VM_SIZE) or a region that offers this SKU."
        return
    }
    if ($VmSkuInfo.Restrictions.Count -gt 0) {
        $msgs = $VmSkuInfo.Restrictions | ForEach-Object {
            $reason = if ($_.reasonCode) { $_.reasonCode } else { 'Restricted' }
            "$reason ($($_.type): $($_.values -join ','))"
        }
        Add-Finding -Severity FAIL -Code 'JUMPBOX_VM_RESTRICTED' `
            -Message "Jumpbox VM size '$VmSize' is restricted in '${Location}': $($msgs -join '; ')." `
            -Hint "Pick a different vmSize or request a quota increase."
    }
}

function Test-ModelQuota {
    param(
        [Parameter(Mandatory)] $ModelDeployments,
        [Parameter(Mandatory)] [string]$Location
    )
    if ([string]::IsNullOrWhiteSpace($Location)) { return }
    $deployments = @($ModelDeployments | Where-Object { $_ -ne $null })
    if ($deployments.Count -eq 0) { return }

    $usage = Invoke-AzCliRaw -Arguments @('cognitiveservices', 'usage', 'list', '--location', $Location, '-o', 'json')
    if (-not $usage) {
        Add-Finding -Severity WARN -Code 'MODEL_QUOTA_LOOKUP' `
            -Message "Could not read Cognitive Services usage/quota for '$Location'." `
            -Hint "Run 'az cognitiveservices usage list --location $Location' and verify Microsoft.CognitiveServices is registered."
        return
    }

    $failures = @()
    foreach ($d in $deployments) {
        # Only OpenAI-format deployments report quota via usage list
        $fmt = $null
        if ($d.PSObject.Properties.Name -contains 'model' -and $d.model) {
            $fmt = $d.model.format
        }
        if ($fmt -ne 'OpenAI') { continue }

        $modelName = [string]$d.model.name
        $skuName = [string]$d.sku.name
        $capacity = [double]$d.sku.capacity
        $quotaName = "OpenAI.$skuName.$modelName"

        $quota = @($usage | Where-Object { $_.name.value -eq $quotaName } | Select-Object -First 1)
        if (-not $quota) {
            $failures += "No quota entry '$quotaName' in $Location."
            continue
        }
        $available = [double]$quota.limit - [double]$quota.currentValue
        if ($available -lt $capacity) {
            $failures += "$quotaName needs $capacity, $available available (used $($quota.currentValue) / limit $($quota.limit))."
        }
    }

    if ($failures.Count -gt 0) {
        Add-Finding -Severity FAIL -Code 'MODEL_QUOTA_INSUFFICIENT' `
            -Message ("Insufficient AI model quota in '${Location}': " + ($failures -join ' ')) `
            -Hint "Request a quota increase (https://aka.ms/oai/quotaincrease), reduce sku.capacity in modelDeploymentList, or set AZURE_AI_FOUNDRY_LOCATION to a region with available quota."
    }
}

# --------------------------------------------------------------------------
# Regional capacity sub-checks folded in from
# pipelines/tools/azure_region_capacity_checker.ps1. Same Azure APIs, scoped
# to the single region the deployment will use rather than scoring a whole
# region set. All read-only.
# --------------------------------------------------------------------------

function Get-CurrentAzureSubscriptionId {
    $acct = Invoke-AzCliRaw -Arguments @('account', 'show', '-o', 'json')
    if ($acct -and $acct.id) { return [string]$acct.id }
    return $null
}

function Test-RegionalVcpuQuota {
    # Checks vCPU quota for the SKU about to be deployed. Prefers the
    # SKU-family quota counter (e.g. standardDSv5Family) because that's the
    # bucket Azure actually debits, and falls back to 'Total Regional vCPUs'
    # when no family info is supplied. RequiredHeadroom should be the SKU's
    # vCPU count (from VmSkuInfo.VCpus) so the comparison reflects what the
    # deployment will consume.
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [int]$RequiredHeadroom,
        [string]$Family
    )
    if ([string]::IsNullOrWhiteSpace($Location)) { return }
    $usage = Invoke-AzCliRaw -Arguments @('vm', 'list-usage', '--location', $Location, '-o', 'json')
    if (-not $usage) {
        Add-Finding -Severity WARN -Code 'VCPU_QUOTA_LOOKUP' `
            -Message "Could not read regional vCPU quota for '$Location'." `
            -Hint "Run: az vm list-usage --location $Location"
        return
    }

    $target = $null
    $scopeLabel = 'Total Regional vCPUs'
    if (-not [string]::IsNullOrWhiteSpace($Family)) {
        $target = @($usage | Where-Object { $_.name -and $_.name.value -eq $Family } | Select-Object -First 1)
        if ($target) { $scopeLabel = "$Family quota" }
    }
    if (-not $target) {
        $target = @($usage | Where-Object {
            ($_.name -and $_.name.localizedValue -eq 'Total Regional vCPUs') -or ($_.localName -eq 'Total Regional vCPUs')
        } | Select-Object -First 1)
    }
    if (-not $target) {
        Add-Finding -Severity WARN -Code 'VCPU_QUOTA_MISSING' `
            -Message "No matching vCPU quota entry (family='$Family') found for '$Location'."
        return
    }

    $available = [int]$target.limit - [int]$target.currentValue
    if ($available -le 0) {
        Add-Finding -Severity FAIL -Code 'VCPU_QUOTA_EXHAUSTED' `
            -Message "$scopeLabel exhausted in '$Location' (used $($target.currentValue) of $($target.limit))." `
            -Hint "Request a quota increase or pick a different region."
    }
    elseif ($available -lt $RequiredHeadroom) {
        Add-Finding -Severity WARN -Code 'VCPU_QUOTA_LOW' `
            -Message "$scopeLabel headroom in '$Location' is $available (need >= $RequiredHeadroom)." `
            -Hint "Reduce VM/container demand, request a quota increase, or pick another region."
    }
}

function Test-CognitiveServicesQuotaHeadroom {
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$Location
    )
    if ([string]::IsNullOrWhiteSpace($Location) -or [string]::IsNullOrWhiteSpace($SubscriptionId)) { return }
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/locations/$Location/usages?api-version=2023-05-01"
    $payload = Invoke-AzCliRaw -Arguments @('rest', '--method', 'get', '--url', $url)
    if (-not $payload) {
        Add-Finding -Severity WARN -Code 'CS_QUOTA_LOOKUP' `
            -Message "Could not read Cognitive Services usage for '$Location'." `
            -Hint "Verify Microsoft.CognitiveServices is registered and the current identity has Reader on the subscription."
        return
    }
    $items = @($payload.value)
    if ($items.Count -eq 0) { return }
    $hasHeadroom = $false
    $nearLimit = $false
    foreach ($item in $items) {
        $current = [double]$item.currentValue
        $limit = [double]$item.limit
        if ($limit -gt $current) { $hasHeadroom = $true }
        if ($limit -gt 0 -and (($limit - $current) / $limit) -lt 0.1) { $nearLimit = $true }
    }
    if (-not $hasHeadroom) {
        Add-Finding -Severity FAIL -Code 'CS_QUOTA_AT_LIMIT' `
            -Message "Cognitive Services quota in '$Location' is fully consumed across all reported metrics." `
            -Hint "Request a quota increase (https://aka.ms/oai/quotaincrease) or pick a different region for AI Foundry."
    }
    elseif ($nearLimit) {
        Add-Finding -Severity WARN -Code 'CS_QUOTA_TIGHT' `
            -Message "Cognitive Services quota in '$Location' is within 10% of the limit on at least one metric."
    }
}

function Test-AzureSearchSkuQuota {
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$Sku
    )
    if ([string]::IsNullOrWhiteSpace($Location) -or [string]::IsNullOrWhiteSpace($SubscriptionId)) { return }
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Search/locations/$Location/usages?api-version=2025-05-01"
    $payload = Invoke-AzCliRaw -Arguments @('rest', '--method', 'get', '--url', $url)
    if (-not $payload) {
        Add-Finding -Severity WARN -Code 'SEARCH_QUOTA_LOOKUP' `
            -Message "Could not read Azure Search usage for '$Location'."
        return
    }
    $skuCanonical = $Sku.ToLowerInvariant()
    $target = @($payload.value | Where-Object { $_.name -and ([string]$_.name.value).ToLowerInvariant() -eq $skuCanonical } | Select-Object -First 1)
    if (-not $target) {
        Add-Finding -Severity WARN -Code 'SEARCH_SKU_UNAVAILABLE' `
            -Message "Azure Search SKU '$Sku' is not listed for '$Location'." `
            -Hint "Pick a supported SKU or region (see https://azure.github.io/AI-Landing-Zones/bicep/regional-considerations/)."
        return
    }
    $available = [int]$target.limit - [int]$target.currentValue
    if ([int]$target.limit -le 0 -or $available -le 0) {
        Add-Finding -Severity FAIL -Code 'SEARCH_QUOTA_AT_LIMIT' `
            -Message "Azure Search SKU '$Sku' quota in '$Location' is exhausted (used $($target.currentValue) of $($target.limit))." `
            -Hint "Request a quota increase or pick another region/SKU."
    }
    elseif (([double]$available / [double]$target.limit) -lt 0.1) {
        Add-Finding -Severity WARN -Code 'SEARCH_QUOTA_TIGHT' `
            -Message "Azure Search SKU '$Sku' quota in '$Location' is nearly exhausted ($available of $($target.limit) available)."
    }
}

function Test-CosmosAvailabilityZone {
    param(
        [Parameter(Mandatory)] [string]$Location
    )
    if ([string]::IsNullOrWhiteSpace($Location)) { return }
    $query = '{online:properties.status, az:properties.isSubscriptionRegionAccessAllowedForAz, regular:properties.isSubscriptionRegionAccessAllowedForRegular, supportsAz:properties.supportsAvailabilityZone}'
    $info = Invoke-AzCliRaw -Arguments @('cosmosdb', 'locations', 'show', '--location', $Location, '--query', $query, '-o', 'json')
    if (-not $info) {
        Add-Finding -Severity WARN -Code 'COSMOS_LOC_LOOKUP' `
            -Message "Could not read Cosmos DB region metadata for '$Location'."
        return
    }
    if ($info.online -and $info.online -ne 'Online') {
        Add-Finding -Severity FAIL -Code 'COSMOS_NOT_ONLINE' `
            -Message "Cosmos DB region '$Location' status is '$($info.online)', not 'Online'." `
            -Hint "Pick a different region for cosmosLocation."
        return
    }
    if (-not [bool]$info.az) {
        Add-Finding -Severity WARN -Code 'COSMOS_NO_AZ' `
            -Message "Cosmos DB Availability-Zone support is not enabled for your subscription in '$Location'." `
            -Hint "Pick a region with AZ support if zonal redundancy is required."
    }
}

# --------------------------------------------------------------------------
# Cosmos analytical storage region eligibility
#
# Azure rejects Cosmos DB account creation when `enableAnalyticalStorage=true`
# is requested against a region/subscription combination that has not been
# allow-listed for Synapse Link, with the literal error: "Enabling analytical
# storage on account creation is not supported in this subscription/region.
# Please disable analytical storage on the account creation request and try
# again." The flag cannot be toggled after the account is created, so a
# failed provision requires deleting the account before retrying. Eligibility
# can change without notice, so this is a WARN, not a FAIL. See issue #93.
# --------------------------------------------------------------------------
$script:CosmosAnalyticalRestrictiveRegions = @(
    'swedencentral'
)

function Test-CosmosAnalyticalStorageRegionSupport {
    param([hashtable]$P)

    $enableAnalytical = ConvertTo-Bool $P['enableCosmosAnalyticalStorage']
    if (-not $enableAnalytical) { return }

    $deployCosmos = ConvertTo-Bool $(if ($null -ne $P['deployCosmosDb']) { $P['deployCosmosDb'] } else { $true })
    if (-not $deployCosmos) { return }

    $location = Get-StringValue $P['location']
    $cosmosLocation = Get-StringValue $P['cosmosLocation']
    if ([string]::IsNullOrWhiteSpace($cosmosLocation)) { $cosmosLocation = $location }
    if ([string]::IsNullOrWhiteSpace($cosmosLocation)) { return }

    $normalized = Get-NormalizedLocation $cosmosLocation
    $restrictive = @($script:CosmosAnalyticalRestrictiveRegions | ForEach-Object { Get-NormalizedLocation $_ })
    if ($restrictive -notcontains $normalized) { return }

    Add-Finding -Severity WARN -Code 'COSMOS_ANALYTICAL_REGION' `
        -Message "enableCosmosAnalyticalStorage=true and cosmosLocation='$cosmosLocation' is on the known-restrictive list. Azure has been observed to reject Cosmos DB account creation in this region/subscription combination with: 'Enabling analytical storage on account creation is not supported in this subscription/region. Please disable analytical storage on the account creation request and try again.' This flag cannot be toggled after the account is created, so a failed provision requires deleting the account before retrying." `
        -Hint "If you do not actively consume Synapse Link or Fabric Mirroring, set enableCosmosAnalyticalStorage=false (or unset ENABLE_COSMOS_ANALYTICAL_STORAGE) and re-run preflight. If you have confirmed your subscription is allow-listed for analytical storage in '$cosmosLocation',         you can ignore this WARN. See https://github.com/Azure/bicep-ptn-aiml-landing-zone/issues/93."
        }

function Test-RegionalReadiness {
    param([hashtable]$P)

    if ($SkipAzureLookups) { return }
    if ($SkipRegional -or $env:LZ_PREFLIGHT_REGIONAL_SKIP -eq 'true' -or $env:LZ_PREFLIGHT_REGIONAL_SKIP -eq '1') {
        Add-Finding -Severity INFO -Code 'REGIONAL_SKIPPED' `
            -Message "Regional readiness checks skipped (LZ_PREFLIGHT_REGIONAL_SKIP=true)."
        return
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return }

    # Subscription consistency: only when invoked from an azd context where the
    # azd env recorded a subscription. When run standalone (no azd env, or no
    # AZURE_SUBSCRIPTION_ID in it), skip without complaint.
    $envValues = Get-AzdEnvValues
    $azdSubId = if ($envValues.ContainsKey('AZURE_SUBSCRIPTION_ID')) { $envValues['AZURE_SUBSCRIPTION_ID'] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($azdSubId)) {
        $account = Invoke-AzCliRaw -Arguments @('account', 'show', '-o', 'json')
        if (-not $account) {
            Add-Finding -Severity FAIL -Code 'AZ_LOGIN_REQUIRED' `
                -Message "Azure CLI is not logged in." `
                -Hint "Run 'az login' (and 'az account set --subscription $azdSubId') before deploying."
        }
        elseif ($account.id -ne $azdSubId) {
            Add-Finding -Severity FAIL -Code 'AZ_SUB_DRIFT' `
                -Message "Azure CLI is using subscription '$($account.id)' but the azd environment expects '$azdSubId'." `
                -Hint "Run: az account set --subscription $azdSubId"
        }
    }

    # Resolve locations from the effective parameter set, falling back to the
    # primary `location` when service-specific overrides are empty.
    $location = Get-StringValue $P['location']
    $aiFoundryLocation = Get-StringValue $P['aiFoundryLocation']
    $cosmosLocation = Get-StringValue $P['cosmosLocation']
    if ([string]::IsNullOrWhiteSpace($aiFoundryLocation)) { $aiFoundryLocation = $location }
    if ([string]::IsNullOrWhiteSpace($cosmosLocation)) { $cosmosLocation = $location }

    if ([string]::IsNullOrWhiteSpace($location)) {
        Add-Finding -Severity WARN -Code 'REGIONAL_NO_LOCATION' `
            -Message "Regional readiness checks skipped: 'location' is empty." `
            -Hint "Set AZURE_LOCATION in the azd environment (azd env set AZURE_LOCATION <region>)."
        return
    }

    # Feature-flag resolution. Default-on flags follow main.parameters.json:
    # deployAiFoundry/deployCosmosDb/deployContainerApps/deployContainerEnv default true.
    # deploySearchService is gated by an env var; treat empty as true (matches the file default).
    # Note: PowerShell does not accept `if` as an expression inside `(...)` when
    # used as a command/function argument — the parser treats `if` as a command
    # name and fails with "The term 'if' is not recognized...". Wrap with the
    # subexpression operator `$(...)` so the if-expression is evaluated first.
    $deployAiFoundry = ConvertTo-Bool $(if ($null -ne $P['deployAiFoundry']) { $P['deployAiFoundry'] } else { $true })
    $deployCosmos = ConvertTo-Bool $(if ($null -ne $P['deployCosmosDb']) { $P['deployCosmosDb'] } else { $true })
    $deployContainerApps = ConvertTo-Bool $(if ($null -ne $P['deployContainerApps']) { $P['deployContainerApps'] } else { $true })
    $deployContainerEnv = ConvertTo-Bool $(if ($null -ne $P['deployContainerEnv']) { $P['deployContainerEnv'] } else { $true })
    $searchRaw = Get-StringValue $P['deploySearchService']
    $deploySearch = if ([string]::IsNullOrWhiteSpace($searchRaw)) { $true } else { ConvertTo-Bool $searchRaw }
    $deployKeyVault = ConvertTo-Bool $(if ($null -ne $P['deployKeyVault']) { $P['deployKeyVault'] } else { $true })
    $deployStorage = ConvertTo-Bool $(if ($null -ne $P['deployStorageAccount']) { $P['deployStorageAccount'] } else { $true })
    $deployAppConfig = ConvertTo-Bool $(if ($null -ne $P['deployAppConfig']) { $P['deployAppConfig'] } else { $true })
    $deployLogAnalytics = ConvertTo-Bool $(if ($null -ne $P['deployLogAnalytics']) { $P['deployLogAnalytics'] } else { $true })

    # Provider/location support
    if ($deploySearch) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.Search' -ResourceType 'searchServices' `
            -Location $location -DisplayName 'Azure AI Search' -CodePrefix 'SEARCH'
    }
    if ($deployCosmos) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.DocumentDB' -ResourceType 'databaseAccounts' `
            -Location $cosmosLocation -DisplayName 'Azure Cosmos DB' -CodePrefix 'COSMOS'
    }
    if ($deployContainerApps -or $deployContainerEnv) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.App' -ResourceType 'managedEnvironments' `
            -Location $location -DisplayName 'Azure Container Apps Environment' -CodePrefix 'ACA'
    }
    if ($deployAiFoundry) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.CognitiveServices' -ResourceType 'accounts' `
            -Location $aiFoundryLocation -DisplayName 'Azure AI Foundry / Cognitive Services' -CodePrefix 'AIFOUNDRY'
    }
    if ($deployKeyVault) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.KeyVault' -ResourceType 'vaults' `
            -Location $location -DisplayName 'Azure Key Vault' -CodePrefix 'KV'
    }
    if ($deployStorage) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.Storage' -ResourceType 'storageAccounts' `
            -Location $location -DisplayName 'Azure Storage' -CodePrefix 'STORAGE'
    }
    if ($deployAppConfig) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.AppConfiguration' -ResourceType 'configurationStores' `
            -Location $location -DisplayName 'Azure App Configuration' -CodePrefix 'APPCONFIG'
    }
    if ($deployLogAnalytics) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.OperationalInsights' -ResourceType 'workspaces' `
            -Location $location -DisplayName 'Log Analytics' -CodePrefix 'LAW'
        Test-ProviderLocation -ProviderNamespace 'Microsoft.Insights' -ResourceType 'components' `
            -Location $location -DisplayName 'Application Insights' -CodePrefix 'APPI'
    }

    # Jumpbox VM SKU. Resolve-DeployJumpbox mirrors main.bicep `_deployJumpbox`
    # so the SKU + quota checks run whenever the deployment will actually create
    # a jumpbox (including the common case where deployJumpbox is unset and
    # networkIsolation=true defaults it to true).
    $deployJump = Resolve-DeployJumpbox $P
    $vmSkuInfo = $null
    if ($deployJump) {
        $vmSize = Get-StringValue $P['vmSize']
        if (-not [string]::IsNullOrWhiteSpace($vmSize)) {
            # Single Azure lookup serves both the SKU-availability check and
            # the family-specific vCPU quota check below.
            $vmSkuInfo = Get-VmSkuInfo -Location $location -VmSize $vmSize
            Test-VmSku -Location $location -VmSize $vmSize -VmSkuInfo $vmSkuInfo
        }
    }

    # Model quota
    if ($deployAiFoundry) {
        $models = $P['modelDeploymentList']
        if ($models) {
            Test-ModelQuota -ModelDeployments $models -Location $aiFoundryLocation
        }
    }

    # Regional capacity sub-checks (folded in from
    # pipelines/tools/azure_region_capacity_checker.ps1).
    if ($deployJump -and $vmSkuInfo) {
        if ($vmSkuInfo.VCpus -gt 0) {
            # Headroom requirement = the SKU's vCPU count, against the SKU's
            # family-specific quota counter (the bucket Azure actually debits).
            Test-RegionalVcpuQuota -Location $location -RequiredHeadroom $vmSkuInfo.VCpus -Family $vmSkuInfo.Family
        }
        else {
            # Get-VmSkuInfo couldn't read the SKU's vCPU capability, so we can't
            # size the headroom requirement. Don't silently skip the quota check:
            # warn that headroom can't be verified, and still run the check with a
            # zero requirement so an already-exhausted family quota (available
            # <= 0) is surfaced rather than masked.
            Add-Finding -Severity WARN -Code 'VCPU_SKU_UNKNOWN' `
                -Message "Could not determine the vCPU count for VM SKU '$($vmSkuInfo.Name)' in '$location'; vCPU headroom cannot be verified." `
                -Hint "Confirm the SKU is offered in the region and re-run, or check family quota manually with: az vm list-usage --location $location"
            Test-RegionalVcpuQuota -Location $location -RequiredHeadroom 0 -Family $vmSkuInfo.Family
        }
    }

    # The Cognitive Services and Azure Search REST usage APIs need an explicit
    # subscription ID. Resolve once and reuse for both calls.
    $resolvedSubId = Get-CurrentAzureSubscriptionId
    if (-not [string]::IsNullOrWhiteSpace($resolvedSubId)) {
        if ($deployAiFoundry) {
            Test-CognitiveServicesQuotaHeadroom -SubscriptionId $resolvedSubId -Location $aiFoundryLocation
        }
        if ($deploySearch) {
            # main.bicep hardcodes the Search SKU to 'standard'; mirror that here.
            Test-AzureSearchSkuQuota -SubscriptionId $resolvedSubId -Location $location -Sku 'standard'
        }
    }

    if ($deployCosmos) {
        Test-CosmosAvailabilityZone -Location $cosmosLocation
    }
}

# --------------------------------------------------------------------------

function Write-FindingsReport {
    $byCode = $script:Findings | Group-Object -Property Code | ForEach-Object { $_.Group | Select-Object -First 1 }  # one row per code
    $failCount = @($script:Findings | Where-Object Severity -eq 'FAIL').Count
    $warnCount = @($script:Findings | Where-Object Severity -eq 'WARN').Count
    $infoCount = @($script:Findings | Where-Object Severity -eq 'INFO').Count

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host '  AI Landing Zone — Pre-Flight Check' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan

    if ($script:Findings.Count -eq 0) {
        Write-Host '  All checks passed.' -ForegroundColor Green
    }
    else {
        foreach ($f in $script:Findings) {
            $color = switch ($f.Severity) { 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Gray' } }
            Write-Host ("  [{0,-4}] {1,-30} {2}" -f $f.Severity, $f.Code, $f.Message) -ForegroundColor $color
            if ($f.Hint) {
                Write-Host ("         hint: {0}" -f $f.Hint) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host '----------------------------------------------------------------'
    Write-Host ("  Summary: {0} fail, {1} warn, {2} info" -f $failCount, $warnCount, $infoCount)
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''

    if ($failCount -gt 0) { return 1 }
    if ($Strict -and $warnCount -gt 0) { return 2 }
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if (-not $ParametersFile) {
    $ParametersFile = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'main.parameters.json'
}

Write-Host "[preflight] Parameters file: $ParametersFile"
if ($AzdEnv) { Write-Host "[preflight] azd environment: $AzdEnv" }
if ($SkipAzureLookups) { Write-Host "[preflight] Azure lookups: SKIPPED" -ForegroundColor Yellow }

Test-Tooling -ParametersPath $ParametersFile

$effective = Get-EffectiveParameters -Path $ParametersFile
if ($effective.Count -eq 0) {
    $code = Write-FindingsReport
    exit $code
}

Test-BooleanParameterValues -P $effective
Test-Topology -P $effective
Test-HostedAgentConfiguration -P $effective
Test-AllowedIpRanges -P $effective
Test-LocalCidrSanity -P $effective
Test-FoundryIqConfiguration -P $effective
Test-AzureResources -P $effective
Test-ApiManagementHubPeering -P $effective
Test-ResourceProviders -P $effective
Test-CosmosAnalyticalStorageRegionSupport -P $effective
Test-RegionalReadiness -P $effective

$exitCode = Write-FindingsReport
exit $exitCode
