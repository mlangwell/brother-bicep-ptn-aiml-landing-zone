#Requires -Version 7.0
<#
.SYNOPSIS
Private, plan-first developer completion and bounded live-probe orchestration.
.DESCRIPTION
Infrastructure owns the application image, identity and environment. This module
never repairs an image with containerapp update. Execute uses real transports;
OfflineTest requires a synthetic profile and injected transports and cannot
produce live-ready or promotion-eligible evidence.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1') -ErrorAction Stop
$script:CompletionRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Assert-CompletionCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-DeveloperCompletionOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $value = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 100
    if ($value.Contains('properties') -and $value.properties.Contains('outputs')) { $value = $value.properties.outputs }
    if ($value.Contains('outputs')) { $value = $value.outputs }
    if ($value.Contains('DEVELOPER_COMPLETION')) { $value = $value.DEVELOPER_COMPLETION.value }
    Assert-CompletionCondition ($value -is [Collections.IDictionary] -and $value.Count -gt 0) 'DEVELOPER_COMPLETION output is missing.'
    return ,$value
}

function Get-CompletionHttpsUri {
    param([string]$Value, [string]$HostPattern, [string]$PathPattern = '^/?$')
    $uri = $null
    $valid = [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)
    Assert-CompletionCondition ($valid -and $Value -cnotmatch '[\s\\\x00-\x1f]' -and
        $uri.Scheme -ceq 'https' -and $uri.Port -eq 443 -and [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Query) -and [string]::IsNullOrEmpty($uri.Fragment) -and
        $uri.DnsSafeHost -cmatch $HostPattern -and $uri.AbsolutePath -cmatch $PathPattern -and
        $Value -notmatch '/\.{1,2}/|%2e|%2f|%5c') 'Invalid HTTPS endpoint; credentials, alternate routes and redirects are not permitted.'
    return $uri
}

function Assert-CompletionResolution {
    param([Collections.IDictionary]$Resolution, [bool]$Execute, [bool]$OfflineTest, [AllowNull()][Collections.IDictionary]$Adapter)
    Assert-CompletionCondition (-not ($Execute -and $OfflineTest)) 'Execute and OfflineTest are mutually exclusive.'
    Assert-CompletionCondition (-not ($Execute -and $null -ne $Adapter)) 'Execution does not accept injected transports.'
    Assert-CompletionCondition ($Resolution.Contains('profile')) 'A resolved environment profile is required.'
    $synthetic = $Resolution.profile.synthetic -eq $true
    Assert-CompletionCondition (-not ($Execute -and $synthetic)) 'Synthetic profiles cannot execute.'
    if ($OfflineTest) {
        Assert-CompletionCondition ($synthetic -and $null -ne $Adapter) 'OfflineTest requires a synthetic profile and fake transports.'
    }
    $resolved = Resolve-EnvironmentProfile -Profile $Resolution.profile -AllowSynthetic:($synthetic -and -not $Execute)
    Assert-CompletionCondition ($Resolution.configurationHash -ceq $resolved.configurationHash -and
        (Get-CanonicalHash $Resolution.parameters) -ceq (Get-CanonicalHash $resolved.parameters)) 'Resolved profile or configuration hash mismatch.'
}

function Assert-CompletionOutput {
    param([Collections.IDictionary]$Resolution, [Collections.IDictionary]$Output)
    $profile = $Resolution.profile
    Assert-CompletionCondition ($Output.schemaVersion -eq 1 -and $Output.environment -ceq $profile.environment -and
        $Output.tenantId -ceq $profile.azure.tenantId -and $Output.subscriptionId -ceq $profile.azure.subscriptionId -and
        $Output.resourceGroup -ceq $profile.azure.resourceGroup) 'Completion output scope does not match the approved profile.'
    Assert-CompletionCondition ((Get-CanonicalHash $Output.release) -ceq (Get-CanonicalHash $profile.release)) 'Completion release mismatch.'
    Assert-CompletionCondition ($Output.gateway.accessMode -ceq 'gateway' -and $Output.gateway.audience -ceq $profile.gateway.audience) 'Governed gateway is required.'
    Assert-CompletionCondition ($Output.registryResourceId -ceq $profile.application.registryResourceId -and
        $Output.workspace.repository -ceq $profile.application.workspaceRepository -and $Output.workspace.ref -ceq $profile.application.workspaceRef) 'Registry or workspace mismatch.'
    $scope = "/subscriptions/$($profile.azure.subscriptionId)/resourceGroups/$($profile.azure.resourceGroup)/providers/"
    foreach ($pair in @(
        @($Output.appConfiguration.resourceId, 'Microsoft.AppConfiguration/configurationStores'),
        @($Output.gateway.resourceId, 'Microsoft.ApiManagement/service'),
        @($Output.gateway.backendResourceId, 'Microsoft.CognitiveServices/accounts')
    )) {
        Assert-CompletionCondition ($pair[0] -cmatch ('^' + [regex]::Escape($scope + $pair[1] + '/') + '[A-Za-z0-9-]+$')) 'Unexpected completion resource scope or type.'
    }
    $null = Get-CompletionHttpsUri $Output.appConfiguration.endpoint '^[a-z0-9][a-z0-9-]*\.azconfig\.io$'
    $null = Get-CompletionHttpsUri $Output.gateway.endpoint '^[a-z0-9][a-z0-9-]*\.azure-api\.net$' ('^/inference/' + [regex]::Escape($profile.gateway.workloadKey) + '/v1/responses$')
    $null = Get-CompletionHttpsUri $Output.gateway.backendEndpoint '^[a-z0-9][a-z0-9-]*\.openai\.azure\.com$'
    Assert-CompletionCondition ($Output.applications.Count -eq 1) 'Exactly the selected starter application is required.'
    $application = $Output.applications[0]
    Assert-CompletionCondition ($application.resourceId -ceq ($scope + 'Microsoft.App/containerApps/' + $application.name) -and
        $application.identityResourceId -ceq $profile.identities.workload.resourceId -and
        $application.principalId -ceq $profile.identities.workload.principalId) 'Application resource or external workload identity mismatch.'
    $null = Get-CompletionHttpsUri ("https://" + $application.fqdn) '^[a-z0-9.-]+\.azurecontainerapps\.io$'
    Assert-CompletionCondition ($Output.appConfiguration.settings -is [Collections.IList] -and $Output.appConfiguration.settings.Count -gt 0) 'Runtime setting descriptors are required.'
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($setting in $Output.appConfiguration.settings) {
        Assert-CompletionCondition ($setting.name -is [string] -and $setting.name.Length -gt 0 -and
            ($null -eq $setting.label -or $setting.label -is [string]) -and $setting.contentType -is [string] -and
            $setting.value -is [string]) 'Invalid runtime setting descriptor.'
        Assert-CompletionCondition ($keys.Add($setting.name + [char]0 + [string]$setting.label)) 'Duplicate App Configuration key and label.'
        if ($setting.sourceResourceId -or $setting.sourceProperty) {
            Assert-CompletionCondition ($setting.value -ceq '' -and
                $setting.sourceResourceId -cmatch ('^' + [regex]::Escape($scope) + 'Microsoft.Insights/components/[A-Za-z0-9-]+$') -and
                $setting.sourceProperty -cin @('ConnectionString', 'InstrumentationKey')) 'Sensitive settings must use an approved observability reference, not an output value.'
        }
    }
}

function Send-CompletionHttp {
    param([string]$Method, [uri]$Uri, [Collections.IDictionary]$Headers, [AllowNull()][object]$Body, [string[]]$Addresses)
    if (-not ('AilzCompletion.PrivateHttp' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace AilzCompletion {
    public sealed class Result {
        public int StatusCode { get; set; }
        public string Body { get; set; }
        public Dictionary<string,string> Headers { get; set; }
    }
    public static class PrivateHttp {
        public static Result Send(string method, string url, Dictionary<string,string> headers, string body, string[] addresses) {
            var uri = new Uri(url);
            if (uri.Scheme != "https" || uri.Port != 443 || addresses.Length == 0)
                throw new InvalidOperationException("Private HTTPS is required.");
            using var handler = new SocketsHttpHandler {
                AllowAutoRedirect = false, UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(10)
            };
            handler.ConnectCallback = async (context, cancellationToken) => {
                if (!string.Equals(context.DnsEndPoint.Host, uri.DnsSafeHost, StringComparison.OrdinalIgnoreCase) ||
                    context.DnsEndPoint.Port != 443) throw new InvalidOperationException("Cross-origin connection denied.");
                var socket = new Socket(IPAddress.Parse(addresses[0]).AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                try {
                    await socket.ConnectAsync(new IPEndPoint(IPAddress.Parse(addresses[0]), 443), cancellationToken);
                    return new NetworkStream(socket, ownsSocket: true);
                } catch { socket.Dispose(); throw; }
            };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(45) };
            using var request = new HttpRequestMessage(new HttpMethod(method), uri);
            foreach (var pair in headers) request.Headers.Add(pair.Key, pair.Value);
            if (body != null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
            using var response = client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
            response.Content.LoadIntoBufferAsync(4 * 1024 * 1024).GetAwaiter().GetResult();
            var result = new Result {
                StatusCode = (int)response.StatusCode,
                Body = response.Content.ReadAsStringAsync().GetAwaiter().GetResult(),
                Headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
            };
            foreach (var header in response.Headers) result.Headers[header.Key] = string.Join(",", header.Value);
            return result;
        }
    }
}
'@ -ErrorAction Stop
    }
    $headersMap = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Headers.Keys) { $headersMap.Add($key, [string]$Headers[$key]) }
    $serialized = if ($null -eq $Body) { $null } else { ConvertTo-CanonicalJson $Body }
    try { $result = [AilzCompletion.PrivateHttp]::Send($Method, $Uri.AbsoluteUri, $headersMap, $serialized, $Addresses) }
    catch { throw 'Bounded HTTPS request failed. Response, credentials and transport details are suppressed.' }
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($result.Body)) {
        try { $parsed = ConvertFrom-Json -InputObject $result.Body -AsHashtable -Depth 100 }
        catch { $parsed = $result.Body }
    }
    $responseHeaders = @{}
    foreach ($key in $result.Headers.Keys) { $responseHeaders[$key] = $result.Headers[$key] }
    return @{ statusCode = $result.StatusCode; body = $parsed; headers = $responseHeaders }
}

function New-CompletionAdapter {
    return @{
        Native = { param($command, $arguments) Invoke-CheckedNative -Command $command -Arguments $arguments }
        Tool = { param($name) (Get-Command -Name $name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
        IsSystem = {
            if ($IsWindows) { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18' }
            return $false
        }
        Token = {
            param($audience)
            $json = Invoke-CheckedNative 'az' @('account', 'get-access-token', '--resource', $audience, '--output', 'json', '--only-show-errors')
            $result = ConvertFrom-Json -InputObject $json -AsHashtable
            Assert-CompletionCondition ($result.Contains('accessToken') -and -not [string]::IsNullOrWhiteSpace($result.accessToken)) 'Azure login did not supply an access token.'
            return $result.accessToken
        }
        ArmGet = {
            param($id, $apiVersion)
            Invoke-CompletionArmGet -ResourceId $id -ApiVersion $apiVersion
        }
        Resolve = { param($hostname) return ,@([Net.Dns]::GetHostAddresses($hostname) | ForEach-Object { $_.ToString() }) }
        Http = { param($method, $uri, $headers, $body, $addresses) Send-CompletionHttp $method $uri $headers $body $addresses }
        Sleep = { param($seconds) Start-Sleep -Seconds $seconds }
        Gateway = {
            param($resolution, $output, $armGet)
            # Classic VNet injection has no inbound private endpoint - Learn:
            # "In the classic API Management tiers, private endpoints aren't
            # supported in instances injected in an internal or external virtual
            # network." The completion evidence is therefore the injected private
            # topology (Internal mode, approved subnet, no PE) rather than an
            # approved private endpoint plus publicNetworkAccess=Disabled, which
            # this topology can never reach.
            Assert-CompletionCondition ($output.gateway.Contains('hostName') -and
                -not [string]::IsNullOrWhiteSpace($output.gateway.hostName)) 'The deployed gateway hostname is required.'
            $path = Join-Path $PSScriptRoot 'Gateway.psm1'
            Assert-CompletionCondition (Test-Path -LiteralPath $path -PathType Leaf) 'Gateway injected-topology verifier is required before completion.'
            Import-Module $path -ErrorAction Stop
            $request = {
                param($method, $url, $body, $headers)
                $uri = [uri]$url
                if ($method -cne 'GET' -or $null -ne $body -or $uri.Scheme -cne 'https' -or
                    $uri.DnsSafeHost -cne 'management.azure.com' -or $uri.Query -cnotmatch '^\?api-version=([0-9-]+)$') {
                    throw 'Completion permits only fixed-version gateway management reads.'
                }
                $version = $Matches[1]
                $value = & $armGet $uri.AbsolutePath $version
                return @{ StatusCode = 200; Body = $value; Headers = @{} }
            }.GetNewClosure()
            $plan = Get-GatewayDeploymentPlan -ServiceResourceId $output.gateway.resourceId -EnvironmentName $resolution.environment -WorkloadKey $resolution.profile.gateway.workloadKey -Request $request
            Assert-CompletionCondition ($plan.observedState -ceq 'Injected' -and -not $plan.initialProvisioning) 'Gateway is absent or not settled in the injected private topology.'
            $service = & $armGet $output.gateway.resourceId '2024-05-01'
            $connections = @()
            if ($service.properties.Contains('privateEndpointConnections') -and $service.properties.privateEndpointConnections) {
                $connections = @($service.properties.privateEndpointConnections)
            }
            Assert-CompletionCondition ($connections.Count -eq 0) 'An injected gateway must carry no private endpoint connection; classic VNet injection does not support one.'
            Assert-CompletionCondition ($service.properties.virtualNetworkType -ceq 'Internal') 'Gateway must be injected in Internal virtual network mode to keep the data plane off public DNS.'
            $verified = Complete-GatewayActivation -Plan $plan -Request $request -MaxAttempts 1 -RetryDelaySeconds 0
            Assert-CompletionCondition ($verified.status -ceq 'VerifiedControlPlane' -and
                $verified.virtualNetworkType -ceq 'Internal' -and -not $verified.changed) 'Gateway injected-topology verification did not complete without mutation.'
            return @{ privateReady = $true }
        }
    }
}

function Test-CompletionAddressInCidr {
    param([string]$Address, [string]$Cidr)
    $parts = $Cidr.Split('/')
    Assert-CompletionCondition ($parts.Count -eq 2) 'Private CIDR is invalid.'
    $network = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $addressBytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    $length = 0
    Assert-CompletionCondition ([int]::TryParse($parts[1], [ref]$length) -and $length -ge 0 -and $length -le $network.Length * 8) 'Private CIDR prefix is invalid.'
    if ($network.Length -ne $addressBytes.Length) { return $false }
    for ($i = 0; $i -lt $network.Length; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $length - $i * 8))
        $mask = if ($bits -eq 0) { 0 } else { (255 -shl (8 - $bits)) -band 255 }
        if (($network[$i] -band $mask) -ne ($addressBytes[$i] -band $mask)) { return $false }
    }
    return $true
}

function Get-CompletionPrivateAddresses {
    param([uri]$Uri, [string[]]$PrivateCidrs, [Collections.IDictionary]$Adapter)
    $addresses = @(& $Adapter.Resolve $Uri.DnsSafeHost)
    Assert-CompletionCondition ($addresses.Count -gt 0 -and $PrivateCidrs.Count -gt 0) 'Private DNS resolution or declared CIDRs are missing.'
    foreach ($address in $addresses) {
        $isPrivate = $false
        foreach ($private in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7')) {
            if (Test-CompletionAddressInCidr $address $private) { $isPrivate = $true; break }
        }
        $isDeclared = $false
        foreach ($cidr in $PrivateCidrs) {
            if (Test-CompletionAddressInCidr $address $cidr) { $isDeclared = $true; break }
        }
        Assert-CompletionCondition ($isPrivate -and $isDeclared) 'Private DNS resolved outside the declared private network; no public-access exception is allowed.'
    }
    return ,([string[]]$addresses)
}

function Invoke-CompletionRetry {
    param(
        [scriptblock]$Request, [scriptblock]$Sleep, [switch]$RetryTransient
    )
    $attempts = if ($RetryTransient) { 3 } else { 1 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $result = & $Request
        Assert-CompletionCondition ($result -is [Collections.IDictionary] -and $result.statusCode -ge 100 -and $result.statusCode -le 599) 'Invalid HTTP transport result.'
        $transient = $result.statusCode -eq 429 -or $result.statusCode -ge 500
        if (-not $transient -or $attempt -eq $attempts) { return ,$result }
        $seconds = [double][Math]::Pow(2, $attempt - 1)
        if ($result.headers.Contains('Retry-After')) {
            $text = [string]$result.headers['Retry-After']
            $delay = 0.0
            $date = [DateTimeOffset]::MinValue
            if ([double]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$delay)) { $seconds = $delay }
            elseif ([DateTimeOffset]::TryParse($text, [ref]$date)) { $seconds = [Math]::Max(0, ($date - [DateTimeOffset]::UtcNow).TotalSeconds) }
            else { throw 'Transient response contains an invalid Retry-After value.' }
        }
        Assert-CompletionCondition ($seconds -ge 0 -and $seconds -le 30) 'Retry-After exceeds the bounded completion retry budget; rerun later.'
        & $Sleep $seconds
    }
}

function Invoke-CompletionHttp {
    param(
        [string]$Method, [uri]$Uri, [Collections.IDictionary]$Headers, [AllowNull()][object]$Body,
        [string[]]$PrivateCidrs, [Collections.IDictionary]$Adapter, [switch]$RetryTransient
    )
    $addresses = Get-CompletionPrivateAddresses $Uri $PrivateCidrs $Adapter
    $request = { & $Adapter.Http $Method $Uri.AbsoluteUri $Headers $Body $addresses }.GetNewClosure()
    Invoke-CompletionRetry -Request $request -Sleep $Adapter.Sleep -RetryTransient:$RetryTransient
}

function Invoke-CompletionArmGet {
    param(
        [string]$ResourceId, [string]$ApiVersion,
        [scriptblock]$Native = { param($command, $arguments) Invoke-CheckedNative $command $arguments },
        [scriptblock]$Http = { param($method, $uri, $headers, $body, $addresses) Send-CompletionHttp $method ([uri]$uri) $headers $body $addresses },
        [scriptblock]$Resolve = { param($hostname) return ,@([Net.Dns]::GetHostAddresses($hostname) | ForEach-Object { $_.ToString() }) },
        [scriptblock]$Sleep = { param($seconds) Start-Sleep -Seconds $seconds }
    )
    Assert-CompletionCondition ($ResourceId -cmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/[A-Za-z0-9./_-]+$' -and
        $ResourceId -cnotmatch '/\.{1,2}(/|$)' -and $ApiVersion -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') 'Invalid management resource identifier or API version.'
    $json = & $Native 'az' @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '--output', 'json', '--only-show-errors')
    try { $token = ConvertFrom-Json -InputObject $json -AsHashtable }
    catch { throw 'Azure login token response is invalid; credential output is suppressed.' }
    Assert-CompletionCondition ($token -is [Collections.IDictionary] -and $token.Contains('accessToken') -and
        $token.accessToken -is [string] -and -not [string]::IsNullOrWhiteSpace($token.accessToken)) 'Azure login did not supply a management access token.'
    # Only the fixed ARM control-plane origin uses public DNS. Data-plane requests
    # continue through Invoke-CompletionHttp and its mandatory declared-CIDR guard.
    $uri = "https://management.azure.com${ResourceId}?api-version=$ApiVersion"
    $addresses = @(& $Resolve 'management.azure.com')
    Assert-CompletionCondition ($addresses.Count -gt 0) 'Management endpoint did not resolve.'
    foreach ($address in $addresses) { $null = [Net.IPAddress]::Parse($address) }
    $headers = @{ Authorization = 'Bearer ' + $token.accessToken; Accept = 'application/json' }
    $request = { & $Http 'GET' $uri $headers $null $addresses }.GetNewClosure()
    $response = Invoke-CompletionRetry -Request $request -Sleep $Sleep -RetryTransient
    Assert-CompletionHttpStatus $response @(200) 'Read management resource'
    Assert-CompletionCondition ($response.body -is [Collections.IDictionary]) 'Management response is not an entity or collection.'
    $value = @{} + $response.body
    if ($response.headers.Contains('ETag') -and -not [string]::IsNullOrWhiteSpace($response.headers.ETag)) {
        $value['etag'] = $response.headers.ETag
    }
    return ,$value
}

function Assert-CompletionHttpStatus {
    param([Collections.IDictionary]$Result, [int[]]$Allowed, [string]$Operation)
    Assert-CompletionCondition ($Result.statusCode -in $Allowed) "$Operation failed with HTTP $($Result.statusCode). Body and credentials are suppressed."
}

function Get-CompletionAccount {
    param([Collections.IDictionary]$Resolution, [Collections.IDictionary]$Adapter, [switch]$Human)
    $json = & $Adapter.Native 'az' @('account', 'show', '--output', 'json', '--only-show-errors')
    $account = ConvertFrom-Json -InputObject $json -AsHashtable
    Assert-CompletionCondition ($account.id -ceq $Resolution.profile.azure.subscriptionId -and
        $account.tenantId -ceq $Resolution.profile.azure.tenantId) 'Azure login scope mismatch. Complete your own interactive SSO and select the approved scope.'
    if ($Human) {
        Assert-CompletionCondition ($account.user.type -ceq 'user') 'A human workspace requires the developer own interactive SSO, not LocalSystem or a pipeline service principal.'
    }
    return ,$account
}

function Get-CompletionPrivateCidrs {
    param([Collections.IDictionary]$Resolution, [Collections.IDictionary]$Output, [Collections.IDictionary]$Adapter)
    $vnet = & $Adapter.ArmGet $Output.vnetResourceId '2024-05-01'
    $declared = @($Resolution.profile.parameters.vnetAddressPrefixes)
    $actual = @($vnet.properties.addressSpace.addressPrefixes)
    Assert-CompletionCondition ((Get-CanonicalHash @($declared | Sort-Object)) -ceq
        (Get-CanonicalHash @($actual | Sort-Object))) 'Deployed VNet address space differs from the approved profile.'
    return ,([string[]]$declared)
}

function Assert-CompletionPrivateServices {
    param([Collections.IDictionary]$Output, [Collections.IDictionary]$Adapter)
    $configResource = & $Adapter.ArmGet $Output.appConfiguration.resourceId '2024-05-01'
    Assert-CompletionCondition ($configResource.properties.publicNetworkAccess -ceq 'Disabled' -and
        $configResource.properties.endpoint.TrimEnd('/') -ceq $Output.appConfiguration.endpoint.TrimEnd('/') -and
        @($configResource.properties.privateEndpointConnections | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -ceq 'Approved'
        }).Count -gt 0) 'App Configuration must have disabled public access and an approved private connection.'
    $backend = & $Adapter.ArmGet $Output.gateway.backendResourceId '2024-10-01'
    Assert-CompletionCondition ($backend.properties.publicNetworkAccess -ceq 'Disabled' -and
        $backend.properties.disableLocalAuth -eq $true) 'The backend must reject public access and local-key authentication.'
}

function Test-CompletionPrivateEndpoints {
    param([Collections.IDictionary]$Output, [string[]]$PrivateCidrs, [Collections.IDictionary]$Adapter)
    $endpoints = @($Output.appConfiguration.endpoint, $Output.gateway.endpoint, $Output.gateway.backendEndpoint)
    foreach ($endpoint in $endpoints) {
        $result = Invoke-CompletionHttp 'GET' ([uri]$endpoint) @{} $null $PrivateCidrs $Adapter
        Assert-CompletionCondition ($result.statusCode -ge 200 -and $result.statusCode -lt 500 -and
            $result.statusCode -notin @(301, 302, 303, 307, 308)) 'Private HTTPS connectivity did not succeed without redirection.'
    }
}

function Get-CompletionApplicationEvidence {
    param([Collections.IDictionary]$Resolution, [Collections.IDictionary]$Output, [string[]]$PrivateCidrs, [Collections.IDictionary]$Adapter)
    $profile = $Resolution.profile
    $registry = & $Adapter.ArmGet $Output.registryResourceId '2023-07-01'
    Assert-CompletionCondition ($registry.properties.loginServer -cmatch '^[a-z0-9]+\.azurecr\.io$') 'Private registry login server is invalid.'
    $expectedImage = "$($registry.properties.loginServer)/$($profile.application.imageRepository)@$($profile.release.imageDigest)"
    $results = [Collections.Generic.List[object]]::new()
    foreach ($app in $Output.applications) {
        Assert-CompletionCondition ($app.image -ceq $expectedImage) 'Infrastructure output does not retain the selected immutable image.'
        $resource = & $Adapter.ArmGet $app.resourceId '2024-03-01'
        $revisions = & $Adapter.ArmGet "$($app.resourceId)/revisions" '2024-03-01'
        $active = @($revisions.value | Where-Object { $_.properties.active -eq $true })
        Assert-CompletionCondition ($active.Count -eq 1 -and $active[0].name -ceq $resource.properties.latestReadyRevisionName -and
            $resource.properties.latestRevisionName -ceq $resource.properties.latestReadyRevisionName -and
            $active[0].properties.healthState -ceq 'Healthy' -and $active[0].properties.runningState -ceq 'Running') 'The selected application revision is not active and healthy.'
        Assert-CompletionCondition ($resource.properties.configuration.ingress.fqdn -ceq $app.fqdn) 'Application FQDN differs from the deployed output.'
        $identity = $resource.identity.userAssignedIdentities
        Assert-CompletionCondition ($identity.Contains($app.identityResourceId) -and
            $identity[$app.identityResourceId].clientId -ceq $profile.identities.workload.clientId -and
            $identity[$app.identityResourceId].principalId -ceq $profile.identities.workload.principalId) 'The active application is not bound to the approved external workload identity.'
        $expected = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        # Values come from the Bicep-shaped descriptors, never from a second settings inventory.
        foreach ($setting in $Output.appConfiguration.settings) {
            if ($setting.name -cmatch '^(SMOKE_|INFERENCE_)|^AZURE_(TENANT_ID|CLIENT_ID)$') {
                Assert-CompletionCondition (-not $expected.ContainsKey($setting.name)) 'Ambiguous runtime configuration labels.'
                $expected.Add($setting.name, $setting.value)
            }
        }
        $expected['APP_CONFIG_ENDPOINT'] = $Output.appConfiguration.endpoint
        $expected['AZURE_TENANT_ID'] = $Output.tenantId
        $expected['AZURE_CLIENT_ID'] = $profile.identities.workload.clientId
        foreach ($template in @($resource.properties.template, $active[0].properties.template)) {
            Assert-CompletionCondition ($template.containers.Count -eq 1 -and $template.containers[0].image -ceq $expectedImage) 'Active application image mismatch. Infrastructure must fix the image; completion will not update it.'
            $environment = @{}
            foreach ($entry in $template.containers[0].env) {
                Assert-CompletionCondition (-not $environment.Contains($entry.name)) 'Duplicate active application setting.'
                $environment[$entry.name] = $entry
            }
            foreach ($key in $expected.Keys) {
                Assert-CompletionCondition ($environment.Contains($key) -and $environment[$key].Contains('value') -and
                    $environment[$key].value -ceq $expected[$key]) 'Required active application configuration is missing or differs from infrastructure.'
            }
        }
        foreach ($route in @('health', 'ready')) {
            $result = Invoke-CompletionHttp 'GET' ([uri]"https://$($app.fqdn)/$route") @{} $null $PrivateCidrs $Adapter -RetryTransient
            Assert-CompletionHttpStatus $result @(200) 'Starter readiness'
            Assert-CompletionCondition ($result.body -is [Collections.IDictionary] -and
                $result.body.service -ceq 'developer-smoke' -and $result.body.version -ceq $profile.release.sourceSha -and
                $result.body.status -ceq $(if ($route -ceq 'health') { 'ok' } else { 'ready' })) 'Health response is not the selected starter identity and version.'
        }
        $results.Add(@{ resourceId = $app.resourceId; name = $app.name; revision = $active[0].name; image = $expectedImage; healthVersion = $profile.release.sourceSha; configurationVerified = $true })
    }
    return ,$results.ToArray()
}

function Invoke-DeveloperCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Resolution,
        [Parameter(Mandatory)][Collections.IDictionary]$DeploymentOutput,
        [switch]$Execute, [switch]$OfflineTest,
        [AllowNull()][Collections.IDictionary]$Adapter
    )
    Assert-CompletionResolution $Resolution $Execute.IsPresent $OfflineTest.IsPresent $Adapter
    Assert-CompletionOutput $Resolution $DeploymentOutput
    $evidence = @{
        schemaVersion = 1; environment = $Resolution.environment; release = $Resolution.profile.release
        configurationHash = $Resolution.configurationHash; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'plan'; runnerReady = $false; humanReady = $false; promotionEligible = $false
        configuration = @{ created = 0; updated = 0; unchanged = 0 }
        applications = @(); pending = @('Execute private completion', 'Developer interactive SSO/workspace and full live enforcement gate')
    }
    if (-not $Execute -and -not $OfflineTest) { return ,$evidence }
    if ($null -eq $Adapter) { $Adapter = New-CompletionAdapter }
    $null = Get-CompletionAccount $Resolution $Adapter
    $output = $DeploymentOutput
    Assert-CompletionPrivateServices $output $Adapter
    $privateCidrs = Get-CompletionPrivateCidrs $Resolution $output $Adapter
    $gateway = & $Adapter.Gateway $Resolution $output $Adapter.ArmGet
    Assert-CompletionCondition ($gateway.privateReady -eq $true) 'Gateway private/PNA readiness is required.'
    Test-CompletionPrivateEndpoints $output $privateCidrs $Adapter
    $evidence.applications = Get-CompletionApplicationEvidence $Resolution $output $privateCidrs $Adapter
    $token = & $Adapter.Token 'https://azconfig.io'
    Assert-CompletionCondition (-not [string]::IsNullOrWhiteSpace($token)) 'App Configuration requires an Entra data-plane token.'
    $baseHeaders = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.microsoft.appconfig.kv+json' }
    $owner = Get-CanonicalHash @{ environment = $Resolution.environment; resourceId = $output.appConfiguration.resourceId }
    $changes = [Collections.Generic.List[object]]::new()
    $sourceCache = @{}
    foreach ($setting in $output.appConfiguration.settings) {
        $value = $setting.value
        if ($setting.sourceResourceId) {
            if (-not $sourceCache.Contains($setting.sourceResourceId)) {
                $sourceCache[$setting.sourceResourceId] = & $Adapter.ArmGet $setting.sourceResourceId '2020-02-02'
            }
            $properties = $sourceCache[$setting.sourceResourceId].properties
            Assert-CompletionCondition ($properties.Contains($setting.sourceProperty) -and
                -not [string]::IsNullOrWhiteSpace($properties[$setting.sourceProperty])) 'Required observability configuration could not be resolved privately.'
            $value = [string]$properties[$setting.sourceProperty]
        }
        $label = if ([string]::IsNullOrEmpty($setting.label)) { '%00' } else { [uri]::EscapeDataString($setting.label) }
        $uri = [uri]($output.appConfiguration.endpoint.TrimEnd('/') + '/kv/' + [uri]::EscapeDataString($setting.name) + "?label=$label&api-version=1.0")
        $existing = Invoke-CompletionHttp 'GET' $uri $baseHeaders $null $privateCidrs $Adapter -RetryTransient
        Assert-CompletionHttpStatus $existing @(200, 404) 'Read App Configuration'
        $headers = @{} + $baseHeaders
        $tags = @{}
        $action = 'created'
        if ($existing.statusCode -eq 200) {
            Assert-CompletionCondition ($existing.body -is [Collections.IDictionary]) 'Invalid App Configuration read result.'
            $current = $existing.body
            if ($current.value -ceq $value -and $current.content_type -ceq $setting.contentType) {
                $evidence.configuration.unchanged++
                continue
            }
            Assert-CompletionCondition ($current.Contains('tags') -and $null -ne $current.tags -and
                $current.tags.Contains('ailz-completion-owner') -and $current.tags['ailz-completion-owner'] -ceq $owner) 'App Configuration ownership conflict; existing values are preserved for a manual decision.'
            Assert-CompletionCondition (-not ($current.Contains('locked') -and $current.locked)) 'Owned App Configuration setting is locked; completion will not unlock it.'
            $etag = if ($existing.headers.Contains('ETag')) { $existing.headers.ETag } elseif ($current.Contains('etag')) { '"' + $current.etag + '"' } else { '' }
            Assert-CompletionCondition (-not [string]::IsNullOrWhiteSpace($etag)) 'ETag is required before an owned configuration update.'
            $headers['If-Match'] = $etag
            $tags = @{} + $current.tags
            $action = 'updated'
        }
        else { $headers['If-None-Match'] = '*' }
        $tags['ailz-completion-owner'] = $owner
        $changes.Add(@{
            uri = $uri; headers = $headers; body = @{ value = $value; content_type = $setting.contentType; tags = $tags }
            action = $action
        })
    }
    # Detect every ownership conflict before the first write. Later failures remain fatal
    # and reruns reconcile only outstanding keys; no unrelated key is ever deleted.
    foreach ($change in $changes) {
        $write = Invoke-CompletionHttp 'PUT' $change.uri $change.headers $change.body $privateCidrs $Adapter -RetryTransient
        Assert-CompletionHttpStatus $write @(200) 'Write App Configuration'
        $read = Invoke-CompletionHttp 'GET' $change.uri $baseHeaders $null $privateCidrs $Adapter -RetryTransient
        Assert-CompletionHttpStatus $read @(200) 'Verify App Configuration'
        Assert-CompletionCondition ($read.body.value -ceq $change.body.value -and
            $read.body.content_type -ceq $change.body.content_type) 'Required configuration did not persist; completion is not ready.'
        $evidence.configuration[$change.action]++
    }
    $evidence.mode = if ($OfflineTest) { 'offline-test' } else { 'executed' }
    $evidence.runnerReady = -not $OfflineTest
    $evidence.privateConnectivity = @{ status = $(if ($OfflineTest) { 'simulated' } else { 'verified' }); endpointCount = 4 }
    $evidence.pending = @('Developer interactive SSO/workspace and full live enforcement gate')
    return ,$evidence
}

function Assert-DeveloperWorkspacePaths {
    param([string]$WorkspacePath, [string]$BootstrapCheckoutPath)
    Assert-CompletionCondition ([IO.Path]::IsPathFullyQualified($WorkspacePath) -and
        [IO.Path]::IsPathFullyQualified($BootstrapCheckoutPath)) 'Explicit absolute workspace and bootstrap checkout paths are required.'
    $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $bootstrap = [IO.Path]::GetFullPath($BootstrapCheckoutPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $separator = [IO.Path]::DirectorySeparatorChar
    Assert-CompletionCondition (-not $workspace.Equals($bootstrap, $comparison) -and
        -not $workspace.StartsWith($bootstrap + $separator, $comparison) -and
        -not $bootstrap.StartsWith($workspace + $separator, $comparison)) 'Editable workspace must be separate from the disposable bootstrap checkout.'
    foreach ($path in @($workspace, $bootstrap)) {
        $cursor = $path
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force
                Assert-CompletionCondition (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Workspace/bootstrap paths must not traverse symlinks or junctions.'
            }
            $parent = [IO.Path]::GetDirectoryName($cursor)
            if ($parent -eq $cursor) { break }
            $cursor = $parent
        }
    }
    return $workspace
}

function Invoke-DeveloperWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Resolution,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$BootstrapCheckoutPath,
        [switch]$Execute, [switch]$OfflineTest,
        [AllowNull()][Collections.IDictionary]$Adapter
    )
    Assert-CompletionResolution $Resolution $Execute.IsPresent $OfflineTest.IsPresent $Adapter
    $workspace = Assert-DeveloperWorkspacePaths $WorkspacePath $BootstrapCheckoutPath
    $application = $Resolution.profile.application
    Assert-CompletionCondition ($application.workspaceRepository -cmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$' -and
        $application.workspaceRef -cmatch '^[0-9a-f]{40}$') 'Workspace requires an approved credential-free GitHub URL and immutable commit SHA.'
    $result = @{
        schemaVersion = 1; environment = $Resolution.environment; configurationHash = $Resolution.configurationHash
        mode = 'plan'; workspacePath = $workspace; repository = $application.workspaceRepository; ref = $application.workspaceRef
        workspacePrepared = $false; humanReady = $false; promotionEligible = $false
        pending = @('Execute tool/worktree/dependency checks under the developer identity', 'Correlated application and full live gate under the developer identity')
    }
    if (-not $Execute -and -not $OfflineTest) { return ,$result }
    if ($null -eq $Adapter) { $Adapter = New-CompletionAdapter }
    Assert-CompletionCondition (-not (& $Adapter.IsSystem)) 'LocalSystem cannot complete a human workspace. Sign in as the developer and perform your own interactive SSO.'
    foreach ($tool in @('git', 'pwsh', 'python', 'az', 'azd')) { $null = & $Adapter.Tool $tool }
    $pwshVersion = & $Adapter.Native 'pwsh' @('--version')
    $pythonVersion = & $Adapter.Native 'python' @('--version')
    Assert-CompletionCondition ($pwshVersion -match '^PowerShell 7\.') 'PowerShell 7 is required.'
    Assert-CompletionCondition ($pythonVersion -match '^Python 3\.13\.') 'Python 3.13 is required for the pinned starter environment.'
    $null = Get-CompletionAccount $Resolution $Adapter -Human
    $exists = Test-Path -LiteralPath $workspace
    if ($exists) {
        Assert-CompletionCondition (Test-Path -LiteralPath $workspace -PathType Container) 'Workspace exists but is not a directory.'
        $gitRoot = (& $Adapter.Native 'git' @('-C', $workspace, 'rev-parse', '--show-toplevel')).Trim()
        Assert-CompletionCondition ([IO.Path]::GetFullPath($gitRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $workspace) 'Workspace must be the actual working-copy root, not a directory inside another checkout.'
        $dirty = & $Adapter.Native 'git' @('-C', $workspace, 'status', '--porcelain=v1', '--untracked-files=all')
        $origin = (& $Adapter.Native 'git' @('-C', $workspace, 'config', '--get', 'remote.origin.url')).Trim()
        $head = (& $Adapter.Native 'git' @('-C', $workspace, 'rev-parse', '--verify', 'HEAD')).Trim()
        Assert-CompletionCondition ([string]::IsNullOrWhiteSpace($dirty) -and $origin -ceq $application.workspaceRepository -and
            $head -ceq $application.workspaceRef) 'Existing workspace is dirty or its origin/ref differs. Preserve it and obtain a manual decision; no fetch, reset, clean or branch change is attempted.'
    }
    else {
        $null = & $Adapter.Native 'git' @('clone', '--no-checkout', '--origin', 'origin', '--', $application.workspaceRepository, $workspace)
        $null = & $Adapter.Native 'git' @('-C', $workspace, 'fetch', '--no-tags', '--depth=1', 'origin', $application.workspaceRef)
        $fetched = (& $Adapter.Native 'git' @('-C', $workspace, 'rev-parse', '--verify', 'FETCH_HEAD')).Trim()
        Assert-CompletionCondition ($fetched -ceq $application.workspaceRef) 'Fetched workspace commit does not match the approved immutable ref.'
        $null = & $Adapter.Native 'git' @('-C', $workspace, 'checkout', '--detach', $application.workspaceRef)
    }
    $sample = Join-Path $workspace 'samples\developer-smoke'
    $lock = Join-Path $sample 'requirements.lock'
    $null = Assert-DeveloperWorkspacePaths $lock $BootstrapCheckoutPath
    Assert-CompletionCondition (Test-Path -LiteralPath $lock -PathType Leaf) 'Selected workspace is missing the pinned starter dependency lock.'
    $venv = Join-Path $sample '.venv'
    $null = Assert-DeveloperWorkspacePaths $venv $BootstrapCheckoutPath
    if (-not (Test-Path -LiteralPath $venv)) {
        $null = & $Adapter.Native 'python' @('-m', 'venv', $venv)
    }
    $venvBin = Join-Path $venv $(if ($IsWindows) { 'Scripts' } else { 'bin' })
    $venvPython = Join-Path $venvBin $(if ($IsWindows) { 'python.exe' } else { 'python' })
    Assert-CompletionCondition ($OfflineTest -or (Test-Path -LiteralPath $venvPython -PathType Leaf)) 'Workspace virtual environment is incomplete; no system-package fallback is allowed.'
    $null = & $Adapter.Native $venvPython @('-m', 'pip', 'install', '--require-hashes', '--only-binary=:all:', '--disable-pip-version-check', '-r', $lock)
    $null = & $Adapter.Native $venvPython @('-m', 'pip', 'check')
    $result.mode = if ($OfflineTest) { 'offline-test' } else { 'executed' }
    $result.workspacePrepared = -not $OfflineTest
    $result.pending = @('Correlated application and full live gate under the developer identity; an Azure login alone does not prove API access')
    return ,$result
}

function New-LiveGateEvidence {
    param([Collections.IDictionary]$Resolution, [string]$ReleaseFingerprint, [long]$WorkflowRunId)
    $pendingDescriptions = @{
        privateConnectivity = 'Pending: approved private DNS, CIDR-pinned TCP/TLS and active application observations have not been made.'
        identityIsolation = 'Pending: human, workload and runner caller separation and direct-backend denial need their respective authorized identity contexts.'
        applicationInference = 'Pending: an allowed developer must produce the required text through a same-request correlated application/APIM invocation.'
        gatewayEnforcement = 'Pending: native rate 429, period-quota 403, Retry-After, stop-new-requests and spoofed metadata enforcement require approved live observations.'
        meteringCoverage = 'Pending: approved concurrency/in-flight accounting remains unobserved; streaming and nontext routes are excluded by the starter.'
        costOperations = 'Pending: owned budget/action-group configuration and actual notification delivery have not been observed.'
        promotionIntegrity = 'Pending: protected approvals and verified same-release prior-environment evidence must be observed by the delivery stage.'
        recovery = 'Pending: known-good image/configuration rollback and non-destructive rerun need separately approved recovery observations.'
        developerWorkspace = 'Pending: the developer-owned workspace, interactive SSO and actual application access require the human context.'
    }
    $checks = @{}
    foreach ($name in $pendingDescriptions.Keys) {
        $checks[$name] = @{ status = 'pending'; evidence = $pendingDescriptions[$name] }
    }
    return @{
        schemaVersion = 1; environment = $Resolution.environment; release = $Resolution.profile.release
        configurationHash = $Resolution.configurationHash; releaseFingerprint = $ReleaseFingerprint
        workflowRunId = $WorkflowRunId; observedAt = $null
        mode = 'plan'; promotionEligible = $false; checks = $checks; probes = @{}
        pending = @(
            'Explicit paid-probe approval and positive request/token ceilings'
            'Private connectivity and correlated application inference/rejection'
            'Direct backend rejection under human, workload and runner identities'
            'Native APIM token-rate 429 and period-quota 403 with Retry-After observations'
            'Approved stop-new-requests control mutation and recovery'
            'Caller separation and spoofed project/model/counter metadata rejection'
            'Concurrency/in-flight accounting; streaming is excluded by the text-only nonstreaming starter'
            'Real notification routing and owned budget/action-group observations'
            'Protected promotion integrity and verified same-release prior-environment evidence'
            'Known-good rollback and non-destructive rerun under separately approved changes'
            'Developer-owned workspace and interactive SSO with actual application access'
        )
    }
}

function Invoke-LiveDeveloperGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Resolution,
        [Parameter(Mandatory)][Collections.IDictionary]$DeploymentOutput,
        [switch]$ExecutePaidProbes, [switch]$OfflineTest,
        [string]$ApprovedEnvironment, [string]$ApprovedSourceSha,
        [int]$MaxRequests, [long]$MaxTotalTokens,
        [ValidateSet('human', 'runner')][string]$IdentityContext = 'human',
        [string]$ReleaseFingerprint, [long]$WorkflowRunId,
        [AllowNull()][Collections.IDictionary]$Adapter
    )
    Assert-CompletionResolution $Resolution $ExecutePaidProbes.IsPresent $OfflineTest.IsPresent $Adapter
    Assert-CompletionOutput $Resolution $DeploymentOutput
    $evidence = New-LiveGateEvidence $Resolution $ReleaseFingerprint $WorkflowRunId
    if (-not $ExecutePaidProbes -and -not $OfflineTest) { return ,$evidence }
    $profile = $Resolution.profile
    $prompt = 'Reply with the word READY.'
    $requestTokenReservation = [Text.Encoding]::UTF8.GetByteCount($prompt) + [long]$profile.application.maxOutputTokens
    Assert-CompletionCondition ($ApprovedEnvironment -ceq $Resolution.environment -and $ApprovedSourceSha -ceq $profile.release.sourceSha) 'Paid probes require explicit approval of this environment and release SHA.'
    Assert-CompletionCondition ($MaxRequests -gt 0 -and $MaxTotalTokens -gt 0 -and $MaxRequests -ge 4 -and
        $MaxTotalTokens -ge 2 * $requestTokenReservation) 'Positive explicit request/token ceilings must cover the selected four HTTP attempts, including a potentially successful bypass. No financial hard-cap claim is made.'
    Assert-CompletionCondition ($ReleaseFingerprint -cmatch '^[0-9a-f]{64}$' -and $WorkflowRunId -gt 0) 'Verified release fingerprint and operator/workflow run identity are required.'
    if ($null -eq $Adapter) { $Adapter = New-CompletionAdapter }
    $account = Get-CompletionAccount $Resolution $Adapter -Human:($IdentityContext -ceq 'human')
    if ($IdentityContext -ceq 'runner') {
        Assert-CompletionCondition ($account.user.type -ceq 'servicePrincipal' -and
            $account.user.name -ceq $profile.identities.deploy.clientId) 'Runner probe identity does not match the approved deployment identity.'
    }
    Assert-CompletionPrivateServices $DeploymentOutput $Adapter
    $privateCidrs = Get-CompletionPrivateCidrs $Resolution $DeploymentOutput $Adapter
    $gateway = & $Adapter.Gateway $Resolution $DeploymentOutput $Adapter.ArmGet
    Assert-CompletionCondition ($gateway.privateReady -eq $true) 'Gateway private readiness is required before paid probes.'
    Test-CompletionPrivateEndpoints $DeploymentOutput $privateCidrs $Adapter
    $null = Get-CompletionApplicationEvidence $Resolution $DeploymentOutput $privateCidrs $Adapter
    $evidence.checks.privateConnectivity = @{ status = 'passed'; evidence = 'Same-invocation approved private DNS, pinned TCP/TLS and application revision observations.' }
    $appUri = [uri]"https://$($DeploymentOutput.applications[0].fqdn)/infer"
    $attempts = 0
    foreach ($kind in @('unauthenticated', 'invalidToken')) {
        $correlation = [guid]::NewGuid().ToString()
        $headers = @{ 'x-correlation-id' = $correlation }
        if ($kind -ceq 'invalidToken') { $headers.Authorization = 'Bearer deliberately-invalid' }
        $attempts++
        $response = Invoke-CompletionHttp 'POST' $appUri $headers @{ input = $prompt } $privateCidrs $Adapter
        Assert-CompletionCondition ($response.statusCode -eq 401 -and
            $response.headers['x-correlation-id'] -ceq $correlation) 'Invalid or unauthenticated caller was not rejected with matching correlation.'
        $evidence.probes[$kind] = @{ status = 'passed'; evidence = @{ correlationId = $correlation; statusCode = $response.statusCode } }
    }
    $appToken = & $Adapter.Token $profile.application.audience
    $correlation = [guid]::NewGuid().ToString()
    $attempts++
    $response = Invoke-CompletionHttp 'POST' $appUri @{ Authorization = "Bearer $appToken"; 'x-correlation-id' = $correlation } @{ input = $prompt } $privateCidrs $Adapter
    $spent = 0L
    if ($IdentityContext -ceq 'runner') {
        Assert-CompletionCondition ($response.statusCode -eq 403 -and
            $response.headers['x-correlation-id'] -ceq $correlation) 'The deployment runner must not be accepted as an allowed developer caller.'
        $evidence.probes.applicationForbiddenRunner = @{ status = 'passed'; evidence = @{ correlationId = $correlation; statusCode = 403 } }
    }
    else {
        Assert-CompletionHttpStatus $response @(200) 'Positive application inference'
        Assert-CompletionCondition ($response.headers['x-correlation-id'] -ceq $correlation -and
            $response.headers.Contains('apim-request-id') -and -not [string]::IsNullOrWhiteSpace($response.headers['apim-request-id']) -and
            $response.body -is [Collections.IDictionary] -and $response.body.object -ceq 'response' -and
            $response.body.status -ceq 'completed' -and $response.body.output.Count -gt 0 -and
            $response.body.usage.total_tokens -gt 0 -and $response.body.usage.total_tokens -le $MaxTotalTokens -and
            $response.body.usage.output_tokens -le $profile.application.maxOutputTokens) 'Positive application inference lacks same-request gateway correlation, supported output or bounded token usage.'
        $text = [Collections.Generic.List[string]]::new()
        foreach ($item in $response.body.output) {
            if ($item.type -ceq 'message') {
                foreach ($content in $item.content) {
                    if ($content.type -ceq 'output_text' -and $content.text -is [string]) { $text.Add($content.text) }
                }
            }
        }
        Assert-CompletionCondition (($text -join '').Trim() -ceq 'READY') 'Positive application probe did not produce its required text outcome.'
        $spent = [long]$response.body.usage.total_tokens
        $evidence.probes.applicationInference = @{ status = 'passed'; evidence = @{ correlationId = $correlation; gatewayRequestId = $response.headers['apim-request-id']; statusCode = 200; totalTokens = $spent } }
        $evidence.checks.applicationInference = @{ status = 'passed'; evidence = "Correlation $correlation; APIM $($response.headers['apim-request-id']); required text and token usage observed, content not retained." }
    }
    Assert-CompletionCondition ($attempts -lt $MaxRequests -and $spent + $requestTokenReservation -le $MaxTotalTokens) 'Insufficient remaining explicit budget for the negative bypass probe.'
    $backendToken = & $Adapter.Token 'https://cognitiveservices.azure.com'
    $correlation = [guid]::NewGuid().ToString()
    $backendUri = [uri]($DeploymentOutput.gateway.backendEndpoint.TrimEnd('/') + '/openai/v1/responses')
    $attempts++
    $response = Invoke-CompletionHttp 'POST' $backendUri @{ Authorization = "Bearer $backendToken"; 'x-correlation-id' = $correlation } @{
        input = $prompt; model = $profile.application.modelDeployment; max_output_tokens = $profile.application.maxOutputTokens
        stream = $false; store = $false
    } $privateCidrs $Adapter
    Assert-CompletionCondition ($response.statusCode -eq 403) 'Direct backend bypass was not denied with authorization failure. Stop; do not treat a 401, model error or successful inference as bypass protection.'
    $name = if ($IdentityContext -ceq 'human') { 'directBackendHuman' } else { 'directBackendRunner' }
    $evidence.probes[$name] = @{ status = 'passed'; evidence = @{ correlationId = $correlation; statusCode = 403; identityContext = $IdentityContext } }
    $evidence.mode = if ($OfflineTest) { 'offline-test' } else { 'observed-live-partial' }
    if ($OfflineTest) {
        foreach ($check in $evidence.checks.Values) {
            if ($check.status -ceq 'passed') {
                $check.status = 'pending'
                $check.evidence = 'Pending live observation; only a synthetic local simulation exercised this check.'
            }
        }
    }
    else { $evidence.observedAt = [DateTimeOffset]::UtcNow.ToString('o') }
    $evidence.requestAttempts = $attempts
    $evidence.observedApplicationTokens = $spent
    $evidence.budget = @{ maxRequests = $MaxRequests; maxTotalTokens = $MaxTotalTokens; maxOutputTokensPerRequest = $profile.application.maxOutputTokens; currencyCap = $false }
    $evidence.pending = @($evidence.pending | Select-Object -Skip 2)
    if ($OfflineTest) { $evidence.pending += 'Private connectivity and application behavior have only synthetic local observations, not live evidence.' }
    if ($IdentityContext -ceq 'runner') { $evidence.pending += 'Positive application inference under the separately signed-in allowed developer identity' }
    $evidence.coverage = @{ streaming = 'excluded: starter rejects streaming, tools, image/audio, background and conversation references'; concurrency = 'pending: approved in-flight/native quota observation required' }
    # These observations cannot authorize controls, impersonate another identity, or
    # authenticate an operator-supplied boolean/file. The complete gate remains pending.
    $evidence.promotionEligible = $false
    return ,$evidence
}

Export-ModuleMember -Function Read-DeveloperCompletionOutput, Invoke-DeveloperCompletion, Invoke-DeveloperWorkspace, Invoke-LiveDeveloperGate
