#!/bin/bash
# Install ZeroPod on the minikube cluster
# Requires: kubectl context set to zeropod-poc
set -e

echo "[INFO] Installing ZeroPod..."
kubectl apply -k https://github.com/ctrox/zeropod/config/production

echo "[INFO] Waiting for ZeroPod manager pods..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=zeropod -n zeropod-system --timeout=120s 2>/dev/null || \
kubectl wait --for=condition=Ready pod -l app=zeropod-manager -n zeropod-system --timeout=120s 2>/dev/null || \
echo "[WARN] Could not wait for zeropod pods — check manually: kubectl get pods -n zeropod-system"

echo "[INFO] Checking RuntimeClass..."
kubectl get runtimeclass zeropod

echo ""
echo "[INFO] ZeroPod pods:"
kubectl get pods -n zeropod-system

echo ""
echo "[SUCCESS] ZeroPod installed. Test with:"
echo "  kubectl apply -f components/zeropod/nginx-test.yaml"
