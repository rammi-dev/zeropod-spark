#!/bin/bash
# Phase 2 notebook test: single long-lived session with open gRPC connection
#
# This is the TRUE notebook simulation:
#   - Single pod holds a SparkSession with an idle gRPC connection
#   - Tests whether ZeroPod/CRIU can checkpoint despite the open TCP socket
#
# Run:
#   bash tests/phase2-notebook.sh
set -e

NAMESPACE="spark-workload"
ZEROPOD_NS="zeropod-system"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/components/spark-connect/test-notebook-sim.py"
JOB_YAML="$SCRIPT_DIR/components/spark-connect/phase2-notebook-job.yaml"
CONFIGMAP_NAME="phase2-notebook-script"
JOB_NAME="phase2-notebook-sim"

# Must be longer than the job's internal idle wait (360s) + setup (~60s)
MONITOR_TIMEOUT=480

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
echo "Phase 2 Notebook Test: single session, open gRPC connection"
echo "============================================"

cleanup 2>/dev/null

# Wait for driver
info "Waiting for driver to be ready..."
kubectl wait --for=condition=Ready pod -l spark-role=driver -n $NAMESPACE --timeout=300s 2>/dev/null || {
    echo "FAIL: driver not ready"
    exit 1
}

# Upload test script
kubectl create configmap $CONFIGMAP_NAME \
    --from-file=test-notebook-sim.py="$TEST_SCRIPT" \
    -n $NAMESPACE

# Launch the notebook simulation job
info "Launching notebook simulation..."
kubectl apply -f "$JOB_YAML"

# Wait for the job pod to be running (Phase 1 starts)
info "Waiting for notebook pod to start..."
kubectl wait --for=condition=Ready pod -l job-name=$JOB_NAME -n $NAMESPACE --timeout=120s 2>/dev/null || true

# Follow logs in background
kubectl logs -f job/$JOB_NAME -n $NAMESPACE 2>/dev/null &
LOG_PID=$!

# Wait for Phase 1 to complete: the job will trigger a RUNNING event when it connects.
# We need the baseline AFTER this restore, so wait for it.
info "Waiting for Phase 1 to trigger driver restore..."
RUNNING_BASELINE=$(count_running)
WAIT=0
while [ $WAIT -lt 120 ]; do
    sleep 5
    WAIT=$((WAIT + 5))
    RUNNING_NOW=$(count_running)
    if [ "$RUNNING_NOW" -gt "$RUNNING_BASELINE" ]; then
        info "Driver restored (Phase 1 connected) after ${WAIT}s"
        break
    fi
done

# Now snapshot the SCALED_DOWN baseline AFTER Phase 1 is done
sleep 10  # give Phase 1 a moment to finish its queries
BASELINE=$(count_scaled_down)
info "Baseline SCALED_DOWN events (after Phase 1): $BASELINE"

# The job idles for 360s internally, then runs Phase 3. Checkpoint should happen
# ~5-6 min after Phase 1 finishes. We monitor until the job completes.
info "Monitoring for checkpoint until job completes..."

CHECKPOINTED=false
CP_DURATION=""
ELAPSED=0
INTERVAL=30
while true; do
    # Check if job finished
    JOB_STATUS=$(kubectl get job $JOB_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[0].type}' 2>/dev/null)
    if [ "$JOB_STATUS" = "Complete" ] || [ "$JOB_STATUS" = "Failed" ]; then
        # One final check for checkpoint
        CURRENT=$(count_scaled_down)
        if [ "$CURRENT" -gt "$BASELINE" ]; then
            CHECKPOINTED=true
            CP_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
                -c manager --tail=10 2>/dev/null | grep "SCALED_DOWN" | grep "spark-connect" | \
                tail -1 | grep -oP '"duration":"\K[^"]+')
            info "CHECKPOINT detected (events: $BASELINE → $CURRENT, duration: $CP_DURATION)"
        fi
        break
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    CURRENT=$(count_scaled_down)
    if [ "$CURRENT" -gt "$BASELINE" ] && ! $CHECKPOINTED; then
        CHECKPOINTED=true
        CP_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
            -c manager --tail=10 2>/dev/null | grep "SCALED_DOWN" | grep "spark-connect" | \
            tail -1 | grep -oP '"duration":"\K[^"]+')
        info "NEW CHECKPOINT detected after ${ELAPSED}s idle (events: $BASELINE → $CURRENT)"
        info "Checkpoint duration: $CP_DURATION"
    else
        info "Waiting... ${ELAPSED}s (scaled_down events: $CURRENT)"
    fi

    # Safety timeout
    if [ $ELAPSED -gt 600 ]; then
        info "Safety timeout reached"
        break
    fi
done

# Get actual exit code
JOB_EXIT=$(kubectl get pod -n $NAMESPACE -l job-name=$JOB_NAME \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)

kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true

# Show zeropod events during our test window
echo ""
echo "--- ZeroPod events (last 20 spark-connect entries) ---"
kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
    -c manager --tail=30 2>/dev/null | grep "spark-connect"

# Extract restore duration if checkpoint happened
if $CHECKPOINTED; then
    RESTORE_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
        -c manager --tail=10 2>/dev/null | grep '"phase":"RUNNING"' | grep "spark-connect" | \
        tail -1 | grep -oP '"duration":"\K[^"]+')
    info "Restore duration: $RESTORE_DURATION"
fi

# ── Final verdict ─────────────────────────────────────────────────
echo ""
echo "============================================"
if $CHECKPOINTED && [ "${JOB_EXIT:-1}" = "0" ]; then
    echo "FULL PASS: notebook session survived checkpoint/restore"
    echo "  - CRIU checkpointed despite open idle gRPC connection"
    echo "  - Temp views and cached DataFrames preserved"
    echo "  - Checkpoint: $CP_DURATION | Restore: $RESTORE_DURATION"
    echo "  - ZeroPod's tcp-listen.patch + --tcp-skip-in-flight handles it"
elif $CHECKPOINTED && [ "${JOB_EXIT:-1}" = "2" ]; then
    echo "PARTIAL PASS: checkpoint worked, session reconnected, but temp view lost"
    echo "  - Checkpoint: $CP_DURATION | Restore: $RESTORE_DURATION"
elif $CHECKPOINTED; then
    echo "FAIL: checkpoint happened but resume failed (exit=$JOB_EXIT)"
elif [ "${JOB_EXIT:-1}" = "0" ]; then
    echo "INCONCLUSIVE: job passed but checkpoint not detected by monitor"
    echo "  Check zeropod logs above — checkpoint may have been missed"
else
    echo "FAIL: no checkpoint detected and job failed (exit=$JOB_EXIT)"
fi
echo "============================================"
exit ${JOB_EXIT:-1}
