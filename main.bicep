targetScope = 'subscription'

// =============================================================================
// azure-vwan-bgp-interhub-lab
// =============================================================================
// Lab for testing BGP inter-hub routing behavior in Azure Virtual WAN.
//
// Architecture:
// - 3 vWAN Hubs: Hub1 (westus), Hub2 (westus3), Hub3 (eastus2)
// - 2 on-prem FRR/strongSwan VMs, each with 3 IPsec tunnels (one per hub)
//   * VM1 (frr-router): Tunnels to Hub1/Hub2/Hub3 VPN GW Instance 0
//   * VM2 (frr-router-backup): Tunnels to Hub1/Hub2/Hub3 VPN GW Instance 1
//   * Both advertise the same on-prem prefix: 10.0.0.0/16
// - Transit routing via FRR:
//   * Hub1 ↔ Hub2: FRR re-advertises Azure-learned routes between them
//   * Hub3: Standard peer (on-prem only, no transit re-advertisement)
//
// Scenarios tested:
// - VPN gateway-learned routes overriding inter-hub (Remote Hub) backbone routes
// - Hub Routing Preference: ExpressRoute / VpnGateway / ASPath
// - AS-path prepending to restore Remote Hub path selection
// - Route-map influence on inbound BGP routes at the hub
// =============================================================================

@description('Primary region for deployment')
param location string = 'westus'

@description('Resource group name')
param resourceGroupName string = 'vwan-bgp-interhub-lab'

@description('Virtual WAN name')
param vwanName string = 'vwan-bgp-interhub'

@description('Secondary hub region')
param hub2Location string = 'westus3'

@description('Tertiary hub region')
param hub3Location string = 'eastus2'

var hubName = 'hub1-${location}'
var hub2Name = 'hub2-${hub2Location}'
var hub3Name = 'hub3-${hub3Location}'

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('SSH public key for the FRR VM')
param sshPublicKey string = ''

@description('VM size for FRR router')
param vmSize string = 'Standard_B2s'

@description('Deploy Azure Firewall on all hubs (adds ~15 min to deployment)')
param enableFirewall bool = false

@description('Enable Routing Intent policies on hubs (requires enableFirewall=true)')
param enableRoutingIntent bool = false

@description('Deploy Azure Bastion for VM access (adds ~5 min to deployment)')
param enableBastion bool = false

@description('Deploy backup VPN sites/connections (secondary path per hub)')
param enableBackupVpn bool = false

@description('Azure Firewall SKU (if enabled)')
@allowed(['Standard', 'Premium'])
param firewallSku string = 'Standard'

// =============================================================================
// Hub Routing Preference (HRP) - controls which route type wins on equal prefix
// ExpressRoute = default Azure behavior (ER > VPN > Remote Hub)
// VpnGateway   = VPN gateway-learned routes override inter-hub backbone
// ASPath        = shortest BGP AS-path wins (regardless of route type)
// =============================================================================
@description('Hub Routing Preference for Hub1 (westus). ExpressRoute is the Azure default; the local-connection-beats-remote-hub rule still overrides Remote Hub at this setting. VpnGateway/ASPath also available.')
@allowed(['ExpressRoute', 'VpnGateway', 'ASPath'])
param hub1RoutingPreference string = 'ExpressRoute'

@description('Hub Routing Preference for Hub2 (westus3). ExpressRoute is the Azure default; the local-connection-beats-remote-hub rule still overrides Remote Hub at this setting. VpnGateway/ASPath also available.')
@allowed(['ExpressRoute', 'VpnGateway', 'ASPath'])
param hub2RoutingPreference string = 'ExpressRoute'

@description('Hub Routing Preference for Hub3 (eastus2). ExpressRoute = control-plane baseline (no VPN transit override). ASPath demonstrates path-length selection.')
@allowed(['ExpressRoute', 'VpnGateway', 'ASPath'])
param hub3RoutingPreference string = 'ExpressRoute'

@description('Pre-shared key for VPN tunnels')
@secure()
param vpnPsk string

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

// =============================================================================
// Network Infrastructure (vWAN, Hub1, Hub2, Hub3, On-Prem VNet)
// =============================================================================
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubName: hubName
    hub2Name: hub2Name
    hub2Location: hub2Location
    hub3Name: hub3Name
    hub3Location: hub3Location
    hub1RoutingPreference: hub1RoutingPreference
    hub2RoutingPreference: hub2RoutingPreference
    hub3RoutingPreference: hub3RoutingPreference
  }
}

// =============================================================================
// VPN Gateways (one per hub, deployed in parallel - ~30 min each)
// =============================================================================
module vpnGateway 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-deployment'
  params: {
    location: location
    hubName: hubName
    hubId: network.outputs.hubId
  }
}

module vpnGatewayHub2 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-hub2-deployment'
  params: {
    location: hub2Location
    hubName: hub2Name
    hubId: network.outputs.hub2Id
  }
}

module vpnGatewayHub3 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-hub3-deployment'
  params: {
    location: hub3Location
    hubName: hub3Name
    hubId: network.outputs.hub3Id
  }
}

// =============================================================================
// FRR/strongSwan VMs - Transit Routers (on-prem, tunnels to all 3 hubs)
// =============================================================================

// Primary router (Instance 0 peers) - re-advertises between Hub1 ↔ Hub2
module frrVm 'modules/frr-vm.bicep' = {
  scope: rg
  name: 'frr-vm-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.onpremSubnetId
    vpnPsk: vpnPsk
    hubVpnGwBgpIp0: vpnGateway.outputs.bgpPeeringAddress0
    hubVpnGwPublicIp0: vpnGateway.outputs.publicIpAddress0
    hub2VpnGwBgpIp0: vpnGatewayHub2.outputs.bgpPeeringAddress0
    hub2VpnGwPublicIp0: vpnGatewayHub2.outputs.publicIpAddress0
    hub3VpnGwBgpIp0: vpnGatewayHub3.outputs.bgpPeeringAddress0
    hub3VpnGwPublicIp0: vpnGatewayHub3.outputs.publicIpAddress0
  }
}

// Backup router (Instance 1 peers) - always deployed; VPN connections only created when enableBackupVpn=true
module frrVmBackup 'modules/frr-vm-backup.bicep' = {
  scope: rg
  name: 'frr-vm-backup-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.onpremSubnetId
    vpnPsk: vpnPsk
    hubVpnGwBgpIp1: vpnGateway.outputs.bgpPeeringAddress1
    hubVpnGwPublicIp1: vpnGateway.outputs.publicIpAddress1
    hub2VpnGwBgpIp1: vpnGatewayHub2.outputs.bgpPeeringAddress1
    hub2VpnGwPublicIp1: vpnGatewayHub2.outputs.publicIpAddress1
    hub3VpnGwBgpIp1: vpnGatewayHub3.outputs.bgpPeeringAddress1
    hub3VpnGwPublicIp1: vpnGatewayHub3.outputs.publicIpAddress1
  }
}

// =============================================================================
// VPN Sites and Connections (2 sites per hub = 6 connections total)
// =============================================================================

// Hub1 VPN Sites (primary + backup)
module vpnSites 'modules/vpn-sites.bicep' = {
  scope: rg
  name: 'vpn-sites-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubVpnGwName: vpnGateway.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress
    onpremPublicIp2: enableBackupVpn ? frrVmBackup.outputs.publicIpAddress : ''
    onpremBgpIp: frrVm.outputs.privateIpAddress
    onpremBgpIp2: enableBackupVpn ? frrVmBackup.outputs.privateIpAddress : ''
    vpnPsk: vpnPsk
    enableBackupVpn: enableBackupVpn
  }
  dependsOn: [spokes]  // Serialize hub operations to avoid UpdateGatewayInProgress
}

// Hub2 VPN Sites (primary + backup)
module vpnSitesHub2 'modules/vpn-sites-hub2.bicep' = {
  scope: rg
  name: 'vpn-sites-hub2-deployment'
  params: {
    location: location
    vwanName: vwanName
    hub2VpnGwName: vpnGatewayHub2.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress
    onpremPublicIp2: enableBackupVpn ? frrVmBackup.outputs.publicIpAddress : ''
    onpremBgpIp: frrVm.outputs.privateIpAddress
    onpremBgpIp2: enableBackupVpn ? frrVmBackup.outputs.privateIpAddress : ''
    vpnPsk: vpnPsk
    enableBackupVpn: enableBackupVpn
  }
  dependsOn: [spokesHub2]  // Serialize hub operations to avoid UpdateGatewayInProgress
}

// Hub3 VPN Sites (primary + backup)
module vpnSitesHub3 'modules/vpn-sites-hub3.bicep' = {
  scope: rg
  name: 'vpn-sites-hub3-deployment'
  params: {
    location: location
    vwanName: vwanName
    hub3VpnGwName: vpnGatewayHub3.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress
    onpremPublicIp2: enableBackupVpn ? frrVmBackup.outputs.publicIpAddress : ''
    onpremBgpIp: frrVm.outputs.privateIpAddress
    onpremBgpIp2: enableBackupVpn ? frrVmBackup.outputs.privateIpAddress : ''
    vpnPsk: vpnPsk
    enableBackupVpn: enableBackupVpn
  }
  dependsOn: [spokesHub3]  // Serialize hub operations to avoid UpdateGatewayInProgress
}

// =============================================================================
// Azure Firewall (optional - for each hub)
// =============================================================================
module firewall 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-deployment'
  params: {
    location: location
    hubName: hubName
    firewallSku: firewallSku
    enableRoutingIntent: enableRoutingIntent
  }
  dependsOn: [
    network
    vpnGateway
  ]
}

module firewallHub2 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-hub2-deployment'
  params: {
    location: hub2Location
    hubName: hub2Name
    firewallSku: firewallSku
    enableRoutingIntent: enableRoutingIntent
  }
  dependsOn: [
    network
    vpnGatewayHub2
  ]
}

module firewallHub3 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-hub3-deployment'
  params: {
    location: hub3Location
    hubName: hub3Name
    firewallSku: firewallSku
    enableRoutingIntent: enableRoutingIntent
  }
  dependsOn: [
    network
    vpnGatewayHub3
  ]
}

// =============================================================================
// Azure Bastion (optional - for management access)
// =============================================================================
module bastion 'modules/bastion.bicep' = if (enableBastion) {
  scope: rg
  name: 'bastion-deployment'
  params: {
    location: location
    vnetName: network.outputs.onpremVnetName
  }
}

// =============================================================================
// Spoke VNets (2 per hub = 6 spokes total)
// =============================================================================
module spokes 'modules/spokes.bicep' = {
  scope: rg
  name: 'spokes-deployment'
  params: {
    location: location
    hubId: network.outputs.hubId
  }
  dependsOn: [
    vpnGateway
  ]
}

module spokesHub2 'modules/spokes-hub2.bicep' = {
  scope: rg
  name: 'spokes-hub2-deployment'
  params: {
    location: hub2Location
    hub2Id: network.outputs.hub2Id
  }
  dependsOn: [
    vpnGatewayHub2
  ]
}

module spokesHub3 'modules/spokes-hub3.bicep' = {
  scope: rg
  name: 'spokes-hub3-deployment'
  params: {
    location: hub3Location
    hub3Id: network.outputs.hub3Id
  }
  dependsOn: [
    vpnGatewayHub3
  ]
}

// =============================================================================
// Workload VMs (on-prem + 2 per hub = 7 VMs total)
// =============================================================================
module workloadVms 'modules/workload-vms.bicep' = {
  scope: rg
  name: 'workload-vms-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    onpremSubnetId: network.outputs.onpremWorkloadsSubnetId
    spoke1SubnetId: spokes.outputs.spoke1SubnetId
    spoke2SubnetId: spokes.outputs.spoke2SubnetId
  }
}

module workloadVmsHub2 'modules/workload-vms-hub2.bicep' = {
  scope: rg
  name: 'workload-vms-hub2-deployment'
  params: {
    location: hub2Location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    spoke3SubnetId: spokesHub2.outputs.spoke3SubnetId
    spoke4SubnetId: spokesHub2.outputs.spoke4SubnetId
  }
}

module workloadVmsHub3 'modules/workload-vms-hub3.bicep' = {
  scope: rg
  name: 'workload-vms-hub3-deployment'
  params: {
    location: hub3Location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    spoke5SubnetId: spokesHub3.outputs.spoke5SubnetId
    spoke6SubnetId: spokesHub3.outputs.spoke6SubnetId
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vwanId string = network.outputs.vwanId
output hubId string = network.outputs.hubId
output hub2Id string = network.outputs.hub2Id
output hub3Id string = network.outputs.hub3Id
output frrVmPublicIp string = frrVm.outputs.publicIpAddress
output frrVmPrivateIp string = frrVm.outputs.privateIpAddress
output frrVmBackupPublicIp string = frrVmBackup.outputs.publicIpAddress
output frrVmBackupPrivateIp string = frrVmBackup.outputs.privateIpAddress
output hubVpnGwPublicIp0 string = vpnGateway.outputs.publicIpAddress0
output hubVpnGwPublicIp1 string = vpnGateway.outputs.publicIpAddress1
output hub2VpnGwPublicIp0 string = vpnGatewayHub2.outputs.publicIpAddress0
output hub2VpnGwPublicIp1 string = vpnGatewayHub2.outputs.publicIpAddress1
output hub3VpnGwPublicIp0 string = vpnGatewayHub3.outputs.publicIpAddress0
output hub3VpnGwPublicIp1 string = vpnGatewayHub3.outputs.publicIpAddress1
output onpremVmPrivateIp string = workloadVms.outputs.onpremVmPrivateIp
output spoke1VmPrivateIp string = workloadVms.outputs.spoke1VmPrivateIp
output spoke2VmPrivateIp string = workloadVms.outputs.spoke2VmPrivateIp
output spoke3VmPrivateIp string = workloadVmsHub2.outputs.spoke3VmPrivateIp
output spoke4VmPrivateIp string = workloadVmsHub2.outputs.spoke4VmPrivateIp
output spoke5VmPrivateIp string = workloadVmsHub3.outputs.spoke5VmPrivateIp
output spoke6VmPrivateIp string = workloadVmsHub3.outputs.spoke6VmPrivateIp
