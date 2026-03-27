#!/usr/bin/env bash
set -euo pipefail
# CONTROL_HEADER: Service 2 - C.O.R.E AdGuard Home (dns.core)

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
DOCKER_COMPOSE_PLUGIN_VERSION="${DOCKER_COMPOSE_PLUGIN_VERSION:-v2.29.7}"
COMPOSE_CMD=()

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

is_port_listening_tcp() {
	local port="$1"
	ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

is_port_listening_udp() {
	local port="$1"
	ss -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

disable_systemd_resolved_stub_listener() {
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

scan_runtime_ports() {
	local panel_ok="no"
	local dns_tcp_ok="no"
	local dns_udp_ok="no"

	if is_port_listening_tcp 3000; then
		panel_ok="yes"
	fi

	if is_port_listening_tcp 53; then
		dns_tcp_ok="yes"
	fi

	if is_port_listening_udp 53; then
		dns_udp_ok="yes"
	fi

	log "Scan: tcp/3000=${panel_ok}, tcp/53=${dns_tcp_ok}, udp/53=${dns_udp_ok}"
}

query_dns_a() {
	local host="$1"

	dig +time=2 +tries=1 +short @127.0.0.1 -p 53 "${host}" A 2>/dev/null | awk 'NF {print; exit}'
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

EXPOSE 53/tcp 53/udp 67/udp 68/tcp 68/udp 80/tcp 3000/tcp 443/tcp

ENTRYPOINT ["/opt/adguardhome/AdGuardHome"]
CMD ["-c", "/opt/adguardhome/conf/AdGuardHome.yaml", "-w", "/opt/adguardhome/work"]
EOF
}

write_compose_file() {
	sudo tee "${COMPOSE_FILE}" >/dev/null <<EOF
services:
  adguard:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
      - "3000:3000/tcp"
      - "443:443/tcp"
    volumes:
      - ${WORK_DIR}:/opt/adguardhome/work
      - ${CONF_DIR}:/opt/adguardhome/conf
EOF
}

start_single() {
	log "Building image and starting single-node container"
	sudo docker build -t "${IMAGE_TAG}" "${BUILD_DIR}"
	write_compose_file

	sudo docker rm -f "${SERVICE_NAME}" >/dev/null 2>&1 || true
	"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

	local state
	state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
	[ "${state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"
}

wait_for_setup_completion() {
	local answer=""
	local panel_http_ok=0

	log "Waiting for setup completion"
	log "Open http://localhost:3000 and complete the AdGuard Home setup wizard."
	log "Ensure DNS is configured to listen on port 53 (tcp+udp)."

	while true; do
		scan_runtime_ports

		panel_http_ok=0
		if curl -fsS -o /dev/null "http://127.0.0.1:3000"; then
			panel_http_ok=1
		fi

		read -r -p "Have you completed setup and saved settings? [y/N]: " answer
		case "$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')" in
			y|yes)
				if [ "${panel_http_ok}" -ne 1 ]; then
					log "Control panel is not reachable on localhost:3000 yet."
					continue
				fi

				if ! is_port_listening_tcp 53 || ! is_port_listening_udp 53; then
					log "Port 53 is not listening on both tcp and udp yet."
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

capture_rewrite_targets() {
	local rewrite_count=""
	local i
	local host
	local ip

	while :; do
		read -r -p "How many DNS rewrites do you want to validate now? " rewrite_count
		if printf '%s' "${rewrite_count}" | grep -Eq '^[0-9]+$'; then
			break
		fi
	done

	if [ "${rewrite_count}" -eq 0 ]; then
		log "No rewrite entries provided. Skipping rewrite checks by request."
		return 0
	fi

	i=1
	while [ "${i}" -le "${rewrite_count}" ]; do
		ensure_value host "Rewrite ${i}/${rewrite_count} hostname (example: service.core)"
		ensure_value ip "Rewrite ${i}/${rewrite_count} target IPv4"

		REWRITE_HOSTS+=("${host}")
		REWRITE_IPS+=("${ip}")
		host=""
		ip=""
		i=$((i + 1))
	done
}

validate_each_rewrite_loop() {
	local idx
	local host
	local expected_ip
	local resolved_ip

	if [ "${#REWRITE_HOSTS[@]}" -eq 0 ]; then
		return 0
	fi

	log "DNS rewrite entry loops"
	for idx in "${!REWRITE_HOSTS[@]}"; do
		host="${REWRITE_HOSTS[${idx}]}"
		expected_ip="${REWRITE_IPS[${idx}]}"

		while true; do
			log "Add/update rewrite in AdGuard UI: ${host} -> ${expected_ip}"
			read -r -p "Press Enter when the rewrite is saved to run scan... " _discard

			resolved_ip="$(query_dns_a "${host}" || true)"
			if [ "${resolved_ip}" = "${expected_ip}" ]; then
				log "Rewrite verified: ${host} resolves to ${resolved_ip}"
				break
			fi

			log "Rewrite scan mismatch for ${host}: expected ${expected_ip}, got ${resolved_ip:-<empty>}"
			log "Fix the rewrite and run the scan again."
		done
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

	curl -fsS -o /dev/null "http://127.0.0.1:3000" || fail "Control panel is not reachable on localhost:3000"
	is_port_listening_tcp 53 || fail "Port 53/tcp is not listening"
	is_port_listening_udp 53 || fail "Port 53/udp is not listening"

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
resolve_compose_cmd

sudo systemctl enable docker
sudo systemctl restart docker

log "[2/8] Applying DNS stub-listener mitigation"
disable_systemd_resolved_stub_listener

log "[3/8] Using single-node runtime mode"

sudo mkdir -p "${INSTALL_DIR}" "${WORK_DIR}" "${CONF_DIR}"

log "[4/8] Downloading AdGuard Home"
download_adguard_home
write_dockerfile

log "[5/8] Starting container runtime"
start_single

log "[6/8] Waiting for setup wizard completion"
wait_for_setup_completion

log "[7/8] Capturing and validating DNS rewrites"
capture_rewrite_targets
if [ "${#REWRITE_HOSTS[@]}" -eq 0 ]; then
	log "No rewrites requested for validation in this run."
else
	validate_each_rewrite_loop
fi

log "[8/8] Running final validation"
final_validation

echo
log "Deployment complete and configuration checks passed"
log "Control panel: http://localhost:3000"
log "Container status: sudo docker ps --filter name=${SERVICE_NAME}"
log "Container logs: sudo docker logs -f ${SERVICE_NAME}"
