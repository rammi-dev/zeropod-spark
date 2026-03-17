# Create minikube cluster for ZeroPod + Spark Connect POC
# Run from PowerShell (as Administrator)
#
# Key: uses containerd runtime (required for ZeroPod shim)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Write-Host "[INFO] === ZeroPod + Spark Connect POC Setup ===" -ForegroundColor Green
Write-Host "  Profile: $PROFILE"
Write-Host "  Runtime: containerd"
Write-Host "  CPUs: $CPUS"
Write-Host "  Memory: ${MEMORY}MB"
Write-Host "  Disk: $DISK_SIZE"
Write-Host "  K8s: $K8S_VERSION"
Write-Host ""

# Check for custom ISO with CRIU support
$isoArgs = @()
$isoPath = Join-Path $PSScriptRoot "..\minikube-x86_64.iso"
if (Test-Path $isoPath) {
    $isoFull = (Resolve-Path $isoPath).Path -replace '\\','/'
    $isoArgs = @("--iso-url=file:///$isoFull")
    Write-Host "  ISO: $isoFull (custom, CRIU-enabled)" -ForegroundColor Cyan
} else {
    Write-Host "  ISO: default (no custom ISO found)" -ForegroundColor Yellow
    Write-Host "  [WARN] Default ISO may lack CONFIG_CHECKPOINT_RESTORE" -ForegroundColor Yellow
    Write-Host "  See scripts/build-minikube-iso.md for build instructions" -ForegroundColor Yellow
}
Write-Host ""

# Create cluster with containerd runtime
Write-Host "[INFO] Creating minikube cluster with containerd..." -ForegroundColor Yellow
& $MINIKUBE_EXE start `
    -p $PROFILE `
    --driver=hyperv `
    --container-runtime=containerd `
    --hyperv-virtual-switch=$SWITCH_NAME `
    --nodes=1 `
    --cpus=$CPUS `
    --memory=$MEMORY `
    --disk-size=$DISK_SIZE `
    --kubernetes-version=$K8S_VERSION `
    --extra-config=kubelet.housekeeping-interval=10s `
    --extra-config=kubelet.fail-swap-on=false `
    @isoArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Minikube failed to start" -ForegroundColor Red
    exit 1
}

# Wait for node ready
Write-Host "[INFO] Waiting for node to be ready..." -ForegroundColor Yellow
& $KUBECTL_EXE --context=$PROFILE wait --for=condition=Ready nodes --all --timeout=300s

# Verify containerd
Write-Host ""
Write-Host "[INFO] Verifying containerd runtime..." -ForegroundColor Yellow
& $MINIKUBE_EXE -p $PROFILE ssh -- "sudo crictl info | head -5"

# Test IPv6 -- only apply fix if needed
Write-Host ""
$pullOk = Test-IPv6Pull -ProfileName $PROFILE
if (-not $pullOk) {
    Fix-IPv6Routing -ProfileName $PROFILE
    # Verify fix worked
    Write-Host "[INFO] Verifying fix..." -ForegroundColor Yellow
    & $MINIKUBE_EXE -p $PROFILE ssh -- "sudo crictl pull nginx:alpine" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[SUCCESS] Image pull works after fix" -ForegroundColor Green
        & $MINIKUBE_EXE -p $PROFILE ssh -- "sudo crictl rmi nginx:alpine" 2>$null
    } else {
        Write-Host "[ERROR] Image pull still failing after IPv6 fix" -ForegroundColor Red
        exit 1
    }
}

# Check CRIU kernel support
Write-Host ""
Write-Host "[INFO] Checking CRIU kernel support..." -ForegroundColor Yellow
$criuCheck = & $MINIKUBE_EXE -p $PROFILE ssh -- "zgrep CONFIG_CHECKPOINT_RESTORE /proc/config.gz"
Write-Host "  $criuCheck"
if ($criuCheck -notmatch '=y') {
    Write-Host "[ERROR] Kernel lacks CONFIG_CHECKPOINT_RESTORE=y -- cannot use CRIU/ZeroPod" -ForegroundColor Red
    Write-Host "[INFO] Options:" -ForegroundColor Yellow
    Write-Host "  - Custom minikube ISO with CRIU-enabled kernel"
    Write-Host "  - Use --iso-url with a kernel that has CRIU support"
    Write-Host "  - Use a different VM/driver with a full distro kernel"
    exit 1
}

Write-Host ""
Write-Host "[SUCCESS] Cluster ready! Next steps:" -ForegroundColor Green
Write-Host "  1. bash components/zeropod/install.sh    # Install ZeroPod"
Write-Host "  2. bash components/spark-operator/install.sh  # Install Spark operator"
Write-Host "  3. kubectl apply -f components/spark-connect/spark-connect.yaml"
Write-Host ""
& $KUBECTL_EXE --context=$PROFILE get nodes -o wide
