// =============================================================================
// Spoke VNets Module - Hub-Connected Spoke Networks
// =============================================================================
// Creates two spoke VNets connected to the vWAN hub for testing routing
// =============================================================================

param location string
param hubId string

// =============================================================================
// Spoke 1 VNet
// =============================================================================
resource spoke1Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'spoke1-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.100.0.0/16']
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.100.1.0/24'
          networkSecurityGroup: {
            id: spokeNsg.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// Spoke 2 VNet
// =============================================================================
resource spoke2Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'spoke2-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.200.0.0/16']
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.200.1.0/24'
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
  name: 'spoke-nsg'
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
// Hub Connection - Spoke 1
// =============================================================================
resource spoke1Connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${split(hubId, '/')[8]}/conn-spoke1'
  properties: {
    remoteVirtualNetwork: {
      id: spoke1Vnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
}

// =============================================================================
// Hub Connection - Spoke 2
// =============================================================================
resource spoke2Connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${split(hubId, '/')[8]}/conn-spoke2'
  dependsOn: [spoke1Connection]  // Serialize to avoid conflicts
  properties: {
    remoteVirtualNetwork: {
      id: spoke2Vnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
}

// =============================================================================
// Outputs
// =============================================================================
output spoke1VnetId string = spoke1Vnet.id
output spoke2VnetId string = spoke2Vnet.id
output spoke1SubnetId string = spoke1Vnet.properties.subnets[0].id
output spoke2SubnetId string = spoke2Vnet.properties.subnets[0].id
