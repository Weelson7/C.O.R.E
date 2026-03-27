#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 0 - C.O.R.E Netbird Enrollment (netbird.core)

# Node enrollment contract alignment:
# 1) dependency installation
# 2) Netbird repository provisioning
# 3) agent installation
# 4) node registration with runtime setup key
# 5) connection status verification

NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
NETBIRD_MGMT_URL="${NETBIRD_MGMT_URL:-}"
NETBIRD_ADMIN_URL="${NETBIRD_ADMIN_URL:-}"
NETBIRD_IFACE_BLACKLIST="${NETBIRD_IFACE_BLACKLIST:-}"
NETBIRD_STATUS_FILE="/tmp/core-netbird-status.txt"

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
  if ! command -v netbird >/dev/null 2>&1; then
    return 1
  fi

  if sudo netbird status 2>/dev/null | grep -qiE 'connected|management:[[:space:]]*connected'; then
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
require_cmd curl
require_cmd gpg

log "[1/5] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg

log "[2/5] Provisioning Netbird package repository"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.netbird.io/ubuntu/public.key | sudo gpg --dearmor -o /etc/apt/keyrings/netbird.gpg
sudo chmod a+r /etc/apt/keyrings/netbird.gpg

echo \
  "deb [signed-by=/etc/apt/keyrings/netbird.gpg] https://pkgs.netbird.io/ubuntu stable main" \
  | sudo tee /etc/apt/sources.list.d/netbird.list >/dev/null

log "[3/5] Installing Netbird agent"
sudo apt update -y
sudo apt install -y netbird
require_cmd netbird

if is_netbird_connected; then
  log "Node is already connected to Netbird. Re-registering with provided setup key."
fi

log "[4/5] Registering node with Netbird network"
mapfile -t NB_UP_ARGS < <(build_up_args)
sudo netbird down >/dev/null 2>&1 || true
sudo netbird "${NB_UP_ARGS[@]}"

log "[5/5] Verifying Netbird runtime status"
sudo netbird status >"${NETBIRD_STATUS_FILE}" 2>/dev/null || fail "Netbird status check failed"
cat "${NETBIRD_STATUS_FILE}"

if ! grep -qiE 'connected|management:[[:space:]]*connected' "${NETBIRD_STATUS_FILE}"; then
  fail "Netbird is not connected after enrollment"
fi

echo
log "Deployment complete and node enrollment checks passed"
log "Runtime status: sudo netbird status"
log "Node debug output: sudo netbird status --detail"
