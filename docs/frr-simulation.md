# FRR / strongSwan — ER Circuit Simulation

This lab has no real ExpressRoute circuit. Two **FRRouting + strongSwan** VMs stand in for it: they hold IPsec tunnels and BGP sessions to all three hub VPN gateways and **re-advertise each hub's spokes to the others** — mimicking how a single ER circuit's MSEE reflects routes between hubs. That reflection is what creates the inter-hub hairpin the lab reproduces.

> You only need this page if you're working on the simulation itself. The Azure behavior and the route-map fix are in the [main README](../README.md).

## FRR transit behavior

The FRR routers re-advertise every hub's spokes to the other hubs, replicating a single ER circuit whose MSEE reflects each hub's routes to its siblings — so **all three hubs** learn cross-hub spokes via their own gateway and hairpin inter-hub traffic.

| Hub | FRR Peer Role | BGP Outbound Policy |
|-----|---------------|---------------------|
| Hub1 (westus) | **TRANSIT** | On-prem `10.0.0.0/16` + re-advertised spokes from Hub2 + Hub3 |
| Hub2 (westus3) | **TRANSIT** | On-prem `10.0.0.0/16` + re-advertised spokes from Hub1 + Hub3 |
| Hub3 (eastus2) | **TRANSIT** | On-prem `10.0.0.0/16` + re-advertised spokes from Hub1 + Hub2 |

> **Control variant:** any hub can be returned to **STANDARD** (`STANDARD_OUT` route-map — on-prem only, no transit) to act as a known-good backbone control. Hub3 originally shipped this way; the default now makes all three transit to match the customer.

## How the override is forced — `as-path exclude 65515`

Because one FRR router talks eBGP to all three hubs, the Azure VPN gateway would normally see its own ASN `65515` in a re-advertised route and drop it (loop detection). The FRR route-maps apply `set as-path exclude 65515`, stripping it so the route is accepted — and as a side effect the gateway-learned path becomes **shorter** than the inter-hub backbone path (`65520 65520`). That's why the override persists even under `AS Path` Hub Routing Preference, and why the durable fix is an inbound Route Map that drops the prefixes, not HRP tuning.

In real environments the same AS-path loss happens more subtly: SD-WAN overlays that don't preserve AS-path, BGP→IGP→BGP redistribution, iBGP between on-prem routers, or static-route redistribution toward a different hub.

## Verify tunnels & BGP sessions

```bash
# On each FRR router (IPs in deployment output):
sudo ipsec status                          # expect 3 ESTABLISHED tunnels (one per hub)
sudo vtysh -c "show ip bgp summary"        # expect 3 peers Established

# What FRR advertises to a hub (all transit hubs get on-prem + sibling spokes):
sudo vtysh -c "show ip bgp neighbors <hub-bgp-ip> advertised-routes"
# Hub1 peer → 10.0.0.0/16 + 10.32.x + 10.48.x ; Hub3 peer → 10.0.0.0/16 + 10.16.x + 10.32.x
```

## Disable transit at the source

If you own the on-prem router, deny Azure spokes in the export policy instead of fixing it hub-side — cross-hub prefixes flip back to `Remote Hub`, on-prem `10.0.0.0/16` stays on the gateway:

```bash
sudo vtysh
configure terminal
router bgp 65001
 address-family ipv4 unicast
  neighbor <hub-bgp-ip> route-map STANDARD_OUT out   # on-prem only, per hub
 exit-address-family
end
clear ip bgp * soft out
```

Repeat on `frr-router-backup`.

## FRR-side AS-path prepend

The FRR-side equivalent of the Azure prepend fix (see README Scenario "HRP + AS-path prepend"): with hub HRP = `ASPath`, prepend on-prem advertisements so the gateway path is **longer** than `65520 65520`.

| FRR route-map | AS-path to Azure | Purpose |
|-----------|----------------------------|---------|
| `TRANSIT_OUT` | `65001` | Default — override active |
| `PREPEND2_OUT` | `65001 64496 64496` | 2× — tie with Remote Hub |
| `PREPEND4_OUT` | `65001 64496 ×4` | 4× — Remote Hub wins (HRP=ASPath) |
| `STANDARD_OUT` | `65001` (on-prem only) | Disables transit |
| `TRANSIT_OUT_SELECTIVE` | Hub1 spokes only | Asymmetric transit |

```bash
# Switch a neighbor to 4x prepend:
sudo vtysh -c 'configure terminal' -c 'router bgp 65001' -c 'address-family ipv4 unicast' \
  -c 'neighbor <hub-bgp-ip> route-map PREPEND4_OUT out' -c 'end' -c 'clear ip bgp * soft out'
```

> Azure Route Maps reject private (64512–65534) and reserved ASNs. Use documentation ASNs **64496–64511** ([RFC 5398](https://datatracker.ietf.org/doc/html/rfc5398)) as prepend values. The lab's peering ASN `65001` is valid for BGP but cannot be injected via Route Maps.

## FRR command reference

```bash
sudo vtysh -c "show ip bgp summary"                                  # 3 peers per VM
sudo vtysh -c "show ip bgp"                                          # full table
sudo vtysh -c "show ip bgp neighbors <peer-ip> advertised-routes"   # what we send a hub
sudo vtysh -c "show ip bgp neighbors <peer-ip> received-routes"     # what a hub sends us
sudo ipsec status                                                   # 3 SAs
sudo vtysh -c "show running-config"
sudo vtysh -c "show route-map"                                      # TRANSIT_OUT, PREPEND*_OUT, STANDARD_OUT
```

The FRR config (cloud-init) lives in [`modules/frr-vm.bicep`](../modules/frr-vm.bicep) and [`modules/frr-vm-backup.bicep`](../modules/frr-vm-backup.bicep).
