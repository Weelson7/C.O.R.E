#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Extra 4 - DOOM WASM (doom.core)

# Required runtime input:
# - NETBIRD_DEVICE_IP: expected NetBird-routed IP of this service for DNS validation

DOMAIN="doom.core"
DOMAIN_CERT_NAME="${DOMAIN}"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_SITE_FILE="/etc/nginx/sites-available/${DOMAIN}"
WEB_ROOT="/var/www/doom"
DOOM_SRC_DIR="${WEB_ROOT}/src"
DOOM_WAD="${DOOM_SRC_DIR}/doom1.wad"
EMSDK_VERSION="3.1.50"
EMSDK_DIR="/opt/emsdk"
WAD_URL="${WAD_URL:-https://www.pc-freak.net/files/doom-wad-files/Doom1.WAD}"

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
while [ -z "${NETBIRD_DEVICE_IP}" ]; do
	read -r -p "Enter NETBIRD_DEVICE_IP (required): " NETBIRD_DEVICE_IP
done

OWNER_USER="${SUDO_USER:-$(id -un)}"

echo "[1/6] Updating system and installing dependencies..."
sudo apt update -y
sudo apt install -y \
	nginx mkcert nginx-extras curl ca-certificates git wget \
	build-essential make automake autoconf libtool pkg-config \
	python3 xz-utils

echo "[2/6] Preparing cloudflare/doom-wasm under ${WEB_ROOT} and building with emsdk ${EMSDK_VERSION}..."
sudo mkdir -p "${WEB_ROOT}"
if [ ! -d "${WEB_ROOT}/.git" ]; then
	sudo git clone https://github.com/cloudflare/doom-wasm "${WEB_ROOT}"
else
	sudo git -C "${WEB_ROOT}" pull --ff-only
fi
sudo mkdir -p "${DOOM_SRC_DIR}"
sudo chown -R "${OWNER_USER}:${OWNER_USER}" "${WEB_ROOT}"

if [ ! -d "${EMSDK_DIR}/.git" ]; then
	sudo git clone https://github.com/emscripten-core/emsdk.git "${EMSDK_DIR}"
else
	sudo git -C "${EMSDK_DIR}" pull --ff-only
fi

sudo "${EMSDK_DIR}/emsdk" install "${EMSDK_VERSION}"
sudo "${EMSDK_DIR}/emsdk" activate --embedded "${EMSDK_VERSION}"

sudo -u "${OWNER_USER}" -H bash -lc "
	set -euo pipefail
	set +u
	source '${EMSDK_DIR}/emsdk_env.sh' >/dev/null
	set -u
	cd '${WEB_ROOT}'
	if [ ! -s '${DOOM_WAD}' ]; then
		wget -q -O '${DOOM_WAD}' '${WAD_URL}'
	fi
	if [ -f Makefile ]; then
		emmake make clean || true
	fi
	autoreconf -fiv
	EM_HOST=\"\$(emcc -dumpmachine 2>/dev/null || true)\"
	if [ -z \"\${EM_HOST}\" ]; then
		EM_HOST='none-none-none'
	fi
	if ! ac_cv_exeext='.html' emconfigure ./configure --host=\"\${EM_HOST}\"; then
		if [ \"\${EM_HOST}\" != 'none-none-none' ]; then
			echo 'Configure with emcc host failed, retrying legacy host none-none-none...'
			ac_cv_exeext='.html' emconfigure ./configure --host='none-none-none'
		else
			echo 'Configure failed for host none-none-none.'
			exit 1
		fi
	fi
	emmake make -j\"\$(nproc)\"
"

echo "[3/6] Creating self-signed certificate for ${DOMAIN}..."
mkcert -install
TMP_CERT_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_CERT_DIR}"' EXIT

mkcert \
	-cert-file "${TMP_CERT_DIR}/doom.crt" \
	-key-file "${TMP_CERT_DIR}/doom.key" \
	"${DOMAIN_CERT_NAME}"

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo install -m 644 "${TMP_CERT_DIR}/doom.crt" "${NGINX_SSL_DIR}/doom.crt"
sudo install -m 600 "${TMP_CERT_DIR}/doom.key" "${NGINX_SSL_DIR}/doom.key"
sudo chmod 600 "${NGINX_SSL_DIR}/doom.key"

echo "[4/6] Configuring nginx for ${DOMAIN} on ports 80 and 443..."
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

		ssl_certificate ${NGINX_SSL_DIR}/doom.crt;
		ssl_certificate_key ${NGINX_SSL_DIR}/doom.key;

		root ${DOOM_SRC_DIR};
		index index.html;

		location / {
				try_files \$uri \$uri/ =404;
		}

		location ~* \\.(wasm)$ {
				add_header Content-Type application/wasm;
		}

		add_header X-Frame-Options        "DENY"        always;
		add_header X-Content-Type-Options "nosniff"     always;
		add_header Referrer-Policy        "no-referrer" always;

		access_log /var/log/nginx/doom.access.log;
		error_log  /var/log/nginx/doom.error.log warn;
}
EOF

sudo ln -sf "${NGINX_SITE_FILE}" "/etc/nginx/sites-enabled/${DOMAIN}"
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

echo "[5/6] Applying web-root ownership and permissions..."
sudo chown -R www-data:www-data "${WEB_ROOT}"
sudo find "${DOOM_SRC_DIR}" -type f -exec chmod 644 {} \;
sudo find "${DOOM_SRC_DIR}" -type d -exec chmod 755 {} \;
echo "Build artifacts and doom1.wad are in place and permissions applied."

echo "[6/6] Verifying NetBird is already running and checking DNS..."
if ! command -v netbird >/dev/null 2>&1; then
	echo "Error: netbird command not found. This script assumes NetBird is pre-installed and connected."
	exit 1
fi

if ! sudo netbird status >/dev/null 2>&1; then
	echo "Error: NetBird appears to be installed but not connected/running."
	echo "Please bring NetBird up first, then rerun this deployment script."
	exit 1
fi

echo "NetBird is available and running."
echo "No local /etc/hosts rewrite is performed by this script."
echo "Configure DNS centrally in the NetBird admin console for ${DOMAIN}."

resolved_ip="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)"

if [ -n "${resolved_ip}" ]; then
	echo "Current DNS resolution: ${DOMAIN} -> ${resolved_ip}"
else
	echo "Warning: ${DOMAIN} did not resolve from this host."
	echo "Check NetBird DNS management settings and nameserver group policies."
fi

if [ "${resolved_ip:-}" = "${NETBIRD_DEVICE_IP}" ]; then
	echo "DNS validation passed: ${DOMAIN} resolves to expected NetBird IP ${NETBIRD_DEVICE_IP}."
else
	echo "Warning: expected ${NETBIRD_DEVICE_IP}, got ${resolved_ip:-<unresolved>}"
	echo "Update the DNS entry in NetBird so all peers resolve ${DOMAIN} consistently."
fi

echo ""
echo "Deployment finished."
echo "Check : https://${DOMAIN}"
echo "Logs  : sudo tail -n 50 /var/log/nginx/doom.error.log"
