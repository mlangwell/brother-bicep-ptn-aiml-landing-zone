targetScope = 'subscription'

@description('Explicit opt-in to privileged governance. False does not delete or disable previously deployed resources.')
param enabled bool = false

@description('Exact existing workload RG in the deployment subscription. No subscription-wide assignment or budget is created.')
@minLength(1)
param resourceGroupName string

@description('Approved deployment subscription. A mismatched execution context fails before policy/budget resource writes.')
param expectedSubscriptionId string = ''

@description('Approved Entra tenant for the privileged boundary. A mismatched execution context fails closed.')
param expectedTenantId string = ''

@description('Validated P1 governance object, produced identically for preview/deploy. Empty only for the disabled path.')
param configuration object = {}

@description('Actual workload budget billing currency, obtained by the authorized platform preflight. No default or conversion; required when enabled.')
param billingCurrency string = ''

@description('Existing owned budget eTag observed in the approved plan, or empty for observed absence.')
param budgetEtag string = ''

resource workloadResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' existing = {
  name: resourceGroupName
}

var assignmentPrefix = enabled ? configuration.assignmentPrefix : 'disabled'

module definitions './policy/definitions.bicep' = if (enabled) {
  name: '${assignmentPrefix}-definitions'
  params: {
    assignmentPrefix: assignmentPrefix
    workloadResourceGroupId: workloadResourceGroup.id
    // Defer these runtime assertions to the callee's allowedValues:[true] ARM guards.
    assessmentApproved: any(enabled ? (configuration.policyEffect != 'Deny' || configuration.assessmentApproved) : true)
    billingCurrencyConfirmed: any(enabled ? (!empty(billingCurrency) && configuration.budget.currency == billingCurrency && configuration.inferenceAllowance.currency == billingCurrency) : true)
    scopeConfirmed: any(enabled ? (toLower(subscription().subscriptionId) == toLower(expectedSubscriptionId) && toLower(tenant().tenantId) == toLower(expectedTenantId)) : true)
  }
}

module assignments './policy/assignments.bicep' = if (enabled) {
  name: '${assignmentPrefix}-governance'
  scope: resourceGroup(resourceGroupName)
  params: {
    configuration: configuration
    assignmentPrefix: assignmentPrefix
    definitionIds: enabled ? definitions!.outputs.definitionIds : {}
    budgetEtag: budgetEtag
  }
}

@description('Owned resource facts and sources. Empty when disabled. ARM completion is not policy compliance or budget delivery evidence.')
output facts object = enabled ? union(assignments!.outputs.facts, {
  definitions: definitions!.outputs.definitionIds
  billingCurrency: billingCurrency
  builtinTenantAvailabilityVerificationRequired: true
}) : {}
