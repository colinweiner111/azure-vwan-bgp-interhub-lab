# Scheduled deployment script for vwan-bgp-interhub-lab
# Triggered by Windows Task Scheduler
#
# Secrets are read from environment variables — never hardcode them here
# (this file is committed to a public repo and the transcript below is
# written to disk). Set these at machine/user scope for the scheduled task,
# or in your shell for a manual run:
#   VM_ADMIN_PASSWORD  - VM administrator password
#   VPN_PSK            - VPN pre-shared key

# Read and validate secrets BEFORE starting the transcript, so a missing-secret
# failure never opens a log file.
$adminPassword = $env:VM_ADMIN_PASSWORD
$vpnPsk        = $env:VPN_PSK
if ([string]::IsNullOrWhiteSpace($adminPassword) -or [string]::IsNullOrWhiteSpace($vpnPsk)) {
    Write-Host "ERROR: Set the VM_ADMIN_PASSWORD and VPN_PSK environment variables before running." -ForegroundColor Red
    exit 1
}

$logFile = "C:\_Demo\azure-vwan-bgp-interhub-lab\deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Start-Transcript -Path $logFile

Write-Host "Starting scheduled deployment at $(Get-Date)"

# Wait for any previous RG deletion to finish
$rg = "vwan-bgp-interhub-lab-v9"
$exists = az group exists -n $rg 2>&1
if ($exists -eq "true") {
    Write-Host "WARNING: $rg already exists, skipping deployment"
    Stop-Transcript
    exit 1
}

# Deploy — secrets are passed via variables, so no literal secret is written
# to this script or to the transcript above.
Set-Location C:\_Demo\azure-vwan-bgp-interhub-lab
.\deploy-bicep.ps1 -ResourceGroupName $rg -AdminPassword $adminPassword -VpnPsk $vpnPsk

Write-Host "Deployment finished at $(Get-Date)"
Stop-Transcript
