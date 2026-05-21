# =============================================================================
# validate-routes.ps1
# =============================================================================
# Comprehensive route validation for the vWAN 3-Hub VPN+BGP lab.
#
# Covers:
#   1. Hub Routing Preference state
#   2. Effective routes per hub (via az network vhub get-effective-routes)
#   3. VPN Gateway BGP peer status per hub
#   4. BGP learned routes from VPN connections (inbound from FRR)
#   5. Spoke VM effective route tables (Network Watcher)
#   6. Next-hop analysis: VPN_S2S_Gateway vs Remote Hub per prefix
#   7. Azure Firewall routing (if enabled)
#   8. FRR-side BGP state (SSH to on-prem VMs via Bastion or public IP)
#
# Usage:
#   # Full validation (all sections)
#   .\validate-routes.ps1
#
#   # Quick hub routes only
#   .\validate-routes.ps1 -QuickCheck
#
#   # Include FRR BGP state (requires SSH connectivity)
#   .\validate-routes.ps1 -IncludeFrrBgp
#
#   # Include spoke VM effective routes (slower - uses Network Watcher)
#   .\validate-routes.ps1 -IncludeSpokeRoutes
#
#   # Save full output to file
#   .\validate-routes.ps1 -OutputFile "routes-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
# =============================================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'vwan-bgp-interhub-lab',

    # Skip spoke VM NIC route tables (slow - Network Watcher API per NIC)
    [switch]$QuickCheck,

    # Also SSH to FRR VMs and collect vtysh BGP output
    [switch]$IncludeFrrBgp,

    # Include spoke VM effective route tables
    [switch]$IncludeSpokeRoutes,

    # Path to save full output (optional)
    [string]$OutputFile = '',

    # Admin username for SSH to FRR VMs
    [string]$SshUser = 'azureuser',

    # Private key path for SSH (optional - uses agent if omitted)
    [string]$SshKeyPath = ''
)

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$report    = [System.Text.StringBuilder]::new()

function Write-Step  { param($msg) $line = "`n[$([math]::Round($stopwatch.Elapsed.TotalSeconds))s] $msg"; Write-Host $line -ForegroundColor Cyan; $null = $report.AppendLine($line) }
function Write-OK    { param($msg) $line = "  [+] $msg"; Write-Host $line -ForegroundColor Green;  $null = $report.AppendLine($line) }
function Write-Warn  { param($msg) $line = "  [~] $msg"; Write-Host $line -ForegroundColor Yellow; $null = $report.AppendLine($line) }
function Write-Fail  { param($msg) $line = "  [!] $msg"; Write-Host $line -ForegroundColor Red;    $null = $report.AppendLine($line) }
function Write-Data  { param($msg) $line = "      $msg"; Write-Host $line -ForegroundColor White;  $null = $report.AppendLine($line) }
function Write-Title { param($msg) $line = "`n  --- $msg ---"; Write-Host $line -ForegroundColor Magenta; $null = $report.AppendLine($line) }

# Spoke prefixes expected in each hub's route table
$spokeMap = @{
    hub1 = @('10.100.0.0/16', '10.200.0.0/16')
    hub2 = @('10.110.0.0/16', '10.210.0.0/16')
    hub3 = @('10.120.0.0/16', '10.220.0.0/16')
}
$onpremPrefix  = '10.0.0.0/16'
$allSpokesCsv  = ($spokeMap.Values | ForEach-Object { $_ }) -join ', '

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Magenta
Write-Host "    vWAN 3-Hub Route Validation (VPN + BGP Lab)" -ForegroundColor Magenta
Write-Host "  ================================================================" -ForegroundColor Magenta
$null = $report.AppendLine("vWAN 3-Hub Route Validation Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$null = $report.AppendLine("Resource Group: $ResourceGroupName")

# ─────────────────────────────────────────────────────────────────────────────
# 1. Discover infrastructure
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "1. Discovering infrastructure..."

$hubs = az network vhub list --resource-group $ResourceGroupName `
    --query "[].{name:name, hrp:hubRoutingPreference, location:location, id:id}" | ConvertFrom-Json

if (-not $hubs -or $hubs.Count -eq 0) {
    Write-Fail "No vWAN hubs found in resource group '$ResourceGroupName'"
    exit 1
}

$vpnGws = az network vpn-gateway list --resource-group $ResourceGroupName `
    --query "[].{name:name, id:id, hubId:virtualHub.id}" | ConvertFrom-Json

$vms = az vm list --resource-group $ResourceGroupName `
    --query "[].{name:name, id:id}" | ConvertFrom-Json 2>$null

Write-OK "Found $($hubs.Count) hubs, $($vpnGws.Count) VPN gateways, $($vms.Count) VMs"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Hub Routing Preference state
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "2. Hub Routing Preference"
Write-Host ""
Write-Host "  Hub                                      Location        HRP             Override Behavior" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

foreach ($h in ($hubs | Sort-Object name)) {
    $hrp     = $h.hrp ?? 'ExpressRoute'
    $color   = switch ($hrp) { 'VpnGateway' { 'Yellow' } 'ASPath' { 'Cyan' } default { 'White' } }
    $behavior = switch ($hrp) {
        'VpnGateway'   { 'VPN gateway-learned routes beat Remote Hub' }
        'ASPath'       { 'Shortest AS-path wins (type-agnostic)' }
        'ExpressRoute' { 'ER > VPN > Remote Hub (Azure default)' }
        default        { 'ExpressRoute default' }
    }
    $line = "  $($h.name.PadRight(40)) $($h.location.PadRight(15)) $($hrp.PadRight(15)) $behavior"
    Write-Host $line -ForegroundColor $color
    $null = $report.AppendLine($line)
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Effective routes per hub
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "3. Hub Effective Routes (all connections)"

$hubRouteResults = @{}

foreach ($hub in ($hubs | Sort-Object name)) {
    Write-Title "Hub: $($hub.name) [$($hub.hrp ?? 'ExpressRoute')]"

    $rawRoutes = az network vhub get-effective-routes `
        --resource-group $ResourceGroupName `
        --name $hub.name `
        --query "value" 2>$null | ConvertFrom-Json

    if (-not $rawRoutes) {
        Write-Warn "Could not retrieve effective routes for $($hub.name)"
        continue
    }

    $hubRouteResults[$hub.name] = $rawRoutes

    # Categorize routes by next-hop type
    $remoteHubRoutes  = $rawRoutes | Where-Object { $_.nextHopType -eq 'Remote Hub' }
    $vpnGwRoutes      = $rawRoutes | Where-Object { $_.nextHopType -eq 'VPN_S2S_Gateway' }
    $vnetConnRoutes   = $rawRoutes | Where-Object { $_.nextHopType -eq 'HubVnetConnection' }
    $staticRoutes     = $rawRoutes | Where-Object { $_.nextHopType -eq 'Static' }

    Write-Data "Total routes:          $($rawRoutes.Count)"
    Write-Data "Remote Hub routes:     $($remoteHubRoutes.Count)"
    Write-Data "VPN_S2S_Gateway routes:$($vpnGwRoutes.Count)"
    Write-Data "HubVnetConnection:     $($vnetConnRoutes.Count)"

    # Analyze each spoke prefix
    Write-Host ""
    Write-Host "      Prefix              Next-Hop Type         AS-Path              Result" -ForegroundColor DarkGray
    Write-Host "      ───────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    foreach ($entry in ($rawRoutes | Where-Object { $_.addressPrefixes } | Sort-Object { $_.addressPrefixes[0] })) {
        foreach ($prefix in $entry.addressPrefixes) {
            $nh        = $entry.nextHopType
            $asPath    = if ($entry.asPath) { $entry.asPath } else { '(none)' }
            $nhColor   = switch ($nh) {
                'VPN_S2S_Gateway'   { 'Yellow' }
                'Remote Hub'        { 'Green' }
                'HubVnetConnection' { 'Cyan' }
                default             { 'White' }
            }
            $prefixPad = $prefix.PadRight(19)
            $nhPad     = $nh.PadRight(21)
            $asPathPad = $asPath.PadRight(20)

            # Flag if VPN overriding a cross-hub spoke
            $isCrossHub = $false
            foreach ($otherHub in $spokeMap.Keys) {
                if ($hub.name -notlike "*$otherHub*" -and $spokeMap[$otherHub] -contains $prefix) {
                    $isCrossHub = $true
                }
            }
            $flag = if ($isCrossHub -and $nh -eq 'VPN_S2S_Gateway') { '** OVERRIDE **' } elseif ($isCrossHub -and $nh -eq 'Remote Hub') { '(normal)' } else { '' }

            Write-Host "      $prefixPad " -NoNewline -ForegroundColor White
            Write-Host "$nhPad " -NoNewline -ForegroundColor $nhColor
            Write-Host "$asPathPad " -NoNewline -ForegroundColor DarkGray
            Write-Host $flag -ForegroundColor $(if ($flag -like '*OVERRIDE*') { 'Red' } else { 'DarkGreen' })
            $null = $report.AppendLine("      $prefixPad $nhPad $asPathPad $flag")
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. VPN Gateway BGP peer status
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "4. VPN Gateway BGP Peer Status"

foreach ($gw in ($vpnGws | Sort-Object name)) {
    Write-Title "Gateway: $($gw.name)"

    $peers = az network vpn-gateway list-bgp-peer-status `
        --resource-group $ResourceGroupName `
        --gateway-name $gw.name `
        --query "value" 2>$null | ConvertFrom-Json

    if (-not $peers) {
        Write-Warn "Could not retrieve BGP peers for $($gw.name)"
        continue
    }

    $connected    = $peers | Where-Object { $_.connectedDuration -ne $null -and $_.connectedDuration -ne '' }
    $disconnected = $peers | Where-Object { $_.connectedDuration -eq $null -or $_.connectedDuration -eq '' }

    Write-Data "Peers total:     $($peers.Count)   Connected: $($connected.Count)   Down: $($disconnected.Count)"
    Write-Host ""
    Write-Host "      Peer IP           State         ASN     Prefixes Rcvd  Prefixes Sent  Connected Duration" -ForegroundColor DarkGray
    Write-Host "      ───────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    foreach ($p in ($peers | Sort-Object neighbor)) {
        $state     = $p.state ?? 'Unknown'
        $stateColor = if ($state -eq 'Connected') { 'Green' } else { 'Red' }
        $asn       = $p.asn ?? '-'
        $rcvd      = $p.receivedPrefixCount ?? '-'
        $sent      = $p.advertisedPrefixCount ?? '-'
        $duration  = $p.connectedDuration ?? '(not connected)'
        $peerPad   = ($p.neighbor ?? '').PadRight(17)
        $statePad  = $state.PadRight(13)

        Write-Host "      $peerPad " -NoNewline -ForegroundColor White
        Write-Host "$statePad " -NoNewline -ForegroundColor $stateColor
        Write-Host "$($asn.ToString().PadRight(7)) $($rcvd.ToString().PadRight(14)) $($sent.ToString().PadRight(14)) $duration" -ForegroundColor White
        $null = $report.AppendLine("      $peerPad $statePad $asn  Rcvd=$rcvd Sent=$sent  $duration")
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. VPN Connection learned routes (BGP inbound table per hub)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "5. BGP Routes Learned from VPN Connections"

foreach ($gw in ($vpnGws | Sort-Object name)) {
    Write-Title "Gateway: $($gw.name)"

    $connections = az network vpn-gateway connection list `
        --resource-group $ResourceGroupName `
        --gateway-name $gw.name `
        --query "[].{name:name, id:id}" 2>$null | ConvertFrom-Json

    foreach ($conn in $connections) {
        Write-Data "Connection: $($conn.name)"

        $learnedRoutes = az network vpn-gateway connection show `
            --resource-group $ResourceGroupName `
            --gateway-name $gw.name `
            --name $conn.name `
            --query "properties.ingressBytesTransferred" 2>$null

        # Get inbound route map if any
        $connDetail = az network vpn-gateway connection show `
            --resource-group $ResourceGroupName `
            --gateway-name $gw.name `
            --name $conn.name `
            --query "{status:connectionStatus, inRM:routingConfiguration.inboundRouteMap.id, outRM:routingConfiguration.outboundRouteMap.id, bgp:enableBgp}" 2>$null | ConvertFrom-Json

        if ($connDetail) {
            $bgpStatus = if ($connDetail.bgp) { 'Enabled' } else { 'Disabled' }
            $inRM  = if ($connDetail.inRM)  { ($connDetail.inRM  -split '/')[-1] } else { '(none)' }
            $outRM = if ($connDetail.outRM) { ($connDetail.outRM -split '/')[-1] } else { '(none)' }
            Write-Data "  Status: $($connDetail.status ?? 'Unknown')   BGP: $bgpStatus   InboundRouteMap: $inRM   OutboundRouteMap: $outRM"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Spoke VM effective routes (optional - requires Network Watcher)
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeSpokeRoutes -and -not $QuickCheck) {
    Write-Step "6. Spoke VM Effective Route Tables (Network Watcher)"

    $spokeVms = $vms | Where-Object { $_.name -like 'spoke*-vm' }
    if (-not $spokeVms) {
        Write-Warn "No spoke VMs found (looking for names matching 'spoke*-vm')"
    }

    foreach ($vm in ($spokeVms | Sort-Object name)) {
        Write-Title "VM: $($vm.name)"

        # Get NIC attached to VM
        $nicId = az vm show --ids $vm.id --query "networkProfile.networkInterfaces[0].id" -o tsv 2>$null
        if (-not $nicId) { Write-Warn "Could not get NIC for $($vm.name)"; continue }
        $nicName = ($nicId -split '/')[-1]

        $routes = az network nic show-effective-route-table `
            --resource-group $ResourceGroupName `
            --name $nicName `
            --query "value[].{prefix:addressPrefix[0], nh:nextHopType, nhIp:nextHopIpAddress[0], source:source}" 2>$null | ConvertFrom-Json

        if (-not $routes) { Write-Warn "No routes returned for NIC $nicName"; continue }

        Write-Host ""
        Write-Host "      Prefix              NH Type              NH IP           Source" -ForegroundColor DarkGray
        Write-Host "      ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        foreach ($r in ($routes | Where-Object { $_.prefix -notlike '0.0.0.0*' } | Sort-Object prefix)) {
            $nhColor = switch ($r.nh) { 'VirtualNetworkGateway' { 'Yellow' } 'VnetLocal' { 'Cyan' } 'VirtualAppliance' { 'Magenta' } default { 'White' } }
            Write-Host "      $($r.prefix.PadRight(19)) $($r.nh.PadRight(20)) $($($r.nhIp ?? '-').PadRight(15)) $($r.source)" -ForegroundColor $nhColor
            $null = $report.AppendLine("      $($r.prefix.PadRight(19)) $($r.nh.PadRight(20)) $($($r.nhIp ?? '-').PadRight(15)) $($r.source)")
        }
    }
}
else {
    Write-Host ""
    Write-Warn "  Skipped spoke VM routes. Run with -IncludeSpokeRoutes to include."
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. FRR BGP state (optional - SSH to on-prem VMs)
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeFrrBgp -and -not $QuickCheck) {
    Write-Step "7. FRR BGP State (on-prem VMs)"

    $frrVms = $vms | Where-Object { $_.name -like 'frr-router*' }
    if (-not $frrVms) { Write-Warn "No FRR VMs found"; }

    foreach ($frrVm in ($frrVms | Sort-Object name)) {
        Write-Title "FRR VM: $($frrVm.name)"

        $pip = az vm show --ids $frrVm.id -d --query "publicIps" -o tsv 2>$null
        if (-not $pip) { Write-Warn "No public IP found for $($frrVm.name)"; continue }

        Write-Data "Public IP: $pip"

        $keyArg = if ($SshKeyPath) { "-i `"$SshKeyPath`"" } else { '' }
        $sshCmd = "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $keyArg $SshUser@$pip"

        # BGP summary
        Write-Data "--- BGP Summary ---"
        $bgpSummary = Invoke-Expression "$sshCmd 'sudo vtysh -c ""show ip bgp summary""'" 2>$null
        if ($bgpSummary) { $bgpSummary | ForEach-Object { Write-Data $_ } }
        else { Write-Warn "Could not retrieve BGP summary (SSH may require key or Bastion)" }

        # BGP neighbors advertised routes to each hub
        Write-Data "--- BGP Advertised Routes to Hub1 ---"
        $adv1 = Invoke-Expression "$sshCmd 'sudo vtysh -c ""show ip bgp neighbors advertised-routes""'" 2>$null
        if ($adv1) { $adv1 | Select-Object -First 30 | ForEach-Object { Write-Data $_ } }

        # Route maps active
        Write-Data "--- Active Route Maps ---"
        $rm = Invoke-Expression "$sshCmd 'sudo vtysh -c ""show route-map""'" 2>$null
        if ($rm) { $rm | Select-Object -First 40 | ForEach-Object { Write-Data $_ } }
    }
}
else {
    Write-Warn "  Skipped FRR BGP state. Run with -IncludeFrrBgp to include."
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Azure Firewall routing (if deployed)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "8. Azure Firewall Routing Intent"

$firewalls = az network firewall list --resource-group $ResourceGroupName `
    --query "[].{name:name, location:location}" 2>$null | ConvertFrom-Json

if (-not $firewalls -or $firewalls.Count -eq 0) {
    Write-Warn "No Azure Firewalls found (deploy with -enableFirewall true in Bicep)"
} else {
    foreach ($fw in $firewalls) {
        Write-Data "Firewall: $($fw.name) [$($fw.location)]"

        # Check for routing intent policies on the hub
        $hubName = ($hubs | Where-Object { $_.location -eq $fw.location } | Select-Object -First 1).name
        if ($hubName) {
            $routingIntent = az network vhub routing-intent show `
                --resource-group $ResourceGroupName `
                --vhub-name $hubName `
                --name 'RoutingIntent' 2>$null | ConvertFrom-Json
            if ($routingIntent) {
                Write-OK "Routing Intent configured on hub $hubName"
                Write-Data "  Private routing policy: $($routingIntent.properties.routingPolicies | Where-Object {$_.name -eq 'PrivateTraffic'} | Select-Object -ExpandProperty destinations -First 1)"
                Write-Data "  Internet routing policy: $($routingIntent.properties.routingPolicies | Where-Object {$_.name -eq 'PublicTraffic'} | Select-Object -ExpandProperty destinations -First 1)"
            } else {
                Write-Warn "No Routing Intent policy found on hub $hubName (traffic may not route through firewall)"
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Route override summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "9. Route Override Analysis Summary"

Write-Host ""
Write-Host "  Prefix              Hub1 Next-Hop         Hub2 Next-Hop         Hub3 Next-Hop" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

$allPrefixes = $spokeMap.Values | ForEach-Object { $_ } | Sort-Object

foreach ($prefix in $allPrefixes) {
    $row = "  $($prefix.PadRight(19)) "
    $rowColors = @()

    foreach ($hub in ($hubs | Sort-Object name)) {
        $routes = $hubRouteResults[$hub.name]
        if ($routes) {
            $match = $routes | Where-Object { $_.addressPrefixes -contains $prefix } | Select-Object -First 1
            $nh = $match.nextHopType ?? '-'
        } else {
            $nh = '?'
        }

        $nhShort = switch ($nh) {
            'VPN_S2S_Gateway'   { 'VPN_GW (OVERRIDE)' }
            'Remote Hub'        { 'RemoteHub (normal)' }
            'HubVnetConnection' { 'VnetConn (local)' }
            default             { $nh }
        }
        $row      += $nhShort.PadRight(22)
        $rowColors += $nh
    }

    # Colorize based on whether any hub shows unexpected overrides
    $hasOverride = $rowColors -contains 'VPN_S2S_Gateway'
    Write-Host $row -ForegroundColor $(if ($hasOverride) { 'Yellow' } else { 'Green' })
    $null = $report.AppendLine($row)
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Validation checklist
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "10. Validation Checklist"

$checks = [ordered]@{
    'Hub1 VPN peers connected'       = { ($vpnGws | Where-Object {$_.name -like '*hub1*'}) -ne $null }
    'Hub2 VPN peers connected'       = { ($vpnGws | Where-Object {$_.name -like '*hub2*'}) -ne $null }
    'Hub3 VPN peers connected'       = { ($vpnGws | Where-Object {$_.name -like '*hub3*'}) -ne $null }
    'Branch-to-Branch enabled'       = {
        $vwan = az network vwan list --resource-group $ResourceGroupName --query "[0].allowBranchToBranchTraffic" | ConvertFrom-Json
        $vwan -eq $true
    }
    'Hub1 HRP = VpnGateway (override test)' = {
        $h = $hubs | Where-Object { $_.name -like '*hub1*' } | Select-Object -First 1
        $h.hrp -eq 'VpnGateway'
    }
    'Hub3 HRP = ExpressRoute (control)' = {
        $h = $hubs | Where-Object { $_.name -like '*hub3*' } | Select-Object -First 1
        ($h.hrp ?? 'ExpressRoute') -eq 'ExpressRoute'
    }
}

foreach ($check in $checks.Keys) {
    try {
        $result = & $checks[$check]
        if ($result) { Write-OK $check } else { Write-Warn $check }
    } catch {
        Write-Warn "${check}: $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
$stopwatch.Stop()
$totalSecs = [math]::Round($stopwatch.Elapsed.TotalSeconds)
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "    Validation complete in ${totalSecs}s" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Interpretation guide:" -ForegroundColor White
Write-Host "    VPN_GW (OVERRIDE) = VPN gateway-learned route is winning over inter-hub backbone" -ForegroundColor Yellow
Write-Host "    RemoteHub (normal) = normal vWAN inter-hub backbone path" -ForegroundColor Green
Write-Host "    VnetConn (local)   = local spoke connection (expected for own-hub spokes)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Related scripts:" -ForegroundColor DarkGray
Write-Host "    set-hub-routing-preference.ps1  - Toggle HRP to test ExpressRoute / VpnGateway / ASPath" -ForegroundColor DarkGray
Write-Host "    test-as-path-prepend.ps1        - Apply AS-path prepend to VPN routes to flip path selection" -ForegroundColor DarkGray
Write-Host "    add-route-maps.ps1              - Summarize + prepend (ER failover scenario)" -ForegroundColor DarkGray

if ($OutputFile) {
    $null = $report.AppendLine("`nTotal time: ${totalSecs}s")
    $report.ToString() | Out-File -FilePath $OutputFile -Encoding utf8
    Write-Host ""
    Write-OK "Report saved to: $OutputFile"
}
