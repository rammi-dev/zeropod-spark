# Shared configuration and functions for zeropod-spark-poc
# Sourced by setup.ps1 and start.ps1

$MINIKUBE_EXE = "minikube"  # assumes minikube is in PATH
$KUBECTL_EXE = "kubectl"
$PROFILE = "zeropod-poc"
$CPUS = 7
$MEMORY = 12288
$DISK_SIZE = "40g"
$K8S_VERSION = "v1.35.0"
$SWITCH_NAME = "minikube-external"

function Test-IPv6Pull {
    <#
    .SYNOPSIS
    Test if containerd can pull images without IPv6 issues.
    Returns $true if pull succeeds, $false if IPv6 fix is needed.
    #>
    param([string]$ProfileName = $PROFILE)

    Write-Host "[INFO] Testing if image pull works without IPv6 fix..." -ForegroundColor Yellow
    & $MINIKUBE_EXE -p $ProfileName ssh -- "sudo crictl pull nginx:alpine" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[SUCCESS] Image pull works -- no IPv6 fix needed" -ForegroundColor Green
        & $MINIKUBE_EXE -p $ProfileName ssh -- "sudo crictl rmi nginx:alpine" 2>$null
        return $true
    } else {
        Write-Host "[INFO] Image pull failed -- applying IPv6 fix" -ForegroundColor Yellow
        return $false
    }
}

function Fix-IPv6Routing {
    <#
    .SYNOPSIS
    Fix IPv6-related image pull failures on Hyper-V minikube nodes.

    Problem: containerd (Go) resolves AAAA records, tries IPv6, fails with
    EADDRNOTAVAIL because the network has no IPv6 routing. Go does NOT fall back to IPv4.

    Fix: Enable IPv6 with a dummy address and default route so packets reach ip6tables,
    then REJECT all IPv6 TCP -- Go gets ECONNREFUSED which triggers proper IPv4 fallback.
    Finally restart containerd so Go re-probes IPv6 availability.

    Must be re-applied after every minikube start (root fs is tmpfs).
    #>
    param([string]$ProfileName = $PROFILE)

    $sshCmd = @(
        "sudo sysctl -q -w net.ipv6.conf.all.disable_ipv6=0",
        "sudo sysctl -q -w net.ipv6.conf.default.disable_ipv6=0",
        "sudo ip -6 addr add fd00::1/128 dev eth0 2>/dev/null; true",
        "sudo ip -6 route add default dev eth0 2>/dev/null; true",
        "sudo ip6tables -F",
        "sudo ip6tables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset",
        "sudo systemctl restart containerd"
    ) -join " && "

    & $MINIKUBE_EXE -p $ProfileName ssh -- $sshCmd 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[SUCCESS] IPv6 reject fix applied" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Failed to apply IPv6 fix" -ForegroundColor Yellow
    }
}
