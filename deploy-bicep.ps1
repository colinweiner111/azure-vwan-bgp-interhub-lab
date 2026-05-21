# =============================================================================
# azure-vwan-bgp-interhub-lab - Deployment Script
# =============================================================================
# Lab for testing BGP inter-hub routing behavior in Azure Virtual WAN:
#   - VPN gateway-learned route override of inter-hub backbone paths
#   - Hub Routing Preference: ExpressRoute / VpnGateway / ASPath
#   - AS-path prepending and Azure hub Route Maps
#
# 3 Hubs, 2 FRR VMs, 6 IPsec tunnels, BGP transit between Hub1 <-> Hub2.
#
# REQUIREMENTS: PowerShell 7+ (run with 'pwsh', not 'powershell')
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "vwan-bgp-interhub-lab",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "westus",

    [Parameter(Mandatory=$false)]
    [string]$Hub2Location = "westus3",

    [Parameter(Mandatory=$false)]
    [string]$Hub3Location = "eastus2",
    
    [Parameter(Mandatory=$false)]
    [string]$AdminUsername = "azureuser",
    
    [Parameter(Mandatory=$false)]
    [string]$AdminPassword,
    
    [Parameter(Mandatory=$false)]
    [string]$VpnPsk,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('Standard', 'Premium')]
    [string]$FirewallSku = "Standard",

    [Parameter(Mandatory=$false)]
    [switch]$EnableFirewall = $false,

    [Parameter(Mandatory=$false)]
    [switch]$EnableBastion = $false
)

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: This script requires PowerShell 7+. Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host "Please run this script using 'pwsh' instead of 'powershell'" -ForegroundColor Yellow
    Write-Host "Install PowerShell 7: https://aka.ms/PSWindows" -ForegroundColor Cyan
    exit 1
}

# Check if logged into Azure
Write-Host "Checking Azure login..." -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (!$account) {
    Write-Host "Not logged in. Please login to Azure..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}

Write-Host "Using subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# Prompt for password if not provided
if (-not $AdminPassword) {
    $SecurePassword = Read-Host -Prompt "Enter VM admin password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

# Prompt for VPN PSK if not provided
if (-not $VpnPsk) {
    $SecurePsk = Read-Host -Prompt "Enter VPN Pre-Shared Key" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePsk)
    $VpnPsk = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "vWAN BGP Inter-Hub Routing Lab" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nDeployment Parameters:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Hub1: $Location"
Write-Host "  Hub2: $Hub2Location"
Write-Host "  Hub3: $Hub3Location"
Write-Host "  Admin Username: $AdminUsername"
Write-Host "  Firewall: $(if ($EnableFirewall) { $FirewallSku } else { 'Disabled' })"
Write-Host "  Bastion: $(if ($EnableBastion) { 'Enabled' } else { 'Disabled' })"

Write-Host "`nLab Architecture:" -ForegroundColor Yellow
Write-Host "  - 3 vWAN Hubs: Hub1 ($Location), Hub2 ($Hub2Location), Hub3 ($Hub3Location)"
Write-Host "  - 2 FRR VMs, 6 IPsec tunnels (2 per hub):"
Write-Host "    * frr-router (Primary):  Tunnels to each hub's VPN GW Instance 0"
Write-Host "    * frr-router-backup:     Tunnels to each hub's VPN GW Instance 1"
Write-Host "  - Both VMs advertise 10.0.0.0/16 (same on-prem prefix)"
  Write-Host "  - Transit routing: FRR re-advertises Hub1 <-> Hub2 learned routes"
Write-Host "  - Hub2: Standard peer (on-prem only, no transit routes)"

Write-Host "`nExpected Result:" -ForegroundColor Magenta
Write-Host "  Hub1/Hub3: See each other's spokes via NextHopType=VpnGateway"
Write-Host "  Hub3: Sees all spokes via NextHopType=RemoteHub (normal, no transit)"

Write-Host "`nComponents to deploy:" -ForegroundColor Cyan
Write-Host "  - Virtual WAN with 3 Hubs"
Write-Host "  - On-Prem VNet (10.0.0.0/16) with 2 FRR/strongSwan VMs"
Write-Host "  - 3 vWAN VPN Gateways (2 instances each)"
Write-Host "  - 6 VPN Sites + Connections (2 per hub)"
Write-Host "  - 6 Spoke VNets (2 per hub)"
Write-Host "  - 7 Workload VMs (on-prem + 2 per hub)"
if ($EnableBastion) {
    Write-Host "  - Azure Bastion for VM access"
}
if ($EnableFirewall) {
    Write-Host "  - Azure Firewall ($FirewallSku SKU) per hub" -ForegroundColor Yellow
}

$extraTime = 0
if ($EnableFirewall) { $extraTime += 15 }
if ($EnableBastion) { $extraTime += 5 }
$estimatedMin = 30 + $extraTime
$estimatedMax = 45 + $extraTime
Write-Host "`nEstimated deployment time: $estimatedMin-$estimatedMax minutes" -ForegroundColor Yellow
Write-Host "  (3 VPN Gateways deploy in parallel: ~30 min)`n"

$deploymentName = "vwan-bgp-interhub-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    Write-Host "Starting deployment..." -ForegroundColor Cyan
    
    az deployment sub create `
        --name $deploymentName `
        --location $Location `
        --template-file "$PSScriptRoot\main.bicep" `
        --parameters resourceGroupName=$ResourceGroupName `
                     location=$Location `
                     hub2Location=$Hub2Location `
                     hub3Location=$Hub3Location `
                     adminUsername=$AdminUsername `
                     adminPassword=$AdminPassword `
                     vpnPsk=$VpnPsk `
                     firewallSku=$FirewallSku `
                     enableFirewall=$($EnableFirewall.ToString().ToLower()) `
                     enableBastion=$($EnableBastion.ToString().ToLower())
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n✓ Deployment completed successfully!" -ForegroundColor Green
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Lab Testing Instructions" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        Write-Host "`nFRR Router VMs (on-prem VNet 10.0.0.0/16):" -ForegroundColor Yellow
        Write-Host "  frr-router (Primary):   3 tunnels to Hub1/Hub2/Hub3 Instance 0"
        Write-Host "  frr-router-backup:      3 tunnels to Hub1/Hub2/Hub3 Instance 1"
        Write-Host "  Both advertise 10.0.0.0/16; transit between Hub1 <-> Hub3"
        
        Write-Host "`nSpoke VMs:" -ForegroundColor Yellow
        Write-Host "  Hub1: spoke1-vm (10.100.1.10), spoke2-vm (10.200.1.10)"
        Write-Host "  Hub2: spoke3-vm (10.110.1.10), spoke4-vm (10.210.1.10)"
        Write-Host "  Hub3: spoke5-vm (10.120.1.10), spoke6-vm (10.220.1.10)"
        
        Write-Host "`nUseful FRR Commands:" -ForegroundColor Yellow
        Write-Host "  sudo vtysh -c 'show ip bgp summary'          # BGP peer status"
        Write-Host "  sudo vtysh -c 'show ip bgp'                  # Full BGP table"
        Write-Host "  sudo vtysh -c 'show ip bgp neighbors X advertised-routes'"
        Write-Host "  sudo ipsec status                            # IPsec tunnel status"
        
        Write-Host "`nVerification Steps:" -ForegroundColor Yellow
        Write-Host "1. SSH to each FRR VM and verify all 3 IPsec tunnels up"
        Write-Host "2. Verify 3 BGP sessions established per VM"
        Write-Host "3. Check Hub1 effective routes: Hub1 spoke routes + Hub3 spoke routes via VPN GW"
        Write-Host "4. Check Hub2 effective routes: All other hub spokes via Remote Hub (normal)"
        Write-Host "5. Check Hub3 effective routes: Hub3 spoke routes + Hub1 spoke routes via VPN GW"
        Write-Host ""
        Write-Host "Key Observation:" -ForegroundColor Magenta
        Write-Host "  Hub1 and Hub3 should show each other's spoke prefixes with"
        Write-Host "  NextHopType=VPN_S2S_Gateway instead of the expected RemoteHub."
        Write-Host "  Hub2 should show all remote spokes via RemoteHub (correct behavior)."
        
        Write-Host "`nCleanup:" -ForegroundColor Yellow
        Write-Host "  az group delete -n $ResourceGroupName --yes --no-wait"
    }
    else {
        Write-Host "`n✗ Deployment failed" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "`n✗ Deployment error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    # Clear sensitive data from memory
    $AdminPassword = $null
    $VpnPsk = $null
    [System.GC]::Collect()
}
