#!/bin/bash
# Install Apache Spark Kubernetes Operator
# Requires: kubectl + helm
set -e

echo "[INFO] Adding Spark operator Helm repo..."
helm repo add spark-operator https://apache.github.io/spark-kubernetes-operator
helm repo update

echo "[INFO] Installing Spark operator..."
helm install spark-operator spark-operator/spark-kubernetes-operator \
  --namespace spark-operator \
  --create-namespace \
  --set "workloadResources.namespaces.data={spark-workload}" \
  --wait

echo ""
echo "[INFO] Spark operator pods:"
kubectl get pods -n spark-operator

echo ""
echo "[SUCCESS] Spark operator installed. Deploy Spark Connect with:"
echo "  kubectl apply -f components/spark-connect/spark-connect.yaml"
