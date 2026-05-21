// =============================================================================
// Spoke VNets Module - Hub3-Connected Spoke Networks
// =============================================================================
// Creates spoke5 and spoke6 VNets connected to the vWAN hub3 for testing routing
// =============================================================================

param location string
param hub3Id string

// =============================================================================
// Spoke 5 VNet
// =============================================================================
resource spoke5Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'spoke5-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.120.0.0/16']
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.120.1.0/24'
          networkSecurityGroup: {
            id: spokeNsg.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// Spoke 6 VNet
// =============================================================================
resource spoke6Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'spoke6-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.220.0.0/16']
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.220.1.0/24'
          networkSecurityGroup: {
            id: spokeNsg.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// NSG for Spoke VNets
// =============================================================================
resource spokeNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'spoke-hub3-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'AllowICMP'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// =============================================================================
// Hub Connection - Spoke 5
// =============================================================================
resource spoke5Connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${split(hub3Id, '/')[8]}/conn-spoke5'
  properties: {
    remoteVirtualNetwork: {
      id: spoke5Vnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
}

// =============================================================================
// Hub Connection - Spoke 6
// =============================================================================
resource spoke6Connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${split(hub3Id, '/')[8]}/conn-spoke6'
  dependsOn: [spoke5Connection]  // Serialize to avoid conflicts
  properties: {
    remoteVirtualNetwork: {
      id: spoke6Vnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
}

// =============================================================================
// Outputs
// =============================================================================
output spoke5VnetId string = spoke5Vnet.id
output spoke6VnetId string = spoke6Vnet.id
output spoke5SubnetId string = spoke5Vnet.properties.subnets[0].id
output spoke6SubnetId string = spoke6Vnet.properties.subnets[0].id
