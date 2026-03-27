#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service x - C.O.R.E Supervisor (supervisor.core)

# Control-plane contract alignment:
# 1) dependency installation
# 2) supervisor artifact provisioning
# 3) runtime bootstrap and state validation
# 4) TLS material provisioning
# 5) ingress configuration validation
# 6) mesh DNS and runtime endpoint validation

SERVICE_NAME="core-supervisor"
DOMAIN="supervisor.core"
INSTALL_DIR="/opt/core/supervisor"
WEB_ROOT="${INSTALL_DIR}/web"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${INSTALL_DIR}/data"
BIN_DIR="${INSTALL_DIR}/bin"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
SUPERVISOR_UI_PORT="${SUPERVISOR_UI_PORT:-18080}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_supervisor"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"
IMAGE_TAG="${IMAGE_TAG:-nginx:1.27-alpine}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
HTPASSWD_USER="${HTPASSWD_USER:-}"
COMPOSE_CMD=()
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"

log() {
  echo "[core-supervisor] $*"
}

fail() {
  echo "[core-supervisor] ERROR: $*" >&2
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

write_nginx_site() {
  sudo tee "${NGINX_SITE_FILE}" >/dev/null <<EOF
server {
  listen ${NETBIRD_DEVICE_IP}:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
  listen ${NETBIRD_DEVICE_IP}:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${NGINX_CERT_FILE};
    ssl_certificate_key ${NGINX_KEY_FILE};

  auth_basic           "C.O.R.E. - restricted";
  auth_basic_user_file ${HTPASSWD_FILE};

  location / {
    proxy_pass         http://127.0.0.1:${SUPERVISOR_UI_PORT};
    proxy_http_version 1.1;
    proxy_set_header   Host              \$host;
    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
  }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;
    add_header Referrer-Policy        "no-referrer" always;

    access_log /var/log/nginx/core-supervisor.access.log;
    error_log  /var/log/nginx/core-supervisor.error.log warn;
}
EOF
}

prepare_web_root() {
  sudo mkdir -p "${WEB_ROOT}"

  [ -f "${INSTALL_DIR}/index.html" ] || fail "Missing index.html in ${INSTALL_DIR}"
  [ -f "${INSTALL_DIR}/style.css" ] || fail "Missing style.css in ${INSTALL_DIR}"
  [ -f "${INSTALL_DIR}/app.js" ] || fail "Missing app.js in ${INSTALL_DIR}"

  sudo cp -f "${INSTALL_DIR}/index.html" "${WEB_ROOT}/index.html"
  sudo cp -f "${INSTALL_DIR}/style.css" "${WEB_ROOT}/style.css"
  sudo cp -f "${INSTALL_DIR}/app.js" "${WEB_ROOT}/app.js"

  if [ -f "${INSTALL_DIR}/logo.png" ]; then
    sudo cp -f "${INSTALL_DIR}/logo.png" "${WEB_ROOT}/logo.png"
  fi

  sudo ln -sfn ../data "${WEB_ROOT}/data"
}

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  supervisor-ui:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    volumes:
      - ${WEB_ROOT}:/usr/share/nginx/html:ro
    ports:
      - "127.0.0.1:${SUPERVISOR_UI_PORT}:80"
EOF
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"
ensure_value HTPASSWD_USER "Enter HTTP Basic Auth username for ${DOMAIN}"
ensure_secret_value HTPASSWD_PASSWORD "Enter HTTP Basic Auth password for ${HTPASSWD_USER}"

log "[1/7] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert curl ca-certificates jq rsync dnsutils openssh-client apache2-utils
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd jq
require_cmd rsync
require_cmd curl
require_cmd ssh
require_cmd htpasswd
require_cmd docker
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/7] Provisioning supervisor artifacts at ${INSTALL_DIR}"
sudo mkdir -p "${INSTALL_DIR}"
sudo rsync -a --delete --exclude '.git' --exclude '.github' --exclude 'deploy.sh' --exclude 'wipe.sh' "${SCRIPT_DIR}/" "${INSTALL_DIR}/"
sudo chown -R root:root "${INSTALL_DIR}"
sudo find "${INSTALL_DIR}" -type d -exec chmod 755 {} \;
sudo find "${INSTALL_DIR}" -type f -exec chmod 644 {} \;
sudo chmod +x "${BIN_DIR}"/*.sh

sudo touch "${DATA_DIR}/events.log"
prepare_web_root

log "[3/7] Writing container runtime definition and starting service"
write_compose_file
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

curl --silent --show-error --fail "http://127.0.0.1:${SUPERVISOR_UI_PORT}/" >/dev/null || fail "Supervisor UI container health check failed"

log "[4/7] Bootstrapping supervisor runtime state"
sudo "${BIN_DIR}/supervisor.sh" init
sudo "${BIN_DIR}/supervisor.sh" status-json >/tmp/core-supervisor-status.json
jq -e '.supervisor.activeNodeId' /tmp/core-supervisor-status.json >/dev/null || fail "Supervisor status bootstrap validation failed"

log "[5/7] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-supervisor-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-supervisor-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[6/7] Enforcing ingress authentication and validating Nginx config"
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

log "[7/7] Validating mesh DNS and runtime endpoint"
require_cmd netbird
sudo netbird status >/dev/null 2>&1 || fail "Netbird is not connected; cannot validate mesh DNS contract"

resolved_ip="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)"
[ -n "${resolved_ip}" ] || fail "DNS lookup failed for ${DOMAIN}; configure AdGuard rewrite and Netbird nameserver group"
validate_resolved_ip "${resolved_ip}"

curl --silent --show-error --fail --insecure "https://${DOMAIN}/" >/dev/null || fail "Ingress health check failed for https://${DOMAIN}/"

echo
log "Deployment complete and supervisor runtime checks passed"
log "URL: https://${DOMAIN}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Supervisor CLI: sudo ${BIN_DIR}/supervisor.sh run-cycle --execute"
log "Nginx logs: sudo tail -n 50 /var/log/nginx/core-supervisor.error.log"
