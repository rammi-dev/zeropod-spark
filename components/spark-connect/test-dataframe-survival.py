#!/usr/bin/env python3
"""Test DataFrame survival across ZeroPod checkpoint/restore.

Simulates a real notebook user: same Spark Connect session_id across
checkpoint/restore. Run as K8s Jobs inside the cluster (no port-forward).

  1. `prepare` — connect, build cached DataFrame + temp view, print session_id
  2. `resume <session_id>` — reconnect with SAME session_id, query temp view

Between the two calls, the client pod exits (no TCP traffic to the driver),
ZeroPod checkpoints the idle driver, then a new pod reconnects with the
same session_id.

The session_id can be passed via the Spark Connect URI:
  sc://spark-connect-server-svc:15002/;session_id=<uuid>

Security note: any client knowing a session_id can attach to that session.
See docs/spark-connect-session-behavior.md for details.
"""
import sys
import time
import json

try:
    from pyspark.sql import SparkSession
    from pyspark.sql import functions as F
except ImportError:
    print("ERROR: pyspark not installed")
    sys.exit(1)

EXPECTED_COUNT = 10000
EXPECTED_SUM_SQUARED = 333383335000
EXPECTED_BUCKETS = 10
VIEW_NAME = "df_survival_test"


def phase_prepare(endpoint):
    """Build a DataFrame, cache it, create temp view, print session_id."""
    print(f"Connecting to {endpoint}...")
    t0 = time.time()
    spark = SparkSession.builder.remote(endpoint).getOrCreate()
    print(f"Connected in {time.time() - t0:.2f}s")
    print(f"Session ID: {spark.session_id}")

    print("\n--- Preparing DataFrame ---")
    t0 = time.time()
    df = spark.range(1, EXPECTED_COUNT + 1) \
        .withColumn("squared", F.col("id") * F.col("id")) \
        .withColumn("bucket", (F.col("id") % 10).cast("int"))

    df.cache()
    total_count = df.count()
    bucket_rows = df.groupBy("bucket").count().orderBy("bucket").collect()
    sum_squared = df.agg(F.sum("squared")).collect()[0][0]
    prep_time = time.time() - t0

    print(f"Total rows:  {total_count} (expected {EXPECTED_COUNT})")
    print(f"Buckets:     {len(bucket_rows)} (expected {EXPECTED_BUCKETS})")
    print(f"Sum squared: {sum_squared} (expected {EXPECTED_SUM_SQUARED})")
    print(f"Prep time:   {prep_time:.2f}s")

    if total_count != EXPECTED_COUNT or len(bucket_rows) != EXPECTED_BUCKETS or sum_squared != EXPECTED_SUM_SQUARED:
        print("FAIL: unexpected results during prepare")
        return 1

    df.createOrReplaceTempView(VIEW_NAME)
    print(f"Temp view '{VIEW_NAME}' created")

    # Print session_id on its own line for easy extraction
    print(f"SESSION_ID={spark.session_id}")
    print("PASS: DataFrame prepared and cached")
    return 0


def phase_resume(endpoint, session_id):
    """Reconnect with the same session_id, query the temp view."""
    # Spark Connect URL format: sc://host:port/;key=value
    # The /; separates the path from parameters (parsed via urllib path params)
    full_endpoint = f"{endpoint}/;session_id={session_id}"
    print(f"Reconnecting to {full_endpoint}...")
    print(f"Reusing session_id: {session_id}")

    t0 = time.time()
    spark = SparkSession.builder.remote(full_endpoint).getOrCreate()
    connect_time = time.time() - t0
    print(f"Connected in {connect_time:.2f}s")
    print(f"Session ID: {spark.session_id}")

    if spark.session_id != session_id:
        print(f"WARNING: session_id mismatch! expected={session_id}, got={spark.session_id}")

    # Attempt 1: query the temp view
    print(f"\n--- Querying temp view '{VIEW_NAME}' via same session ---")
    try:
        t0 = time.time()
        result_df = spark.sql(f"SELECT * FROM {VIEW_NAME}")
        count = result_df.count()
        elapsed = time.time() - t0
        print(f"Temp view query returned {count} rows in {elapsed:.2f}s")

        if count == EXPECTED_COUNT:
            sum_sq = result_df.agg(F.sum("squared")).collect()[0][0]
            if sum_sq == EXPECTED_SUM_SQUARED:
                print("PASS: Temp view AND data survived checkpoint/restore")
                print(f"  Session {session_id} preserved across CRIU freeze/thaw")
                spark.stop()
                return 0  # full pass
            else:
                print(f"FAIL: data corrupted — sum_squared={sum_sq}, expected {EXPECTED_SUM_SQUARED}")
                spark.stop()
                return 1
        else:
            print(f"FAIL: expected {EXPECTED_COUNT} rows, got {count}")
            spark.stop()
            return 1

    except Exception as e:
        elapsed = time.time() - t0
        print(f"Temp view query failed after {elapsed:.2f}s: {e}")

    # Attempt 2: temp view lost — check if session is at least functional
    print("\n--- Fallback: rebuilding DataFrame on same session ---")
    try:
        t0 = time.time()
        df2 = spark.range(1, EXPECTED_COUNT + 1) \
            .withColumn("squared", F.col("id") * F.col("id")) \
            .withColumn("bucket", (F.col("id") % 10).cast("int"))
        count = df2.count()
        sum_sq = df2.agg(F.sum("squared")).collect()[0][0]
        elapsed = time.time() - t0

        print(f"Rebuilt count:       {count} (expected {EXPECTED_COUNT})")
        print(f"Rebuilt sum_squared: {sum_sq} (expected {EXPECTED_SUM_SQUARED})")
        print(f"Rebuild time:        {elapsed:.2f}s")

        if count == EXPECTED_COUNT and sum_sq == EXPECTED_SUM_SQUARED:
            print("PARTIAL PASS: temp view lost but same session functional after restore")
            spark.stop()
            return 2  # partial pass
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
        print("Usage:")
        print("  test-dataframe-survival.py prepare [endpoint]")
        print("  test-dataframe-survival.py resume <session_id> [endpoint]")
        sys.exit(1)

    phase = sys.argv[1]
    default_endpoint = "sc://spark-connect-server-svc.spark-workload.svc.cluster.local:15002"

    if phase == "prepare":
        endpoint = sys.argv[2] if len(sys.argv) > 2 else default_endpoint
        sys.exit(phase_prepare(endpoint))
    else:
        if len(sys.argv) < 3:
            print("ERROR: resume requires session_id argument")
            sys.exit(1)
        session_id = sys.argv[2]
        endpoint = sys.argv[3] if len(sys.argv) > 3 else default_endpoint
        sys.exit(phase_resume(endpoint, session_id))
