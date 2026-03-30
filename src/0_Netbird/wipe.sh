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

fail() {
  echo "[core-netbird:wipe] ERROR: $*" >&2
  exit 1
}

stop_netbird_services() {
  log "Checking for systemctl availability..."
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not available; skipping service teardown"
    return 0
  fi

  log "Stopping Netbird systemd services..."
  sudo systemctl stop netbird.service netbird-ui.service >/dev/null 2>&1 || true
  log "Netbird systemd services stopped"

  log "Disabling Netbird systemd services..."
  sudo systemctl disable netbird.service netbird-ui.service >/dev/null 2>&1 || true
  log "Netbird systemd services disabled"

  log "Resetting failed state for Netbird systemd services..."
  sudo systemctl reset-failed netbird.service netbird-ui.service >/dev/null 2>&1 || true
  log "Netbird systemd service failed state reset"
}

resolve_netbird_bin() {
  log "Resolving Netbird binary path..."

  if command -v netbird >/dev/null 2>&1; then
    NETBIRD_BIN="$(command -v netbird)"
    log "Netbird binary resolved to ${NETBIRD_BIN}"

  elif [ -x "/snap/bin/netbird" ]; then
    NETBIRD_BIN="/snap/bin/netbird"
    log "Netbird binary resolved to ${NETBIRD_BIN}"

  else
    NETBIRD_BIN=""
    log "Netbird binary not found in known locations; skipping agent-level teardown"
  fi
}

confirm() {
  log "Checking confirmation requirements..."

  if [ "${FORCE}" = "true" ]; then
    log "FORCE=true; skipping confirmation prompt"
    return 0
  fi

  log "Prompting user for wipe confirmation..."
  echo "This will remove Netbird enrollment artifacts and optionally purge installed packages."
  read -r -p "Type WIPE to continue: " answer

  [ "${answer}" = "WIPE" ] || {
    log "Aborted by user"
    exit 1
  }

  log "User confirmed wipe"
}

ensure_ubuntu() {
  log "Ensuring operating system is Ubuntu..."
  [ -r /etc/os-release ] || fail "Cannot determine operating system (/etc/os-release missing)"

  log "Reading /etc/os-release for OS information"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || fail "This script is intended for Ubuntu hosts (detected: ${ID:-unknown})"

  log "Operating system confirmed: ${PRETTY_NAME:-ubuntu}"
}

confirm
ensure_ubuntu

log "Stopping Netbird runtime if present"
stop_netbird_services

log "Resolving Netbird binary for agent-level teardown"
resolve_netbird_bin

if [ -n "${NETBIRD_BIN}" ]; then
  log "Bringing Netbird agent down via ${NETBIRD_BIN}..."
  sudo "${NETBIRD_BIN}" down >/dev/null 2>&1 || true
  log "Netbird agent brought down"
else
  log "No Netbird binary found; skipping agent down"
fi

log "Removing apt repository artifacts..."
sudo rm -f /etc/apt/sources.list.d/netbird.list
log "Removed /etc/apt/sources.list.d/netbird.list"

sudo rm -f /etc/apt/keyrings/netbird.gpg
log "Removed /etc/apt/keyrings/netbird.gpg"

log "Removing Netbird runtime status file..."
sudo rm -f "${NETBIRD_STATUS_FILE}"
log "Removed ${NETBIRD_STATUS_FILE}"

log "Removing Netbird configuration and data directories..."
sudo rm -rf /etc/netbird /var/lib/netbird /var/log/netbird
log "Removed /etc/netbird, /var/lib/netbird, /var/log/netbird"

if [ "${PURGE_PACKAGES}" = "true" ]; then

  log "Purging Netbird apt packages..."
  sudo apt purge -y netbird netbird-ui || true
  log "Netbird apt packages purged"

  if command -v snap >/dev/null 2>&1; then
    log "Checking if Netbird snap package is installed..."

    if sudo snap list netbird >/dev/null 2>&1; then
      log "Netbird snap package found; removing..."
      sudo snap remove netbird || true
      log "Netbird snap package removed"

    else
      log "Netbird snap package not installed; skipping snap removal"
    fi

  else
    log "Snap not available; skipping snap removal"
  fi

  log "Running apt autoremove..."
  sudo apt autoremove -y || true
  log "Apt autoremove complete"

  log "Running apt clean..."
  sudo apt clean || true
  log "Apt clean complete"

else
  log "Skipping package purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Netbird wipe complete"