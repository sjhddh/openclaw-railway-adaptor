#!/usr/bin/env bash
# Resolves a tag on ghcr.io/openclaw/openclaw to its current manifest digest.
#
# Usage: scripts/resolve-upstream-digest.sh [tag]
#   If [tag] is omitted, reads from UPSTREAM_TAG.
#
# Prints the digest (sha256:...) on success, exits non-zero on failure.
# Retries each network call up to 3 times with backoff to ride out GHCR blips.

set -euo pipefail

tag="${1:-}"
if [ -z "$tag" ]; then
    if [ ! -f UPSTREAM_TAG ]; then
        echo >&2 "ERROR: no tag argument and UPSTREAM_TAG file missing"
        exit 2
    fi
    tag=$(tr -d '[:space:]' < UPSTREAM_TAG)
fi

if [ -z "$tag" ]; then
    echo >&2 "ERROR: tag is empty"
    exit 2
fi

retry_curl() {
    # retry_curl <description> <curl args...>
    # Runs curl up to 3 times with exponential backoff. Echoes result on success.
    local desc="$1"
    shift
    local attempt
    for attempt in 1 2 3; do
        if out=$(curl --fail --silent --show-error --location --max-time 30 "$@"); then
            printf '%s' "$out"
            return 0
        fi
        echo >&2 "WARN: $desc failed (attempt $attempt/3)"
        sleep $((attempt * 5))
    done
    echo >&2 "ERROR: $desc failed after 3 attempts"
    return 1
}

token_json=$(retry_curl "GHCR token request" \
    "https://ghcr.io/token?scope=repository:openclaw/openclaw:pull&service=ghcr.io")

token=$(printf '%s' "$token_json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

# Validate token format before using it in an Authorization header.
# A token with whitespace, control chars, or CR/LF would let a hostile
# response inject extra headers or break the request.
if ! printf '%s' "$token" | grep -Eq '^[A-Za-z0-9._=+/-]+$'; then
    echo >&2 "ERROR: GHCR returned an unexpected token format; refusing to use it"
    exit 1
fi

headers_dump=$(retry_curl "GHCR manifest HEAD" \
    --header "Authorization: Bearer ${token}" \
    --header "Accept: application/vnd.oci.image.index.v1+json" \
    --header "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    --header "Accept: application/vnd.oci.image.manifest.v1+json" \
    --header "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    --dump-header - --output /dev/null \
    "https://ghcr.io/v2/openclaw/openclaw/manifests/${tag}")

digest=$(printf '%s' "$headers_dump" \
    | awk 'tolower($1) == "docker-content-digest:" { print $2; exit }' \
    | tr -d '\r\n[:space:]')

if [ -z "$digest" ] || ! printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo >&2 "ERROR: failed to resolve digest for tag '$tag' (got: '$digest')"
    exit 1
fi

printf '%s\n' "$digest"
