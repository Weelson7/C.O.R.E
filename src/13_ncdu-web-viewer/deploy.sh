#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 13 - C.O.R.E ncdu-web-viewer (ncdu.core)

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) TLS material provisioning
# 3) scan path validation
# 4) container build context preparation
# 5) ingress configuration and auth
# 6) container activation
# 7) DNS resolution verification
# 8) runtime health confirmation

DOMAIN="ncdu.core"
SERVICE_NAME="core-ncdu-web-viewer"
INSTALL_DIR="/opt/core/ncdu-web-viewer"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
DOCKERFILE_PATH="${INSTALL_DIR}/Dockerfile"
PYTHON_APP_PATH="${INSTALL_DIR}/ncdu_http.py"

HTTP_PORT="${HTTP_PORT:-3030}"
SCAN_PATH="${SCAN_PATH:-/}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-3600}"
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

# FIX: write the Python app as a standalone file so the Dockerfile can COPY it.
# Previously the script embedded the Python source inside a bash heredoc inside
# a Dockerfile RUN heredoc — a nested-heredoc construct that requires BuildKit
# and breaks on Docker < 23.  Writing the file separately eliminates that
# fragility entirely.
write_python_app() {
  local target="$1"

  sudo tee "${target}" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
"""
C.O.R.E ncdu-web-viewer
Runs ncdu in the background, exports its JSON, and serves an interactive
disk-usage tree over HTTP.

Endpoints:
  GET /          — HTML tree viewer UI
  GET /data      — raw ncdu JSON (202 while scan is in progress)
  GET /health    — {"status":"ok"} once the first scan has completed,
                   {"status":"scanning"} while the initial scan is running
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

SCAN_PATH = "/mnt/scan"
PORT = int(os.getenv("PORT", "3030"))
REFRESH_INTERVAL = int(os.getenv("REFRESH_INTERVAL", "3600"))

# Shared scan state
_lock = threading.Lock()
_state = {
    "status": "scanning",   # "scanning" | "ok" | "error"
    "data": None,           # raw ncdu JSON string
    "error": None,
    "scanned_at": None,
}


def _scan_loop():
    """Background thread: run ncdu periodically and update shared state."""
    while True:
        try:
            proc = subprocess.run(
        ["ncdu", "-0", "-x", "--ignore-config", "-o", "-", SCAN_PATH],
                capture_output=True,
                text=True,
                timeout=7200,
            )
            with _lock:
                if proc.returncode == 0:
                    _state["status"] = "ok"
                    _state["data"] = proc.stdout
                    _state["error"] = None
                    _state["scanned_at"] = time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
                    )
                else:
                    _state["status"] = "error"
                    _state["data"] = None
                    _state["error"] = proc.stderr.strip() or "ncdu exited non-zero"
        except subprocess.TimeoutExpired:
            with _lock:
                _state["status"] = "error"
                _state["error"] = "ncdu scan timed out after 7200 seconds"
        except Exception as exc:  # noqa: BLE001
            with _lock:
                _state["status"] = "error"
                _state["error"] = str(exc)

        time.sleep(REFRESH_INTERVAL)


_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>ncdu-web-viewer &mdash; C.O.R.E</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{background:#1a1a1a;color:#e0e0e0;font-family:monospace;font-size:14px;padding:1.5rem}
    h1{color:#4fc3f7;margin-bottom:.25rem;font-size:1.25rem}
    #meta{color:#888;margin-bottom:1rem;font-size:.85rem}
    #status{color:#ffd54f;margin:1rem 0}
    #tree{margin-top:.5rem}
    .row{display:flex;align-items:center;padding:3px 0;border-bottom:1px solid #2a2a2a;cursor:pointer}
    .row:hover{background:#2a2a2a}
    .bar-wrap{width:160px;flex-shrink:0;background:#333;height:10px;border-radius:3px;margin-right:10px}
    .bar{background:#4fc3f7;height:10px;border-radius:3px;transition:width .2s}
    .size{width:80px;flex-shrink:0;text-align:right;margin-right:12px;color:#a5d6a7}
    .name{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .dir{color:#ffd54f}
    .icon{margin-right:5px;font-size:.9em;user-select:none}
    .children{padding-left:20px}
    .collapsed > .children{display:none}
    .path-bar{color:#888;font-size:.8rem;margin-bottom:.5rem;word-break:break-all}
  </style>
</head>
<body>
  <h1>&#128202; C.O.R.E &mdash; ncdu-web-viewer</h1>
  <div id="meta">Scan path: <code>/mnt/scan</code></div>
  <div id="status">Loading scan data&hellip;</div>
  <div id="tree"></div>
  <script>
  const fmt = (bytes) => {
    const u = ['B','KiB','MiB','GiB','TiB'];
    let i = 0, v = bytes;
    while(v >= 1024 && i < u.length-1){v/=1024;i++}
    return v.toFixed(i?1:0)+'\u00a0'+u[i];
  };

  // Parse ncdu JSON: [1, 0, {meta}, <dir_node>]
  // dir_node: [{name,...}, child, child, ...]
  // child: either an object (file) or an array (subdir, same structure)
  function parseDir(node) {
    const [info, ...children] = node;
    const entries = children.map(c => {
      if (Array.isArray(c)) {
        const sub = parseDir(c);
        return { ...sub, isDir: true };
      }
      return { name: c.name, dsize: c.dsize ?? c.asize ?? 0, isDir: false };
    });
    entries.sort((a,b) => b.dsize - a.dsize);
    const dsize = info.dsize ?? info.asize ?? entries.reduce((s,e)=>s+e.dsize,0);
    return { name: info.name, dsize, isDir: true, children: entries };
  }

  function buildNode(entry, maxSize) {
    const div = document.createElement('div');
    div.className = 'row' + (entry.isDir ? ' dir-row' : '');

    const pct = maxSize > 0 ? Math.round(entry.dsize / maxSize * 100) : 0;
    div.innerHTML =
      '<div class="bar-wrap"><div class="bar" style="width:'+pct+'%"></div></div>' +
      '<div class="size">'+fmt(entry.dsize)+'</div>' +
      '<div class="name '+(entry.isDir?'dir':'')+'">' +
        '<span class="icon">'+(entry.isDir?'&#128193;':'&#128196;')+'</span>' +
        escHtml(entry.name) +
      '</div>';

    if (entry.isDir && entry.children && entry.children.length) {
      const wrap = document.createElement('div');
      wrap.className = 'dir-entry collapsed';

      const childWrap = document.createElement('div');
      childWrap.className = 'children';

      const childMax = entry.children[0]?.dsize ?? 0;
      entry.children.forEach(c => childWrap.appendChild(buildNode(c, childMax)));

      wrap.appendChild(div);
      wrap.appendChild(childWrap);

      div.addEventListener('click', () => wrap.classList.toggle('collapsed'));
      return wrap;
    }

    return div;
  }

  function escHtml(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  async function load() {
    const statusEl = document.getElementById('status');
    const treeEl = document.getElementById('tree');
    const metaEl = document.getElementById('meta');

    try {
      const res = await fetch('/data');
      if (res.status === 202) {
        statusEl.textContent = 'Scan in progress\u2026 refreshing in 10 s';
        setTimeout(load, 10000);
        return;
      }
      if (!res.ok) {
        const err = await res.json().catch(()=>({error:'unknown error'}));
        statusEl.textContent = 'Scan error: ' + (err.error || res.statusText);
        setTimeout(load, 15000);
        return;
      }

      const raw = await res.json();
      // raw is: [1, 0, {meta}, rootDir]
      const meta = raw[2] ?? {};
      const rootNode = parseDir(raw[3]);

      const ts = meta.timestamp
        ? new Date(meta.timestamp * 1000).toLocaleString()
        : 'unknown';
      metaEl.innerHTML =
        'Scan path: <code>/mnt/scan</code> &nbsp;|&nbsp; ' +
        'ncdu ' + (meta.progver ?? '?') + ' &nbsp;|&nbsp; ' +
        'Scanned at: ' + ts;
      statusEl.textContent = '';

      treeEl.innerHTML = '';
      const maxSize = rootNode.children[0]?.dsize ?? 0;
      rootNode.children.forEach(c => treeEl.appendChild(buildNode(c, maxSize)));

      // Auto-refresh after REFRESH_INTERVAL (passed via data attribute)
      const ri = parseInt(document.body.dataset.refresh || '3600', 10);
      setTimeout(load, ri * 1000);

    } catch(e) {
      statusEl.textContent = 'Failed to load: ' + e.message;
      setTimeout(load, 10000);
    }
  }

  document.body.dataset.refresh = '""" + str(REFRESH_INTERVAL) + """';
  load();
  </script>
</body>
</html>
"""


class NCDUHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/health":
            with _lock:
                status = _state["status"]
            if status == "scanning":
                self._send_json(202, {"status": "scanning"})
            elif status == "ok":
                self._send_json(200, {"status": "ok", "scanned_at": _state["scanned_at"]})
            else:
                self._send_json(500, {"status": "error", "error": _state["error"]})

        elif path == "/data":
            with _lock:
                state = dict(_state)
            if state["status"] == "scanning":
                self._send_json(202, {"status": "scanning"})
            elif state["status"] == "error":
                self._send_json(500, {"status": "error", "error": state["error"]})
            else:
                body = state["data"].encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        elif path == "/":
            # Embed REFRESH_INTERVAL into the HTML at serve time
            body = _HTML.replace(
                'document.body.dataset.refresh = \'""" + str(REFRESH_INTERVAL) + """\';',
                f"document.body.dataset.refresh = '{REFRESH_INTERVAL}';",
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # noqa: N802
        pass  # suppress per-request stdout noise


if __name__ == "__main__":
    t = threading.Thread(target=_scan_loop, daemon=True)
    t.start()
    print(f"ncdu HTTP server listening on 0.0.0.0:{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), NCDUHandler).serve_forever()
PYEOF
  sudo chmod 644 "${target}"
}

# FIX: Dockerfile no longer embeds the Python source via a nested heredoc.
# It simply COPYs the pre-written file, which works on all Docker versions.
# Also fixed:
#   - ENTRYPOINT now explicitly invokes python3 (exec form + shebang is fragile)
#   - python3-requests removed (was never used)
#   - WORKDIR removed (served no purpose; entrypoint uses absolute paths)
write_dockerfile() {
  local target="$1"

  sudo tee "${target}" >/dev/null <<'EOF'
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ncdu \
    python3-minimal \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

COPY ncdu_http.py /app/ncdu_http.py

ENTRYPOINT ["python3", "/app/ncdu_http.py"]
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
      - REFRESH_INTERVAL=${REFRESH_INTERVAL}
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
    proxy_read_timeout 120s;
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

# FIX: health check now waits for /health to report 200 so deployment only
# completes after the first full export is ready to render.
wait_for_local_health() {
  local retries="${1:-30}"
  local delay="${2:-2}"
  local i http_code

  for i in $(seq 1 "${retries}"); do
    http_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      "http://127.0.0.1:${HTTP_PORT}/health" || true)"
    if [ "${http_code}" = "200" ]; then
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

# ── main ──────────────────────────────────────────────────────────────────────

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
# FIX: write Python app first so the Dockerfile COPY instruction can find it
write_python_app "${PYTHON_APP_PATH}"
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
log "  Username : ${HTPASSWD_USER}"
log "  Scan path: ${SCAN_PATH} (refreshes every ${REFRESH_INTERVAL}s)"
log "  Note: first scan may still be in progress — check /health for status"