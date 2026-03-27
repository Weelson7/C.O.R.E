#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: x_Supervisor Wipe

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
DATA_DIR="${ROOT_DIR}/data"
DOMAIN="supervisor.core"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_supervisor"
INSTALL_DIR="/opt/core/supervisor"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-true}"

log() {
  echo "[x-supervisor:wipe] $*"
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove supervisor runtime artifacts and optional package dependencies."
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

log "Stopping supervisor containers/images if present"
if command -v docker >/dev/null 2>&1; then
  sudo docker rm -f core-supervisor >/dev/null 2>&1 || true
  sudo docker image rm -f core/supervisor:local >/dev/null 2>&1 || true
  sudo docker image rm -f core-supervisor:latest >/dev/null 2>&1 || true
fi

log "Removing generated runtime files"
sudo rm -f "${DATA_DIR}/events.log"
sudo rm -f /tmp/core-supervisor-status.json
sudo rm -rf "${INSTALL_DIR}" /var/backups/core

log "Removing ingress and TLS artifacts"
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f "${NGINX_CERT_FILE}" "${NGINX_KEY_FILE}"
sudo rm -f "${HTPASSWD_FILE}"
sudo rm -f /var/log/nginx/core-supervisor.access.log /var/log/nginx/core-supervisor.error.log

if command -v mkcert >/dev/null 2>&1; then
  mkcert -uninstall >/dev/null 2>&1 || true
fi

if command -v nginx >/dev/null 2>&1; then
  sudo nginx -t >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || true
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y nginx mkcert curl ca-certificates jq rsync dnsutils openssh-client docker.io docker-compose-plugin apache2-utils || true
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"
