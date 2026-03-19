#!/usr/bin/env bash
# Sync minikube kubeconfig from Windows into WSL so kubectl/kubectx work.
# Run from WSL after minikube is started on Windows.
#
# Usage: bash scripts/wsl-kubeconfig.sh

set -euo pipefail

PROFILE="zeropod-poc"

# Detect Windows user home via /mnt/c
WIN_HOME=$(wslpath "$(cmd.exe /C 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")

if [[ ! -d "$WIN_HOME/.minikube" ]]; then
    echo "[ERROR] Could not find $WIN_HOME/.minikube — is minikube installed on Windows?" >&2
    exit 1
fi

# Find minikube.exe (Windows) — needed to export kubeconfig
MINIKUBE_WIN="minikube.exe"
if ! command -v "$MINIKUBE_WIN" &>/dev/null; then
    echo "[ERROR] minikube.exe not found in PATH. Add Windows minikube to WSL PATH." >&2
    exit 1
fi

echo "[INFO] Exporting kubeconfig from Windows minikube (profile: $PROFILE)..."

# Export kubeconfig from Windows minikube and convert paths to WSL
KUBECONFIG_RAW=$($MINIKUBE_WIN kubectl -p "$PROFILE" -- config view --flatten 2>/dev/null | tr -d '\r')

if [[ -z "$KUBECONFIG_RAW" ]]; then
    echo "[ERROR] Failed to export kubeconfig from minikube" >&2
    exit 1
fi

# Ensure ~/.kube exists
mkdir -p "$HOME/.kube"

# Write the kubeconfig — certificate data is already embedded via --flatten
echo "$KUBECONFIG_RAW" > "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

echo "[INFO] Kubeconfig written to ~/.kube/config"

# Set current context
kubectl config use-context "$PROFILE" 2>/dev/null || true

# Verify connectivity
echo ""
echo "[INFO] Verifying cluster access..."
if kubectl --context="$PROFILE" get nodes -o wide 2>/dev/null; then
    echo ""
    echo "[SUCCESS] kubectx/kubectl ready. Available contexts:"
    kubectx 2>/dev/null || kubectl config get-contexts -o name
else
    echo ""
    echo "[WARN] Cannot reach cluster. Is minikube running on Windows?"
    echo "  Start it with: powershell -File scripts/start.ps1"
fi
