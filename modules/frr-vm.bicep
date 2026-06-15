// =============================================================================
// FRR/strongSwan VM Module - Primary Router (Instance 0) - Multi-Hub Transit
// =============================================================================
// Creates:
// - Linux VM with FRRouting + strongSwan
// - Cloud-init configuration for:
//   * 3 IPsec tunnels to each hub's vWAN VPN Gateway Instance 0
//   * BGP peers to each Instance 0, advertising on-prem 10.0.0.0/16
//   * Transit routing: re-advertises routes learned from Hub1 ↔ Hub2
//   * Hub3 only receives static on-prem prefix (no transit)
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param sshPublicKey string
param vmSize string
param subnetId string
@secure()
param vpnPsk string

// Hub1 vWAN VPN Gateway Instance 0
param hubVpnGwBgpIp0 string      // e.g., 10.16.0.13
param hubVpnGwPublicIp0 string   // Instance 0 public IP

// Hub2 vWAN VPN Gateway Instance 0
param hub2VpnGwBgpIp0 string     // e.g., 10.32.0.13
param hub2VpnGwPublicIp0 string  // Instance 0 public IP

// Hub3 vWAN VPN Gateway Instance 0
param hub3VpnGwBgpIp0 string     // e.g., 10.48.0.13
param hub3VpnGwPublicIp0 string  // Instance 0 public IP

var vmName = 'frr-router'
var nicName = '${vmName}-nic'
var publicIpName = '${vmName}-pip'
var onpremAsn = 65001

// =============================================================================
// Public IP
// =============================================================================
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// =============================================================================
// Network Interface
// =============================================================================
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.0.10'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
          primary: true
        }
      }
    ]
    enableIPForwarding: true
  }
}

// =============================================================================
// Cloud-init configuration for FRR + strongSwan (Primary - Multi-Hub Transit)
// =============================================================================
// 3 IPsec tunnels (one per hub) + 3 BGP peers
// Hub1 & Hub2 = TRANSIT peers (re-advertise learned routes between them)
// Hub3 = STANDARD peer (only on-prem prefix, no transit)
//
// format() placeholders:
//   {0} = Hub1 VPN GW Public IP (Instance 0)
//   {1} = VPN PSK
//   {2} = on-prem ASN (65001)
//   {3} = Hub1 VPN GW BGP IP (Instance 0)
//   {4} = Hub2 VPN GW Public IP (Instance 0)
//   {5} = Hub2 VPN GW BGP IP (Instance 0)
//   {6} = Hub3 VPN GW Public IP (Instance 0)
//   {7} = Hub3 VPN GW BGP IP (Instance 0)
// =============================================================================
var cloudInitConfig = format('''#cloud-config
package_update: true
package_upgrade: true

packages:
  - strongswan
  - strongswan-pki
  - libcharon-extra-plugins
  - frr
  - frr-pythontools
  - netcat-openbsd

write_files:
  # strongSwan ipsec.conf - 3 VTI tunnels to each hub's VPN Gateway Instance 0
  - path: /etc/ipsec.conf
    content: |
      config setup
        charondebug="ike 1, knl 1"

      conn %default
        ikelifetime=28800s
        keylife=3600s
        rekeymargin=3m
        keyingtries=3
        keyexchange=ikev2
        authby=secret
        ike=aes256-sha256-modp1024!
        esp=aes256-sha256!
        type=tunnel
        auto=start
        dpdaction=restart
        dpddelay=30s
        dpdtimeout=120s
        leftsubnet=0.0.0.0/0
        rightsubnet=0.0.0.0/0
        leftid=%any
        leftupdown=/opt/flush-mangle.sh

      # Hub1 VTI tunnel (westus) - VPN GW Instance 0
      conn primary-hub1
        left=%defaultroute
        right={0}
        rightid={0}
        mark=100

      # Hub2 VTI tunnel (westus3) - VPN GW Instance 0
      conn primary-hub2
        left=%defaultroute
        right={4}
        rightid={4}
        mark=200

      # Hub3 VTI tunnel (eastus2) - VPN GW Instance 0
      conn primary-hub3
        left=%defaultroute
        right={6}
        rightid={6}
        mark=300

  # strongSwan updown script - flushes iptables mangle rules that strongSwan
  # auto-creates from mark= config. These mangle rules break BGP over VTI because
  # they cause XfrmInTmplMismatch on inbound. VTI handles marking via tunnel key,
  # so the mangle rules are unnecessary. Must flush after every tunnel UP event
  # (not just at boot) since strongSwan re-adds them on each rekey/reconnect.
  - path: /opt/flush-mangle.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      if [ "$PLUTO_VERB" = "up-client" ] || [ "$PLUTO_VERB" = "up-client-v6" ]; then
        sleep 2
        iptables-legacy -t mangle -F PREROUTING 2>/dev/null || true
        iptables-legacy -t mangle -F OUTPUT 2>/dev/null || true
        logger -t flush-mangle "Flushed iptables mangle chains after $PLUTO_CONNECTION $PLUTO_VERB"
      fi

  # strongSwan secrets
  - path: /etc/ipsec.secrets
    permissions: '0600'
    content: |
      : PSK "{1}"

  # FRR daemons config
  - path: /etc/frr/daemons
    content: |
      zebra=yes
      bgpd=yes
      ospfd=no
      ospf6d=no
      ripd=no
      ripngd=no
      isisd=no
      pimd=no
      ldpd=no
      nhrpd=no
      eigrpd=no
      babeld=no
      sharpd=no
      staticd=yes
      pbrd=no
      bfdd=no
      fabricd=no
      vrrpd=no
      pathd=no

  # FRR configuration - Transit router between Hub1 and Hub2
  # Hub3 only gets static on-prem prefix (no transit re-advertisement)
  # __LOCAL_IP__ will be replaced at runtime with actual private IP
  - path: /etc/frr/frr.conf
    content: |
      frr version 8.1
      frr defaults traditional
      hostname frr-router
      log syslog informational
      service integrated-vtysh-config
      !
      ! Static route for on-prem advertisement (high admin distance
      ! so it doesn't blackhole intra-VNet traffic to workload subnets)
      ip route 10.0.0.0/16 Null0 250
      !
      ! Allow next-hop resolution via default route (required for BGP
      ! next-hops reachable only through IPsec tunnel policies)
      ip nht resolve-via-default
      !
      ! === Prefix Lists ===
      ! ONPREM: static on-prem prefix only
      ip prefix-list ONPREM seq 5 permit 10.0.0.0/16
      !
      ! AZURE_LEARNED: accept spoke prefixes learned from Azure hubs
      ip prefix-list AZURE_LEARNED seq 5 permit 10.16.4.0/22
      ip prefix-list AZURE_LEARNED seq 10 permit 10.16.8.0/22
      ip prefix-list AZURE_LEARNED seq 15 permit 10.32.4.0/22
      ip prefix-list AZURE_LEARNED seq 20 permit 10.32.8.0/22
      ip prefix-list AZURE_LEARNED seq 25 permit 10.48.4.0/22
      ip prefix-list AZURE_LEARNED seq 30 permit 10.48.8.0/22
      !
      ! === Route Maps ===
      ! TRANSIT_OUT: advertise on-prem + re-advertise learned Azure routes
      ! as-path exclude 65515 strips the Azure VPN GW ASN to prevent loop detection
      ! when re-advertising routes back to the hub that originally sent them
      route-map TRANSIT_OUT permit 10
        match ip address prefix-list ONPREM
      route-map TRANSIT_OUT permit 20
        match ip address prefix-list AZURE_LEARNED
        set as-path exclude 65515
      route-map TRANSIT_OUT deny 100
      !
      ! TRANSIT_IN: strip Azure VPN GW ASN on inbound to avoid sender-side
      ! eBGP loop check when re-advertising to another AS 65515 peer
      route-map TRANSIT_IN permit 10
        set as-path exclude 65515
      !
      ! STANDARD_OUT: only advertise on-prem prefix (no transit)
      route-map STANDARD_OUT permit 10
        match ip address prefix-list ONPREM
      route-map STANDARD_OUT deny 100
      !
      ! === AS-Path Prepend Variants (for Hub Routing Preference = ASPath testing) ===
      !
      ! PREPEND2_OUT: on-prem + transit routes with 2x ASN 64496 prepended.
      !   VPN advertised path becomes: 65001, 64496, 64496
      !   Remote Hub path remains:     65520, 65520
      !   Result with HRP=ASPath: tie — Azure tiebreaker applies.
      !   Use: vtysh -c "neighbor X.X.X.X route-map PREPEND2_OUT out"
      !        vtysh -c "clear ip bgp X.X.X.X soft out"
      route-map PREPEND2_OUT permit 10
        match ip address prefix-list ONPREM
        set as-path prepend 64496 64496
      route-map PREPEND2_OUT permit 20
        match ip address prefix-list AZURE_LEARNED
        set as-path exclude 65515
        set as-path prepend 64496 64496
      route-map PREPEND2_OUT deny 100
      !
      ! PREPEND4_OUT: on-prem + transit routes with 4x ASN 64496 prepended.
      !   VPN advertised path becomes: 65001, 64496, 64496, 64496, 64496
      !   Remote Hub path remains:     65520, 65520
      !   Result with HRP=ASPath: Remote Hub wins (VPN path is longer).
      !   Use: vtysh -c "neighbor X.X.X.X route-map PREPEND4_OUT out"
      !        vtysh -c "clear ip bgp X.X.X.X soft out"
      route-map PREPEND4_OUT permit 10
        match ip address prefix-list ONPREM
        set as-path prepend 64496 64496 64496 64496
      route-map PREPEND4_OUT permit 20
        match ip address prefix-list AZURE_LEARNED
        set as-path exclude 65515
        set as-path prepend 64496 64496 64496 64496
      route-map PREPEND4_OUT deny 100
      !
      ! TRANSIT_OUT_SELECTIVE: transit re-advertisement for Hub1 spokes only.
      !   Advertises Hub1 spokes to Hub2 but NOT Hub2 spokes to Hub1.
      !   Simulates asymmetric SD-WAN or selective re-advertisement.
      ip prefix-list HUB1_SPOKES seq 5 permit 10.16.4.0/22
      ip prefix-list HUB1_SPOKES seq 10 permit 10.16.8.0/22
      route-map TRANSIT_OUT_SELECTIVE permit 10
        match ip address prefix-list ONPREM
      route-map TRANSIT_OUT_SELECTIVE permit 20
        match ip address prefix-list HUB1_SPOKES
        set as-path exclude 65515
      route-map TRANSIT_OUT_SELECTIVE deny 100
      !
      ! === BGP Configuration ===
      router bgp {2}
        bgp router-id __LOCAL_IP__
        no bgp ebgp-requires-policy
        bgp log-neighbor-changes
        !
        ! --- TRANSIT peers: Hub1 and Hub2 (re-advertise between them) ---
        !
        ! Hub1 (westus) - VPN GW Instance 0
        neighbor {3} remote-as 65515
        neighbor {3} ebgp-multihop 64
        neighbor {3} update-source __LOCAL_IP__
        neighbor {3} timers 3 9
        neighbor {3} description TRANSIT-HUB1
        !
        ! Hub2 (westus3) - VPN GW Instance 0
        neighbor {5} remote-as 65515
        neighbor {5} ebgp-multihop 64
        neighbor {5} update-source __LOCAL_IP__
        neighbor {5} timers 3 9
        neighbor {5} description TRANSIT-HUB2
        !
        ! --- STANDARD peer: Hub3 (on-prem only, no transit) ---
        !
        ! Hub3 (eastus2) - VPN GW Instance 0
        neighbor {7} remote-as 65515
        neighbor {7} ebgp-multihop 64
        neighbor {7} update-source __LOCAL_IP__
        neighbor {7} timers 3 9
        neighbor {7} description STANDARD-HUB3
        !
        address-family ipv4 unicast
          redistribute static
          !
          ! Hub1: accept all, advertise on-prem + transit routes
          neighbor {3} soft-reconfiguration inbound
          neighbor {3} route-map TRANSIT_IN in
          neighbor {3} route-map TRANSIT_OUT out
          neighbor {3} as-override
          !
          ! Hub2: accept all, advertise on-prem + transit routes
          neighbor {5} soft-reconfiguration inbound
          neighbor {5} route-map TRANSIT_IN in
          neighbor {5} route-map TRANSIT_OUT out
          neighbor {5} as-override
          !
          ! Hub3: accept all, advertise on-prem only (no transit)
          neighbor {7} soft-reconfiguration inbound
          neighbor {7} route-map STANDARD_OUT out
        exit-address-family
      !
      line vty
      !

  # Setup script - replaces __LOCAL_IP__ and adds routes
  - path: /opt/setup-vpn.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      LOG=/var/log/vpn-setup.log
      exec > >(tee -a $LOG) 2>&1
      echo "=== Primary Router Multi-Hub Transit Setup started at $(date) ==="
      
      # Get local private IP
      LOCAL_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){{3}}' | head -1)
      echo "Local IP: $LOCAL_IP"
      
      # Get default gateway
      DEFAULT_GW=$(ip route | grep default | awk '{{print $3}}')
      echo "Default Gateway: $DEFAULT_GW"
      
      # Replace __LOCAL_IP__ placeholder in FRR config
      sed -i "s/__LOCAL_IP__/$LOCAL_IP/g" /etc/frr/frr.conf
      
      # Enable IP forwarding and disable rp_filter for VTI
      cat >> /etc/sysctl.conf << 'SYSCTL'
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.rp_filter=0
      net.ipv4.conf.default.rp_filter=0
      net.ipv4.conf.eth0.rp_filter=0
      SYSCTL
      sysctl -w net.ipv4.ip_forward=1
      sysctl -w net.ipv4.conf.all.rp_filter=0
      sysctl -w net.ipv4.conf.default.rp_filter=0
      sysctl -w net.ipv4.conf.eth0.rp_filter=0
      
      # Create VTI interfaces for each hub tunnel
      echo "Creating VTI interfaces..."
      ip tunnel add vti1 local $LOCAL_IP remote {0} mode vti key 100
      ip addr add 169.254.0.1/32 dev vti1
      ip link set vti1 up mtu 1400
      sysctl -w net.ipv4.conf.vti1.disable_policy=1
      sysctl -w net.ipv4.conf.vti1.rp_filter=0
      
      ip tunnel add vti2 local $LOCAL_IP remote {4} mode vti key 200
      ip addr add 169.254.0.2/32 dev vti2
      ip link set vti2 up mtu 1400
      sysctl -w net.ipv4.conf.vti2.disable_policy=1
      sysctl -w net.ipv4.conf.vti2.rp_filter=0
      
      ip tunnel add vti3 local $LOCAL_IP remote {6} mode vti key 300
      ip addr add 169.254.0.3/32 dev vti3
      ip link set vti3 up mtu 1400
      sysctl -w net.ipv4.conf.vti3.disable_policy=1
      sysctl -w net.ipv4.conf.vti3.rp_filter=0
      
      # Prevent Azure table 220 (DHCP default route) from overriding VTI routes.
      # Hub BGP peer IPs (10.16.x, 10.32.x, 10.48.x) and spoke/on-prem data
      # plane (10.x.x.x) all fall within 10.0.0.0/8 — one rule covers both.
      #   (without this, transit traffic is sent out eth0 instead of VTI tunnels)
      echo "Adding ip rules for BGP peer and data plane routing..."
      ip rule add to 10.0.0.0/8 lookup main priority 100
      
      echo "Starting IPsec..."
      systemctl enable ipsec
      systemctl restart ipsec
      
      # Wait for tunnels to establish
      echo "Waiting for IPsec tunnels..."
      sleep 30
      ipsec status || true
      
      # Flush iptables-legacy mangle rules auto-created by strongSwan.
      # strongSwan's mark= config installs PREROUTING rules that mark
      # incoming ESP-in-UDP packets, but these marks cause
      # XfrmInTmplMismatch errors because the inbound SA has no mark.
      # VTI inbound works via SPI lookup without marks.
      iptables-legacy -t mangle -F PREROUTING || true
      iptables-legacy -t mangle -F OUTPUT || true
      
      # Add routes to BGP peers via VTI interfaces
      echo "Adding routes to BGP peers..."
      ip route add {3}/32 dev vti1 || true
      ip route add {5}/32 dev vti2 || true
      ip route add {7}/32 dev vti3 || true
      
      echo "Starting FRR..."
      systemctl enable frr
      systemctl restart frr
      
      # Wait for BGP to establish
      sleep 30
      
      echo "=== Setup complete at $(date) ==="
      echo ""
      echo "IPsec status:"
      ipsec status || true
      echo ""
      echo "BGP summary:"
      vtysh -c "show ip bgp summary" || true

runcmd:
  - /opt/setup-vpn.sh
''', hubVpnGwPublicIp0, vpnPsk, string(onpremAsn), hubVpnGwBgpIp0, hub2VpnGwPublicIp0, hub2VpnGwBgpIp0, hub3VpnGwPublicIp0, hub3VpnGwBgpIp0)

// =============================================================================
// Virtual Machine
// =============================================================================
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: sshPublicKey != ''
        ssh: sshPublicKey != '' ? {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        } : null
      }
      customData: base64(cloudInitConfig)
    }
    storageProfile: {
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vmId string = vm.id
output vmName string = vm.name
output publicIpAddress string = publicIp.properties.ipAddress
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
