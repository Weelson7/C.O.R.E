#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 25 - C.O.R.E Minecraft (NeoForge 1.21.1)

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_JAR="${SERVICE_DIR}/neoforge-21.1.228-server.jar"

log() {
  echo "[core-minecraft] $*"
}

fail() {
  echo "[core-minecraft] ERROR: $*" >&2
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

install_runtime_deps() {
  sudo apt update
  sudo apt install -y openjdk-21-jre-headless unzip curl ca-certificates
}

prepare_layout() {
  mkdir -p "${SERVICE_DIR}/mods"
  mkdir -p "${SERVICE_DIR}/config"
  mkdir -p "${SERVICE_DIR}/defaultconfigs"

  [ -f "${SERVICE_DIR}/eula.txt" ] || printf 'eula=true\n' > "${SERVICE_DIR}/eula.txt"

  if [ -f "${SERVICE_DIR}/server.properties" ]; then
    if ! grep -q '^view-distance=' "${SERVICE_DIR}/server.properties"; then
      printf '\nview-distance=8\n' >> "${SERVICE_DIR}/server.properties"
    fi
    if ! grep -q '^simulation-distance=' "${SERVICE_DIR}/server.properties"; then
      printf 'simulation-distance=6\n' >> "${SERVICE_DIR}/server.properties"
    fi
  else
    cat > "${SERVICE_DIR}/server.properties" <<'EOF'
view-distance=8
simulation-distance=6
EOF
  fi

  chmod +x "${SERVICE_DIR}/run.sh"
}

validate_payload() {
  [ -f "${SERVER_JAR}" ] || fail "Missing ${SERVER_JAR}. Download the NeoForge 1.21.1 server jar before running."

  if command -v netbird >/dev/null 2>&1; then
    if ! netbird status >/dev/null 2>&1; then
      log "Netbird CLI is installed but reports disconnected state."
      log "Continue setup, then connect Netbird before production launch."
    fi
  else
    log "Netbird CLI not found on this host. Install and connect Netbird for mesh exposure."
  fi
}

ensure_ubuntu
require_cmd sudo
install_runtime_deps
prepare_layout
validate_payload

log "Setup complete."
log "Next steps:"
log "1) Ensure neoforge-21.1.228-server.jar is present in ${SERVICE_DIR}."
log "2) Start server with: ./run.sh"
