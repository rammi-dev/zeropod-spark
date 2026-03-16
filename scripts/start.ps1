# Start existing minikube cluster and re-apply fixes if needed
# Run from PowerShell (as Administrator)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Write-Host "[INFO] Starting minikube cluster ($PROFILE)..." -ForegroundColor Yellow
& $MINIKUBE_EXE start -p $PROFILE

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Minikube failed to start" -ForegroundColor Red
    exit 1
}

& $KUBECTL_EXE --context=$PROFILE wait --for=condition=Ready nodes --all --timeout=300s

# Test if IPv6 fix is needed (root fs is tmpfs, fix lost on reboot)
Write-Host ""
$pullOk = Test-IPv6Pull -ProfileName $PROFILE
if (-not $pullOk) {
    Fix-IPv6Routing -ProfileName $PROFILE
}

Write-Host ""
Write-Host "[SUCCESS] Cluster is ready!" -ForegroundColor Green
& $KUBECTL_EXE --context=$PROFILE get nodes -o wide
