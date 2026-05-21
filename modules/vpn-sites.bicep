// =============================================================================
// VPN Sites Module - Hub1 (Primary + Backup)
// =============================================================================
// Creates TWO VPN sites for Hub1:
// - Site 1 (primary): Connects to frr-router (Instance 0)
// - Site 2 (backup): Connects to frr-router-backup (Instance 1)
//
// Both sites advertise the same on-prem prefix (10.0.0.0/16).
// FRR handles transit routing behavior (re-advertise between Hub1 ↔ Hub3).
// =============================================================================

param location string
param vwanName string
param hubVpnGwName string
param onpremPublicIp string      // PIP1 for ER-path site
param onpremPublicIp2 string     // PIP2 for VPN-backup site
param onpremBgpIp string         // Private IP 1
param onpremBgpIp2 string        // Private IP 2
param vpnPsk string

// On-prem FRR uses ASN 65001
var onpremAsn = 65001

// =============================================================================
// VPN Site 1 - ER Path (Primary)
// =============================================================================
resource vpnSiteErPath 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'er-path-site'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'FRRouting'
      deviceModel: 'strongSwan-ER'
      linkSpeedInMbps: 1000
    }
    vpnSiteLinks: [
      {
        name: 'link-er-primary'
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
// VPN Site 2 - VPN Backup (Secondary)
// =============================================================================
resource vpnSiteVpnBackup 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'vpn-backup-site'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'FRRouting'
      deviceModel: 'strongSwan-VPN'
      linkSpeedInMbps: 100
    }
    vpnSiteLinks: [
      {
        name: 'link-vpn-backup'
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
// Get existing Hub VPN Gateway
// =============================================================================
resource hubVpnGw 'Microsoft.Network/vpnGateways@2023-11-01' existing = {
  name: hubVpnGwName
}

// =============================================================================
// VPN Connection 1 - ER Path (Higher bandwidth = preferred)
// =============================================================================
resource vpnConnectionErPath 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hubVpnGw
  name: 'conn-er-path'
  properties: {
    remoteVpnSite: {
      id: vpnSiteErPath.id
    }
    vpnLinkConnections: [
      {
        name: 'link-er-primary'
        properties: {
          vpnSiteLink: {
            id: vpnSiteErPath.properties.vpnSiteLinks[0].id
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
// VPN Connection 2 - VPN Backup (Lower bandwidth = backup)
// =============================================================================
resource vpnConnectionVpnBackup 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hubVpnGw
  name: 'conn-vpn-backup'
  dependsOn: [vpnConnectionErPath]  // Ensure sequential creation
  properties: {
    remoteVpnSite: {
      id: vpnSiteVpnBackup.id
    }
    vpnLinkConnections: [
      {
        name: 'link-vpn-backup'
        properties: {
          vpnSiteLink: {
            id: vpnSiteVpnBackup.properties.vpnSiteLinks[0].id
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
output vpnSiteErPathId string = vpnSiteErPath.id
output vpnSiteVpnBackupId string = vpnSiteVpnBackup.id
output connectionErPathId string = vpnConnectionErPath.id
output connectionVpnBackupId string = vpnConnectionVpnBackup.id
