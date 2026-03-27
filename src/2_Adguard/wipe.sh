#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 2 - C.O.R.E AdGuard Home Wipe (dns.core)

SERVICE_NAME="core-adguard"
IMAGE_TAG="core/adguard:local"
INSTALL_DIR="/opt/core/adguard"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-true}"

log() {
  echo "[core-adguard:wipe] $*"
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove AdGuard runtime artifacts and optionally purge installed packages."
  read -r -p "Type WIPE to continue: " answer
  [ "${answer}" = "WIPE" ] || {
    log "Aborted by user"
    exit 1
  }
}

ensure_ubuntu() {
  [ -r /etc/os-release ] || {
    log "Cannot determine operating system"
    exit 1
  }

  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || {
    log "This script is intended for Ubuntu hosts"
    exit 1
  }
}

confirm
ensure_ubuntu

log "Stopping container workload"
if command -v docker >/dev/null 2>&1; then
  if [ -f "${COMPOSE_FILE}" ]; then
    sudo docker compose -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
  fi
  sudo docker rm -f "${SERVICE_NAME}" >/dev/null 2>&1 || true
  sudo docker image rm -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
fi

log "Removing filesystem artifacts"
sudo rm -rf "${INSTALL_DIR}"

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y ca-certificates curl tar docker.io docker-compose-plugin dnsutils || true
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"
