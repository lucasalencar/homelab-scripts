#!/bin/bash
# Runs inside the pulse LXC: installs Docker and starts Pulse.
set -e
export DEBIAN_FRONTEND=noninteractive

PULSE_VERSION="${1:-latest}"

log() { echo "[pulse-install] $*"; }

log "Updating OS..."
apt update
apt upgrade -y
apt install -y ca-certificates curl gnupg

if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    codename=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release | tr -d '"')
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable" > /etc/apt/sources.list.d/docker.list
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
else
    log "Docker already installed — skipping"
fi

mkdir -p /opt/pulse
cat >/opt/pulse/docker-compose.yml <<EOF
services:
  pulse:
    image: rcourtman/pulse:${PULSE_VERSION}
    container_name: pulse
    restart: unless-stopped
    ports:
      - "7655:7655"
    volumes:
      - pulse_data:/data
    environment:
      PULSE_DEPLOYMENT_METHOD: docker_compose

volumes:
  pulse_data:
EOF

log "Starting Pulse ${PULSE_VERSION} on :7655..."
docker compose -f /opt/pulse/docker-compose.yml up -d
docker compose -f /opt/pulse/docker-compose.yml ps

log "Pulse running. Get the setup token with: docker exec pulse /app/pulse bootstrap-token"
