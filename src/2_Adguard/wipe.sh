#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 2 - C.O.R.E AdGuard Home Wipe (dns.core)

SERVICE_NAME="core-adguard"
IMAGE_TAG="core/adguard:local"
INSTALL_DIR="/opt/core/adguard"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-true}"
COMPOSE_CMD=()

log() {
  echo "[core-adguard:wipe] $*"
}

resolve_compose_cmd() {
  log "Resolving Docker Compose command..."

  if ! command -v docker >/dev/null 2>&1; then
    log "Docker binary not found; cannot resolve compose command"
    return 1
  fi

  if sudo docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker compose)
    log "Docker Compose v2 plugin resolved via 'docker compose'"
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker-compose)
    log "Docker Compose resolved via standalone 'docker-compose' binary"
    return 0
  fi

  log "No Docker Compose variant found"
  return 1
}

confirm() {
  log "Requesting confirmation before proceeding with wipe..."

  if [ "${FORCE}" = "true" ]; then
    log "FORCE=true; skipping interactive confirmation"
    return 0
  fi

  echo "This will remove AdGuard runtime artifacts and optionally purge installed packages."
  read -r -p "Type WIPE to continue: " answer
  [ "${answer}" = "WIPE" ] || {
    log "Aborted by user"
    exit 1
  }

  log "User confirmed wipe"
}

ensure_ubuntu() {
  log "Ensuring operating system is Ubuntu..."
  [ -r /etc/os-release ] || {
    log "Cannot determine operating system (/etc/os-release missing)"
    exit 1
  }

  log "Reading /etc/os-release for OS information"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || {
    log "This script is intended for Ubuntu hosts (detected: ${ID:-unknown})"
    exit 1
  }

  log "Operating system confirmed as Ubuntu"
}

confirm
ensure_ubuntu

log "Stopping container workload"

if command -v docker >/dev/null 2>&1; then
  log "Docker binary found; proceeding with container cleanup"

  if resolve_compose_cmd && [ -f "${COMPOSE_FILE}" ]; then
    log "Compose file found at ${COMPOSE_FILE}; tearing down existing stack"
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
    log "Compose stack torn down"
  else
    log "No compose file found at ${COMPOSE_FILE} or compose command unavailable; skipping stack teardown"
  fi

  log "Collecting container IDs matching name /${SERVICE_NAME} and ancestor image ${IMAGE_TAG}..."
  mapfile -t container_ids < <(
    {
      sudo docker ps -aq --filter "name=^/${SERVICE_NAME}$"
      sudo docker ps -aq --filter "ancestor=${IMAGE_TAG}"
    } | awk 'NF && !seen[$1]++'
  )
  log "Collected ${#container_ids[@]} unique container ID(s) for removal"

  if [ "${#container_ids[@]}" -gt 0 ]; then
    log "Force-removing ${#container_ids[@]} container(s)"
    sudo docker rm -f "${container_ids[@]}" >/dev/null 2>&1 || true
    log "Containers removed"
  else
    log "No matching containers found; nothing to remove"
  fi

  log "Removing Docker image ${IMAGE_TAG}..."
  sudo docker image rm -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
  log "Docker image ${IMAGE_TAG} removed (or was not present)"
else
  log "Docker binary not found; skipping container and image cleanup"
fi

log "Removing filesystem artifacts at ${INSTALL_DIR}"
sudo rm -rf "${INSTALL_DIR}"
log "Filesystem artifacts removed"

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y ca-certificates curl tar docker.io docker-compose-plugin dnsutils || true
  log "apt purge complete"
  sudo apt autoremove -y || true
  log "apt autoremove complete"
  sudo apt clean || true
  log "apt clean complete"
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"