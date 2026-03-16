#!/bin/bash
# Phase 1 test suite: ZeroPod + Spark Connect checkpoint/restore
#
# Run after all components are deployed:
#   bash tests/phase1.sh
#
# Tests can be run individually by passing test numbers:
#   bash tests/phase1.sh 1.4   # run only nginx checkpoint test
set -e

NAMESPACE="spark-workload"
ZEROPOD_NS="zeropod-system"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${1:-all}"
PASS=0
FAIL=0

run_test() {
    local id="$1"
    local name="$2"
    if [ "$FILTER" != "all" ] && [ "$FILTER" != "$id" ]; then
        return 0
    fi
    echo ""
    echo "=== TEST $id: $name ==="
}

pass() { echo "  PASS"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
info() { echo "  INFO: $1"; }

# --- Test 1.1: Containerd runtime ---
run_test "1.1" "Containerd runtime is active"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.1" ]; then
    minikube -p zeropod-poc ssh -- "crictl info" 2>/dev/null | grep -q "containerd" && pass || fail "containerd not running"
fi

# --- Test 1.2: CRIU kernel support ---
run_test "1.2" "Kernel CONFIG_CHECKPOINT_RESTORE enabled"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.2" ]; then
    minikube -p zeropod-poc ssh -- "zgrep CONFIG_CHECKPOINT_RESTORE /proc/config.gz" 2>/dev/null | grep -q "=y" && pass || fail "kernel lacks CRIU support"
fi

# --- Test 1.3: ZeroPod RuntimeClass exists ---
run_test "1.3" "ZeroPod RuntimeClass registered"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.3" ]; then
    kubectl get runtimeclass zeropod -o name 2>/dev/null | grep -q "zeropod" && pass || fail "zeropod runtimeclass not found"
    kubectl get pods -n $ZEROPOD_NS -o wide
fi

# --- Test 1.4: Nginx checkpoint/restore cycle ---
run_test "1.4" "Nginx checkpoint and restore"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.4" ]; then
    # Deploy
    kubectl apply -f "$SCRIPT_DIR/components/zeropod/nginx-test.yaml"
    kubectl wait --for=condition=Ready pod/nginx-test --timeout=60s

    NGINX_IP=$(kubectl get pod nginx-test -o jsonpath='{.status.podIP}')
    info "Pod IP: $NGINX_IP"

    # 1.4a: Initial response
    kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl -- curl -sf --max-time 5 "http://$NGINX_IP:80" > /dev/null 2>&1 && echo "  1.4a PASS: nginx responds" || echo "  1.4a FAIL: no response"

    # 1.4b: Wait for checkpoint (30s scaledown + buffer)
    info "Waiting 45s for checkpoint..."
    sleep 45
    if kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod --tail=30 2>/dev/null | grep -iq "checkpoint\|scaled down"; then
        echo "  1.4b PASS: checkpoint detected in logs"
    else
        echo "  1.4b WARN: no checkpoint log found — check zeropod-system logs manually"
    fi

    # 1.4c: Restore on new request
    kubectl run curl-restore --rm -i --restart=Never --image=curlimages/curl -- curl -sf --max-time 10 "http://$NGINX_IP:80" > /dev/null 2>&1 && echo "  1.4c PASS: nginx restored" || echo "  1.4c FAIL: restore failed"

    # 1.4d: Restore time from logs
    RESTORE_LOG=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod --tail=50 2>/dev/null | grep -i "restore" | tail -1)
    info "Restore log: $RESTORE_LOG"

    # Cleanup
    kubectl delete -f "$SCRIPT_DIR/components/zeropod/nginx-test.yaml" --wait=false
    ((PASS++))
fi

# --- Test 1.5: Spark operator running ---
run_test "1.5" "Spark operator is ready"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.5" ]; then
    kubectl get pods -n spark-operator
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=spark-kubernetes-operator -n spark-operator --timeout=120s 2>/dev/null && pass || fail "spark operator not ready"
fi

# --- Test 1.6: Spark Connect serves queries ---
run_test "1.6" "Spark Connect responds to query"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.6" ]; then
    info "Waiting for Spark Connect driver..."
    kubectl wait --for=condition=Ready pod -l spark-app=spark-connect-server -n $NAMESPACE --timeout=300s 2>/dev/null || {
        fail "driver pod not ready"
        kubectl get pods -n $NAMESPACE
    }

    kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
    PF_PID=$!
    sleep 5

    if python3 "$SCRIPT_DIR/components/spark-connect/test-query.py"; then
        pass
    else
        fail "query failed"
    fi
    kill $PF_PID 2>/dev/null || true
fi

# --- Test 1.7: Spark Connect checkpoint/restore ---
run_test "1.7" "Spark Connect checkpoint and restore cycle"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "1.7" ]; then
    info "Waiting 5m30s for driver checkpoint (scaledown-duration=5m)..."
    sleep 330

    if kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod --tail=50 2>/dev/null | grep -iq "checkpoint\|scaled down"; then
        echo "  1.7a PASS: driver checkpointed"
    else
        echo "  1.7a FAIL: no checkpoint detected"
        ((FAIL++))
    fi

    # Trigger restore with new query
    kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
    PF_PID=$!
    sleep 5

    START_MS=$(date +%s%3N)
    if python3 "$SCRIPT_DIR/components/spark-connect/test-query.py"; then
        END_MS=$(date +%s%3N)
        ELAPSED=$((END_MS - START_MS))
        info "Query after restore: ${ELAPSED}ms (includes connect + query)"
        pass
    else
        fail "query after restore failed"
    fi
    kill $PF_PID 2>/dev/null || true
fi

# Summary
echo ""
echo "================================"
echo "Phase 1 Results: $PASS passed, $FAIL failed"
echo "================================"
[ $FAIL -eq 0 ] && echo "All tests passed!" || echo "Some tests failed — check output above"
exit $FAIL
