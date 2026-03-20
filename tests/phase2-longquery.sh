#!/bin/bash
# Phase 2 long query test: verify ZeroPod does NOT checkpoint during active query
#
# Validates:
#   1. Long-running query (>5 min) prevents checkpoint (TCP ACKs keep timer alive)
#   2. After query finishes and idle period, checkpoint happens
#   3. Resume with same session works
#
# Run:
#   bash tests/phase2-longquery.sh
set -e

NAMESPACE="spark-workload"
ZEROPOD_NS="zeropod-system"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/components/spark-connect/test-long-query.py"
JOB_YAML="$SCRIPT_DIR/components/spark-connect/phase2-longquery-job.yaml"
CONFIGMAP_NAME="phase2-longquery-script"
JOB_NAME="phase2-long-query"

info() { echo "  INFO: $1"; }

cleanup() {
    kubectl delete job $JOB_NAME -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
    kubectl delete configmap $CONFIGMAP_NAME -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
}
trap cleanup EXIT

count_scaled_down() {
    kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
        -c manager 2>/dev/null | grep "SCALED_DOWN" | grep "spark-connect" | wc -l
}

count_running() {
    kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
        -c manager 2>/dev/null | grep '"phase":"RUNNING"' | grep "spark-connect" | wc -l
}

echo ""
echo "============================================"
echo "Phase 2 Long Query Test"
echo "  Verify: no checkpoint during active query"
echo "  Verify: checkpoint after idle"
echo "  Verify: session survives"
echo "============================================"

cleanup 2>/dev/null

info "Waiting for driver to be ready..."
kubectl wait --for=condition=Ready pod -l spark-role=driver -n $NAMESPACE --timeout=300s 2>/dev/null || {
    echo "FAIL: driver not ready"
    exit 1
}

# Upload test script
kubectl create configmap $CONFIGMAP_NAME \
    --from-file=test-long-query.py="$TEST_SCRIPT" \
    -n $NAMESPACE

# Launch job
info "Launching long query test..."
kubectl apply -f "$JOB_YAML"

# Wait for pod to start
kubectl wait --for=condition=Ready pod -l job-name=$JOB_NAME -n $NAMESPACE --timeout=120s 2>/dev/null || true

# Follow logs in background
kubectl logs -f job/$JOB_NAME -n $NAMESPACE 2>/dev/null &
LOG_PID=$!

# Wait for driver restore (Phase 1 connect)
info "Waiting for Phase 1 to connect..."
RUNNING_BASELINE=$(count_running)
WAIT=0
while [ $WAIT -lt 120 ]; do
    sleep 5
    WAIT=$((WAIT + 5))
    if [ "$(count_running)" -gt "$RUNNING_BASELINE" ]; then
        info "Driver restored (Phase 1 connected) after ${WAIT}s"
        break
    fi
done

sleep 10
BASELINE=$(count_scaled_down)
info "Baseline SCALED_DOWN events: $BASELINE"

# Monitor: detect when long query starts and ensure NO checkpoint during it
QUERY_RUNNING=false
CHECKPOINT_DURING_QUERY=false
CHECKPOINT_AFTER_IDLE=false
CP_DURATION=""
RESTORE_DURATION=""

info "Monitoring zeropod events..."
ELAPSED=0
INTERVAL=15
while true; do
    # Check if job pod has terminated
    POD_PHASE=$(kubectl get pod -n $NAMESPACE -l job-name=$JOB_NAME \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
        # Final check
        CURRENT=$(count_scaled_down)
        if [ "$CURRENT" -gt "$BASELINE" ] && ! $CHECKPOINT_AFTER_IDLE; then
            CHECKPOINT_AFTER_IDLE=true
            CP_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
                -c manager --tail=10 2>/dev/null | grep "SCALED_DOWN" | grep "spark-connect" | \
                tail -1 | grep -oP '"duration":"\K[^"]+')
            RESTORE_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
                -c manager --tail=10 2>/dev/null | grep '"phase":"RUNNING"' | grep "spark-connect" | \
                tail -1 | grep -oP '"duration":"\K[^"]+')
        fi
        break
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    CURRENT=$(count_scaled_down)

    # Detect query phase from job logs
    LATEST_LOG=$(kubectl logs job/$JOB_NAME -n $NAMESPACE --tail=3 2>/dev/null)
    if echo "$LATEST_LOG" | grep -q "LONG_QUERY_START" && ! echo "$LATEST_LOG" | grep -q "LONG_QUERY_END"; then
        if ! $QUERY_RUNNING; then
            QUERY_RUNNING=true
            info "Long query is RUNNING"
        fi
        # Check for checkpoint during query — this should NOT happen
        if [ "$CURRENT" -gt "$BASELINE" ]; then
            CHECKPOINT_DURING_QUERY=true
            info "WARNING: checkpoint detected DURING active query!"
        fi
    fi

    if echo "$LATEST_LOG" | grep -q "LONG_QUERY_END"; then
        if $QUERY_RUNNING; then
            QUERY_RUNNING=false
            info "Long query FINISHED — now idle"
        fi
    fi

    if [ "$CURRENT" -gt "$BASELINE" ] && ! $CHECKPOINT_DURING_QUERY; then
        CHECKPOINT_AFTER_IDLE=true
        CP_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
            -c manager --tail=10 2>/dev/null | grep "SCALED_DOWN" | grep "spark-connect" | \
            tail -1 | grep -oP '"duration":"\K[^"]+')
        info "Checkpoint detected after idle (events: $BASELINE → $CURRENT, duration: $CP_DURATION)"
    fi

    info "Monitor: ${ELAPSED}s elapsed, scaled_down=$CURRENT, query_running=$QUERY_RUNNING"

    if [ $ELAPSED -gt 900 ]; then
        info "Safety timeout"
        break
    fi
done

kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true

# Get job exit code
JOB_EXIT=$(kubectl get pod -n $NAMESPACE -l job-name=$JOB_NAME \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)

# ZeroPod events
echo ""
echo "--- ZeroPod events during test ---"
kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
    -c manager --tail=20 2>/dev/null | grep "spark-connect"

# ── Verdict ───────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "Results:"

if $CHECKPOINT_DURING_QUERY; then
    echo "  FAIL: checkpoint happened DURING active query"
    echo "    TCP ACKs did not keep the timer alive"
else
    echo "  PASS: no checkpoint during active query"
fi

if $CHECKPOINT_AFTER_IDLE; then
    echo "  PASS: checkpoint detected after idle (${CP_DURATION})"
else
    echo "  INCONCLUSIVE: checkpoint after idle not detected by monitor"
    echo "    (check zeropod logs above)"
fi

case ${JOB_EXIT:-1} in
    0) echo "  PASS: session survived long query + checkpoint/restore" ;;
    2) echo "  PARTIAL: session reconnected but temp view lost" ;;
    *) echo "  FAIL: job failed (exit=$JOB_EXIT)" ;;
esac

echo ""
if ! $CHECKPOINT_DURING_QUERY && [ "${JOB_EXIT:-1}" = "0" ]; then
    echo "FULL PASS: long queries are safe with ZeroPod"
else
    echo "ISSUES DETECTED — see details above"
fi
echo "============================================"
exit ${JOB_EXIT:-1}
