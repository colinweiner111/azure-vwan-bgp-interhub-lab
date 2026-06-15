# =============================================================================
# compare-routes.ps1
# =============================================================================
# Before/after route snapshot and diff for the vWAN 3-Hub VPN+BGP lab.
#
# Captures hub effective routes to a JSON snapshot file, then compares two
# snapshots to show exactly which prefixes changed next-hop type, AS-path,
# or disappeared/appeared between lab state changes.
#
# Usage:
#   # Step 1 - capture baseline (transit ON, VPN override active)
#   .\compare-routes.ps1 -Snapshot -SnapshotFile before.json
#
#   # Apply a lab change (e.g., Scenario E drop, FRR filter, HRP change)
#   .\test-as-path-prepend.ps1 -Scenario E
#   Start-Sleep -Seconds 90   # allow BGP reconvergence
#
#   # Step 2 - capture after state
#   .\compare-routes.ps1 -Snapshot -SnapshotFile after.json
#
#   # Step 3 - diff the two snapshots
#   .\compare-routes.ps1 -Compare -Before before.json -After after.json
#
#   # One-shot: snapshot + compare in a single call (captures 'after', diffs vs existing 'before')
#   .\compare-routes.ps1 -Snapshot -SnapshotFile after.json -Compare -Before before.json
#
# Output:
#   - Colored diff table showing NextHopType and AS-path changes per prefix per hub
#   - Summary counts: routes improved (Remote Hub), degraded (VPN override), unchanged
#   - Optionally saved to a text report file
# =============================================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'vwan-bgp-interhub-lab',

    # Capture current hub effective routes to a JSON file
    [switch]$Snapshot,

    # Path to save snapshot JSON
    [Parameter(Mandatory = $false)]
    [string]$SnapshotFile = "snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss').json",

    # Compare two snapshots
    [switch]$Compare,

    # Path to before snapshot JSON
    [Parameter(Mandatory = $false)]
    [string]$Before = '',

    # Path to after snapshot JSON
    [Parameter(Mandatory = $false)]
    [string]$After = '',

    # Save comparison report to text file
    [Parameter(Mandatory = $false)]
    [string]$OutputFile = ''
)

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$report    = [System.Text.StringBuilder]::new()

function Write-Step  { param($m) $l = "`n[$([math]::Round($stopwatch.Elapsed.TotalSeconds))s] $m"; Write-Host $l -ForegroundColor Cyan;    $null = $report.AppendLine($l) }
function Write-OK    { param($m) $l = "  [+] $m"; Write-Host $l -ForegroundColor Green;   $null = $report.AppendLine($l) }
function Write-Warn  { param($m) $l = "  [~] $m"; Write-Host $l -ForegroundColor Yellow;  $null = $report.AppendLine($l) }
function Write-Fail  { param($m) $l = "  [!] $m"; Write-Host $l -ForegroundColor Red;     $null = $report.AppendLine($l) }
function Write-Data  { param($m) $l = "      $m"; Write-Host $l -ForegroundColor White;   $null = $report.AppendLine($l) }
function Write-Title { param($m) $l = "`n  --- $m ---"; Write-Host $l -ForegroundColor Magenta; $null = $report.AppendLine($l) }

if (-not $Snapshot -and -not $Compare) {
    Write-Host ""
    Write-Fail "Specify -Snapshot, -Compare, or both."
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    # Capture baseline"                                                   -ForegroundColor DarkGray
    Write-Host "    .\compare-routes.ps1 -Snapshot -SnapshotFile before.json"            -ForegroundColor DarkGray
    Write-Host "    # Capture after state"                                                -ForegroundColor DarkGray
    Write-Host "    .\compare-routes.ps1 -Snapshot -SnapshotFile after.json"             -ForegroundColor DarkGray
    Write-Host "    # Diff"                                                               -ForegroundColor DarkGray
    Write-Host "    .\compare-routes.ps1 -Compare -Before before.json -After after.json" -ForegroundColor DarkGray
    exit 1
}

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Magenta
Write-Host "    vWAN Hub Route Snapshot / Compare" -ForegroundColor Magenta
Write-Host "  ================================================================" -ForegroundColor Magenta
$null = $report.AppendLine("vWAN Hub Route Snapshot/Compare - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$null = $report.AppendLine("Resource Group: $ResourceGroupName")

# =============================================================================
# SNAPSHOT
# =============================================================================
if ($Snapshot) {
    Write-Step "Capturing hub effective routes to '$SnapshotFile'..."

    $hubs = az network vhub list --resource-group $ResourceGroupName `
        --query "[].{name:name, hrp:hubRoutingPreference, location:location}" | ConvertFrom-Json

    if (-not $hubs -or $hubs.Count -eq 0) {
        Write-Fail "No vWAN hubs found in '$ResourceGroupName'"
        exit 1
    }

    $snapshot = @{
        timestamp     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        resourceGroup = $ResourceGroupName
        hubs          = @{}
    }

    foreach ($hub in ($hubs | Sort-Object name)) {
        Write-Host "  Collecting: $($hub.name)..." -ForegroundColor Yellow

        $rawRoutes = az network vhub get-effective-routes `
            --resource-group $ResourceGroupName `
            --name $hub.name `
            --query "value" 2>$null | ConvertFrom-Json

        $routeEntries = @()
        if ($rawRoutes) {
            foreach ($r in $rawRoutes) {
                foreach ($prefix in $r.addressPrefixes) {
                    $routeEntries += @{
                        prefix      = $prefix
                        nextHopType = $r.nextHopType
                        nextHops    = $r.nextHops -join ','
                        asPath      = $r.asPath ?? ''
                        origin      = $r.origin ?? ''
                    }
                }
            }
        }

        $snapshot.hubs[$hub.name] = @{
            hrp      = $hub.hrp ?? 'ExpressRoute'
            location = $hub.location
            routes   = $routeEntries
        }

        Write-OK "$($hub.name): $($routeEntries.Count) route entries collected"
    }

    $snapshot | ConvertTo-Json -Depth 10 | Out-File -FilePath $SnapshotFile -Encoding utf8NoBOM
    Write-OK "Snapshot saved to '$SnapshotFile'"
}

# =============================================================================
# COMPARE
# =============================================================================
if ($Compare) {
    if (-not $Before -or -not $After) {
        Write-Fail "Both -Before and -After snapshot file paths are required for comparison."
        exit 1
    }
    if (-not (Test-Path $Before)) { Write-Fail "Before file not found: $Before"; exit 1 }
    if (-not (Test-Path $After))  { Write-Fail "After file not found: $After";  exit 1 }

    Write-Step "Comparing snapshots..."
    Write-Data "Before: $Before"
    Write-Data "After:  $After"

    $snapBefore = Get-Content $Before -Raw | ConvertFrom-Json
    $snapAfter  = Get-Content $After  -Raw | ConvertFrom-Json

    Write-Host ""
    $null = $report.AppendLine("")
    $null = $report.AppendLine("Before timestamp: $($snapBefore.timestamp)")
    $null = $report.AppendLine("After timestamp:  $($snapAfter.timestamp)")
    Write-Host "  Before: $($snapBefore.timestamp)" -ForegroundColor DarkGray
    Write-Host "  After:  $($snapAfter.timestamp)"  -ForegroundColor DarkGray

    # Spoke prefix ownership map for cross-hub detection
    $spokeOwner = @{
        '10.16.4.0/22' = 'hub1'; '10.16.8.0/22' = 'hub1'
        '10.32.4.0/22' = 'hub2'; '10.32.8.0/22' = 'hub2'
        '10.48.4.0/22' = 'hub3'; '10.48.8.0/22' = 'hub3'
    }

    $totalImproved  = 0
    $totalDegraded  = 0
    $totalUnchanged = 0
    $totalNew       = 0
    $totalRemoved   = 0

    # All hub names across both snapshots
    $allHubs = @(($snapBefore.hubs.PSObject.Properties.Name) + ($snapAfter.hubs.PSObject.Properties.Name)) | Sort-Object -Unique

    foreach ($hubName in $allHubs) {
        Write-Title "Hub: $hubName"

        $beforeHub = $snapBefore.hubs.$hubName
        $afterHub  = $snapAfter.hubs.$hubName

        if (-not $beforeHub) { Write-Warn "Hub '$hubName' not present in before snapshot"; continue }
        if (-not $afterHub)  { Write-Warn "Hub '$hubName' not present in after snapshot";  continue }

        $hrpBefore = $beforeHub.hrp ?? 'ExpressRoute'
        $hrpAfter  = $afterHub.hrp  ?? 'ExpressRoute'
        $hrpChange = if ($hrpBefore -ne $hrpAfter) { " → $hrpAfter" } else { '' }
        Write-Data "HRP: $hrpBefore$hrpChange"
        $null = $report.AppendLine("      HRP: $hrpBefore$hrpChange")

        # Index routes by prefix
        $beforeMap = @{}
        foreach ($r in $beforeHub.routes) { $beforeMap[$r.prefix] = $r }
        $afterMap  = @{}
        foreach ($r in $afterHub.routes)  { $afterMap[$r.prefix]  = $r }

        # All prefixes in either snapshot
        $allPrefixes = @(($beforeMap.Keys) + ($afterMap.Keys)) | Sort-Object -Unique

        Write-Host ""
        $hdrLine = "      {0,-22} {1,-22} {2,-22} {3,-22} {4}" -f 'Prefix','Before NextHop','After NextHop','AS-Path Change','Result'
        $sepLine  = "      {0}" -f ('-' * 105)
        Write-Host $hdrLine -ForegroundColor DarkGray
        Write-Host $sepLine -ForegroundColor DarkGray
        $null = $report.AppendLine($hdrLine)
        $null = $report.AppendLine($sepLine)

        foreach ($prefix in $allPrefixes) {
            $bRoute = $beforeMap[$prefix]
            $aRoute = $afterMap[$prefix]

            if (-not $bRoute) {
                # New route
                $line = "      {0,-22} {1,-22} {2,-22} {3,-22} {4}" -f $prefix, '(absent)', $aRoute.nextHopType, $aRoute.asPath, 'NEW'
                Write-Host $line -ForegroundColor Cyan
                $null = $report.AppendLine($line)
                $totalNew++
                continue
            }
            if (-not $aRoute) {
                # Removed route
                $line = "      {0,-22} {1,-22} {2,-22} {3,-22} {4}" -f $prefix, $bRoute.nextHopType, '(removed)', $bRoute.asPath, 'REMOVED'
                Write-Host $line -ForegroundColor DarkGray
                $null = $report.AppendLine($line)
                $totalRemoved++
                continue
            }

            $nhBefore  = $bRoute.nextHopType ?? ''
            $nhAfter   = $aRoute.nextHopType ?? ''
            $aspBefore = $bRoute.asPath      ?? ''
            $aspAfter  = $aRoute.asPath      ?? ''

            $nhChanged  = $nhBefore -ne $nhAfter
            $aspChanged = $aspBefore -ne $aspAfter

            # Determine cross-hub direction for result labeling
            $owner = $spokeOwner[$prefix]
            $isCrossHub = $owner -and $hubName -notlike "*$owner*"

            $result = ''
            $color  = 'White'

            if ($nhChanged) {
                if ($nhAfter -eq 'Remote Hub' -and $nhBefore -eq 'VPN_S2S_Gateway' -and $isCrossHub) {
                    $result = 'IMPROVED (backbone restored)'
                    $color  = 'Green'
                    $totalImproved++
                }
                elseif ($nhAfter -eq 'VPN_S2S_Gateway' -and $nhBefore -eq 'Remote Hub' -and $isCrossHub) {
                    $result = 'DEGRADED (VPN override)'
                    $color  = 'Red'
                    $totalDegraded++
                }
                else {
                    $result = "NH: $nhBefore -> $nhAfter"
                    $color  = 'Yellow'
                    $totalUnchanged++
                }
            }
            elseif ($aspChanged) {
                $result = "AS-path changed"
                $color  = 'Cyan'
                $totalUnchanged++
            }
            else {
                $result = 'unchanged'
                $color  = 'DarkGray'
                $totalUnchanged++
            }

            $aspDisplay = if ($aspChanged) { "$aspBefore -> $aspAfter" } else { $aspAfter }
            $line = "      {0,-22} {1,-22} {2,-22} {3,-22} {4}" -f $prefix, $nhBefore, $nhAfter, $aspDisplay, $result
            Write-Host $line -ForegroundColor $color
            $null = $report.AppendLine($line)
        }
    }

    # Summary
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Magenta
    Write-Host "    Comparison Summary" -ForegroundColor Magenta
    Write-Host "  ================================================================" -ForegroundColor Magenta
    $null = $report.AppendLine("`n  === Comparison Summary ===")

    $summaryLines = @(
        ("  Improved  (VPN_S2S_Gateway -> Remote Hub, cross-hub): " + $totalImproved)
        ("  Degraded  (Remote Hub -> VPN_S2S_Gateway, cross-hub): " + $totalDegraded)
        ("  Other changes (AS-path, other NH type):               " + ($totalUnchanged - $totalNew - $totalRemoved))
        ("  New routes:                                           " + $totalNew)
        ("  Removed routes:                                       " + $totalRemoved)
        ("  Unchanged:                                            " + ($totalUnchanged))
    )
    foreach ($line in $summaryLines) {
        $color = if ($line -match 'Improved') { 'Green' } elseif ($line -match 'Degraded') { 'Red' } else { 'White' }
        Write-Host $line -ForegroundColor $color
        $null = $report.AppendLine($line)
    }

    if ($totalImproved -gt 0 -and $totalDegraded -eq 0) {
        Write-Host ""
        Write-Host "  Result: All monitored cross-hub routes restored to Remote Hub (backbone). " -ForegroundColor Green
        $null = $report.AppendLine("  Result: PASS - all monitored cross-hub routes restored to Remote Hub.")
    }
    elseif ($totalDegraded -gt 0) {
        Write-Host ""
        Write-Host "  Result: VPN override still active on $totalDegraded route(s)." -ForegroundColor Yellow
        $null = $report.AppendLine("  Result: PARTIAL - VPN override still active on $totalDegraded route(s).")
    }
    elseif ($totalImproved -eq 0 -and $totalDegraded -eq 0) {
        Write-Host ""
        Write-Host "  Result: No cross-hub next-hop changes detected between snapshots." -ForegroundColor DarkGray
        $null = $report.AppendLine("  Result: No cross-hub next-hop changes detected.")
    }
}

# =============================================================================
# Save report
# =============================================================================
if ($OutputFile) {
    $report.ToString() | Out-File -FilePath $OutputFile -Encoding utf8NoBOM
    Write-Host ""
    Write-OK "Report saved to '$OutputFile'"
}

$stopwatch.Stop()
Write-Host ""
Write-Host "  Done in $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -ForegroundColor DarkGray
