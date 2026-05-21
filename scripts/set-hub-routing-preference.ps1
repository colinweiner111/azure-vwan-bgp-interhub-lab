# =============================================================================
# set-hub-routing-preference.ps1
# =============================================================================
# Toggle Hub Routing Preference (HRP) on one or all vWAN hubs at runtime.
#
# HRP controls which learned route type wins when multiple paths to the same
# prefix exist. With VPN transit re-advertisement this directly determines
# whether inter-hub (Remote Hub) or VPN gateway paths are used.
#
# Allowed values per hub:
#   ExpressRoute  - Default Azure behavior. Priority: ER > VPN > Remote Hub.
#                   With no ER in this lab, VPN still overrides Remote Hub
#                   when gateway-learned routes are present.
#   VpnGateway    - VPN gateway-learned routes override Remote Hub routes.
#                   Triggers the inter-hub route override behavior.
#   ASPath        - Shortest BGP AS-path wins regardless of route type.
#                   With FRR stripping AS 65515 (as-path exclude), VPN path
#                   is shorter than Remote Hub path (65520-65520), so VPN
#                   still wins. Combine with AS-path prepend to flip this.
#
# Examples:
#   # Set all hubs to default ER preference (baseline)
#   .\set-hub-routing-preference.ps1 -Hub1 ExpressRoute -Hub2 ExpressRoute -Hub3 ExpressRoute
#
#   # Trigger override on Hub1+Hub2, leave Hub3 as control
#   .\set-hub-routing-preference.ps1 -Hub1 VpnGateway -Hub2 VpnGateway
#
#   # Test AS-path selection (pair with prepend script for full effect)
#   .\set-hub-routing-preference.ps1 -Hub1 ASPath -Hub2 ASPath -Hub3 ASPath
#
#   # Single-hub update
#   .\set-hub-routing-preference.ps1 -TargetHub hub1-westus -Preference ASPath
# =============================================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'vwan-bgp-interhub-lab',

    # Per-hub preference overrides (used when updating all three at once)
    [Parameter(Mandatory = $false)]
    [ValidateSet('ExpressRoute', 'VpnGateway', 'ASPath')]
    [string]$Hub1 = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('ExpressRoute', 'VpnGateway', 'ASPath')]
    [string]$Hub2 = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('ExpressRoute', 'VpnGateway', 'ASPath')]
    [string]$Hub3 = '',

    # Single-hub mode: target hub name + preference
    [Parameter(Mandatory = $false)]
    [string]$TargetHub = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('ExpressRoute', 'VpnGateway', 'ASPath')]
    [string]$Preference = '',

    # Show current HRP state and exit
    [switch]$ShowCurrent
)

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Step { param($msg) Write-Host "`n[$([math]::Round($stopwatch.Elapsed.TotalSeconds))s] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  --  $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "  !! $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Magenta
Write-Host "    Hub Routing Preference Manager - vWAN 3-Hub Lab" -ForegroundColor Magenta
Write-Host "  ================================================================" -ForegroundColor Magenta
Write-Host "  Resource Group : $ResourceGroupName" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────────────────────
# Discover hubs
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Discovering vWAN hubs in '$ResourceGroupName'..."

$hubs = az network vhub list --resource-group $ResourceGroupName --query "[].{name:name, hrp:hubRoutingPreference, location:location}" | ConvertFrom-Json
if (-not $hubs) { Write-Fail "No vWAN hubs found in '$ResourceGroupName'"; exit 1 }

# Map hub names to HRP values from parameters
$hubNameMap = @{}
foreach ($h in $hubs) {
    $hubNameMap[$h.name] = $h.hubRoutingPreference
}

Write-Host ""
Write-Host "  Current Hub Routing Preference:" -ForegroundColor White
Write-Host "  ┌─────────────────────────────────────────┬────────────────┬──────────────┐" -ForegroundColor DarkGray
Write-Host "  │ Hub                                     │ Location       │ HRP          │" -ForegroundColor DarkGray
Write-Host "  ├─────────────────────────────────────────┼────────────────┼──────────────┤" -ForegroundColor DarkGray
foreach ($h in ($hubs | Sort-Object name)) {
    $hrpColor = switch ($h.hrp) {
        'VpnGateway'    { 'Yellow' }
        'ASPath'        { 'Cyan' }
        default         { 'White' }
    }
    $hubPad  = $h.name.PadRight(39)
    $locPad  = $h.location.PadRight(14)
    $hrpPad  = ($h.hrp ?? 'ExpressRoute').PadRight(12)
    Write-Host "  │ $hubPad │ $locPad │ " -NoNewline -ForegroundColor DarkGray
    Write-Host $hrpPad -NoNewline -ForegroundColor $hrpColor
    Write-Host " │" -ForegroundColor DarkGray
}
Write-Host "  └─────────────────────────────────────────┴────────────────┴──────────────┘" -ForegroundColor DarkGray

if ($ShowCurrent) {
    Write-Host ""
    Write-Host "  Routing Preference Reference:" -ForegroundColor White
    Write-Host "    ExpressRoute  = ER > VPN > Remote Hub (Azure default)" -ForegroundColor DarkGray
    Write-Host "    VpnGateway    = VPN gateway-learned routes override Remote Hub" -ForegroundColor DarkGray
    Write-Host "    ASPath        = Shortest BGP AS-path wins (combine with prepend)" -ForegroundColor DarkGray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Build update list
# ─────────────────────────────────────────────────────────────────────────────
$updates = [System.Collections.Generic.List[hashtable]]::new()

if ($TargetHub -and $Preference) {
    # Single-hub mode
    $matchedHub = $hubs | Where-Object { $_.name -eq $TargetHub } | Select-Object -First 1
    if (-not $matchedHub) { Write-Fail "Hub '$TargetHub' not found in resource group"; exit 1 }
    $updates.Add(@{ name = $TargetHub; pref = $Preference; current = $matchedHub.hrp })
}
else {
    # Multi-hub mode - match by position (hub1/hub2/hub3 are sorted by name)
    $sortedHubs = $hubs | Sort-Object name
    $prefMap = @{ $sortedHubs[0].name = $Hub1; $sortedHubs[1].name = $Hub2 }
    if ($sortedHubs.Count -ge 3) { $prefMap[$sortedHubs[2].name] = $Hub3 }

    foreach ($h in $sortedHubs) {
        $desired = $prefMap[$h.name]
        if ($desired -and $desired -ne '') {
            $updates.Add(@{ name = $h.name; pref = $desired; current = $h.hrp })
        }
    }
}

if ($updates.Count -eq 0) {
    Write-Warn "No updates requested. Use -Hub1/-Hub2/-Hub3 or -TargetHub/-Preference."
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    .\set-hub-routing-preference.ps1 -Hub1 ASPath -Hub2 ASPath -Hub3 ASPath" -ForegroundColor DarkGray
    Write-Host "    .\set-hub-routing-preference.ps1 -TargetHub hub1-westus -Preference ASPath" -ForegroundColor DarkGray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Apply updates
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Applying Hub Routing Preference updates..."
Write-Host ""
Write-Host "  NOTE: Each hub update takes ~60-120s. Updates run sequentially" -ForegroundColor DarkGray
Write-Host "        to avoid simultaneous hub modifications." -ForegroundColor DarkGray

$anyFailed = $false
foreach ($u in $updates) {
    $arrow = "$($u.current ?? 'ExpressRoute') -> $($u.pref)"
    Write-Host ""
    Write-Host "  Updating $($u.name) ($arrow)..." -ForegroundColor Yellow
    $t = $stopwatch.Elapsed.TotalSeconds

    az network vhub update `
        --resource-group $ResourceGroupName `
        --name $u.name `
        --hub-routing-preference $u.pref `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to update $($u.name)"
        $anyFailed = $true
    }
    else {
        $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds - $t)
        Write-OK "$($u.name) set to $($u.pref) (${elapsed}s)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Post-update state
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Refreshing hub state..."
$hubs = az network vhub list --resource-group $ResourceGroupName --query "[].{name:name, hrp:hubRoutingPreference, location:location}" | ConvertFrom-Json

Write-Host ""
Write-Host "  Updated Hub Routing Preference:" -ForegroundColor White
Write-Host "  ┌─────────────────────────────────────────┬────────────────┬──────────────┐" -ForegroundColor DarkGray
Write-Host "  │ Hub                                     │ Location       │ HRP          │" -ForegroundColor DarkGray
Write-Host "  ├─────────────────────────────────────────┼────────────────┼──────────────┤" -ForegroundColor DarkGray
foreach ($h in ($hubs | Sort-Object name)) {
    $hrpColor = switch ($h.hrp) {
        'VpnGateway'    { 'Yellow' }
        'ASPath'        { 'Cyan' }
        default         { 'White' }
    }
    $hubPad  = $h.name.PadRight(39)
    $locPad  = $h.location.PadRight(14)
    $hrpPad  = ($h.hrp ?? 'ExpressRoute').PadRight(12)
    Write-Host "  │ $hubPad │ $locPad │ " -NoNewline -ForegroundColor DarkGray
    Write-Host $hrpPad -NoNewline -ForegroundColor $hrpColor
    Write-Host " │" -ForegroundColor DarkGray
}
Write-Host "  └─────────────────────────────────────────┴────────────────┴──────────────┘" -ForegroundColor DarkGray

$stopwatch.Stop()
Write-Host ""
if ($anyFailed) {
    Write-Host "  Completed with errors in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -ForegroundColor Red
} else {
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host "    Done in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -ForegroundColor Green
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    - Run validate-routes.ps1 to observe route changes" -ForegroundColor DarkGray
    Write-Host "    - Combine ASPath HRP with test-as-path-prepend.ps1 to" -ForegroundColor DarkGray
    Write-Host "      force Remote Hub paths by making VPN AS-path longer" -ForegroundColor DarkGray
}
