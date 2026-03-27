#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 7 - C.O.R.E ttyd (ttyd.core)

# Snap + ingress architecture contract alignment:
# 1) dependency installation
# 2) snap runtime installation
# 3) runtime directory provisioning
# 4) systemd runtime definition generation
# 5) service activation + local health validation
# 6) TLS material provisioning
# 7) centralized ingress authentication and validation
# 8) mesh DNS and external health validation

SERVICE_NAME="core-ttyd"
DOMAIN="ttyd.core"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALL_DIR="/opt/core/ttyd"
ENV_FILE="${INSTALL_DIR}/ttyd.env"
SYSTEMD_UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
WEB_ROOT="/var/www/core-ttyd"
PUBLISHED_HTTP_PORT="${PUBLISHED_HTTP_PORT:-7681}"
TTYD_MAX_CLIENTS="${TTYD_MAX_CLIENTS:-10}"
TTYD_EXEC_CMD="${TTYD_EXEC_CMD:-/bin/bash}"
TTYD_WORKDIR="${TTYD_WORKDIR:-/C.O.R.E}"
TTYD_EXTRA_ARGS="${TTYD_EXTRA_ARGS:-}"
TTYD_BIN=""

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/${DOMAIN}.crt"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/${DOMAIN}.key"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_FILE="/etc/nginx/.htpasswd_core_ttyd"
HTPASSWD_PASSWORD="${HTPASSWD_PASSWORD:-}"
BRANDING_LOGO_SOURCE="${REPO_ROOT}/Docs/Branding/logo.png"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
NETBIRD_FAILOVER_IP="${NETBIRD_FAILOVER_IP:-}"
HTPASSWD_USER="${HTPASSWD_USER:-}"

log() {
  echo "[core-ttyd] $*"
}

fail() {
  echo "[core-ttyd] ERROR: $*" >&2
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

ensure_numeric_port() {
  if ! printf '%s' "${PUBLISHED_HTTP_PORT}" | grep -Eq '^[0-9]+$'; then
    fail "Invalid PUBLISHED_HTTP_PORT value: ${PUBLISHED_HTTP_PORT}"
  fi

  if [ "${PUBLISHED_HTTP_PORT}" -lt 1 ] || [ "${PUBLISHED_HTTP_PORT}" -gt 65535 ]; then
    fail "PUBLISHED_HTTP_PORT out of range (1-65535): ${PUBLISHED_HTTP_PORT}"
  fi
}

ensure_workdir_exists() {
  if [ -d "${TTYD_WORKDIR}" ]; then
    return 0
  fi

  log "Working directory ${TTYD_WORKDIR} does not exist; creating it"
  sudo mkdir -p "${TTYD_WORKDIR}"
}

normalize_ttyd_extra_args() {
  local cleaned

  cleaned="$(printf '%s' "${TTYD_EXTRA_ARGS}" | sed -E 's/(^|[[:space:]])(--readonly|-R|--writable|-W)([[:space:]]|$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [ "${cleaned}" != "${TTYD_EXTRA_ARGS}" ]; then
    log "Sanitized TTYD_EXTRA_ARGS by removing writable/readonly flags to enforce deploy policy"
  fi

  TTYD_EXTRA_ARGS="${cleaned}"
}

wait_for_local_ttyd_health() {
  local retries="${1:-30}"
  local delay_seconds="${2:-1}"
  local i
  local endpoint
  local status_code

  for i in $(seq 1 "${retries}"); do
    for endpoint in "http://127.0.0.1:${PUBLISHED_HTTP_PORT}/" "http://localhost:${PUBLISHED_HTTP_PORT}/"; do
      status_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "${endpoint}" 2>/dev/null || true)"
      case "${status_code}" in
        200|301|302|401|403)
          return 0
          ;;
      esac
    done
    sleep "${delay_seconds}"
  done

  return 1
}

assert_ttyd_runtime_is_writable() {
  local main_pid
  local cmdline

  main_pid="$(sudo systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null || true)"
  if ! printf '%s' "${main_pid}" | grep -Eq '^[0-9]+$' || [ "${main_pid}" -le 1 ]; then
    fail "Could not determine active ttyd process PID for ${SERVICE_NAME}"
  fi

  cmdline="$(sudo tr '\0' ' ' < "/proc/${main_pid}/cmdline" 2>/dev/null || true)"
  [ -n "${cmdline}" ] || fail "Could not read ttyd process command line for PID ${main_pid}"

  if ! printf '%s' "${cmdline}" | grep -Eq '(^|[[:space:]])(--writable|-W)([[:space:]]|$)'; then
    log "Active ttyd command line: ${cmdline}"
    fail "ttyd is running without --writable"
  fi

  if printf '%s' "${cmdline}" | grep -Eq '(^|[[:space:]])(--readonly|-R)([[:space:]]|$)'; then
    log "Active ttyd command line: ${cmdline}"
    fail "ttyd is running with --readonly"
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

resolve_ttyd_bin() {
  if command -v ttyd >/dev/null 2>&1; then
    TTYD_BIN="$(command -v ttyd)"
  elif [ -x "/snap/bin/ttyd" ]; then
    TTYD_BIN="/snap/bin/ttyd"
  else
    TTYD_BIN=""
  fi
}

install_ttyd_with_snap() {
  if ! command -v snap >/dev/null 2>&1; then
    sudo apt install -y snapd
  fi

  sudo systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  sudo systemctl restart snapd >/dev/null 2>&1 || true

  if sudo snap list ttyd >/dev/null 2>&1; then
    log "Snap package 'ttyd' already installed"
    return 0
  fi

  sudo snap install ttyd --classic
}

write_env_file() {
  sudo tee "${ENV_FILE}" >/dev/null <<EOF
TTYD_BIN=${TTYD_BIN}
PUBLISHED_HTTP_PORT=${PUBLISHED_HTTP_PORT}
TTYD_MAX_CLIENTS=${TTYD_MAX_CLIENTS}
TTYD_WORKDIR=${TTYD_WORKDIR}
TTYD_EXTRA_ARGS=${TTYD_EXTRA_ARGS}
TTYD_EXEC_CMD=${TTYD_EXEC_CMD}
EOF

  sudo chmod 600 "${ENV_FILE}"
}

write_systemd_unit() {
  sudo tee "${SYSTEMD_UNIT_FILE}" >/dev/null <<'EOF'
[Unit]
Description=C.O.R.E ttyd terminal gateway
After=network-online.target snapd.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/core/ttyd/ttyd.env
ExecStart=/bin/bash -lc 'exec "${TTYD_BIN}" --interface 127.0.0.1 --port "${PUBLISHED_HTTP_PORT}" --cwd "${TTYD_WORKDIR}" --check-origin --max-clients "${TTYD_MAX_CLIENTS}" ${TTYD_EXTRA_ARGS} --writable ${TTYD_EXEC_CMD}'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
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

    root ${WEB_ROOT};

    location = / {
      try_files /index.html =404;
    }

    location = /terminal {
      return 302 /terminal/;
    }

    location /terminal/ {
      proxy_pass         http://127.0.0.1:${PUBLISHED_HTTP_PORT}/;
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

    location / {
      try_files \$uri \$uri/ /index.html;
    }

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy        "same-origin" always;

    access_log /var/log/nginx/core-ttyd.access.log;
    error_log  /var/log/nginx/core-ttyd.error.log warn;
}

write_brand_shell() {
  sudo mkdir -p "${WEB_ROOT}"

  if [ -f "${BRANDING_LOGO_SOURCE}" ]; then
    sudo cp -f "${BRANDING_LOGO_SOURCE}" "${WEB_ROOT}/logo.png"
  elif [ -f "${REPO_ROOT}/src/1_Indexer/logo.png" ]; then
    sudo cp -f "${REPO_ROOT}/src/1_Indexer/logo.png" "${WEB_ROOT}/logo.png"
  fi

  sudo tee "${WEB_ROOT}/index.html" >/dev/null <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>C.O.R.E ttyd</title>
  <style>
    :root {
      --background-base: #080812;
      --background-elev-1: #0d0d1a;
      --background-elev-2: #130a2b;
      --surface-card: #1a0a3d;
      --surface-card-alt: #14082f;
      --primary-dark: #0d0d1a;
      --primary-medium: #1a0a3d;
      --accent-neon: #b44fff;
      --accent-shimmer: #d28bff;
      --accent-glow: rgba(180, 79, 255, 0.25);
      --text-primary: #f1e6ff;
      --text-secondary: #c8addf;
      --status-success: #39ff8a;
      --border-subtle: rgba(180, 79, 255, 0.25);
      --shadow-soft: 0 4px 20px rgba(0, 0, 0, 0.45);
    }

    * { box-sizing: border-box; }
    html, body { height: 100%; margin: 0; }

    body {
      font-family: "Inter", "Segoe UI", sans-serif;
      color: var(--text-primary);
      background:
        radial-gradient(1200px 700px at 85% -10%, rgba(180, 79, 255, 0.12), transparent 60%),
        radial-gradient(900px 500px at -10% 110%, rgba(122, 47, 181, 0.16), transparent 65%),
        linear-gradient(135deg, var(--background-base) 0%, var(--primary-medium) 100%);
    }

    .wrap {
      max-width: 1250px;
      margin: 0 auto;
      padding: 20px;
      display: grid;
      grid-template-rows: auto auto 1fr;
      gap: 14px;
      height: 100%;
    }

    .header {
      border: 1px solid var(--border-subtle);
      border-radius: 14px;
      background: linear-gradient(120deg, var(--primary-dark), var(--primary-medium));
      box-shadow: 0 0 24px var(--accent-glow), var(--shadow-soft);
      padding: 14px 18px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
    }

    .brand img {
      height: 36px;
      width: auto;
      display: block;
      filter: drop-shadow(0 0 8px rgba(180, 79, 255, 0.5));
    }

    .title {
      display: flex;
      flex-direction: column;
      gap: 3px;
      min-width: 0;
    }

    .title h1 {
      margin: 0;
      font-size: 16px;
      letter-spacing: 0.04em;
    }

    .title p {
      margin: 0;
      color: var(--text-secondary);
      font-size: 13px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .badge {
      font-family: "JetBrains Mono", "Consolas", monospace;
      font-size: 12px;
      color: var(--status-success);
      border: 1px solid var(--status-success);
      border-radius: 999px;
      padding: 4px 10px;
      background: rgba(57, 255, 138, 0.08);
    }

    .hint {
      font-family: "JetBrains Mono", "Consolas", monospace;
      font-size: 12px;
      color: var(--text-secondary);
      border: 1px solid var(--border-subtle);
      border-radius: 10px;
      background: linear-gradient(135deg, rgba(26, 10, 61, 0.62), rgba(13, 13, 26, 0.8));
      padding: 8px 10px;
    }

    .terminal-shell {
      border: 1px solid var(--border-subtle);
      border-radius: 14px;
      overflow: hidden;
      background: linear-gradient(135deg, var(--surface-card), var(--surface-card-alt));
      box-shadow: var(--shadow-soft);
      min-height: 0;
      display: grid;
    }

    iframe {
      border: 0;
      width: 100%;
      height: 100%;
      min-height: 440px;
      background: #05050c;
    }

    @media (max-width: 760px) {
      .wrap { padding: 12px; }
      .header { flex-direction: column; align-items: flex-start; }
      .title p { white-space: normal; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <header class="header">
      <div class="brand">
        <img src="/logo.png" alt="C.O.R.E logo" onerror="this.style.display='none'">
        <div class="title">
          <h1>C.O.R.E ttyd Gateway</h1>
          <p>Interactive terminal surface for mesh operators</p>
        </div>
      </div>
      <span class="badge">ONLINE</span>
    </header>

    <div class="hint">Access is secured by HTTP auth. Terminal IO is interactive and persisted via systemd service lifecycle.</div>

    <section class="terminal-shell">
      <iframe src="/terminal/" title="ttyd terminal" loading="eager"></iframe>
    </section>
  </div>
</body>
</html>
EOF

  sudo chown -R root:root "${WEB_ROOT}"
  sudo find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
  sudo find "${WEB_ROOT}" -type f -exec chmod 644 {} \;
}

ensure_ubuntu
require_cmd sudo
require_cmd apt
require_cmd getent
require_cmd awk
require_cmd grep

ensure_numeric_port
ensure_workdir_exists
ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (primary mesh IP expected for ${DOMAIN})"
ensure_value HTPASSWD_USER "Enter HTTP Basic Auth username for ${DOMAIN}"
ensure_secret_value HTPASSWD_PASSWORD "Enter HTTP Basic Auth password for ${HTPASSWD_USER}"

log "[1/8] Installing deployment dependencies"
sudo apt update -y
sudo apt install -y nginx mkcert apache2-utils curl ca-certificates

require_cmd mkcert
require_cmd nginx
require_cmd curl
require_cmd htpasswd

log "[2/8] Installing ttyd using snap"
install_ttyd_with_snap
resolve_ttyd_bin
[ -n "${TTYD_BIN}" ] || fail "ttyd installed but binary was not found"

log "[3/8] Provisioning runtime directories"
sudo mkdir -p "${INSTALL_DIR}"
write_brand_shell

log "[4/8] Writing and enabling systemd runtime for ttyd"
normalize_ttyd_extra_args
write_env_file
write_systemd_unit
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
sudo systemctl restart "${SERVICE_NAME}"

log "[5/8] Verifying local ttyd health"
service_state="$(sudo systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
[ "${service_state}" = "active" ] || fail "Service ${SERVICE_NAME} is not active"

assert_ttyd_runtime_is_writable

if ! wait_for_local_ttyd_health 45 1; then
  log "ttyd local health check did not pass in time; dumping diagnostics"
  sudo ss -lntp | grep -E "(:${PUBLISHED_HTTP_PORT}[[:space:]]|:${PUBLISHED_HTTP_PORT}$)" || true
  sudo journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
  fail "ttyd local health check failed"
fi

log "[6/8] Provisioning TLS material for ${DOMAIN}"
mkcert -install

tmp_cert="$(mktemp /tmp/core-ttyd-cert.XXXXXX.pem)"
tmp_key="$(mktemp /tmp/core-ttyd-key.XXXXXX.pem)"
mkcert -cert-file "${tmp_cert}" -key-file "${tmp_key}" "${DOMAIN}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${tmp_cert}" "${NGINX_CERT_FILE}"
sudo mv -f "${tmp_key}" "${NGINX_KEY_FILE}"
sudo chmod 640 "${NGINX_CERT_FILE}"
sudo chmod 600 "${NGINX_KEY_FILE}"

log "[7/8] Writing and validating Nginx ingress for ${DOMAIN}"
if [ ! -f "${HTPASSWD_FILE}" ]; then
  sudo htpasswd -cb "${HTPASSWD_FILE}" "${HTPASSWD_USER}" "${HTPASSWD_PASSWORD}"
else
  sudo htpasswd -b "${HTPASSWD_FILE}" "${HTPASSWD_USER}" "${HTPASSWD_PASSWORD}"
fi

write_nginx_site
sudo ln -sfn "${NGINX_SITE_FILE}" "${NGINX_SITE_LINK}"
sudo nginx -t
sudo systemctl restart nginx

log "[8/8] Verifying mesh DNS and ingress runtime health"
resolved_ip="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -n1)"
[ -n "${resolved_ip}" ] || fail "DNS resolution failed for ${DOMAIN}"
validate_resolved_ip "${resolved_ip}"

curl --silent --show-error --fail --insecure \
  --resolve "${DOMAIN}:443:${NETBIRD_DEVICE_IP}" \
  --user "${HTPASSWD_USER}:${HTPASSWD_PASSWORD}" \
  "https://${DOMAIN}/" >/dev/null || fail "Ingress health check failed on https://${DOMAIN}/"

echo
log "Deployment complete"
log "Service status: sudo systemctl status ${SERVICE_NAME}"
log "Service logs: sudo journalctl -u ${SERVICE_NAME} -f"
log "Ingress check: curl -k -u <user>:<password> https://${DOMAIN}/"
