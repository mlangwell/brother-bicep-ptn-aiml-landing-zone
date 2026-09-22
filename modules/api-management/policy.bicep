import { callerMapping, gatewayConfiguration } from './types.bicep'

var template = loadTextContent('./responses-policy.xml')

@export()
@description('Render only the owned API policy. Native rates/quotas are literals, not caller-supplied expressions. apiPath is the workload-scoped route prefix the policy pins the inbound request to.')
func renderPolicy(owner string, apiPath string, callers callerMapping[]) string => replace(
  replace(
    replace(template, '__OWNER__', owner),
    '__API_PATH__',
    apiPath
  ),
  '__TOKEN_LIMITS__',
  join(map(callers, caller => '<when condition="@((string)context.Variables[&quot;caller-id&quot;] == &quot;${toLower(caller.objectId)}&quot;)"><llm-token-limit counter-key="@((string)context.Variables[&quot;counter-key&quot;])" tokens-per-minute="${caller.tokensPerMinute}" token-quota="${caller.tokenQuota}" token-quota-period="${caller.tokenQuotaPeriod}" estimate-prompt-tokens="true" tokens-consumed-variable-name="consumed-tokens" remaining-quota-tokens-variable-name="remaining-quota" /></when>'), '\n')
)

@export()
@description('Nonsecret, ownership-tagged named values. Names and tags are keyed by the workload-scoped owner so landing zones sharing one gateway never collide. Initial/recovery provisioning forces stop until private completion. Base64 is encoding, not encryption.')
func gatewayNamedValues(owner string, environmentName string, tenantId string, configuration gatewayConfiguration, backendEndpoint string, initialProvisioning bool) array => [
  {
    name: '${owner}-configuration'
    displayName: '${owner}-configuration'
    secret: false
    tags: [owner]
    value: base64(string({
      environment: environmentName
      tenantId: toLower(tenantId)
      backendHost: toLower(split(backendEndpoint, '/')[2])
      callerMappings: configuration.callerMappings
    }))
  }
  {
    name: '${owner}-tenant'
    displayName: '${owner}-tenant'
    secret: false
    tags: [owner]
    value: toLower(tenantId)
  }
  {
    name: '${owner}-audience'
    displayName: '${owner}-audience'
    secret: false
    tags: [owner]
    value: configuration.audience
  }
  {
    name: '${owner}-stop'
    displayName: '${owner}-stop'
    secret: false
    tags: [owner]
    value: (initialProvisioning || configuration.stopNewRequests) ? 'true' : 'false'
  }
]
