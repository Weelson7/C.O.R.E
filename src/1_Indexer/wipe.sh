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

log() {
  echo "[core-indexer:wipe] $*"
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove Indexer artifacts, ingress config, container assets, and optional packages."
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
  sudo docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  sudo docker image rm -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
fi

log "Removing filesystem artifacts"
sudo rm -rf "${INSTALL_DIR}" "${WEB_ROOT}"
sudo rm -f "${HTPASSWD_FILE}"
sudo rm -f "${NGINX_CERT_FILE}" "${NGINX_KEY_FILE}"
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f /var/log/nginx/core-indexer.access.log /var/log/nginx/core-indexer.error.log

if command -v mkcert >/dev/null 2>&1; then
  mkcert -uninstall >/dev/null 2>&1 || true
fi

if command -v nginx >/dev/null 2>&1; then
  sudo nginx -t >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || true
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y nginx mkcert apache2-utils curl ca-certificates rsync docker.io docker-compose-plugin || true
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete for ${DOMAIN}"
