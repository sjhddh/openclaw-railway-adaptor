# Auto-managed wrapper around the upstream openclaw image.
#
# Source of truth for what tag to track: UPSTREAM_TAG.
# The FROM line below is rewritten by .github/workflows/sync-upstream.yml on
# every cron run. Do not edit the digest by hand — change UPSTREAM_TAG and
# the workflow repins on next run (or trigger it manually).
#
# Upstream image: https://github.com/openclaw/openclaw/pkgs/container/openclaw

FROM ghcr.io/openclaw/openclaw@sha256:2ca86d6296fe2ae7111dac14843551340a4c5099e01566253b62c4d3e0a337fc

USER root

# Install gosu (~2 MB, single static binary) for reliable drop-privileges.
# bookworm-slim moved `runuser` into util-linux-extra and `su` argument-passing
# is fiddly across implementations; gosu is the standard container drop-priv
# tool. Pre-create the volume mount target so Railway volumes inherit
# node:node ownership when first mounted.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gosu && \
    rm -rf /var/lib/apt/lists/* && \
    install -d -m 0755 -o node -g node /data

# Entrypoint shim: chowns the mounted volume (root only), validates env if
# the operator provided a token, drops to the node user via gosu, and execs
# the upstream gateway with --bind lan --port $PORT.
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
