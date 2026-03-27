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

IMAGE_TAG="${IMAGE_TAG:-ghcr.io/suwayomi/suwayomi-server:latest}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-4567}"
TACHIYOMI_EXTENSION_URL="${TACHIYOMI_EXTENSION_URL:-}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_suwayomi"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
HTPASSWD_USER="${HTPASSWD_USER:-}"
COMPOSE_CMD=()

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

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker-compose)
    return 0
  fi

  fail "No Docker Compose command available after installation"
}

install_container_stack() {
  if sudo apt install -y docker.io docker-compose-plugin; then
    return 0
  fi

  log "Package docker-compose-plugin unavailable; falling back to docker-compose"
  sudo apt install -y docker.io docker-compose
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

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  suwayomi:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    environment:
      - TZ=${TZ:-UTC}
      - BIND_IP=0.0.0.0
      - BIND_PORT=4567
      - WEB_UI_ENABLED=true
      - EXTENSION_REPOS=${EXTENSION_REPOS:-https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json}
    volumes:
      - ${DATA_DIR}:/home/suwayomi/.local/share/Tachidesk
      - ${DOWNLOADS_DIR}:/home/suwayomi/.local/share/Tachidesk/downloads
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:4567"
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

    auth_basic           "C.O.R.E. - restricted";
    auth_basic_user_file ${HTPASSWD_FILE};

    location / {
        proxy_pass         http://127.0.0.1:${PUBLISHED_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_read_timeout 3600;
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;
    add_header Referrer-Policy        "same-origin" always;

    access_log /var/log/nginx/core-suwayomi.access.log;
    error_log  /var/log/nginx/core-suwayomi.error.log warn;
}
EOF
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
ensure_value HTPASSWD_USER "Enter HTTP Basic Auth username for ${DOMAIN}"
ensure_secret_value HTPASSWD_PASSWORD "Enter HTTP Basic Auth password for ${HTPASSWD_USER}"

log "[1/8] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert apache2-utils curl ca-certificates
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
require_cmd htpasswd
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/8] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${DOWNLOADS_DIR}" "${EXTENSIONS_DIR}"

log "[3/8] Writing container runtime definition"
write_compose_file

log "[4/8] Starting Suwayomi container"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

wait_for_local_health 30 2 || fail "Suwayomi local health check failed"

log "[5/8] Bootstrapping Tachiyomi extension settings"
bootstrap_tachiyomi_extension

log "[6/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-suwayomi-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-suwayomi-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[7/8] Writing and validating Nginx ingress for ${DOMAIN}"
if [ ! -f "${HTPASSWD_FILE}" ]; then
  printf '%s\n' "${HTPASSWD_PASSWORD}" | sudo htpasswd -i -c "${HTPASSWD_FILE}" "${HTPASSWD_USER}"
else
  printf '%s\n' "${HTPASSWD_PASSWORD}" | sudo htpasswd -i "${HTPASSWD_FILE}" "${HTPASSWD_USER}"
fi
sudo chmod 640 "${HTPASSWD_FILE}"

write_nginx_site

sudo ln -sf "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

log "[8/8] Validating mesh DNS and ingress runtime"
require_cmd netbird
sudo netbird status >/dev/null 2>&1 || fail "Netbird is not connected; cannot validate mesh DNS contract"

resolved_ip="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)"
[ -n "${resolved_ip}" ] || fail "DNS lookup failed for ${DOMAIN}; configure AdGuard rewrite and Netbird nameserver group"
validate_resolved_ip "${resolved_ip}"

curl --silent --show-error --fail --insecure "https://${DOMAIN}/" >/dev/null \
  || fail "Ingress health check failed for https://${DOMAIN}/"

echo
log "Deployment complete and container runtime checks passed"
log "URL: https://${DOMAIN}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Compose stack: ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} ps"
