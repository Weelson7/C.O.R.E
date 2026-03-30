#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 7 - C.O.R.E ttyd Wipe (ttyd.core)

DOMAIN="ttyd.core"
SERVICE_NAME="core-ttyd"
INSTALL_DIR="/opt/core/ttyd"
SYSTEMD_UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_ttyd"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-false}"

log() {
  echo "[core-ttyd:wipe] $*"
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove ttyd runtime artifacts, ingress config, and optionally purge installed packages."
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

log "Stopping ttyd runtime"
sudo systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
sudo systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
sudo systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
sudo rm -f "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"

if [ -f "${SYSTEMD_UNIT_FILE}" ]; then
  sudo rm -f "${SYSTEMD_UNIT_FILE}"
fi
sudo systemctl daemon-reload

log "Removing filesystem and ingress artifacts"
sudo rm -rf "${INSTALL_DIR}"
sudo rm -f "${NGINX_CERT_FILE}" "${NGINX_KEY_FILE}"
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f "${HTPASSWD_FILE}"
sudo rm -f /var/log/nginx/core-ttyd.access.log /var/log/nginx/core-ttyd.error.log

if command -v mkcert >/dev/null 2>&1; then
  mkcert -uninstall >/dev/null 2>&1 || true
fi

if command -v nginx >/dev/null 2>&1; then
  sudo nginx -t >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || true
fi

if command -v snap >/dev/null 2>&1 && sudo snap list ttyd >/dev/null 2>&1; then
  log "Removing snap package ttyd"
  sudo snap remove ttyd --purge >/dev/null 2>&1 || sudo snap remove ttyd >/dev/null 2>&1 || true
  sudo rm -rf /var/snap/ttyd
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y nginx mkcert apache2-utils curl ca-certificates snapd || true
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"
