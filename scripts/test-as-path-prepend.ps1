# =============================================================================
# test-as-path-prepend.ps1
# =============================================================================
# Test Azure Route Map strategies on inbound VPN routes to control inter-hub
# path selection. Creates Route Maps on vWAN hub VPN connections to manipulate
# AS-path length (prepend), block transit routes (drop), or restrict inbound
# prefixes (filter), allowing the Remote Hub backbone path to win.
#
# Scenarios covered:
#   Scenario A (default):  No prepend. FRR already strips AS 65515 so VPN
#                          path is short. With HRP=VpnGateway or HRP=ASPath
#                          the VPN route wins.
#
#   Scenario B (2x prepend): Inject 2x ASN 64496 on VPN inbound. VPN path
#                          becomes: 65001, 64496, 64496 — same length as
#                          Remote Hub path (65520, 65520). Result: tie broken
#                          by HRP type (VpnGateway still wins, ASPath = TBD
#                          by Azure tiebreaking).
#
#   Scenario C (4x prepend): Inject 4x ASN 64496. VPN path explicitly longer
#                          than Remote Hub path. With HRP=ASPath the Remote Hub
#                          path wins — restoring normal inter-hub backbone
#                          routing even when VPN transit is active.
#
#   Scenario D (remove):   Remove route maps, reset to baseline (Scenario A).
#
#   Scenario E (drop):     Azure Route Map on inbound VPN connections drops
#                          any transit-re-advertised Azure spoke prefix
#                          (10.16.4.0/22, 10.16.8.0/22, 10.32.4.0/22,
#                          10.32.8.0/22, 10.48.4.0/22, 10.48.8.0/22).
#                          On-prem 10.0.0.0/16 passes.
#                          Works regardless of Hub Routing Preference.
#
#   Scenario F (filter):   Azure Route Map on inbound VPN connections permits
#                          only 10.0.0.0/16 (on-prem), drops everything else.
#                          Blanket deny — catches any unenumerated Azure prefixes.
#
# ASN choices for prepend:
#   64496-64511 = RFC 5398 documentation ASNs (Azure Route Maps accept these)
#   Cannot use private ASNs 64512-65534 or reserved ASNs via Azure route maps.
#
# Usage:
#   # Apply 4x prepend to all hubs (Remote Hub wins with HRP=ASPath)
#   .\test-as-path-prepend.ps1 -Scenario C
#
#   # Apply 2x prepend to Hub1 only (test asymmetric path influence)
#   .\test-as-path-prepend.ps1 -Scenario B -TargetHub hub1-westus
#
#   # Remove all route maps
#   .\test-as-path-prepend.ps1 -Scenario D
#
#   # Show current route map assignments
#   .\test-as-path-prepend.ps1 -ShowCurrent
#
# Recommended test sequence:
#   1. .\validate-routes.ps1                          # Baseline
#   2. .\set-hub-routing-preference.ps1 -Hub1 ASPath -Hub2 ASPath -Hub3 ASPath
#   3. .\validate-routes.ps1                          # ASPath, no prepend -> VPN wins
#   4. .\test-as-path-prepend.ps1 -Scenario C         # 4x prepend
#   5. .\validate-routes.ps1                          # ASPath + long VPN -> RemoteHub wins
#   6. .\test-as-path-prepend.ps1 -Scenario D         # Remove prepend
#   7. .\set-hub-routing-preference.ps1 -Hub1 VpnGateway -Hub2 VpnGateway  # Restore
# =============================================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'vwan-bgp-interhub-lab',

    # Test scenario
    [Parameter(Mandatory = $false)]
    [ValidateSet('A', 'B', 'C', 'D', 'E', 'F')]
    [string]$Scenario = 'C',

    # Optional: apply to one hub only (leave blank for all hubs)
    [Parameter(Mandatory = $false)]
    [string]$TargetHub = '',

    # Optional: apply to one connection name pattern (default: all VPN connections)
    [Parameter(Mandatory = $false)]
    [string]$ConnectionFilter = '',

    # Show current route map state and exit
    [switch]$ShowCurrent,

    # Create route maps but do not apply to connections
    [switch]$SkipApply,

    # Force removal even if dry-run (-WhatIf mode)
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Step { param($msg) Write-Host "`n[$([math]::Round($stopwatch.Elapsed.TotalSeconds))s] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  [~] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "  [!] $msg" -ForegroundColor Red }
function Write-Data { param($msg) Write-Host "      $msg" -ForegroundColor White }

# ─────────────────────────────────────────────────────────────────────────────
# Scenario definitions
# ─────────────────────────────────────────────────────────────────────────────
$prependAsn   = '64496'   # RFC 5398 documentation ASN - accepted by Azure Route Maps
$routeMapName = 'vpn-aspath-prepend'

$scenarioDefs = @{
    A = @{ prepends = 0;  description = 'No prepend (baseline) - VPN AS-path stripped by FRR, VPN route wins' }
    B = @{ prepends = 2;  description = '2x prepend (64496 64496) - VPN path ties Remote Hub, tiebreaker applies' }
    C = @{ prepends = 4;  description = '4x prepend (64496 x4) - VPN path explicitly longer, RemoteHub wins with HRP=ASPath' }
    D = @{ prepends = -1; description = 'Remove all route maps from connections' }
    E = @{ prepends = -2; description = 'DROP - Azure Route Map drops transit-re-advertised Azure spoke prefixes inbound (HRP-independent fix)' }
    F = @{ prepends = -3; description = 'FILTER - Azure Route Map permits only on-prem prefix (10.0.0.0/16), drops all Azure spoke routes inbound' }
}

$def = $scenarioDefs[$Scenario]

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Magenta
Write-Host "    AS-Path Prepend Route Map Test - vWAN 3-Hub Lab" -ForegroundColor Magenta
Write-Host "  ================================================================" -ForegroundColor Magenta
Write-Host "  Resource Group : $ResourceGroupName" -ForegroundColor DarkGray
Write-Host "  Scenario       : $Scenario - $($def.description)" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────────────────────
# Discover hubs and gateways
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Discovering hubs and VPN gateways..."

$hubs = az network vhub list --resource-group $ResourceGroupName `
    --query "[].{name:name, hrp:hubRoutingPreference}" | ConvertFrom-Json

$vpnGws = az network vpn-gateway list --resource-group $ResourceGroupName `
    --query "[].{name:name, hubId:virtualHub.id}" | ConvertFrom-Json

if ($TargetHub) {
    $hubs   = $hubs   | Where-Object { $_.name -eq $TargetHub }
    $vpnGws = $vpnGws | Where-Object { $_.hubId -like "*$TargetHub*" }
}

Write-OK "Processing $($hubs.Count) hub(s) / $($vpnGws.Count) gateway(s)"

# ─────────────────────────────────────────────────────────────────────────────
# Show current state
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Current VPN connection route map assignments..."

foreach ($gw in ($vpnGws | Sort-Object name)) {
    $conns = az network vpn-gateway connection list `
        --resource-group $ResourceGroupName `
        --gateway-name $gw.name `
        --query "[].{name:name, inRM:routingConfiguration.inboundRouteMap.id, bgp:enableBgp}" 2>$null | ConvertFrom-Json

    Write-Data "Gateway: $($gw.name)"
    foreach ($c in $conns) {
        $rm = if ($c.inRM) { ($c.inRM -split '/')[-1] } else { '(none)' }
        Write-Data "  $($c.name.PadRight(30)) InboundRouteMap: $rm  BGP: $($c.bgp)"
    }
}

if ($ShowCurrent) { exit 0 }

# ─────────────────────────────────────────────────────────────────────────────
# Scenario D: Remove route maps
# ─────────────────────────────────────────────────────────────────────────────
if ($Scenario -eq 'D') {
    Write-Step "Removing AS-path prepend route maps from all connections..."

    foreach ($gw in ($vpnGws | Sort-Object name)) {
        # Find hub for this gateway
        $hubName = ($hubs | Where-Object { $gw.hubId -like "*$($_.name)*" } | Select-Object -First 1).name
        if (-not $hubName) {
            # Try matching by gateway name pattern
            $hubName = $gw.name -replace '-vpngw$', ''
        }

        $conns = az network vpn-gateway connection list `
            --resource-group $ResourceGroupName `
            --gateway-name $gw.name `
            --query "[?routingConfiguration.inboundRouteMap.id != null].name" 2>$null | ConvertFrom-Json

        if (-not $conns -or $conns.Count -eq 0) {
            Write-Warn "No connections with inbound route maps on $($gw.name)"
            continue
        }

        foreach ($connName in $conns) {
            if ($ConnectionFilter -and $connName -notlike "*$ConnectionFilter*") { continue }

            Write-Host "  Clearing route map from $($gw.name)/$connName..." -ForegroundColor Yellow
            if (-not $WhatIf) {
                az network vpn-gateway connection update `
                    --resource-group $ResourceGroupName `
                    --gateway-name $gw.name `
                    --name $connName `
                    --remove routingConfiguration.inboundRouteMap `
                    --output none
                if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to clear route map"; continue }
            }
            Write-OK "Cleared from $connName"
        }

        # Clean up all route map resources created by this script (prepend, drop, filter)
        if ($hubName) {
            $allMaps = @($routeMapName, 'vpn-drop-transit-azure', 'vpn-filter-onprem-only')
            foreach ($mapName in $allMaps) {
                $existing = az network vhub route-map show `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hubName `
                    --name $mapName 2>$null | ConvertFrom-Json

                if ($existing -and -not $WhatIf) {
                    Write-Host "  Deleting route map '$mapName' from $hubName..." -ForegroundColor Yellow
                    az network vhub route-map delete `
                        --resource-group $ResourceGroupName `
                        --vhub-name $hubName `
                        --name $mapName `
                        --yes --output none 2>$null
                    Write-OK "Route map '$mapName' deleted from $hubName"
                }
            }
        }
    }

    $stopwatch.Stop()
    Write-Host ""
    Write-OK "All route maps removed in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s"
    Write-Host "  Run validate-routes.ps1 to confirm baseline (VPN override) is restored." -ForegroundColor DarkGray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario E: DROP transit Azure spoke routes at the hub (inbound Route Map)
# ─────────────────────────────────────────────────────────────────────────────
# Creates an inbound Route Map on each hub's VPN connections that drops routes
# matching any Azure spoke prefix. On-prem routes (10.0.0.0/16) are permitted.
# This works regardless of Hub Routing Preference — the route is dropped before
# the hub's route selection logic runs.
#
# Expected result:
#   Hub1/Hub2 stop receiving Hub2/Hub1 spoke prefixes via VPN entirely.
#   Those prefixes are only learned via Remote Hub (backbone), so effective
#   routes flip from VPN_S2S_Gateway back to Remote Hub.
# ─────────────────────────────────────────────────────────────────────────────
if ($Scenario -eq 'E') {
    Write-Step "Scenario E: Creating DROP Route Map for transit Azure spoke prefixes..."

    # Azure spoke prefixes that should NOT be re-advertised between hubs
    $azureSpokePrefixes = @(
        '10.16.4.0/22',   # Hub1 spoke1
        '10.16.8.0/22',   # Hub1 spoke2
        '10.32.4.0/22',   # Hub2 spoke3
        '10.32.8.0/22',   # Hub2 spoke4
        '10.48.4.0/22',   # Hub3 spoke5
        '10.48.8.0/22'    # Hub3 spoke6
    )
    $prefixArrayJson = ($azureSpokePrefixes | ForEach-Object { "`"$_`"" }) -join ','

    $dropRouteMapName = 'vpn-drop-transit-azure'

    # Route map rules:
    #   Rule 1: Match any Azure spoke prefix → Drop (Terminate)
    #   Rule 2: Everything else (on-prem 10.0.0.0/16) → Continue (permit)
    $dropRulesJson = @"
[
  {
    "name": "rule1-drop-azure-spoke-transit",
    "matchCriteria": [
      {
        "matchCondition": "Contains",
        "routePrefix": [$prefixArrayJson]
      }
    ],
    "actions": [
      { "type": "Drop" }
    ],
    "nextStepIfMatched": "Terminate"
  },
  {
    "name": "rule2-permit-rest",
    "matchCriteria": [],
    "actions": [],
    "nextStepIfMatched": "Continue"
  }
]
"@

    foreach ($hub in ($hubs | Sort-Object name)) {
        Write-Step "Hub: $($hub.name)"

        $tempFile = [System.IO.Path]::GetTempFileName()
        $dropRulesJson | Out-File -FilePath $tempFile -Encoding utf8NoBOM

        try {
            # Remove existing drop route map if present
            $existing = az network vhub route-map show `
                --resource-group $ResourceGroupName `
                --vhub-name $hub.name `
                --name $dropRouteMapName 2>$null

            if ($existing -and -not $WhatIf) {
                Write-Warn "Removing existing '$dropRouteMapName' to recreate..."
                az network vhub route-map delete `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hub.name `
                    --name $dropRouteMapName `
                    --yes --output none 2>$null
            }

            if (-not $WhatIf) {
                Write-Host "  Creating drop route map '$dropRouteMapName'..." -ForegroundColor Yellow
                az network vhub route-map create `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hub.name `
                    --name $dropRouteMapName `
                    --rules "@$tempFile" `
                    --output none
                if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to create drop route map on $($hub.name)"; continue }
                Write-OK "Drop route map created on $($hub.name)"
            }
            else {
                Write-Warn "[WhatIf] Would create drop route map '$dropRouteMapName'"
            }

            if (-not $SkipApply) {
                $routeMapId = az network vhub route-map show `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hub.name `
                    --name $dropRouteMapName `
                    --query "id" -o tsv 2>$null

                $hubGw = $vpnGws | Where-Object { $_.hubId -like "*$($hub.name)*" } | Select-Object -First 1
                if (-not $hubGw) { Write-Warn "No VPN gateway found for $($hub.name)"; continue }

                $conns = az network vpn-gateway connection list `
                    --resource-group $ResourceGroupName `
                    --gateway-name $hubGw.name `
                    --query "[?vpnLinkConnections[?enableBgp==\`true\`]].name" 2>$null | ConvertFrom-Json

                foreach ($connName in $conns) {
                    if ($ConnectionFilter -and $connName -notlike "*$ConnectionFilter*") { continue }
                    Write-Host "  Applying inbound drop map to $($hubGw.name)/$connName..." -ForegroundColor Yellow
                    if (-not $WhatIf) {
                        az network vpn-gateway connection update `
                            --resource-group $ResourceGroupName `
                            --gateway-name $hubGw.name `
                            --name $connName `
                            --set routingConfiguration.inboundRouteMap.id=$routeMapId `
                            --output none
                        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to apply drop route map to $connName"; continue }
                    }
                    Write-OK "Drop route map applied to $connName"
                }
            }
        }
        finally {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    $stopwatch.Stop()
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host "    Scenario E applied in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -ForegroundColor Green
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  What was applied: $($def.description)" -ForegroundColor DarkGray
    Write-Host "  Dropped prefixes: $($azureSpokePrefixes -join ', ')" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    Wait 60-90s for BGP reconvergence, then run:" -ForegroundColor DarkGray
    Write-Host "    .\\validate-routes.ps1" -ForegroundColor Cyan
    Write-Host "    Expected: Hub1/Hub2 cross-hub spoke routes flip to Remote Hub" -ForegroundColor DarkGray
    Write-Host "    To undo: .\\test-as-path-prepend.ps1 -Scenario D" -ForegroundColor DarkGray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario F: FILTER - permit only on-prem prefix inbound, drop all Azure routes
# ─────────────────────────────────────────────────────────────────────────────
# More aggressive than Scenario E. Creates an inbound Route Map that:
#   Rule 1: Permit 10.0.0.0/16 (on-prem)
#   Rule 2: Drop everything else (catches any Azure-learned routes, hub prefixes, etc.)
#
# This is the "deny any Azure route at hub level" mitigation — useful when you
# cannot enumerate all Azure spoke prefixes and want a blanket deny.
# ─────────────────────────────────────────────────────────────────────────────
if ($Scenario -eq 'F') {
    Write-Step "Scenario F: Creating FILTER Route Map (permit on-prem only, drop rest)..."

    $onpremPrefix     = '10.0.0.0/16'
    $filterRouteMapName = 'vpn-filter-onprem-only'

    $filterRulesJson = @"
[
  {
    "name": "rule1-permit-onprem",
    "matchCriteria": [
      {
        "matchCondition": "Equals",
        "routePrefix": ["$onpremPrefix"]
      }
    ],
    "actions": [],
    "nextStepIfMatched": "Terminate"
  },
  {
    "name": "rule2-drop-all-other",
    "matchCriteria": [],
    "actions": [
      { "type": "Drop" }
    ],
    "nextStepIfMatched": "Terminate"
  }
]
"@

    foreach ($hub in ($hubs | Sort-Object name)) {
        Write-Step "Hub: $($hub.name)"

        $tempFile = [System.IO.Path]::GetTempFileName()
        $filterRulesJson | Out-File -FilePath $tempFile -Encoding utf8NoBOM

        try {
            $existing = az network vhub route-map show `
                --resource-group $ResourceGroupName `
                --vhub-name $hub.name `
                --name $filterRouteMapName 2>$null

            if ($existing -and -not $WhatIf) {
                Write-Warn "Removing existing '$filterRouteMapName' to recreate..."
                az network vhub route-map delete `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hub.name `
                    --name $filterRouteMapName `
                    --yes --output none 2>$null
            }

            if (-not $WhatIf) {
                Write-Host "  Creating filter route map '$filterRouteMapName'..." -ForegroundColor Yellow
                az network vhub route-map create `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hub.name `
                    --name $filterRouteMapName `
                    --rules "@$tempFile" `
                    --output none
                if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to create filter route map on $($hub.name)"; continue }
                Write-OK "Filter route map created on $($hub.name)"
            }
            else {
                Write-Warn "[WhatIf] Would create filter route map '$filterRouteMapName'"
            }

            if (-not $SkipApply) {
                $routeMapId = az network vhub route-map show `
                    --resource-group $ResourceGroupName `
                    --vhub-name $hub.name `
                    --name $filterRouteMapName `
                    --query "id" -o tsv 2>$null

                $hubGw = $vpnGws | Where-Object { $_.hubId -like "*$($hub.name)*" } | Select-Object -First 1
                if (-not $hubGw) { Write-Warn "No VPN gateway found for $($hub.name)"; continue }

                $conns = az network vpn-gateway connection list `
                    --resource-group $ResourceGroupName `
                    --gateway-name $hubGw.name `
                    --query "[?vpnLinkConnections[?enableBgp==\`true\`]].name" 2>$null | ConvertFrom-Json

                foreach ($connName in $conns) {
                    if ($ConnectionFilter -and $connName -notlike "*$ConnectionFilter*") { continue }
                    Write-Host "  Applying inbound filter map to $($hubGw.name)/$connName..." -ForegroundColor Yellow
                    if (-not $WhatIf) {
                        az network vpn-gateway connection update `
                            --resource-group $ResourceGroupName `
                            --gateway-name $hubGw.name `
                            --name $connName `
                            --set routingConfiguration.inboundRouteMap.id=$routeMapId `
                            --output none
                        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to apply filter route map to $connName"; continue }
                    }
                    Write-OK "Filter route map applied to $connName"
                }
            }
        }
        finally {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    $stopwatch.Stop()
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host "    Scenario F applied in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -ForegroundColor Green
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  What was applied: $($def.description)" -ForegroundColor DarkGray
    Write-Host "  Permitted:        $onpremPrefix (on-prem only)" -ForegroundColor DarkGray
    Write-Host "  Dropped:          All other inbound routes" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    Wait 60-90s for BGP reconvergence, then run:" -ForegroundColor DarkGray
    Write-Host "    .\\validate-routes.ps1" -ForegroundColor Cyan
    Write-Host "    Expected: VPN connections only contribute 10.0.0.0/16 to hub route table" -ForegroundColor DarkGray
    Write-Host "    To undo: .\\test-as-path-prepend.ps1 -Scenario D" -ForegroundColor DarkGray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenarios A / B / C: Create route map with N prepends
# ─────────────────────────────────────────────────────────────────────────────
$prependCount = $def.prepends

Write-Step "Building route map: $prependCount prepend(s) of ASN $prependAsn"

# Build route map rules JSON
if ($prependCount -eq 0) {
    # Scenario A: pass-through (no-op route map)
    $rulesJson = @"
[
  {
    "name": "rule1-passthrough",
    "matchCriteria": [],
    "actions": [],
    "nextStepIfMatched": "Continue"
  }
]
"@
}
else {
    $prependArray = (1..$prependCount | ForEach-Object { "`"$prependAsn`"" }) -join ","
    $rulesJson = @"
[
  {
    "name": "rule1-prepend-aspath",
    "matchCriteria": [],
    "actions": [
      {
        "type": "Add",
        "parameters": [{"asPath": [$prependArray]}]
      }
    ],
    "nextStepIfMatched": "Continue"
  }
]
"@
}

# Apply to each hub
foreach ($hub in ($hubs | Sort-Object name)) {
    Write-Step "Hub: $($hub.name) [HRP=$($hub.hrp ?? 'ExpressRoute')]"

    $tempFile = [System.IO.Path]::GetTempFileName()
    $rulesJson | Out-File -FilePath $tempFile -Encoding utf8NoBOM

    try {
        # Create or update route map
        $existing = az network vhub route-map show `
            --resource-group $ResourceGroupName `
            --vhub-name $hub.name `
            --name $routeMapName 2>$null

        if ($existing -and -not $WhatIf) {
            Write-Warn "Deleting existing route map '$routeMapName' to recreate..."
            az network vhub route-map delete `
                --resource-group $ResourceGroupName `
                --vhub-name $hub.name `
                --name $routeMapName `
                --yes --output none 2>$null
        }

        if (-not $WhatIf) {
            Write-Host "  Creating route map '$routeMapName' ($prependCount prepend(s))..." -ForegroundColor Yellow
            az network vhub route-map create `
                --resource-group $ResourceGroupName `
                --vhub-name $hub.name `
                --name $routeMapName `
                --rules "@$tempFile" `
                --output none
            if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to create route map on $($hub.name)"; continue }
            Write-OK "Route map '$routeMapName' created on $($hub.name)"
        }
        else {
            Write-Warn "[WhatIf] Would create route map '$routeMapName' with $prependCount prepend(s)"
        }

        # Get route map ID
        $routeMapId = az network vhub route-map show `
            --resource-group $ResourceGroupName `
            --vhub-name $hub.name `
            --name $routeMapName `
            --query "id" -o tsv 2>$null

        if (-not $SkipApply -and $routeMapId) {
            # Apply to each VPN connection on this hub's gateway
            $hubGw = $vpnGws | Where-Object { $_.hubId -like "*$($hub.name)*" } | Select-Object -First 1
            if (-not $hubGw) {
                Write-Warn "No VPN gateway found for hub $($hub.name)"
                continue
            }

            $conns = az network vpn-gateway connection list `
                --resource-group $ResourceGroupName `
                --gateway-name $hubGw.name `
                --query "[?vpnLinkConnections[?enableBgp==\`true\`]].name" 2>$null | ConvertFrom-Json

            foreach ($connName in $conns) {
                if ($ConnectionFilter -and $connName -notlike "*$ConnectionFilter*") { continue }

                Write-Host "  Applying inbound route map to $($hubGw.name)/$connName..." -ForegroundColor Yellow
                if (-not $WhatIf) {
                    az network vpn-gateway connection update `
                        --resource-group $ResourceGroupName `
                        --gateway-name $hubGw.name `
                        --name $connName `
                        --set routingConfiguration.inboundRouteMap.id=$routeMapId `
                        --output none
                    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to apply route map to $connName"; continue }
                }
                Write-OK "Inbound route map applied to $connName"
            }
        }
        elseif ($SkipApply) {
            Write-Warn "Route map created but not applied (-SkipApply). RouteMap ID: $routeMapId"
        }
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
$stopwatch.Stop()
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "    Scenario $Scenario applied in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  What was applied:" -ForegroundColor White
Write-Host "    $($def.description)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Expected path selection:" -ForegroundColor White
switch ($Scenario) {
    'A' { Write-Host "    VPN path short (65001) < Remote Hub (65520, 65520)" -ForegroundColor Yellow
          Write-Host "    HRP=VpnGateway: VPN wins  |  HRP=ASPath: VPN wins  |  HRP=ER: VPN wins (GW override)" -ForegroundColor Yellow }
    'B' { Write-Host "    VPN path (65001, 64496, 64496) ~= Remote Hub (65520, 65520) — tie" -ForegroundColor Yellow
          Write-Host "    HRP=VpnGateway: VPN wins  |  HRP=ASPath: Azure tiebreaker decides  |  HRP=ER: GW override" -ForegroundColor Yellow }
    'C' { Write-Host "    VPN path (65001, 64496x4) > Remote Hub (65520, 65520) — VPN longer" -ForegroundColor Green
          Write-Host "    HRP=VpnGateway: VPN wins  |  HRP=ASPath: RemoteHub wins  |  HRP=ER: GW override" -ForegroundColor Green }
    'D' { Write-Host "    Baseline restored - see Scenario A" -ForegroundColor White }
}
Write-Host ""
Write-Host "  Run validate-routes.ps1 to observe route changes." -ForegroundColor DarkGray
Write-Host "  IMPORTANT: Allow 60-120s for route map changes to propagate." -ForegroundColor DarkGray
