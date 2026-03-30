#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 4 - C.O.R.E Suwayomi (suwayomi.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) runtime directory provisioning
# 3) container runtime definition generation
# 4) container activation + local health validation
# 5) Tachiyomi extension bootstrap
# 6) TLS and ingress configuration validation
# 7) mesh DNS and runtime health validation

SERVICE_NAME="core-suwayomi"
DOMAIN="suwayomi.core"
INSTALL_DIR="/opt/core/suwayomi"
DATA_DIR="${INSTALL_DIR}/data"
DOWNLOADS_DIR="${INSTALL_DIR}/downloads"
EXTENSIONS_DIR="${DATA_DIR}/extensions"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

IMAGE_TAG="${IMAGE_TAG:-ghcr.io/suwayomi/suwayomi-server:preview}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-4567}"
TACHIYOMI_EXTENSION_URL="${TACHIYOMI_EXTENSION_URL:-}"

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
  echo "[core-suwayomi] $*"
}

fail() {
  echo "[core-suwayomi] ERROR: $*" >&2
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

wait_for_local_health() {
  local retries="${1:-60}"
  local delay="${2:-3}"
  local i

  for i in $(seq 1 "${retries}"); do
    if curl --silent --show-error --fail "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" >/dev/null 2>&1; then
      log "Container health check passed on attempt ${i}"
      return 0
    fi
    log "Health check attempt ${i}/${retries} - waiting ${delay}s before retry..."
    sleep "${delay}"
  done

  log "Container health check failed after ${retries} attempts (${retries} * ${delay}s = $(( retries * delay ))s)"
  log "Container logs:"
  sudo docker logs "${SERVICE_NAME}" --tail 30
  return 1
}

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  suwayomi:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    environment:
      TZ: UTC
    volumes:
      - ${DATA_DIR}:/home/suwayomi/.local/share/Tachidesk
      - ${DOWNLOADS_DIR}:/home/suwayomi/.local/share/Tachidesk/downloads
      - ${EXTENSIONS_DIR}:/home/suwayomi/.local/share/Tachidesk/extensions
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:4567"
    network_mode: bridge
EOF
}

write_server_conf() {
  sudo mkdir -p "${DATA_DIR}"
  sudo tee "${DATA_DIR}/server.conf" >/dev/null <<EOF
server {
  port = 4567
  socketTimeout = 60000
  downloadAsCbz = false
  ehentaiCookieDownload = false

  webUI {
    enabled = true
    initialOpenInBrowserEnabled = false
  }

  proxy {
    enabled = false
  }
}
EOF
  sudo chown 1000:1000 "${DATA_DIR}/server.conf"
  sudo chmod 644 "${DATA_DIR}/server.conf"
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

    access_log /var/log/nginx/core-suwayomi.access.log;
    error_log  /var/log/nginx/core-suwayomi.error.log warn;
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
    log "Removing existing Suwayomi container workload (${#ids[@]} container(s))"
    sudo docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
  fi
}

bootstrap_tachiyomi_extension() {
  local tmp_apk=""
  local extension_url_path=""
  local extension_name=""

  if [ -z "${TACHIYOMI_EXTENSION_URL}" ]; then
    log "No TACHIYOMI_EXTENSION_URL provided; extension package bootstrap is skipped"
    return 0
  fi

  extension_url_path="${TACHIYOMI_EXTENSION_URL%%\?*}"
  extension_url_path="${extension_url_path%%\#*}"
  extension_name="$(basename "${extension_url_path}")"

  case "${extension_name}" in
    *.[aA][pP][kK]) ;;
    *) fail "TACHIYOMI_EXTENSION_URL must point to an .apk file" ;;
  esac

  log "Bootstrapping Tachiyomi extension from ${TACHIYOMI_EXTENSION_URL}"
  tmp_apk="$(mktemp /tmp/core-suwayomi-extension.XXXXXX.apk)"

  curl --silent --show-error --fail --location "${TACHIYOMI_EXTENSION_URL}" -o "${tmp_apk}"

  sudo mkdir -p "${EXTENSIONS_DIR}"
  sudo mv -f "${tmp_apk}" "${EXTENSIONS_DIR}/${extension_name}"
  sudo chmod 644 "${EXTENSIONS_DIR}/${extension_name}"
  # Ensure container user (UID 1000) can access extensions
  sudo chown -R 1000:1000 "${EXTENSIONS_DIR}"

  sudo docker restart "${SERVICE_NAME}" >/dev/null
  wait_for_local_health 30 2 || fail "Suwayomi did not become healthy after extension bootstrap restart"

  log "Extension package staged at ${EXTENSIONS_DIR}/${extension_name}"
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk
require_cmd grep

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"

log "[1/9] Installing deployment dependencies"
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

log "[2/9] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${DOWNLOADS_DIR}" "${EXTENSIONS_DIR}"
# Suwayomi container runs as non-root user (UID 1000), directories must be writable
sudo chown -R 1000:1000 "${DATA_DIR}" "${DOWNLOADS_DIR}"

log "[3/9] Writing container runtime definition"
write_compose_file
write_server_conf

log "[4/9] Cleaning up existing Suwayomi runtime"
cleanup_previous_runtime

log "[5/9] Starting Suwayomi container (fresh)"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate --pull always

# Wait a moment for container to initialize
sleep 5

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
if [ "${container_state}" != "running" ]; then
  log "Container is not running. Checking for errors..."
  sudo docker logs "${SERVICE_NAME}" --tail 50 2>&1 || true
  fail "Container ${SERVICE_NAME} is not running (state: ${container_state:-not found})"
fi

log "Container ${SERVICE_NAME} is running, waiting for application startup..."
log "Note: Suwayomi is a Java application and may take 30-60 seconds to fully start"

wait_for_local_health 60 3 || fail "Suwayomi local health check failed"

log "[6/9] Bootstrapping Tachiyomi extension settings"
bootstrap_tachiyomi_extension

log "[7/9] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-suwayomi-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-suwayomi-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[8/9] Writing and validating Nginx ingress for ${DOMAIN}"
write_nginx_site

sudo ln -sf "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

log "[9/9] Validating mesh DNS and ingress runtime"
require_cmd netbird
sudo netbird status >/dev/null 2>&1 || fail "Netbird is not connected; cannot validate mesh DNS contract"

resolved_ip="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)"
[ -n "${resolved_ip}" ] || fail "DNS lookup failed for ${DOMAIN}; configure AdGuard rewrite and Netbird nameserver group"
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
log "Deployment complete and container runtime checks passed"
log "URL: https://${DOMAIN}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Compose stack: ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} ps"
