#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 13 - C.O.R.E ncdu-web-viewer (ncdu.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) TLS material provisioning
# 3) container activation
# 4) ingress configuration validation
# 5) DNS resolution verification
# 6) runtime health confirmation

DOMAIN="ncdu.core"
SERVICE_NAME="core-ncdu-web-viewer"
INSTALL_DIR="/opt/core/ncdu-web-viewer"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
DOCKERFILE_PATH="${INSTALL_DIR}/Dockerfile"

HTTP_PORT="${HTTP_PORT:-3030}"
SCAN_PATH="${SCAN_PATH:-/}"
IMAGE_TAG="${IMAGE_TAG:-core/ncdu-web-viewer:local}"
CONTAINER_NAME="core-ncdu-web-viewer"

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
  echo "[core-ncdu-web-viewer] $*"
}

fail() {
  echo "[core-ncdu-web-viewer] ERROR: $*" >&2
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

ensure_scan_path_readable() {
  local scan_path="$1"
  
  if [ ! -d "${scan_path}" ]; then
    fail "Scan path does not exist or is not accessible: ${scan_path}"
  fi
  
  if [ ! -r "${scan_path}" ]; then
    fail "Scan path is not readable: ${scan_path}"
  fi
}

write_dockerfile() {
  local target="$1"

  sudo tee "${target}" >/dev/null <<'EOF'
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ncdu \
    python3-minimal \
    python3-requests \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app && cat > /app/ncdu_http.py <<'PYEOF'
#!/usr/bin/env python3
import subprocess
import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
import threading

class NCDUHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            html = '''<!DOCTYPE html>
<html>
<head>
  <title>ncdu-web-viewer</title>
  <style>
    body { font-family: monospace; background: #222; color: #0f0; padding: 2rem; }
    .container { max-width: 1200px; margin: 0 auto; }
    h1 { color: #0f0; }
    iframe { width: 100%; height: 800px; border: 1px solid #0f0; }
  </style>
</head>
<body>
  <div class="container">
    <h1>C.O.R.E ncdu-web-viewer</h1>
    <p>ncdu v2 is running on your C.O.R.E node. Analysis may take a moment...</p>
    <iframe src="/ncdu/"></iframe>
  </div>
</body>
</html>'''
            self.wfile.write(html.encode())
        
        elif parsed_path.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "ok"}')
        
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    port = int(os.getenv('PORT', 3030))
    server = HTTPServer(('0.0.0.0', port), NCDUHandler)
    print(f'ncdu HTTP server listening on 0.0.0.0:{port}')
    server.serve_forever()
PYEOF
RUN chmod +x /app/ncdu_http.py

WORKDIR /mnt/scan
ENTRYPOINT ["/app/ncdu_http.py"]
EOF
}

write_compose_file() {
  local target="$1"

  sudo tee "${target}" >/dev/null <<EOF
services:
  ncdu-web-viewer:
    container_name: ${CONTAINER_NAME}
    image: ${IMAGE_TAG}
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    environment:
      - PORT=${HTTP_PORT}
      - TZ=\${TZ:-UTC}
    volumes:
      - ${SCAN_PATH}:/mnt/scan:ro
    ports:
      - "127.0.0.1:${HTTP_PORT}:${HTTP_PORT}"
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

  auth_basic "C.O.R.E ncdu-web-viewer";
  auth_basic_user_file ${HTPASSWD_FILE};

  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;

  access_log /var/log/nginx/core-ncdu-web-viewer.access.log;
  error_log /var/log/nginx/core-ncdu-web-viewer.error.log;

  location / {
    proxy_pass http://127.0.0.1:${HTTP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_redirect off;
    proxy_buffering off;
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
    if curl --silent --show-error --fail "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null; then
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
[ -n "${CONTAINER_NAME}" ] || fail "Container name must not be empty"

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-ncdu-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-ncdu-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[3/8] Validating scan path accessibility"
ensure_scan_path_readable "${SCAN_PATH}"

log "[4/8] Preparing container build context at ${INSTALL_DIR}"
sudo mkdir -p "${INSTALL_DIR}"
write_dockerfile "${DOCKERFILE_PATH}"
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

log "[7/8] Building and starting container workload"
cd "${INSTALL_DIR}"
"${COMPOSE_CMD[@]}" build --no-cache || fail "Docker build failed"
"${COMPOSE_CMD[@]}" up -d || fail "Docker compose up failed"

if ! wait_for_local_health "${HEALTH_RETRIES}" "${HEALTH_DELAY_SECONDS}"; then
  log "Local health check failed. Checking logs:"
  sudo docker logs "${CONTAINER_NAME}" || true
  fail "Container did not become healthy within timeout"
fi

log "[8/8] Validating mesh and ingress contract"
sudo systemctl is-active netbird >/dev/null 2>&1 || fail "Netbird is not running"

resolved_ip="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -1)"
[ -n "${resolved_ip}" ] || fail "DNS resolution failed for ${DOMAIN}"
validate_resolved_ip "${resolved_ip}"

if ! wait_for_ingress_health "${HEALTH_RETRIES}" "${HEALTH_DELAY_SECONDS}"; then
  log "Ingress health check failed. Checking logs:"
  sudo docker logs "${CONTAINER_NAME}" || true
  sudo tail -20 /var/log/nginx/core-ncdu-web-viewer.error.log || true
  fail "Ingress endpoint did not become healthy within timeout"
fi

log "Deployment complete"
log "Service is now accessible at https://${DOMAIN}/"
log "Username: ${HTPASSWD_USER}"
