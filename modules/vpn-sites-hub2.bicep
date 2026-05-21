// =============================================================================
// VPN Sites Module - Hub2 (Primary + Backup)
// =============================================================================
// Creates TWO VPN sites for Hub2:
// - Site 1 (primary-hub2): Connects to frr-router (Instance 0)
// - Site 2 (backup-hub2): Connects to frr-router-backup (Instance 1)
//
// Both advertise the same on-prem prefix (10.0.0.0/16).
// Hub2 is a STANDARD peer - only receives on-prem routes (no transit).
// =============================================================================

param location string
param vwanName string
param hub2VpnGwName string
param onpremPublicIp string      // PIP for ER-path site (hub2 FRR VM)
param onpremPublicIp2 string     // PIP for VPN-backup site (hub2 FRR backup VM)
param onpremBgpIp string         // Private IP 1
param onpremBgpIp2 string        // Private IP 2
param vpnPsk string

// On-prem FRR uses ASN 65001
var onpremAsn = 65001

// =============================================================================
// VPN Site 1 - ER Path (Primary) for Hub2
// =============================================================================
resource vpnSiteErPathHub2 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'er-path-site-hub2'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'FRRouting'
      deviceModel: 'strongSwan-ER-Hub2'
      linkSpeedInMbps: 1000
    }
    vpnSiteLinks: [
      {
        name: 'link-er-primary-hub2'
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
// VPN Site 2 - VPN Backup (Secondary) for Hub2
// =============================================================================
resource vpnSiteVpnBackupHub2 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'vpn-backup-site-hub2'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'FRRouting'
      deviceModel: 'strongSwan-VPN-Hub2'
      linkSpeedInMbps: 100
    }
    vpnSiteLinks: [
      {
        name: 'link-vpn-backup-hub2'
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
// Get existing Hub2 VPN Gateway
// =============================================================================
resource hub2VpnGw 'Microsoft.Network/vpnGateways@2023-11-01' existing = {
  name: hub2VpnGwName
}

// =============================================================================
// VPN Connection 1 - ER Path (Higher bandwidth = preferred) for Hub2
// =============================================================================
resource vpnConnectionErPathHub2 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub2VpnGw
  name: 'conn-er-path-hub2'
  properties: {
    remoteVpnSite: {
      id: vpnSiteErPathHub2.id
    }
    vpnLinkConnections: [
      {
        name: 'link-er-primary-hub2'
        properties: {
          vpnSiteLink: {
            id: vpnSiteErPathHub2.properties.vpnSiteLinks[0].id
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
// VPN Connection 2 - VPN Backup (Lower bandwidth = backup) for Hub2
// =============================================================================
resource vpnConnectionVpnBackupHub2 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub2VpnGw
  name: 'conn-vpn-backup-hub2'
  dependsOn: [vpnConnectionErPathHub2]  // Ensure sequential creation
  properties: {
    remoteVpnSite: {
      id: vpnSiteVpnBackupHub2.id
    }
    vpnLinkConnections: [
      {
        name: 'link-vpn-backup-hub2'
        properties: {
          vpnSiteLink: {
            id: vpnSiteVpnBackupHub2.properties.vpnSiteLinks[0].id
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
output vpnSiteErPathHub2Id string = vpnSiteErPathHub2.id
output vpnSiteVpnBackupHub2Id string = vpnSiteVpnBackupHub2.id
output connectionErPathHub2Id string = vpnConnectionErPathHub2.id
output connectionVpnBackupHub2Id string = vpnConnectionVpnBackupHub2.id
