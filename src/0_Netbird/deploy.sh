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
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
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

install_netbird() {
  if sudo apt install -y netbird; then
    return 0
  fi

  log "Apt package 'netbird' unavailable; falling back to snap"
  if ! command -v snap >/dev/null 2>&1; then
    sudo apt install -y snapd
  fi

  sudo snap install netbird
}

ensure_ubuntu() {
  [ -r /etc/os-release ] || fail "Cannot determine operating system (/etc/os-release missing)"

  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || fail "This script is intended for Ubuntu hosts (detected: ${ID:-unknown})"
}

ensure_value() {
  local var_name="$1"
  local prompt="$2"
  local is_secret="${3:-false}"
  local current_value="${!var_name:-}"

  while [ -z "${current_value}" ]; do
    if [ "${is_secret}" = "true" ]; then
      read -r -s -p "${prompt}: " current_value
      echo
    else
      read -r -p "${prompt}: " current_value
    fi
  done

  printf -v "${var_name}" '%s' "${current_value}"
}

is_netbird_connected() {
  resolve_netbird_bin
  if [ -z "${NETBIRD_BIN}" ]; then
    return 1
  fi

  if sudo "${NETBIRD_BIN}" status 2>/dev/null | grep -qiE 'connected|management:[[:space:]]*connected'; then
    return 0
  fi

  return 1
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

log "[2/4] Installing Netbird agent"
install_netbird
resolve_netbird_bin
[ -n "${NETBIRD_BIN}" ] || fail "Netbird installed but binary was not found"

if is_netbird_connected; then
  log "Node is already connected to Netbird. Re-registering with provided setup key."
fi

log "[3/4] Registering node with Netbird network"
mapfile -t NB_UP_ARGS < <(build_up_args)
sudo "${NETBIRD_BIN}" down >/dev/null 2>&1 || true
sudo "${NETBIRD_BIN}" "${NB_UP_ARGS[@]}"

log "[4/4] Verifying Netbird runtime status"
sudo "${NETBIRD_BIN}" status >"${NETBIRD_STATUS_FILE}" 2>/dev/null || fail "Netbird status check failed"
cat "${NETBIRD_STATUS_FILE}"

if ! grep -qiE 'connected|management:[[:space:]]*connected' "${NETBIRD_STATUS_FILE}"; then
  fail "Netbird is not connected after enrollment"
fi

echo
log "Deployment complete and node enrollment checks passed"
log "Runtime status: sudo ${NETBIRD_BIN} status"
log "Node debug output: sudo ${NETBIRD_BIN} status --detail"
