#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 5 - C.O.R.E Kasm Workspaces (kasm.core)

# Official Kasm Workspaces deployment:
# 1) dependency installation
# 2) download and extract Kasm Workspaces installer
# 3) run official installation script
# 4) configure nginx reverse proxy with SSL
# 5) mesh DNS and runtime health validation

SERVICE_NAME="kasm"
DOMAIN="kasm.core"
KASM_VERSION="${KASM_VERSION:-1.17.0}"
KASM_BUILD="${KASM_BUILD:-7f020d}"
KASM_PORT="${KASM_PORT:-8443}"
SWAP_SIZE="${SWAP_SIZE:-2048}"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"

log() {
  echo "[kasm] $*"
}

fail() {
  echo "[kasm] ERROR: $*" >&2
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

setup_swap() {
  local swap_file="/swapfile"
  
  if [ "$(swapon --show | wc -l)" -gt 0 ]; then
    log "Swap already configured"
    return 0
  fi

  log "Creating ${SWAP_SIZE}MB swap file..."
  sudo fallocate -l "${SWAP_SIZE}M" "${swap_file}" || sudo dd if=/dev/zero of="${swap_file}" bs=1M count="${SWAP_SIZE}"
  sudo chmod 600 "${swap_file}"
  sudo mkswap "${swap_file}"
  sudo swapon "${swap_file}"
  echo "${swap_file} none swap sw 0 0" | sudo tee -a /etc/fstab
  log "Swap configured successfully"
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
        proxy_pass         https://127.0.0.1:${KASM_PORT};
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
        proxy_ssl_server_name on;
        proxy_ssl_verify      off;
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy        "same-origin" always;

    access_log /var/log/nginx/kasm.access.log;
    error_log  /var/log/nginx/kasm.error.log warn;
}
EOF
}

ensure_ubuntu
require_cmd sudo
require_cmd getent
require_cmd awk

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"

log "[1/7] Cleaning up any previous Kasm installation"
# Stop Kasm if it's running
if [ -f /opt/kasm/bin/stop ]; then
  log "Stopping existing Kasm services..."
  sudo /opt/kasm/bin/stop || true
fi

# Remove all Kasm containers
log "Removing old Kasm containers..."
sudo docker ps -a --format '{{.Names}}' | grep -i kasm | xargs -r sudo docker rm -f 2>/dev/null || true

# Wait a moment for ports to be freed
sleep 3

log "[2/7] Installing dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert curl ca-certificates

require_cmd mkcert
require_cmd nginx
require_cmd curl

log "[3/7] Setting up swap space (Kasm requires sufficient memory)"
setup_swap

log "[4/7] Downloading and installing Kasm Workspaces ${KASM_VERSION}"
cd /tmp
KASM_TAR="kasm_release_${KASM_VERSION}.${KASM_BUILD}.tar.gz"
KASM_URL="https://kasm-static-content.s3.amazonaws.com/${KASM_TAR}"

if [ ! -f "/tmp/${KASM_TAR}" ]; then
  log "Downloading from ${KASM_URL}"
  curl -fsSL "${KASM_URL}" -o "${KASM_TAR}"
fi

tar -xf "${KASM_TAR}"

log "Running Kasm installer on port ${KASM_PORT} (this takes 5-10 minutes)..."
log "Note: The installer will generate random passwords for admin and user accounts"

# Run the installer with custom port to avoid conflict with nginx
sudo bash kasm_release/install.sh --accept-eula --swap-size ${SWAP_SIZE} -L ${KASM_PORT} || {
  log "Installation may have completed with warnings. Checking status..."
}

# Wait for services to start
log "Waiting for Kasm services to initialize..."
sleep 30

# Check if Kasm is running
if ! sudo docker ps | grep -q kasm; then
  log "ERROR: Kasm containers are not running. Listing all containers:"
  sudo docker ps -a
  fail "Kasm containers failed to start. Check installation log in /tmp/kasm_install_*.log"
fi

# Check if port is listening
log "Checking if Kasm is listening on port ${KASM_PORT}..."
if ! sudo ss -lntp | grep -q ":${KASM_PORT}"; then
  log "ERROR: Port ${KASM_PORT} is not listening. Checking what ports Kasm is using:"
  sudo docker ps --format "table {{.Names}}\t{{.Ports}}" | grep kasm
  sudo ss -lntp | grep -E ":(443|8443|3000)" || true
  fail "Kasm is not listening on expected port ${KASM_PORT}"
fi

# Test direct access to Kasm
log "Testing direct access to Kasm at https://127.0.0.1:${KASM_PORT}"
if ! curl -k -s --max-time 10 "https://127.0.0.1:${KASM_PORT}" >/dev/null 2>&1; then
  log "WARNING: Could not reach Kasm directly at https://127.0.0.1:${KASM_PORT}"
  log "This may be normal if Kasm is still initializing. Continuing..."
fi

log "[5/7] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/kasm-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/kasm-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[6/7] Writing and validating Nginx ingress for ${DOMAIN}"
write_nginx_site

sudo ln -sf "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

log "[7/7] Validating mesh DNS and ingress runtime"
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
  200|301|302)
    log "Ingress check passed with HTTP ${http_code}"
    ;;
  *)
    fail "Ingress health check failed on https://${DOMAIN}/ (HTTP ${http_code})"
    ;;
esac

echo
log "========================================"
log "Kasm Workspaces deployment complete!"
log "========================================"
log "URL: https://${DOMAIN}"
log ""
log "Default credentials are in: /opt/kasm/current/conf/app/api.app.config.yaml"
log "Look for 'admin_password' and 'user_password'"
log ""
log "To view credentials:"
log "  sudo grep -A1 'admin_password\\|user_password' /opt/kasm/current/conf/app/api.app.config.yaml"
log ""
log "If you get 502 errors, check:"
log "  1. Container status: sudo docker ps | grep kasm"
log "  2. Port listening: sudo ss -lntp | grep ${KASM_PORT}"
log "  3. Direct access: curl -k https://127.0.0.1:${KASM_PORT}"
log "  4. Nginx errors: sudo tail -50 /var/log/nginx/kasm.error.log"
log ""
log "Manage services:"
log "  sudo /opt/kasm/bin/stop"
log "  sudo /opt/kasm/bin/start"
log "  sudo docker ps"

log() {
  echo "[core-kasm] $*"
}

fail() {
  echo "[core-kasm] ERROR: $*" >&2
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
    fail "Port conflict detected: tcp/${port} is already in use. Set PUBLISHED_HTTPS_PORT to a free port and rerun."
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
  local retries="${1:-90}"
  local delay="${2:-3}"
  local i

  log "Waiting for Kasm to become ready (this can take 2-4 minutes on first start)..."
  
  for i in $(seq 1 "${retries}"); do
    if curl --silent --output /dev/null --max-time 5 "http://127.0.0.1:${PUBLISHED_HTTPS_PORT}/" 2>/dev/null; then
      log "Health check passed on attempt ${i}"
      return 0
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
      log "Still waiting... attempt ${i}/${retries}"
    fi
    sleep "${delay}"
  done

  return 1
}

write_compose_file() {
  sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  kasm:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    privileged: true
    environment:
      - TZ=${TZ:-UTC}
      - PUID=${PUID}
      - PGID=${PGID}
    volumes:
      - ${INSTALL_DIR}/opt:/opt
      - ${INSTALL_DIR}/profiles:/profiles
      - /dev/input:/dev/input
      - /run/udev/data:/run/udev/data
    ports:
      - "127.0.0.1:${PUBLISHED_HTTPS_PORT}:3000"
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
        proxy_pass         http://127.0.0.1:${PUBLISHED_HTTPS_PORT};
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

    access_log /var/log/nginx/core-kasm.access.log;
    error_log  /var/log/nginx/core-kasm.error.log warn;
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

ensure_numeric_port "${PUBLISHED_HTTPS_PORT}"

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"

log "[1/8] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert curl ca-certificates iproute2
install_container_stack

require_cmd mkcert
require_cmd nginx
require_cmd docker
require_cmd curl
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/8] Cleaning up previous deployment"
if [ -f "${COMPOSE_FILE}" ]; then
  "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
fi
sudo docker stop "${SERVICE_NAME}" 2>/dev/null || true
sudo docker rm -f "${SERVICE_NAME}" 2>/dev/null || true

log "[3/8] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${INSTALL_DIR}/opt" "${INSTALL_DIR}/profiles"

log "[4/8] Enforcing no-port-conflict policy"
assert_host_port_available "${PUBLISHED_HTTPS_PORT}"

log "[5/8] Writing container runtime definition"
write_compose_file

log "[6/8] Starting Kasm container"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --pull always

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${container_state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

log "Container started. Kasm takes 2-4 minutes to initialize on first run..."
wait_for_local_health 90 3 || {
  log "Health check failed. Container logs:"
  sudo docker logs "${SERVICE_NAME}" --tail 50
  fail "Kasm local health check failed on http://127.0.0.1:${PUBLISHED_HTTPS_PORT}/"
}

log "[7/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-kasm-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-kasm-key.XXXXXX.pem)"
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
