#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 12 - C.O.R.E Seafile Wipe (seafile.core)

DOMAIN="seafile.core"
SERVICE_NAME="core-seafile"
INSTALL_DIR="/opt/core/seafile"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
IMAGE_TAG="${IMAGE_TAG:-seafileltd/seafile-mc:latest}"
IMAGE_TAG_DB="${IMAGE_TAG_DB:-mariadb:10.11}"
IMAGE_TAG_CACHE="${IMAGE_TAG_CACHE:-memcached:1.6.18}"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-false}"
COMPOSE_CMD=()

log() {
  echo "[core-seafile:wipe] $*"
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

  echo "This will remove Seafile runtime artifacts (containers, images, TLS, nginx config)."
  echo "MySQL data at ${INSTALL_DIR}/mysql and Seafile data at ${INSTALL_DIR}/data will also be removed."
  echo "If you want to preserve data, abort now and back up those directories first."
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

  log "Collecting container IDs matching Seafile stack containers..."
  mapfile -t container_ids < <(
    {
      sudo docker ps -aq --filter "name=^/${SERVICE_NAME}$"
      sudo docker ps -aq --filter "name=^/core-seafile-db$"
      sudo docker ps -aq --filter "name=^/core-seafile-memcached$"
      sudo docker ps -aq --filter "ancestor=${IMAGE_TAG}"
      sudo docker ps -aq --filter "ancestor=${IMAGE_TAG_DB}"
      sudo docker ps -aq --filter "ancestor=${IMAGE_TAG_CACHE}"
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

  log "Removing Docker images for Seafile stack..."
  sudo docker image rm -f "${IMAGE_TAG}" "${IMAGE_TAG_DB}" "${IMAGE_TAG_CACHE}" >/dev/null 2>&1 || true
  log "Docker images removed (or were not present)"

  log "Removing Docker network seafile-net (if present)..."
  sudo docker network rm seafile-net >/dev/null 2>&1 || true
  log "Docker network seafile-net removed (or was not present)"
else
  log "Docker binary not found; skipping container and image cleanup"
fi

log "Removing filesystem and ingress artifacts"

log "Removing install directory ${INSTALL_DIR} (includes data and MySQL)..."
sudo rm -rf "${INSTALL_DIR}"
log "Install directory removed"

log "Removing TLS certificate ${NGINX_CERT_FILE} and key ${NGINX_KEY_FILE}..."
sudo rm -f "${NGINX_CERT_FILE}" "${NGINX_KEY_FILE}"
log "TLS certificate and key removed (or were not present)"

log "Removing Nginx site file ${NGINX_SITE_FILE} and symlink ${NGINX_SITE_LINK}..."
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
log "Nginx site file and symlink removed (or were not present)"

log "Removing Nginx access and error logs for ${SERVICE_NAME}..."
sudo rm -f /var/log/nginx/core-seafile.access.log /var/log/nginx/core-seafile.error.log
log "Nginx log files removed (or were not present)"

if command -v mkcert >/dev/null 2>&1; then
  log "mkcert binary found; uninstalling mkcert root CA..."
  mkcert -uninstall >/dev/null 2>&1 || true
  log "mkcert root CA uninstalled (or was not present)"
else
  log "mkcert binary not found; skipping root CA uninstall"
fi

if command -v nginx >/dev/null 2>&1; then
  log "Nginx binary found; testing remaining Nginx configuration..."
  sudo nginx -t >/dev/null 2>&1 || true
  log "Nginx configuration test complete"

  log "Restarting Nginx to apply removed site configuration..."
  sudo systemctl restart nginx >/dev/null 2>&1 || true
  log "Nginx restarted"
else
  log "Nginx binary not found; skipping Nginx reload"
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y nginx mkcert curl ca-certificates docker.io docker-compose-plugin || true
  log "apt purge complete"
  sudo apt autoremove -y || true
  log "apt autoremove complete"
  sudo apt clean || true
  log "apt clean complete"
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"