# Auto-managed wrapper around the upstream openclaw image.
#
# Source of truth for what tag to track: UPSTREAM_TAG.
# The FROM line below is rewritten by .github/workflows/sync-upstream.yml on
# every cron run. Do not edit the digest by hand — change UPSTREAM_TAG and
# the workflow repins on next run (or trigger it manually).
#
# Upstream image: https://github.com/openclaw/openclaw/pkgs/container/openclaw

FROM ghcr.io/openclaw/openclaw@sha256:142f70fa2751bdedf03648ae427372fff3f92ac0e96ab91abb3824b088c38b7b

USER root

# Pre-create the volume mount target. Railway mounts a volume on top of /data
# at runtime; the actual ownership is decided by the volume, not the image.
# start.sh runs as root and chowns /data before dropping to the node user, so
# the volume's initial mode/ownership doesn't matter.
RUN install -d -m 0755 -o node -g node /data

# Entrypoint shim: chowns the mounted volume, validates env, drops privileges
# to the node user, and execs the upstream gateway with --bind lan --port $PORT.
COPY start.sh /usr/local/bin/openclaw-railway-start.sh
RUN chmod 755 /usr/local/bin/openclaw-railway-start.sh

ENV OPENCLAW_STATE_DIR=/data/.openclaw \
    OPENCLAW_WORKSPACE_DIR=/data/workspace

# Drop the upstream Docker HEALTHCHECK — Railway uses railway.json's
# healthcheckPath against the proxied port, and the upstream check hardcodes
# 18789 which won't match $PORT.
HEALTHCHECK NONE

# start.sh is the entrypoint and runs as root to fix volume ownership;
# it then execs the gateway as the node user via runuser.
CMD ["/usr/local/bin/openclaw-railway-start.sh"]
