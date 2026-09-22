#Requires -Version 7.0
[CmdletBinding()]
param([string]$TemplatePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts\github\Gateway.psm1') -Force
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected a failure.'
    Assert-True ($caught.Exception.Message -like $Pattern) "Unexpected failure; expected $Pattern"
}
function Invoke-Bicep {
    param([string[]]$Arguments)
    & bicep @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Gateway test Bicep compilation failed.' }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ailz-gateway-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $profile = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
    $workloadKey = $profile.gateway.workloadKey
    $owner = "ailz-inference-dev-$workloadKey"
    $apiPath = "inference/$workloadKey"
    $serviceId = "$($profile.identities.workload.resourceId -replace '/providers/.*$','')/providers/Microsoft.ApiManagement/service/synthetic-governed-gateway"
    $peId = ($serviceId -replace '/providers/.*$', '') + '/providers/Microsoft.Network/privateEndpoints/synthetic-governed-gateway-inbound'
    $backendId = ($serviceId -replace '/providers/.*$', '') + '/providers/Microsoft.CognitiveServices/accounts/synthetic-foundry'
    $backendEndpoint = 'https://synthetic-foundry.openai.azure.com/'
    Assert-GatewayConfiguration -Profile $profile -ServiceName $profile.gateway.name -BackendAccountResourceId $backendId -BackendEndpoint $backendEndpoint -AllowSynthetic
    $guidAudience = '00000000-0000-4000-8000-000000000072'
    $guidProfile = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
    $guidProfile.gateway.audience = $guidAudience
    Assert-GatewayConfiguration -Profile $guidProfile -ServiceName $guidProfile.gateway.name -BackendAccountResourceId $backendId -BackendEndpoint $backendEndpoint -AllowSynthetic
    foreach ($badEndpoint in @('http://synthetic-foundry.openai.azure.com/', 'https://example.invalid/', 'https://synthetic-foundry.openai.azure.com/openai', 'https://synthetic-foundry.openai.azure.com/?api-key=TEST', 'https://other-foundry.openai.azure.com/', 'https://synthetic-foundry.openai.azure.com:8443/')) {
        Assert-Throws { Assert-GatewayConfiguration -Profile $profile -ServiceName $profile.gateway.name -BackendAccountResourceId $backendId -BackendEndpoint $badEndpoint -AllowSynthetic } '*backend*'
    }
    foreach ($mutation in @(
        { param($p) $p.gateway.callerMappings[0].Remove('tokensPerMinute') },
        { param($p) $p.gateway.callerMappings[0].tokenQuota = 0 },
        { param($p) $p.gateway.callerMappings += $p.gateway.callerMappings[0] },
        { param($p) $p.gateway.foundryIntegration = $true },
        { param($p) $p.gateway.name = 'invalid_gateway_name' }
    )) {
        $bad = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
        & $mutation $bad
        Assert-Throws { Assert-GatewayConfiguration -Profile $bad -ServiceName $bad.gateway.name -BackendAccountResourceId $backendId -BackendEndpoint $backendEndpoint -AllowSynthetic }
    }
    $large = & (Join-Path $PSScriptRoot 'New-SyntheticProfile.ps1')
    for ($i = 100; $i -lt 130; $i++) {
        $id = '00000000-0000-4000-8000-' + $i.ToString('D12')
        $mapping = $large.gateway.callerMappings[0].Clone()
        $mapping.objectId = $id
        $large.gateway.callerMappings += $mapping
        $large.identities.developerObjectIds += $id
    }
    $large.governance.inferenceAllowance.allocatedTokens = 32000
    Assert-Throws { Assert-GatewayConfiguration -Profile $large -ServiceName $large.gateway.name -BackendAccountResourceId $backendId -BackendEndpoint $backendEndpoint -AllowSynthetic } '*named-value*'
    # workloadKey is lifted out of the gateway block before it reaches the sealed
    # Bicep gatewayConfiguration type, exactly as Get-ComposedParameterValues does.
    $gatewayConfiguration = [ordered]@{}
    foreach ($key in $profile.gateway.Keys) {
        if ($key -ceq 'workloadKey') { continue }
        $gatewayConfiguration[$key] = $profile.gateway[$key]
    }
    $gatewayConfiguration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $scratch 'gateway.json')
    $policyFile = [IO.Path]::GetRelativePath($scratch, (Join-Path $root 'modules\api-management\policy.bicep')).Replace('\', '/')
    $parametersFile = Join-Path $scratch 'policy.bicepparam'
    @"
using none
import { renderPolicy, gatewayNamedValues } from '$policyFile'
var configuration = loadJsonContent('./gateway.json')
param policy = renderPolicy('$owner', '$apiPath', configuration.callerMappings)
param namedValues = gatewayNamedValues('$owner', 'dev', '$($profile.azure.tenantId)', configuration, '$backendEndpoint', false)
param guidNamedValues = gatewayNamedValues('$owner', 'dev', '$($profile.azure.tenantId)', union(configuration, { audience: '$guidAudience' }), '$backendEndpoint', false)
param initialNamedValues = gatewayNamedValues('$owner', 'dev', '$($profile.azure.tenantId)', configuration, '$backendEndpoint', true)
param stoppedNamedValues = gatewayNamedValues('$owner', 'dev', '$($profile.azure.tenantId)', union(configuration, { stopNewRequests: true }), '$backendEndpoint', false)
"@ | Set-Content -LiteralPath $parametersFile
    Invoke-Bicep @('build-params', $parametersFile, '--outfile', (Join-Path $scratch 'policy.parameters.json'))
    $rendered = Get-Content -LiteralPath (Join-Path $scratch 'policy.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
    $guidNamedValue = @($rendered.parameters.guidNamedValues.value | Where-Object displayName -CEQ "$owner-audience")[0]
    Assert-True ($guidNamedValue.value -ceq $guidAudience) 'The exact GUID audience was rewritten or widened.'
    Assert-True (@($rendered.parameters.initialNamedValues.value | Where-Object displayName -CEQ "$owner-stop")[0].value -ceq 'true') 'Initial provisioning must force new requests stopped.'
    Assert-True (@($rendered.parameters.stoppedNamedValues.value | Where-Object displayName -CEQ "$owner-stop")[0].value -ceq 'true') 'A steady deployment must preserve the approved stop setting.'
    Assert-True (@($rendered.parameters.namedValues.value | Where-Object displayName -CEQ "$owner-stop")[0].value -ceq 'false') 'A private steady deployment must honor the approved resume setting.'
    $xmlText = $rendered.parameters.policy.value
    foreach ($value in $rendered.parameters.namedValues.value) {
        $xmlText = $xmlText.Replace(('{{' + $value.displayName + '}}'), [Security.SecurityElement]::Escape([string]$value.value))
    }
    Assert-True ($xmlText -notmatch '__[A-Z_]+__|\{\{') 'Unresolved generated policy placeholder.'
    [xml]$policy = $xmlText
    Assert-True ($policy.policies.inbound.'validate-azure-ad-token'.'tenant-id' -ceq $profile.azure.tenantId) 'Tenant validation drift.'
    Assert-True ($policy.policies.inbound.'validate-azure-ad-token'.audiences.audience -ceq $profile.gateway.audience) 'Audience validation drift.'
    Assert-True ($policy.policies.inbound.'validate-azure-ad-token'.'required-claims'.claim.name -ceq 'tid') 'The tenant claim must also be required.'
    Assert-True ($policy.SelectNodes('//base').Count -eq 0) 'The dedicated owned API must not inherit unknown logging/routing policies.'
    Assert-True ($policy.SelectNodes('//llm-token-limit').Count -eq $profile.gateway.callerMappings.Count) 'Each caller needs an explicit native rate and quota.'
    $limitIndex = 0
    foreach ($limit in $policy.SelectNodes('//llm-token-limit')) {
        Assert-True ([long]$limit.'tokens-per-minute' -gt 0 -and [long]$limit.'token-quota' -gt 0) 'Unlimited caller.'
        Assert-True ([long]$limit.'tokens-per-minute' -eq $profile.gateway.callerMappings[$limitIndex].tokensPerMinute -and [long]$limit.'token-quota' -eq $profile.gateway.callerMappings[$limitIndex].tokenQuota) 'Native limits differ from the approved values.'
        Assert-True ($limit.'token-quota-period' -cin @('Hourly', 'Daily', 'Weekly', 'Monthly', 'Yearly')) 'Invalid quota period.'
        Assert-True ($limit.'estimate-prompt-tokens' -ceq 'true') 'Prompt estimation is required.'
        Assert-True (-not $limit.HasAttribute('retry-after-header-name')) 'Do not rename the native Retry-After header.'
        $limitIndex++
    }
    Assert-True ($policy.SelectNodes('//llm-emit-token-metric/dimension').Count -eq 4) 'Token metrics must use bounded environment/caller/project/model dimensions, not correlation IDs.'
    Assert-True ($policy.policies.inbound.'authentication-managed-identity'.resource -ceq 'https://cognitiveservices.azure.com') 'Wrong backend identity audience.'
    Assert-True ($policy.policies.backend.'forward-request'.'buffer-response' -ceq 'false') 'Streaming must not be buffered.'
    Assert-True ($policy.policies.backend.'forward-request'.'fail-on-error-status-code' -ceq 'false') 'Backend failures must retain their status and headers.'
    Assert-True ($policy.SelectNodes('//on-error//return-response').Count -eq 0) 'Native quota/rate failures must not be translated.'
    Assert-True ($policy.SelectNodes('//trace//metadata[@name="authorization" or @name="prompt" or @name="completion"]').Count -eq 0) 'Sensitive telemetry field.'

    # Compile the actual generated C# expressions, not a second PowerShell authorizer.
    $expressions = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($node in $policy.SelectNodes('//@*|//set-body|//value|//message')) {
        $text = if ($node -is [Xml.XmlAttribute]) { $node.Value } else { $node.InnerText }
        if ($text.StartsWith('@(') -or $text.StartsWith('@{')) {
            if (-not $expressions.ContainsKey($text)) { $expressions.Add($text, "E$($expressions.Count)") }
        }
    }
    $methods = foreach ($entry in $expressions.GetEnumerator()) {
        $body = if ($entry.Key.StartsWith('@{')) { $entry.Key.Substring(2, $entry.Key.Length - 3) } else { 'return ' + $entry.Key.Substring(2, $entry.Key.Length - 3) + ';' }
        "public static object $($entry.Value)(Context context) { $body }"
    }
    $source = @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
namespace P3GatewayTests {
    public sealed class Jwt { public Dictionary<string,string[]> Claims = new Dictionary<string,string[]>(); }
    public sealed class Body {
        public string Text;
        public T As<T>(bool preserveContent = false) {
            if (typeof(T) == typeof(string)) return (T)(object)Text;
            return JsonConvert.DeserializeObject<T>(Text);
        }
    }
    public sealed class Url {
        public string Path = "__API_PATH__";
        public string QueryString = "";
    }
    public sealed class Request {
        public Body Body = new Body();
        public Url Url = new Url();
        public Url OriginalUrl = new Url();
        public string Method = "POST";
        public string IpAddress = "192.0.2.10";
        public object PrivateEndpointConnection = new object();
        public Dictionary<string,string[]> Headers = new Dictionary<string,string[]>(StringComparer.OrdinalIgnoreCase);
    }
    public sealed class Response {
        public int StatusCode = 200;
        public Dictionary<string,string[]> Headers = new Dictionary<string,string[]>(StringComparer.OrdinalIgnoreCase);
    }
    public sealed class Error { public string Reason = "TokenLimitExceeded"; public string Source = "llm-token-limit"; }
    public sealed class Context {
        public Guid RequestId = Guid.Parse("00000000-0000-4000-8000-000000000071");
        public Request Request = new Request();
        public Response Response = new Response();
        public Error LastError = new Error();
        public Dictionary<string,object> Variables = new Dictionary<string,object>();
        public bool Forwarded;
        public bool IdentityUsed;
        public bool ValidToken = true;
        public int NativeFailure;
        public int BackendStatus = 200;
        public string Counter;
        public List<string> TraceMetadata = new List<string>();
    }
    public static class Extensions {
        public static string GetValueOrDefault(this Dictionary<string,string[]> values, string key, string fallback) {
            return values.ContainsKey(key) ? string.Join(",",values[key]) : fallback;
        }
        public static T GetValueOrDefault<T>(this Dictionary<string,object> values, string key, T fallback) {
            return values.ContainsKey(key) ? (T)values[key] : fallback;
        }
    }
    public static class Expressions {
'@ + ($methods -join "`n") + "`n}}"
    $source = $source.Replace('__API_PATH__', "/$apiPath/v1/responses")
    $references = @([Newtonsoft.Json.Linq.JObject].Assembly.Location)
    $references += Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | Select-Object -ExpandProperty FullName
    # PowerShell's bundled Newtonsoft targets an older runtime than the host reference assemblies.
    Add-Type -TypeDefinition $source -ReferencedAssemblies $references -CompilerOptions '/nowarn:1701'
    function Get-PolicyValue {
        param([string]$Value, $Context)
        if ($expressions.ContainsKey($Value)) {
            return [P3GatewayTests.Expressions].GetMethod($expressions[$Value]).Invoke($null, @($Context))
        }
        return $Value
    }
    function Invoke-PolicyNodes {
        param($Nodes, $Context)
        foreach ($node in $Nodes) {
            if ($node -isnot [Xml.XmlElement]) { continue }
            switch ($node.LocalName) {
                'set-variable' { $Context.Variables[$node.GetAttribute('name')] = Get-PolicyValue $node.GetAttribute('value') $Context }
                'choose' {
                    foreach ($branch in $node.ChildNodes) {
                        if ($branch.LocalName -eq 'otherwise' -or ($branch.LocalName -eq 'when' -and (Get-PolicyValue $branch.GetAttribute('condition') $Context))) {
                            if (Invoke-PolicyNodes $branch.ChildNodes $Context) { return $true }
                            break
                        }
                    }
                }
                'validate-azure-ad-token' {
                    $jwt = $Context.Variables['validated-jwt']
                    if (-not $Context.ValidToken -or $jwt.Claims['tid'][0] -cne $node.'tenant-id') {
                        $Context.Response.StatusCode = 401
                        [void](Invoke-PolicyNodes $policy.policies.'on-error'.ChildNodes $Context)
                        return $true
                    }
                }
                'return-response' {
                    $Context.Response.StatusCode = [int]$node.SelectSingleNode('set-status').GetAttribute('code')
                    foreach ($header in $node.SelectNodes('set-header')) {
                        $Context.Response.Headers[$header.GetAttribute('name')] = @([string](Get-PolicyValue $header.SelectSingleNode('value').InnerText $Context))
                    }
                    return $true
                }
                'set-header' {
                    if ($node.GetAttribute('exists-action') -eq 'delete') { [void]$Context.Request.Headers.Remove($node.GetAttribute('name')) }
                    else { $Context.Request.Headers[$node.GetAttribute('name')] = @([string](Get-PolicyValue $node.SelectSingleNode('value').InnerText $Context)) }
                }
                'set-body' { $Context.Request.Body.Text = [string](Get-PolicyValue $node.InnerText $Context) }
                'trace' {
                    foreach ($metadata in $node.SelectNodes('metadata')) { $Context.TraceMetadata.Add("$($metadata.GetAttribute('name'))=$(Get-PolicyValue $metadata.GetAttribute('value') $Context)") }
                }
                'llm-token-limit' {
                    $Context.Counter = [string](Get-PolicyValue $node.'counter-key' $Context)
                    if ($Context.NativeFailure) {
                        $Context.Response.StatusCode = $Context.NativeFailure
                        $Context.Response.Headers['Retry-After'] = @('17')
                        [void](Invoke-PolicyNodes $policy.policies.'on-error'.ChildNodes $Context)
                        return $true
                    }
                }
                'authentication-managed-identity' { $Context.IdentityUsed = $true; $Context.Request.Headers['Authorization'] = @('TEST-BACKEND-IDENTITY-NOT-A-TOKEN') }
                'forward-request' {
                    $Context.Forwarded = $true
                    $Context.Response.StatusCode = $Context.BackendStatus
                    if ($Context.BackendStatus -in @(403, 429)) { $Context.Response.Headers['Retry-After'] = @('23') }
                }
                { $_ -in @('llm-emit-token-metric', 'set-backend-service', 'rewrite-uri') } {}
                default { throw "Unimplemented test interpreter node: $($node.LocalName)" }
            }
        }
        return $false
    }
    function New-Context {
        param([string]$ObjectId = $profile.gateway.callerMappings[0].objectId)
        $c = [P3GatewayTests.Context]::new()
        $c.Request.Body.Text = '{"model":"synthetic-chat","input":"TEST-PRIVATE-PROMPT-DO-NOT-LOG","max_output_tokens":16}'
        $c.Request.Headers['Content-Type'] = @('application/json')
        $c.Request.Headers['Authorization'] = @('TEST-CLIENT-CREDENTIAL-DO-NOT-LOG')
        $jwt = [P3GatewayTests.Jwt]::new()
        $jwt.Claims['oid'] = @($ObjectId)
        $jwt.Claims['tid'] = @($profile.azure.tenantId)
        $c.Variables['validated-jwt'] = $jwt
        return $c
    }
    function Invoke-Request {
        param($Context)
        if (-not (Invoke-PolicyNodes $policy.policies.inbound.ChildNodes $Context)) {
            [void](Invoke-PolicyNodes $policy.policies.backend.ChildNodes $Context)
            [void](Invoke-PolicyNodes $policy.policies.outbound.ChildNodes $Context)
        }
        return $Context
    }
    $valid = Invoke-Request (New-Context)
    Assert-True ($valid.Forwarded -and $valid.IdentityUsed) 'An approved private text request did not reach the identity-backed backend.'
    Assert-True ($valid.Counter -match [regex]::Escape($profile.azure.tenantId) -and $valid.Counter -match [regex]::Escape($profile.gateway.callerMappings[0].objectId)) 'Counter is not derived from validated tenant and OID.'
    Assert-True ($valid.Counter -match 'dev.*synthetic-project.*synthetic-chat|dev.*synthetic-chat.*synthetic-project') 'Counter must isolate environment/project/model.'
    Assert-True (($valid.Request.Body.Text | ConvertFrom-Json).store -eq $false) 'Backend persistence must be explicitly off.'
    $other = Invoke-Request (New-Context $profile.gateway.callerMappings[1].objectId)
    Assert-True ($other.Forwarded -and $other.Counter -cne $valid.Counter) 'Caller counters were shared.'

    $spoofed = New-Context
    foreach ($header in @('api-key', 'x-project-id', 'x-ms-project-name', 'x-caller-id', 'x-model', 'x-backend-url', 'x-stop-new-requests', 'Ocp-Apim-Subscription-Key', 'x-correlation-id', 'Host', 'X-Forwarded-For')) {
        $spoofed.Request.Headers[$header] = @('TEST-SPOOF-DO-NOT-LOG')
    }
    $spoofed = Invoke-Request $spoofed
    Assert-True ($spoofed.Forwarded -and $spoofed.Counter -ceq $valid.Counter) 'Caller metadata changed authorization/counter or the configured stop switch.'
    foreach ($header in @('api-key', 'x-project-id', 'x-ms-project-name', 'x-caller-id', 'x-model', 'x-backend-url', 'x-stop-new-requests', 'Ocp-Apim-Subscription-Key')) {
        Assert-True (-not $spoofed.Request.Headers.ContainsKey($header)) 'A caller routing or credential header reached the backend.'
    }
    Assert-True ($spoofed.Request.Headers['x-correlation-id'][0] -ceq $spoofed.RequestId.ToString()) 'Correlation trusted a caller header.'
    Assert-True ($spoofed.Request.Headers['Host'][0] -ceq 'synthetic-foundry.openai.azure.com') 'Caller Host controlled backend routing.'
    Assert-True ($spoofed.Request.Headers['X-Forwarded-For'][0] -ceq $spoofed.Request.IpAddress) 'Caller-supplied forwarding metadata survived normalization.'
    Assert-True (($spoofed.TraceMetadata -join "`n") -notmatch 'TEST-(PRIVATE|CLIENT|SPOOF|BACKEND)') 'A transcript contains request content or a credential.'

    $badBodies = @(
        '{"model":"synthetic-chat-evil","input":"x","max_output_tokens":1}',
        '{"model":"SYNTHETIC-CHAT","input":"x","max_output_tokens":1}',
        '{"model":"synthetic-chat","input":[{"type":"input_image","image_url":"https://example.invalid"}],"max_output_tokens":1}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":0}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1000000}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":"1"}',
        '{"model":"synthetic-chat","input":"x"}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"store":true}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"stream":"true"}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"tools":[]}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"background":false}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"previous_response_id":"other-caller"}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"conversation":"other-caller"}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"modalities":["audio"]}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"batch":true}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"response_format":{"type":"image"}}',
        '{"model":"synthetic-chat","input":"x","max_output_tokens":1,"tool_choice":"auto"}',
        '[]', 'null', '{broken'
    )
    foreach ($body in $badBodies) {
        $c = New-Context
        $c.Request.Body.Text = $body
        $c = Invoke-Request $c
        Assert-True (-not $c.Forwarded -and -not $c.IdentityUsed -and $c.Response.StatusCode -in @(400, 403)) 'Unapproved body reached inference.'
    }
    foreach ($mutation in @(
        { param($c) $c.Request.PrivateEndpointConnection = $null },
        { param($c) $c.Request.Method = 'GET' },
        { param($c) $c.Request.Url.Path = "/$apiPath/v1/chat/completions" },
        # A sibling landing zone's route on the same shared gateway must not be
        # accepted by this landing zone's policy.
        { param($c) $c.Request.Url.Path = '/inference/otherlz02/v1/responses' },
        { param($c) $c.Request.Url.Path = '/inference/v1/responses' },
        { param($c) $c.Request.Url.QueryString = '?api-key=TEST-DO-NOT-LOG' },
        { param($c) $c.Request.Headers['x-arbitrary-routing-override'] = @('evil') },
        { param($c) $c.Variables['validated-jwt'].Claims['oid'] = @('untrusted') },
        { param($c) $c.Variables['validated-jwt'].Claims['oid'] = @('00000000-0000-4000-8000-000000000099') },
        { param($c) $c.Variables['validated-jwt'].Claims['tid'] = @('00000000-0000-4000-8000-000000000098') },
        { param($c) $c.ValidToken = $false }
    )) {
        $c = New-Context
        & $mutation $c
        $c = Invoke-Request $c
        Assert-True (-not $c.Forwarded -and -not $c.IdentityUsed) 'An unauthorized route, caller, network, or header reached inference.'
    }
    $streaming = New-Context
    $streaming.Request.Body.Text = '{"model":"synthetic-chat","input":"text","max_output_tokens":16,"stream":true}'
    Assert-True ((Invoke-Request $streaming).Forwarded) 'Approved text streaming must remain a supported, live-validation-pending path.'
    foreach ($code in @(403, 429)) {
        $c = New-Context
        $c.NativeFailure = $code
        $c = Invoke-Request $c
        Assert-True (-not $c.Forwarded -and $c.Response.StatusCode -eq $code -and $c.Response.Headers['Retry-After'][0] -ceq '17') 'Native quota/rate semantics were rewritten.'
        $c = New-Context
        $c.BackendStatus = $code
        $c = Invoke-Request $c
        Assert-True ($c.Response.StatusCode -eq $code -and $c.Response.Headers['Retry-After'][0] -ceq '23') 'Backend rejection semantics were rewritten.'
    }
    $stopNode = $policy.SelectSingleNode('//set-variable[@name="stop-new-requests"]')
    $priorStop = $stopNode.value
    $stopNode.value = 'true'
    $stopped = Invoke-Request (New-Context)
    Assert-True (-not $stopped.Forwarded -and -not $stopped.IdentityUsed -and $stopped.Response.StatusCode -eq 503) 'The owned stop switch did not prevent new inference.'
    $stopNode.value = $priorStop
    $configurationNode = $policy.SelectSingleNode('//set-variable[@name="configuration"]')
    $priorConfiguration = $configurationNode.value
    foreach ($mutation in @(
        { param($c) $c.callerMappings[0].Remove('tokensPerMinute') },
        { param($c) $c.callerMappings[0].tokensPerMinute = 0 },
        { param($c) $c.callerMappings[0].tokenQuota = 0 },
        { param($c) $c.callerMappings += $c.callerMappings[0] }
    )) {
        $settings = @{ environment = 'dev'; tenantId = $profile.azure.tenantId; callerMappings = ($profile.gateway.callerMappings | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable) }
        & $mutation $settings
        $configurationNode.value = $settings | ConvertTo-Json -Depth 30 -Compress
        $c = Invoke-Request (New-Context)
        Assert-True (-not $c.Forwarded -and -not $c.IdentityUsed -and $c.Response.StatusCode -eq 403) 'A missing/zero/ambiguous named-value limit bypassed authorization.'
    }
    $configurationNode.value = $priorConfiguration

    $arm = @{
        calls = [Collections.Generic.List[object]]::new()
        state = 'Absent'
        approvedPe = $true
        conflicts = 0
        ownerTag = $owner
        children = @{}
        peTarget = $serviceId
        peCollision = $false
        namedValueEtag = 'version-1'
        managedBy = 'github-dev-environment'
        environment = 'dev'
        provisioningState = 'Succeeded'
        stopValue = 'true'
        stopConflicts = 0
        stopSecret = $false
        failure = 0
    }
    $request = {
        param($Method, $Uri, $Body, $Headers)
        $arm.calls.Add(@{ method = $Method; uri = $Uri; body = $Body; headers = $Headers; state = $arm.state })
        if ($arm.failure) { return @{ StatusCode = $arm.failure; Body = @{}; Headers = @{} } }
        if ($Method -eq 'POST' -and $Uri -match "/namedValues/$owner-stop/listValue\?") {
            return @{ StatusCode = 200; Headers = @{ ETag = $arm.namedValueEtag }; Body = @{ value = $arm.stopValue } }
        }
        if ($Method -eq 'PATCH' -and $Uri -match "/namedValues/$owner-stop\?") {
            if ($arm.stopConflicts -gt 0) {
                $arm.stopConflicts--
                $arm.namedValueEtag += '-conflict'
                return @{ StatusCode = 412; Headers = @{}; Body = @{} }
            }
            if ($Headers['If-Match'] -cne $arm.namedValueEtag) { return @{ StatusCode = 412; Headers = @{}; Body = @{} } }
            $arm.stopValue = $Body.properties.value
            $arm.namedValueEtag += '-updated'
            return @{ StatusCode = 200; Headers = @{ ETag = $arm.namedValueEtag }; Body = @{} }
        }
        if ($Method -eq 'PATCH') {
            if ($arm.conflicts -gt 0) { $arm.conflicts--; return @{ StatusCode = 409; Body = @{}; Headers = @{} } }
            $arm.state = 'Private'
            return @{ StatusCode = 202; Body = @{}; Headers = @{} }
        }
        if ($Uri -like '*Microsoft.Network/privateEndpoints/*') {
            if ($arm.state -eq 'Absent' -and -not $arm.peCollision) { return @{ StatusCode = 404; Body = @{ error = @{ code = 'ResourceNotFound' } }; Headers = @{} } }
            return @{ StatusCode = 200; Headers = @{}; Body = @{
                id = $peId; tags = @{ 'ailz-managed-by' = $arm.managedBy; 'ailz-environment' = $arm.environment }; properties = @{
                    provisioningState = 'Succeeded'
                    privateLinkServiceConnections = @(@{ properties = @{
                        privateLinkServiceId = $arm.peTarget; groupIds = @('Gateway')
                        privateLinkServiceConnectionState = @{ status = $(if ($arm.approvedPe) { 'Approved' } else { 'Pending' }) }
                    } })
                }
            } }
        }
        if ($Uri -match "/namedValues/$owner-stop\?") {
            return @{ StatusCode = 200; Headers = @{ ETag = $arm.namedValueEtag }; Body = @{
                id = "$serviceId/namedValues/$owner-stop"
                name = "$owner-stop"
                properties = @{ displayName = "$owner-stop"; tags = @($owner); secret = $arm.stopSecret; provisioningState = 'Succeeded' }
            } }
        }
        if ($Uri -match '/(apis|backends|namedValues|loggers)(\?|/)') {
            $collection = $Matches[1]
            $items = if ($arm.children.Contains($collection)) { $arm.children[$collection] } else { @() }
            return @{ StatusCode = 200; Body = @{ value = @($items) }; Headers = @{} }
        }
        if ($arm.state -eq 'Absent') { return @{ StatusCode = 404; Body = @{ error = @{ code = 'ResourceNotFound' } }; Headers = @{} } }
        $serviceTags = @{ 'ailz-managed-by' = $arm.managedBy; 'ailz-environment' = $arm.environment; unrelated = 'preserve' }
        if ($null -ne $arm.ownerTag) { $serviceTags['ailz-owner'] = $arm.ownerTag }
        return @{ StatusCode = 200; Headers = @{}; Body = @{
            id = $serviceId; tags = $serviceTags
            properties = @{
                provisioningState = $arm.provisioningState
                publicNetworkAccess = $(if ($arm.state -eq 'Private') { 'Disabled' } else { 'Enabled' })
                privateEndpointConnections = @(@{ properties = @{
                    privateEndpoint = @{ id = $peId }
                    privateLinkServiceConnectionState = @{ status = $(if ($arm.approvedPe) { 'Approved' } else { 'Pending' }) }
                } })
            }
        } }
    }.GetNewClosure()
    $plan = Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request
    Assert-True ($plan.initialProvisioning -and $plan.observedState -ceq 'Absent') 'Initial public creation must require observed absence.'
    $arm.peCollision = $true
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*private endpoint*'
    $arm.peCollision = $false
    Assert-GatewayDeploymentPlan -Plan $plan -Request $request
    Assert-True ($arm.calls.Count -gt 0 -and @($arm.calls | Where-Object method -ne GET).Count -eq 0) 'Planning did not exclusively read actual mocked ARM state.'
    $arm.state = 'Public'
    Assert-Throws { Assert-GatewayDeploymentPlan -Plan $plan -Request $request } '*stale*'
    $publicApproved = Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request
    Assert-True (-not $publicApproved.initialProvisioning -and $publicApproved.observedState -ceq 'PublicPendingDisable') 'Public with an approved PE must disable without initial=true.'
    $arm.approvedPe = $false
    $interrupted = Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request
    Assert-True ($interrupted.initialProvisioning -and $interrupted.observedState -ceq 'PublicPendingPrivateEndpoint') 'Owned already-public interrupted creation must preserve Enabled, not require deletion.'
    Assert-GatewayDeploymentPlan -Plan $interrupted -Request $request
    $arm.provisioningState = 'Failed'
    Assert-True ((Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request).initialProvisioning) 'An owned failed first creation must be recoverable without reopening a private service.'
    $arm.provisioningState = 'Succeeded'
    $arm.approvedPe = $true
    Assert-Throws { Assert-GatewayDeploymentPlan -Plan $interrupted -Request $request } '*stale*'
    $arm.calls.Clear()
    Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request | Out-Null
    Assert-True (@($arm.calls | Where-Object method -eq PATCH).Count -eq 0) 'Completion without explicit Apply made a write.'
    Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -WhatIf | Out-Null
    Assert-True (@($arm.calls | Where-Object method -eq PATCH).Count -eq 0) 'WhatIf made an ARM write.'
    $arm.approvedPe = $false
    Assert-Throws { Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -MaxAttempts 2 -RetryDelaySeconds 0 } '*private endpoint*'
    Assert-True (@($arm.calls | Where-Object method -eq PATCH).Count -eq 0) 'Public access was changed before PE approval.'
    $arm.approvedPe = $true
    $arm.peTarget = $serviceId + '-unrelated'
    Assert-Throws { Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -MaxAttempts 1 -RetryDelaySeconds 0 } '*private endpoint*'
    $arm.peTarget = $serviceId
    $arm.conflicts = 1
    Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -MaxAttempts 3 -RetryDelaySeconds 0 | Out-Null
    Assert-True ($arm.state -ceq 'Private') 'Public access was not disabled.'
    $patches = @($arm.calls | Where-Object method -eq PATCH)
    Assert-True ($patches.Count -eq 2) 'A conflict did not trigger a bounded read/retry.'
    foreach ($patch in $patches) {
        Assert-True (($patch.body | ConvertTo-Json -Depth 10 -Compress) -ceq '{"properties":{"publicNetworkAccess":"Disabled"}}') 'PATCH changed unrelated service settings.'
    }
    $arm.calls.Clear()
    Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -RetryDelaySeconds 0 | Out-Null
    Assert-True (@($arm.calls | Where-Object method -ne GET).Count -eq 0) 'A private rerun wrote or reenabled public access.'
    $steady = Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request
    Assert-True (-not $steady.initialProvisioning -and $steady.observedState -ceq 'Private') 'A steady deployment would reenable public access.'
    $arm.ownerTag = $null
    Assert-True ((Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request).observedState -ceq 'Private') 'The agreed management/environment ownership pair must be sufficient.'
    $arm.managedBy = 'unrelated-manager'
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*ownership*'
    $arm.managedBy = 'github-dev-environment'
    $arm.environment = 'test'
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*ownership*'
    $arm.environment = 'dev'
    $arm.ownerTag = $owner
    $arm.approvedPe = $false
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*private endpoint*'
    $arm.approvedPe = $true
    $arm.children.namedValues = @(@{ name = "$owner-stop"; properties = @{ tags = @($owner); secret = $false } })
    $withStop = Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request
    $arm.namedValueEtag = 'version-2'
    Assert-Throws { Assert-GatewayDeploymentPlan -Plan $withStop -Request $request } '*stale*'
    $arm.children.Clear()
    $arm.children.apis = @(@{ name = 'unrelated-api'; properties = @{ path = 'other' } })
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*unapproved API*'
    $arm.children.Clear()
    $arm.children.backends = @(@{ name = "$owner-foundry"; properties = @{ description = 'unrelated-owner' } })
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*ownership*'
    $arm.children.Clear()
    $arm.ownerTag = 'unrelated-owner'
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*ownership*'
    Assert-Throws { Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -RetryDelaySeconds 0 } '*ownership*'
    $arm.ownerTag = $owner
    $arm.failure = 403
    Assert-Throws { Get-GatewayDeploymentPlan -ServiceResourceId $serviceId -EnvironmentName dev -WorkloadKey $workloadKey -Request $request } '*HTTP 403*'
    $arm.failure = 0
    $arm.state = 'Public'
    $arm.conflicts = 5
    $arm.calls.Clear()
    Assert-Throws { Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -MaxAttempts 2 -RetryDelaySeconds 0 } '*retry budget*'
    Assert-True (@($arm.calls | Where-Object method -eq PATCH).Count -eq 2 -and $arm.state -ceq 'Public') 'Retry exhaustion did not fail closed at the configured bound.'
    $arm.conflicts = 0
    $arm.stopValue = 'true'
    $arm.stopConflicts = 1
    $arm.calls.Clear()
    $resumed = Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -StopNewRequests $false -MaxAttempts 5 -RetryDelaySeconds 0
    Assert-True ($resumed.status -ceq 'VerifiedControlPlane' -and $resumed.stopControlVerified -and $resumed.stopNewRequests -eq $false -and $resumed.changed) 'Approved stop value was not persisted and verified after private completion.'
    $stopCalls = @($arm.calls | Where-Object uri -Like '*namedValues*')
    Assert-True ($stopCalls.Count -gt 0 -and @($stopCalls | Where-Object state -ne Private).Count -eq 0) 'Stop control was read or changed before private access was established.'
    foreach ($write in @($stopCalls | Where-Object method -eq PATCH)) {
        Assert-True ($write.headers['If-Match'] -and $write.headers['If-Match'] -cne '*' -and
            ($write.body | ConvertTo-Json -Depth 5 -Compress) -ceq '{"properties":{"value":"false"}}') 'Stop restoration must use exact-scope value-only conditional PATCH.'
    }
    $arm.calls.Clear()
    $sameStop = Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -StopNewRequests $false -MaxAttempts 2 -RetryDelaySeconds 0
    Assert-True ($sameStop.stopControlVerified -and -not $sameStop.changed -and @($arm.calls | Where-Object method -eq PATCH).Count -eq 0) 'An unchanged stop setting made another write.'
    $arm.calls.Clear()
    Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -StopNewRequests $true | Out-Null
    Assert-True (@($arm.calls | Where-Object method -ne GET).Count -eq 0) 'Read-only verification acquired values or changed the stop setting.'
    $arm.stopSecret = $true
    Assert-Throws { Complete-GatewayPrivateAccess -Plan $plan -PrivateEndpointResourceId $peId -Request $request -Apply -StopNewRequests $false -MaxAttempts 1 -RetryDelaySeconds 0 } '*nonsecret*'
    $arm.stopSecret = $false

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $scratch 'gateway.template.json'
        Invoke-Bicep @('build', (Join-Path $root 'modules\api-management\main.bicep'), '--outfile', $TemplatePath)
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($template.resources.operation.dependsOn -contains 'apiPolicy') 'A callable operation can appear before its enforcement policy.'
    Assert-True ($template.parameters.initialProvisioning.defaultValue -eq $false) 'Private must be the steady-state default.'
    $bicepSource = Get-Content -LiteralPath (Join-Path $root 'modules\api-management\main.bicep') -Raw
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'main.bicep') -Raw) -match '(?m)^param deployApiManagement bool = false\r?$') 'The parent opt-in default changed.'
    Assert-True ($bicepSource -match 'br/public:avm/res/api-management/service:0\.14\.4') 'Unverified AVM version.'
    Assert-True ($bicepSource -match "initialProvisioning\s*\?\s*'Enabled'\s*:\s*'Disabled'") 'Incorrect initial/private ordering.'
    Assert-True ($bicepSource -match 'gatewayNamedValues\(owner, environmentName, tenantId, configuration, backendEndpoint, initialProvisioning\)') 'Initial stop enforcement is not wired to the real module state.'
    Assert-True ($bicepSource -match "virtualNetworkType:\s*'External'" -and $bicepSource -match 'subnetResourceId:\s*integrationSubnetResourceId') 'Missing explicit v2 outbound integration.'
    Assert-True ($bicepSource -notmatch "resource\s+\w+\s+'Microsoft.ApiManagement/service/policies@") 'Global policy write.'
    Assert-True ($bicepSource -match 'const\.roles\.CognitiveServicesOpenAIUser' -and $bicepSource -match 'resource-role-assignment\.bicep') 'Backend role must use the existing role boundary and constants.'
    Assert-True ($bicepSource -match 'logClientIp:\s*false' -and $bicepSource -match 'bytes:\s*0' -and $bicepSource -match 'metrics:\s*true') 'Missing explicit no-body diagnostic defaults or token metrics.'
    Assert-True ($bicepSource -match 'percentage:\s*0' -and $bicepSource -match 'alwaysLog:\s*null' -and $bicepSource -match 'logCategoriesAndGroups:\s*\[\]') 'Automatic URL/error telemetry can expose malicious query credentials; only explicit metadata traces and token metrics are permitted.'
    # One gateway is shared by many landing zones, so the owner marker, the API
    # name/path and the published route must all be keyed by workloadKey. A route
    # that is merely 'inference/v1/responses' collides across landing zones.
    Assert-True ($bicepSource.Contains("var owner = 'ailz-inference-`${environmentName}-`${workloadKey}'")) 'The owner marker is not workload-scoped; landing zones sharing a gateway would collide.'
    Assert-True ($bicepSource.Contains("var apiPath = 'inference/`${workloadKey}'") -and $bicepSource.Contains('path: apiPath')) 'The API path is not workload-scoped; two landing zones would claim the same route.'
    Assert-True ($template.outputs.inferenceEndpoint.value -match 'v1/responses' -and $template.outputs.inferenceEndpoint.value -match 'apiPath') 'Gateway endpoint contract changed.'
    Assert-True ($template.outputs.inferenceEndpoint.value -notmatch 'inference/v1/responses') 'The published route must not be the unscoped, collision-prone path.'
    Write-Host "Gateway: $script:assertions assertions passed. Native JWT, metering and ARM behavior still require the authorized live matrix."
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Get-ChildItem -LiteralPath $scratch -File | Remove-Item
        Remove-Item -LiteralPath $scratch
    }
}
