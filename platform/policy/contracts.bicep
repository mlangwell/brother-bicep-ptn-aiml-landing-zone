@export()
@description('Exact P1 OpenAI model paths. A model-root trailing slash approves all versions of that exact name; /versions/x approves exactly model.version x, never a prefix.')
func approvedModels(assetIds string[]) array =>
  map(assetIds, assetId => {
    format: 'OpenAI'
    name: split(assetId, '/')[5]
    version: length(split(assetId, '/')) == 8 ? split(assetId, '/')[7] : ''
  })

@export()
@description('Whole-RG monthly Cost budget. JSON numeric values are retained without integer casts, currency conversion, filters or financial defaults.')
func budgetProperties(budget object) object => {
  category: 'Cost'
  amount: budget.amount
  timeGrain: 'Monthly'
  timePeriod: {
    startDate: '${budget.startDate}T00:00:00Z'
    endDate: '${budget.endDate}T00:00:00Z'
  }
  notifications: {
    actual: {
      enabled: true
      operator: 'GreaterThanOrEqualTo'
      threshold: budget.actualThreshold
      thresholdType: 'Actual'
      contactEmails: budget.contactEmails
      contactGroups: budget.contactGroups
      contactRoles: []
    }
    forecast: {
      enabled: true
      operator: 'GreaterThanOrEqualTo'
      threshold: budget.forecastThreshold
      thresholdType: 'Forecasted'
      contactEmails: budget.contactEmails
      contactGroups: budget.contactGroups
      contactRoles: []
    }
  }
}

var builtins = loadJsonContent('./builtins.json')
var effectParameter = {
  type: 'String'
  allowedValues: ['Audit', 'Deny', 'Disabled']
  defaultValue: 'Audit'
  metadata: { displayName: 'Effect', description: 'Assess before explicitly approved Deny enforcement.' }
}
var definitionTemplates = [
  {
    suffix: 'models'
    displayName: 'Exact approved OpenAI model names and versions'
    description: 'Exact ARM model format/name/version allow-list. Does not use publisher or asset-ID substring matching.'
    mode: 'All'
    parameters: {
      effect: effectParameter
      allowedModels: {
        type: 'Array'
        metadata: {
          displayName: 'Approved exact models'
          description: 'OpenAI format, exact name, and exact version (empty version means all versions of that exact model).'
        }
      }
    }
    policyRule: loadJsonContent('./exact-models.policy.json')
  }
  {
    suffix: 'skus'
    displayName: 'Approved Foundry deployment SKUs'
    description: 'Deployment type is independent of resource region; Global SKUs do not imply region-local processing.'
    mode: 'All'
    parameters: {
      effect: effectParameter
      allowedDeploymentSkus: {
        type: 'Array'
        metadata: {
          displayName: 'Approved deployment SKUs'
          description: 'Exact approved deployment SKU names; no wildcard allowance.'
        }
      }
    }
    policyRule: loadJsonContent('./deployment-skus.policy.json')
  }
  {
    suffix: 'private'
    displayName: 'Private-only Foundry and Search backends'
    description: 'Tightens the current network-ACL built-in: publicNetworkAccess must be Disabled, not merely IP-filtered. Does not target APIM initial provisioning.'
    mode: 'Indexed'
    parameters: { effect: effectParameter }
    policyRule: loadJsonContent('./private-backends.policy.json')
  }
]

@export()
@description('The exact custom definition properties shared by deployment and read-only readiness.')
func definitionContracts(scope string, prefix string) array =>
  map(definitionTemplates, definition => {
    name: '${prefix}-${definition.suffix}'
    properties: {
      policyType: 'Custom'
      mode: definition.mode
      displayName: '${prefix}: ${definition.displayName}'
      description: definition.description
      metadata: {
        'ailz-owner': 'ailz-governance:${toLower(scope)}:${prefix}'
        workloadResourceGroupId: scope
        version: '1.0.0'
        source: 'https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types'
      }
      parameters: definition.parameters
      policyRule: definition.policyRule
    }
  })

func assignmentProperties(
  scope string,
  prefix string,
  effect string,
  displayName string,
  definitionId string,
  parameters object
) object => {
  displayName: '${prefix}: ${displayName}'
  policyDefinitionId: definitionId
  enforcementMode: effect == 'Deny' ? 'Default' : 'DoNotEnforce'
  notScopes: effect == 'Disabled' ? [scope] : []
  metadata: {
    'ailz-owner': 'ailz-governance:${toLower(scope)}:${prefix}'
    workloadResourceGroupId: scope
    budgetResourceId: '${scope}/providers/Microsoft.Consumption/budgets/${prefix}-environment'
    sourceCommit: builtins.sourceCommit
  }
  parameters: parameters
}

@export()
@description('The exact built-in assignment contracts shared by deployment and readiness.')
func baselineAssignmentContracts(scope string, prefix string, configuration object) array =>
  map(
    [
      {
        suffix: 'network'
        definition: builtins.definitions.network
        parameters: { effect: { value: configuration.policyEffect } }
      }
      {
        suffix: 'local-auth'
        definition: builtins.definitions.localAuth
        parameters: { effect: { value: configuration.policyEffect } }
      }
      {
        suffix: 'locations'
        definition: builtins.definitions.locations
        parameters: {
          effect: { value: configuration.policyEffect }
          listOfAllowedLocations: { value: configuration.allowedLocations }
        }
      }
      {
        suffix: 'private-link'
        definition: builtins.definitions.privateEndpoint
        parameters: { effect: { value: configuration.policyEffect == 'Disabled' ? 'Disabled' : 'Audit' } }
      }
      {
        suffix: 'diagnostics'
        definition: builtins.definitions.diagnostics
        parameters: {
          listOfResourceTypes: { value: ['Microsoft.CognitiveServices/accounts', 'Microsoft.Search/searchServices'] }
          logsEnabled: { value: true }
          metricsEnabled: { value: true }
        }
      }
    ],
    item => {
      name: '${prefix}-${item.suffix}'
      properties: union(
        assignmentProperties(
          scope,
          prefix,
          configuration.policyEffect,
          item.suffix,
          item.definition.id,
          item.parameters
        ),
        {
          definitionVersion: item.definition.version
        }
      )
    }
  )

@export()
@description('The exact required-tag assignment contracts shared by deployment and readiness.')
func tagAssignmentContracts(scope string, prefix string, configuration object) array =>
  map(range(0, length(configuration.requiredTags)), i => {
    name: '${prefix}-tag-${i}'
    properties: union(
      assignmentProperties(
        scope,
        prefix,
        configuration.policyEffect,
        'require ${configuration.requiredTags[i]}',
        builtins.definitions.tags.id,
        {
          tagName: { value: configuration.requiredTags[i] }
        }
      ),
      { definitionVersion: builtins.definitions.tags.version }
    )
  })

@export()
@description('The exact custom-policy assignment contracts shared by deployment and readiness.')
func customAssignmentContracts(scope string, prefix string, configuration object, definitionIds object) array =>
  map(
    [
      {
        suffix: 'models'
        definitionId: definitionIds.models
        parameters: {
          effect: { value: configuration.policyEffect }
          allowedModels: { value: approvedModels(configuration.allowedModelAssetIds) }
        }
      }
      {
        suffix: 'skus'
        definitionId: definitionIds.skus
        parameters: {
          effect: { value: configuration.policyEffect }
          allowedDeploymentSkus: { value: configuration.allowedDeploymentSkus }
        }
      }
      {
        suffix: 'private'
        definitionId: definitionIds.private
        parameters: { effect: { value: configuration.policyEffect } }
      }
    ],
    item => {
      name: '${prefix}-${item.suffix}'
      properties: assignmentProperties(
        scope,
        prefix,
        configuration.policyEffect,
        item.suffix,
        item.definitionId,
        item.parameters
      )
    }
  )

func definitionIds(scope string, prefix string) object => {
  models: '/subscriptions/${split(scope, '/')[2]}/providers/Microsoft.Authorization/policyDefinitions/${prefix}-models'
  skus: '/subscriptions/${split(scope, '/')[2]}/providers/Microsoft.Authorization/policyDefinitions/${prefix}-skus'
  private: '/subscriptions/${split(scope, '/')[2]}/providers/Microsoft.Authorization/policyDefinitions/${prefix}-private'
}

@export()
@description('Complete expected resource properties for offline planning and observed readiness. No Azure reads or financial defaults.')
func governanceResourceContracts(scope string, configuration object) array =>
  concat(
    map(definitionContracts(scope, configuration.assignmentPrefix), definition => {
      kind: 'definition'
      resourceId: '/subscriptions/${split(scope, '/')[2]}/providers/Microsoft.Authorization/policyDefinitions/${definition.name}'
      apiVersion: '2023-04-01'
      properties: definition.properties
    }),
    map(
      concat(
        baselineAssignmentContracts(scope, configuration.assignmentPrefix, configuration),
        tagAssignmentContracts(scope, configuration.assignmentPrefix, configuration),
        customAssignmentContracts(
          scope,
          configuration.assignmentPrefix,
          configuration,
          definitionIds(scope, configuration.assignmentPrefix)
        )
      ),
      assignment => {
        kind: 'assignment'
        resourceId: '${scope}/providers/Microsoft.Authorization/policyAssignments/${assignment.name}'
        apiVersion: '2024-04-01'
        properties: assignment.properties
      }
    ),
    [
      {
        kind: 'budget'
        resourceId: '${scope}/providers/Microsoft.Consumption/budgets/${configuration.assignmentPrefix}-environment'
        apiVersion: '2024-08-01'
        properties: budgetProperties(configuration.budget)
      }
    ]
  )
