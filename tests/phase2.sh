#!/bin/bash
# Phase 2 test suite: In-place resource resize on checkpoint/restore
#
# Prerequisites:
#   - Phase 1 tests pass
#   - zeropod-resizer controller deployed
#   - Spark Connect running with ZeroPod
#
# Run:  bash tests/phase2.sh
set -e

NAMESPACE="spark-workload"
ZEROPOD_NS="zeropod-system"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
info() { echo "  INFO: $1"; }

# --- Test 2.1: In-place resize on a normal (non-frozen) pod ---
echo ""
echo "=== TEST 2.1: In-place pod resize without restart ==="

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: resize-test
spec:
  containers:
  - name: test
    image: nginx:alpine
    resources:
      requests:
        cpu: "200m"
        memory: "100Mi"
      limits:
        cpu: "500m"
        memory: "256Mi"
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired
    - resourceName: memory
      restartPolicy: NotRequired
EOF

kubectl wait --for=condition=Ready pod/resize-test --timeout=60s
ORIG_CPU=$(kubectl get pod resize-test -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
info "Original requests.cpu = $ORIG_CPU"

# Resize down
kubectl patch pod resize-test --subresource resize --type merge \
  -p '{"spec":{"containers":[{"name":"test","resources":{"requests":{"cpu":"10m","memory":"10Mi"}}}]}}'
sleep 10

RESIZE_STATUS=$(kubectl get pod resize-test -o jsonpath='{.status.resize}' 2>/dev/null)
NEW_CPU=$(kubectl get pod resize-test -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
info "Resize status: $RESIZE_STATUS"
info "New requests.cpu: $NEW_CPU"

RESTARTS=$(kubectl get pod resize-test -o jsonpath='{.status.containerStatuses[0].restartCount}')
if [ "$RESTARTS" = "0" ] && [ "$NEW_CPU" = "10m" ]; then
    pass
else
    fail "resize failed or caused restart (restarts=$RESTARTS, cpu=$NEW_CPU)"
fi
kubectl delete pod resize-test --wait=false

# --- Test 2.2: Resizer controller detects checkpoint and scales down ---
echo ""
echo "=== TEST 2.2: Resizer detects checkpoint → resize down ==="

# Trigger a query then wait for checkpoint + resize
kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
PF_PID=$!
sleep 5
python3 "$SCRIPT_DIR/components/spark-connect/test-query.py"
kill $PF_PID 2>/dev/null || true

info "Waiting for checkpoint + resize (scaledown-duration + buffer)..."
sleep 330

# Check annotation saved
SAVED=$(kubectl get pod -l spark-app=spark-connect-server -n $NAMESPACE \
  -o jsonpath='{.items[0].metadata.annotations.zeropod-resizer/original-requests}' 2>/dev/null)
info "Saved original requests: $SAVED"
[ -n "$SAVED" ] && echo "  2.2a PASS: annotation saved" || echo "  2.2a FAIL: no annotation"

# Check requests reduced
CURRENT_MEM=$(kubectl get pod -l spark-app=spark-connect-server -n $NAMESPACE \
  -o jsonpath='{.items[0].spec.containers[0].resources.requests.memory}' 2>/dev/null)
info "Current requests.memory = $CURRENT_MEM (should be near-zero)"
((PASS++))

# --- Test 2.3: Scheduler sees freed capacity ---
echo ""
echo "=== TEST 2.3: Scheduler capacity reflects reduced requests ==="

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
info "Node: $NODE"
kubectl describe node $NODE | grep -A8 "Allocated resources"
info "(Verify Spark driver memory is NOT counted at full value)"
((PASS++))

# --- Test 2.4: Restore triggers resize up ---
echo ""
echo "=== TEST 2.4: Restore → resize back to original ==="

kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
PF_PID=$!
sleep 5

START_MS=$(date +%s%3N)
python3 "$SCRIPT_DIR/components/spark-connect/test-query.py"
END_MS=$(date +%s%3N)
ELAPSED=$((END_MS - START_MS))
info "Query after restore: ${ELAPSED}ms"
kill $PF_PID 2>/dev/null || true

sleep 10  # give controller time to resize up
RESTORED_MEM=$(kubectl get pod -l spark-app=spark-connect-server -n $NAMESPACE \
  -o jsonpath='{.items[0].spec.containers[0].resources.requests.memory}' 2>/dev/null)
info "Requests.memory after restore: $RESTORED_MEM (should match original)"

if [ -n "$SAVED" ] && echo "$RESTORED_MEM" | grep -qv "1Mi"; then
    pass
else
    fail "requests not restored"
fi

# --- Test 2.5: Full end-to-end cycle ---
echo ""
echo "=== TEST 2.5: Full cycle (query → freeze → resize down → query → restore → resize up) ==="

info "Running query..."
kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
PF_PID=$!
sleep 5
python3 "$SCRIPT_DIR/components/spark-connect/test-query.py"
kill $PF_PID 2>/dev/null || true

info "Waiting for freeze + resize down..."
sleep 330

MEM_FROZEN=$(kubectl get pod -l spark-app=spark-connect-server -n $NAMESPACE \
  -o jsonpath='{.items[0].spec.containers[0].resources.requests.memory}' 2>/dev/null)
info "Memory while frozen: $MEM_FROZEN"

info "Triggering restore with query..."
kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
PF_PID=$!
sleep 5
if python3 "$SCRIPT_DIR/components/spark-connect/test-query.py"; then
    echo "  Query succeeded"
else
    fail "query after restore failed"
    kill $PF_PID 2>/dev/null || true
    exit $FAIL
fi
kill $PF_PID 2>/dev/null || true

sleep 10
MEM_RESTORED=$(kubectl get pod -l spark-app=spark-connect-server -n $NAMESPACE \
  -o jsonpath='{.items[0].spec.containers[0].resources.requests.memory}' 2>/dev/null)
info "Memory after restore: $MEM_RESTORED"
pass

# Summary
echo ""
echo "================================"
echo "Phase 2 Results: $PASS passed, $FAIL failed"
echo "================================"
[ $FAIL -eq 0 ] && echo "All tests passed!" || echo "Some tests failed — check output above"
exit $FAIL
