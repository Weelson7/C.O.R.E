#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 1 - C.O.R.E Indexer (index.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) TLS material provisioning
# 3) container activation
# 4) ingress configuration validation
# 5) DNS resolution verification
# 6) runtime health confirmation

DOMAIN="index.core"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/index.core.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/index.core.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/index.core"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/index.core"
WEB_ROOT="/var/www/core-indexer"
API_PORT="${API_PORT:-5001}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_SOURCE_DIR="${API_SOURCE_DIR:-${SCRIPT_DIR}}"
API_ENTRYPOINT="${API_ENTRYPOINT:-${API_SOURCE_DIR}/app.py}"
API_ENTRYPOINT_BASENAME="$(basename "${API_ENTRYPOINT}")"
INSTALL_DIR="/opt/core/indexer"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
DOCKERFILE_PATH="${INSTALL_DIR}/Dockerfile"
IMAGE_TAG="${IMAGE_TAG:-core/indexer:local}"
CONTAINER_NAME="core-indexer"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
STRICT_DNS_VALIDATION="${STRICT_DNS_VALIDATION:-false}"
COMPOSE_CMD=()
API_HEALTH_RETRIES="${API_HEALTH_RETRIES:-30}"
API_HEALTH_DELAY_SECONDS="${API_HEALTH_DELAY_SECONDS:-2}"
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"

log() {
  echo "[core-indexer] $*"
}

fail() {
  echo "[core-indexer] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  log "Checking for required command: $1"
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
  log "Required command found: $1"
}

ensure_ubuntu() {
  log "Ensuring operating system is Ubuntu..."
  [ -r /etc/os-release ] || fail "Cannot determine operating system (/etc/os-release missing)"

  log "Reading /etc/os-release for OS information"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || fail "This script is intended for Ubuntu hosts (detected: ${ID:-unknown})"
  log "Operating system confirmed: Ubuntu"
}

ensure_value() {
  log "Ensuring required value for ${1}"
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"

  while [ -z "${current_value}" ]; do
    log "Value for ${var_name} is required but not set"
    log "Prompting for ${var_name}"
    read -r -p "${prompt}: " current_value
    log "Value for ${var_name} received: ${current_value}"
  done

  log "Value for ${var_name} is set"
  printf -v "${var_name}" '%s' "${current_value}"
}

ensure_secret_value() {
  log "Ensuring required secret value for ${1}"
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"

  while [ -z "${current_value}" ]; do
    log "Value for ${var_name} is required but not set"
    log "Prompting for ${var_name} (input will be hidden)"
    read -r -s -p "${prompt}: " current_value
    echo
    log "Value for ${var_name} received (hidden)"
  done

  log "Value for ${var_name} is set"
  printf -v "${var_name}" '%s' "${current_value}"
}

resolve_compose_cmd() {
  log "Resolving Docker Compose v2 plugin..."

  if sudo docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker compose)
    log "Docker Compose v2 plugin resolved"
    return 0
  fi

  fail "Docker Compose v2 plugin is not available after installation"
}

remove_existing_indexer_containers() {
  log "Scanning for existing Indexer containers to remove..."
  local ids=()
  local id

  log "Searching by container name: ${CONTAINER_NAME}"
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    ids+=("${id}")
  done < <(sudo docker ps -aq --filter "name=^/${CONTAINER_NAME}$")

  log "Searching by image ancestor: ${IMAGE_TAG}"
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    ids+=("${id}")
  done < <(sudo docker ps -aq --filter "ancestor=${IMAGE_TAG}")

  if [ "${#ids[@]}" -gt 0 ]; then
    mapfile -t ids < <(printf '%s\n' "${ids[@]}" | awk '!seen[$1]++')
    log "Removing existing Indexer container workload (${#ids[@]} container(s))"
    sudo docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
    log "Existing Indexer containers removed"

  else
    log "No existing Indexer containers found"
  fi
}

install_compose_plugin_manually() {
  log "Installing Docker Compose plugin manually..."
  local arch
  local plugin_arch
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  local plugin_path="${plugin_dir}/docker-compose"
  local plugin_url=""

  arch="$(uname -m)"
  log "Detected host architecture: ${arch}"
  case "${arch}" in
    x86_64|amd64) plugin_arch="x86_64" ;;
    aarch64|arm64) plugin_arch="aarch64" ;;
    *) fail "Unsupported architecture for compose plugin fallback: ${arch}" ;;
  esac

  plugin_url="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_PLUGIN_VERSION}/docker-compose-linux-${plugin_arch}"
  log "Compose plugin download URL: ${plugin_url}"

  sudo mkdir -p "${plugin_dir}"
  log "Downloading Docker Compose plugin to ${plugin_path}"
  sudo curl -fsSL "${plugin_url}" -o "${plugin_path}"
  sudo chmod +x "${plugin_path}"
  log "Docker Compose plugin installed manually at ${plugin_path}"
}

install_container_stack() {
  log "Installing container stack (docker.io + docker-compose-plugin)..."

  if sudo apt install -y docker.io docker-compose-plugin; then
    log "Container stack installed via apt"
    return 0
  fi

  log "Package docker-compose-plugin unavailable; installing Docker Compose plugin manually"
  sudo apt install -y docker.io
  install_compose_plugin_manually
  log "Container stack installation complete"
}

write_fallback_api() {
  log "Writing fallback API entrypoint to ${1}"
  local target="$1"

  cat <<'PY' | sudo tee "${target}" >/dev/null
from flask import Flask, jsonify

app = Flask(__name__)


@app.get('/api/sites')
def sites():
  # Fallback endpoint used when no project-specific API source exists.
  return jsonify([])


@app.get('/health')
def health():
  return jsonify({'status': 'ok'})


if __name__ == '__main__':
  from os import getenv

  port = int(getenv('PORT', '5001'))
  app.run(host='0.0.0.0', port=port)
PY

  log "Fallback API entrypoint written to ${target}"
}

write_frontend_assets() {
  log "Writing frontend assets to ${WEB_ROOT}..."
  local required_assets=(index.html style.css logic.js)
  local asset

  sudo mkdir -p "${WEB_ROOT}"
  log "Web root directory ensured: ${WEB_ROOT}"

  for asset in "${required_assets[@]}"; do
    [ -f "${SCRIPT_DIR}/${asset}" ] || fail "Missing frontend asset: ${SCRIPT_DIR}/${asset}"
    sudo cp -f "${SCRIPT_DIR}/${asset}" "${WEB_ROOT}/${asset}"
    log "Copied frontend asset: ${asset}"
  done

  if [ -f "${SCRIPT_DIR}/logo.png" ]; then
    sudo cp -f "${SCRIPT_DIR}/logo.png" "${WEB_ROOT}/logo.png"
    log "Copied optional logo asset: logo.png"
  else
    log "Optional logo asset not found at ${SCRIPT_DIR}/logo.png; skipping"
  fi

  sudo chown -R root:root "${WEB_ROOT}"
  sudo chmod -R 755 "${WEB_ROOT}"
  log "Frontend asset permissions set on ${WEB_ROOT}"
}

validate_resolved_ip_list() {
  log "Validating resolved IPs for ${DOMAIN} against expected mesh IP(s)..."
  local resolved_ips="$1"
  local ip
  local found="false"

  while IFS= read -r ip; do
    [ -n "${ip}" ] || continue
    log "Checking resolved IP: ${ip}"
    if [ "${ip}" = "${NETBIRD_DEVICE_IP}" ]; then
      log "Resolved IP matches primary Netbird device IP: ${ip}"
      found="true"
      break
    fi
    if [ -n "${NETBIRD_FAILOVER_IP}" ] && [ "${ip}" = "${NETBIRD_FAILOVER_IP}" ]; then
      log "Resolved IP matches Netbird failover IP: ${ip}"
      found="true"
      break
    fi
  done <<EOF
${resolved_ips}
EOF

  [ "${found}" = "true" ] || fail "DNS mismatch for ${DOMAIN}: none of the resolved IPs match expected mesh IP(s). Resolved: ${resolved_ips//$'\n'/, }"
  log "DNS validation passed for ${DOMAIN}"
}

wait_for_ingress_api_health() {
  log "Waiting for ingress API health at https://${DOMAIN}/api/sites (mode: ${3}, retries: ${1}, delay: ${2}s)..."
  local retries="$1"
  local delay="$2"
  local mode="$3"
  local i

  for i in $(seq 1 "${retries}"); do
    log "Ingress API health attempt ${i}/${retries} (mode: ${mode})"

    if [ "${mode}" = "dns" ]; then

      if curl --silent --show-error --fail --insecure \
        -u "${HTPASSWD_USER}:${HTPASSWD_PASSWORD}" \
        "https://${DOMAIN}/api/sites" >/dev/null; then
        log "Ingress API is healthy via DNS on attempt ${i}"
        return 0
      fi

    else
      if curl --silent --show-error --fail --insecure \
        -u "${HTPASSWD_USER}:${HTPASSWD_PASSWORD}" \
        --resolve "${DOMAIN}:443:${NETBIRD_DEVICE_IP}" \
        "https://${DOMAIN}/api/sites" >/dev/null; then
        log "Ingress API is healthy via IP resolve on attempt ${i}"
        return 0
      fi
    fi

    log "Ingress API not yet healthy; retrying in ${delay}s"
    sleep "${delay}"

  done

  log "Ingress API did not become healthy within ${retries} attempts"
  return 1
}

wait_for_ingress_api_health_dns_only() {
  log "Waiting for ingress API reachability via system DNS (retries: ${1}, delay: ${2}s)..."
  local retries="$1"
  local delay="$2"
  local i

  for i in $(seq 1 "${retries}"); do
    log "DNS-only ingress reachability attempt ${i}/${retries}"

    if curl --silent --show-error --fail --insecure \
      -u "${HTPASSWD_USER}:${HTPASSWD_PASSWORD}" \
      "https://${DOMAIN}/api/sites" >/dev/null; then
      log "Ingress API reachable via system DNS on attempt ${i}"
      return 0
    fi

    log "Ingress not yet reachable via DNS; retrying in ${delay}s"
    sleep "${delay}"
  done

  log "Ingress API not reachable via system DNS within ${retries} attempts"
  return 1
}

wait_for_local_api_health() {
  log "Waiting for local API health at http://127.0.0.1:${API_PORT}/api/sites (retries: ${1}, delay: ${2}s)..."
  local retries="$1"
  local delay="$2"
  local i

  for i in $(seq 1 "${retries}"); do
    log "Local API health attempt ${i}/${retries}"

    if curl --silent --show-error --fail "http://127.0.0.1:${API_PORT}/api/sites" >/dev/null; then
      log "Local API is healthy on attempt ${i}"
      return 0
    fi

    log "Local API not yet healthy; retrying in ${delay}s"
    sleep "${delay}"
  done

  log "Local API did not become healthy within ${retries} attempts"
  return 1
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"
ensure_value HTPASSWD_USER "Enter HTTP Basic Auth username for ${DOMAIN}"
ensure_secret_value HTPASSWD_PASSWORD "Enter HTTP Basic Auth password for ${HTPASSWD_USER}"

log "[1/8] Installing deployment dependencies"
sudo apt update -y
log "Apt package index updated"
sudo apt install -y nginx mkcert apache2-utils curl ca-certificates rsync
log "Base dependency packages installed"
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
require_cmd rsync
require_cmd htpasswd
resolve_compose_cmd
[ -n "${CONTAINER_NAME}" ] || fail "Container name must not be empty"

log "Enabling and restarting Docker service"
sudo systemctl enable docker
sudo systemctl restart docker
log "Docker service is active"

log "[2/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install
log "mkcert local CA installed"

tmp_cert="$(mktemp /tmp/core-indexer-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-indexer-key.XXXXXX.pem)"
log "Temporary TLS paths: cert=${tmp_cert} key=${tmp_key}"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"
log "TLS certificate and key generated for ${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"
log "TLS material installed to ${NGINX_SSL_DIR} with restricted permissions"

log "[3/8] Deploying static frontend assets"
write_frontend_assets
log "Static frontend assets deployed to ${WEB_ROOT}"

log "[4/8] Preparing container build context at ${INSTALL_DIR}"
sudo mkdir -p "${INSTALL_DIR}"
log "Install directory ensured: ${INSTALL_DIR}"
sudo rsync -a --delete "${API_SOURCE_DIR}/" "${INSTALL_DIR}/"
log "API source synced from ${API_SOURCE_DIR} to ${INSTALL_DIR}"

RUNTIME_API_ENTRYPOINT="${INSTALL_DIR}/${API_ENTRYPOINT_BASENAME}"
if [ ! -f "${RUNTIME_API_ENTRYPOINT}" ]; then
  log "API entrypoint not found at ${API_ENTRYPOINT}; generating fallback API at ${RUNTIME_API_ENTRYPOINT}"
  write_fallback_api "${RUNTIME_API_ENTRYPOINT}"
else
  log "API entrypoint found at ${RUNTIME_API_ENTRYPOINT}"
fi

log "Writing Dockerfile to ${DOCKERFILE_PATH}"
sudo tee "${DOCKERFILE_PATH}" >/dev/null <<EOF
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir --upgrade pip \
  && pip install --no-cache-dir "flask>=3.0,<4.0"

COPY . .

ENV FLASK_ENV=production
ENV PORT=${API_PORT}
ENV PYTHONUNBUFFERED=1
EXPOSE ${API_PORT}

CMD ["python", "${API_ENTRYPOINT_BASENAME}"]
EOF

log "Dockerfile written to ${DOCKERFILE_PATH}"

log "Writing Docker Compose file to ${COMPOSE_FILE}"
sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  indexer:
    container_name: ${CONTAINER_NAME}
    build:
      context: ${INSTALL_DIR}
      dockerfile: Dockerfile
    image: ${IMAGE_TAG}
    restart: unless-stopped
    environment:
      - PORT=${API_PORT}
      - FLASK_ENV=production
      - PYTHONUNBUFFERED=1
    ports:
      - "127.0.0.1:${API_PORT}:${API_PORT}"
EOF
log "Docker Compose file written to ${COMPOSE_FILE}"

log "[5/8] Enforcing ingress authentication baseline"

if [ ! -f "${HTPASSWD_FILE}" ]; then
  log "htpasswd file not found; creating new file at ${HTPASSWD_FILE}"
  printf '%s\n' "${HTPASSWD_PASSWORD}" | sudo htpasswd -i -c "${HTPASSWD_FILE}" "${HTPASSWD_USER}"
  log "htpasswd file created for user ${HTPASSWD_USER}"

else
  log "htpasswd file exists; updating credentials for user ${HTPASSWD_USER}"
  printf '%s\n' "${HTPASSWD_PASSWORD}" | sudo htpasswd -i "${HTPASSWD_FILE}" "${HTPASSWD_USER}"
  log "htpasswd credentials updated for user ${HTPASSWD_USER}"
fi

sudo chown root:www-data "${HTPASSWD_FILE}"
sudo chmod 640 "${HTPASSWD_FILE}"
log "htpasswd file permissions set: root:www-data 640"

log "[6/8] Writing Nginx ingress config for ${DOMAIN}"
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

    root  ${WEB_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
      proxy_pass         http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        add_header         Cache-Control "no-store, no-cache, must-revalidate";
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;
    add_header Referrer-Policy        "no-referrer" always;

    access_log /var/log/nginx/core-indexer.access.log;
    error_log  /var/log/nginx/core-indexer.error.log warn;
}
EOF

log "Nginx site config written to ${NGINX_SITE_FILE}"

sudo ln -sf "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
log "Nginx site enabled: ${NGINX_SITE_LINK}"

sudo rm -f /etc/nginx/sites-enabled/index.zenith.su /etc/nginx/sites-enabled/default
log "Stale Nginx site symlinks removed"

log "Validating Nginx configuration"
sudo nginx -t
log "Nginx configuration is valid"

sudo systemctl enable nginx
sudo systemctl restart nginx
log "Nginx service is active"

log "[7/8] Building and starting containerized API"
log "Tearing down any existing Compose stack"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
remove_existing_indexer_containers

log "Starting Indexer container via Docker Compose"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --build
log "Docker Compose stack started"

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
log "Container state for ${CONTAINER_NAME}: ${container_state}"
[ "${container_state}" = "running" ] || fail "Container ${CONTAINER_NAME} is not running"
log "Container ${CONTAINER_NAME} is running"

if ! wait_for_local_api_health "${API_HEALTH_RETRIES}" "${API_HEALTH_DELAY_SECONDS}"; then
  log "Indexer API did not become healthy in time; showing recent container logs"
  sudo docker logs --tail 80 "${CONTAINER_NAME}" || true
  fail "Indexer API health check failed at /api/sites"
fi
log "Local API health confirmed at http://127.0.0.1:${API_PORT}/api/sites"

log "[8/8] Verifying mesh DNS and runtime endpoint"
require_cmd netbird
sudo netbird status >/dev/null 2>&1 || fail "Netbird is not connected; cannot validate mesh DNS contract"
log "Netbird is connected"

dns_validated="false"
log "Querying DNS for ${DOMAIN} via getent ahostsv4"
resolved_ips="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1}' | awk '!seen[$1]++' || true)"

if [ -n "${resolved_ips}" ]; then
  log "DNS resolved ${DOMAIN} to: ${resolved_ips//$'\n'/, }"
  validate_resolved_ip_list "${resolved_ips}"
  dns_validated="true"

else
  log "getent returned no results for ${DOMAIN}; attempting DNS-only ingress reachability check"
  
  if wait_for_ingress_api_health_dns_only 5 1; then
    log "${DOMAIN} is reachable through system DNS despite empty getent output; continuing"
    dns_validated="true"
  fi

fi

if [ "${dns_validated}" != "true" ]; then

  if [ "${STRICT_DNS_VALIDATION}" = "true" ]; then
    fail "DNS lookup failed for ${DOMAIN}; configure AdGuard and Netbird nameserver group"
  fi

  log "DNS for ${DOMAIN} is not ready yet. Continuing with direct ingress check via NETBIRD_DEVICE_IP (${NETBIRD_DEVICE_IP})."
fi

if [ "${dns_validated}" = "true" ]; then
  log "Performing authenticated ingress health check via DNS"

  if ! wait_for_ingress_api_health "${API_HEALTH_RETRIES}" "${API_HEALTH_DELAY_SECONDS}" "dns"; then
    log "Authenticated ingress check failed via DNS; showing diagnostics"
    sudo docker logs --tail 80 "${CONTAINER_NAME}" || true
    sudo tail -n 80 /var/log/nginx/core-indexer.error.log || true
    fail "Ingress health check failed for https://${DOMAIN}/api/sites"
  fi

  log "Authenticated ingress health check passed via DNS"

else
  log "Performing authenticated ingress health check via NETBIRD_DEVICE_IP (${NETBIRD_DEVICE_IP})"
  
  if ! wait_for_ingress_api_health "${API_HEALTH_RETRIES}" "${API_HEALTH_DELAY_SECONDS}" "resolve"; then
    log "Authenticated ingress check failed with NETBIRD_DEVICE_IP override; showing diagnostics"
    sudo docker logs --tail 80 "${CONTAINER_NAME}" || true
    sudo tail -n 80 /var/log/nginx/core-indexer.error.log || true
    fail "Ingress health check failed for https://${DOMAIN}/api/sites using NETBIRD_DEVICE_IP override"
  fi
  
  log "Authenticated ingress health check passed via NETBIRD_DEVICE_IP override"
fi

echo
log "Deployment complete and container runtime checks passed"
log "URL: https://${DOMAIN}"
log "Container logs: sudo docker logs -f ${CONTAINER_NAME}"
log "Compose stack: ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} ps"