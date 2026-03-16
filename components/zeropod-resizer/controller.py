#!/usr/bin/env python3
"""
ZeroPod Resource Resizer Controller (Phase 2 - Placeholder)

Watches for ZeroPod checkpoint/restore events and resizes pod resource
requests using KEP-1287 in-place vertical pod scaling.

On checkpoint: save original requests as annotation, resize to near-zero.
On restore: read annotation, resize back to original values.

TODO:
  1. Research ZeroPod's event model — how does it signal checkpoint/restore?
     Options: Prometheus metrics, pod status, log scraping, custom annotation
  2. Implement detection mechanism
  3. Test in-place resize on CRIU-frozen pods
  4. Handle edge cases (pod restart, annotation missing, resize rejected)
"""

import json
import os
import sys
import time

# TODO: pip install kubernetes
# from kubernetes import client, config, watch

ANNOTATION_KEY = "zeropod-resizer/original-requests"
FROZEN_REQUESTS = {"cpu": "1m", "memory": "1Mi"}
WATCH_NAMESPACE = os.environ.get("WATCH_NAMESPACE", "spark-workload")


def save_original_requests(pod, container_name):
    """Save current resource requests as an annotation before resizing down."""
    # TODO: implement
    pass


def resize_down(pod, container_name):
    """Resize pod requests to near-zero after checkpoint."""
    # TODO: implement using /resize subresource
    # PATCH /api/v1/namespaces/{ns}/pods/{name}/resize
    pass


def resize_up(pod, container_name):
    """Restore pod requests from annotation after restore."""
    # TODO: implement
    pass


def detect_checkpoint_event():
    """
    Detect when ZeroPod checkpoints a container.

    Options to research:
    1. Watch ZeroPod Prometheus metrics (zeropod_container_status)
    2. Watch pod status changes
    3. Scrape zeropod-manager logs
    4. Poll pod annotations set by ZeroPod
    """
    # TODO: implement based on ZeroPod's actual event model
    pass


def main():
    print(f"ZeroPod Resizer Controller starting...")
    print(f"Watching namespace: {WATCH_NAMESPACE}")
    print(f"Frozen requests: {FROZEN_REQUESTS}")
    print()
    print("TODO: This is a placeholder. Implement the controller.")
    sys.exit(1)


if __name__ == "__main__":
    main()
