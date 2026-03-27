#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 2 - C.O.R.E AdGuard Home (dns.core)

# Required runtime input:
# - NETBIRD_DEVICE_IP: target IP used for default DNS rewrites

# Containerized architecture contract alignment:
# 1) dependency installation
# 2) single-node runtime mode
# 3) AdGuard Home download
# 4) container image build + runtime activation
# 5) setup wizard completion gate with live port scans
# 6) DNS rewrite capture and per-entry validation loops
# 7) runtime and configuration validation

SERVICE_NAME="core-adguard"
IMAGE_TAG="core/adguard:local"
INSTALL_DIR="/opt/core/adguard"
BUILD_DIR="${INSTALL_DIR}/build"
WORK_DIR="${INSTALL_DIR}/work"
CONF_DIR="${INSTALL_DIR}/conf"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
ADGUARD_VERSION="${ADGUARD_VERSION:-v0.107.59}"
ADGUARD_RELEASE_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${ADGUARD_VERSION}/AdGuardHome_linux_amd64.tar.gz"
ADMIN_PANEL_PORT="${ADMIN_PANEL_PORT:-8080}"
ADGUARD_ADMIN_CONTAINER_PORT="${ADGUARD_ADMIN_CONTAINER_PORT:-3000}"
ADGUARD_FALLBACK_PANEL_PORT="${ADGUARD_FALLBACK_PANEL_PORT:-3000}"
ADGUARD_DNS_PORT="${ADGUARD_DNS_PORT:-54}"
PUBLISH_HTTPS_PORT="${PUBLISH_HTTPS_PORT:-false}"
ADGUARD_HTTPS_PORT="${ADGUARD_HTTPS_PORT:-443}"
ALLOW_UFW_ADMIN_PORT="${ALLOW_UFW_ADMIN_PORT:-true}"
KEEP_NETBIRD_DNS_ON_53="${KEEP_NETBIRD_DNS_ON_53:-true}"
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"
COMPOSE_CMD=()
NETBIRD_DEVICE_IP="${NETBIRD_DEVICE_IP:-}"
ADGUARD_ADMIN_USER="${ADGUARD_ADMIN_USER:-}"
ADGUARD_ADMIN_PASSWORD="${ADGUARD_ADMIN_PASSWORD:-}"

DEFAULT_REWRITE_DOMAINS=(
	"index.core"
	"dns.core"
	"jellyfin.core"
	"suwayomi.core"
	"kasm.core"
	"crafty.core"
	"ttyd.core"
	"qbittorrent.core"
	"jupyter.core"
	"stirling.core"
	"doom.zenith.su"
	"supervisor.core"
)

declare -a REWRITE_HOSTS=()
declare -a REWRITE_IPS=()

log() {
	echo "[core-adguard] $*"
}

fail() {
	echo "[core-adguard] ERROR: $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
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

is_port_listening_tcp() {
	local port="$1"
	ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

is_port_listening_udp() {
	local port="$1"
	ss -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

disable_systemd_resolved_stub_listener() {
	if [ "${ADGUARD_DNS_PORT}" != "53" ]; then
		log "Skipping systemd-resolved DNSStubListener changes because ADGUARD_DNS_PORT=${ADGUARD_DNS_PORT}"
		return 0
	fi

	local dropin_dir="/etc/systemd/resolved.conf.d"
	local dropin_file="${dropin_dir}/99-core-adguard.conf"

	if ! systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
		log "systemd-resolved service not found; skipping DNS stub listener tuning"
		return 0
	fi

	log "Disabling systemd-resolved DNSStubListener to free host port 53"
	sudo mkdir -p "${dropin_dir}"
	sudo tee "${dropin_file}" >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF

	sudo systemctl restart systemd-resolved
	sleep 1

	if is_port_listening_tcp 53 || is_port_listening_udp 53; then
		log "Port 53 is still in use after systemd-resolved restart; another service may be bound to it"
	fi
}

is_netbird_bound_to_port_53() {
	sudo ss -luntp 2>/dev/null | grep -E '(:53[[:space:]]|:53$)' | grep -qi 'netbird'
}

disable_netbird_dns_usage() {
	if [ "${KEEP_NETBIRD_DNS_ON_53}" = "true" ]; then
		log "Keeping NetBird DNS on port 53 (KEEP_NETBIRD_DNS_ON_53=true)"
		return 0
	fi

	if ! command -v netbird >/dev/null 2>&1; then
		return 0
	fi

	if ! sudo netbird status >/dev/null 2>&1; then
		return 0
	fi

	if ! is_netbird_bound_to_port_53; then
		return 0
	fi

	log "NetBird is bound to port 53; reconfiguring NetBird with DNS disabled"
	sudo netbird down >/dev/null 2>&1 || true
	if ! sudo netbird up --disable-dns; then
		fail "Failed to restart NetBird with --disable-dns"
	fi

	sleep 1
	if is_netbird_bound_to_port_53; then
		log "NetBird still appears bound to port 53 after --disable-dns; forcing DNS resolver to 127.0.0.1:22053"
		sudo netbird down >/dev/null 2>&1 || true
		if ! sudo netbird up --dns-resolver-address 127.0.0.1:22053; then
			fail "Failed to restart NetBird with --dns-resolver-address 127.0.0.1:22053"
		fi

		sleep 1
		if is_netbird_bound_to_port_53; then
			fail "NetBird still appears bound to port 53 after resolver port override"
		fi
	fi
}

scan_runtime_ports() {
	local panel_ok="no"
	local dns_tcp_ok="no"
	local dns_udp_ok="no"

	if is_port_listening_tcp "${ADMIN_PANEL_PORT}"; then
		panel_ok="yes"
	fi

	if is_port_listening_tcp "${ADGUARD_DNS_PORT}"; then
		dns_tcp_ok="yes"
	fi

	if is_port_listening_udp "${ADGUARD_DNS_PORT}"; then
		dns_udp_ok="yes"
	fi

	log "Scan: tcp/${ADMIN_PANEL_PORT}=${panel_ok}, tcp/${ADGUARD_DNS_PORT}=${dns_tcp_ok}, udp/${ADGUARD_DNS_PORT}=${dns_udp_ok}"
}

query_dns_a() {
	local host="$1"

	dig +time=2 +tries=1 +short @127.0.0.1 -p "${ADGUARD_DNS_PORT}" "${host}" A 2>/dev/null | awk 'NF {print; exit}'
}

download_adguard_home() {
	log "Downloading AdGuard Home ${ADGUARD_VERSION}"
	sudo mkdir -p "${BUILD_DIR}"
	sudo rm -rf "${BUILD_DIR}/AdGuardHome" "${BUILD_DIR}/AdGuardHome_linux_amd64.tar.gz"

	curl -fsSL "${ADGUARD_RELEASE_URL}" -o /tmp/core-adguard.tar.gz
	sudo mv /tmp/core-adguard.tar.gz "${BUILD_DIR}/AdGuardHome_linux_amd64.tar.gz"

	sudo tar -xzf "${BUILD_DIR}/AdGuardHome_linux_amd64.tar.gz" -C "${BUILD_DIR}"
	[ -x "${BUILD_DIR}/AdGuardHome/AdGuardHome" ] || fail "AdGuardHome binary missing after extraction"
}

write_dockerfile() {
	sudo tee "${BUILD_DIR}/Dockerfile" >/dev/null <<'EOF'
FROM debian:bookworm-slim

RUN apt-get update \
		&& apt-get install -y --no-install-recommends ca-certificates \
		&& rm -rf /var/lib/apt/lists/*

WORKDIR /opt/adguardhome
COPY AdGuardHome/ ./

RUN chmod +x /opt/adguardhome/AdGuardHome

EXPOSE 53/tcp 53/udp 67/udp 68/tcp 68/udp 8080/tcp 3000/tcp 443/tcp

ENTRYPOINT ["/opt/adguardhome/AdGuardHome"]
CMD ["-c", "/opt/adguardhome/conf/AdGuardHome.yaml", "-w", "/opt/adguardhome/work"]
EOF
}

write_compose_file() {
	{
		printf '%s\n' \
			"services:" \
			"  adguard:" \
			"    container_name: ${SERVICE_NAME}" \
			"    image: ${IMAGE_TAG}" \
			"    restart: unless-stopped" \
			"    ports:" \
			"      - \"${ADGUARD_DNS_PORT}:53/tcp\"" \
			"      - \"${ADGUARD_DNS_PORT}:53/udp\"" \
			"      - \"${ADMIN_PANEL_PORT}:${ADGUARD_ADMIN_CONTAINER_PORT}/tcp\""
		if [ "${ADGUARD_FALLBACK_PANEL_PORT}" != "${ADMIN_PANEL_PORT}" ]; then
			echo "      - \"${ADGUARD_FALLBACK_PANEL_PORT}:${ADGUARD_ADMIN_CONTAINER_PORT}/tcp\""
		fi
		if [ "${PUBLISH_HTTPS_PORT}" = "true" ]; then
			echo "      - \"${ADGUARD_HTTPS_PORT}:443/tcp\""
		fi
		printf '%s\n' \
			"    volumes:" \
			"      - ${WORK_DIR}:/opt/adguardhome/work" \
			"      - ${CONF_DIR}:/opt/adguardhome/conf"
	} | sudo tee "${COMPOSE_FILE}" >/dev/null
}

open_firewall_admin_port() {
	if [ "${ALLOW_UFW_ADMIN_PORT}" != "true" ]; then
		return 0
	fi

	if ! command -v ufw >/dev/null 2>&1; then
		return 0
	fi

	if ! sudo ufw status 2>/dev/null | grep -qi '^status:[[:space:]]*active'; then
		return 0
	fi

	log "UFW is active; allowing tcp/${ADMIN_PANEL_PORT} for AdGuard admin access"
	sudo ufw allow "${ADMIN_PANEL_PORT}/tcp" >/dev/null || true
	if [ "${ADGUARD_FALLBACK_PANEL_PORT}" != "${ADMIN_PANEL_PORT}" ]; then
		sudo ufw allow "${ADGUARD_FALLBACK_PANEL_PORT}/tcp" >/dev/null || true
	fi
}

sync_admin_panel_bind_from_config() {
	local config_file="${CONF_DIR}/AdGuardHome.yaml"
	local configured_port=""

	[ -f "${config_file}" ] || return 0

	if sudo grep -Eq '^[[:space:]]*bind_host:[[:space:]]*(127\.0\.0\.1|localhost)[[:space:]]*$' "${config_file}"; then
		log "AdGuard bind_host is loopback; forcing bind_host to 0.0.0.0 for NetBird reachability"
		sudo sed -E -i 's/^([[:space:]]*bind_host:[[:space:]]*)(127\.0\.0\.1|localhost)[[:space:]]*$/\10.0.0.0/' "${config_file}"
	fi

	if sudo grep -Eq '^[[:space:]]*address:[[:space:]]*("|\x27)?(127\.0\.0\.1|localhost):[0-9]+("|\x27)?[[:space:]]*$' "${config_file}"; then
		log "AdGuard address is loopback; forcing address host to 0.0.0.0"
		sudo sed -E -i 's/^([[:space:]]*address:[[:space:]]*)("|\x27)?(127\.0\.0\.1|localhost):([0-9]+)("|\x27)?[[:space:]]*$/\10.0.0.0:\4/' "${config_file}"
	fi

	configured_port="$(sudo awk '
		/^[[:space:]]*bind_port:[[:space:]]*[0-9]+[[:space:]]*$/ {
			print $2; exit
		}
		/^[[:space:]]*address:[[:space:]]*/ {
			line=$0
			sub(/^[[:space:]]*address:[[:space:]]*/, "", line)
			gsub(/"|\x27/, "", line)
			n=split(line, parts, ":")
			if (n >= 2 && parts[n] ~ /^[0-9]+$/) {
				print parts[n]; exit
			}
		}
	' "${config_file}" 2>/dev/null || true)"

	if printf '%s' "${configured_port}" | grep -Eq '^[0-9]+$' && [ "${configured_port}" != "${ADGUARD_ADMIN_CONTAINER_PORT}" ]; then
		log "Detected AdGuard admin port ${configured_port}; updating container port mapping"
		ADGUARD_ADMIN_CONTAINER_PORT="${configured_port}"
	fi
}

cleanup_previous_runtime() {
	log "Cleaning previous AdGuard runtime artifacts"

	if [ -f "${COMPOSE_FILE}" ]; then
		"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
	fi

	sudo docker rm -f "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

wait_for_admin_panel_http() {
	local attempt=1
	local max_attempts=20

	while [ "${attempt}" -le "${max_attempts}" ]; do
		if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}"; then
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done

	log "AdGuard panel is not reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}"
	log "Container logs (last 80 lines):"
	sudo docker logs --tail 80 "${SERVICE_NAME}" || true
	fail "Setup wizard endpoint is unavailable"
}

sync_admin_panel_mapping_from_config() {
	sync_admin_panel_bind_from_config
	write_compose_file
	"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate
	sleep 2
}

start_single() {
	log "Building image and starting single-node container"
	cleanup_previous_runtime
	sync_admin_panel_bind_from_config
	sudo docker build -t "${IMAGE_TAG}" "${BUILD_DIR}"
	write_compose_file
	"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" config >/dev/null || fail "Generated compose file is invalid: ${COMPOSE_FILE}"

	"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate

	local state
	state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
	[ "${state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

	open_firewall_admin_port
	wait_for_admin_panel_http
}

wait_for_setup_completion() {
	local answer=""
	local panel_http_ok=0

	log "Waiting for setup completion"
	log "Open http://localhost:${ADMIN_PANEL_PORT} and complete the AdGuard Home setup wizard."
	log "Ensure DNS is enabled in AdGuard; host publishes DNS on port ${ADGUARD_DNS_PORT} (tcp+udp)."

	while true; do
		scan_runtime_ports

		panel_http_ok=0
		if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}"; then
			panel_http_ok=1
		fi

		read -r -p "Have you completed setup and saved settings? [y/N]: " answer
		case "$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')" in
			y|yes)
				if [ "${panel_http_ok}" -ne 1 ]; then
					sync_admin_panel_mapping_from_config
					if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}"; then
						panel_http_ok=1
					fi
				fi

				if [ "${panel_http_ok}" -ne 1 ]; then
					log "Control panel is not reachable on localhost:${ADMIN_PANEL_PORT} yet."
					continue
				fi

				if ! is_port_listening_tcp "${ADGUARD_DNS_PORT}" || ! is_port_listening_udp "${ADGUARD_DNS_PORT}"; then
					log "Port ${ADGUARD_DNS_PORT} is not listening on both tcp and udp yet."
					continue
				fi

				log "Setup gate passed."
				break
				;;
			*)
				log "Setup pending. Re-scanning in 5 seconds."
				sleep 5
				;;
		esac
	done
}

load_default_rewrite_targets() {
	local host

	REWRITE_HOSTS=()
	REWRITE_IPS=()

	for host in "${DEFAULT_REWRITE_DOMAINS[@]}"; do
		REWRITE_HOSTS+=("${host}")
		REWRITE_IPS+=("${NETBIRD_DEVICE_IP}")
	done
}

apply_rewrites_via_api() {
	local idx
	local host
	local ip
	local payload

	ensure_value ADGUARD_ADMIN_USER "Enter AdGuard admin username (for rewrite API)"
	ensure_secret_value ADGUARD_ADMIN_PASSWORD "Enter AdGuard admin password (for rewrite API)"

	log "Applying default DNS rewrites through AdGuard API"
	for idx in "${!REWRITE_HOSTS[@]}"; do
		host="${REWRITE_HOSTS[${idx}]}"
		ip="${REWRITE_IPS[${idx}]}"
		payload="{\"domain\":\"${host}\",\"answer\":\"${ip}\"}"

		if ! curl --silent --show-error --fail \
			-u "${ADGUARD_ADMIN_USER}:${ADGUARD_ADMIN_PASSWORD}" \
			-H 'Content-Type: application/json' \
			-X POST \
			-d "${payload}" \
			"http://127.0.0.1:${ADMIN_PANEL_PORT}/control/rewrite/add" >/dev/null; then
			log "Rewrite add API returned non-success for ${host}; continuing to validation"
		fi
	done
}

validate_rewrites() {
	local idx
	local host
	local expected_ip
	local resolved_ip

	if [ "${#REWRITE_HOSTS[@]}" -eq 0 ]; then
		return 0
	fi

	log "Validating DNS rewrites"
	for idx in "${!REWRITE_HOSTS[@]}"; do
		host="${REWRITE_HOSTS[${idx}]}"
		expected_ip="${REWRITE_IPS[${idx}]}"
		resolved_ip="$(query_dns_a "${host}" || true)"
		[ "${resolved_ip}" = "${expected_ip}" ] || fail "Rewrite validation failed: ${host}, expected ${expected_ip}, got ${resolved_ip:-<empty>}"
		log "Rewrite verified: ${host} resolves to ${resolved_ip}"
	done
}

final_validation() {
	local state=""
	local idx
	local host
	local expected_ip
	local resolved_ip

	log "Final runtime + config validation"
	scan_runtime_ports

	state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
	[ "${state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"

	curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}" || fail "Control panel is not reachable on localhost:${ADMIN_PANEL_PORT}"
	is_port_listening_tcp "${ADGUARD_DNS_PORT}" || fail "Port ${ADGUARD_DNS_PORT}/tcp is not listening"
	is_port_listening_udp "${ADGUARD_DNS_PORT}" || fail "Port ${ADGUARD_DNS_PORT}/udp is not listening"

	for idx in "${!REWRITE_HOSTS[@]}"; do
		host="${REWRITE_HOSTS[${idx}]}"
		expected_ip="${REWRITE_IPS[${idx}]}"
		resolved_ip="$(query_dns_a "${host}" || true)"
		[ "${resolved_ip}" = "${expected_ip}" ] || fail "Rewrite validation failed: ${host}, expected ${expected_ip}, got ${resolved_ip:-<empty>}"
	done
}

log "[1/8] Installing deployment dependencies"
ensure_ubuntu
require_cmd sudo
require_cmd apt

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (target IP for default DNS rewrites)"

sudo apt update -y
sudo apt install -y ca-certificates curl tar dnsutils
install_container_stack

require_cmd curl
require_cmd tar
require_cmd docker
require_cmd dig
require_cmd ss
require_cmd awk
require_cmd grep
require_cmd netbird
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/9] Applying DNS stub-listener mitigation"
disable_systemd_resolved_stub_listener

log "[3/9] Applying NetBird DNS-port mitigation"
disable_netbird_dns_usage

log "[4/9] Using single-node runtime mode"

sudo mkdir -p "${INSTALL_DIR}" "${WORK_DIR}" "${CONF_DIR}"

log "[5/9] Downloading AdGuard Home"
download_adguard_home
write_dockerfile

log "[6/9] Starting container runtime"
start_single

log "[7/9] Waiting for setup wizard completion"
wait_for_setup_completion

log "[8/9] Capturing and validating DNS rewrites"
load_default_rewrite_targets
apply_rewrites_via_api
validate_rewrites

log "[9/9] Running final validation"
sync_admin_panel_mapping_from_config
final_validation

echo
log "Deployment complete and configuration checks passed"
log "Control panel: http://localhost:${ADMIN_PANEL_PORT}"
log "Container status: sudo docker ps --filter name=${SERVICE_NAME}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
