#!/usr/bin/env python3
"""Test DataFrame survival across ZeroPod checkpoint/restore.

Simulates a notebook workflow:
  1. Start Spark session, run a calculation, cache the DataFrame
  2. Verify the DataFrame is usable
  3. Wait for ZeroPod to scale down the driver (checkpoint)
  4. Attempt to reuse the same DataFrame after restore

Usage:
  # Phase A — build DataFrame and verify:
  python3 test-dataframe-survival.py prepare [endpoint]

  # Phase B — reuse DataFrame after restore:
  python3 test-dataframe-survival.py resume [endpoint]
"""
import sys
import time
import json

try:
    from pyspark.sql import SparkSession
    from pyspark.sql import functions as F
except ImportError:
    print("ERROR: pyspark not installed. Run: pip install pyspark[connect]")
    sys.exit(1)

STATE_FILE = "/tmp/spark-df-test-state.json"


def get_session(endpoint):
    print(f"Connecting to {endpoint}...")
    start = time.time()
    spark = SparkSession.builder \
        .remote(endpoint) \
        .getOrCreate()
    elapsed = time.time() - start
    print(f"Connected in {elapsed:.2f}s")
    return spark


def phase_prepare(endpoint):
    """Build a DataFrame, cache it, and verify results."""
    spark = get_session(endpoint)

    print("\n--- Preparing DataFrame ---")
    start = time.time()

    # Simulate a non-trivial calculation
    df = spark.range(1, 10001) \
        .withColumn("squared", F.col("id") * F.col("id")) \
        .withColumn("bucket", (F.col("id") % 10).cast("int"))

    # Cache to Spark memory so the data persists in the driver/executors
    df.cache()

    # Materialize the cache
    total_count = df.count()
    bucket_counts = df.groupBy("bucket").count().orderBy("bucket")
    bucket_rows = bucket_counts.collect()
    sum_squared = df.agg(F.sum("squared")).collect()[0][0]

    prep_time = time.time() - start

    print(f"Total rows:  {total_count} (expected 10000)")
    print(f"Buckets:     {len(bucket_rows)} (expected 10)")
    print(f"Sum squared: {sum_squared} (expected 333383335000)")
    print(f"Prep time:   {prep_time:.2f}s")

    # Save expected values so the resume phase can verify
    state = {
        "total_count": total_count,
        "bucket_count": len(bucket_rows),
        "sum_squared": sum_squared,
        "view_name": "df_survival_test",
    }

    # Register as a temp view so the resume phase can query by name
    df.createOrReplaceTempView(state["view_name"])

    with open(STATE_FILE, "w") as f:
        json.dump(state, f)

    ok = (total_count == 10000 and len(bucket_rows) == 10 and sum_squared == 333383335000)
    if not ok:
        print("FAIL: unexpected results during prepare")
        spark.stop()
        sys.exit(1)

    print("PASS: DataFrame prepared and cached")
    # Intentionally do NOT stop the session — it stays open for resume
    return 0


def phase_resume(endpoint):
    """Reconnect and try to reuse the DataFrame after ZeroPod restore."""
    # Load expected state
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except FileNotFoundError:
        print("FAIL: no state file — run 'prepare' phase first")
        sys.exit(1)

    spark = get_session(endpoint)
    view_name = state["view_name"]

    print(f"\n--- Resuming: querying temp view '{view_name}' ---")

    # Attempt 1: try the temp view (may fail if session state was lost)
    try:
        start = time.time()
        df = spark.sql(f"SELECT * FROM {view_name}")
        count = df.count()
        elapsed = time.time() - start
        print(f"Temp view query returned {count} rows in {elapsed:.2f}s")

        if count == state["total_count"]:
            print("PASS: temp view survived checkpoint/restore")
            spark.stop()
            return 0
        else:
            print(f"FAIL: expected {state['total_count']} rows, got {count}")
            spark.stop()
            return 1
    except Exception as e:
        print(f"Temp view query failed (expected if session state lost): {e}")

    # Attempt 2: rebuild and verify (proves the server is alive post-restore)
    print("\n--- Fallback: rebuilding DataFrame after restore ---")
    try:
        start = time.time()
        df = spark.range(1, 10001) \
            .withColumn("squared", F.col("id") * F.col("id")) \
            .withColumn("bucket", (F.col("id") % 10).cast("int"))
        count = df.count()
        sum_sq = df.agg(F.sum("squared")).collect()[0][0]
        elapsed = time.time() - start

        print(f"Rebuilt count:       {count} (expected {state['total_count']})")
        print(f"Rebuilt sum_squared: {sum_sq} (expected {state['sum_squared']})")
        print(f"Rebuild time:        {elapsed:.2f}s")

        if count == state["total_count"] and sum_sq == state["sum_squared"]:
            print("PARTIAL PASS: temp view lost but server functional after restore")
            spark.stop()
            return 2  # exit code 2 = partial pass
        else:
            print("FAIL: rebuilt DataFrame has wrong results")
            spark.stop()
            return 1
    except Exception as e:
        print(f"FAIL: cannot use Spark at all after restore: {e}")
        spark.stop()
        return 1


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("prepare", "resume"):
        print("Usage: test-dataframe-survival.py <prepare|resume> [endpoint]")
        sys.exit(1)

    phase = sys.argv[1]
    endpoint = sys.argv[2] if len(sys.argv) > 2 else "sc://localhost:15002"

    if phase == "prepare":
        sys.exit(phase_prepare(endpoint))
    else:
        sys.exit(phase_resume(endpoint))
