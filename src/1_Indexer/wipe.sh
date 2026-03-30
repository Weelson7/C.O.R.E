#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 1 - C.O.R.E Indexer Wipe (index.core)

DOMAIN="index.core"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/index.core.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/index.core.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/index.core"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/index.core"
WEB_ROOT="/var/www/core-indexer"
INSTALL_DIR="/opt/core/indexer"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
IMAGE_TAG="${IMAGE_TAG:-core/indexer:local}"
CONTAINER_NAME="core-indexer"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-true}"
COMPOSE_CMD=()

log() {
  echo "[core-indexer:wipe] $*"
}

resolve_compose_cmd() {
  log "Resolving Docker Compose command..."

  if ! command -v docker >/dev/null 2>&1; then
    log "Docker binary not found; cannot resolve Compose command"
    return 1
  fi

  if sudo docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker compose)
    log "Docker Compose v2 plugin resolved"
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker-compose)
    log "Legacy docker-compose binary resolved"
    return 0
  fi

  log "No Docker Compose implementation found"
  return 1
}

confirm() {
  log "Requesting wipe confirmation..."

  if [ "${FORCE}" = "true" ]; then
    log "FORCE=true; skipping interactive confirmation"
    return 0
  fi

  echo "This will remove Indexer artifacts, ingress config, container assets, and optional packages."
  read -r -p "Type WIPE to continue: " answer
  [ "${answer}" = "WIPE" ] || {
    log "Aborted by user"
    exit 1
  }

  log "Wipe confirmed by user"
}

ensure_ubuntu() {
  log "Ensuring operating system is Ubuntu..."
  [ -r /etc/os-release ] || {
    log "Cannot determine operating system"
    exit 1
  }

  log "Reading /etc/os-release for OS information"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || {
    log "This script is intended for Ubuntu hosts"
    exit 1
  }

  log "Operating system confirmed: Ubuntu"
}

confirm
ensure_ubuntu

log "Stopping container workload"
if command -v docker >/dev/null 2>&1; then
  log "Docker is available; proceeding with container teardown"

  if resolve_compose_cmd && [ -f "${COMPOSE_FILE}" ]; then
    log "Compose file found at ${COMPOSE_FILE}; running compose down"
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
    log "Compose stack torn down"
  else
    log "Compose file not found or Compose command unavailable; skipping compose down"
  fi

  log "Removing container: ${CONTAINER_NAME}"
  sudo docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  log "Removing image: ${IMAGE_TAG}"
  sudo docker image rm -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
  log "Container workload removed"

else
  log "Docker not found; skipping container teardown"
fi

log "Removing filesystem artifacts"
log "Removing install directory: ${INSTALL_DIR}"
log "Removing web root: ${WEB_ROOT}"
sudo rm -rf "${INSTALL_DIR}" "${WEB_ROOT}"

log "Removing htpasswd file: ${HTPASSWD_FILE}"
sudo rm -f "${HTPASSWD_FILE}"

log "Removing TLS certificate: ${NGINX_CERT_FILE}"
log "Removing TLS key: ${NGINX_KEY_FILE}"
sudo rm -f "${NGINX_CERT_FILE}" "${NGINX_KEY_FILE}"

log "Removing Nginx site config: ${NGINX_SITE_FILE}"
log "Removing Nginx site symlink: ${NGINX_SITE_LINK}"
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"

log "Removing Nginx access and error logs for ${DOMAIN}"
sudo rm -f /var/log/nginx/core-indexer.access.log /var/log/nginx/core-indexer.error.log
log "Filesystem artifacts removed"

if command -v mkcert >/dev/null 2>&1; then
  log "mkcert is available; uninstalling local CA"
  mkcert -uninstall >/dev/null 2>&1 || true
  log "mkcert local CA uninstalled"
else
  log "mkcert not found; skipping CA uninstall"
fi

if command -v nginx >/dev/null 2>&1; then
  log "Nginx is available; validating config and restarting service"
  sudo nginx -t >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || true
  log "Nginx restarted"
else
  log "Nginx not found; skipping config validation and service restart"
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y nginx mkcert apache2-utils curl ca-certificates rsync docker.io docker-compose-plugin || true
  sudo apt autoremove -y || true
  sudo apt clean || true
  log "Package purge complete"
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete for ${DOMAIN}"