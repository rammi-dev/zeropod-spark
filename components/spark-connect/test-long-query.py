#!/usr/bin/env python3
"""Test: long-running query does NOT get checkpointed mid-flight.

Simulates a notebook user who:
  1. Connects and prepares a temp view
  2. Runs a heavy query that takes several minutes
  3. Goes idle after the query
  4. Resumes after checkpoint/restore

The shell harness verifies:
  - NO checkpoint during the query (TCP ACKs keep the timer alive)
  - Checkpoint happens AFTER the query finishes and idle period passes
"""
import sys
import time

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

ENDPOINT = sys.argv[1] if len(sys.argv) > 1 else "sc://spark-connect-server-svc.spark-workload.svc.cluster.local:15002"
IDLE_WAIT = int(sys.argv[2]) if len(sys.argv) > 2 else 360

VIEW_NAME = "long_query_test"


def info(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"  [{ts}] {msg}", flush=True)


# ── Phase 1: Connect ─────────────────────────────────────────────
print("\n=== PHASE 1: Connect ===", flush=True)
t0 = time.time()
spark = SparkSession.builder.remote(ENDPOINT).getOrCreate()
info(f"Connected in {time.time() - t0:.2f}s, session={spark.session_id}")

# Quick temp view for later verification
df = spark.range(1, 10001).withColumn("val", F.col("id") * 2)
df.cache()
df.count()
df.createOrReplaceTempView(VIEW_NAME)
info("Temp view created")
print("PASS: Phase 1", flush=True)

# ── Phase 2: Long-running query ──────────────────────────────────
# We need a query that keeps the server busy for >5 min (the scaledown duration).
# Strategy: repeated self-joins on a large range to force heavy shuffle.
print("\n=== PHASE 2: Long-running query (target: ~6 min) ===", flush=True)
info("LONG_QUERY_START")
query_start = time.time()

# Build a heavy computation using cross join to force real compute time.
# Target: >5 min so it spans the entire scaledown window.
# Cross joining 10k x 10k = 100M rows with aggregation is heavy enough.
a = spark.range(1, 10001).withColumnRenamed("id", "a")
b = spark.range(1, 10001).withColumnRenamed("id", "b")

batch = 0
while True:
    batch += 1
    info(f"Running batch {batch}...")
    t0 = time.time()
    result = a.crossJoin(b) \
        .withColumn("product", F.col("a") * F.col("b")) \
        .withColumn("bucket", (F.col("product") % 100).cast("int")) \
        .groupBy("bucket") \
        .agg(
            F.count("*").alias("cnt"),
            F.sum("product").alias("total"),
            F.avg("product").alias("avg_val"),
        ) \
        .orderBy("bucket") \
        .collect()
    elapsed = time.time() - t0
    info(f"Batch {batch} done in {elapsed:.1f}s ({len(result)} rows)")

    total = time.time() - query_start
    if total > 360:
        info(f"Reached {total:.0f}s total, target met")
        break
    info(f"Total elapsed: {total:.0f}s, continuing...")

query_elapsed = time.time() - query_start
info(f"LONG_QUERY_END — total query time: {query_elapsed:.0f}s")
print(f"PASS: Phase 2 — long query completed in {query_elapsed:.0f}s", flush=True)

# ── Phase 3: Go idle, wait for checkpoint ─────────────────────────
print(f"\n=== PHASE 3: Idle wait ({IDLE_WAIT}s) ===", flush=True)
info("Session idle — gRPC connection open, no Spark calls")

elapsed = 0
interval = 30
while elapsed < IDLE_WAIT:
    time.sleep(interval)
    elapsed += interval
    info(f"Idle... {elapsed}s / {IDLE_WAIT}s")

print("Phase 3 done", flush=True)

# ── Phase 4: Resume ──────────────────────────────────────────────
print("\n=== PHASE 4: Resume with same session ===", flush=True)
info(f"Session ID: {spark.session_id}")

t0 = time.time()
try:
    result = spark.sql(f"SELECT count(*) as cnt FROM {VIEW_NAME}")
    cnt = result.collect()[0]["cnt"]
    elapsed_ms = (time.time() - t0) * 1000
    info(f"Temp view query: {cnt} rows in {elapsed_ms:.0f}ms")

    if cnt == 10000:
        print("PASS: Phase 4 — session survived long query + checkpoint/restore", flush=True)
        spark.stop()
        sys.exit(0)
    else:
        print(f"FAIL: expected 10000, got {cnt}", flush=True)
        spark.stop()
        sys.exit(1)
except Exception as e:
    info(f"Query failed: {e}")
    # Fallback
    try:
        t0 = time.time()
        c = spark.range(1, 100).count()
        info(f"Fallback: {c} rows in {(time.time() - t0)*1000:.0f}ms")
        print("PARTIAL PASS: temp view lost but session functional", flush=True)
        spark.stop()
        sys.exit(2)
    except Exception as e2:
        print(f"FAIL: Spark not functional: {e2}", flush=True)
        spark.stop()
        sys.exit(1)
