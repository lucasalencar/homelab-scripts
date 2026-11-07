#!/bin/bash
# Runs inside the pulse LXC: pulls the Pulse image and recreates the container.
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[pulse-update] $*"; }

log "Pulling latest Pulse image..."
docker compose -f /opt/pulse/docker-compose.yml pull
docker compose -f /opt/pulse/docker-compose.yml up -d
docker image prune -f >/dev/null 2>&1 || true

log "Pulse updated."
docker compose -f /opt/pulse/docker-compose.yml ps
