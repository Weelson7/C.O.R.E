#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 10 - C.O.R.E OnlyOffice (onlyoffice.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) runtime directory provisioning
# 3) container runtime definition generation
# 4) container activation
# 5) TLS material provisioning
# 6) ingress configuration and validation
# 7) mesh DNS and runtime health validation

SERVICE_NAME="core-onlyoffice"
DOMAIN="onlyoffice.core"
INSTALL_DIR="/opt/core/onlyoffice"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

IMAGE_TAG="${IMAGE_TAG:-onlyoffice/documentserver}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-8005}"

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
  echo "[core-onlyoffice] $*"
}

fail() {
  echo "[core-onlyoffice] ERROR: $*" >&2
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
  log "Operating system confirmed as Ubuntu"
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

resolve_compose_cmd() {
  log "Resolving Docker Compose v2 command..."

  if sudo docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker compose)
    log "Docker Compose v2 plugin resolved via 'docker compose'"
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

  log "Detecting host architecture for manual compose plugin installation..."
  arch="$(uname -m)"
  log "Detected host architecture: ${arch}"

  case "${arch}" in
    x86_64|amd64) plugin_arch="x86_64" ;;
    aarch64|arm64) plugin_arch="aarch64" ;;
    *) fail "Unsupported architecture for compose plugin fallback: ${arch}" ;;
  esac

  log "Mapped architecture to compose plugin variant: ${plugin_arch}"
  plugin_url="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_PLUGIN_VERSION}/docker-compose-linux-${plugin_arch}"
  log "Compose plugin download URL: ${plugin_url}"

  log "Creating Docker CLI plugins directory at ${plugin_dir}"
  sudo mkdir -p "${plugin_dir}"

  log "Downloading Docker Compose plugin to ${plugin_path}"
  sudo curl -fsSL "${plugin_url}" -o "${plugin_path}"

  log "Setting execute permission on ${plugin_path}"
  sudo chmod +x "${plugin_path}"

  log "Docker Compose plugin installed manually to ${plugin_path}"
}

install_container_stack() {
  log "Attempting to install docker.io and docker-compose-plugin via apt..."

  if sudo apt install -y docker.io docker-compose-plugin; then
    log "docker.io and docker-compose-plugin installed via apt"
    return 0
  fi

  log "Package docker-compose-plugin unavailable; installing Docker Compose plugin manually"
  sudo apt install -y docker.io
  log "docker.io installed via apt"
  install_compose_plugin_manually
}

validate_resolved_ip() {
  local resolved_ip="$1"

  log "Validating resolved IP ${resolved_ip} for ${DOMAIN}..."

  if [ "${resolved_ip}" = "${NETBIRD_DEVICE_IP}" ]; then
    log "Resolved IP ${resolved_ip} matches primary device IP ${NETBIRD_DEVICE_IP}"
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

wait_for_local_onlyoffice_health() {
  local retries="${1:-60}"
  local delay_seconds="${2:-3}"
  local i
  local endpoint
  local status_code

  log "Waiting for local OnlyOffice health check to pass (max ${retries} attempts, ${delay_seconds}s delay)..."

  for i in $(seq 1 "${retries}"); do
    log "Health check attempt ${i}/${retries}..."

    for endpoint in "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" "http://localhost:${PUBLISHED_HTTP_PORT}/"; do
      log "Probing ${endpoint}"
      status_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "${endpoint}" 2>/dev/null || true)"
      log "HTTP response code from ${endpoint}: ${status_code}"

      case "${status_code}" in
        200|301|302|401|403)
          log "OnlyOffice responded with acceptable status code ${status_code} at ${endpoint}"
          return 0
          ;;
      esac
    done

    log "OnlyOffice not yet healthy; waiting ${delay_seconds}s before next attempt"
    sleep "${delay_seconds}"
  done

  log "OnlyOffice did not become healthy after ${retries} attempts"
  return 1
}

generate_jwt_secret() {
  log "Generating random JWT secret..." >&2
  local secret

  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -hex 32)"
    log "JWT secret generated via openssl" >&2
  else
    secret="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)"
    log "JWT secret generated via /dev/urandom (openssl not available)" >&2
  fi

  echo "${secret}"
}

write_compose_file() {
  local jwt_secret="$1"
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  onlyoffice:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    environment:
      - TZ=UTC
      - JWT_ENABLED=true
      - JWT_SECRET=${jwt_secret}
    volumes:
      - ${DATA_DIR}:/var/www/onlyoffice/Data
      - ${LOG_DIR}:/var/log/onlyoffice
    ports:
      - "127.0.0.1:${PUBLISHED_HTTP_PORT}:80"
    network_mode: bridge
EOF
  log "Docker Compose file written successfully"
}

write_nginx_site() {
  log "Writing Nginx site configuration to ${NGINX_SITE_FILE}"
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

    access_log /var/log/nginx/core-onlyoffice.access.log;
    error_log  /var/log/nginx/core-onlyoffice.error.log warn;
}
EOF
  log "Nginx site configuration written successfully"
}

cleanup_previous_runtime() {
  log "Cleaning previous OnlyOffice runtime artifacts..."
  local ids=()
  local id

  if [ -f "${COMPOSE_FILE}" ]; then
    log "Compose file found at ${COMPOSE_FILE}; tearing down existing stack"
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
    log "Existing compose stack torn down"
  else
    log "No compose file found at ${COMPOSE_FILE}; skipping stack teardown"
  fi

  log "Collecting container IDs matching name /${SERVICE_NAME}..."
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    ids+=("${id}")
  done < <(sudo docker ps -aq --filter "name=^/${SERVICE_NAME}$")

  log "Collecting container IDs matching ancestor image ${IMAGE_TAG}..."
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    ids+=("${id}")
  done < <(sudo docker ps -aq --filter "ancestor=${IMAGE_TAG}")

  if [ "${#ids[@]}" -gt 0 ]; then
    mapfile -t ids < <(printf '%s\n' "${ids[@]}" | awk '!seen[$1]++')
    log "Removing existing OnlyOffice container workload (${#ids[@]} container(s))"
    sudo docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
    log "Existing OnlyOffice containers removed"
  else
    log "No existing OnlyOffice containers found; nothing to remove"
  fi
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"

log "[1/7] Installing deployment dependencies"
log "Running apt update..."
sudo apt update -y
log "apt update complete"

log "Installing nginx, mkcert, curl, ca-certificates..."
sudo apt install -y nginx mkcert curl ca-certificates
log "Core packages installed"

log "Installing container stack (docker.io, docker-compose-plugin)..."
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
resolve_compose_cmd

log "Enabling and restarting Docker daemon..."
sudo systemctl enable docker
sudo systemctl restart docker
log "Docker daemon enabled and restarted"

log "[2/7] Provisioning runtime directories"
log "Creating install, data, and log directories..."
sudo mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}"
log "Directories created: ${INSTALL_DIR}, ${DATA_DIR}, ${LOG_DIR}"

log "[3/7] Writing container runtime definition"
JWT_SECRET="$(generate_jwt_secret)"
write_compose_file "${JWT_SECRET}"
log "JWT secret written into compose file (not echoed to log)"

log "[4/7] Starting OnlyOffice container"
cleanup_previous_runtime

log "Bringing up OnlyOffice container via compose..."
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d
log "Compose up complete; inspecting container state..."

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
log "Container ${SERVICE_NAME} state: ${container_state}"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"
log "Container ${SERVICE_NAME} is confirmed running"

log "Waiting for OnlyOffice to initialise (cold-start may take up to 3 minutes)..."
if ! wait_for_local_onlyoffice_health 60 3; then
  log "OnlyOffice local health check did not pass in time; dumping diagnostics"
  sudo ss -lntp | grep -E "(:${PUBLISHED_HTTP_PORT}[[:space:]]|:${PUBLISHED_HTTP_PORT}$)" || true
  sudo docker logs "${SERVICE_NAME}" | tail -30 || true
  fail "OnlyOffice local health check failed"
fi
log "OnlyOffice local health check passed"

log "[5/7] Provisioning TLS material for ${DOMAIN}"
log "Installing mkcert root CA..."
mkcert -install
log "mkcert root CA installed"

log "Generating TLS certificate and key for ${DOMAIN}..."
tmp_cert="$(mktemp /tmp/core-onlyoffice-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-onlyoffice-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"
log "TLS certificate generated at ${tmp_cert}"
log "TLS key generated at ${tmp_key}"

log "Installing TLS material into ${NGINX_SSL_DIR}..."
sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"
log "TLS certificate installed at ${NGINX_CERT_FILE}"
log "TLS key installed at ${NGINX_KEY_FILE}"

log "[6/7] Writing and validating Nginx ingress for ${DOMAIN}"
write_nginx_site

log "Symlinking ${NGINX_SITE_FILE} to ${NGINX_SITE_LINK}..."
sudo ln -sfn "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
log "Nginx site symlink created"

log "Testing Nginx configuration..."
sudo nginx -t
log "Nginx configuration test passed"

log "Restarting Nginx to apply new site configuration..."
sudo systemctl restart nginx
log "Nginx restarted successfully"

log "[7/7] Verifying mesh DNS and ingress runtime health"
log "Resolving ${DOMAIN} via getent..."
resolved_ip="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -n1)"
log "Resolved IP for ${DOMAIN}: ${resolved_ip:-<empty>}"
[ -n "${resolved_ip}" ] || fail "DNS resolution failed for ${DOMAIN}"
validate_resolved_ip "${resolved_ip}"

log "Testing ingress at https://${DOMAIN}/..."
ingress_response="$(curl --silent --show-error --insecure -w "\nHTTP_CODE:%{http_code}" \
  --resolve "${DOMAIN}:443:${NETBIRD_DEVICE_IP}" \
  "https://${DOMAIN}/" 2>&1)" || true

echo "${ingress_response}"

log "Extracting HTTP status code from ingress response..."
http_code="$(echo "${ingress_response}" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)"
log "Ingress HTTP response code: ${http_code}"

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
log "Container status:  sudo docker ps -f name=${SERVICE_NAME}"
log "Container logs:    sudo docker logs -f ${SERVICE_NAME}"
log "Nginx error log:   sudo tail -50 /var/log/nginx/core-onlyoffice.error.log"
log "Ingress check:     curl -k https://${DOMAIN}/"
log "JWT secret:        sudo grep JWT_SECRET ${COMPOSE_FILE}"
