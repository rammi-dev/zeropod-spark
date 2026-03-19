# Phase 2 Test Results — DataFrame Survival Across Checkpoint/Restore

**Date**: 2026-03-19
**Cluster**: minikube `zeropod-poc` (Hyper-V, containerd, K8s v1.35.0)
**ZeroPod**: v0.11.2, scaledown-duration=5m
**Spark**: 4.1.1 (Spark Connect server)

## Test 2.1: Prepare DataFrame (in-cluster Job)

**Result: PASS**

- Connected to `spark-connect-server-svc.spark-workload.svc.cluster.local:15002`
- Built DataFrame: 10,000 rows, 10 buckets, sum_squared=333383335000
- Created temp view `df_survival_test`
- Session ID: `a445f1f8-a2a1-4e64-a004-947dc2b1deb4`
- Prep time: 5.07s
- Connection time from in-cluster: 0.27s (vs ~3s via port-forward from WSL)

## Test 2.2: Wait for ZeroPod Checkpoint

**Result: PASS**

- Baseline SCALED_DOWN events: 4
- New checkpoint detected after 300s (5 minutes of zero TCP traffic)
- Checkpoint duration: reported in zeropod logs
- Driver pod stayed in Running status (ZeroPod uses in-place resource scaling)

## Test 2.3: Resume with Same session_id After Restore

**Result: PASS (FULL)**

- Reconnected from a **new pod** using same session_id via:
  `sc://...server-svc:15002/;session_id=a445f1f8-a2a1-4e64-a004-947dc2b1deb4`
- Session ID confirmed: `a445f1f8-a2a1-4e64-a004-947dc2b1deb4` (matches prepare phase)
- Temp view `df_survival_test` returned 10,000 rows
- Data integrity verified (sum_squared matches)
- ZeroPod restore duration: **249ms**
- Total resume time (including pip install, connect, query): 51.6s
- Query time after restore: 4.15s

## What This Proves

1. **CRIU preserves JVM heap** — `SessionHolder`, temp views, cached DataFrames all survive
   checkpoint/restore
2. **Spark Connect sessions are keyed by `session_id`**, not TCP connection — a new client
   pod with the same session_id gets the same server-side session
3. **ZeroPod restore is fast** — 249ms from frozen to serving queries
4. **No port-forward needed** — in-cluster service DNS works correctly

## What This Does NOT Prove (yet)

The test used **two separate pods** (Job for prepare, Job for resume). This proved session_id
reattachment but does NOT simulate a real notebook scenario where:

- A single long-lived pod holds the SparkSession object
- The same process goes idle and later resumes
- The idle gRPC channel (open TCP socket, no traffic) may or may not prevent checkpoint

**Next step**: Run the test as a single long-lived pod inside the cluster to validate the
real notebook use case — same process, same session object, idle gRPC connection.

### Resolved: idle gRPC TCP connection does NOT prevent checkpoint

Initial concern: CRIU's `AllowOpenTCP: false` would prevent checkpoint when a notebook
holds an idle gRPC connection. **This turned out to be wrong.**

ZeroPod includes a custom CRIU patch (`criu/tcp-listen.patch`) that handles this:
- When a socket inode has both LISTEN and ESTABLISHED entries, the patch **skips the
  ESTABLISHED socket** and checkpoints only the LISTEN one
- Combined with `--tcp-skip-in-flight`, idle established connections are ignored
- CRIU checkpoints successfully despite the open TCP connection

**Notebook simulation test confirmed this** (phase2-notebook.sh):
- Single pod held an open SparkSession with idle gRPC connection for 6 minutes
- ZeroPod checkpointed the driver at 19:52:45 (317ms checkpoint)
- Phase 3 query at 19:52:50 triggered restore (273ms)
- Temp view returned 10,000 rows — data intact
- Same session ID preserved across CRIU freeze/thaw

### Previous port-forward issue explained

The earlier port-forward test failed because `kubectl port-forward` generates
continuous TCP traffic (not just an idle connection), which kept resetting ZeroPod's
activity tracker. The issue was traffic, not the open socket itself.

## Notebook Simulation Test (phase2-notebook.sh)

**Result: FULL PASS**

Single long-lived pod simulating a real notebook user:

| Phase | Time | Result |
|-------|------|--------|
| 1. Connect + prepare | 20:31:35 | 10k rows, temp view created, session `d13e0495-...` |
| 1→idle | 20:31:35 | gRPC connection open, no Spark calls |
| 2. Checkpoint | 20:36:36 | SCALED_DOWN after 5 min idle (**330ms** checkpoint) |
| 3. Resume (same session) | 20:37:35 | RUNNING restored in **299ms** |
| 3. Query result | 20:37:39 | 10,000 rows, data intact, 4008ms total |

Monitoring confirmed: checkpoint detected at 210s into monitor window (events: 4 → 6).

**Key findings:**
- CRIU checkpoints the JVM **despite an open idle TCP connection** from the notebook
- ZeroPod's custom CRIU patch (`tcp-listen.patch`) + `--tcp-skip-in-flight` handles this
- Same SparkSession object, same session_id, same temp views — fully transparent
- No Spark patches, no client changes, no gRPC config needed
- **This is NOT a deal breaker — it works out of the box**

## Security Finding

The `session_id` parameter (`sc://host:port/;session_id=<uuid>`) allows **any client** to
attach to an existing session. This is a potential session hijacking vector in multi-tenant
environments. See `docs/spark-connect-session-behavior.md` for details.
