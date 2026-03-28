#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 9 - C.O.R.E Jupyter (jupyter.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) runtime directory provisioning
# 3) container runtime definition generation
# 4) explicit host port conflict checks
# 5) container activation + local health validation
# 6) TLS and ingress configuration validation
# 7) mesh DNS and runtime health validation

SERVICE_NAME="core-jupyter"
DOMAIN="jupyter.core"
INSTALL_DIR="/opt/core/jupyter"
WORK_DIR="${INSTALL_DIR}/workspace"
CONFIG_DIR="${INSTALL_DIR}/config"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

IMAGE_TAG="${IMAGE_TAG:-quay.io/jupyter/base-notebook:python-3.11}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-18888}"
CONTAINER_PORT="${CONTAINER_PORT:-8888}"
JUPYTER_LAB_ROOT_DIR="${JUPYTER_LAB_ROOT_DIR:-/home/jovyan/work}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-}"
JUPYTER_EXTRA_ARGS="${JUPYTER_EXTRA_ARGS:-}"
PUID="${PUID:-1000}"
PGID="${PGID:-100}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_jupyter"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
HTPASSWD_USER="${HTPASSWD_USER:-}"
COMPOSE_CMD=()
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"

log() {
  echo "[core-jupyter] $*"
}

fail() {
  echo "[core-jupyter] ERROR: $*" >&2
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
  local retries="${1:-40}"
  local delay="${2:-2}"
  local i

  for i in $(seq 1 "${retries}"); do
    if curl --silent --show-error --fail "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/api" >/dev/null; then
      return 0
    fi
    sleep "${delay}"
  done

  return 1
}

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  jupyter:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    environment:
      - TZ=${TZ:-UTC}
      - JUPYTER_TOKEN=${JUPYTER_TOKEN}
      - JUPYTER_ENABLE_LAB=yes
    command: >-
      start-notebook.py
      --ServerApp.ip=0.0.0.0
      --ServerApp.port=${CONTAINER_PORT}
      --ServerApp.root_dir=${JUPYTER_LAB_ROOT_DIR}
      --ServerApp.allow_remote_access=True
      --ServerApp.trust_xheaders=True
      --ServerApp.disable_check_xsrf=False
      ${JUPYTER_EXTRA_ARGS}
    volumes:
      - ${WORK_DIR}:${JUPYTER_LAB_ROOT_DIR}
      - ${CONFIG_DIR}:/home/jovyan/.jupyter
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:${CONTAINER_PORT}"
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
        proxy_send_timeout 3600;
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy        "same-origin" always;

    access_log /var/log/nginx/core-jupyter.access.log;
    error_log  /var/log/nginx/core-jupyter.error.log warn;
}
EOF
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk
require_cmd grep
require_cmd ss

ensure_numeric_port "${PUBLISHED_HTTP_PORT}"
ensure_numeric_port "${CONTAINER_PORT}"

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

log "[2/8] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${WORK_DIR}" "${CONFIG_DIR}"

if [ -f "${COMPOSE_FILE}" ]; then
  log "Stopping existing stack before conflict checks"
  "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
fi
sudo docker rm -f "${SERVICE_NAME}" >/dev/null 2>&1 || true

log "[3/8] Enforcing no-port-conflict policy"
# Single localhost binding keeps all Jupyter kernel ports internal to the container.
assert_host_port_available "${PUBLISHED_HTTP_PORT}"

log "[4/8] Writing container runtime definition"
write_compose_file

log "[5/8] Starting Jupyter container"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

wait_for_local_health 40 2 || fail "Jupyter local health check failed on http://127.0.0.1:${PUBLISHED_HTTP_PORT}/api"

log "[6/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-jupyter-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-jupyter-key.XXXXXX.pem)"
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

curl --silent --show-error --fail --insecure "https://${DOMAIN}/api" >/dev/null \
  || fail "Ingress health check failed for https://${DOMAIN}/api"

echo
log "Deployment complete and container runtime checks passed"
log "URL: https://${DOMAIN}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Compose stack: ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} ps"
