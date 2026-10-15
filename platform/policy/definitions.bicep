targetScope = 'subscription'

import { definitionContracts } from './contracts.bicep'

@description('Explicit ownership prefix. Distinct workload RGs must not reuse a subscription definition prefix.')
@minLength(1)
@maxLength(40)
param assignmentPrefix string

@description('Exact workload RG resource ID; definitions exist at subscription scope but are not assigned there.')
param workloadResourceGroupId string

@description('True for Audit/Disabled, or explicit prior assessment approval for Deny. ARM rejects false before resource writes.')
@allowed([true])
param assessmentApproved bool

@description('The supplied, observed billing currency must match both approved financial inputs. No currency is inferred here.')
@allowed([true])
param billingCurrencyConfirmed bool

@description('The current subscription and tenant must match the approved P1 Azure scope.')
@allowed([true])
param scopeConfirmed bool

var owner = 'ailz-governance:${toLower(workloadResourceGroupId)}:${assignmentPrefix}'
var definitions = definitionContracts(workloadResourceGroupId, assignmentPrefix)

resource policies 'Microsoft.Authorization/policyDefinitions@2023-04-01' = [
  for definition in definitions: if (assessmentApproved && billingCurrencyConfirmed && scopeConfirmed) {
    name: definition.name
    properties: definition.properties
  }
]

@description('Owned custom definition IDs, scoped to the subscription only because Azure requires that definition boundary.')
output definitionIds object = {
  models: policies[0].id
  skus: policies[1].id
  private: policies[2].id
}

@description('The explicit owner used for conflict detection, not authorization to overwrite existing definitions.')
output owner string = owner
