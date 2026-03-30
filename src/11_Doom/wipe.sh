#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Extra 4 - DOOM WASM Wipe (doom.zenith.su)

DOMAIN="doom.zenith.su"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_SITE_FILE="/etc/nginx/sites-available/doom.zenith.su"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/doom.zenith.su"
WEB_ROOT="/var/www/doom"
EMSDK_DIR="/opt/emsdk"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-true}"

log() {
  echo "[doom-wipe] $*"
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove DOOM deployment artifacts and optionally purge installed packages."
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

log "Removing deployed web artifacts"
sudo rm -rf "${WEB_ROOT}"

log "Removing emsdk artifacts used by local server build"
sudo rm -rf "${EMSDK_DIR}"

log "Removing nginx ingress and TLS artifacts"
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f "${NGINX_SSL_DIR}/doom.crt" "${NGINX_SSL_DIR}/doom.key"
sudo rm -f /var/log/nginx/doom.access.log /var/log/nginx/doom.error.log

if command -v mkcert >/dev/null 2>&1; then
  mkcert -uninstall >/dev/null 2>&1 || true
fi

if command -v nginx >/dev/null 2>&1; then
  sudo nginx -t >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || true
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y \
    nginx mkcert nginx-extras curl ca-certificates git wget \
    build-essential make automake autoconf libtool pkg-config \
    python3 xz-utils || true
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete for ${DOMAIN}"
