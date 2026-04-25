#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 14 - C.O.R.E Music Assistant (music.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) runtime directory provisioning
# 3) container runtime definition generation
# 4) container activation + local health validation
# 5) TLS and ingress configuration validation
# 6) mesh DNS and runtime health validation

SERVICE_NAME="core-music-assistant"
DOMAIN="music.core"
INSTALL_DIR="/opt/core/music-assistant"
DATA_DIR="${INSTALL_DIR}/data"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

IMAGE_TAG="${IMAGE_TAG:-ghcr.io/music-assistant/server:stable}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-18095}"
CONTAINER_PORT="${CONTAINER_PORT:-8095}"
MUSIC_LIBRARY_PATH="${MUSIC_LIBRARY_PATH:-/srv/media/music}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core"
HTPASSWD_USER="${HTPASSWD_USER:-}"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
COMPOSE_CMD=()
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_DELAY_SECONDS="${HEALTH_DELAY_SECONDS:-2}"

log() {
  echo "[core-music-assistant] $*"
}

fail() {
  echo "[core-music-assistant] ERROR: $*" >&2
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

ensure_numeric_port() {
  local port="$1"
  if ! printf '%s' "${port}" | grep -Eq '^[0-9]+$'; then
    fail "Invalid port value: ${port}"
  fi
  if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    fail "Port out of range (1-65535): ${port}"
  fi
}

is_port_listening_tcp() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

assert_host_port_available() {
  local port="$1"
  if is_port_listening_tcp "${port}"; then
    fail "Port conflict detected: tcp/${port} is already in use. Set PUBLISHED_HTTP_PORT to a free port and rerun."
  fi
}

ensure_music_library_path() {
  local path="$1"
  if [ ! -d "${path}" ]; then
    sudo mkdir -p "${path}"
  fi
  if [ ! -r "${path}" ]; then
    fail "MUSIC_LIBRARY_PATH is not readable: ${path}"
  fi
}

write_compose_file() {
  local target="$1"

  sudo tee "${target}" >/dev/null <<EOF
services:
  music-assistant:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    environment:
      - TZ=\${TZ:-UTC}
      - LOG_LEVEL=info
      - MUSIC_ASSISTANT_SERVER_ID=core-music-assistant
    volumes:
      - ${DATA_DIR}:/data
      - ${MUSIC_LIBRARY_PATH}:/media/music:ro
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:${CONTAINER_PORT}"
EOF
}

write_nginx_site() {
  local target="$1"

  sudo tee "${target}" >/dev/null <<EOF
server {
  listen 80;
  server_name ${DOMAIN};
  return 301 https://\$server_name\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate ${NGINX_CERT_FILE};
  ssl_certificate_key ${NGINX_KEY_FILE};
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  auth_basic "C.O.R.E Music Assistant";
  auth_basic_user_file ${HTPASSWD_FILE};

  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;

  access_log /var/log/nginx/core-music-assistant.access.log;
  error_log /var/log/nginx/core-music-assistant.error.log;

  location / {
    proxy_pass http://127.0.0.1:${PUBLISHED_HTTP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300;
    proxy_redirect off;
  }
}
EOF
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
  local retries="${1:-30}"
  local delay="${2:-2}"
  local i

  for i in $(seq 1 "${retries}"); do
    if curl --silent --show-error --fail "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" >/dev/null; then
      return 0
    fi
    sleep "${delay}"
  done

  return 1
}

wait_for_ingress_health() {
  local retries="${1:-30}"
  local delay="${2:-2}"
  local i

  for i in $(seq 1 "${retries}"); do
    if curl --silent --show-error --fail --insecure \
      -u "${HTPASSWD_USER}:${HTPASSWD_PASSWORD}" \
      "https://${DOMAIN}/" >/dev/null; then
      return 0
    fi
    sleep "${delay}"
  done

  return 1
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk
require_cmd ss

ensure_numeric_port "${PUBLISHED_HTTP_PORT}"
ensure_numeric_port "${CONTAINER_PORT}"
assert_host_port_available "${PUBLISHED_HTTP_PORT}"
ensure_music_library_path "${MUSIC_LIBRARY_PATH}"

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"
ensure_value HTPASSWD_USER "Enter HTTP Basic Auth username for ${DOMAIN}"
ensure_secret_value HTPASSWD_PASSWORD "Enter HTTP Basic Auth password for ${HTPASSWD_USER}"

log "[1/8] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert apache2-utils curl ca-certificates iproute2
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
require_cmd htpasswd
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-music-assistant-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-music-assistant-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[3/8] Preparing runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${DATA_DIR}"
sudo chown -R root:root "${INSTALL_DIR}"

log "[4/8] Writing container runtime definition"
write_compose_file "${COMPOSE_FILE}"

log "[5/8] Creating ingress auth credentials"
if [ -f "${HTPASSWD_FILE}" ]; then
  sudo htpasswd -b "${HTPASSWD_FILE}" "${HTPASSWD_USER}" "${HTPASSWD_PASSWORD}"
else
  sudo htpasswd -c -b "${HTPASSWD_FILE}" "${HTPASSWD_USER}" "${HTPASSWD_PASSWORD}"
fi
sudo chmod 640 "${HTPASSWD_FILE}"

log "[6/8] Configuring Nginx ingress for ${DOMAIN}"
write_nginx_site "${NGINX_SITE_FILE}"
sudo ln -sf "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t || fail "Nginx configuration validation failed"
sudo systemctl restart nginx

log "[7/8] Starting container workload"
cd "${INSTALL_DIR}"
"${COMPOSE_CMD[@]}" pull || true
"${COMPOSE_CMD[@]}" up -d || fail "Docker compose up failed"

if ! wait_for_local_health "${HEALTH_RETRIES}" "${HEALTH_DELAY_SECONDS}"; then
  log "Local health check failed. Checking logs:"
  sudo docker logs "${SERVICE_NAME}" || true
  fail "Container did not become healthy within timeout"
fi

log "[8/8] Validating mesh and ingress contract"
sudo systemctl is-active netbird >/dev/null 2>&1 || fail "Netbird is not running"

resolved_ip="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -1)"
[ -n "${resolved_ip}" ] || fail "DNS resolution failed for ${DOMAIN}"
validate_resolved_ip "${resolved_ip}"

if ! wait_for_ingress_health "${HEALTH_RETRIES}" "${HEALTH_DELAY_SECONDS}"; then
  log "Ingress health check failed. Checking logs:"
  sudo docker logs "${SERVICE_NAME}" || true
  sudo tail -20 /var/log/nginx/core-music-assistant.error.log || true
  fail "Ingress endpoint did not become healthy within timeout"
fi

log "Deployment complete"
log "Service is now accessible at https://${DOMAIN}/"
log "Username: ${HTPASSWD_USER}"
