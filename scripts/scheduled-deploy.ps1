# Scheduled deployment script for vwan-bgp-interhub-lab
# Triggered by Windows Task Scheduler
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

# Deploy
Set-Location C:\_Demo\azure-vwan-bgp-interhub-lab
.\deploy-bicep.ps1 -ResourceGroupName $rg -AdminPassword 'Azur3Lab2024!' -VpnPsk 'VpnLab2024Psk!'

Write-Host "Deployment finished at $(Get-Date)"
Stop-Transcript
