#!/usr/bin/env python3
"""
ZeroPod Resource Resizer Controller

Watches pods with ZeroPod annotations for checkpoint/restore events.
On checkpoint: saves original resource requests, resizes to near-zero.
On restore: reads saved requests, resizes back to original values.

Uses KEP-1287 In-Place Pod Vertical Scaling (K8s 1.33+ Beta).

Run locally:  python3 controller.py
Run in-cluster: deployed as a pod (see deploy.yaml)
"""

import json
import logging
import os

import kopf
import kubernetes
from kubernetes import client

# Configuration
ANNOTATION_ORIGINAL = "zeropod-resizer.dev/original-requests"
ANNOTATION_STATUS = "zeropod-resizer.dev/status"  # "resized-down" | "resized-up"
FROZEN_REQUESTS = {"cpu": "1m", "memory": "1Mi"}
WATCH_NAMESPACE = os.environ.get("WATCH_NAMESPACE", "spark-workload")
ZEROPOD_CONTAINER_NAMES_ANN = "zeropod.ctrox.dev/container-names"

# TODO: Determine actual ZeroPod annotation/field that signals checkpoint/restore.
# These are placeholders — update after Phase 1 testing reveals ZeroPod's event model.
ZEROPOD_STATUS_ANN = "zeropod.ctrox.dev/status"  # hypothetical
STATUS_CHECKPOINTED = "scaled-down"  # hypothetical value
STATUS_RUNNING = "running"  # hypothetical value

logger = logging.getLogger("zeropod-resizer")


@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    """Configure kopf operator settings."""
    settings.watching.server_timeout = 270
    settings.watching.client_timeout = 300
    settings.posting.level = logging.WARNING
    logger.info(f"ZeroPod Resizer starting, watching namespace={WATCH_NAMESPACE}")


@kopf.on.field(
    "v1", "pods",
    namespace=WATCH_NAMESPACE,
    field=f"metadata.annotations.{ZEROPOD_STATUS_ANN.replace('/', '~1')}",
)
def on_zeropod_status_change(name, namespace, old, new, body, **_):
    """
    React to ZeroPod status annotation changes on pods.

    TODO: This handler assumes ZeroPod sets an annotation when it checkpoints
    or restores a container. The actual detection mechanism needs to be
    determined during Phase 1 testing. Alternatives:
      - Watch Prometheus metrics (zeropod_container_status)
      - Poll pod container statuses for state changes
      - Scrape zeropod-manager logs
    """
    logger.info(f"Pod {namespace}/{name}: zeropod status {old!r} -> {new!r}")

    if new == STATUS_CHECKPOINTED:
        _handle_checkpoint(name, namespace, body)
    elif new == STATUS_RUNNING:
        _handle_restore(name, namespace, body)


@kopf.timer(
    "v1", "pods",
    namespace=WATCH_NAMESPACE,
    interval=30,
    annotations={ZEROPOD_CONTAINER_NAMES_ANN: kopf.PRESENT},
)
def poll_zeropod_status(name, namespace, body, **_):
    """
    Fallback: periodically poll pods with ZeroPod annotations.

    If ZeroPod doesn't set status annotations, this timer checks container
    status or other signals to detect checkpoint/restore events.

    TODO: Implement actual detection logic after Phase 1 reveals how
    ZeroPod represents frozen state. Possible signals:
      - container status changes (Running -> some other state)
      - process count inside container drops to 0
      - zeropod-manager metrics
    """
    annotations = body.get("metadata", {}).get("annotations", {})
    our_status = annotations.get(ANNOTATION_STATUS, "")

    # TODO: Replace this with actual checkpoint detection
    # For now, this is a no-op placeholder
    is_checkpointed = _detect_checkpoint(body)

    if is_checkpointed and our_status != "resized-down":
        logger.info(f"Detected checkpoint on {namespace}/{name}, resizing down")
        _handle_checkpoint(name, namespace, body)
    elif not is_checkpointed and our_status == "resized-down":
        logger.info(f"Detected restore on {namespace}/{name}, resizing up")
        _handle_restore(name, namespace, body)


def _detect_checkpoint(body: dict) -> bool:
    """
    Detect if a pod's container is currently checkpointed.

    TODO: Implement based on Phase 1 findings. Possible approaches:
    1. Check ZeroPod annotation (if it sets one)
    2. Check container status (may show non-Running state)
    3. Query ZeroPod metrics endpoint
    4. Check if process is frozen (signals from kubelet)

    Returns True if container is checkpointed, False if running.
    """
    # Placeholder — always returns False (no detection yet)
    return False


def _handle_checkpoint(name: str, namespace: str, body: dict):
    """Save original requests and resize pod to near-zero."""
    api = client.CoreV1Api()

    # Find the ZeroPod-managed container
    container_name = _get_zeropod_container(body)
    if not container_name:
        logger.warning(f"No ZeroPod container found on {namespace}/{name}")
        return

    # Get current resource requests
    containers = body.get("spec", {}).get("containers", [])
    container = next((c for c in containers if c["name"] == container_name), None)
    if not container:
        logger.warning(f"Container {container_name} not found on {namespace}/{name}")
        return

    original_requests = container.get("resources", {}).get("requests", {})
    if not original_requests:
        logger.info(f"No resource requests on {namespace}/{name}, skipping")
        return

    # Save original requests as annotation
    logger.info(f"Saving original requests: {original_requests}")
    api.patch_namespaced_pod(
        name=name,
        namespace=namespace,
        body={
            "metadata": {
                "annotations": {
                    ANNOTATION_ORIGINAL: json.dumps(original_requests),
                    ANNOTATION_STATUS: "resized-down",
                }
            }
        },
    )

    # Resize to near-zero using /resize subresource
    logger.info(f"Resizing down: {original_requests} -> {FROZEN_REQUESTS}")
    _resize_pod(api, name, namespace, container_name, FROZEN_REQUESTS)


def _handle_restore(name: str, namespace: str, body: dict):
    """Restore original resource requests from annotation."""
    api = client.CoreV1Api()

    annotations = body.get("metadata", {}).get("annotations", {})
    original_json = annotations.get(ANNOTATION_ORIGINAL)
    if not original_json:
        logger.warning(f"No saved requests on {namespace}/{name}, cannot resize up")
        return

    original_requests = json.loads(original_json)
    container_name = _get_zeropod_container(body)
    if not container_name:
        return

    # Resize back to original
    logger.info(f"Resizing up: {FROZEN_REQUESTS} -> {original_requests}")
    _resize_pod(api, name, namespace, container_name, original_requests)

    # Update status annotation
    api.patch_namespaced_pod(
        name=name,
        namespace=namespace,
        body={
            "metadata": {
                "annotations": {
                    ANNOTATION_STATUS: "resized-up",
                }
            }
        },
    )


def _resize_pod(api: client.CoreV1Api, name: str, namespace: str,
                container_name: str, requests: dict):
    """
    Patch pod resource requests using the /resize subresource (KEP-1287).

    Requires:
      - K8s 1.33+ (InPlacePodVerticalScaling feature gate)
      - Container has resizePolicy with restartPolicy: NotRequired
    """
    patch_body = {
        "spec": {
            "containers": [
                {
                    "name": container_name,
                    "resources": {
                        "requests": requests,
                    },
                }
            ]
        }
    }

    try:
        # Use the /resize subresource
        api.patch_namespaced_pod_resize(
            name=name,
            namespace=namespace,
            body=patch_body,
        )
        logger.info(f"Resized {namespace}/{name}:{container_name} -> {requests}")
    except kubernetes.client.ApiException as e:
        if e.status == 422:
            logger.error(
                f"Resize rejected for {namespace}/{name} — "
                f"container may lack resizePolicy or resize not supported: {e.reason}"
            )
        else:
            logger.error(f"Failed to resize {namespace}/{name}: {e}")
            raise


def _get_zeropod_container(body: dict) -> str | None:
    """Get the container name managed by ZeroPod from pod annotations."""
    annotations = body.get("metadata", {}).get("annotations", {})
    names = annotations.get(ZEROPOD_CONTAINER_NAMES_ANN, "")
    if not names:
        return None
    # Return first container name (comma-separated list)
    return names.split(",")[0].strip()
