#!/bin/bash
# Phase 2 test: DataFrame survival across ZeroPod checkpoint/restore
#
# Runs pyspark client as K8s Jobs INSIDE the cluster (no port-forward).
# This simulates a real notebook user connecting via service DNS.
#
#   1. Job "prepare" — connects, builds cached DataFrame + temp view
#   2. Job completes → no TCP traffic → ZeroPod checkpoints driver
#   3. Job "resume"  — reconnects with SAME session_id → queries temp view
#
# Prerequisites:
#   - Phase 1 tests pass (Spark Connect + ZeroPod operational)
#
# Run:
#   bash tests/phase2.sh
set -e

NAMESPACE="spark-workload"
ZEROPOD_NS="zeropod-system"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/components/spark-connect/test-dataframe-survival.py"
JOB_TEMPLATE="$SCRIPT_DIR/components/spark-connect/phase2-job.yaml"
CONFIGMAP_NAME="phase2-test-script"
SCALEDOWN_WAIT=360

PASS=0
FAIL=0

pass() { echo "  PASS"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
info() { echo "  INFO: $1"; }

cleanup() {
    kubectl delete job phase2-prepare phase2-resume -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
    kubectl delete configmap $CONFIGMAP_NAME -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
}
trap cleanup EXIT

count_scaled_down() {
    kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
        -c manager 2>/dev/null | grep "SCALED_DOWN" | grep "spark-connect" | wc -l
}

run_job() {
    local job_name="$1"
    local cmd_args="$2"

    # Render job from template: replace name and args
    sed -e "s|name: PLACEHOLDER|name: $job_name|" \
        -e "s|args: \[\"PLACEHOLDER\"\]|args: [\"pip install -q 'pyspark[connect]' \&\& python3 /opt/test/test-dataframe-survival.py $cmd_args\"]|" \
        "$JOB_TEMPLATE" | kubectl apply -f -

    info "Waiting for job/$job_name to complete..."
    if ! kubectl wait --for=condition=complete job/$job_name -n $NAMESPACE --timeout=180s 2>/dev/null; then
        if kubectl wait --for=condition=failed job/$job_name -n $NAMESPACE --timeout=5s 2>/dev/null; then
            echo ""
            kubectl logs job/$job_name -n $NAMESPACE 2>/dev/null
            return 1
        fi
        echo ""
        kubectl logs job/$job_name -n $NAMESPACE 2>/dev/null
        return 1
    fi

    echo ""
    kubectl logs job/$job_name -n $NAMESPACE 2>/dev/null
    return 0
}

echo ""
echo "============================================"
echo "Phase 2: DataFrame survival across checkpoint/restore"
echo "  (in-cluster Jobs, same session_id, no port-forward)"
echo "============================================"

# Cleanup previous runs
cleanup 2>/dev/null

# Upload test script as ConfigMap
info "Creating ConfigMap with test script..."
kubectl create configmap $CONFIGMAP_NAME \
    --from-file=test-dataframe-survival.py="$TEST_SCRIPT" \
    -n $NAMESPACE

# ── 2.1: Prepare ─────────────────────────────────────────────────
echo ""
echo "=== TEST 2.1: Prepare DataFrame (in-cluster Job) ==="

info "Waiting for driver to be ready..."
kubectl wait --for=condition=Ready pod -l spark-role=driver -n $NAMESPACE --timeout=300s 2>/dev/null || {
    fail "driver pod not ready"
    kubectl get pods -n $NAMESPACE
    exit 1
}

if ! run_job "phase2-prepare" "prepare"; then
    fail "prepare job failed"
    exit 1
fi

# Extract session_id from job logs
SESSION_ID=$(kubectl logs job/phase2-prepare -n $NAMESPACE 2>/dev/null | grep "^SESSION_ID=" | cut -d= -f2)
if [ -z "$SESSION_ID" ]; then
    fail "could not extract session_id from prepare job logs"
    exit 1
fi
info "Session ID to preserve: $SESSION_ID"
pass

# ── 2.2: Wait for checkpoint ─────────────────────────────────────
echo ""
echo "=== TEST 2.2: Wait for ZeroPod checkpoint ==="
info "Prepare job completed — no client TCP traffic to driver"

BASELINE=$(count_scaled_down)
info "Baseline SCALED_DOWN events: $BASELINE"
info "Waiting up to ${SCALEDOWN_WAIT}s for ZeroPod to checkpoint (scaledown-duration=5m)..."
kubectl get pods -n $NAMESPACE -l spark-role=driver -o wide

ELAPSED=0
INTERVAL=30
CHECKPOINTED=false
while [ $ELAPSED -lt $SCALEDOWN_WAIT ]; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    CURRENT=$(count_scaled_down)
    if [ "$CURRENT" -gt "$BASELINE" ]; then
        CHECKPOINTED=true
        info "New checkpoint detected after ${ELAPSED}s (events: $BASELINE → $CURRENT)"
        break
    fi
    info "Still waiting... ${ELAPSED}s / ${SCALEDOWN_WAIT}s (events: $CURRENT)"
done

if $CHECKPOINTED; then
    pass
else
    fail "no new checkpoint detected after ${SCALEDOWN_WAIT}s"
    echo ""
    echo "============================================"
    echo "Phase 2 Results: $PASS passed, $FAIL failed"
    echo "============================================"
    exit 1
fi

# ── 2.3: Resume with same session_id ─────────────────────────────
echo ""
echo "=== TEST 2.3: Resume with same session_id after restore ==="

info "Launching resume job with session_id=$SESSION_ID"
info "This triggers ZeroPod restore..."

START_MS=$(date +%s%3N)

run_job "phase2-resume" "resume $SESSION_ID"
RUN_EXIT=$?

END_MS=$(date +%s%3N)
TOTAL_MS=$((END_MS - START_MS))
info "Total resume time: ${TOTAL_MS}ms"

# Show restore duration from zeropod logs
RESTORE_DURATION=$(kubectl logs -n $ZEROPOD_NS -l app.kubernetes.io/name=zeropod-node \
    -c manager --tail=20 2>/dev/null | grep "RUNNING" | grep "spark-connect" | \
    tail -1 | grep -oP '"duration":"\K[^"]+')
info "ZeroPod restore duration: $RESTORE_DURATION"

# Get actual exit code from the resume pod
RESUME_EXIT=$(kubectl get pod -n $NAMESPACE -l job-name=phase2-resume \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
FINAL_EXIT=${RESUME_EXIT:-$RUN_EXIT}

case $FINAL_EXIT in
    0)
        echo "  2.3 PASS: Temp view AND data survived checkpoint/restore"
        PASS=$((PASS + 1))
        ;;
    2)
        echo "  2.3 PARTIAL: temp view lost, but same session functional after restore"
        PASS=$((PASS + 1))
        ;;
    *)
        fail "Spark Connect not functional after restore"
        ;;
esac

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "Phase 2 Results: $PASS passed, $FAIL failed"
case $FINAL_EXIT in
    0) echo "FULL PASS: session state survived CRIU checkpoint/restore" ;;
    2) echo "PARTIAL PASS: session reconnected but temp view lost" ;;
    *) echo "FAILED" ;;
esac
echo "============================================"
exit $FINAL_EXIT
