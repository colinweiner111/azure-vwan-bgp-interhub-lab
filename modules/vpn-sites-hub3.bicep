// =============================================================================
// VPN Sites Module - Hub3 (Primary + Backup)
// =============================================================================
// Creates TWO VPN sites for Hub3:
// - Site 1 (primary-hub3): Connects to frr-router (Instance 0)
// - Site 2 (backup-hub3): Connects to frr-router-backup (Instance 1)
//
// Both advertise the same on-prem prefix (10.0.0.0/16).
// Hub3 is a TRANSIT peer - FRR re-advertises between Hub1 ↔ Hub3.
// =============================================================================

param location string
param vwanName string
param hub3VpnGwName string
param onpremPublicIp string      // PIP for ER-path site (hub3 FRR VM)
param onpremPublicIp2 string     // PIP for VPN-backup site (hub3 FRR backup VM)
param onpremBgpIp string         // Private IP 1
param onpremBgpIp2 string        // Private IP 2
param vpnPsk string

// On-prem FRR uses ASN 65001
var onpremAsn = 65001

// =============================================================================
// VPN Site 1 - ER Path (Primary) for Hub3
// =============================================================================
resource vpnSiteErPathHub3 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'er-path-site-hub3'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'FRRouting'
      deviceModel: 'strongSwan-ER-Hub3'
      linkSpeedInMbps: 1000
    }
    vpnSiteLinks: [
      {
        name: 'link-er-primary-hub3'
        properties: {
          ipAddress: onpremPublicIp
          bgpProperties: {
            asn: onpremAsn
            bgpPeeringAddress: onpremBgpIp
          }
          linkProperties: {
            linkSpeedInMbps: 1000
          }
        }
      }
    ]
  }
}

// =============================================================================
// VPN Site 2 - VPN Backup (Secondary) for Hub3
// =============================================================================
resource vpnSiteVpnBackupHub3 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'vpn-backup-site-hub3'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'FRRouting'
      deviceModel: 'strongSwan-VPN-Hub3'
      linkSpeedInMbps: 100
    }
    vpnSiteLinks: [
      {
        name: 'link-vpn-backup-hub3'
        properties: {
          ipAddress: onpremPublicIp2
          bgpProperties: {
            asn: onpremAsn
            bgpPeeringAddress: onpremBgpIp2
          }
          linkProperties: {
            linkSpeedInMbps: 100
          }
        }
      }
    ]
  }
}

// =============================================================================
// Get existing Hub3 VPN Gateway
// =============================================================================
resource hub3VpnGw 'Microsoft.Network/vpnGateways@2023-11-01' existing = {
  name: hub3VpnGwName
}

// =============================================================================
// VPN Connection 1 - ER Path (Higher bandwidth = preferred) for Hub3
// =============================================================================
resource vpnConnectionErPathHub3 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub3VpnGw
  name: 'conn-er-path-hub3'
  properties: {
    remoteVpnSite: {
      id: vpnSiteErPathHub3.id
    }
    vpnLinkConnections: [
      {
        name: 'link-er-primary-hub3'
        properties: {
          vpnSiteLink: {
            id: vpnSiteErPathHub3.properties.vpnSiteLinks[0].id
          }
          sharedKey: vpnPsk
          enableBgp: true
          vpnConnectionProtocolType: 'IKEv2'
          connectionBandwidth: 1000
          routingWeight: 10
        }
      }
    ]
  }
}

// =============================================================================
// VPN Connection 2 - VPN Backup (Lower bandwidth = backup) for Hub3
// =============================================================================
resource vpnConnectionVpnBackupHub3 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub3VpnGw
  name: 'conn-vpn-backup-hub3'
  dependsOn: [vpnConnectionErPathHub3]  // Ensure sequential creation
  properties: {
    remoteVpnSite: {
      id: vpnSiteVpnBackupHub3.id
    }
    vpnLinkConnections: [
      {
        name: 'link-vpn-backup-hub3'
        properties: {
          vpnSiteLink: {
            id: vpnSiteVpnBackupHub3.properties.vpnSiteLinks[0].id
          }
          sharedKey: vpnPsk
          enableBgp: true
          vpnConnectionProtocolType: 'IKEv2'
          connectionBandwidth: 100
          routingWeight: 1
        }
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vpnSiteErPathHub3Id string = vpnSiteErPathHub3.id
output vpnSiteVpnBackupHub3Id string = vpnSiteVpnBackupHub3.id
output connectionErPathHub3Id string = vpnConnectionErPathHub3.id
output connectionVpnBackupHub3Id string = vpnConnectionVpnBackupHub3.id
