#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Extra 4 - DOOM WASM (doom.zenith.su)

# Required runtime input:
# - NETBIRD_DEVICE_IP: expected NetBird-routed IP of this service for DNS validation

DOMAIN="doom.zenith.su"
DOMAIN_CERT_NAME="doom.zenith.su"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_SITE_FILE="/etc/nginx/sites-available/doom.zenith.su"
WEB_ROOT="/var/www/doom"
DOOM_SRC_DIR="/var/www/doom/src"
DOOM_WAD="${DOOM_SRC_DIR}/doom1.wad"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

lookup_generated_file() {
	local target_name="$1"
	local candidate=""

	for base_dir in "$(pwd)" "${SCRIPT_DIR}" "${HOME}"; do
		if [ -f "${base_dir}/${target_name}" ]; then
			echo "${base_dir}/${target_name}"
			return 0
		fi
	done

	candidate="$(find "$(pwd)" "${SCRIPT_DIR}" "${HOME}" -maxdepth 3 -type f -name "${target_name}" 2>/dev/null | head -n 1 || true)"
	if [ -n "${candidate}" ]; then
		echo "${candidate}"
		return 0
	fi

	return 1
}

NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
while [ -z "${NETBIRD_DEVICE_IP}" ]; do
	read -r -p "Enter NETBIRD_DEVICE_IP (required): " NETBIRD_DEVICE_IP
done

POLL_SECONDS="${POLL_SECONDS:-10}"

echo "[1/6] Updating system and installing dependencies..."
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y nginx mkcert nginx-extras openssl curl ca-certificates git wget

echo "[2/6] Preparing cloudflare/doom-wasm under ${WEB_ROOT}..."
sudo mkdir -p "${WEB_ROOT}"
if [ ! -d "${WEB_ROOT}/.git" ]; then
	sudo git clone https://github.com/cloudflare/doom-wasm "${WEB_ROOT}"
else
	sudo git -C "${WEB_ROOT}" pull --ff-only
fi
sudo mkdir -p "${DOOM_SRC_DIR}"

echo "[3/6] Creating self-signed certificate for ${DOMAIN}..."
mkcert -install
mkcert "${DOMAIN_CERT_NAME}"

cert_src="$(lookup_generated_file "${DOMAIN_CERT_NAME}.pem" || true)"
key_src="$(lookup_generated_file "${DOMAIN_CERT_NAME}-key.pem" || true)"

if [ -z "${cert_src}" ] || [ -z "${key_src}" ]; then
	echo "Error: Could not locate mkcert output files for ${DOMAIN_CERT_NAME}."
	echo "Expected files: ${DOMAIN_CERT_NAME}.pem and ${DOMAIN_CERT_NAME}-key.pem"
	exit 1
fi

sudo mkdir -p "${NGINX_SSL_DIR}"
sudo mv -f "${cert_src}" "${NGINX_SSL_DIR}/doom.crt"
sudo mv -f "${key_src}" "${NGINX_SSL_DIR}/doom.key"
sudo chmod 600 "${NGINX_SSL_DIR}/doom.key"

echo "[4/6] Configuring nginx for ${DOMAIN} on ports 80 and 443..."
sudo tee "${NGINX_SITE_FILE}" >/dev/null <<EOF
server {
		listen 80;
		listen [::]:80;
		server_name ${DOMAIN};
		proxy_ssl_verify off;
		return 301 https://\$host\$request_uri;
}

server {
		listen 443 ssl;
		listen [::]:443 ssl;
		server_name ${DOMAIN};
		proxy_ssl_verify off;

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

sudo ln -sf "${NGINX_SITE_FILE}" /etc/nginx/sites-enabled/doom.zenith.su
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

echo "[5/6] Awaiting manual transfer of doom1.wad..."
OWNER_USER="${SUDO_USER:-$(id -un)}"
sudo chown -R "${OWNER_USER}:${OWNER_USER}" /var/www/doom/src
sudo chmod -R 755 /var/www/doom/src
echo "Please run the following commands on your x64/x86 laptop with wsl installed:"
echo "sudo apt install emscripten automake autoconf make libsdl2-dev libsdl2-mixer-dev libsdl2-net-dev"
echo "cd ~"
echo "git clone https://github.com/emscripten-core/emsdk.git"
echo "cd emsdk"
echo "./emsdk install 3.1.50"
echo "./emsdk activate 3.1.50"
echo "source ./emsdk_env.sh"
echo "git clone https://github.com/cloudflare/doom-wasm ~/doom-wasm"
echo "cd ~/doom-wasm"
echo "wget https://www.pc-freak.net/files/doom-wad-files/Doom1.WAD -O src/doom1.wad"
echo "sudo ./scripts/clean.sh"
echo "sudo ./scripts/build.sh"
echo "rsync -av ~/doom-wasm/src/ pi@${NETBIRD_DEVICE_IP}:/var/www/doom/src/"

echo "This script will keep scanning until the file appears."
while [ ! -s "${DOOM_WAD}" ]; do
	echo "Waiting... ${DOOM_WAD} not found yet (next check in ${POLL_SECONDS}s)."
	sleep "${POLL_SECONDS}"
done

sudo chown -R www-data:www-data "${WEB_ROOT}"
sudo find /var/www/doom/src -type f -exec chmod 644 {} \;
sudo find /var/www/doom/src -type d -exec chmod 755 {} \;
echo "doom1.wad detected and web root permissions applied."

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
