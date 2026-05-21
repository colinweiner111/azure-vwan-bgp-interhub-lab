// =============================================================================
// Firewall Module - Azure Firewall with Routing Intent
// =============================================================================
// Creates:
// - Azure Firewall Policy (Allow All for lab purposes)
// - Azure Firewall in the hub
// - Log Analytics Workspace for diagnostics
// - Routing Intent (forces traffic through firewall)
// =============================================================================

param location string
param firewallSku string
param hubName string

// =============================================================================
// Firewall Policy
// =============================================================================
resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: '${hubName}-fwpolicy'
  location: location
  properties: {
    sku: {
      tier: firewallSku
    }
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource fwPolicyRuleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: fwPolicy
  name: 'NetworkRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowAll-Lab'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AnyToAny'
            description: 'Allow all traffic for lab testing'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: [
              '*'
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

// =============================================================================
// Azure Firewall
// =============================================================================
resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: '${hubName}-azfw'
  location: location
  properties: {
    sku: {
      name: 'AZFW_Hub'
      tier: firewallSku
    }
    virtualHub: {
      id: resourceId('Microsoft.Network/virtualHubs', hubName)
    }
    hubIPAddresses: {
      publicIPs: {
        count: 1
      }
    }
    firewallPolicy: {
      id: fwPolicy.id
    }
  }
}

// =============================================================================
// Log Analytics Workspace
// =============================================================================
resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${hubName}-${location}-Logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// =============================================================================
// Diagnostic Settings
// =============================================================================
resource fwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: firewall
  name: 'toLogAnalytics'
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'AzureFirewallApplicationRule'
        enabled: true
      }
      {
        category: 'AzureFirewallNetworkRule'
        enabled: true
      }
      {
        category: 'AzureFirewallDnsProxy'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================
output firewallId string = firewall.id
output firewallPrivateIp string = firewall.properties.hubIPAddresses.privateIPAddress
output logWorkspaceId string = logWorkspace.id
