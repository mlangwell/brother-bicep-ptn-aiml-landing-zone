#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9./:_-]+$')][string]$Image,
    [Parameter(Mandatory)][string]$OciArchivePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ExpectedSourceSha
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')
Import-Module (Join-Path $PSScriptRoot 'Oci.psm1')
$oci = Test-OciArchive -Path $OciArchivePath
$imageId = (Invoke-CheckedNative -Command docker -Arguments @('image', 'inspect', '--format', '{{.Id}}', $Image)).Trim()
if ($imageId -cne $oci.configDigest) { throw 'The container test image is not the same configuration and layers as the release OCI image.' }

# These identities and settings exist only in a network-disabled packaging test.
$settings = @{
    AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
    AZURE_CLIENT_ID = '55555555-5555-5555-5555-555555555555'
    INFERENCE_ACCESS_MODE = 'gateway'
    INFERENCE_GATEWAY_ENDPOINT = 'https://synthetic.azure-api.net/inference/v1/responses'
    INFERENCE_GATEWAY_AUDIENCE = 'api://22222222-2222-2222-2222-222222222222'
    SMOKE_API_AUDIENCE = 'api://33333333-3333-3333-3333-333333333333'
    SMOKE_ALLOWED_OBJECT_IDS = '["44444444-4444-4444-4444-444444444444"]'
    SMOKE_ALLOWED_GROUP_IDS = '[]'
    SMOKE_MODEL_DEPLOYMENT = 'synthetic-chat'
    SMOKE_MAX_OUTPUT_TOKENS = '16'
    APP_CONFIG_ENDPOINT = 'https://synthetic.azconfig.io'
}
$arguments = @('run', '--detach', '--network', 'none')
foreach ($key in $settings.Keys) { $arguments += @('--env', "$key=$($settings[$key])") }
$arguments += $Image
$containerId = (Invoke-CheckedNative -Command docker -Arguments $arguments).Trim()
if ($containerId -cnotmatch '^[a-f0-9]{64}$') { throw 'Docker did not return a new test container ID.' }
$probe = @'
import json, sys, urllib.error, urllib.request
try:
    for route in ("health", "ready"):
        with urllib.request.urlopen("http://127.0.0.1:8080/" + route, timeout=2) as response:
            body = json.load(response)
            if response.status != 200 or body.get("service") != "developer-smoke" or body.get("version") != sys.argv[1]:
                sys.exit(2)
except (urllib.error.URLError, TimeoutError):
    sys.exit(75)
'@
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        & docker exec $containerId python -c $probe $ExpectedSourceSha
        $result = $LASTEXITCODE
        if ($result -eq 0) { $ready = $true; break }
        if ($result -ne 75) { throw 'Packaged starter health check failed.' }
        $running = (Invoke-CheckedNative -Command docker -Arguments @('inspect', '--format', '{{.State.Running}}', $containerId)).Trim()
        if ($running -cne 'true') { throw 'Packaged starter exited before becoming healthy.' }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'Packaged starter did not become healthy within its bounded startup test.' }
    Write-Output "Packaged starter is healthy with external networking disabled; OCI configuration digest $imageId."
}
finally {
    $null = Invoke-CheckedNative -Command docker -Arguments @('rm', '--force', $containerId)
}
