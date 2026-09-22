targetScope = 'resourceGroup'

import { baselineAssignmentContracts, tagAssignmentContracts, customAssignmentContracts, budgetProperties } from './contracts.bicep'

@description('Validated frozen P1 governance object. Budget amounts/thresholds remain JSON numbers, including fractions.')
param configuration object

@description('Validated ownership prefix, kept separate for ARM length validation.')
@minLength(1)
@maxLength(40)
param assignmentPrefix string

@description('Owned subscription-level definition IDs returned by the privileged definitions module.')
param definitionIds object

@description('Observed budget eTag frozen with preview. Empty only when the owned budget was observed absent.')
param budgetEtag string = ''

var builtins = loadJsonContent('./builtins.json')
var owner = 'ailz-governance:${toLower(resourceGroup().id)}:${assignmentPrefix}'
var budgetName = '${assignmentPrefix}-environment'
var mode = configuration.policyEffect == 'Deny' ? 'Default' : 'DoNotEnforce'
var baseline = baselineAssignmentContracts(resourceGroup().id, assignmentPrefix, configuration)
var tagContracts = tagAssignmentContracts(resourceGroup().id, assignmentPrefix, configuration)
var custom = customAssignmentContracts(resourceGroup().id, assignmentPrefix, configuration, definitionIds)

resource baselineAssignments 'Microsoft.Authorization/policyAssignments@2024-04-01' = [
  for item in baseline: {
    name: item.name
    properties: item.properties
  }
]

resource tagAssignments 'Microsoft.Authorization/policyAssignments@2024-04-01' = [
  for item in tagContracts: {
    name: item.name
    properties: item.properties
  }
]

resource customAssignments 'Microsoft.Authorization/policyAssignments@2024-04-01' = [
  for item in custom: {
    name: item.name
    properties: item.properties
  }
]

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: budgetName
  eTag: empty(budgetEtag) ? null : budgetEtag
  properties: budgetProperties(configuration.budget)
  dependsOn: [baselineAssignments, tagAssignments, customAssignments]
}

var baselineFacts = [for (item, i) in baseline: { resourceId: baselineAssignments[i].id, definitionId: item.properties.policyDefinitionId, definitionVersion: item.properties.definitionVersion }]
var tagFacts = [for (tag, i) in configuration.requiredTags: { resourceId: tagAssignments[i].id, definitionId: builtins.definitions.tags.id, tag: tag }]
var customFacts = [for (item, i) in custom: { resourceId: customAssignments[i].id, definitionId: item.properties.policyDefinitionId }]

@description('Per-owned assignment and budget facts; none imply compliance, alert delivery, private readiness or a financial hard cap.')
output facts object = {
  owner: owner
  scope: resourceGroup().id
  assignments: concat(baselineFacts, tagFacts, customFacts)
  policyEffect: configuration.policyEffect
  enforcementMode: mode
  budget: {
    resourceId: budget.id
    scope: resourceGroup().id
    wholeEnvironment: true
    requestedCurrency: configuration.budget.currency
    amount: configuration.budget.amount
    hardCap: false
  }
  inferenceAllowance: configuration.inferenceAllowance
  sourceCommit: builtins.sourceCommit
  sources: map(items(builtins.definitions), definition => definition.value.source)
}
