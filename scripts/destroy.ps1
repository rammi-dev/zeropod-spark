# Destroy the ZeroPod POC minikube cluster
# Run from PowerShell (as Administrator)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Write-Host "[INFO] Deleting minikube cluster ($PROFILE)..." -ForegroundColor Yellow
& $MINIKUBE_EXE delete -p $PROFILE

Write-Host "[SUCCESS] Cluster deleted" -ForegroundColor Green
