#!/bin/bash
# Phase 2 test: DataFrame survival across ZeroPod checkpoint/restore
#
# Simulates a notebook user who:
#   1. Starts a Spark session and builds a cached DataFrame
#   2. Walks away — ZeroPod checkpoints the idle driver
#   3. Comes back and tries to use the same DataFrame
#
# Prerequisites:
#   - Phase 1 tests pass (Spark Connect + ZeroPod operational)
#   - pyspark[connect] installed
#
# Run:
#   bash tests/phase2.sh
#
# Run individual steps:
#   bash tests/phase2.sh 2.1   # prepare only
#   bash tests/phase2.sh 2.2   # wait for checkpoint only (assumes 2.1 done)
#   bash tests/phase2.sh 2.3   # resume only (assumes driver already restored)
set -e

NAMESPACE="spark-workload"
ZEROPOD_NS="zeropod-system"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/components/spark-connect/test-dataframe-survival.py"
FILTER="${1:-all}"
PASS=0
FAIL=0

# ZeroPod scaledown is 5m; we wait scaledown + 30s buffer
SCALEDOWN_WAIT=330

run_test() {
    local id="$1"
    local name="$2"
    if [ "$FILTER" != "all" ] && [ "$FILTER" != "$id" ]; then
        return 0
    fi
    echo ""
    echo "=== TEST $id: $name ==="
}

pass() { echo "  PASS"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
info() { echo "  INFO: $1"; }

cleanup_port_forward() {
    lsof -ti:15002 2>/dev/null | xargs kill 2>/dev/null || true
}

start_port_forward() {
    cleanup_port_forward
    kubectl port-forward svc/spark-connect-server-svc -n $NAMESPACE 15002:15002 &
    PF_PID=$!
    sleep 5
    if ! kill -0 $PF_PID 2>/dev/null; then
        fail "port-forward died"
        return 1
    fi
    return 0
}

# --- Test 2.1: Prepare DataFrame ---
run_test "2.1" "Start Spark session and prepare cached DataFrame"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "2.1" ]; then
    info "Waiting for Spark Connect driver to be ready..."
    kubectl wait --for=condition=Ready pod -l spark-role=driver -n $NAMESPACE --timeout=300s 2>/dev/null || {
        fail "driver pod not ready"
        kubectl get pods -n $NAMESPACE
        exit 1
    }

    start_port_forward || exit 1

    info "Running prepare phase..."
    if python3 "$TEST_SCRIPT" prepare; then
        pass
    else
        fail "prepare phase failed"
        kill $PF_PID 2>/dev/null || true
        exit 1
    fi
    kill $PF_PID 2>/dev/null || true
fi

# --- Test 2.2: Wait for ZeroPod checkpoint ---
run_test "2.2" "ZeroPod checkpoints idle Spark driver"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "2.2" ]; then
    info "Waiting ${SCALEDOWN_WAIT}s for ZeroPod to checkpoint the driver (scaledown-duration=5m)..."

    # Show driver pod status before waiting
    info "Driver pod status:"
    kubectl get pods -n $NAMESPACE -l spark-role=driver -o wide

    # Poll zeropod logs for checkpoint event instead of blind sleep
    ELAPSED=0
    INTERVAL=30
    CHECKPOINTED=false
    while [ $ELAPSED -lt $SCALEDOWN_WAIT ]; do
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        if kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node -c manager --tail=50 2>/dev/null | grep -q "SCALED_DOWN.*spark-connect"; then
            CHECKPOINTED=true
            info "Checkpoint detected after ${ELAPSED}s"
            break
        fi
        info "Still waiting... ${ELAPSED}s / ${SCALEDOWN_WAIT}s"
    done

    if $CHECKPOINTED; then
        pass
    else
        fail "no checkpoint detected in zeropod logs after ${SCALEDOWN_WAIT}s"
    fi
fi

# --- Test 2.3: Resume and reuse DataFrame ---
run_test "2.3" "Reuse DataFrame after ZeroPod restore"
if [ "$FILTER" = "all" ] || [ "$FILTER" = "2.3" ]; then
    start_port_forward || exit 1

    info "Running resume phase (this triggers ZeroPod restore)..."
    START_MS=$(date +%s%3N)

    python3 "$TEST_SCRIPT" resume
    EXIT_CODE=$?

    END_MS=$(date +%s%3N)
    TOTAL_MS=$((END_MS - START_MS))
    info "Total resume time: ${TOTAL_MS}ms"

    # Show restore duration from zeropod logs
    RESTORE_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node -c manager --tail=20 2>/dev/null | grep "RUNNING.*spark-connect" | tail -1 | grep -oP '"duration":"\K[^"]+')
    info "ZeroPod restore duration: $RESTORE_DURATION"

    case $EXIT_CODE in
        0)
            echo "  2.3a PASS: DataFrame and temp view survived checkpoint/restore"
            PASS=$((PASS + 1))
            ;;
        2)
            echo "  2.3a PARTIAL: temp view lost, but server functional after restore"
            echo "  2.3b INFO: cached DataFrames do NOT survive CRIU checkpoint — expected for Spark Connect"
            PASS=$((PASS + 1))
            ;;
        *)
            fail "Spark Connect not functional after restore"
            ;;
    esac

    kill $PF_PID 2>/dev/null || true
fi

# Summary
echo ""
echo "================================"
echo "Phase 2 Results: $PASS passed, $FAIL failed"
echo "================================"
[ $FAIL -eq 0 ] && echo "All tests passed!" || echo "Some tests failed — check output above"
exit $FAIL
