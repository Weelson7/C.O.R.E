#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 12 - C.O.R.E Seafile (seafile.core)

SERVICE_NAME="core-seafile"
DOMAIN="seafile.core"
INSTALL_DIR="/opt/core/seafile"
DATA_DIR="${INSTALL_DIR}/data"
MYSQL_DIR="${INSTALL_DIR}/mysql"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
LOGS_DIR="${INSTALL_DIR}/logs"

IMAGE_TAG="${IMAGE_TAG:-seafileltd/seafile-mc:latest}"
IMAGE_TAG_DB="${IMAGE_TAG_DB:-mariadb:10.11}"
IMAGE_TAG_CACHE="${IMAGE_TAG_CACHE:-memcached:1.6.18}"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-8083}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
SEAFILE_ADMIN_EMAIL="${SEAFILE_ADMIN_EMAIL:-}"
SEAFILE_ADMIN_PASSWORD="${SEAFILE_ADMIN_PASSWORD:-}"
COMPOSE_CMD=()
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"

# Log to stderr so it doesn't get captured by variable expansion
log() {
  echo "[core-seafile] $*" >&2
}

fail() {
  echo "[core-seafile] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  log "Checking for required command: $1"
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ensure_ubuntu() {
  log "Ensuring operating system is Ubuntu..."
  [ -r /etc/os-release ] || fail "Cannot determine operating system"
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || fail "This script requires Ubuntu (detected: ${ID:-unknown})"
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
  fail "Docker Compose v2 plugin not available"
}

install_container_stack() {
  if sudo apt install -y docker.io docker-compose-plugin 2>/dev/null; then
    return 0
  fi

  log "docker-compose-plugin unavailable; installing manually"
  sudo apt install -y docker.io

  local arch plugin_arch plugin_dir plugin_path plugin_url
  arch="$(uname -m)"
  plugin_dir="/usr/local/lib/docker/cli-plugins"
  plugin_path="${plugin_dir}/docker-compose"

  case "${arch}" in
    x86_64|amd64) plugin_arch="x86_64" ;;
    aarch64|arm64) plugin_arch="aarch64" ;;
    *) fail "Unsupported architecture: ${arch}" ;;
  esac

  plugin_url="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_PLUGIN_VERSION}/docker-compose-linux-${plugin_arch}"
  sudo mkdir -p "${plugin_dir}"
  sudo curl -fsSL "${plugin_url}" -o "${plugin_path}"
  sudo chmod +x "${plugin_path}"
}

validate_resolved_ip() {
  local resolved_ip="$1"

  if [ "${resolved_ip}" = "${NETBIRD_DEVICE_IP}" ]; then
    return 0
  fi

  if [ -n "${NETBIRD_FAILOVER_IP}" ] && [ "${resolved_ip}" = "${NETBIRD_FAILOVER_IP}" ]; then
    return 0
  fi

  if [ -n "${NETBIRD_FAILOVER_IP}" ]; then
    fail "DNS mismatch for ${DOMAIN}: expected ${NETBIRD_DEVICE_IP} or ${NETBIRD_FAILOVER_IP}, got ${resolved_ip}"
  fi

  fail "DNS mismatch for ${DOMAIN}: expected ${NETBIRD_DEVICE_IP}, got ${resolved_ip}"
}

wait_for_local_seafile_health() {
  local retries="${1:-100}"
  local delay_seconds="${2:-3}"
  local i status_code

  log "Waiting for Seafile to be healthy (max ${retries} attempts, ${delay_seconds}s delay)..."

  for i in $(seq 1 "${retries}"); do
    for endpoint in "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" "http://localhost:${PUBLISHED_HTTP_PORT}/"; do
      status_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "${endpoint}" 2>/dev/null || true)"
      
      case "${status_code}" in
        200|301|302|303)
          log "Seafile healthy (HTTP ${status_code})"
          return 0
          ;;
      esac
    done

    log "Attempt ${i}/${retries}: not ready, waiting ${delay_seconds}s..."
    sleep "${delay_seconds}"
  done

  return 1
}

generate_secret() {
  local secret
  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -hex 32)"
  else
    secret="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)"
  fi
  echo "${secret}"
}

write_compose_file() {
  local mysql_root_password="$1"
  local tmp_compose

  tmp_compose=$(mktemp)

  cat > "${tmp_compose}" <<'COMPOSE_EOF'
networks:
  seafile-net:
    driver: bridge

services:
  db:
    container_name: core-seafile-db
    image: IMAGE_TAG_DB_PLACEHOLDER
    restart: unless-stopped
    networks: [seafile-net]
    environment:
      MYSQL_ROOT_PASSWORD: MYSQL_ROOT_PASSWORD_PLACEHOLDER
      MYSQL_LOG_CONSOLE: "true"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - MYSQL_DIR_PLACEHOLDER:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10

  memcached:
    container_name: core-seafile-memcached
    image: IMAGE_TAG_CACHE_PLACEHOLDER
    restart: unless-stopped
    networks: [seafile-net]
    entrypoint: memcached -m 256

  seafile:
    container_name: SERVICE_NAME_PLACEHOLDER
    image: IMAGE_TAG_PLACEHOLDER
    restart: unless-stopped
    networks: [seafile-net]
    ports:
      - "127.0.0.1:PUBLISHED_HTTP_PORT_PLACEHOLDER:80"
    volumes:
      - DATA_DIR_PLACEHOLDER:/shared
    environment:
      TZ: UTC
      DB_HOST: db
      DB_ROOT_PASSWD: MYSQL_ROOT_PASSWORD_PLACEHOLDER
      SEAFILE_ADMIN_EMAIL: SEAFILE_ADMIN_EMAIL_PLACEHOLDER
      SEAFILE_ADMIN_PASSWORD: SEAFILE_ADMIN_PASSWORD_PLACEHOLDER
      SEAFILE_SERVER_HOSTNAME: DOMAIN_PLACEHOLDER
      SEAFILE_SERVER_LETSENCRYPT: "false"
      FORCE_HTTPS_IN_CONF: "false"
    depends_on:
      db:
        condition: service_healthy
      memcached:
        condition: service_started
COMPOSE_EOF

  # Safe replacements using sed
  sed -i "s|IMAGE_TAG_DB_PLACEHOLDER|${IMAGE_TAG_DB}|g" "${tmp_compose}"
  sed -i "s|IMAGE_TAG_CACHE_PLACEHOLDER|${IMAGE_TAG_CACHE}|g" "${tmp_compose}"
  sed -i "s|SERVICE_NAME_PLACEHOLDER|${SERVICE_NAME}|g" "${tmp_compose}"
  sed -i "s|IMAGE_TAG_PLACEHOLDER|${IMAGE_TAG}|g" "${tmp_compose}"
  sed -i "s|PUBLISHED_HTTP_PORT_PLACEHOLDER|${PUBLISHED_HTTP_PORT}|g" "${tmp_compose}"
  sed -i "s|DATA_DIR_PLACEHOLDER|${DATA_DIR}|g" "${tmp_compose}"
  sed -i "s|MYSQL_DIR_PLACEHOLDER|${MYSQL_DIR}|g" "${tmp_compose}"
  sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "${tmp_compose}"

  # Escape special characters for sed
  local escaped_password escaped_email escaped_admin_password
  escaped_password=$(printf '%s\n' "${mysql_root_password}" | sed -e 's/[\/&]/\\&/g')
  escaped_email=$(printf '%s\n' "${SEAFILE_ADMIN_EMAIL}" | sed -e 's/[\/&]/\\&/g')
  escaped_admin_password=$(printf '%s\n' "${SEAFILE_ADMIN_PASSWORD}" | sed -e 's/[\/&]/\\&/g')

  sed -i "s|MYSQL_ROOT_PASSWORD_PLACEHOLDER|${escaped_password}|g" "${tmp_compose}"
  sed -i "s|SEAFILE_ADMIN_EMAIL_PLACEHOLDER|${escaped_email}|g" "${tmp_compose}"
  sed -i "s|SEAFILE_ADMIN_PASSWORD_PLACEHOLDER|${escaped_admin_password}|g" "${tmp_compose}"

  sudo mv "${tmp_compose}" "${COMPOSE_FILE}"
  log "Compose file written"
}

write_nginx_site() {
  log "Writing Nginx configuration"
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

    access_log /var/log/nginx/core-seafile.access.log;
    error_log  /var/log/nginx/core-seafile.error.log warn;
}
EOF
}

prepare_directories() {
  log "Preparing directories with Seafile permissions (UID 1000:GID 1000)..."
  sudo mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${MYSQL_DIR}" "${LOGS_DIR}"
  sudo chown -R 1000:1000 "${INSTALL_DIR}"
  sudo chmod -R 755 "${INSTALL_DIR}"
  log "Directories ready: ${INSTALL_DIR}/*"
}

cleanup_previous_runtime() {
  log "Cleaning up previous runtime..."

  if [ -f "${COMPOSE_FILE}" ]; then
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi

  local ids id
  ids=()
  for filter in \
    "name=^/${SERVICE_NAME}$" \
    "name=^/core-seafile-db$" \
    "name=^/core-seafile-memcached$" \
    "ancestor=${IMAGE_TAG}" \
    "ancestor=${IMAGE_TAG_DB}" \
    "ancestor=${IMAGE_TAG_CACHE}"; do
    while IFS= read -r id; do
      [ -n "${id}" ] && ids+=("${id}")
    done < <(sudo docker ps -aq --filter "${filter}" 2>/dev/null)
  done

  if [ "${#ids[@]}" -gt 0 ]; then
    mapfile -t ids < <(printf '%s\n' "${ids[@]}" | awk '!seen[$1]++')
    sudo docker rm -f "${ids[@]}" 2>/dev/null || true
  fi

  log "Cleanup complete"
}

# Main execution
ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk

log "=== Seafile Deployment Script ==="
log "Domain: ${DOMAIN}"
log "Install directory: ${INSTALL_DIR}"

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP"
ensure_value SEAFILE_ADMIN_EMAIL "Enter Seafile admin email"
ensure_secret_value SEAFILE_ADMIN_PASSWORD "Enter Seafile admin password"

log "[1/7] Installing dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert curl ca-certificates
install_container_stack
require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
resolve_compose_cmd

log "Enabling Docker daemon"
sudo systemctl enable docker
sudo systemctl restart docker

log "[2/7] Provisioning directories"
prepare_directories

log "[3/7] Generating secrets and compose file"
MYSQL_ROOT_PASSWORD="$(generate_secret)"
write_compose_file "${MYSQL_ROOT_PASSWORD}"

log "[4/7] Starting Seafile stack"
cleanup_previous_runtime
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

sleep 5
container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container failed to start"

log "Waiting for Seafile initialization..."
if ! wait_for_local_seafile_health 120 5; then
  log "Health check failed. Dumping logs:"
  sudo docker logs "${SERVICE_NAME}" | tail -50 || true
  fail "Seafile failed to become healthy"
fi

log "[5/7] Provisioning TLS certificates"
mkcert -install
tmp_cert="$(mktemp /tmp/core-seafile-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-seafile-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"
log "TLS certificates installed"

log "[6/7] Configuring Nginx"
write_nginx_site
sudo ln -sfn "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo nginx -t
sudo systemctl restart nginx
log "Nginx configured and restarted"

log "[7/7] Validating deployment"
resolved_ip="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -n1)"
[ -n "${resolved_ip}" ] || fail "DNS resolution failed for ${DOMAIN}"
validate_resolved_ip "${resolved_ip}"

ingress_response="$(curl --silent --show-error --insecure -w "\nHTTP_CODE:%{http_code}" \
  --resolve "${DOMAIN}:443:${NETBIRD_DEVICE_IP}" \
  "https://${DOMAIN}/" 2>&1)" || true

http_code="$(echo "${ingress_response}" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)"
case "${http_code}" in
  200|301|302|303)
    log "Ingress validated (HTTP ${http_code})"
    ;;
  *)
    fail "Ingress check failed (HTTP ${http_code})"
    ;;
esac

echo
log "✓ Deployment complete"
log "Access Seafile at: https://${DOMAIN}/"
log "Useful commands:"
log "  Container status: sudo docker ps --filter name=core-seafile"
log "  View logs:        sudo docker logs -f core-seafile"
log "  View database:    sudo docker logs -f core-seafile-db"
log "  Database password: sudo grep DB_ROOT_PASSWD ${COMPOSE_FILE}"