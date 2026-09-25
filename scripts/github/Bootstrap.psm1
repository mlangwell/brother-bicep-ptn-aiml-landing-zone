#Requires -Version 7.0
<#
.SYNOPSIS
Plan-first, scoped GitHub and Azure platform reconciliation.
.DESCRIPTION
New-PlatformBootstrapPlan only reads. Invoke-PlatformBootstrapPlan requires
Execute, the inspected plan hash, current state, and ShouldProcess approval.
Neither a credential nor a successful plan authorizes execution.

PlatformInputs is a closed, versioned supplemental contract; obtain its JSON
schema with Get-BootstrapPlatformInputSchema. ResolvedEnvironment is the
unchanged Resolve-EnvironmentProfile result from Environment.psm1.

The GitHub environment PUT schema opened on 2026-09-16 does not accept
can_admins_bypass. This module never sends an undocumented field: test/prod
block unless the existing GET response proves bypass is disabled. Custom OIDC
templates similarly block under the current P1 immutable/legacy-only schema.

REST contracts:
https://docs.github.com/en/rest/deployments/environments
https://docs.github.com/en/rest/actions/oidc
https://docs.github.com/en/rest/actions/self-hosted-runner-groups
https://docs.github.com/en/rest/orgs/network-configurations
https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-examples
https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Roles = Get-Content -LiteralPath (Join-Path $script:Root 'constants\roles.json') -Raw | ConvertFrom-Json -AsHashtable
$script:LiveGates = @(
    'Run the separately authorized ProviderNoRbac preview with Azure CLI >= 2.76; static role inspection does not prove effective RBAC.'
    'Verify private DNS, routing and permitted egress from the actual private runner and developer/workload contexts.'
    'Complete resource-bound RBAC after DEVELOPER_COMPLETION exists, then verify governed inference access and rejection of backend bypass.'
)

function Get-BootstrapPlatformInputSchema {
    [CmdletBinding()]
    param()
    return @'
{
  "$schema":"http://json-schema.org/draft-07/schema#",
  "type":"object","additionalProperties":false,"required":["schemaVersion","owner"],
  "properties":{
    "schemaVersion":{"const":1},
    "owner":{"type":"string","pattern":"^[a-z][a-z0-9-]{2,39}$"},
    "github":{"type":"object","additionalProperties":false,"required":["serverUrl","apiUrl"],"properties":{
      "serverUrl":{"const":"https://github.com"},"apiUrl":{"const":"https://api.github.com"}
    }},
    "runner":{"type":"object","additionalProperties":false,
      "required":["groupId","approvedRepositoryIds","approvedWorkflowRefs","adminLogin","adminId","nsgResourceId","approvedNsgFingerprint"],
      "properties":{
        "groupId":{"type":"integer","minimum":1},
        "approvedRepositoryIds":{"type":"array","minItems":1,"uniqueItems":true,"items":{"type":"integer","minimum":1}},
        "approvedWorkflowRefs":{"type":"array","minItems":1,"uniqueItems":true,"items":{"type":"string","pattern":"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\\.github/workflows/[A-Za-z0-9_.-]+\\.ya?ml@refs/(heads|tags)/[^*?\\[\\]\\\\ ]+$"}},
        "adminLogin":{"type":"string","pattern":"^[A-Za-z0-9-]+$"},"adminId":{"type":"integer","minimum":1},
        "nsgResourceId":{"$ref":"#/definitions/resourceId"},"approvedNsgFingerprint":{"$ref":"#/definitions/hash"},
        "machineBindings":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,
          "required":["runnerId","runnerName","virtualMachineResourceId","networkInterfaceResourceId"],"properties":{
            "runnerId":{"type":"integer","minimum":1},
            "runnerName":{"type":"string","minLength":1,"pattern":"^[^\\r\\n]+$"},
            "virtualMachineResourceId":{"$ref":"#/definitions/resourceId"},"networkInterfaceResourceId":{"$ref":"#/definitions/resourceId"}
          }}}
      }
    },
    "access":{"type":"object","additionalProperties":false,"required":["deploymentRoleNames"],"properties":{
      "deploymentRoleNames":{"type":"array","minItems":1,"uniqueItems":true,"items":{"type":"string","pattern":"^[A-Za-z][A-Za-z0-9]+$"}},
      "gatewayBackendRoleName":{"enum":["CognitiveServicesOpenAIUser","CognitiveServicesUser"]}
    }},
    "governance":{"type":"object","additionalProperties":false,"required":["billingCurrency"],"properties":{
      "billingCurrency":{"type":"string","pattern":"^[A-Z]{3}$"}
    }},
    "ownership":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["resourceId","owner","fingerprint"],"properties":{
      "resourceId":{"$ref":"#/definitions/resourceId"},"owner":{"type":"string"},"fingerprint":{"$ref":"#/definitions/hash"}
    }}},
    "oidcEvidence":{"type":"object","additionalProperties":false,"properties":{
      "preview":{"$ref":"#/definitions/oidcEvidence"},"deploy":{"$ref":"#/definitions/oidcEvidence"}
    }},
    "network":{"type":"object","additionalProperties":false,"required":["spokeVnetResourceId","allowForwardedTraffic","egress"],"properties":{
      "spokeVnetResourceId":{"$ref":"#/definitions/resourceId"},"allowForwardedTraffic":{"type":"boolean"},
      "privateDnsZoneResourceIds":{"type":"array","uniqueItems":true,"items":{"$ref":"#/definitions/resourceId"}},
      "preparedSubnetNsgs":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,
        "required":["subnetResourceId","nsgResourceId","approvedNsgFingerprint"],"properties":{
          "subnetResourceId":{"$ref":"#/definitions/resourceId"},"nsgResourceId":{"$ref":"#/definitions/resourceId"},
          "approvedNsgFingerprint":{"$ref":"#/definitions/hash"}
        }}},
      "egress":{"type":"object","additionalProperties":false,
        "required":["routeTableResourceId","expectedNextHopIp","dnsResolverResourceId","approvedResolverFingerprint","expectedDnsServers","subnetResourceIds"],
        "properties":{
          "routeTableResourceId":{"$ref":"#/definitions/resourceId"},"dnsResolverResourceId":{"$ref":"#/definitions/resourceId"},
          "expectedNextHopIp":{"type":"string","format":"ipv4"},
          "approvedResolverFingerprint":{"$ref":"#/definitions/hash"},
          "expectedDnsServers":{"type":"array","minItems":1,"uniqueItems":true,"items":{"type":"string","format":"ipv4"}},
          "subnetResourceIds":{"type":"array","minItems":1,"uniqueItems":true,"items":{"$ref":"#/definitions/resourceId"}}
        }}
    }},
    "foundation":{"type":"object","additionalProperties":false,"required":["environment","azure","identityNames"],"properties":{
      "environment":{"enum":["dev","test","prod"]},
      "azure":{"type":"object","additionalProperties":false,"required":["tenantId","subscriptionId","resourceGroup","location"],"properties":{
        "tenantId":{"$ref":"#/definitions/guid"},"subscriptionId":{"$ref":"#/definitions/guid"},
        "resourceGroup":{"type":"string","pattern":"^(?!\\.{1,2}$)[A-Za-z0-9_().-]+(?<!\\.)$"},"location":{"type":"string","pattern":"^[a-z0-9]+$"}
      }},
      "identityNames":{"type":"object","additionalProperties":false,"required":["preview","deploy","workload"],"properties":{
        "preview":{"$ref":"#/definitions/identityName"},"deploy":{"$ref":"#/definitions/identityName"},"workload":{"$ref":"#/definitions/identityName"}
      }}
    }}
  },
  "definitions":{
    "guid":{"type":"string","pattern":"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"},
    "hash":{"type":"string","pattern":"^[a-f0-9]{64}$"},
    "identityName":{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9_-]{2,119}$"},
    "resourceId":{"type":"string","pattern":"^/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[A-Za-z0-9_().-]+/providers/[A-Za-z0-9.]+/[A-Za-z0-9_()./-]+$","not":{"pattern":"(^|/)\\.{1,2}(/|$)"}},
    "oidcEvidence":{"type":"object","additionalProperties":false,"required":["schemaVersion","serverUrl","claims"],"properties":{
      "schemaVersion":{"const":1},"serverUrl":{"const":"https://github.com"},
      "claims":{"type":"object","additionalProperties":false,
        "required":["iss","aud","sub","repository","repository_id","repository_owner_id","environment","ref","run_id","run_attempt","workflow_ref","workflow_sha","event_name"],
        "properties":{
          "iss":{"const":"https://token.actions.githubusercontent.com"},"aud":{"const":"api://AzureADTokenExchange"},
          "sub":{"type":"string","minLength":1},"repository":{"type":"string","pattern":"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"},
          "repository_id":{"type":"string","pattern":"^[1-9][0-9]*$"},"repository_owner_id":{"type":"string","pattern":"^[1-9][0-9]*$"},
          "environment":{"enum":["dev","dev-preview","test","test-preview","prod","prod-preview"]},
          "ref":{"type":"string","pattern":"^refs/(heads|tags)/[^*?\\[\\]\\\\ ]+$"},
          "run_id":{"type":"string","pattern":"^[1-9][0-9]*$"},"run_attempt":{"type":"string","pattern":"^[1-9][0-9]*$"},
          "workflow_ref":{"type":"string","minLength":1},"workflow_sha":{"type":"string","pattern":"^[a-f0-9]{40}$"},
          "event_name":{"const":"workflow_dispatch"},"iat":{"type":"integer"},"exp":{"type":"integer"},"nbf":{"type":"integer"}
        }}
    }}
  }
}
'@
}

function ConvertFrom-BootstrapElement {
    param([System.Text.Json.JsonElement]$Element)
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $value = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($value.Contains($property.Name)) { throw 'Duplicate or case-colliding JSON property in bootstrap input.' }
                $value[$property.Name] = ConvertFrom-BootstrapElement $property.Value
            }
            return ,$value
        }
        'Array' {
            $values = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $values.Add((ConvertFrom-BootstrapElement $item)) }
            return ,$values.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' { return $Element.GetDecimal() }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'Unsupported bootstrap JSON value.' }
    }
}

function ConvertFrom-BootstrapJson {
    <#
    .SYNOPSIS
    Parse strict JSON without converting ISO-8601 strings into DateTime objects.
    .DESCRIPTION
    Returns JSON dictionaries/arrays/scalars with exact decimal numbers. Rejects
    duplicate/case-colliding keys and logs no input values on parse failure.
    Use this for P3 Request.Body and P5 native JSON output before canonical hashes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $document = $null
    try {
        try { $document = [System.Text.Json.JsonDocument]::Parse($Json) }
        catch { throw 'Invalid bootstrap JSON; values are not included in diagnostics.' }
        return ConvertFrom-BootstrapElement $document.RootElement
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Assert-BootstrapArtifactSafe {
    param([AllowNull()][AllowEmptyCollection()]$Value)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -match '(?i)(password|passwd|client.?secret|access.?token|refresh.?token|private.?key|api.?key|account.?key|connectionstring|authorization|jwt)') {
                throw 'Bootstrap artifacts cannot contain credential-like fields. No field values are logged.'
            }
            Assert-BootstrapArtifactSafe -Value $Value[$key]
        }
    }
    elseif ($Value -is [Collections.IList]) {
        foreach ($item in $Value) { Assert-BootstrapArtifactSafe -Value $item }
    }
    elseif ($Value -is [string] -and
        ($Value -match '-----BEGIN .*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' -or
         $Value -match '(?i)\bBearer\s+\S+|(?:password|passwd|clientsecret|accountkey|sharedaccesssignature)\s*[:=]')) {
        throw 'Bootstrap artifacts cannot contain credential material. Values are suppressed.'
    }
}

function Read-BootstrapJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try { $json = [IO.File]::ReadAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) }
    catch { throw 'Bootstrap artifact could not be read.' }
    $value = ConvertFrom-BootstrapJson $json
    Assert-BootstrapArtifactSafe -Value $value
    return ,$value
}

function Read-PlatformInputs {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Json')][string]$Json
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        try { $Json = [IO.File]::ReadAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) }
        catch { throw 'Platform inputs could not be read.' }
    }
    $parsed = ConvertFrom-BootstrapJson $Json
    $valid = Test-Json -Json $Json -Schema (Get-BootstrapPlatformInputSchema) -ErrorAction SilentlyContinue
    if (-not $valid) { throw 'Platform input schema invalid: unknown property, missing field, or unsupported value.' }
    if ($Json -match '-----BEGIN .*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+') {
        throw 'Secret material is forbidden in platform inputs.'
    }
    Assert-BootstrapArtifactSafe -Value $parsed
    return ,$parsed
}

function Get-Field {
    param([AllowNull()]$Value, [string]$Name, [AllowNull()]$Default = $null)
    if ($Value -is [Collections.IDictionary] -and $Value.Contains($Name)) { return $Value[$Name] }
    return $Default
}

function Copy-BootstrapValue {
    param([AllowNull()]$Value)
    ConvertFrom-BootstrapJson (ConvertTo-CanonicalJson -Value $Value)
}

function Get-UnsignedHash {
    param([Collections.IDictionary]$Value, [string]$Field)
    $copy = [ordered]@{}
    foreach ($key in $Value.Keys) { if ($key -cne $Field) { $copy[$key] = $Value[$key] } }
    Get-CanonicalHash $copy
}

function Assert-ResolvedBootstrapEnvironment {
    param([Collections.IDictionary]$Resolved, [switch]$AllowSynthetic)
    if ($Resolved.schemaVersion -ne 1 -or $Resolved.environment -notin @('dev', 'test', 'prod') -or
        $Resolved.environment -cne $Resolved.profile.environment -or
        $Resolved.configurationHash -cne (Get-UnsignedHash $Resolved 'configurationHash')) {
        throw 'Invalid or changed Resolve-EnvironmentProfile contract/hash.'
    }
    Assert-BootstrapProfile -Profile $Resolved.profile -AllowSynthetic:$AllowSynthetic
}

function Assert-BootstrapProfile {
    param([Collections.IDictionary]$Profile, [switch]$AllowSynthetic)
    $p = $Profile
    if ($p.schemaVersion -ne 1 -or $p.environment -notin @('dev', 'test', 'prod')) { throw 'A valid v1 dev/test/prod profile is required.' }
    if ($p.synthetic -and -not $AllowSynthetic) { throw 'Synthetic bootstrap inputs are allowed only in offline mock planning.' }
    foreach ($field in 'tenantId', 'subscriptionId') {
        $id = [guid]::Empty
        if (-not [guid]::TryParseExact($p.azure[$field], 'D', [ref]$id) -or $id -eq [guid]::Empty) { throw "Invalid azure.$field." }
    }
    if ($p.azure.resourceGroup -notmatch '^[A-Za-z0-9_().-]+$' -or
        $p.github.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $p.github.protectedRef -notmatch '^refs/(heads|tags)/[^*?\[\]\\ ]+$') {
        throw 'Bootstrap requires an exact resource group, repository and approved ref, not patterns.'
    }
    if ($p.github.repositoryId -lt 1 -or $p.github.ownerId -lt 1) { throw 'Numeric repository and owner IDs are required.' }
    if ($p.github.oidc.issuer -cne 'https://token.actions.githubusercontent.com' -or
        $p.github.oidc.audience -cne 'api://AzureADTokenExchange') { throw 'Unsupported OIDC issuer or audience.' }
}

function Invoke-BootstrapNative {
    param([string]$Command, [AllowEmptyCollection()][string[]]$Arguments = @())
    $executable = @(Get-Command -Name $Command -CommandType Application -ErrorAction Stop)[0]
    if ($IsWindows -and [IO.Path]::GetExtension($executable.Source) -in @('.cmd', '.bat')) {
        foreach ($value in @($executable.Source) + $Arguments) {
            if ($value -match '["&|<>^%!\r\n]') { throw 'Unsupported shell metacharacter in Windows CLI invocation. Arguments are suppressed.' }
        }
        return Invoke-CheckedNative -Command $env:ComSpec -Arguments (@('/d', '/c', 'call', $executable.Source) + $Arguments)
    }
    Invoke-CheckedNative -Command $Command -Arguments $Arguments
}

function New-BootstrapTransport {
    param(
        [Collections.IDictionary]$Azure,
        [Collections.IDictionary]$GitHub,
        [scriptblock]$Native = { param($Command, $Arguments) Invoke-BootstrapNative -Command $Command -Arguments $Arguments },
        [scriptblock]$Http = { param($Arguments) Invoke-WebRequest @Arguments }
    )
    $context = @{
        Azure = $Azure; GitHub = $GitHub; GitHubToken = $null; AzureToken = $null
        Native = $Native; Http = $Http; Parser = ${function:ConvertFrom-BootstrapJson}
    }
    return {
        param($Request)
        $headers = @{ Accept = 'application/json' }
        if ($Request.provider -eq 'GitHub') {
            if ($context.GitHub.serverUrl -cne 'https://github.com' -or $context.GitHub.apiUrl -cne 'https://api.github.com') {
                throw 'This bootstrap contract supports github.com only; another cloud requires a reviewed adapter.'
            }
            if ($Request.path -notmatch '^/(repos|orgs|meta|user)(/|$|\?)' -or $Request.path -match '://|[\r\n]') { throw 'Rejected GitHub API target.' }
            if ($null -eq $context.GitHubToken) {
                $context.GitHubToken = (& $context.Native 'gh' @('auth', 'token', '--hostname', 'github.com')).Trim()
                if (-not $context.GitHubToken) { throw 'GitHub authentication returned no credential.' }
            }
            $headers.Authorization = "Bearer $($context.GitHubToken)"
            $headers.Accept = 'application/vnd.github+json'
            $headers['X-GitHub-Api-Version'] = '2026-03-10'
            $uri = "https://api.github.com$($Request.path)"
        }
        elseif ($Request.provider -eq 'Azure') {
            $subscriptionTarget = $Request.path -match '^/subscriptions/[a-fA-F0-9-]{36}/'
            $builtinRead = $Request.method -ceq 'GET' -and $Request.path -match '^/providers/Microsoft\.Authorization/policyDefinitions/[a-fA-F0-9-]{36}(?:/versions/[0-9.]+)?\?'
            if ((-not $subscriptionTarget -and -not $builtinRead) -or $Request.path -match '://|[\r\n]') { throw 'Rejected Azure API target.' }
            if ($null -eq $context.AzureToken) {
                $account = & $context.Native 'az' @('account', 'show', '--subscription', $context.Azure.subscriptionId, '--output', 'json')
                $account = & $context.Parser $account
                if ($account.id -ine $context.Azure.subscriptionId -or $account.tenantId -ine $context.Azure.tenantId) {
                    throw 'Azure credential tenant/subscription does not match the inspected bootstrap scope.'
                }
                $context.AzureToken = (& $context.Native 'az' @('account', 'get-access-token', '--subscription', $context.Azure.subscriptionId, '--resource', 'https://management.azure.com/', '--query', 'accessToken', '--output', 'tsv')).Trim()
                if (-not $context.AzureToken) { throw 'Azure authentication returned no credential.' }
            }
            $headers.Authorization = "Bearer $($context.AzureToken)"
            $uri = "https://management.azure.com$($Request.path)"
        }
        else { throw 'Unknown bootstrap API provider.' }
        foreach ($key in $Request.headers.Keys) { $headers[$key] = $Request.headers[$key] }
        $arguments = @{
            Uri = $uri; Method = $Request.method; Headers = $headers
            SkipHttpErrorCheck = $true; MaximumRedirection = 0; TimeoutSec = 60; ErrorAction = 'Stop'
            Verbose = $false; Debug = $false
        }
        if ($null -ne $Request.body) {
            $arguments.Body = ConvertTo-CanonicalJson $Request.body
            $arguments.ContentType = 'application/json'
        }
        try { $response = & $context.Http $arguments }
        catch { throw 'Bootstrap HTTP transport failed; credentials and response content are not logged.' }
        $body = if ([string]::IsNullOrWhiteSpace($response.Content)) { $null } else { & $context.Parser $response.Content }
        $etag = if ($response.Headers.ContainsKey('ETag')) { [string]($response.Headers['ETag'] -join '') } else { '' }
        return @{ status = [int]$response.StatusCode; body = $body; etag = $etag }
    }.GetNewClosure()
}

function New-PlanContext {
    param($Resolved, $Inputs, [scriptblock]$Transport)
    @{
        Resolved = $Resolved; Profile = if ($null -ne $Resolved) { $Resolved.profile } else { $null }
        Inputs = $Inputs; Transport = $Transport; Cache = @{}
        Operations = [Collections.Generic.List[object]]::new()
        Observations = [Collections.Generic.List[object]]::new()
        Blockers = [Collections.Generic.List[object]]::new()
    }
}

function Add-BootstrapBlocker {
    param($Context, [string]$Code, [string]$Target, [string]$Requirement)
    $Context.Blockers.Add(@{ code = $Code; target = $Target; requirement = $Requirement })
}

function Read-BootstrapResource {
    param($Context, [string]$Provider, [string]$Path, [switch]$AllowMissing)
    $key = "${Provider}:$Path"
    if ($Context.Cache.ContainsKey($key)) { return $Context.Cache[$key] }
    $response = & $Context.Transport @{ provider = $Provider; method = 'GET'; path = $Path; body = $null; headers = @{} }
    if ($null -eq $response -or -not $response.Contains('status')) { throw 'Bootstrap transport returned no HTTP status.' }
    if ($response.status -ne 200 -and -not ($AllowMissing -and $response.status -eq 404)) {
        throw "Bootstrap GET $Provider $Path failed with HTTP $($response.status). Verify scoped privileges and API support."
    }
    $snapshot = @{
        provider = $Provider; path = $Path; status = [int]$response.status
        etag = [string](Get-Field $response 'etag' '')
        fingerprint = Get-CanonicalHash -Value $response.body
        body = Copy-BootstrapValue $response.body
    }
    if (-not $snapshot.etag) { $snapshot.etag = [string](Get-Field $snapshot.body 'etag' '') }
    $Context.Cache[$key] = $snapshot
    $Context.Observations.Add(@{ provider = $Provider; path = $Path; status = $snapshot.status; etag = $snapshot.etag; fingerprint = $snapshot.fingerprint })
    return $snapshot
}

function Read-BootstrapCollection {
    param($Context, [string]$Provider, [string]$Path, [string]$Field, [switch]$AllowMissing)
    $items = [Collections.Generic.List[object]]::new()
    $page = 1
    $next = $Path
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($next) {
        if (-not $seen.Add($next)) { throw 'Bootstrap collection pagination repeated a URL.' }
        $response = Read-BootstrapResource $Context $Provider $next -AllowMissing:$AllowMissing
        if ($response.status -eq 404) { return ,@() }
        $values = @(Get-Field $response.body $Field @())
        foreach ($item in $values) { $items.Add($item) }
        if ($Provider -eq 'GitHub') {
            $total = Get-Field $response.body 'total_count' $null
            if ($null -eq $total) { throw "GitHub collection $Path has no total_count; pagination cannot be verified." }
            if ($items.Count -ge $total) { break }
            if ($values.Count -eq 0) { throw "GitHub collection $Path ended before total_count." }
            $page++
            $separator = if ($Path.Contains('?')) { '&' } else { '?' }
            $next = "${Path}${separator}per_page=100&page=$page"
        }
        else {
            $next = [string](Get-Field $response.body 'nextLink' '')
            if ($next) {
                $uri = [uri]$next
                if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or $uri.AbsolutePath -ine ($Path -split '\?', 2)[0]) {
                    throw 'Rejected an out-of-scope Azure pagination URL.'
                }
                $next = $uri.PathAndQuery
            }
        }
    }
    return ,$items.ToArray()
}

function Test-DesiredSubset {
    param([AllowNull()]$Actual, [AllowNull()]$Desired)
    if ($null -eq $Desired) { return $null -eq $Actual }
    if ($Desired -is [Collections.IDictionary]) {
        if ($Actual -isnot [Collections.IDictionary]) { return $false }
        foreach ($key in $Desired.Keys) {
            if (-not $Actual.Contains($key) -or -not (Test-DesiredSubset $Actual[$key] $Desired[$key])) { return $false }
        }
        return $true
    }
    if ($Desired -is [Collections.IList]) {
        if ($Actual -isnot [Collections.IList] -or $Actual.Count -ne $Desired.Count) { return $false }
        $actualHashes = @($Actual | ForEach-Object { Get-CanonicalHash $_ } | Sort-Object)
        $desiredHashes = @($Desired | ForEach-Object { Get-CanonicalHash $_ } | Sort-Object)
        return (Get-CanonicalHash -Value $actualHashes) -ceq (Get-CanonicalHash -Value $desiredHashes)
    }
    if ($Desired -is [string] -and $Desired.StartsWith('/subscriptions/', [StringComparison]::OrdinalIgnoreCase)) {
        return $Actual -is [string] -and $Actual -ieq $Desired
    }
    return (Get-CanonicalHash -Value $Actual) -ceq (Get-CanonicalHash -Value $Desired)
}

function Get-OwnerValue {
    param($Context)
    if ($null -eq (Get-Field $Context.Profile 'github')) {
        return "$($Context.Inputs.owner):foundation:$($Context.Profile.environment)"
    }
    "$($Context.Inputs.owner):$($Context.Profile.github.repositoryId):$($Context.Profile.environment)"
}

function Get-BootstrapName {
    param($Context, [string]$Purpose, [string]$Target)
    $suffix = (Get-CanonicalHash -Value $Target.ToLowerInvariant()).Substring(0, 12)
    "$($Context.Inputs.owner)-$($Context.Profile.environment)-$Purpose-$suffix"
}

function Get-BootstrapGuid {
    param([string]$Value)
    $hex = (Get-CanonicalHash -Value $Value.ToLowerInvariant()).Substring(0, 32)
    ([guid]::ParseExact($hex, 'N')).ToString('D')
}

function Test-ResourceOwnership {
    param($Context, $Snapshot)
    if ($Snapshot.status -eq 404) { return $true }
    $owner = Get-OwnerValue $Context
    $tags = Get-Field $Snapshot.body 'tags' @{}
    if ((Get-Field $tags 'ailz-bootstrap-owner' '') -ceq $owner) { return $true }
    $properties = Get-Field $Snapshot.body 'properties' @{}
    if ((Get-Field $properties 'description' '') -ceq "Managed by ailz-bootstrap; owner=$owner") { return $true }
    $id = ($Snapshot.path -split '\?', 2)[0]
    $receipts = @(Get-Field $Context.Inputs 'ownership' @())
    return @($receipts | Where-Object { $_.resourceId -ieq $id -and $_.owner -ceq $owner -and $_.fingerprint -ceq $Snapshot.fingerprint }).Count -eq 1
}

function Add-ArmOperation {
    param($Context, [string]$Kind, [string]$Id, [string]$ApiVersion, $Body, [string]$Scope, [string]$Permission)
    $path = "${Id}?api-version=$ApiVersion"
    $before = Read-BootstrapResource $Context 'Azure' $path -AllowMissing
    if ($before.status -eq 200 -and $Body.Contains('tags')) {
        $tags = Copy-BootstrapValue (Get-Field $before.body 'tags' @{})
        foreach ($key in $Body.tags.Keys) { $tags[$key] = $Body.tags[$key] }
        $Body.tags = $tags
    }
    if ($before.status -eq 200 -and $Kind -eq 'dnsLink' -and $before.body.properties.Contains('resolutionPolicy')) {
        $Body.properties.resolutionPolicy = $before.body.properties.resolutionPolicy
    }
    if ($before.status -eq 200 -and (Test-DesiredSubset $before.body $Body)) { return }
    if (-not (Test-ResourceOwnership $Context $before)) {
        Add-BootstrapBlocker $Context 'OWNERSHIP_CONFLICT' $Id 'Existing nonmatching resource is not owned. Supply a reviewed ownership receipt or have its administrator reconcile it.'
        return
    }
    $Context.Operations.Add(@{
        kind = $Kind; provider = 'Azure'; method = 'PUT'; path = $path; scope = $Scope
        permission = $Permission; body = $Body; before = $before; owner = Get-OwnerValue $Context
    })
}

function Read-GitHubBootstrapIdentity {
    param($Context)
    $p = $Context.Profile
    if ($null -eq (Get-Field $Context.Inputs 'github')) {
        Add-BootstrapBlocker $Context 'GITHUB_CLOUD_UNVERIFIED' 'platformInputs.github' 'Supply the exact supported serverUrl and apiUrl.'
        return $null
    }
    $meta = (Read-BootstrapResource $Context 'GitHub' '/meta').body
    if (Get-Field $meta 'installed_version') { Add-BootstrapBlocker $Context 'GITHUB_CLOUD_UNSUPPORTED' 'GitHub Enterprise Server' 'The frozen P1 contract and issuer support github.com, not GHES.' }
    $repo = (Read-BootstrapResource $Context 'GitHub' "/repos/$($p.github.repository)").body
    if ($repo.id -ne $p.github.repositoryId -or $repo.owner.id -ne $p.github.ownerId -or
        $repo.full_name -cne $p.github.repository -or $repo.visibility -cne $p.github.visibility) {
        Add-BootstrapBlocker $Context 'REPOSITORY_IDENTITY_CHANGED' $p.github.repository 'Observed numeric IDs, repository name and visibility must match the inspected profile.'
    }
    if ((Get-Field $repo 'archived' $false) -or (Get-Field $repo 'disabled' $false)) {
        Add-BootstrapBlocker $Context 'REPOSITORY_READ_ONLY' $p.github.repository 'Archived or disabled repositories cannot establish the required deployment path.'
    }
    $refPath = (($p.github.protectedRef.Substring(5).Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $ref = Read-BootstrapResource $Context 'GitHub' "/repos/$($p.github.repository)/git/ref/$refPath" -AllowMissing
    if ($ref.status -ne 200 -or $ref.body.ref -cne $p.github.protectedRef) {
        Add-BootstrapBlocker $Context 'PROTECTED_REF_UNVERIFIED' $p.github.protectedRef 'The exact approved branch/tag ref must exist in the observed target repository.'
    }
    if ($repo.owner.type -cne 'Organization') {
        Add-BootstrapBlocker $Context 'ORGANIZATION_REQUIRED' $repo.owner.login 'Private runner administration requires the actual target organization; a personal public fork proves no entitlement.'
        return $repo
    }
    $org = (Read-BootstrapResource $Context 'GitHub' "/orgs/$($repo.owner.login)").body
    $planName = [string](Get-Field (Get-Field $org 'plan' @{}) 'name' '')
    $observedOffering = if ($planName -eq 'enterprise') { 'enterprise-cloud' } else { $planName }
    if ($org.id -ne $p.github.ownerId -or $observedOffering -cne $p.github.offering) {
        Add-BootstrapBlocker $Context 'ENTITLEMENT_UNVERIFIED' $repo.owner.login 'Organization ID and the authenticated organization plan must substantiate the selected offering; unavailable billing/plan evidence blocks readiness.'
    }
    if ($p.environment -in @('test', 'prod') -and $repo.visibility -ne 'public' -and $observedOffering -ne 'enterprise-cloud') {
        Add-BootstrapBlocker $Context 'ENTITLEMENT_UNVERIFIED' $repo.full_name 'Required reviewers in a private/internal repository require verified Enterprise entitlement.'
    }
    return $repo
}

function Get-EnvironmentState {
    param($Context, [string]$Name, [switch]$WithoutOwnership)
    $path = "/repos/$($Context.Profile.github.repository)/environments/$([uri]::EscapeDataString($Name))"
    $resource = Read-BootstrapResource $Context 'GitHub' $path -AllowMissing
    $marker = $null
    if (-not $WithoutOwnership) { $marker = Read-BootstrapResource $Context 'GitHub' "$path/variables/AILZ_BOOTSTRAP_OWNER" -AllowMissing }
    $branches = @()
    if ($resource.status -eq 200) {
        $branches = Read-BootstrapCollection $Context 'GitHub' "$path/deployment-branch-policies" 'branch_policies'
    }
    return @{ resource = $resource; marker = $marker; branches = @($branches) }
}

function Get-EnvironmentWriteBody {
    param($State)
    $rules = @(Get-Field $State.resource.body 'protection_rules' @())
    $reviewers = [Collections.Generic.List[object]]::new()
    $prevent = $false
    $wait = 0
    foreach ($rule in $rules) {
        if ($rule.type -eq 'required_reviewers') {
            $prevent = [bool](Get-Field $rule 'prevent_self_review' $false)
            foreach ($reviewer in $rule.reviewers) { $reviewers.Add(@{ type = $reviewer.type; id = $reviewer.reviewer.id }) }
        }
        if ($rule.type -eq 'wait_timer') { $wait = $rule.wait_timer }
    }
    return @{
        wait_timer = $wait; prevent_self_review = $prevent
        reviewers = @($reviewers.ToArray() | Sort-Object type, id)
        deployment_branch_policy = Get-Field $State.resource.body 'deployment_branch_policy' $null
    }
}

function Add-EnvironmentPlans {
    param($Context, $Repository, [switch]$AssertExisting)
    $p = $Context.Profile
    if (-not $AssertExisting -and -not [bool](Get-Field (Get-Field $Repository 'permissions' @{}) 'admin' $false)) {
        Add-BootstrapBlocker $Context 'GITHUB_ADMIN_REQUIRED' $p.github.repository 'The current GitHub principal needs repository administration permission for these exact environments.'
    }
    foreach ($name in @("$($p.environment)-preview", $p.environment)) {
        $state = Get-EnvironmentState $Context $name -WithoutOwnership:$AssertExisting
        $protected = $name -in @('test', 'prod')
        $owner = if ($AssertExisting) { '' } else { Get-OwnerValue $Context }
        if ($AssertExisting -and $state.resource.status -ne 200) {
            Add-BootstrapBlocker $Context 'ENVIRONMENT_NOT_READY' $name 'The selected preview/deployment environment must already exist before private jobs are scheduled.'
            continue
        }
        if (-not $AssertExisting -and $state.resource.status -eq 200 -and ($state.marker.status -ne 200 -or $state.marker.body.value -cne $owner)) {
            Add-BootstrapBlocker $Context 'OWNERSHIP_CONFLICT' $name 'Existing environment lacks this exact bootstrap ownership marker; do not overwrite foreign configuration.'
            continue
        }
        if ($protected -and @($p.github.environmentReviewers).Count -eq 0) {
            Add-BootstrapBlocker $Context 'REVIEWERS_REQUIRED' $name 'Supply independent User/Team reviewers for the protected deployment environment.'
            continue
        }
        if ($protected -and ($state.resource.status -ne 200 -or
            (Get-Field $state.resource.body 'can_admins_bypass' $null) -isnot [bool] -or $state.resource.body.can_admins_bypass)) {
            Add-BootstrapBlocker $Context 'ADMIN_BYPASS_UNVERIFIED' $name 'An administrator must establish bypass-disabled protection using a supported mechanism; the published environment PUT schema cannot set it. Require an observed can_admins_bypass=false response.'
            continue
        }
        $current = Get-EnvironmentWriteBody $state
        $desired = Copy-BootstrapValue $current
        if ($protected) {
            $desired.prevent_self_review = $true
            $reviewers = @{}
            foreach ($reviewer in @($current.reviewers) + @($p.github.environmentReviewers)) { $reviewers["$($reviewer.type):$($reviewer.id)"] = $reviewer }
            $desired.reviewers = @($reviewers.Values | Sort-Object type, id)
            if ($desired.reviewers.Count -gt 6) {
                Add-BootstrapBlocker $Context 'REVIEWER_MERGE_UNSUPPORTED' $name 'Preserving the existing reviewer set exceeds the published API maximum of six; obtain an administrator decision.'
                continue
            }
        }
        if ($null -ne $current.deployment_branch_policy -and $current.deployment_branch_policy.protected_branches) {
            Add-BootstrapBlocker $Context 'BRANCH_POLICY_CONFLICT' $name 'Do not replace an existing protected-branches rule with a different protection model.'
            continue
        }
        $desired.deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
        $refParts = $p.github.protectedRef -split '/', 3
        $branch = @{ name = $refParts[2]; type = if ($refParts[1] -eq 'heads') { 'branch' } else { 'tag' } }
        $otherBranches = @($state.branches | Where-Object { $_.name -cne $branch.name -or $_.type -cne $branch.type })
        if ($otherBranches.Count -gt 0 -or $state.branches.Count -gt 1) {
            Add-BootstrapBlocker $Context 'BRANCH_POLICY_CONFLICT' $name 'Existing deployment allowlist differs from the exact approved ref; no policy is deleted or broadened automatically.'
            continue
        }
        $update = $state.resource.status -eq 404 -or -not (Test-DesiredSubset $current $desired)
        $unknownRules = @((Get-Field $state.resource.body 'protection_rules' @()) | Where-Object { $_.type -notin @('wait_timer', 'required_reviewers', 'branch_policy') })
        if ($update -and $unknownRules.Count -gt 0) {
            Add-BootstrapBlocker $Context 'PROTECTION_MERGE_UNSUPPORTED' $name 'An environment with additional protection-rule types needs administrator reconciliation; do not risk dropping them through PUT.'
            continue
        }
        if ($AssertExisting) {
            if ($update -or $state.branches.Count -eq 0) {
                Add-BootstrapBlocker $Context 'ENVIRONMENT_NOT_READY' $name 'Observed reviewer/self-review and exact deployment-ref restrictions do not meet the profile. The select job cannot repair them.'
            }
            continue
        }
        if ($update -or $state.marker.status -eq 404 -or $state.branches.Count -eq 0) {
            $Context.Operations.Add(@{
                kind = 'environment'; provider = 'GitHub'; name = $name; path = $state.resource.path
                before = $state; body = $desired; branch = $branch; owner = $owner
                updateEnvironment = $update; createMarker = $state.marker.status -eq 404; createBranch = $state.branches.Count -eq 0
                requireAdminBypassDisabled = $protected
            })
        }
    }
}

function Test-OidcEvidence {
    param($Context, [string]$Purpose, $Evidence)
    $p = $Context.Profile
    $g = $p.github
    $name = if ($Purpose -eq 'preview') { "$($p.environment)-preview" } else { $p.environment }
    if ($null -eq $Evidence) { return $false }
    $claims = $Evidence.claims
    $repoParts = $g.repository.Split('/')
    $prefix = if ($g.oidc.subjectFormat -ceq 'immutable') {
        "repo:$($repoParts[0])@$($g.ownerId)/$($repoParts[1])@$($g.repositoryId)"
    }
    elseif ($g.oidc.subjectFormat -ceq 'legacy') { "repo:$($g.repository)" }
    else { return $false }
    $subject = "${prefix}:environment:$name"
    if ($Evidence.serverUrl -cne 'https://github.com' -or $claims.iss -cne $g.oidc.issuer -or $claims.aud -cne $g.oidc.audience -or
        $claims.sub -cne $subject -or $g.oidc["${Purpose}Subject"] -cne $subject -or
        $claims.repository -cne $g.repository -or [string]$claims.repository_id -cne [string]$g.repositoryId -or
        [string]$claims.repository_owner_id -cne [string]$g.ownerId -or $claims.environment -cne $name -or
        $claims.ref -cne $g.protectedRef -or $claims.event_name -cne 'workflow_dispatch') { return $false }
    $run = (Read-BootstrapResource $Context 'GitHub' "/repos/$($g.repository)/actions/runs/$($claims.run_id)/attempts/$($claims.run_attempt)").body
    $workflowRef = "$($g.repository)/$($run.path)@$($g.protectedRef)"
    return (
        [string]$run.id -ceq [string]$claims.run_id -and [string]$run.run_attempt -ceq [string]$claims.run_attempt -and
        $run.repository.id -eq $g.repositoryId -and $run.repository.owner.id -eq $g.ownerId -and
        $run.head_sha -ceq $claims.workflow_sha -and $claims.workflow_ref -ceq $workflowRef -and
        $run.event -ceq 'workflow_dispatch' -and $run.status -ceq 'completed' -and $run.conclusion -ceq 'success' -and
        $run.head_branch -ceq ($g.protectedRef -split '/', 3)[2]
    )
}

function Read-BootstrapIdentity {
    param($Context, [string]$Purpose)
    $identity = $Context.Profile.identities[$Purpose]
    if ($identity.resourceId -notmatch '^/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[^/]+/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[^/]+$') {
        throw "The $Purpose identity must be an exact user-assigned managed identity resource ID."
    }
    $observed = (Read-BootstrapResource $Context 'Azure' "$($identity.resourceId)?api-version=2024-11-30").body
    if ($observed.id -ine $identity.resourceId -or $observed.properties.clientId -ine $identity.clientId -or
        $observed.properties.principalId -ine $identity.principalId -or $observed.properties.tenantId -ine $Context.Profile.azure.tenantId) {
        Add-BootstrapBlocker $Context 'IDENTITY_BINDING_INVALID' $identity.resourceId 'Actual resource/client/principal/tenant IDs must match; generated IDs require the separate foundation stage first.'
    }
    return $observed
}

function Add-FederationPlans {
    param($Context)
    $p = $Context.Profile
    $configuration = (Read-BootstrapResource $Context 'GitHub' "/repos/$($p.github.repository)/actions/oidc/customization/sub").body
    if ((Get-Field $configuration 'use_default' $null) -isnot [bool] -or -not $configuration.use_default) {
        Add-BootstrapBlocker $Context 'OIDC_CUSTOM_TEMPLATE_UNSUPPORTED' $p.github.repository 'Observed custom/unknown OIDC templates are outside the frozen P1 contract. Extend that contract through the parent; never overwrite GitHub customization.'
        return
    }
    if ((Get-Field $configuration 'use_immutable_subject' $false) -and $p.github.oidc.subjectFormat -cne 'immutable') {
        Add-BootstrapBlocker $Context 'OIDC_EVIDENCE_INVALID' $p.github.repository 'The observed immutable-subject setting contradicts the selected legacy profile/evidence.'
        return
    }
    if ($p.identities.preview.resourceId -ieq $p.identities.deploy.resourceId -or
        $p.identities.preview.clientId -ieq $p.identities.deploy.clientId -or
        $p.identities.preview.principalId -ieq $p.identities.deploy.principalId -or
        $p.github.oidc.previewSubject -ceq $p.github.oidc.deploySubject) {
        Add-BootstrapBlocker $Context 'IDENTITIES_NOT_SEPARATE' $p.environment 'Preview and deployment require distinct resources, client/principal IDs, environments and subjects.'
        return
    }
    $evidence = Get-Field $Context.Inputs 'oidcEvidence' @{}
    foreach ($purpose in 'preview', 'deploy') {
        if (-not (Test-OidcEvidence $Context $purpose (Get-Field $evidence $purpose))) {
            Add-BootstrapBlocker $Context 'OIDC_EVIDENCE_INVALID' "$($p.environment):$purpose" 'Capture verified emitted claims in a successful no-Azure-access workflow; repository IDs, run/attempt, exact ref, workflow, issuer, audience and environment must match.'
        }
    }
    if ($Context.Blockers.Count -gt 0) { return }
    foreach ($purpose in 'preview', 'deploy') {
        $null = Read-BootstrapIdentity $Context $purpose
        $identity = $p.identities[$purpose]
        $desired = @{ properties = @{ issuer = $p.github.oidc.issuer; audiences = @($p.github.oidc.audience); subject = $evidence[$purpose].claims.sub } }
        $existing = Read-BootstrapCollection $Context 'Azure' "$($identity.resourceId)/federatedIdentityCredentials?api-version=2024-11-30" 'value'
        $matches = @($existing | Where-Object { Test-DesiredSubset $_ $desired })
        if ($matches.Count -gt 1) { Add-BootstrapBlocker $Context 'DUPLICATE_FEDERATION' $identity.resourceId 'Multiple equivalent trusts already exist; administrator reconciliation is required.'; continue }
        if ($matches.Count -eq 1) { continue }
        $name = Get-BootstrapName $Context $purpose $identity.resourceId
        Add-ArmOperation $Context 'federation' "$($identity.resourceId)/federatedIdentityCredentials/$name" '2024-11-30' $desired $identity.resourceId 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write'
    }
}

function Add-RunnerMachineChecks {
    param($Context, [AllowEmptyCollection()][object[]]$Runners, [switch]$MetadataOnly)
    $input = $Context.Inputs.runner
    $runner = $Context.Profile.github.runner
    $bindings = @(Get-Field $input 'machineBindings' @())
    if ($bindings.Count -eq 0) {
        Add-BootstrapBlocker $Context 'RUNNER_MACHINE_BINDING_REQUIRED' $runner.group 'Supply administrator-approved runner ID/name, Azure VM/NIC bindings and the approved subnet NSG fingerprint.'
        return
    }
    foreach ($registered in $Runners) {
        $binding = @($bindings | Where-Object { $_.runnerId -eq $registered.id -and $_.runnerName -ceq $registered.name })
        if ($binding.Count -ne 1) {
            Add-BootstrapBlocker $Context 'RUNNER_MACHINE_BINDING_REQUIRED' $registered.name 'Require one explicit approved runner ID/name to machine binding.'
            continue
        }
        $vmId = $binding[0].virtualMachineResourceId
        $nicId = $binding[0].networkInterfaceResourceId
        Assert-ResourceBinding $vmId 'Microsoft\.Compute/(virtualMachines/[^/]+|virtualMachineScaleSets/[^/]+/virtualMachines/[^/]+)'
        Assert-ResourceBinding $nicId '(Microsoft\.Network/networkInterfaces/[^/]+|Microsoft\.Compute/virtualMachineScaleSets/[^/]+/virtualMachines/[^/]+/networkInterfaces/[^/]+)'
        if ($MetadataOnly) { continue }
        $vm = (Read-BootstrapResource $Context 'Azure' "${vmId}?api-version=2024-07-01").body
        $nic = (Read-BootstrapResource $Context 'Azure' "${nicId}?api-version=2024-05-01").body
        $interfaces = @(Get-Field (Get-Field $vm.properties 'networkProfile' @{}) 'networkInterfaces' @())
        $osType = Get-Field (Get-Field (Get-Field $vm.properties 'storageProfile' @{}) 'osDisk' @{}) 'osType' ''
        $ipConfigurations = @(Get-Field $nic.properties 'ipConfigurations' @())
        $wrongNetwork = @($ipConfigurations | Where-Object {
            (Get-Field (Get-Field $_.properties 'subnet' @{}) 'id' '') -ine $runner.subnetResourceId -or
            $null -ne (Get-Field $_.properties 'publicIPAddress')
        })
        if ($vm.id -ine $vmId -or $nic.id -ine $nicId -or $osType -ine 'Linux' -or
            @($interfaces | Where-Object { $_.id -ieq $nicId }).Count -ne 1 -or
            $ipConfigurations.Count -eq 0 -or $wrongNetwork.Count -gt 0) {
            Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $vmId 'Observed Linux VM/NIC attachments must bind the approved executing runner to its private subnet without a public NIC IP.'
        }
    }
}

function Add-RunnerAzureChecks {
    param($Context, [AllowEmptyCollection()][object[]]$Runners = @())
    $p = $Context.Profile
    $runner = $p.github.runner
    $input = $Context.Inputs.runner
    if ($runner.mode -ceq 'existing-private') { Add-RunnerMachineChecks $Context $Runners }
    $subnet = (Read-BootstrapResource $Context 'Azure' "$($runner.subnetResourceId)?api-version=2024-05-01").body
    $prefixes = @((Get-Field $subnet.properties 'addressPrefixes' @())) + @((Get-Field $subnet.properties 'addressPrefix' ''))
    if ($subnet.id -ine $runner.subnetResourceId -or $prefixes -notcontains $p.network.runnerSubnetPrefix -or
        (Get-Field (Get-Field $subnet.properties 'networkSecurityGroup' @{}) 'id' '') -ine $input.nsgResourceId) {
        Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $runner.subnetResourceId 'Runner subnet prefix and associated NSG must match the approved resources.'
    }
    $delegations = @(Get-Field $subnet.properties 'delegations' @())
    if ($runner.mode -eq 'github-hosted-private' -and
        ($delegations.Count -ne 1 -or @($delegations | Where-Object { $_.properties.serviceName -ceq 'GitHub.Network/networkSettings' }).Count -ne 1)) {
        Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $runner.subnetResourceId 'The subnet requires the observed GitHub.Network/networkSettings delegation.'
    }
    if ($runner.mode -eq 'existing-private' -and $delegations.Count -ne 0) {
        Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $runner.subnetResourceId 'A VM-backed existing runner must not share a service-exclusive delegated subnet.'
    }
    $nsg = (Read-BootstrapResource $Context 'Azure' "$($input.nsgResourceId)?api-version=2024-05-01").body
    if ((Get-CanonicalHash $nsg.properties) -cne $input.approvedNsgFingerprint) {
        Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $input.nsgResourceId 'NSG configuration differs from the administrator-approved fingerprint.'
    }
}

function Add-RunnerChecks {
    param($Context, [switch]$GitHubOnly, [string]$CurrentRunnerName = '')
    $p = $Context.Profile
    $input = Get-Field $Context.Inputs 'runner'
    if ($null -eq $input) {
        Add-BootstrapBlocker $Context 'RUNNER_ADMIN_UNVERIFIED' $p.github.runner.group 'Supply exact org-admin, group, selected repository/workflow and approved NSG evidence in platformInputs.runner.'
        return
    }
    $org = $p.github.repository.Split('/')[0]
    if (-not $GitHubOnly) {
        $actor = (Read-BootstrapResource $Context 'GitHub' '/user').body
        $membership = (Read-BootstrapResource $Context 'GitHub' "/orgs/$org/memberships/$($input.adminLogin)").body
        if ($membership.state -cne 'active' -or $membership.role -cne 'admin' -or
            $membership.user.id -ne $input.adminId -or $membership.organization.id -ne $p.github.ownerId -or
            $actor.id -ne $input.adminId -or $actor.login -cne $input.adminLogin) {
            Add-BootstrapBlocker $Context 'RUNNER_ADMIN_UNVERIFIED' $org 'The authenticated runner approver must be the named active administrator of this exact organization, not an unverified third-party attestation.'
        }
    }
    $path = "/orgs/$org/actions/runner-groups/$($input.groupId)"
    $group = (Read-BootstrapResource $Context 'GitHub' $path).body
    $repositories = Read-BootstrapCollection $Context 'GitHub' "$path/repositories" 'repositories'
    $actualIds = @($repositories | ForEach-Object { $_.id } | Sort-Object)
    $expectedIds = @($input.approvedRepositoryIds | Sort-Object)
    if ($group.id -ne $input.groupId -or $group.name -cne $p.github.runner.group -or $group.visibility -cne 'selected' -or
        $actualIds -notcontains $p.github.repositoryId -or -not (Test-DesiredSubset $actualIds $expectedIds)) {
        Add-BootstrapBlocker $Context 'RUNNER_REPOSITORY_RESTRICTION_INVALID' $path 'Require exact selected repository restrictions; do not widen a shared runner group.'
    }
    if ((Get-Field $group 'restricted_to_workflows' $null) -isnot [bool] -or -not $group.restricted_to_workflows -or
        -not (Test-DesiredSubset @($group.selected_workflows) @($input.approvedWorkflowRefs))) {
        Add-BootstrapBlocker $Context 'RUNNER_WORKFLOW_RESTRICTION_INVALID' $path 'Supported selected-workflow restrictions must match the explicitly approved workflow/ref set.'
    }
    $runner = $p.github.runner
    if ($runner.labels -contains 'ubuntu-latest' -or @($runner.labels).Count -eq 0) {
        Add-BootstrapBlocker $Context 'RUNNER_LABELS_INVALID' $path 'A public ubuntu-latest label does not select a private runner.'
    }
    $networkId = [string](Get-Field $runner 'networkConfigurationId' '')
    if ($runner.mode -ceq 'github-hosted-private' -or $networkId) {
        if (-not $networkId -or (Get-Field $group 'network_configuration_id' '') -cne $networkId) {
            Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $path 'An administrator must bind the group to the exact approved hosted-compute network configuration.'
            return
        }
        $configuration = (Read-BootstrapResource $Context 'GitHub' "/orgs/$org/settings/network-configurations/$([uri]::EscapeDataString($networkId))").body
        if ($configuration.id -cne $networkId -or $configuration.compute_service -cne 'actions' -or $configuration.network_settings_ids.Count -ne 1) {
            Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $networkId 'Require the actual Actions network configuration with one verified network settings binding.'
            return
        }
        $settings = (Read-BootstrapResource $Context 'GitHub' "/orgs/$org/settings/network-settings/$($configuration.network_settings_ids[0])").body
        if ($settings.subnet_id -ine $runner.subnetResourceId -or $settings.region -ine $p.azure.location) {
            Add-BootstrapBlocker $Context 'RUNNER_NETWORK_INVALID' $networkId 'Actual network settings subnet and region must match the approved Azure input.'
        }
    }
    if ($runner.mode -ceq 'github-hosted-private') {
        $runners = Read-BootstrapCollection $Context 'GitHub' "$path/hosted-runners" 'runners'
        $ready = @($runners | Where-Object {
            $_.platform -match '^linux' -and $_.status -ceq 'Ready' -and $_.maximum_runners -gt 0 -and
            -not $_.public_ip_enabled -and $runner.labels.Count -eq 1 -and $runner.labels[0] -ceq $_.name
        })
    }
    elseif ($runner.mode -ceq 'existing-private') {
        $runners = Read-BootstrapCollection $Context 'GitHub' "$path/runners" 'runners'
        $ready = @($runners | Where-Object {
            $labels = @($_.labels | ForEach-Object { $_.name })
            $available = if ($CurrentRunnerName) { $_.name -ceq $CurrentRunnerName } else { -not $_.busy }
            $_.os -ceq 'linux' -and $_.status -ceq 'online' -and $available -and
            @($runner.labels | Where-Object { $labels -notcontains $_ }).Count -eq 0
        })
        Add-RunnerMachineChecks $Context $ready -MetadataOnly
    }
    else { Add-BootstrapBlocker $Context 'RUNNER_MODE_UNSUPPORTED' $path 'Only approved existing private Linux groups or GitHub-hosted private larger runners are supported.'; return }
    if ($ready.Count -eq 0) { Add-BootstrapBlocker $Context 'RUNNER_CAPACITY_UNAVAILABLE' $path 'No matching ready Linux capacity is observable; provision it through the runner administrator before queueing private jobs.' }
    if ($GitHubOnly) { return }
    Add-RunnerAzureChecks $Context $ready
}

function Assert-GitHubBootstrapReadiness {
    <#
    .SYNOPSIS
    GitHub-only P5 scheduling/current-runner gate. Returns true or throws.
    .DESCRIPTION
    Reuses the operator validators in observation-only mode. It verifies both
    environments and requires selected repository access plus the exact
    deploy-environment-reusable.yml at the protected ref.
    The caller separately enforces workflow_dispatch, caller repository/ref,
    artifact provenance, and privileged Azure readiness gates.

    The token must read repository environments/ref, organization plan, runner
    groups/repository access/hosted runners, and hosted network settings.
    Missing API permissions or an unavailable protection field fails closed.
    Existing-private requires immutable, administrator-approved PlatformInputs
    containing exact runner ID/name to VM/NIC bindings and NSG fingerprints.
    Only their structure and registered runner identity are checked here.
    Assert-PreparedDeploymentFoundation verifies the actual current runner in
    Azure after OIDC login, before What-If/main. Selection is not Azure proof.
    CurrentRunnerName is explicit and defaults to no override. Select requires
    idle capacity; verified private jobs may name their own approved online
    runner even though that job has made it busy. The parent must derive this
    value from RUNNER_NAME only after its workflow-context guard succeeds.
    Transport is solely an in-memory test seam.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Collections.IDictionary]$PlatformInputs,
        [scriptblock]$Transport,
        [string]$CurrentRunnerName = ''
    )
    Assert-BootstrapProfile -Profile $Profile
    if ($Profile.github.runner.mode -ceq 'existing-private' -and $null -eq $PlatformInputs) {
        throw 'RUNNER_APPROVAL_REQUIRED: existing-private selection requires administrator-approved PlatformInputs from the same immutable configuration commit.'
    }
    $inputs = if ($null -ne $PlatformInputs) { Read-PlatformInputs -Json (ConvertTo-CanonicalJson $PlatformInputs) } else { @{} }
    if (-not $inputs.Contains('github')) { $inputs.github = @{ serverUrl = 'https://github.com'; apiUrl = 'https://api.github.com' } }
    $inner = $Transport
    if ($null -eq $inner) { $inner = New-BootstrapTransport -Azure @{} -GitHub $inputs.github }
    $githubReads = {
        param($Request)
        if ($Request.provider -cne 'GitHub' -or $Request.method -cne 'GET') {
            throw 'GitHub readiness transport forbids Azure access and all API writes.'
        }
        & $inner $Request
    }.GetNewClosure()
    $context = New-PlanContext @{ profile = $Profile } $inputs $githubReads
    $repo = Read-GitHubBootstrapIdentity $context
    if ($null -ne $repo) { Add-EnvironmentPlans $context $repo -AssertExisting }
    if ($context.Blockers.Count -eq 0) {
        $org = $Profile.github.repository.Split('/')[0]
        $groups = Read-BootstrapCollection $context 'GitHub' "/orgs/$org/actions/runner-groups" 'runner_groups'
        $selected = @($groups | Where-Object { $_.name -ceq $Profile.github.runner.group })
        if ($selected.Count -ne 1) {
            Add-BootstrapBlocker $context 'RUNNER_GROUP_UNVERIFIED' $Profile.github.runner.group 'The exact named group must resolve unambiguously in the observed organization.'
        }
        else {
            $expectedWorkflow = "$($Profile.github.repository)/.github/workflows/deploy-environment-reusable.yml@$($Profile.github.protectedRef)"
            if ($null -ne (Get-Field $inputs 'runner')) {
                if ($inputs.runner.groupId -ne $selected[0].id -or
                    -not (Test-DesiredSubset @($inputs.runner.approvedWorkflowRefs) @($expectedWorkflow))) {
                    Add-BootstrapBlocker $context 'RUNNER_APPROVAL_MISMATCH' $Profile.github.runner.group 'The immutable platform approval must bind this group and the exact P5 reusable workflow/ref.'
                }
            }
            else {
                if ($Profile.github.runner.mode -ceq 'existing-private') { throw 'RUNNER_APPROVAL_REQUIRED: platformInputs.runner is required.' }
                $context.Inputs.runner = @{
                    groupId = $selected[0].id
                    approvedRepositoryIds = @($Profile.github.repositoryId)
                    approvedWorkflowRefs = @($expectedWorkflow)
                }
            }
            Add-RunnerChecks $context -GitHubOnly -CurrentRunnerName $CurrentRunnerName
        }
    }
    if ($context.Operations.Count -ne 0) { throw 'The GitHub select gate must not produce mutation operations.' }
    if ($context.Blockers.Count -gt 0) {
        $details = @($context.Blockers | ForEach-Object { "$($_.code): $($_.target) -- $($_.requirement)" }) -join '; '
        throw "GitHub bootstrap readiness failed. $details"
    }
    return $true
}

function Add-RoleAssignmentPlan {
    param($Context, [string]$Kind, [string]$Scope, [string]$PrincipalId, [string]$PrincipalType, [string]$RoleId, [string]$Condition = '')
    $assignments = Read-BootstrapCollection $Context 'Azure' "${Scope}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" 'value'
    $description = "Managed by ailz-bootstrap; owner=$(Get-OwnerValue $Context)"
    $properties = @{ principalId = $PrincipalId; principalType = $PrincipalType; roleDefinitionId = $RoleId; description = $description }
    if ($Condition) { $properties.condition = $Condition; $properties.conditionVersion = '2.0' }
    $sameGrant = @($assignments | Where-Object {
        $_.properties.principalId -ieq $PrincipalId -and $_.properties.roleDefinitionId -ieq $RoleId -and
        (Get-Field $_.properties 'scope' $Scope) -ieq $Scope
    })
    if ($sameGrant.Count -gt 1) { Add-BootstrapBlocker $Context 'DUPLICATE_ROLE_ASSIGNMENT' $Scope 'Multiple equivalent principal/role grants need administrator reconciliation.'; return }
    if ($sameGrant.Count -eq 1) {
        $existingCondition = [string](Get-Field $sameGrant[0].properties 'condition' '')
        if ($existingCondition -ceq $Condition) { return }
        Add-BootstrapBlocker $Context 'ROLE_CONDITION_CONFLICT' $sameGrant[0].id 'An existing grant has a different or unbounded condition; do not add a second grant or overwrite it.'
        return
    }
    $name = Get-BootstrapGuid "$Scope|$PrincipalId|$RoleId"
    Add-ArmOperation $Context $Kind "$Scope/providers/Microsoft.Authorization/roleAssignments/$name" '2022-04-01' @{ properties = $properties } $Scope 'Microsoft.Authorization/roleAssignments/write'
}

function Add-AccessPlans {
    param($Context)
    $p = $Context.Profile
    $access = Get-Field $Context.Inputs 'access'
    if ($null -eq $access) { Add-BootstrapBlocker $Context 'DEPLOYMENT_ROLE_ALLOWLIST_REQUIRED' 'platformInputs.access' 'Supply the exact role names the accelerator may assign, using constants/roles.json.'; return }
    if ($p.identities.preview.principalId -ieq $p.identities.deploy.principalId -or
        $p.identities.preview.resourceId -ieq $p.identities.deploy.resourceId -or
        $p.identities.workload.principalId -in @($p.identities.preview.principalId, $p.identities.deploy.principalId)) {
        Add-BootstrapBlocker $Context 'IDENTITIES_NOT_SEPARATE' $p.environment 'Privileged preview/deployment identities must be separate from each other and the governed workload.'
        return
    }
    foreach ($purpose in 'preview', 'deploy') { $null = Read-BootstrapIdentity $Context $purpose }
    $null = Read-BootstrapIdentity $Context 'workload'
    $registry = Read-BootstrapRegistry $Context
    $scope = "/subscriptions/$($p.azure.subscriptionId)/resourceGroups/$($p.azure.resourceGroup)"
    $definitionRoot = "/subscriptions/$($p.azure.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions"
    $previewRoleId = "$definitionRoot/$(Get-BootstrapGuid "$(Get-OwnerValue $Context)|$scope|preview")"
    $previewBody = @{ properties = @{
        roleName = Get-BootstrapName $Context 'preview' $scope
        description = "Managed by ailz-bootstrap; owner=$(Get-OwnerValue $Context)"
        type = 'CustomRole'; assignableScopes = @($scope)
        permissions = @(@{
            actions = @('*/read', 'Microsoft.Resources/deployments/whatIf/action', 'Microsoft.Resources/deployments/validate/action')
            notActions = @(); dataActions = @(); notDataActions = @()
        })
    }}
    Add-ArmOperation $Context 'previewRole' $previewRoleId '2022-04-01' $previewBody $scope 'Microsoft.Authorization/roleDefinitions/write'
    Add-RoleAssignmentPlan $Context 'previewRoleAssignment' $scope $p.identities.preview.principalId 'ServicePrincipal' $previewRoleId
    Add-RoleAssignmentPlan $Context 'deploymentRoleAssignment' $scope $p.identities.deploy.principalId 'ServicePrincipal' "$definitionRoot/$($script:Roles.Contributor.guid)"
    $allowed = [Collections.Generic.List[string]]::new()
    foreach ($name in $access.deploymentRoleNames) {
        if (-not $script:Roles.ContainsKey($name) -or $name -in @('Owner', 'UserAccessAdministrator', 'RoleBasedAccessControlAdministrator')) {
            Add-BootstrapBlocker $Context 'DEPLOYMENT_ROLE_ALLOWLIST_INVALID' $name 'Only reviewed non-access-administrator role definitions from constants/roles.json may be delegated.'
            continue
        }
        $allowed.Add($script:Roles[$name].guid)
    }
    if ($allowed.Count -ne $access.deploymentRoleNames.Count) { return }
    $ids = @($allowed.ToArray() | Sort-Object -Unique) -join ', '
    $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ids} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ids} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))"
    Add-RoleAssignmentPlan $Context 'deploymentRoleDelegation' $scope $p.identities.deploy.principalId 'ServicePrincipal' "$definitionRoot/$($script:Roles.RoleBasedAccessControlAdministrator.guid)" $condition
    $registrySubscription = ($registry.id -split '/')[2]
    $registryRoleId = "/subscriptions/$registrySubscription/providers/Microsoft.Authorization/roleDefinitions/$($script:Roles.AcrPull.guid)"
    Add-RoleAssignmentPlan $Context 'workloadRegistryPullAssignment' $registry.id $p.identities.workload.principalId 'ServicePrincipal' $registryRoleId
    $deploymentRegistryRoleId = "/subscriptions/$registrySubscription/providers/Microsoft.Authorization/roleDefinitions/$($script:Roles.AcrPush.guid)"
    Add-RoleAssignmentPlan $Context 'deploymentRegistryPushAssignment' $registry.id $p.identities.deploy.principalId 'ServicePrincipal' $deploymentRegistryRoleId
}

function Read-BootstrapRegistry {
    param($Context)
    $id = $Context.Profile.application.registryResourceId
    Assert-ResourceBinding $id 'Microsoft\.ContainerRegistry/registries/[^/]+'
    $registry = (Read-BootstrapResource $Context 'Azure' "${id}?api-version=2025-04-01").body
    $expectedLogin = "$(($id -split '/')[-1]).azurecr.io"
    $properties = $registry.properties
    $armPolicy = Get-Field (Get-Field $properties 'policies' @{}) 'azureADAuthenticationAsArmPolicy' @{}
    if ($registry.id -ine $id -or $properties.loginServer -ine $expectedLogin -or
        $properties.publicNetworkAccess -cne 'Disabled' -or
        (Get-Field $properties 'adminUserEnabled' $null) -isnot [bool] -or $properties.adminUserEnabled -or
        (Get-Field $properties 'roleAssignmentMode' '') -cne 'LegacyRegistryPermissions' -or
        (Get-Field $armPolicy 'status' '') -cne 'enabled') {
        throw 'The existing private registry must have its exact login server, public/admin access disabled, LegacyRegistryPermissions for AcrPull, and ARM-audience authentication enabled. No registry setting is changed automatically.'
    }
    return $registry
}

function Assert-RegistryAccessRole {
    param($Context, [string]$RegistryId, [ValidateSet('workload', 'deploy')][string]$Purpose, [ValidateSet('AcrPull', 'AcrPush')][string]$RoleName)
    $assignments = Read-BootstrapCollection $Context 'Azure' "${RegistryId}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" 'value'
    $matching = @($assignments | Where-Object {
        $_.properties.principalId -ieq $Context.Profile.identities[$Purpose].principalId -and
        ($_.properties.roleDefinitionId -split '/')[-1] -ieq $script:Roles[$RoleName].guid -and
        (Get-Field $_.properties 'scope' $RegistryId) -ieq $RegistryId -and
        -not (Get-Field $_.properties 'condition' '')
    })
    if ($matching.Count -ne 1) { throw "The $Purpose identity requires one verified, registry-scoped $RoleName grant before image import/main. Run the separately approved Access bootstrap stage first." }
}

function Assert-WorkloadRegistryPull {
    param($Context, [string]$RegistryId)
    Assert-RegistryAccessRole $Context $RegistryId 'workload' 'AcrPull'
}

function Assert-DeploymentRegistryPush {
    param($Context, [string]$RegistryId)
    Assert-RegistryAccessRole $Context $RegistryId 'deploy' 'AcrPush'
}

function Assert-PreparedSpokeSelection {
    param($Profile)
    $p = $Profile.parameters
    if ((Get-Field $p 'useExistingVNet' $null) -isnot [bool] -or -not $p.useExistingVNet -or
        (Get-Field $p 'deploySubnets' $null) -isnot [bool] -or $p.deploySubnets -or
        (Get-Field $p 'hubIntegrationCreateHubPeering' $null) -isnot [bool] -or $p.hubIntegrationCreateHubPeering -or
        -not (Get-Field $p 'networkIsolation' $false)) {
        throw 'The first-deployment contract requires a prepared spoke: useExistingVNet=true, deploySubnets=false, hubIntegrationCreateHubPeering=false, and networkIsolation=true. Main must not bootstrap its own image-pull network.'
    }
    Assert-ResourceBinding $p.existingVnetResourceId 'Microsoft\.Network/virtualNetworks/[^/]+'
    Assert-ResourceBinding $p.hubIntegrationHubVnetResourceId 'Microsoft\.Network/virtualNetworks/[^/]+'
    Assert-ResourceBinding $p.hubIntegrationExistingRouteTableResourceId 'Microsoft\.Network/routeTables/[^/]+'
    if ($p.Contains('hubIntegrationEgressNextHopIp')) { throw 'Prepared profiles must select only the existing route-table mechanism; expected next-hop verification belongs in PlatformInputs.network.egress.expectedNextHopIp.' }
}

function Invoke-PrivateRegistryProbe {
    param([string]$Hostname, [string[]]$ExpectedAddresses)
    $lookup = [Net.Dns]::GetHostAddressesAsync($Hostname)
    if (-not $lookup.Wait(10000)) { throw 'Private registry DNS resolution timed out.' }
    $addresses = @($lookup.GetAwaiter().GetResult() | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
    if ($addresses.Count -eq 0 -or @($addresses | Where-Object { $_ -notin $ExpectedAddresses }).Count -gt 0) {
        throw 'Registry DNS did not resolve exclusively to the observed private endpoint addresses.'
    }
    foreach ($address in $addresses) {
        $client = [Net.Sockets.TcpClient]::new()
        $tls = $null
        try {
            $connect = $client.ConnectAsync([Net.IPAddress]::Parse($address), 443)
            if (-not $connect.Wait(10000)) { throw 'Private registry TCP connection timed out.' }
            $null = $connect.GetAwaiter().GetResult()
            $tls = [Net.Security.SslStream]::new($client.GetStream(), $false)
            $handshake = $tls.AuthenticateAsClientAsync($Hostname)
            if (-not $handshake.Wait(10000)) { throw 'Private registry TLS handshake timed out.' }
            $null = $handshake.GetAwaiter().GetResult()
            if (-not $tls.IsAuthenticated -or -not $tls.IsEncrypted) { throw 'Private registry TLS was not authenticated.' }
        }
        finally {
            if ($null -ne $tls) { $tls.Dispose() }
            $client.Dispose()
        }
    }
    return @{ addresses = $addresses; tls = $true }
}

function Assert-PreparedDeploymentFoundation {
    <#
    .SYNOPSIS
    Read-only pre-main gate for an existing prepared spoke and private ACR pull.
    .DESCRIPTION
    Run from the approved private runner before preview/main, after separately
    approved platform preparation. No image is imported or pulled, no resource
    is created, and no .azure state is read. The profile must reuse the prepared
    VNet and must not ask main to create/update its subnets or hub peering.

    Requires read access to the exact VNet, subnets, route table, hub peerings,
    ACR zone/links, registry/approved endpoints/NICs, workload UAI and registry
    role assignments. Missing cross-resource-group read access is a named
    operator dependency, not a reason to grant subscription-wide access.
    PlatformInputs.network must match the immutable profile and include
    preparedSubnetNsgs for ACA and PE subnet IDs, NSG IDs and approved property
    fingerprints. Retrieve both files from the approved configuration commit;
    never manufacture approved fingerprints from the state under inspection.
    For existing-private, RUNNER_NAME selects exactly one approved
    runner.machineBindings entry (runnerId, runnerName, virtualMachineResourceId,
    networkInterfaceResourceId). Azure verifies that executing runner's Linux
    VM/NIC/subnet and approved NSG before any What-If/main call. The GitHub-only
    select gate checks structure/scheduling only; its success is not this proof.
    CurrentRunnerName is an isolated-test seam; P5 uses the runner-provided
    RUNNER_NAME rather than a profile override.

    DNS and certificate-validated TLS probes cover every advertised login/data
    endpoint using its observed private IPs. This proves prerequisites from the
    runner, not eventual RBAC propagation or ACA-managed image-pull success.
    Both workload AcrPull and deployment AcrPush must already exist at the
    private registry; post-main completion cannot first prepare import access.
    A missing image/provider-preflight failure still requires an explicitly
    approved pre-import exception; this gate never imports an image.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][Collections.IDictionary]$PlatformInputs,
        [string]$CurrentRunnerName = $env:RUNNER_NAME,
        [scriptblock]$Transport,
        [scriptblock]$NetworkProbe = ${function:Invoke-PrivateRegistryProbe}
    )
    Assert-BootstrapProfile -Profile $Profile
    Assert-PreparedSpokeSelection $Profile
    $inputs = Read-PlatformInputs -Json (ConvertTo-CanonicalJson $PlatformInputs)
    $inner = $Transport
    if ($null -eq $inner) { $inner = New-BootstrapTransport -Azure $Profile.azure -GitHub @{} }
    $reads = {
        param($Request)
        if ($Request.provider -cne 'Azure' -or $Request.method -cne 'GET') { throw 'Prepared-foundation verification permits only Azure reads.' }
        & $inner $Request
    }.GetNewClosure()
    $context = New-PlanContext @{ profile = $Profile } $inputs $reads
    $executing = @()
    if ($Profile.github.runner.mode -ceq 'existing-private') {
        $bindings = @(Get-Field (Get-Field $inputs 'runner' @{}) 'machineBindings' @())
        $current = @($bindings | Where-Object { $_.runnerName -ceq $CurrentRunnerName })
        if ([string]::IsNullOrWhiteSpace($CurrentRunnerName) -or $current.Count -ne 1) {
            throw 'The current runner (RUNNER_NAME) must have one exact approved machine binding before Azure foundation verification.'
        }
        $executing = @(@{ id = $current[0].runnerId; name = $CurrentRunnerName })
    }
    Add-RunnerAzureChecks $context $executing
    if ($context.Blockers.Count -gt 0) {
        $details = @($context.Blockers | ForEach-Object { "$($_.code): $($_.target)" }) -join '; '
        throw "Executing runner Azure verification failed before What-If/main: $details"
    }
    Add-NetworkPlans $context
    if ($context.Blockers.Count -gt 0 -or $context.Operations.Count -gt 0) {
        $details = @($context.Blockers | ForEach-Object { "$($_.code): $($_.target)" }) +
            @($context.Operations | ForEach-Object { "$($_.kind): $($_.path)" })
        throw "Prepared network dependencies are incomplete before main: $($details -join '; '). Apply a separately inspected and approved Network preparation plan first."
    }
    $approvedNsgs = @(Get-Field $inputs.network 'preparedSubnetNsgs' @())
    $p = $Profile.parameters
    $spoke = $p.existingVnetResourceId
    $hub = $p.hubIntegrationHubVnetResourceId
    $vnet = (Read-BootstrapResource $context 'Azure' "${spoke}?api-version=2024-05-01").body
    if ($vnet.id -ine $spoke) { throw 'The prepared spoke resource binding changed.' }
    foreach ($stem in 'acaEnvironment', 'pe') {
        $name = [string](Get-Field $p "${stem}SubnetName" '')
        if ($name -notmatch '^[A-Za-z0-9_.-]+$') { throw "An explicit prepared $stem subnet name is required." }
        $id = "$spoke/subnets/$name"
        $subnet = (Read-BootstrapResource $context 'Azure' "${id}?api-version=2024-05-01").body
        $prefixes = @(Get-Field $subnet.properties 'addressPrefixes' @()) + @(Get-Field $subnet.properties 'addressPrefix' '')
        if ($subnet.id -ine $id -or $prefixes -notcontains $p["${stem}SubnetPrefix"] -or
            -not (Get-Field (Get-Field $subnet.properties 'networkSecurityGroup' @{}) 'id' '')) {
            throw "Prepared $stem subnet prefix/NSG does not match the typed profile."
        }
        $binding = @($approvedNsgs | Where-Object { $_.subnetResourceId -ieq $id })
        if ($binding.Count -ne 1 -or $binding[0].nsgResourceId -ine $subnet.properties.networkSecurityGroup.id) {
            throw "Prepared $stem subnet requires one administrator-approved NSG binding/fingerprint."
        }
        $nsg = (Read-BootstrapResource $context 'Azure' "$($binding[0].nsgResourceId)?api-version=2024-05-01").body
        if ($nsg.id -ine $binding[0].nsgResourceId -or (Get-CanonicalHash $nsg.properties) -cne $binding[0].approvedNsgFingerprint) {
            throw "Prepared $stem subnet NSG differs from the approved configuration."
        }
        if ($stem -eq 'acaEnvironment') {
            $delegations = @(Get-Field $subnet.properties 'delegations' @())
            if ($delegations.Count -ne 1 -or $delegations[0].properties.serviceName -cne 'Microsoft.App/environments' -or
                (Get-Field (Get-Field $subnet.properties 'routeTable' @{}) 'id' '') -ine $p.hubIntegrationExistingRouteTableResourceId) {
                throw 'The prepared ACA subnet requires its service delegation and the approved egress route table before main.'
            }
        }
    }
    $routes = (Read-BootstrapResource $context 'Azure' "$($p.hubIntegrationExistingRouteTableResourceId)?api-version=2024-05-01").body
    $default = @($routes.properties.routes | Where-Object { $_.properties.addressPrefix -ceq '0.0.0.0/0' })
    if ($default.Count -ne 1 -or $default[0].properties.nextHopType -cne 'VirtualAppliance' -or
        $default[0].properties.nextHopIpAddress -cne $inputs.network.egress.expectedNextHopIp) { throw 'The prepared egress route must already point to the approved hub appliance.' }
    foreach ($direction in @(@{ local = $spoke; remote = $hub }, @{ local = $hub; remote = $spoke })) {
        $peerings = Read-BootstrapCollection $context 'Azure' "$($direction.local)/virtualNetworkPeerings?api-version=2024-05-01" 'value'
        $match = @($peerings | Where-Object { $_.properties.remoteVirtualNetwork.id -ieq $direction.remote })
        if ($match.Count -ne 1 -or $match[0].properties.peeringState -cne 'Connected' -or
            -not $match[0].properties.allowVirtualNetworkAccess -or -not $match[0].properties.allowForwardedTraffic) {
            throw 'Both hub/spoke peering directions and forwarded traffic must be connected before main; post-provision peering completion is too late.'
        }
    }
    $zone = [string](Get-Field $p 'existingPrivateDnsZoneAcrResourceId' '')
    Assert-ResourceBinding $zone 'Microsoft\.Network/privateDnsZones/privatelink\.azurecr\.io'
    $null = Read-BootstrapResource $context 'Azure' "${zone}?api-version=2024-06-01"
    $links = Read-BootstrapCollection $context 'Azure' "$zone/virtualNetworkLinks?api-version=2024-06-01" 'value'
    foreach ($network in @($spoke, $hub)) {
        $link = @($links | Where-Object { $_.properties.virtualNetwork.id -ieq $network })
        if ($link.Count -ne 1 -or $link[0].properties.registrationEnabled -or
            $link[0].properties.virtualNetworkLinkState -cne 'Completed' -or $link[0].properties.provisioningState -cne 'Succeeded') {
            throw 'ACR private DNS links to the prepared spoke and hub resolver network must already be complete with registration disabled.'
        }
    }
    $null = Read-BootstrapIdentity $context 'workload'
    $null = Read-BootstrapIdentity $context 'deploy'
    $registry = Read-BootstrapRegistry $context
    Assert-WorkloadRegistryPull $context $registry.id
    Assert-DeploymentRegistryPush $context $registry.id
    $dataHosts = @(Get-Field $registry.properties 'dataEndpointHostNames' @())
    if ($dataHosts.Count -eq 0) { throw 'Private registry data endpoint names are unavailable; image-pull networking cannot be verified.' }
    $hosts = @(@($registry.properties.loginServer) + $dataHosts | Sort-Object -Unique)
    $dns = @{}
    $connections = @((Get-Field $registry.properties 'privateEndpointConnections' @()) | Where-Object { $_.properties.privateLinkServiceConnectionState.status -ceq 'Approved' })
    if ($connections.Count -eq 0) { throw 'The registry requires an approved private endpoint before main.' }
    foreach ($connection in $connections) {
        $id = $connection.properties.privateEndpoint.id
        Assert-ResourceBinding $id 'Microsoft\.Network/privateEndpoints/[^/]+'
        $endpoint = (Read-BootstrapResource $context 'Azure' "${id}?api-version=2024-05-01").body
        $endpointSubnet = [string](Get-Field (Get-Field $endpoint.properties 'subnet' @{}) 'id' '')
        if ($endpoint.properties.provisioningState -cne 'Succeeded' -or
            (-not $endpointSubnet.StartsWith("$spoke/subnets/", [StringComparison]::OrdinalIgnoreCase) -and
             -not $endpointSubnet.StartsWith("$hub/subnets/", [StringComparison]::OrdinalIgnoreCase))) { continue }
        foreach ($entry in @(Get-Field $endpoint.properties 'customDnsConfigs' @())) {
            if ($entry.fqdn -in $hosts) { $dns[$entry.fqdn] = @($entry.ipAddresses) }
        }
        foreach ($nicReference in @(Get-Field $endpoint.properties 'networkInterfaces' @())) {
            $nic = (Read-BootstrapResource $context 'Azure' "$($nicReference.id)?api-version=2024-05-01").body
            foreach ($configuration in @(Get-Field $nic.properties 'ipConfigurations' @())) {
                $linkProperties = Get-Field $configuration.properties 'privateLinkConnectionProperties' @{}
                foreach ($hostname in @(Get-Field $linkProperties 'fqdns' @())) {
                    if ($hostname -in $hosts) {
                        $previous = if ($dns.ContainsKey($hostname)) { @($dns[$hostname]) } else { @() }
                        $dns[$hostname] = @($previous + @($configuration.properties.privateIPAddress) | Sort-Object -Unique)
                    }
                }
            }
        }
    }
    foreach ($hostname in $hosts) {
        if ($hostname -notmatch '^[a-z0-9][a-z0-9.-]*\.azurecr\.io$' -or -not $dns.ContainsKey($hostname) -or $dns[$hostname].Count -eq 0) {
            throw 'Every ACR login/data hostname must map to an approved private endpoint IP before main.'
        }
        $probe = & $NetworkProbe $hostname @($dns[$hostname])
        $resolved = @(Get-Field $probe 'addresses' @())
        if ($resolved.Count -eq 0 -or @($resolved | Where-Object { $_ -notin $dns[$hostname] }).Count -gt 0 -or
            (Get-Field $probe 'tls' $false) -ne $true) { throw 'ACR DNS/private endpoint or TLS connectivity verification failed before main.' }
    }
    return $true
}

function Assert-ResourceBinding {
    param([string]$Id, [string]$Type, [string]$Scope = '')
    $pattern = '^/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[A-Za-z0-9_().-]+/providers/' + $Type + '$'
    if ($Id -notmatch $pattern -or $Id -match '(^|/)\.\.?(/|$)' -or
        ($Scope -and -not $Id.StartsWith("$Scope/providers/", [StringComparison]::OrdinalIgnoreCase))) {
        throw "Resource binding is outside the approved scope/type: $Id"
    }
}

function Add-NetworkPlans {
    param($Context)
    $p = $Context.Profile
    $network = Get-Field $Context.Inputs 'network'
    if ($null -eq $network) {
        Add-BootstrapBlocker $Context 'NETWORK_INPUT_REQUIRED' 'platformInputs.network' 'Supply the actual spoke VNet, forwarded-traffic decision, route table and resolver evidence. Do not invent a generated VNet ID before infrastructure exists.'
        return
    }
    $hubId = [string](Get-Field $p.parameters 'hubIntegrationHubVnetResourceId' '')
    $spokeId = $network.spokeVnetResourceId
    Assert-PreparedSpokeSelection $p
    if ($spokeId -ine $p.parameters.existingVnetResourceId -or $network.egress.routeTableResourceId -ine $p.parameters.hubIntegrationExistingRouteTableResourceId) {
        throw 'Prepared spoke/route bindings in PlatformInputs must match the exact reused resources in the P1 profile.'
    }
    Assert-ResourceBinding $hubId 'Microsoft\.Network/virtualNetworks/[^/]+'
    Assert-ResourceBinding $spokeId 'Microsoft\.Network/virtualNetworks/[^/]+'
    if ($hubId -ieq $spokeId) { throw 'Hub and spoke resource bindings must differ.' }
    $hub = (Read-BootstrapResource $Context 'Azure' "${hubId}?api-version=2024-05-01").body
    $spoke = (Read-BootstrapResource $Context 'Azure' "${spokeId}?api-version=2024-05-01").body
    if ($hub.id -ine $hubId -or $spoke.id -ine $spokeId -or
        -not (Test-DesiredSubset @($hub.properties.addressSpace.addressPrefixes) @($p.network.hubAddressPrefixes))) {
        Add-BootstrapBlocker $Context 'NETWORK_BINDING_INVALID' $hubId 'Observed hub/spoke IDs and approved hub address space must match.'
    }
    $egress = $network.egress
    Assert-ResourceBinding $egress.routeTableResourceId 'Microsoft\.Network/routeTables/[^/]+'
    Assert-ResourceBinding $egress.dnsResolverResourceId 'Microsoft\.Network/dnsResolvers/[^/]+'
    $routeTable = (Read-BootstrapResource $Context 'Azure' "$($egress.routeTableResourceId)?api-version=2024-05-01").body
    $defaults = @($routeTable.properties.routes | Where-Object { $_.properties.addressPrefix -ceq '0.0.0.0/0' })
    $nextHop = $egress.expectedNextHopIp
    foreach ($subnetId in $egress.subnetResourceIds) {
        Assert-ResourceBinding $subnetId 'Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+'
        if (-not $subnetId.StartsWith("$spokeId/subnets/", [StringComparison]::OrdinalIgnoreCase) -and $subnetId -ine $p.github.runner.subnetResourceId) {
            throw 'Egress subnet binding must target this spoke or the explicitly approved runner subnet.'
        }
        $subnet = (Read-BootstrapResource $Context 'Azure' "${subnetId}?api-version=2024-05-01").body
        if ($subnet.id -ine $subnetId -or (Get-Field (Get-Field $subnet.properties 'routeTable' @{}) 'id' '') -ine $egress.routeTableResourceId) {
            Add-BootstrapBlocker $Context 'EGRESS_INVALID' $subnetId 'Every declared egress subnet must actually reference the approved route table.'
        }
    }
    if (-not $nextHop -or $defaults.Count -ne 1 -or $defaults[0].properties.nextHopType -cne 'VirtualAppliance' -or
        $defaults[0].properties.nextHopIpAddress -cne $nextHop) {
        Add-BootstrapBlocker $Context 'EGRESS_INVALID' $egress.routeTableResourceId 'Require the approved 0/0 VirtualAppliance next hop and an actual spoke subnet association; routing is not changed automatically.'
    }
    $forward = Read-BootstrapCollection $Context 'Azure' "$spokeId/virtualNetworkPeerings?api-version=2024-05-01" 'value'
    $toHub = @($forward | Where-Object { $_.properties.remoteVirtualNetwork.id -ieq $hubId })
    if ($toHub.Count -ne 1 -or -not $toHub[0].properties.allowVirtualNetworkAccess -or $toHub[0].properties.allowForwardedTraffic -ne $network.allowForwardedTraffic) {
        Add-BootstrapBlocker $Context 'SPOKE_PEERING_REQUIRED' $spokeId 'An administrator must prepare the matching spoke-to-hub peering before CD. Do not wait for full main provisioning to establish the private image-pull network.'
    }
    $resolver = (Read-BootstrapResource $Context 'Azure' "$($egress.dnsResolverResourceId)?api-version=2022-07-01").body
    if ((Get-CanonicalHash $resolver.properties) -cne $egress.approvedResolverFingerprint -or
        -not (Test-DesiredSubset @((Get-Field (Get-Field $spoke.properties 'dhcpOptions' @{}) 'dnsServers' @())) @($egress.expectedDnsServers))) {
        Add-BootstrapBlocker $Context 'DNS_RESOLVER_INVALID' $egress.dnsResolverResourceId 'Observed resolver configuration and spoke DHCP DNS servers must match the administrator-approved input.'
    }
    $peerings = Read-BootstrapCollection $Context 'Azure' "$hubId/virtualNetworkPeerings?api-version=2024-05-01" 'value'
    $sameRemote = @($peerings | Where-Object { $_.properties.remoteVirtualNetwork.id -ieq $spokeId })
    $peeringId = "$hubId/virtualNetworkPeerings/$(Get-BootstrapName $Context 'reverse' $spokeId)"
    $peeringBody = @{ properties = @{
        remoteVirtualNetwork = @{ id = $spokeId }
        allowVirtualNetworkAccess = $true; allowForwardedTraffic = $network.allowForwardedTraffic
        allowGatewayTransit = $false; useRemoteGateways = $false
    }}
    if ($sameRemote.Count -gt 1) {
        Add-BootstrapBlocker $Context 'PEERING_CONFLICT' $hubId 'More than one peering targets the approved spoke; no duplicate is created.'
    }
    elseif ($sameRemote.Count -eq 1 -and $sameRemote[0].id -ine $peeringId -and -not (Test-DesiredSubset $sameRemote[0] $peeringBody)) {
        Add-BootstrapBlocker $Context 'PEERING_CONFLICT' $sameRemote[0].id 'A foreign-named peering has different forwarding/gateway settings. Its administrator must reconcile it.'
    }
    elseif ($sameRemote.Count -eq 0 -or -not (Test-DesiredSubset $sameRemote[0] $peeringBody)) {
        Add-ArmOperation $Context 'reversePeering' $peeringId '2024-05-01' $peeringBody $hubId 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write'
    }
    $zoneIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $p.parameters.Keys) {
        $value = $p.parameters[$key]
        if ($key -match '^existingPrivateDnsZone' -and $value -is [string] -and $value -match '/providers/Microsoft.Network/privateDnsZones/') { $null = $zoneIds.Add($value) }
    }
    foreach ($id in @(Get-Field $network 'privateDnsZoneResourceIds' @())) { $null = $zoneIds.Add($id) }
    if ($zoneIds.Count -eq 0) {
        Add-BootstrapBlocker $Context 'BYO_DNS_INPUT_REQUIRED' 'Private DNS zones' 'Supply the actual existing private DNS zone IDs. This stage never creates competing zones.'
    }
    foreach ($zoneId in @($zoneIds | Sort-Object)) {
        Assert-ResourceBinding $zoneId 'Microsoft\.Network/privateDnsZones/[^/]+'
        $null = Read-BootstrapResource $Context 'Azure' "${zoneId}?api-version=2024-06-01"
        $links = Read-BootstrapCollection $Context 'Azure' "$zoneId/virtualNetworkLinks?api-version=2024-06-01" 'value'
        $existing = @($links | Where-Object { $_.properties.virtualNetwork.id -ieq $spokeId })
        $linkId = "$zoneId/virtualNetworkLinks/$(Get-BootstrapName $Context 'spoke' $spokeId)"
        $properties = @{ registrationEnabled = $false; virtualNetwork = @{ id = $spokeId } }
        if ($existing.Count -gt 1) { Add-BootstrapBlocker $Context 'DNS_LINK_CONFLICT' $zoneId 'Multiple links to this spoke require administrator reconciliation.'; continue }
        if ($existing.Count -eq 1 -and (Test-DesiredSubset $existing[0].properties $properties)) { continue }
        if ($existing.Count -eq 1 -and $existing[0].id -ine $linkId) {
            Add-BootstrapBlocker $Context 'DNS_LINK_CONFLICT' $existing[0].id 'A foreign-named link has incompatible registration settings; do not create another link or overwrite it.'
            continue
        }
        $body = @{ location = 'global'; properties = $properties; tags = @{ 'ailz-bootstrap-owner' = Get-OwnerValue $Context } }
        Add-ArmOperation $Context 'dnsLink' $linkId '2024-06-01' $body $zoneId 'Microsoft.Network/privateDnsZones/virtualNetworkLinks/write'
    }
}

function Add-CompletionPlans {
    param($Context, [AllowNull()]$Completion)
    $p = $Context.Profile
    if ($null -eq $Completion) {
        Add-BootstrapBlocker $Context 'COMPLETION_OUTPUT_REQUIRED' 'DEVELOPER_COMPLETION' 'Run the explicit completion stage using actual infrastructure output. First bootstrap cannot complete backend-resource RBAC before those resources exist.'
        return
    }
    if ($Completion.schemaVersion -ne 1 -or $Completion.environment -cne $p.environment -or
        $Completion.tenantId -ine $p.azure.tenantId -or $Completion.subscriptionId -ine $p.azure.subscriptionId -or
        $Completion.resourceGroup -ine $p.azure.resourceGroup -or
        (Get-CanonicalHash $Completion.release) -cne (Get-CanonicalHash $p.release)) {
        throw 'Completion output identity/release binding does not match the approved profile.'
    }
    $scope = "/subscriptions/$($p.azure.subscriptionId)/resourceGroups/$($p.azure.resourceGroup)"
    $configId = $Completion.appConfiguration.resourceId
    $gatewayId = $Completion.gateway.resourceId
    $backendId = $Completion.gateway.backendResourceId
    $registryId = $Completion.registryResourceId
    Assert-ResourceBinding $configId 'Microsoft\.AppConfiguration/configurationStores/[^/]+' $scope
    Assert-ResourceBinding $gatewayId 'Microsoft\.ApiManagement/service/[^/]+' $scope
    Assert-ResourceBinding $backendId 'Microsoft\.CognitiveServices/accounts/[^/]+' $scope
    Assert-ResourceBinding $registryId 'Microsoft\.ContainerRegistry/registries/[^/]+'
    if ($registryId -ine $p.application.registryResourceId -or $Completion.gateway.accessMode -cne 'gateway') {
        throw 'Completion registry/gateway binding differs from the governed profile.'
    }
    $config = (Read-BootstrapResource $Context 'Azure' "${configId}?api-version=2024-05-01").body
    $gateway = (Read-BootstrapResource $Context 'Azure' "${gatewayId}?api-version=2024-05-01").body
    $backend = (Read-BootstrapResource $Context 'Azure' "${backendId}?api-version=2025-06-01").body
    $registry = Read-BootstrapRegistry $Context
    Assert-WorkloadRegistryPull $Context $registryId
    Assert-DeploymentRegistryPush $Context $registryId
    $gatewayRoot = $null
    $rootUrl = [string]$gateway.properties.gatewayUrl
    $rootValid = [uri]::TryCreate($rootUrl, [UriKind]::Absolute, [ref]$gatewayRoot) -and
        $gatewayRoot.Scheme -ceq 'https' -and $gatewayRoot.Port -eq 443 -and
        $gatewayRoot.AbsolutePath -ceq '/' -and -not $gatewayRoot.UserInfo -and
        -not $gatewayRoot.Query -and -not $gatewayRoot.Fragment
    $expectedGatewayId = "$scope/providers/Microsoft.ApiManagement/service/$($p.gateway.name)"
    $expectedEndpoint = $rootUrl.TrimEnd('/') + "/inference/$($p.gateway.workloadKey)/v1/responses"
    $gatewayBindingValid = $rootValid -and $gateway.id -ieq $gatewayId -and
        $gatewayId -ieq $expectedGatewayId -and $Completion.gateway.endpoint -ceq $expectedEndpoint
    if ($config.properties.endpoint -cne $Completion.appConfiguration.endpoint -or
        -not $gatewayBindingValid -or
        $config.properties.publicNetworkAccess -cne 'Disabled' -or $gateway.properties.publicNetworkAccess -cne 'Disabled' -or
        $backend.properties.publicNetworkAccess -cne 'Disabled' -or -not $backend.properties.disableLocalAuth -or
        $registry.properties.publicNetworkAccess -cne 'Disabled' -or $registry.properties.adminUserEnabled) {
        Add-BootstrapBlocker $Context 'COMPLETION_RESOURCE_STATE_INVALID' $scope 'Actual resource bindings, APIM service-root origin plus the exact workload-scoped /inference/<workloadKey>/v1/responses route, private access and disabled local/backend keys must match before resource-bound RBAC.'
    }
    $gatewayIdentity = Get-Field $gateway 'identity' @{}
    $gatewayPrincipal = [string](Get-Field $gatewayIdentity 'principalId' '')
    $guid = [guid]::Empty
    if ((Get-Field $gatewayIdentity 'type' '') -cne 'SystemAssigned' -or
        -not [guid]::TryParseExact($gatewayPrincipal, 'D', [ref]$guid) -or $guid -eq [guid]::Empty -or
        (Get-Field $gatewayIdentity 'tenantId' '') -ine $p.azure.tenantId) {
        Add-BootstrapBlocker $Context 'GATEWAY_IDENTITY_UNVERIFIED' $gatewayId 'This completion contract requires the actual APIM system-assigned backend identity. A user-assigned/multi-identity backend needs an explicit parent-approved contract.'
        return
    }
    $normalPrincipals = @($p.identities.workload.principalId) + @($p.identities.developerObjectIds) + @($p.identities.developerGroupObjectIds)
    if ($gatewayPrincipal -in ($normalPrincipals + @($p.identities.preview.principalId, $p.identities.deploy.principalId))) {
        Add-BootstrapBlocker $Context 'GATEWAY_IDENTITY_NOT_SEPARATE' $gatewayId 'Gateway backend, governed caller and privileged CI identities must be distinct.'
        return
    }
    $backendRole = [string](Get-Field (Get-Field $Context.Inputs 'access' @{}) 'gatewayBackendRoleName' '')
    if (-not $backendRole) {
        Add-BootstrapBlocker $Context 'GATEWAY_ROLE_REQUIRED' 'platformInputs.access.gatewayBackendRoleName' 'Select the reviewed constants/roles.json inference role that matches the gateway backend API; no role is guessed.'
        return
    }
    $existingBackendGrants = Read-BootstrapCollection $Context 'Azure' "${backendId}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" 'value'
    foreach ($assignment in @($existingBackendGrants | Where-Object { $_.properties.principalId -in $normalPrincipals })) {
        $role = (Read-BootstrapResource $Context 'Azure' "$($assignment.properties.roleDefinitionId)?api-version=2022-04-01").body
        foreach ($permission in $role.properties.permissions) {
            if (@(Get-Field $permission 'dataActions' @()).Count -gt 0 -or
                @($permission.actions | Where-Object { $_ -eq '*' -or $_ -match '(?i)(Microsoft.CognitiveServices/.*/(write|action)|Microsoft.Authorization/.*/write)' }).Count -gt 0) {
                Add-BootstrapBlocker $Context 'GOVERNED_BACKEND_BYPASS' $assignment.id 'A governed caller already has backend data-plane or privilege-changing access. Its administrator must remove the bypass under separate approval.'
            }
        }
    }
    $null = Read-BootstrapIdentity $Context 'workload'
    foreach ($application in $Completion.applications) {
        Assert-ResourceBinding $application.resourceId 'Microsoft\.App/containerApps/[^/]+' $scope
        if ($application.identityResourceId -ine $p.identities.workload.resourceId -or $application.principalId -ine $p.identities.workload.principalId) {
            throw 'Completion application identity binding differs from the approved workload identity.'
        }
    }
    $definitionRoot = "/subscriptions/$($p.azure.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions"
    Add-RoleAssignmentPlan $Context 'completionConfigurationWriterAssignment' $configId $p.identities.deploy.principalId 'ServicePrincipal' "$definitionRoot/$($script:Roles.AppConfigurationDataOwner.guid)"
    Add-RoleAssignmentPlan $Context 'workloadConfigurationReaderAssignment' $configId $p.identities.workload.principalId 'ServicePrincipal' "$definitionRoot/$($script:Roles.AppConfigurationDataReader.guid)"
    foreach ($principal in $p.identities.developerObjectIds) {
        Add-RoleAssignmentPlan $Context 'developerConfigurationReaderAssignment' $configId $principal 'User' "$definitionRoot/$($script:Roles.AppConfigurationDataReader.guid)"
    }
    foreach ($principal in $p.identities.developerGroupObjectIds) {
        Add-RoleAssignmentPlan $Context 'developerConfigurationReaderAssignment' $configId $principal 'Group' "$definitionRoot/$($script:Roles.AppConfigurationDataReader.guid)"
    }
    Add-RoleAssignmentPlan $Context 'gatewayInferenceAssignment' $backendId $gatewayPrincipal 'ServicePrincipal' "$definitionRoot/$($script:Roles[$backendRole].guid)"
}

function New-FoundationContext {
    param($Inputs, [scriptblock]$Transport)
    $foundation = Get-Field $Inputs 'foundation'
    if ($null -eq $foundation) { throw 'The foundation stage requires platformInputs.foundation with exact Azure scope and identity names.' }
    if ($null -eq $Transport) { $Transport = New-BootstrapTransport $foundation.azure @{} }
    $resolved = @{ profile = @{ environment = $foundation.environment; azure = $foundation.azure; synthetic = $false } }
    New-PlanContext $resolved $Inputs $Transport
}

function New-BootstrapFoundationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$PlatformInputs, [scriptblock]$Transport)
    $inputs = Read-PlatformInputs -Json (ConvertTo-CanonicalJson $PlatformInputs)
    $context = New-FoundationContext $inputs $Transport
    $foundation = $inputs.foundation
    foreach ($key in 'tenantId', 'subscriptionId') {
        if ([guid]$foundation.azure[$key] -eq [guid]::Empty) { throw "Foundation azure.$key cannot be an empty identifier." }
    }
    $scope = "/subscriptions/$($foundation.azure.subscriptionId)/resourceGroups/$($foundation.azure.resourceGroup)"
    $null = Read-BootstrapResource $context 'Azure' "${scope}?api-version=2022-09-01"
    $names = @($foundation.identityNames.Values)
    if (@($names | Sort-Object -Unique).Count -ne 3) { throw 'Foundation preview, deploy and workload identity names must be distinct.' }
    foreach ($purpose in 'preview', 'deploy', 'workload') {
        $id = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($foundation.identityNames[$purpose])"
        $body = @{
            location = $foundation.azure.location
            tags = @{ 'ailz-bootstrap-owner' = Get-OwnerValue $context; 'ailz-bootstrap-purpose' = $purpose }
        }
        Add-ArmOperation $context 'foundationIdentity' $id '2024-11-30' $body $scope 'Microsoft.ManagedIdentity/userAssignedIdentities/write'
    }
    Test-PlannedPermissions $context
    $plan = @{
        schemaVersion = 1; stage = 'foundation'; environment = $foundation.environment
        configurationHash = Get-CanonicalHash $foundation; platformInputsHash = Get-CanonicalHash $inputs
        synthetic = $false; liveReady = $false; liveGates = @('Use verified foundation output IDs to complete the P1 profile before federation or deployment. No trust or access assignment is created by foundation.')
        status = if ($context.Blockers.Count -gt 0) { 'blocked' } else { 'planned' }
        operations = $context.Operations.ToArray(); observations = $context.Observations.ToArray(); blockers = $context.Blockers.ToArray()
    }
    Assert-BootstrapArtifactSafe -Value $plan
    $plan.planHash = Get-CanonicalHash $plan
    return ,$plan
}

function Get-FoundationOutputs {
    param($Context)
    $f = $Context.Inputs.foundation
    $scope = "/subscriptions/$($f.azure.subscriptionId)/resourceGroups/$($f.azure.resourceGroup)"
    $identities = [ordered]@{}
    foreach ($purpose in 'preview', 'deploy', 'workload') {
        $id = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($f.identityNames[$purpose])"
        $identity = (Read-BootstrapResource $Context 'Azure' "${id}?api-version=2024-11-30").body
        foreach ($key in 'clientId', 'principalId') {
            $value = [guid]::Empty
            if (-not [guid]::TryParseExact([string](Get-Field $identity.properties $key ''), 'D', [ref]$value) -or $value -eq [guid]::Empty) { throw "Foundation $purpose has no verified generated $key yet." }
        }
        if ($identity.properties.tenantId -ine $f.azure.tenantId) { throw "Foundation $purpose identity tenant does not match." }
        $identities[$purpose] = @{ resourceId = $id; clientId = $identity.properties.clientId; principalId = $identity.properties.principalId }
    }
    return @{ schemaVersion = 1; environment = $f.environment; azure = $f.azure; identities = $identities }
}

function Test-PlannedPermissions {
    param($Context)
    foreach ($scope in @($Context.Operations | Where-Object provider -eq 'Azure' | ForEach-Object { $_.scope } | Sort-Object -Unique)) {
        $permissions = Read-BootstrapCollection $Context 'Azure' "${scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" 'value'
        foreach ($operation in @($Context.Operations | Where-Object { $_.provider -eq 'Azure' -and $_.scope -eq $scope })) {
            $allowed = @($permissions | Where-Object {
                $permission = $_
                @($permission.actions | Where-Object { $operation.permission -like $_ }).Count -gt 0 -and
                @($permission.notActions | Where-Object { $operation.permission -like $_ }).Count -eq 0
            }).Count -gt 0
            if (-not $allowed) { Add-BootstrapBlocker $Context 'BOOTSTRAP_PERMISSION_REQUIRED' $operation.path "The bootstrap principal lacks observed $($operation.permission) permission at $scope. Do not elevate a preview/deploy identity to compensate." }
        }
    }
}

function New-BootstrapGovernanceRequest {
    <#
    .SYNOPSIS
    GET-only, date-preserving ARM adapter for the finalized P3 governance APIs.
    .DESCRIPTION
    Returns (method, absoluteUri, body, headers) -> {StatusCode; Body; Headers}.
    Allows only the profile workload RG, its subscription definitions/provider
    catalogs, global versioned built-ins and explicitly configured action groups.
    It never caches reads: P3's second observation must detect concurrent changes.
    Authentication stays in memory. No input/output credentials are logged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Profile, [scriptblock]$Transport)
    $inner = $Transport
    if ($null -eq $inner) { $inner = New-BootstrapTransport -Azure $Profile.azure -GitHub @{} }
    $scope = "/subscriptions/$($Profile.azure.subscriptionId)/resourceGroups/$($Profile.azure.resourceGroup)"
    $subscription = "/subscriptions/$($Profile.azure.subscriptionId)"
    $prefix = [regex]::Escape([string]$Profile.governance.assignmentPrefix)
    $actionGroups = @($Profile.governance.budget.contactGroups)
    return {
        param($Method, $AbsoluteUri, $Body, $Headers)
        $uri = [uri]$AbsoluteUri
        if ($Method -cne 'GET' -or $null -ne $Body -or $Headers -isnot [Collections.IDictionary] -or $Headers.Count -ne 0 -or
            $uri.Scheme -cne 'https' -or $uri.Host -cne 'management.azure.com' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment) {
            throw 'Governance adapter accepts only credential-free GET requests to the approved ARM host.'
        }
        $path = $uri.AbsolutePath
        if ($path.Contains('%') -or $path -match '(^|/)\.\.?(/|$)') { throw 'Governance read contains an ambiguous encoded or relative resource path.' }
        $allowed = $path -ieq $scope -or $path.StartsWith("$scope/providers/", [StringComparison]::OrdinalIgnoreCase) -or
            $path -imatch ('^' + [regex]::Escape($subscription) + '/providers/Microsoft\.Authorization/policyDefinitions/' + $prefix + '-(?:models|skus|private)$') -or
            $path -imatch ('^' + [regex]::Escape($subscription) + '/providers/Microsoft\.[A-Za-z0-9.]+$') -or
            $path -imatch '^/providers/Microsoft\.Authorization/policyDefinitions/[a-f0-9-]{36}/versions/[0-9.]+$' -or
            $path -iin $actionGroups
        if (-not $allowed) { throw 'Governance read is outside the explicitly approved resource/dependency scopes.' }
        $response = & $inner @{ provider = 'Azure'; method = 'GET'; path = $uri.PathAndQuery; body = $null; headers = @{} }
        if ($null -eq $response -or -not $response.Contains('status') -or $response.body -isnot [Collections.IDictionary]) {
            throw 'Governance ARM responses must preserve a JSON object body and explicit status, including real error codes for absence.'
        }
        $responseHeaders = @{}
        $etag = if ($response.Contains('etag')) { [string]$response.etag } else { '' }
        if ($etag) { $responseHeaders.ETag = $etag }
        return @{ StatusCode = [int]$response.status; Body = $response.body; Headers = $responseHeaders }
    }.GetNewClosure()
}

function Get-BootstrapGovernanceSourceHash {
    $files = @((Join-Path $script:Root 'platform\governance.bicep')) +
        @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'platform\policy') -File -Recurse | Where-Object { $_.Extension -in @('.bicep', '.json', '.psm1') } | ForEach-Object { $_.FullName })
    $hashes = [ordered]@{}
    foreach ($file in @($files | Sort-Object)) {
        $name = [IO.Path]::GetRelativePath($script:Root, $file).Replace('\', '/')
        $hashes[$name] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Get-CanonicalHash $hashes
}

function Test-GovernanceMutableProperties {
    param($Actual, $Expected, [string]$Kind)
    if ($Actual -isnot [Collections.IDictionary]) { return $false }
    $value = Copy-BootstrapValue $Actual
    if ($Kind -eq 'budget' -and $value.Contains('timePeriod')) {
        foreach ($key in 'startDate', 'endDate') {
            [datetimeoffset]$actualDate = [datetimeoffset]::MinValue
            [datetimeoffset]$expectedDate = [datetimeoffset]::MinValue
            if ($value.timePeriod.Contains($key) -and
                [datetimeoffset]::TryParse([string]$value.timePeriod[$key], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$actualDate) -and
                [datetimeoffset]::TryParse([string]$Expected.timePeriod[$key], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$expectedDate) -and $actualDate -eq $expectedDate) {
                $value.timePeriod[$key] = $Expected.timePeriod[$key]
            }
        }
    }
    foreach ($key in 'parameters', 'policyRule', 'notifications') {
        if ($Expected.Contains($key) -and (-not $value.Contains($key) -or
            (Get-CanonicalHash $value[$key]) -cne (Get-CanonicalHash $Expected[$key]))) { return $false }
    }
    Test-DesiredSubset $value $Expected
}

function Add-GovernancePlans {
    param($Context)
    $input = Get-Field $Context.Inputs 'governance'
    if ($null -eq $input) {
        Add-BootstrapBlocker $Context 'GOVERNANCE_INPUT_REQUIRED' 'platformInputs.governance.billingCurrency' 'Supply separately observed workload billing currency; profile declarations alone are not deployed controls or currency evidence.'
        return
    }
    Import-Module (Join-Path $script:Root 'platform\policy\Governance.psm1') -Scope Local
    $profile = $Context.Profile
    $sourceHash = Get-BootstrapGovernanceSourceHash
    $inner = $Context.Transport
    $trackedReads = {
        param($Request)
        if ($Request.provider -cne 'Azure' -or $Request.method -cne 'GET') { throw 'Governance planning is GET-only.' }
        $response = & $inner $Request
        $Context.Observations.Add(@{
            provider = 'Azure'; path = $Request.path; status = $response.status
            etag = if ($response.Contains('etag')) { [string]$response.etag } else { '' }
            fingerprint = Get-CanonicalHash -Value $response.body
        })
        return $response
    }.GetNewClosure()
    $request = New-BootstrapGovernanceRequest -Profile $profile -Transport $trackedReads
    $governancePlan = Governance\Get-GovernanceDeploymentPlan -Profile $profile -BillingCurrency $input.billingCurrency -Request $request -AllowSynthetic:$profile.synthetic
    $desired = Governance\Get-GovernanceDesiredState -Profile $profile -BillingCurrency $input.billingCurrency -AllowSynthetic:$profile.synthetic
    if ($desired.scope -ine $governancePlan.scope -or $desired.owner -cne $governancePlan.owner) { throw 'P3 governance planner/renderer scope contract disagrees.' }
    if ($profile.governance.policyEffect -ceq 'Disabled') {
        Add-BootstrapBlocker $Context 'GOVERNANCE_DISABLED' $desired.scope 'Disabled controls cannot authorize governed workload creation.'
    }
    foreach ($builtin in $desired.requiredBuiltins.Values) {
        $id = "$($builtin.id)/versions/$($builtin.version)"
        $observed = & $request 'GET' "https://management.azure.com${id}?api-version=2023-04-01" $null @{}
        if ($observed.StatusCode -ne 200 -or $observed.Body.id -ine $id -or $observed.Body.properties.version -cne $builtin.version -or $observed.Body.properties.policyType -cne 'BuiltIn') {
            Add-BootstrapBlocker $Context 'GOVERNANCE_BUILTIN_UNAVAILABLE' $id 'The pinned built-in version must be available; no fallback definition is substituted.'
        }
    }
    foreach ($resource in $desired.resources) {
        if ($resource.kind -notin @('definition', 'assignment', 'budget')) { throw 'Unsupported resource kind in the P3 governance contract.' }
        $record = @($governancePlan.resources | Where-Object { $_.resourceId -ieq $resource.resourceId })
        if ($record.Count -ne 1) { throw 'P3 governance ownership inventory does not match its desired resource inventory.' }
        $path = "$($resource.resourceId)?api-version=$($resource.apiVersion)"
        $before = Read-BootstrapResource $Context 'Azure' $path -AllowMissing
        $actual = if ($before.status -eq 404) { $null } else { $before.body }
        if ((Get-CanonicalHash -Value $actual) -cne $record[0].observedStateHash) { throw 'Governance state changed while planning; re-inspect before approval.' }
        if ($null -ne $actual) {
            if ($resource.kind -eq 'budget' -and $actual.properties.Contains('filter') -and $null -ne $actual.properties.filter -and
                ($actual.properties.filter -isnot [Collections.IDictionary] -or $actual.properties.filter.Count -gt 0)) {
                throw 'An existing governance budget has an unapproved filter. Use an inspected owned recovery plan; no silent coverage change is applied.'
            }
            if ($resource.kind -eq 'assignment') {
                foreach ($key in 'overrides', 'resourceSelectors') {
                    if ($actual.properties.Contains($key) -and @($actual.properties[$key]).Count -gt 0 -and $null -ne $actual.properties[$key]) {
                        throw 'An existing governance assignment has unapproved coverage overrides/selectors; explicit owned recovery is required.'
                    }
                }
            }
            if (Test-GovernanceMutableProperties $actual.properties $resource.properties $resource.kind) { continue }
        }
        $body = @{ properties = Copy-BootstrapValue $resource.properties }
        if ($resource.kind -eq 'budget' -and $governancePlan.parameters.parameters.budgetEtag.value) {
            $body.eTag = $governancePlan.parameters.parameters.budgetEtag.value
        }
        $scope = if ($resource.kind -eq 'definition') { "/subscriptions/$($profile.azure.subscriptionId)" } else { $desired.scope }
        $permission = switch ($resource.kind) {
            'definition' { 'Microsoft.Authorization/policyDefinitions/write' }
            'assignment' { 'Microsoft.Authorization/policyAssignments/write' }
            'budget' { 'Microsoft.Consumption/budgets/write' }
        }
        $Context.Operations.Add(@{
            kind = 'governanceResource'; governanceKind = $resource.kind; provider = 'Azure'; method = 'PUT'
            path = $path; scope = $scope; permission = $permission; before = $before; body = $body; owner = $desired.owner
        })
    }
    $Context.Governance = @{
        planHash = $governancePlan.planHash; desiredStateHash = $desired.desiredStateHash
        sourceHash = $sourceHash; sourceCommit = $governancePlan.sourceCommit
        billingCurrency = $input.billingCurrency; parameters = $governancePlan.parameters
        remainingLiveEvidence = $governancePlan.remainingLiveEvidence
    }
    if ((Get-BootstrapGovernanceSourceHash) -cne $sourceHash) { throw 'Governance source changed during planning.' }
}

function New-PlatformBootstrapPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ResolvedEnvironment,
        [Parameter(Mandatory)][Collections.IDictionary]$PlatformInputs,
        [ValidateSet('All', 'Environments', 'Federation', 'Runner', 'Network', 'Access', 'Completion', 'Governance')][string]$Stage = 'All',
        [Collections.IDictionary]$Completion,
        [scriptblock]$Transport,
        [switch]$AllowSynthetic
    )
    if ($AllowSynthetic -and $null -eq $Transport) { throw 'AllowSynthetic requires an explicit offline mock transport.' }
    Assert-ResolvedBootstrapEnvironment $ResolvedEnvironment -AllowSynthetic:$AllowSynthetic
    $inputs = Read-PlatformInputs -Json (ConvertTo-CanonicalJson $PlatformInputs)
    if ($null -eq $Transport) { $Transport = New-BootstrapTransport $ResolvedEnvironment.profile.azure (Get-Field $inputs 'github' @{}) }
    $context = New-PlanContext $ResolvedEnvironment $inputs $Transport
    $stageName = $Stage.ToLowerInvariant()
    $repo = $null
    if ($stageName -ne 'governance') { $repo = Read-GitHubBootstrapIdentity $context }
    if ($stageName -in @('all', 'environments') -and $null -ne $repo) { Add-EnvironmentPlans $context $repo }
    if ($stageName -in @('all', 'federation') -and $null -ne $repo) { Add-FederationPlans $context }
    if ($stageName -in @('all', 'runner') -and $null -ne $repo) { Add-RunnerChecks $context }
    if ($stageName -in @('all', 'network')) { Add-NetworkPlans $context }
    if ($stageName -in @('all', 'access')) { Add-AccessPlans $context }
    if ($stageName -in @('all', 'completion')) { Add-CompletionPlans $context $Completion }
    if ($stageName -in @('all', 'governance')) { Add-GovernancePlans $context }
    Test-PlannedPermissions $context
    $plan = @{
        schemaVersion = 1; environment = $ResolvedEnvironment.environment; stage = $stageName
        configurationHash = $ResolvedEnvironment.configurationHash; platformInputsHash = Get-CanonicalHash $inputs
        completionHash = Get-CanonicalHash -Value $Completion
        synthetic = [bool]$ResolvedEnvironment.profile.synthetic
        status = if ($context.Blockers.Count -gt 0) { 'blocked' } else { 'planned' }
        operations = $context.Operations.ToArray(); observations = $context.Observations.ToArray()
        blockers = $context.Blockers.ToArray(); liveReady = $false; liveGates = $script:LiveGates
    }
    if ($context.ContainsKey('Governance')) { $plan.governance = $context.Governance }
    Assert-BootstrapArtifactSafe -Value $plan
    $plan.planHash = Get-CanonicalHash $plan
    return ,$plan
}

function Invoke-BootstrapWrite {
    param([scriptblock]$Transport, [string]$Provider, [string]$Method, [string]$Path, $Body, [string]$ETag = '', [switch]$CreateOnly)
    $headers = @{}
    if ($ETag) { $headers['If-Match'] = $ETag }
    if ($CreateOnly) { $headers['If-None-Match'] = '*' }
    $response = & $Transport @{ provider = $Provider; method = $Method; path = $Path; body = $Body; headers = $headers }
    if ($null -eq $response -or $response.status -notin @(200, 201, 202, 204)) {
        $status = if ($null -eq $response) { 'missing' } else { $response.status }
        throw "Bootstrap $Method $Provider $Path failed with HTTP $status; no fallback was applied."
    }
    return $response
}

function Invoke-EnvironmentOperation {
    param($Context, $Operation)
    $current = Get-EnvironmentState $Context $Operation.name
    if ((Get-CanonicalHash $current) -cne (Get-CanonicalHash $Operation.before)) { throw "Stale environment state: $($Operation.name)." }
    if ($Operation.updateEnvironment) {
        $null = Invoke-BootstrapWrite $Context.Transport 'GitHub' 'PUT' $Operation.path $Operation.body $current.resource.etag
    }
    if ($Operation.createMarker) {
        $null = Invoke-BootstrapWrite $Context.Transport 'GitHub' 'POST' "$($Operation.path)/variables" @{ name = 'AILZ_BOOTSTRAP_OWNER'; value = $Operation.owner }
    }
    if ($Operation.createBranch) {
        $null = Invoke-BootstrapWrite $Context.Transport 'GitHub' 'POST' "$($Operation.path)/deployment-branch-policies" $Operation.branch
    }
    $Context.Cache.Clear()
    $after = Get-EnvironmentState $Context $Operation.name
    if ($after.marker.status -ne 200 -or $after.marker.body.value -cne $Operation.owner -or
        -not (Test-DesiredSubset (Get-EnvironmentWriteBody $after) $Operation.body) -or
        $after.branches.Count -ne 1 -or -not (Test-DesiredSubset $after.branches[0] $Operation.branch) -or
        ($Operation.requireAdminBypassDisabled -and (Get-Field $after.resource.body 'can_admins_bypass' $true))) {
        throw "Environment postcondition failed: $($Operation.name). The bootstrap is not complete."
    }
}

function Wait-BootstrapArmResource {
    param($Context, $Operation, [switch]$DeferPropertyVerification)
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $Context.Cache.Clear()
        $after = Read-BootstrapResource $Context 'Azure' $Operation.path -AllowMissing
        $state = [string](Get-Field (Get-Field $after.body 'properties' @{}) 'provisioningState' '')
        if ($state -in @('Failed', 'Canceled', 'Cancelled')) { throw "Resource provisioning failed: $($Operation.path)." }
        $matches = $DeferPropertyVerification -or (Test-DesiredSubset $after.body $Operation.body)
        $ready = $after.status -eq 200 -and $matches -and (-not $state -or $state -eq 'Succeeded')
        if ($ready -and $Operation.kind -eq 'reversePeering') { $ready = (Get-Field $after.body.properties 'peeringState' '') -ceq 'Connected' }
        if ($ready -and $Operation.kind -eq 'dnsLink') { $ready = (Get-Field $after.body.properties 'virtualNetworkLinkState' '') -ceq 'Completed' }
        if ($ready) { return $after }
        if (-not $DeferPropertyVerification -and $state -eq 'Succeeded' -and -not $matches) { throw "Resource postcondition failed: $($Operation.path)." }
        if ($attempt -lt 29) { Start-Sleep -Seconds 2 }
    }
    throw "Resource readiness was not observed within the bounded polling window: $($Operation.path). Re-inspect before continuing."
}

function Invoke-PlatformBootstrapPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Plan,
        [Collections.IDictionary]$ResolvedEnvironment,
        [Parameter(Mandatory)][Collections.IDictionary]$PlatformInputs,
        [Collections.IDictionary]$Completion,
        [switch]$Execute,
        [string]$ApprovedPlanHash,
        [scriptblock]$Transport
    )
    if (-not $Execute) { return @{ status = 'notExecuted'; planHash = $Plan.planHash; liveReady = $false } }
    $foundation = $Plan.stage -ceq 'foundation'
    if (-not $foundation -and $null -eq $ResolvedEnvironment) { throw 'An environment bootstrap plan requires its original Resolve-EnvironmentProfile result.' }
    if ($Plan.synthetic -or (-not $foundation -and $ResolvedEnvironment.profile.synthetic)) { throw 'Synthetic bootstrap inputs can never execute.' }
    if (-not $ApprovedPlanHash -or $ApprovedPlanHash -cne $Plan.planHash -or
        $Plan.planHash -cne (Get-UnsignedHash $Plan 'planHash')) { throw 'Approved plan hash does not exactly match the inspected, unmodified plan.' }
    if ($Plan.status -ne 'planned' -or $Plan.blockers.Count -gt 0) { throw 'The inspected bootstrap plan is blocked; resolve its dependencies before execution.' }
    if ($foundation) {
        $foundationContext = New-FoundationContext $PlatformInputs $Transport
        $Transport = $foundationContext.Transport
        $fresh = New-BootstrapFoundationPlan -PlatformInputs $PlatformInputs -Transport $Transport
    }
    else {
        if ($null -eq $ResolvedEnvironment) { throw 'An environment bootstrap plan requires its original Resolve-EnvironmentProfile result.' }
        if ($null -eq $Transport) { $Transport = New-BootstrapTransport $ResolvedEnvironment.profile.azure (Get-Field $PlatformInputs 'github' @{}) }
        $fresh = New-PlatformBootstrapPlan -ResolvedEnvironment $ResolvedEnvironment -PlatformInputs $PlatformInputs -Stage $Plan.stage -Completion $Completion -Transport $Transport
    }
    if ($fresh.planHash -cne $Plan.planHash) { throw 'Bootstrap plan is stale: configuration, entitlement, ownership, ETag or resource fingerprint changed. Inspect and approve a new plan.' }
    if (-not $PSCmdlet.ShouldProcess("$($Plan.environment): $($Plan.operations.Count) exact scoped operations", "Apply bootstrap plan $ApprovedPlanHash")) {
        return @{ status = 'notExecuted'; planHash = $Plan.planHash; liveReady = $false }
    }
    $completed = [Collections.Generic.List[object]]::new()
    $receipts = [Collections.Generic.List[object]]::new()
    $operation = $null
    try {
        foreach ($operation in $Plan.operations) {
            $context = if ($foundation) { New-FoundationContext $PlatformInputs $Transport } else { New-PlanContext $ResolvedEnvironment $PlatformInputs $Transport }
            if ($operation.kind -eq 'environment') { Invoke-EnvironmentOperation $context $operation }
            else {
                $current = Read-BootstrapResource $context 'Azure' $operation.path -AllowMissing
                if ($current.status -ne $operation.before.status -or $current.fingerprint -cne $operation.before.fingerprint -or $current.etag -cne $operation.before.etag) {
                    throw "Stale resource state: $($operation.path)."
                }
                $createOnly = $operation.kind -eq 'dnsLink' -and $current.status -eq 404
                $null = Invoke-BootstrapWrite $Transport 'Azure' $operation.method $operation.path $operation.body $current.etag -CreateOnly:$createOnly
                $after = Wait-BootstrapArmResource $context $operation -DeferPropertyVerification:($operation.kind -eq 'governanceResource')
                if ($operation.kind -in @('reversePeering', 'federation')) {
                    $receipts.Add(@{ resourceId = ($operation.path -split '\?', 2)[0]; owner = $operation.owner; fingerprint = $after.fingerprint })
                }
            }
            $status = if ($operation.kind -eq 'governanceResource') { 'applied-pending-governance-check' } else { 'verified' }
            $completed.Add(@{ kind = $operation.kind; target = $operation.path; status = $status })
        }
        if ($Plan.Contains('governance')) {
            Import-Module (Join-Path $script:Root 'platform\policy\Governance.psm1') -Scope Local
            $request = New-BootstrapGovernanceRequest -Profile $ResolvedEnvironment.profile -Transport $Transport
            $ready = Governance\Assert-GovernanceDeploymentReadiness -Profile $ResolvedEnvironment.profile -BillingCurrency $Plan.governance.billingCurrency -Request $request
            if ($ready -isnot [bool] -or -not $ready) { throw 'P3 governance readiness did not return exact success.' }
            foreach ($entry in $completed) { if ($entry.kind -eq 'governanceResource') { $entry.status = 'verified' } }
        }
    }
    catch {
        $_.Exception.Data['BootstrapEvidence'] = @{
            status = 'failed'; planHash = $Plan.planHash; completedOperations = $completed.ToArray()
            attemptedOperation = if ($null -ne $operation) { @{ kind = $operation.kind; target = $operation.path } } else { $null }
            partialEffectsPossible = $true; ownership = $receipts.ToArray()
            liveReady = $false; requirement = 'Execution stopped on the first error. Partial effects must be re-inspected, not treated as completion.'
        }
        throw
    }
    $result = @{ schemaVersion = 1; status = 'applied'; planHash = $Plan.planHash; completedOperations = $completed.ToArray(); ownership = $receipts.ToArray(); liveReady = $false; liveGates = $Plan.liveGates }
    if ($Plan.Contains('governance')) {
        $result.governanceReady = $true
        $result.governancePlanHash = $Plan.governance.planHash
        $result.governanceSourceHash = $Plan.governance.sourceHash
        $result.governanceRemainingLiveEvidence = $Plan.governance.remainingLiveEvidence
    }
    if ($foundation) { $result.outputs = Get-FoundationOutputs (New-FoundationContext $PlatformInputs $Transport) }
    return $result
}

function ConvertFrom-BootstrapBase64Url {
    param([string]$Value)
    if ($Value -notmatch '^[A-Za-z0-9_-]+$' -or $Value.Length % 4 -eq 1) { throw 'Invalid OIDC encoding.' }
    $text = $Value.Replace('-', '+').Replace('_', '/')
    $text += '=' * ((4 - ($text.Length % 4)) % 4)
    try { return ,[Convert]::FromBase64String($text) }
    catch { throw 'Invalid OIDC encoding.' }
}

function ConvertFrom-VerifiedGitHubOidcToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][Collections.IDictionary]$Jwks,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedClaims,
        [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )
    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) { throw 'Invalid OIDC compact token.' }
    $header = ConvertFrom-BootstrapJson ([Text.Encoding]::UTF8.GetString((ConvertFrom-BootstrapBase64Url $parts[0])))
    $claims = ConvertFrom-BootstrapJson ([Text.Encoding]::UTF8.GetString((ConvertFrom-BootstrapBase64Url $parts[1])))
    if ($header.alg -cne 'RS256' -or (Get-Field $header 'typ' 'JWT') -cne 'JWT' -or (Get-Field $header 'crit')) { throw 'Unsupported OIDC signing algorithm or critical header.' }
    $keys = @($Jwks.keys | Where-Object { $_.kid -ceq $header.kid -and $_.kty -ceq 'RSA' -and (Get-Field $_ 'use' 'sig') -ceq 'sig' -and (Get-Field $_ 'alg' 'RS256') -ceq 'RS256' })
    if ($keys.Count -ne 1) { throw 'OIDC signature key is unavailable or ambiguous.' }
    $parameters = [Security.Cryptography.RSAParameters]::new()
    $parameters.Modulus = ConvertFrom-BootstrapBase64Url $keys[0].n
    $parameters.Exponent = ConvertFrom-BootstrapBase64Url $keys[0].e
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportParameters($parameters)
        $verified = $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"), (ConvertFrom-BootstrapBase64Url $parts[2]), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $verified) { throw 'OIDC signature verification failed.' }
    }
    finally { $rsa.Dispose() }
    foreach ($name in 'iat', 'nbf', 'exp') {
        if (-not $claims.Contains($name) -or $claims[$name] -is [string] -or $claims[$name] -is [bool] -or
            $claims[$name] -isnot [ValueType] -or [decimal]$claims[$name] % 1 -ne 0) { throw 'OIDC validity claims must be integer NumericDate values.' }
    }
    if ($claims.iss -isnot [string] -or $claims.aud -isnot [string] -or
        $claims.iss -cne 'https://token.actions.githubusercontent.com' -or $claims.aud -cne 'api://AzureADTokenExchange' -or
        $claims.exp -le $Now -or $claims.nbf -gt $Now -or $claims.iat -gt $Now -or $claims.iat -gt $claims.exp) {
        throw 'OIDC issuer/audience or validity/expiry check failed.'
    }
    $allowed = @('iss', 'aud', 'sub', 'repository', 'repository_id', 'repository_owner_id', 'environment', 'ref', 'run_id', 'run_attempt', 'workflow_ref', 'workflow_sha', 'event_name', 'iat', 'exp', 'nbf')
    $required = @($allowed | Where-Object { $_ -notin @('iat', 'exp', 'nbf') })
    foreach ($name in $required) {
        if (-not $ExpectedClaims.Contains($name) -or -not $claims.Contains($name) -or [string]$claims[$name] -cne [string]$ExpectedClaims[$name]) {
            throw "OIDC claim/context mismatch: $name."
        }
    }
    $safe = [ordered]@{}
    foreach ($name in $allowed) { if ($claims.Contains($name)) { $safe[$name] = $claims[$name] } }
    return ,$safe
}

Export-ModuleMember -Function Get-BootstrapPlatformInputSchema, Read-PlatformInputs, Read-BootstrapJsonFile, ConvertFrom-BootstrapJson, New-BootstrapGovernanceRequest, New-PlatformBootstrapPlan, New-BootstrapFoundationPlan, Invoke-PlatformBootstrapPlan, ConvertFrom-VerifiedGitHubOidcToken, Assert-GitHubBootstrapReadiness, Assert-PreparedDeploymentFoundation
