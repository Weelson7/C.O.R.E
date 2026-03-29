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
PUBLISHED_HTTP_PORT="8096"

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_jellyfin"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
HTPASSWD_USER="${HTPASSWD_USER:-}"
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
      - JELLYFIN_PublishedHttpPort=80
      - JELLYFIN_PublishedHttpsPort=443
    volumes:
      - ${CONFIG_DIR}:/config
      - ${CACHE_DIR}:/cache
      - ${MEDIA_DIR}:/media:ro
    ports:
      - "0.0.0.0:${PUBLISHED_HTTP_PORT}:8096"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

write_nginx_site() {
  sudo tee "${NGINX_SITE_FILE}" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    listen ${NETBIRD_DEVICE_IP}:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen ${NETBIRD_DEVICE_IP}:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${NGINX_CERT_FILE};
    ssl_certificate_key ${NGINX_KEY_FILE};

    auth_basic           "C.O.R.E. - restricted";
    auth_basic_user_file ${HTPASSWD_FILE};

    client_max_body_size 20G;

    location / {
        proxy_pass         http://127.0.0.1:${PUBLISHED_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   X-Forwarded-Host  \$host;
        proxy_set_header   X-Forwarded-Port  \$server_port;
        
        proxy_buffering          off;
        proxy_cache              off;
        proxy_redirect           off;
        
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_connect_timeout 600;
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;
    add_header Referrer-Policy        "same-origin" always;

    access_log /var/log/nginx/core-jellyfin.access.log;
    error_log  /var/log/nginx/core-jellyfin.error.log warn;
}
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

log "[2/7] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}" "${CACHE_DIR}" "${MEDIA_DIR}"

log "[3/7] Writing container runtime definition"
write_compose_file

log "[4/7] Starting Jellyfin container"
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

sleep 2

container_state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
if [ "${container_state}" != "running" ]; then
  log "ERROR: Container state is '${container_state}', not running"
  log "Container inspect output:"
  sudo docker inspect "${SERVICE_NAME}" 2>&1 | head -30
  log "Recent container logs:"
  sudo docker logs "${SERVICE_NAME}" 2>&1 | tail -50
  fail "Container ${SERVICE_NAME} failed to start"
fi

log "Waiting for Jellyfin HTTP port to be accessible..."
max_attempts=30
attempt=0
while [ "${attempt}" -lt "${max_attempts}" ]; do
  if timeout 3 bash -c "</dev/tcp/127.0.0.1/${PUBLISHED_HTTP_PORT}" 2>/dev/null; then
    log "Port ${PUBLISHED_HTTP_PORT} is listening"
    break
  fi
  attempt=$((attempt + 1))
  if [ "${attempt}" -lt "${max_attempts}" ]; then
    log "Port check attempt ${attempt}/${max_attempts} - port not listening yet; retrying in 1s..."
    sleep 1
  fi
done

if [ "${attempt}" -ge "${max_attempts}" ]; then
  log "ERROR: Jellyfin port ${PUBLISHED_HTTP_PORT} never became accessible"
  log "Container status: $(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}")"
  log "Container logs (last 100 lines):"
  sudo docker logs "${SERVICE_NAME}" 2>&1 | tail -100
  fail "Port ${PUBLISHED_HTTP_PORT} did not open; check container logs above"
fi

log "Waiting for Jellyfin HTTP health endpoint..."
attempt=0
while [ "${attempt}" -lt "${max_attempts}" ]; do
  if curl --silent --show-error --fail --max-time 3 "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/web/index.html" >/dev/null 2>&1; then
    log "Jellyfin HTTP endpoint is healthy"
    break
  fi
  attempt=$((attempt + 1))
  if [ "${attempt}" -lt "${max_attempts}" ]; then
    log "HTTP health check attempt ${attempt}/${max_attempts} failed; retrying in 1s..."
    sleep 1
  fi
done

if [ "${attempt}" -ge "${max_attempts}" ]; then
  log "ERROR: Jellyfin HTTP endpoint never responded"
  log "Recent curl output:"
  curl -v "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/web/index.html" 2>&1 || true
  log "Container logs (last 100 lines):"
  sudo docker logs "${SERVICE_NAME}" 2>&1 | tail -100
  fail "Jellyfin HTTP health check failed"
fi

log "[5/7] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-jellyfin-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-jellyfin-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[6/7] Enforcing centralized ingress authentication"
if [ ! -f "${HTPASSWD_FILE}" ]; then
  printf '%s\n' "${HTPASSWD_PASSWORD}" | sudo htpasswd -i -c "${HTPASSWD_FILE}" "${HTPASSWD_USER}"
else
  printf '%s\n' "${HTPASSWD_PASSWORD}" | sudo htpasswd -i "${HTPASSWD_FILE}" "${HTPASSWD_USER}"
fi
sudo chmod 640 "${HTPASSWD_FILE}"

log "[7/8] Writing and validating Nginx ingress for ${DOMAIN}"
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

log "Testing nginx accessibility on netbird IP (${NETBIRD_DEVICE_IP})..."
log "  Checking if port 80 is open on ${NETBIRD_DEVICE_IP}:80"
if timeout 3 bash -c "echo > /dev/tcp/${NETBIRD_DEVICE_IP}/80" 2>/dev/null; then
  log "  Port 80: OPEN"
else
  log "  Port 80: CLOSED/UNREACHABLE (nginx may not be bound to netbird IP, or port filtered)"
fi

log "  Checking if port 443 is open on ${NETBIRD_DEVICE_IP}:443"
if timeout 3 bash -c "echo > /dev/tcp/${NETBIRD_DEVICE_IP}/443" 2>/dev/null; then
  log "  Port 443: OPEN"
else
  log "  Port 443: CLOSED/UNREACHABLE (nginx may not be bound to netbird IP, or port filtered)"
fi

log "Testing HTTP redirect from nginx on netbird IP..."
if curl --silent --max-time 3 "http://${NETBIRD_DEVICE_IP}" 2>&1 | grep -q "301\|302\|Location"; then
  log "  HTTP redirect: OK (nginx is responding)"
else
  log "  HTTP redirect: FAILED or no response"
fi

log "Testing HTTPS with auth on domain ${DOMAIN}..."
if curl --silent --show-error --insecure "https://${DOMAIN}/web/index.html" >/dev/null 2>&1; then
  log "  HTTPS to domain: OK"
else
  log "  HTTPS to domain: FAILED"
  log "  Testing direct IP HTTPS (${NETBIRD_DEVICE_IP}:443/web/index.html)..."
  if curl --silent --show-error --insecure "https://${NETBIRD_DEVICE_IP}/web/index.html" 2>&1 | head -5; then
    log "  Direct IP: Got response (check above)"
  else
    log "  Direct IP: No response"
  fi
fi

log "Nginx configuration and status:"
log "  Listening sockets:"
sudo ss -tlnp 2>/dev/null | grep -E ':(80|443) ' | sed 's/^/    /' || log "    (ss command failed)"

log "  Nginx test output:"
sudo nginx -t 2>&1 | sed 's/^/    /'

log "  Nginx error log (last 10 lines):"
sudo tail -10 /var/log/nginx/core-jellyfin.error.log 2>/dev/null | sed 's/^/    /' || log "    (no errors)"

fail "Ingress health check failed for https://${DOMAIN}/web/index.html - check diagnostics above"

echo
log "Deployment complete and container runtime checks passed"
log "URL: https://${DOMAIN}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
log "Compose stack: ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} ps"
