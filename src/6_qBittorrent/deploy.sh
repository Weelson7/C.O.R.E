#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 6 - C.O.R.E qBittorrent (qbittorrent-nox WebUI, qbittorrent.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) runtime directory provisioning
# 3) container runtime definition generation
# 4) container activation + local health validation
# 5) TLS material provisioning
# 6) ingress configuration validation
# 7) mesh DNS and runtime health validation

SERVICE_NAME="core-qbittorrent"
DOMAIN="qbittorrent.core"
INSTALL_DIR="/opt/core/qbittorrent"
CONFIG_DIR="${INSTALL_DIR}/config"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-/downloads}"
INCOMPLETE_DIR="${DOWNLOADS_DIR}/incomplete"
WATCH_DIR="${DOWNLOADS_DIR}/watch"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

IMAGE_TAG="${IMAGE_TAG:-lscr.io/linuxserver/qbittorrent:latest}"
WEBUI_RUNTIME="${WEBUI_RUNTIME:-qbittorrent-nox}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-18081}"
CONTAINER_WEBUI_PORT="${CONTAINER_WEBUI_PORT:-8080}"
PUBLISHED_TORRENT_TCP_PORT="${PUBLISHED_TORRENT_TCP_PORT:-6881}"
PUBLISHED_TORRENT_UDP_PORT="${PUBLISHED_TORRENT_UDP_PORT:-6881}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
TZ="${TZ:-UTC}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
COMPOSE_CMD=()
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"

log() {
  echo "[core-qbittorrent] $*"
}

fail() {
  echo "[core-qbittorrent] ERROR: $*" >&2
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
  local current_value="${!var_name:-}"

  while [ -z "${current_value}" ]; do
    read -r -p "${prompt}: " current_value
  done

  printf -v "${var_name}" '%s' "${current_value}"
}

resolve_compose_cmd() {
  if sudo docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker compose)
    return 0
  fi

  fail "Docker Compose v2 plugin is not available after installation"
}

install_compose_plugin_manually() {
  local arch
  local plugin_arch
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  local plugin_path="${plugin_dir}/docker-compose"
  local plugin_url=""

  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) plugin_arch="x86_64" ;;
    aarch64|arm64) plugin_arch="aarch64" ;;
    *) fail "Unsupported architecture for compose plugin fallback: ${arch}" ;;
  esac

  plugin_url="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_PLUGIN_VERSION}/docker-compose-linux-${plugin_arch}"

  sudo mkdir -p "${plugin_dir}"
  sudo curl -fsSL "${plugin_url}" -o "${plugin_path}"
  sudo chmod +x "${plugin_path}"
}

install_container_stack() {
  if sudo apt install -y docker.io docker-compose-plugin; then
    return 0
  fi

  log "Package docker-compose-plugin unavailable; installing Docker Compose plugin manually"
  sudo apt install -y docker.io
  install_compose_plugin_manually
}

validate_resolved_ip() {
  local resolved_ip="$1"

  if [ "${resolved_ip}" = "${NETBIRD_DEVICE_IP}" ]; then
    return 0
  fi

  if [ -n "${NETBIRD_FAILOVER_IP}" ] && [ "${resolved_ip}" = "${NETBIRD_FAILOVER_IP}" ]; then
    log "DNS currently resolves to configured failover IP (${NETBIRD_FAILOVER_IP})"
    return 0
  fi

  if [ -n "${NETBIRD_FAILOVER_IP}" ]; then
    fail "DNS mismatch for ${DOMAIN}: expected ${NETBIRD_DEVICE_IP} or ${NETBIRD_FAILOVER_IP}, got ${resolved_ip}"
  fi

  fail "DNS mismatch for ${DOMAIN}: expected ${NETBIRD_DEVICE_IP}, got ${resolved_ip}"
}

wait_for_local_health() {
  local retries="${1:-60}"
  local delay="${2:-2}"
  local i
  local status_code

  for i in $(seq 1 "${retries}"); do
    status_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" 2>/dev/null || true)"
    case "${status_code}" in
      200|301|302|401|403)
        return 0
        ;;
    esac
    sleep "${delay}"
  done

  return 1
}

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  qbittorrent:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    labels:
      - core.webui=qbittorrent
      - core.webui.runtime=${WEBUI_RUNTIME}
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - WEBUI_PORT=${CONTAINER_WEBUI_PORT}
    volumes:
      - ${CONFIG_DIR}:/config
      - ${DOWNLOADS_DIR}:/downloads
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:${CONTAINER_WEBUI_PORT}"
      - "${PUBLISHED_TORRENT_TCP_PORT}:6881/tcp"
      - "${PUBLISHED_TORRENT_UDP_PORT}:6881/udp"
    network_mode: bridge
EOF
}

write_nginx_site() {
  sudo tee "${NGINX_SITE_FILE}" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${NGINX_CERT_FILE};
    ssl_certificate_key ${NGINX_KEY_FILE};

    location / {
        proxy_pass         http://127.0.0.1:${PUBLISHED_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_buffering    off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy        "same-origin" always;

    access_log /var/log/nginx/core-qbittorrent.access.log;
    error_log  /var/log/nginx/core-qbittorrent.error.log warn;
}
EOF
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"

case "${WEBUI_RUNTIME}" in
  qbittorrent|qbittorrent-nox) ;;
  *) fail "WEBUI_RUNTIME must be either qbittorrent or qbittorrent-nox (got: ${WEBUI_RUNTIME})" ;;
esac

log "[1/8] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert curl ca-certificates
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/8] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}" "${DOWNLOADS_DIR}" "${INCOMPLETE_DIR}" "${WATCH_DIR}"
sudo chown -R "${PUID}:${PGID}" "${CONFIG_DIR}"

log "[3/8] Writing container runtime definition"
write_compose_file

if [ -f "${COMPOSE_FILE}" ]; then
  log "Stopping any existing stack before recreate"
  "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
fi
sudo docker rm -f "${SERVICE_NAME}" >/dev/null 2>&1 || true

log "[4/8] Starting qBittorrent container"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate --pull always

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

wait_for_local_health 60 2 || fail "qBittorrent local health check failed on http://127.0.0.1:${PUBLISHED_HTTP_PORT}/"

log "[5/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-qbittorrent-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-qbittorrent-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[6/8] Writing and validating Nginx ingress for ${DOMAIN}"
write_nginx_site

sudo ln -sf "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

log "[7/8] Validating mesh DNS contract"
require_cmd netbird
sudo netbird status >/dev/null 2>&1 || fail "Netbird is not connected; cannot validate mesh DNS contract"

resolved_ip="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)"
[ -n "${resolved_ip}" ] || fail "DNS lookup failed for ${DOMAIN}; configure AdGuard rewrite and Netbird nameserver group"
validate_resolved_ip "${resolved_ip}"

log "[8/8] Validating ingress runtime"
ingress_response="$(curl --silent --show-error --insecure -w "\nHTTP_CODE:%{http_code}" \
  --resolve "${DOMAIN}:443:${NETBIRD_DEVICE_IP}" \
  "https://${DOMAIN}/" 2>&1)" || true

echo "${ingress_response}"

http_code="$(echo "${ingress_response}" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)"
case "${http_code}" in
  200|301|302|401|403)
    log "Ingress check passed with HTTP ${http_code}"
    ;;
  *)
    fail "Ingress health check failed on https://${DOMAIN}/ (HTTP ${http_code})"
    ;;
esac

echo
log "Deployment complete and container runtime checks passed"
log "URL: https://${DOMAIN}"
log "WebUI runtime profile: ${WEBUI_RUNTIME}"
log "First-run WebUI credentials are managed by qBittorrent. If needed, check logs for the temporary password:"
log "sudo docker logs ${SERVICE_NAME} | grep -i password"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Compose stack: ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} ps"
