# =============================================================================
# 🚀 TURBO ROUTE MAPS - Add & Apply Route Maps to vWAN Hub
# =============================================================================
# Creates Route Map with Summarization + AS-Path Prepending:
#   1. Summarizes VPN /24 routes to /16 (matching ExpressRoute)
#   2. Prepends AS-path (64496) to deprioritize VPN when ER is available
#
# ASN Restrictions for Azure Route Maps:
#   - Private ASNs (64512-65534):    REJECTED
#   - Microsoft ASN (12076):         REJECTED
#   - Documentation ASNs (64496-64511): WORKS! (RFC 5398 - designed for examples)
#   - Public ASNs (1-64495):         Also works (e.g., 132, 174, 3356)
#
# This enables proper failover (VPN when ER down) AND failback (ER preferred).
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "vwan-failover-lab",
    
    [Parameter(Mandatory=$false)]
    [string]$HubName = "hub1",
    
    [Parameter(Mandatory=$false)]
    [string]$VpnConnectionName = "conn-vpn-backup",
    
    [Parameter(Mandatory=$false)]
    [string]$RouteMapName = "summarize-vpn",
    
    [Parameter(Mandatory=$false)]
    [string]$OnPremPrefix = "10.0.0.0/16",
    
    [Parameter(Mandatory=$false)]
    [string]$PrependAsn = "64496",  # RFC 5398 documentation ASN - ideal for labs/demos
    
    [switch]$SkipApply,
    [switch]$RemoveRouteMap,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Step { param($msg) Write-Host "`n[$([math]::Round($stopwatch.Elapsed.TotalSeconds))s] $msg" -ForegroundColor Cyan }
function Write-OK { param($msg) Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "  ✗ $msg" -ForegroundColor Red }

# Banner
Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║        🚀 TURBO ROUTE MAPS - vWAN Edition 🚀              ║" -ForegroundColor Magenta  
Write-Host "  ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host "  Resource Group : $ResourceGroupName" -ForegroundColor DarkGray
Write-Host "  Hub            : $HubName" -ForegroundColor DarkGray
Write-Host "  Connection     : $VpnConnectionName" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────────────────────
# REMOVE MODE
# ─────────────────────────────────────────────────────────────────────────────
if ($RemoveRouteMap) {
    Write-Step "REMOVE MODE - Clearing Route Map from connection..."
    
    # Get VPN Gateway name
    $vpnGwName = (az network vpn-gateway list -g $ResourceGroupName --query "[0].name" -o tsv)
    if (-not $vpnGwName) { Write-Fail "No VPN Gateway found"; exit 1 }
    
    # Clear the inbound route map from connection
    Write-Host "  Clearing inbound route map from $VpnConnectionName..." -ForegroundColor Yellow
    az network vpn-gateway connection update `
        --resource-group $ResourceGroupName `
        --gateway-name $vpnGwName `
        --name $VpnConnectionName `
        --set inboundRouteMap=null 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Inbound route map cleared from connection"
    }
    
    if ($Force) {
        Write-Host "  Deleting route map '$RouteMapName'..." -ForegroundColor Yellow
        az network vhub route-map delete `
            --resource-group $ResourceGroupName `
            --vhub-name $HubName `
            --name $RouteMapName `
            --yes 2>$null
        Write-OK "Route map deleted"
    }
    
    $stopwatch.Stop()
    Write-Host "`n🏁 Done in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s - Route map removed!" -ForegroundColor Green
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# CREATE ROUTE MAP (Summarize + AS-Path Prepend)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Creating Route Map '$RouteMapName'..."
Write-Host "  Summarize to: $OnPremPrefix" -ForegroundColor DarkGray
Write-Host "  AS-Path prepend: $PrependAsn, $PrependAsn" -ForegroundColor DarkGray

# Check if route map already exists
$existingRouteMap = az network vhub route-map show `
    --resource-group $ResourceGroupName `
    --vhub-name $HubName `
    --name $RouteMapName 2>$null

if ($existingRouteMap) {
    Write-Warn "Route Map already exists - will update"
}

# Write rules to temp file (avoids PowerShell JSON escaping hell)
# Rule 1: Summarize /24 routes to /16 using RoutePrefix Replace
# Rule 2: Prepend AS-path to deprioritize vs ExpressRoute
$rulesJson = @"
[
  {
    "name": "rule1-summarize",
    "matchCriteria": [
      {
        "matchCondition": "Contains",
        "routePrefix": ["$OnPremPrefix"]
      }
    ],
    "actions": [
      {
        "type": "Replace",
        "parameters": [{"routePrefix": ["$OnPremPrefix"]}]
      }
    ],
    "nextStepIfMatched": "Continue"
  },
  {
    "name": "rule2-prepend",
    "matchCriteria": [
      {
        "matchCondition": "Contains",
        "routePrefix": ["$OnPremPrefix"]
      }
    ],
    "actions": [
      {
        "type": "Add",
        "parameters": [{"asPath": ["$PrependAsn", "$PrependAsn"]}]
      }
    ],
    "nextStepIfMatched": "Continue"
  }
]
"@

$tempFile = [System.IO.Path]::GetTempFileName()
$rulesJson | Out-File -FilePath $tempFile -Encoding utf8NoBOM

try {
    az network vhub route-map create `
        --resource-group $ResourceGroupName `
        --vhub-name $HubName `
        --name $RouteMapName `
        --rules "@$tempFile" `
        --output none
    
    if ($LASTEXITCODE -ne 0) { throw "Failed to create route map" }
    Write-OK "Route Map created/updated"
}
finally {
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# APPLY TO CONNECTION (automatic!)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipApply) {
    Write-Step "Applying Route Map to VPN connection..."
    
    # Get VPN Gateway name
    $vpnGwName = (az network vpn-gateway list -g $ResourceGroupName --query "[0].name" -o tsv)
    if (-not $vpnGwName) {
        Write-Fail "No VPN Gateway found in resource group"
        exit 1
    }
    Write-Host "  Found VPN Gateway: $vpnGwName" -ForegroundColor DarkGray
    
    # Get Route Map resource ID
    $routeMapId = (az network vhub route-map show `
        --resource-group $ResourceGroupName `
        --vhub-name $HubName `
        --name $RouteMapName `
        --query "id" -o tsv)
    
    if (-not $routeMapId) {
        Write-Fail "Could not get Route Map ID"
        exit 1
    }
    Write-Host "  Route Map ID: ...$(($routeMapId -split '/')[-1])" -ForegroundColor DarkGray
    
    # Apply inbound route map to the VPN backup connection
    Write-Host "  Updating connection (this takes ~60-90s)..." -ForegroundColor Yellow
    
    $updateStart = $stopwatch.Elapsed.TotalSeconds
    az network vpn-gateway connection update `
        --resource-group $ResourceGroupName `
        --gateway-name $vpnGwName `
        --name $VpnConnectionName `
        --set routingConfiguration.inboundRouteMap.id=$routeMapId `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to apply route map to connection"
        exit 1
    }
    
    $updateDuration = [math]::Round($stopwatch.Elapsed.TotalSeconds - $updateStart)
    Write-OK "Route Map applied to '$VpnConnectionName' ($updateDuration`s)"
}
else {
    Write-Warn "Skipped applying to connection (-SkipApply)"
    Write-Host ""
    Write-Host "  Manual steps to apply:" -ForegroundColor Yellow
    Write-Host "  1. Portal → Virtual WAN → $HubName → VPN (Site to site)"
    Write-Host "  2. Click '$VpnConnectionName' → Edit"
    Write-Host "  3. Set Inbound Route Map = '$RouteMapName'"
    Write-Host "  4. Save"
}

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipApply) {
    Write-Step "Verifying configuration..."
    
    $vpnGwName = (az network vpn-gateway list -g $ResourceGroupName --query "[0].name" -o tsv)
    $connConfig = az network vpn-gateway connection show `
        --resource-group $ResourceGroupName `
        --gateway-name $vpnGwName `
        --name $VpnConnectionName `
        --query "{routeMap: inboundRouteMap.id, status: connectionStatus}" 2>$null | ConvertFrom-Json
    
    if ($connConfig.routeMap -like "*$RouteMapName*") {
        Write-OK "Inbound route map is configured!"
    }
    else {
        Write-Warn "Route map may not be applied yet (check Portal)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# DONE!
# ─────────────────────────────────────────────────────────────────────────────
$stopwatch.Stop()
Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  🏁 TURBO COMPLETE in $([math]::Round($stopwatch.Elapsed.TotalSeconds).ToString().PadLeft(3))s                               ║" -ForegroundColor Green
Write-Host "  ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  VPN routes are now:" -ForegroundColor White
Write-Host "    1. Summarized to $OnPremPrefix (matching ER prefix)" -ForegroundColor White
Write-Host "    2. AS-path prepended (deprioritized vs ER)" -ForegroundColor White
Write-Host ""
Write-Host "  ✓ Failover:  VPN backup when ER is down" -ForegroundColor Green
Write-Host "  ✓ Failback:  ER preferred when restored" -ForegroundColor Green
Write-Host ""
Write-Host "  Tip: Use -RemoveRouteMap to revert, -SkipApply to create only" -ForegroundColor DarkGray
