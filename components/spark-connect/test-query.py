#!/usr/bin/env python3
"""Test Spark Connect server by running a simple query.

Usage:
  # With port-forward active (kubectl port-forward svc/... 15002:15002):
  python3 test-query.py

  # With custom endpoint:
  python3 test-query.py sc://localhost:15002
"""
import sys
import time

try:
    from pyspark.sql import SparkSession
except ImportError:
    print("ERROR: pyspark not installed. Run: pip install pyspark[connect]")
    sys.exit(1)

endpoint = sys.argv[1] if len(sys.argv) > 1 else "sc://localhost:15002"

print(f"Connecting to {endpoint}...")
start = time.time()

spark = SparkSession.builder \
    .remote(endpoint) \
    .getOrCreate()

connect_time = time.time() - start
print(f"Connected in {connect_time:.2f}s")

# Simple query
start = time.time()
df = spark.range(100).filter("id > 50")
count = df.count()
query_time = time.time() - start

print(f"Query result: count = {count} (expected 49)")
print(f"Query time: {query_time:.2f}s")

spark.stop()
print("Disconnected.")

if count != 49:
    print("FAIL: unexpected count")
    sys.exit(1)

print("PASS")
