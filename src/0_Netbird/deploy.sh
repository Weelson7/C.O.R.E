#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 0 - C.O.R.E Netbird Enrollment (netbird.core)

# Node enrollment contract alignment:
# 1) dependency installation
# 2) agent installation
# 3) node registration with runtime setup key
# 4) connection status verification

NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
NETBIRD_MGMT_URL="${NETBIRD_MGMT_URL:-}"
NETBIRD_ADMIN_URL="${NETBIRD_ADMIN_URL:-}"
NETBIRD_IFACE_BLACKLIST="${NETBIRD_IFACE_BLACKLIST:-}"
NETBIRD_STATUS_FILE="/tmp/core-netbird-status.txt"
NETBIRD_BIN=""

log() {
  echo "[core-netbird] $*"
}

fail() {
  echo "[core-netbird] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  log "Checking for required command: $1"
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

resolve_netbird_bin() {
  log "Resolving Netbird binary path"

  if command -v netbird >/dev/null 2>&1; then
    NETBIRD_BIN="$(command -v netbird)"
    log "Netbird binary resolved to ${NETBIRD_BIN}"

  elif [ -x "/snap/bin/netbird" ]; then
    NETBIRD_BIN="/snap/bin/netbird"
    log "Netbird binary resolved to ${NETBIRD_BIN}"

  else
    NETBIRD_BIN=""
    fail "Netbird binary not found in known locations"
  fi
}

install_netbird() {
  log "Installing Netbird agent..."

  if sudo apt install -y netbird; then
    log "Netbird installed via apt"
    return 0
  fi

  log "Apt package 'netbird' unavailable; falling back to snap"

  if ! command -v snap >/dev/null 2>&1; then
    log "Snap is not installed, installing snapd..."
    sudo apt install -y snapd
    sudo systemctl enable --now snapd.socket
    sudo systemctl enable --now snapd
    log "Snap installed successfully"
  fi

  log "Installing Netbird via snap..."
  sudo snap install netbird
  log "Netbird installed via snap"
}

ensure_ubuntu() {
  log "Ensuring operating system is Ubuntu..."
  [ -r /etc/os-release ] || fail "Cannot determine operating system (/etc/os-release missing)"

  log "Reading /etc/os-release for OS information"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || fail "This script is intended for Ubuntu hosts (detected: ${ID:-unknown})"
}

ensure_value() {
  log "Ensuring required value for ${1}"
  local var_name="$1"
  local prompt="$2"
  local is_secret="${3:-false}"
  local current_value="${!var_name:-}"

  while [ -z "${current_value}" ]; do
    log "Value for ${var_name} is required but not set"

    if [ "${is_secret}" = "true" ]; then
      log "Prompting for ${var_name} (input will be hidden)"
      read -r -s -p "${prompt}: " current_value
      log "Value for ${var_name} received (hidden)"
      echo

    else
      log "Prompting for ${var_name}"
      read -r -p "${prompt}: " current_value
      log "Value for ${var_name} received: ${current_value}"
    fi

  done

  log "Value for ${var_name} is set"
  printf -v "${var_name}" '%s' "${current_value}"
}

is_netbird_connected() {
  log "Checking if Netbird is currently connected..."

  resolve_netbird_bin || {
    log "Netbird binary not found; assuming not connected"
    return 1
  }

  if sudo "${NETBIRD_BIN}" status 2>/dev/null | grep -qiE 'connected|management:[[:space:]]*connected'; then
    log "Netbird is currently connected"
    return 0
  fi

  log "Netbird is not connected, an unattended error occurred, or the status output format is unexpected"
  return 1
}

cleanup_existing_netbird_runtime() {
  log "Attempting to clean up existing Netbird runtime before re-enrollment..."

  if command -v systemctl >/dev/null 2>&1; then
    log "Stopping Netbird systemd services if running..."
    sudo systemctl stop netbird.service netbird-ui.service >/dev/null 2>&1 || true
    log "Stopped Netbird systemd services that were running"
  fi

  resolve_netbird_bin
  if [ -n "${NETBIRD_BIN}" ]; then
    log "Stopping Netbird agent..."
    sudo "${NETBIRD_BIN}" down >/dev/null 2>&1 || true
    log "Netbird agent stopped"
  fi

  log "Removing existing Netbird status file if it exists..."
  rm -f "${NETBIRD_STATUS_FILE}"
  log "Existing Netbird runtime cleanup complete"
}

build_up_args() {
  local args=(up --setup-key "${NETBIRD_SETUP_KEY}")

  if [ -n "${NETBIRD_MGMT_URL}" ]; then
    args+=(--management-url "${NETBIRD_MGMT_URL}")
  fi

  if [ -n "${NETBIRD_ADMIN_URL}" ]; then
    args+=(--admin-url "${NETBIRD_ADMIN_URL}")
  fi

  if [ -n "${NETBIRD_IFACE_BLACKLIST}" ]; then
    args+=(--interface-blacklist "${NETBIRD_IFACE_BLACKLIST}")
  fi

  printf '%s\n' "${args[@]}"
}

ensure_value NETBIRD_SETUP_KEY "Enter NETBIRD_SETUP_KEY for node enrollment" true

ensure_ubuntu
require_cmd sudo
require_cmd apt

log "[1/4] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y ca-certificates
log "Deployment dependencies installed"

log "[2/4] Installing Netbird agent"
install_netbird
resolve_netbird_bin

if is_netbird_connected; then
  log "Node is already connected to Netbird. Re-registering with provided setup key."
else
  log "Node is not currently connected to Netbird. Proceeding with enrollment."
fi

log "[3/4] Registering node with Netbird network"
mapfile -t NB_UP_ARGS < <(build_up_args)
cleanup_existing_netbird_runtime

sudo "${NETBIRD_BIN}" "${NB_UP_ARGS[@]}"
log "Netbird enrollment executed"

log "[4/4] Verifying Netbird runtime status"
sudo "${NETBIRD_BIN}" status >"${NETBIRD_STATUS_FILE}" 2>/dev/null || fail "Netbird status check failed"
cat "${NETBIRD_STATUS_FILE}"

if ! grep -qiE 'connected|management:[[:space:]]*connected' "${NETBIRD_STATUS_FILE}"; then
  fail "Netbird is not connected after enrollment"
fi
log "Netbird enrollment successful and node is connected"

echo
log "Deployment complete and node enrollment checks passed"
log "Runtime status: sudo ${NETBIRD_BIN} status"
log "Node debug output: sudo ${NETBIRD_BIN} status --detail"