// =============================================================================
// VPN Gateway Module - Hub VPN Gateway
// =============================================================================
// Creates:
// - Hub VPN Gateway for vWAN (takes ~30 minutes to deploy)
// =============================================================================

param location string
param hubName string
param hubId string

// =============================================================================
// Hub VPN Gateway
// =============================================================================
resource hubVpnGw 'Microsoft.Network/vpnGateways@2023-11-01' = {
  name: '${hubName}-vpngw'
  location: location
  properties: {
    virtualHub: {
      id: hubId
    }
    bgpSettings: {
      asn: 65515  // Azure default ASN for vWAN
    }
    vpnGatewayScaleUnit: 1
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vpnGatewayId string = hubVpnGw.id
output vpnGatewayName string = hubVpnGw.name
output bgpPeeringAddress0 string = hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
output bgpPeeringAddress1 string = hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
output publicIpAddress0 string = hubVpnGw.properties.ipConfigurations[0].publicIpAddress
output publicIpAddress1 string = hubVpnGw.properties.ipConfigurations[1].publicIpAddress
