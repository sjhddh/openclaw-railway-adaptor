#!/usr/bin/env sh
# OpenClaw Railway entrypoint.
#
# Runs as root to chown the Railway-mounted volume at /data (volumes can come
# up root-owned, blocking the non-root node user). Validates required env,
# ensures state directories exist, then drops privileges to node and execs
# the upstream gateway with Railway-friendly bind/port flags.

set -eu

state_dir="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
workspace_dir="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
port="${PORT:-8080}"

if [ "$(id -u)" = "0" ]; then
    chown node:node /data 2>/dev/null || true
    install -d -m 0755 -o node -g node "$state_dir" "$workspace_dir" 2>/dev/null || {
        printf >&2 'ERROR: cannot create state dirs under /data.\n'
        printf >&2 '       Attach a Railway volume at /data, or override\n'
        printf >&2 '       OPENCLAW_STATE_DIR / OPENCLAW_WORKSPACE_DIR.\n'
        exit 1
    }
fi

if [ ! -w "$state_dir" ] || [ ! -w "$workspace_dir" ]; then
    printf >&2 'ERROR: state dirs not writable (%s, %s).\n' "$state_dir" "$workspace_dir"
    printf >&2 '       Check Railway volume permissions on /data.\n'
    exit 1
fi

if command -v mountpoint >/dev/null 2>&1; then
    if ! mountpoint -q /data 2>/dev/null; then
        printf >&2 'WARN: /data is not a mountpoint. Attach a Railway volume at /data\n'
        printf >&2 '      to persist OpenClaw state and channel auth across redeploys.\n'
    fi
fi

# Token validation: must be present, non-whitespace, ≥24 chars. The wrapper
# binds to LAN (0.0.0.0) via --bind lan, so the gateway is publicly reachable
# through the Railway proxy. A weak/blank token would publicly expose it.
tok=""
if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    tok="$OPENCLAW_GATEWAY_TOKEN"
elif [ -n "${OPENCLAW_GATEWAY_PASSWORD:-}" ]; then
    tok="$OPENCLAW_GATEWAY_PASSWORD"
fi

if [ -z "$tok" ]; then
    printf >&2 'ERROR: OPENCLAW_GATEWAY_TOKEN (or OPENCLAW_GATEWAY_PASSWORD) is\n'
    printf >&2 '       required. The gateway binds to LAN and refuses to start\n'
    printf >&2 '       unauthenticated. Generate one with:\n'
    printf >&2 '         openssl rand -hex 32\n'
    printf >&2 '       Add it as a Railway service variable, then redeploy.\n'
    exit 1
fi

# Compare against a tab/space/newline-stripped copy. POSIX-portable (avoids
# command substitution inside case patterns, which behaves inconsistently
# across shells when the substitution result is empty).
tok_clean=$(printf '%s' "$tok" | tr -d '[:space:]')
if [ "$tok_clean" != "$tok" ]; then
    printf >&2 'ERROR: gateway token contains whitespace. Regenerate with:\n'
    printf >&2 '         openssl rand -hex 32\n'
    exit 1
fi

tok_len=$(printf '%s' "$tok" | wc -c | tr -d '[:space:]')
if [ "$tok_len" -lt 24 ]; then
    printf >&2 'ERROR: gateway token too short (%d chars; need at least 24).\n' "$tok_len"
    printf >&2 '       Regenerate with: openssl rand -hex 32\n'
    exit 1
fi
unset tok tok_clean tok_len

# Build argv. --allow-unconfigured lets the gateway boot without LLM keys so
# the user can configure via UI/API after deploy. Set OPENCLAW_REQUIRE_CONFIGURED=1
# to disable this and require a fully-configured deploy.
set -- gateway --bind lan --port "$port"
if [ "${OPENCLAW_REQUIRE_CONFIGURED:-}" != "1" ]; then
    set -- "$@" --allow-unconfigured
fi

# Drop privileges if running as root.
if [ "$(id -u)" = "0" ]; then
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u node -- node /app/openclaw.mjs "$@"
    elif command -v su >/dev/null 2>&1; then
        # Pass argv through positional params to su's child shell.
        exec su -s /bin/sh node -c \
            'exec node /app/openclaw.mjs "$@"' \
            -- "$@"
    else
        printf >&2 'WARN: no runuser/su available; running gateway as root.\n'
        exec node /app/openclaw.mjs "$@"
    fi
else
    exec node /app/openclaw.mjs "$@"
fi
