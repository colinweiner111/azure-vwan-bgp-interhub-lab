// =============================================================================
// Network Module - vWAN Hubs and On-Prem VNet
// =============================================================================
// Creates:
// - Virtual WAN with three hubs (hub1 primary, hub2 secondary, hub3 tertiary)
// - On-Prem VNet (simulates on-premises network with FRR/strongSwan router)
// =============================================================================

param location string
param vwanName string
param hubName string

@description('Name for the second hub')
param hub2Name string

@description('Location for the second hub')
param hub2Location string

@description('Name for the third hub')
param hub3Name string

@description('Location for the third hub')
param hub3Location string

@description('Hub Routing Preference for Hub1: ExpressRoute | VpnGateway | ASPath')
@allowed(['ExpressRoute', 'VpnGateway', 'ASPath'])
param hub1RoutingPreference string = 'VpnGateway'

@description('Hub Routing Preference for Hub2: ExpressRoute | VpnGateway | ASPath')
@allowed(['ExpressRoute', 'VpnGateway', 'ASPath'])
param hub2RoutingPreference string = 'VpnGateway'

@description('Hub Routing Preference for Hub3: ExpressRoute | VpnGateway | ASPath')
@allowed(['ExpressRoute', 'VpnGateway', 'ASPath'])
param hub3RoutingPreference string = 'ExpressRoute'

// =============================================================================
// Virtual WAN
// =============================================================================
resource vwan 'Microsoft.Network/virtualWans@2023-11-01' = {
  name: vwanName
  location: location
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
  }
}

// =============================================================================
// Virtual Hub
// =============================================================================
resource hub 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: hubName
  location: location
  properties: {
    addressPrefix: '192.168.1.0/24'
    virtualWan: {
      id: vwan.id
    }
    sku: 'Standard'
    hubRoutingPreference: hub1RoutingPreference
  }
}

// =============================================================================
// Virtual Hub 2 (Secondary Region)
// =============================================================================
resource hub2 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: hub2Name
  location: hub2Location
  properties: {
    addressPrefix: '192.168.2.0/24'
    virtualWan: {
      id: vwan.id
    }
    sku: 'Standard'
    hubRoutingPreference: hub2RoutingPreference
  }
}

// =============================================================================
// Virtual Hub 3 (Tertiary Region)
// =============================================================================
resource hub3 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: hub3Name
  location: hub3Location
  properties: {
    addressPrefix: '192.168.3.0/24'
    virtualWan: {
      id: vwan.id
    }
    sku: 'Standard'
    hubRoutingPreference: hub3RoutingPreference
  }
}

// =============================================================================
// Route Table for On-Prem Workloads subnet
// Sends spoke-bound traffic through the FRR router so it reaches Azure via VTI
// =============================================================================
resource onpremWorkloadUdr 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'onprem-workloads-udr'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'spoke1'
        properties: {
          addressPrefix: '10.100.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.0.10'
        }
      }
      {
        name: 'spoke2'
        properties: {
          addressPrefix: '10.200.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.0.10'
        }
      }
      {
        name: 'spoke3'
        properties: {
          addressPrefix: '10.110.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.0.10'
        }
      }
      {
        name: 'spoke4'
        properties: {
          addressPrefix: '10.210.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.0.10'
        }
      }
      {
        name: 'spoke5'
        properties: {
          addressPrefix: '10.120.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.0.10'
        }
      }
      {
        name: 'spoke6'
        properties: {
          addressPrefix: '10.220.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.0.10'
        }
      }
    ]
  }
}

// =============================================================================
// On-Prem VNet - Simulates customer's on-premises network
// Contains FRR/strongSwan router VM that creates 2 tunnels to vWAN
// Address Space: 10.0.0.0/16 (what will be advertised to Azure)
// =============================================================================
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'onprem-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'router'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: onpremNsg.id
          }
        }
      }
      {
        name: 'workloads-1'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: onpremNsg.id
          }
          routeTable: {
            id: onpremWorkloadUdr.id
          }
        }
      }
      {
        name: 'workloads-2'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: {
            id: onpremNsg.id
          }
          routeTable: {
            id: onpremWorkloadUdr.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.255.0/27'
        }
      }
    ]
  }
}

// =============================================================================
// Network Security Group for On-Prem
// =============================================================================
resource onpremNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'onprem-nsg'
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
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowIKE'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '500'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowNATT'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '4500'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowBGP'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '179'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowICMP'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vwanId string = vwan.id
output hubId string = hub.id
output hub2Id string = hub2.id
output hub3Id string = hub3.id
output onpremVnetId string = onpremVnet.id
output onpremVnetName string = onpremVnet.name
output onpremSubnetId string = onpremVnet.properties.subnets[0].id
output onpremWorkloadsSubnetId string = onpremVnet.properties.subnets[1].id
