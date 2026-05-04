#!/usr/bin/env bash
# Boots a container from a given image (digest-pinned recommended) and waits
# for the /healthz endpoint to return 2xx.
#
# Usage: scripts/smoke-test.sh <image-ref>
#   <image-ref> is e.g. ghcr.io/openclaw/openclaw@sha256:abc... or a local tag.
#
# Env:
#   SMOKE_PORT        host port to publish (default 18789)
#   SMOKE_TIMEOUT_SECS  /healthz wait budget (default 180)
#
# Exits 0 on healthy, non-zero on timeout/error. Always cleans up the container.
# Logs from the container are printed on failure with the test token redacted.

set -euo pipefail

image="${1:-}"
if [ -z "$image" ]; then
    echo >&2 "Usage: $0 <image-ref>"
    exit 2
fi

container="oc-smoke-$$"
host_port="${SMOKE_PORT:-18789}"
container_port=18789
timeout_secs="${SMOKE_TIMEOUT_SECS:-180}"

token=$(openssl rand -hex 32)

cleanup() {
    if docker inspect "$container" >/dev/null 2>&1; then
        # Redact the test token from logs before printing.
        docker logs "$container" 2>&1 | sed "s|${token}|[REDACTED-TEST-TOKEN]|g" | tail -200 >&2 || true
        docker rm --force "$container" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "Pulling $image"
docker pull "$image" >/dev/null

docker run --detach \
    --name "$container" \
    --env "OPENCLAW_GATEWAY_TOKEN=$token" \
    --publish "${host_port}:${container_port}" \
    "$image" \
    node /app/openclaw.mjs gateway --bind lan --port "$container_port" --allow-unconfigured \
    >/dev/null

deadline=$(( $(date +%s) + timeout_secs ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    # Container exited early — fail fast instead of polling for the full budget.
    state=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
    if [ "$state" != "true" ]; then
        echo >&2 "Smoke test FAILED: container exited unexpectedly"
        exit 1
    fi
    if curl --fail --silent --show-error \
        "http://127.0.0.1:${host_port}/healthz" >/dev/null 2>&1; then
        echo "Smoke test OK: /healthz responded within ${timeout_secs}s"
        exit 0
    fi
    sleep 2
done

echo >&2 "Smoke test FAILED: /healthz did not respond within ${timeout_secs}s"
exit 1
