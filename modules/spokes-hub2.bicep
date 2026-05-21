// =============================================================================
// Spoke VNets Module - Hub2-Connected Spoke Networks
// =============================================================================
// Creates spoke3 and spoke4 VNets connected to the vWAN hub2 for testing routing
// =============================================================================

param location string
param hub2Id string

// =============================================================================
// Spoke 3 VNet
// =============================================================================
resource spoke3Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'spoke3-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.110.0.0/16']
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.110.1.0/24'
          networkSecurityGroup: {
            id: spokeNsg.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// Spoke 4 VNet
// =============================================================================
resource spoke4Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'spoke4-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.210.0.0/16']
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.210.1.0/24'
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
  name: 'spoke-hub2-nsg'
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
// Hub Connection - Spoke 3
// =============================================================================
resource spoke3Connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${split(hub2Id, '/')[8]}/conn-spoke3'
  properties: {
    remoteVirtualNetwork: {
      id: spoke3Vnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
}

// =============================================================================
// Hub Connection - Spoke 4
// =============================================================================
resource spoke4Connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${split(hub2Id, '/')[8]}/conn-spoke4'
  dependsOn: [spoke3Connection]  // Serialize to avoid conflicts
  properties: {
    remoteVirtualNetwork: {
      id: spoke4Vnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
}

// =============================================================================
// Outputs
// =============================================================================
output spoke3VnetId string = spoke3Vnet.id
output spoke4VnetId string = spoke4Vnet.id
output spoke3SubnetId string = spoke3Vnet.properties.subnets[0].id
output spoke4SubnetId string = spoke4Vnet.properties.subnets[0].id
