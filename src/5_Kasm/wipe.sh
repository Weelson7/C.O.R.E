#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 5 - C.O.R.E Kasm Wipe (kasm.core)

DOMAIN="kasm.core"
INSTALL_DIR="/opt/core/kasm"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
KASM_INSTALL_DIR="/opt/kasm"
KASM_COMPOSE_FILE="${KASM_INSTALL_DIR}/current/docker/docker-compose.yaml"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_kasm"
FORCE="${FORCE:-false}"
PURGE_PACKAGES="${PURGE_PACKAGES:-false}"
COMPOSE_CMD=()

log() {
  echo "[core-kasm:wipe] $*"
}

resolve_compose_cmd() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  if sudo docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker compose)
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker-compose)
    return 0
  fi

  return 1
}

confirm() {
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi

  echo "This will remove Kasm runtime artifacts, ingress config, and optionally purge installed packages."
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

if [ -x "${KASM_INSTALL_DIR}/bin/stop" ]; then
  log "Stopping Kasm services via official stop script"
  sudo "${KASM_INSTALL_DIR}/bin/stop" >/dev/null 2>&1 || true
fi

if command -v docker >/dev/null 2>&1; then
  if resolve_compose_cmd; then
    if [ -f "${KASM_COMPOSE_FILE}" ]; then
      "${COMPOSE_CMD[@]}" -f "${KASM_COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
    fi
    if [ -f "${COMPOSE_FILE}" ]; then
      "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
    fi
  fi

  mapfile -t kasm_container_ids < <(sudo docker ps -aq --filter "name=^kasmweb_")
  if [ "${#kasm_container_ids[@]}" -gt 0 ]; then
    sudo docker rm -f "${kasm_container_ids[@]}" >/dev/null 2>&1 || true
  fi

  mapfile -t kasm_networks < <(sudo docker network ls --format '{{.Name}}' | awk '/^kasmweb_/' )
  if [ "${#kasm_networks[@]}" -gt 0 ]; then
    sudo docker network rm "${kasm_networks[@]}" >/dev/null 2>&1 || true
  fi

  mapfile -t kasm_volumes < <(sudo docker volume ls --format '{{.Name}}' | awk '/^kasmweb_/' )
  if [ "${#kasm_volumes[@]}" -gt 0 ]; then
    sudo docker volume rm "${kasm_volumes[@]}" >/dev/null 2>&1 || true
  fi
fi

log "Removing filesystem and ingress artifacts"
sudo rm -rf "${INSTALL_DIR}" "${KASM_INSTALL_DIR}"
sudo rm -f "${NGINX_CERT_FILE}" "${NGINX_KEY_FILE}"
sudo rm -f "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f "${HTPASSWD_FILE}"
sudo rm -f /var/log/nginx/core-kasm.access.log /var/log/nginx/core-kasm.error.log

if command -v mkcert >/dev/null 2>&1; then
  mkcert -uninstall >/dev/null 2>&1 || true
fi

if command -v nginx >/dev/null 2>&1; then
  sudo nginx -t >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || true
fi

if [ "${PURGE_PACKAGES}" = "true" ]; then
  log "Purging packages installed by deploy.sh"
  sudo apt purge -y nginx mkcert apache2-utils curl ca-certificates docker.io docker-compose-plugin iproute2 || true
  sudo apt autoremove -y || true
  sudo apt clean || true
else
  log "Skipping apt purge because PURGE_PACKAGES=${PURGE_PACKAGES}"
fi

log "Wipe complete"
