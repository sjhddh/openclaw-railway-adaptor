#!/usr/bin/env sh
# OpenClaw Railway entrypoint.
#
# Runs as root to chown the Railway-mounted volume at /data (volumes can come
# up root-owned, blocking the non-root node user). If the operator supplied a
# gateway token, validates its strength. Otherwise, lets upstream openclaw
# auto-generate one on first start (the value is persisted under
# OPENCLAW_STATE_DIR — find it in `gateway.json` after first boot). Drops
# privileges to the node user via gosu, then execs the upstream gateway.

set -eu

state_dir="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
workspace_dir="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
port="${PORT:-8080}"

printf 'openclaw-railway-adaptor: starting (port=%s, state=%s)\n' \
    "$port" "$state_dir"

if [ "$(id -u)" = "0" ]; then
    # Reclaim the entire /data tree for the node user (uid 1000). Railway
    # volumes can come up with files from a previous template's setup that
    # are owned by a different uid — without -R, our gateway fails to read
    # /data/<state_dir>/openclaw.json with EACCES on first boot.
    chown -R node:node /data 2>/dev/null || \
        printf >&2 'WARN: chown -R /data failed; some files may remain unreadable.\n'
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

# Token policy:
#   - If OPENCLAW_GATEWAY_TOKEN (or _PASSWORD) is set: validate strength.
#   - If unset: do nothing — upstream openclaw auto-generates a strong token
#     on first start when binding beyond loopback (per upstream's render.yaml
#     `generateValue: true` precedent). The auto-gen value is written to the
#     gateway's state and surfaced in the gateway logs / state file.
tok=""
if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    tok="$OPENCLAW_GATEWAY_TOKEN"
elif [ -n "${OPENCLAW_GATEWAY_PASSWORD:-}" ]; then
    tok="$OPENCLAW_GATEWAY_PASSWORD"
fi

if [ -n "$tok" ]; then
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
    printf 'openclaw-railway-adaptor: using operator-supplied gateway token\n'
    unset tok_clean tok_len
else
    printf 'openclaw-railway-adaptor: no token set; upstream will auto-generate\n'
    printf '  (find it in %s/gateway.json after first boot, or set\n' "$state_dir"
    printf '   OPENCLAW_GATEWAY_TOKEN as a service variable)\n'
fi
unset tok

# Build argv for the gateway. --allow-unconfigured is on by default so the
# gateway boots without LLM keys (configure via UI/API after deploy). Set
# OPENCLAW_REQUIRE_CONFIGURED=1 to disable.
set -- gateway --bind lan --port "$port"
if [ "${OPENCLAW_REQUIRE_CONFIGURED:-}" != "1" ]; then
    set -- "$@" --allow-unconfigured
fi

# Mirror the port into upstream's env-var path too (belt & suspenders against
# upstream changes to flag parsing).
export OPENCLAW_GATEWAY_PORT="$port"
export OPENCLAW_GATEWAY_BIND="lan"

if [ "$(id -u)" = "0" ]; then
    if command -v gosu >/dev/null 2>&1; then
        printf 'openclaw-railway-adaptor: dropping privileges (root -> node) via gosu\n'
        exec gosu node node /app/openclaw.mjs "$@"
    else
        printf >&2 'WARN: gosu missing; running gateway as root (degraded).\n'
        exec node /app/openclaw.mjs "$@"
    fi
else
    exec node /app/openclaw.mjs "$@"
fi
