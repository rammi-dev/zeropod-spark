#!/usr/bin/env python3
"""Simulate a real notebook: single process, hold session, wait, resume.

This is the true notebook test:
  1. Connect and prepare DataFrame + temp view
  2. Hold the session (idle gRPC connection stays open)
  3. Sleep for scaledown duration + buffer
  4. Use the SAME session object to query the temp view

The shell harness monitors zeropod logs to confirm checkpoint happened.
"""
import sys
import time

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

ENDPOINT = sys.argv[1] if len(sys.argv) > 1 else "sc://spark-connect-server-svc.spark-workload.svc.cluster.local:15002"
IDLE_WAIT = int(sys.argv[2]) if len(sys.argv) > 2 else 360

EXPECTED_COUNT = 10000
EXPECTED_SUM_SQUARED = 333383335000
VIEW_NAME = "df_survival_test"


def info(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"  [{ts}] {msg}", flush=True)


# ── Phase 1: Connect and prepare ──────────────────────────────────
print("\n=== PHASE 1: Prepare DataFrame ===", flush=True)
info(f"Connecting to {ENDPOINT}...")

t0 = time.time()
spark = SparkSession.builder.remote(ENDPOINT).getOrCreate()
info(f"Connected in {time.time() - t0:.2f}s")
info(f"Session ID: {spark.session_id}")

t0 = time.time()
df = spark.range(1, EXPECTED_COUNT + 1) \
    .withColumn("squared", F.col("id") * F.col("id")) \
    .withColumn("bucket", (F.col("id") % 10).cast("int"))

df.cache()
count = df.count()
sum_sq = df.agg(F.sum("squared")).collect()[0][0]
df.createOrReplaceTempView(VIEW_NAME)
info(f"Prepared: {count} rows, sum_squared={sum_sq} in {time.time() - t0:.2f}s")

if count != EXPECTED_COUNT or sum_sq != EXPECTED_SUM_SQUARED:
    print("FAIL: unexpected results", flush=True)
    sys.exit(1)

print("PASS: Phase 1", flush=True)

# ── Phase 2: Hold session idle ────────────────────────────────────
print(f"\n=== PHASE 2: Holding session idle for {IDLE_WAIT}s ===", flush=True)
info("gRPC connection stays open — no Spark calls")
info("ZeroPod should checkpoint if CRIU can handle the open TCP socket")

interval = 30
elapsed = 0
while elapsed < IDLE_WAIT:
    time.sleep(interval)
    elapsed += interval
    info(f"Idle... {elapsed}s / {IDLE_WAIT}s")

print("Phase 2 done — idle wait complete", flush=True)

# ── Phase 3: Resume with SAME session ─────────────────────────────
print("\n=== PHASE 3: Resume with same session ===", flush=True)
info(f"Using same SparkSession (id={spark.session_id})")
info("Next Spark call triggers ZeroPod restore (if checkpoint happened)...")

t0 = time.time()
try:
    result = spark.sql(f"SELECT * FROM {VIEW_NAME}")
    resume_count = result.count()
    elapsed_ms = (time.time() - t0) * 1000
    info(f"Query returned {resume_count} rows in {elapsed_ms:.0f}ms")

    if resume_count == EXPECTED_COUNT:
        sum_sq2 = result.agg(F.sum("squared")).collect()[0][0]
        if sum_sq2 == EXPECTED_SUM_SQUARED:
            print(f"PASS: Phase 3 — temp view survived, data intact", flush=True)
            print(f"  Session {spark.session_id} preserved across CRIU freeze/thaw", flush=True)
            print(f"  Resume latency: {elapsed_ms:.0f}ms", flush=True)
            spark.stop()
            sys.exit(0)

    print(f"FAIL: data mismatch after restore", flush=True)
    spark.stop()
    sys.exit(1)

except Exception as e:
    elapsed_ms = (time.time() - t0) * 1000
    info(f"Query failed after {elapsed_ms:.0f}ms: {e}")

    # Fallback: try rebuilding on same session
    print("\n--- Fallback: rebuild on same session ---", flush=True)
    try:
        t0 = time.time()
        df2 = spark.range(1, EXPECTED_COUNT + 1) \
            .withColumn("squared", F.col("id") * F.col("id"))
        c = df2.count()
        info(f"Rebuild: {c} rows in {(time.time() - t0) * 1000:.0f}ms")
        if c == EXPECTED_COUNT:
            print("PARTIAL PASS: temp view lost but session functional", flush=True)
            spark.stop()
            sys.exit(2)
    except Exception as e2:
        print(f"FAIL: cannot use Spark after restore: {e2}", flush=True)

    spark.stop()
    sys.exit(1)
