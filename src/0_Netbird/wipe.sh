#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 0 - C.O.R.E Netbird Wipe (netbird.core)

PURGE_PACKAGES="${PURGE_PACKAGES:-true}"
FORCE="${FORCE:-false}"
NETBIRD_STATUS_FILE="/tmp/core-netbird-status.txt"
NETBIRD_BIN=""

log() {
  echo "[core-netbird:wipe] $*"
}

stop_netbird_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  sudo systemctl stop netbird.service netbird-ui.service >/dev/null 2>&1 || true
  sudo systemctl disable netbird.service netbird-ui.service >/dev/null 2>&1 || true
  sudo systemctl reset-failed netbird.service netbird-ui.service >/dev/null 2>&1 || true
}

resolve_netbird_bin() {
  if command -v netbird >/dev/null 2>&1; then
    NETBIRD_BIN="$(command -v netbird)"
  elif [ -x "/snap/bin/netbird" ]; then
    NETBIRD_BIN="/snap/bin/netbird"
  else
    NETBIRD_BIN=""
  fi
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove Netbird enrollment artifacts and optionally purge installed packages."
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

log "Stopping Netbird runtime if present"
stop_netbird_services
resolve_netbird_bin
[ -n "${NETBIRD_BIN}" ] && sudo "${NETBIRD_BIN}" down >/dev/null 2>&1 || true

log "Removing repository and runtime artifacts"
sudo rm -f /etc/apt/sources.list.d/netbird.list
sudo rm -f /etc/apt/keyrings/netbird.gpg
sudo rm -f "${NETBIRD_STATUS_FILE}"
sudo rm -rf /etc/netbird /var/lib/netbird /var/log/netbird

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y netbird netbird-ui || true
  if command -v snap >/dev/null 2>&1 && sudo snap list netbird >/dev/null 2>&1; then
    sudo snap remove netbird || true
  fi
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"
