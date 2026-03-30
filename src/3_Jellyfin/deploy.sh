#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 3 - C.O.R.E Jellyfin (jellyfin.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) runtime directory provisioning
# 3) container runtime definition generation
# 4) container activation
# 5) TLS material provisioning
# 6) centralized ingress authentication
# 7) ingress configuration validation
# 8) mesh DNS and runtime health validation

SERVICE_NAME="core-jellyfin"
DOMAIN="jellyfin.core"
INSTALL_DIR="/opt/core/jellyfin"
CONFIG_DIR="${INSTALL_DIR}/config"
CACHE_DIR="${INSTALL_DIR}/cache"
MEDIA_DIR="${MEDIA_DIR:-/srv/media}"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

IMAGE_TAG="${IMAGE_TAG:-jellyfin/jellyfin:latest}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-8096}"

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
  echo "[core-jellyfin] $*"
}

fail() {
  echo "[core-jellyfin] ERROR: $*" >&2
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

ensure_secret_value() {
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"

  while [ -z "${current_value}" ]; do
    read -r -s -p "${prompt}: " current_value
    echo
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

wait_for_local_jellyfin_health() {
  local retries="${1:-30}"
  local delay_seconds="${2:-1}"
  local i
  local endpoint
  local status_code

  for i in $(seq 1 "${retries}"); do
    for endpoint in "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" "http://localhost:${PUBLISHED_HTTP_PORT}/"; do
      status_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "${endpoint}" 2>/dev/null || true)"
      case "${status_code}" in
        200|301|302|401|403)
          return 0
          ;;
      esac
    done
    sleep "${delay_seconds}"
  done

  return 1
}

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  jellyfin:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    environment:
      - TZ=${TZ:-UTC}
      - JELLYFIN_PublishedServerUrl=https://${DOMAIN}
    volumes:
      - ${CONFIG_DIR}:/config
      - ${CACHE_DIR}:/cache
      - ${MEDIA_DIR}:/media:ro
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:8096"
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

    client_max_body_size 20G;

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

    access_log /var/log/nginx/core-jellyfin.access.log;
    error_log  /var/log/nginx/core-jellyfin.error.log warn;
}
EOF
}

cleanup_previous_runtime() {
  local ids=()
  local id

  if [ -f "${COMPOSE_FILE}" ]; then
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
  fi

  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    ids+=("${id}")
  done < <(sudo docker ps -aq --filter "name=^/${SERVICE_NAME}$")

  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    ids+=("${id}")
  done < <(sudo docker ps -aq --filter "ancestor=${IMAGE_TAG}")

  if [ "${#ids[@]}" -gt 0 ]; then
    mapfile -t ids < <(printf '%s\n' "${ids[@]}" | awk '!seen[$1]++')
    log "Removing existing Jellyfin container workload (${#ids[@]} container(s))"
    sudo docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
  fi
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"

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
sudo mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}" "${CACHE_DIR}" "${MEDIA_DIR}"

log "[3/8] Writing container runtime definition"
write_compose_file

log "[4/8] Starting Jellyfin container"
cleanup_previous_runtime

"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

log "[5/8] Verifying local Jellyfin health"
if ! wait_for_local_jellyfin_health 45 1; then
  log "Jellyfin local health check did not pass in time; dumping diagnostics"
  sudo ss -lntp | grep -E "(:${PUBLISHED_HTTP_PORT}[[:space:]]|:${PUBLISHED_HTTP_PORT}$)" || true
  sudo docker logs "${SERVICE_NAME}" | tail -20 || true
  fail "Jellyfin local health check failed"
fi

log "[6/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-jellyfin-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-jellyfin-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[7/8] Writing and validating Nginx ingress for ${DOMAIN}"
write_nginx_site
sudo ln -sfn "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo nginx -t
sudo systemctl restart nginx

log "[8/8] Verifying mesh DNS and ingress runtime health"
resolved_ip="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -n1)"
[ -n "${resolved_ip}" ] || fail "DNS resolution failed for ${DOMAIN}"
validate_resolved_ip "${resolved_ip}"

log "Testing ingress at https://${DOMAIN}/"
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
log "Deployment complete"
log "Container status: sudo docker ps -f name=${SERVICE_NAME}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Nginx error log: sudo tail -50 /var/log/nginx/core-jellyfin.error.log"
log "Ingress check: curl -k https://${DOMAIN}/"
