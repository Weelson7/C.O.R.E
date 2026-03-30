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
PUBLISH_HTTPS_PORT="${PUBLISH_HTTPS_PORT:-false}"
ADGUARD_HTTPS_PORT="${ADGUARD_HTTPS_PORT:-443}"
ALLOW_UFW_ADMIN_PORT="${ALLOW_UFW_ADMIN_PORT:-true}"
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
    "seanime.core"
    "ttyd.core"
    "qbittorrent.core"
    "jupyter.core"
    "onlyoffice.core"
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
    log "Checking for required command: $1"
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
    log "Required command found: $1"
}

resolve_compose_cmd() {
    log "Resolving Docker Compose v2 command..."

    if sudo docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(sudo docker compose)
        log "Docker Compose v2 plugin resolved via 'docker compose'"
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

    log "Detecting host architecture for manual compose plugin installation..."
    arch="$(uname -m)"
    log "Detected host architecture: ${arch}"

    case "${arch}" in
        x86_64|amd64) plugin_arch="x86_64" ;;
        aarch64|arm64) plugin_arch="aarch64" ;;
        *) fail "Unsupported architecture for compose plugin fallback: ${arch}" ;;
    esac

    log "Mapped architecture to compose plugin variant: ${plugin_arch}"
    plugin_url="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_PLUGIN_VERSION}/docker-compose-linux-${plugin_arch}"
    log "Compose plugin download URL: ${plugin_url}"

    log "Creating Docker CLI plugins directory at ${plugin_dir}"
    sudo mkdir -p "${plugin_dir}"

    log "Downloading Docker Compose plugin to ${plugin_path}"
    sudo curl -fsSL "${plugin_url}" -o "${plugin_path}"

    log "Setting execute permission on ${plugin_path}"
    sudo chmod +x "${plugin_path}"

    log "Docker Compose plugin installed manually to ${plugin_path}"
}

install_container_stack() {
    log "Attempting to install docker.io and docker-compose-plugin via apt..."

    if sudo apt install -y docker.io docker-compose-plugin; then
        log "docker.io and docker-compose-plugin installed via apt"
        return 0
    fi

    log "Package docker-compose-plugin unavailable; installing Docker Compose plugin manually"
    sudo apt install -y docker.io
    log "docker.io installed via apt"
    install_compose_plugin_manually
}

ensure_ubuntu() {
    log "Ensuring operating system is Ubuntu..."
    [ -r /etc/os-release ] || fail "Cannot determine operating system (/etc/os-release missing)"

    log "Reading /etc/os-release for OS information"
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || fail "This script is intended for Ubuntu hosts (detected: ${ID:-unknown})"
    log "Operating system confirmed as Ubuntu"
}

ensure_value() {
    log "Ensuring required value for ${1}"
    local var_name="$1"
    local prompt="$2"
    local current_value="${!var_name:-}"

    while [ -z "${current_value}" ]; do
        log "Value for ${var_name} is required but not set"
        log "Prompting for ${var_name}"
        read -r -p "${prompt}: " current_value
        log "Value for ${var_name} received: ${current_value}"
    done

    log "Value for ${var_name} is set"
    printf -v "${var_name}" '%s' "${current_value}"
}

ensure_secret_value() {
    log "Ensuring required secret value for ${1}"
    local var_name="$1"
    local prompt="$2"
    local current_value="${!var_name:-}"

    while [ -z "${current_value}" ]; do
        log "Value for ${var_name} is required but not set"
        log "Prompting for ${var_name} (input will be hidden)"
        read -r -s -p "${prompt}: " current_value
        echo
        log "Value for ${var_name} received (hidden)"
    done

    log "Value for ${var_name} is set"
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

    log "Checking if systemd-resolved service is present..."
    if ! systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
        log "systemd-resolved service not found; skipping DNS stub listener tuning"
        return 0
    fi

    log "Disabling systemd-resolved DNSStubListener to free host port 53"
    sudo mkdir -p "${dropin_dir}"
    log "Writing drop-in config to ${dropin_file}"
    sudo tee "${dropin_file}" >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF

    log "Restarting systemd-resolved to apply drop-in config"
    sudo systemctl restart systemd-resolved
    sleep 1

    if is_port_listening_tcp 53 || is_port_listening_udp 53; then
        log "Port 53 is still in use after systemd-resolved restart; another service may be bound to it"
    else
        log "Port 53 is now free after disabling systemd-resolved stub listener"
    fi
}

is_netbird_bound_to_port_53() {
    sudo ss -luntp 2>/dev/null | grep -E '(:53[[:space:]]|:53$)' | grep -qi 'netbird'
}

disable_netbird_dns_usage() {
    log "Checking if NetBird is present and bound to port 53..."

    if ! command -v netbird >/dev/null 2>&1; then
        log "NetBird binary not found; skipping NetBird DNS mitigation"
        return 0
    fi

    if ! sudo netbird status >/dev/null 2>&1; then
        log "NetBird status check failed or agent is not running; skipping NetBird DNS mitigation"
        return 0
    fi

    if ! is_netbird_bound_to_port_53; then
        log "NetBird is not bound to port 53; no DNS mitigation required"
        return 0
    fi

    log "NetBird is bound to port 53; reconfiguring NetBird with DNS disabled"
    sudo netbird down >/dev/null 2>&1 || true
    log "NetBird brought down; restarting with --disable-dns"

    if ! sudo netbird up --disable-dns; then
        fail "Failed to restart NetBird with --disable-dns"
    fi

    log "NetBird restarted with --disable-dns; waiting for port 53 to be released"
    sleep 1

    if is_netbird_bound_to_port_53; then
        log "NetBird still appears bound to port 53 after --disable-dns; forcing DNS resolver to 127.0.0.1:22053"
        sudo netbird down >/dev/null 2>&1 || true
        log "NetBird brought down; restarting with --dns-resolver-address 127.0.0.1:22053"

        if ! sudo netbird up --dns-resolver-address 127.0.0.1:22053; then
            fail "Failed to restart NetBird with --dns-resolver-address 127.0.0.1:22053"
        fi

        log "NetBird restarted with --dns-resolver-address 127.0.0.1:22053; verifying port 53 is released"
        sleep 1

        if is_netbird_bound_to_port_53; then
            fail "NetBird still appears bound to port 53 after resolver port override"
        fi

        log "NetBird is no longer bound to port 53 after resolver port override"
    else
        log "NetBird is no longer bound to port 53 after --disable-dns"
    fi
}

scan_runtime_ports() {
    local panel_ok="no"
    local dns_tcp_ok="no"
    local dns_udp_ok="no"

    log "Scanning runtime ports..."

    if is_port_listening_tcp "${ADMIN_PANEL_PORT}"; then
        panel_ok="yes"
    fi

    if is_port_listening_tcp 53; then
        dns_tcp_ok="yes"
    fi

    if is_port_listening_udp 53; then
        dns_udp_ok="yes"
    fi

    log "Scan: tcp/${ADMIN_PANEL_PORT}=${panel_ok}, tcp/53=${dns_tcp_ok}, udp/53=${dns_udp_ok}"
}

query_dns_a() {
    local host="$1"
    log "Querying DNS A record for ${host} via 127.0.0.1:53"
    dig +time=2 +tries=1 +short @127.0.0.1 -p 53 "${host}" A 2>/dev/null | awk 'NF {print; exit}'
}

download_adguard_home() {
    log "Downloading AdGuard Home ${ADGUARD_VERSION}"
    log "Preparing build directory at ${BUILD_DIR}"
    sudo mkdir -p "${BUILD_DIR}"

    log "Removing any previous AdGuard Home artifacts from ${BUILD_DIR}"
    sudo rm -rf "${BUILD_DIR}/AdGuardHome" "${BUILD_DIR}/AdGuardHome_linux_amd64.tar.gz"

    log "Fetching AdGuard Home release archive from ${ADGUARD_RELEASE_URL}"
    curl -fsSL "${ADGUARD_RELEASE_URL}" -o /tmp/core-adguard.tar.gz

    log "Moving downloaded archive to ${BUILD_DIR}"
    sudo mv /tmp/core-adguard.tar.gz "${BUILD_DIR}/AdGuardHome_linux_amd64.tar.gz"

    log "Extracting AdGuard Home archive into ${BUILD_DIR}"
    sudo tar -xzf "${BUILD_DIR}/AdGuardHome_linux_amd64.tar.gz" -C "${BUILD_DIR}"

    log "Verifying AdGuardHome binary exists and is executable"
    [ -x "${BUILD_DIR}/AdGuardHome/AdGuardHome" ] || fail "AdGuardHome binary missing after extraction"
    log "AdGuardHome binary verified at ${BUILD_DIR}/AdGuardHome/AdGuardHome"
}

write_dockerfile() {
    log "Writing Dockerfile to ${BUILD_DIR}/Dockerfile"
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
    log "Dockerfile written successfully"
}

write_compose_file() {
    log "Writing Docker Compose file to ${COMPOSE_FILE}"
    {
        cat <<EOF
services:
  adguard:
    container_name: ${SERVICE_NAME}
    image: ${IMAGE_TAG}
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "${ADMIN_PANEL_PORT}:${ADGUARD_ADMIN_CONTAINER_PORT}/tcp"
EOF
        if [ "${ADGUARD_FALLBACK_PANEL_PORT}" != "${ADMIN_PANEL_PORT}" ]; then
            log "Fallback admin panel port ${ADGUARD_FALLBACK_PANEL_PORT} differs from primary ${ADMIN_PANEL_PORT}; adding fallback port mapping"
            echo "      - \"${ADGUARD_FALLBACK_PANEL_PORT}:${ADGUARD_ADMIN_CONTAINER_PORT}/tcp\""
        fi
        if [ "${PUBLISH_HTTPS_PORT}" = "true" ]; then
            log "PUBLISH_HTTPS_PORT is true; adding HTTPS port mapping ${ADGUARD_HTTPS_PORT}:443"
            echo "      - \"${ADGUARD_HTTPS_PORT}:443/tcp\""
        fi
        cat <<EOF
    volumes:
      - ${WORK_DIR}:/opt/adguardhome/work
      - ${CONF_DIR}:/opt/adguardhome/conf
EOF
    } | sudo tee "${COMPOSE_FILE}" >/dev/null
    log "Docker Compose file written successfully"
}

open_firewall_admin_port() {
    log "Evaluating UFW firewall rule for admin panel port ${ADMIN_PANEL_PORT}..."

    if [ "${ALLOW_UFW_ADMIN_PORT}" != "true" ]; then
        log "ALLOW_UFW_ADMIN_PORT is not true; skipping UFW rule"
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log "ufw binary not found; skipping firewall rule"
        return 0
    fi

    if ! sudo ufw status 2>/dev/null | grep -qi '^status:[[:space:]]*active'; then
        log "UFW is not active; skipping firewall rule"
        return 0
    fi

    log "UFW is active; allowing tcp/${ADMIN_PANEL_PORT} for AdGuard admin access"
    sudo ufw allow "${ADMIN_PANEL_PORT}/tcp" >/dev/null || true

    if [ "${ADGUARD_FALLBACK_PANEL_PORT}" != "${ADMIN_PANEL_PORT}" ]; then
        log "Allowing fallback admin panel port tcp/${ADGUARD_FALLBACK_PANEL_PORT} in UFW"
        sudo ufw allow "${ADGUARD_FALLBACK_PANEL_PORT}/tcp" >/dev/null || true
    fi

    log "UFW rules applied for admin panel access"
}

sync_admin_panel_bind_from_config() {
    local config_file="${CONF_DIR}/AdGuardHome.yaml"
    local configured_port=""

    log "Checking AdGuard Home config at ${config_file} for bind host and port settings..."

    [ -f "${config_file}" ] || {
        log "Config file ${config_file} does not exist yet; skipping bind sync"
        return 0
    }

    if sudo grep -Eq '^[[:space:]]*bind_host:[[:space:]]*(127\.0\.0\.1|localhost)[[:space:]]*$' "${config_file}"; then
        log "AdGuard bind_host is loopback; forcing bind_host to 0.0.0.0 for NetBird reachability"
        sudo sed -E -i 's/^([[:space:]]*bind_host:[[:space:]]*)(127\.0\.0\.1|localhost)[[:space:]]*$/\10.0.0.0/' "${config_file}"
        log "bind_host patched to 0.0.0.0 in ${config_file}"
    else
        log "AdGuard bind_host is not loopback; no patch required"
    fi

    if sudo grep -Eq '^[[:space:]]*address:[[:space:]]*("|\x27)?(127\.0\.0\.1|localhost):[0-9]+("|\x27)?[[:space:]]*$' "${config_file}"; then
        log "AdGuard address is loopback; forcing address host to 0.0.0.0"
        sudo sed -E -i 's/^([[:space:]]*address:[[:space:]]*)("|\x27)?(127\.0\.0\.1|localhost):([0-9]+)("|\x27)?[[:space:]]*$/\10.0.0.0:\4/' "${config_file}"
        log "address host patched to 0.0.0.0 in ${config_file}"
    else
        log "AdGuard address is not loopback; no patch required"
    fi

    log "Extracting configured admin port from ${config_file}"
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
        log "Detected AdGuard admin port ${configured_port} in config differs from current container port ${ADGUARD_ADMIN_CONTAINER_PORT}; updating container port mapping"
        ADGUARD_ADMIN_CONTAINER_PORT="${configured_port}"
    else
        log "Configured admin port matches current container port ${ADGUARD_ADMIN_CONTAINER_PORT}; no update needed"
    fi
}

cleanup_previous_runtime() {
    log "Cleaning previous AdGuard runtime artifacts..."
    local ids=()
    local id

    if [ -f "${COMPOSE_FILE}" ]; then
        log "Compose file found at ${COMPOSE_FILE}; tearing down existing stack"
        "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
        log "Existing compose stack torn down"
    else
        log "No compose file found at ${COMPOSE_FILE}; skipping stack teardown"
    fi

    log "Collecting container IDs matching name /${SERVICE_NAME}..."
    while IFS= read -r id; do
        [ -n "${id}" ] || continue
        ids+=("${id}")
    done < <(sudo docker ps -aq --filter "name=^/${SERVICE_NAME}$")

    log "Collecting container IDs matching ancestor image ${IMAGE_TAG}..."
    while IFS= read -r id; do
        [ -n "${id}" ] || continue
        ids+=("${id}")
    done < <(sudo docker ps -aq --filter "ancestor=${IMAGE_TAG}")

    if [ "${#ids[@]}" -gt 0 ]; then
        mapfile -t ids < <(printf '%s\n' "${ids[@]}" | awk '!seen[$1]++')
        log "Removing existing AdGuard container workload (${#ids[@]} container(s))"
        sudo docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
        log "Existing AdGuard containers removed"
    else
        log "No existing AdGuard containers found; nothing to remove"
    fi
}

wait_for_admin_panel_http() {
    local attempt=1
    local max_attempts=20

    log "Waiting for AdGuard admin panel to become reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}..."

    while [ "${attempt}" -le "${max_attempts}" ]; do
        log "Attempt ${attempt}/${max_attempts}: probing http://127.0.0.1:${ADMIN_PANEL_PORT}"

        if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}"; then
            log "Admin panel is reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}"
            return 0
        fi

        log "Admin panel not yet reachable; retrying in 1 second"
        sleep 1
        attempt=$((attempt + 1))
    done

    log "AdGuard panel is not reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}"
    log "Container logs (last 80 lines):"
    sudo docker logs --tail 80 "${SERVICE_NAME}" || true
    fail "Setup wizard endpoint is unavailable"
}

sync_admin_panel_mapping_from_config() {
    log "Syncing admin panel port mapping from config and recreating container..."
    sync_admin_panel_bind_from_config
    write_compose_file
    log "Recreating container with updated compose file"
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate
    log "Container recreated; waiting 2 seconds for startup"
    sleep 2
}

start_single() {
    log "Building image and starting single-node container"
    cleanup_previous_runtime
    sync_admin_panel_bind_from_config

    log "Building Docker image ${IMAGE_TAG} from ${BUILD_DIR}"
    sudo docker build -t "${IMAGE_TAG}" "${BUILD_DIR}"
    log "Docker image ${IMAGE_TAG} built successfully"

    write_compose_file

    log "Validating generated compose file at ${COMPOSE_FILE}"
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" config >/dev/null || fail "Generated compose file is invalid: ${COMPOSE_FILE}"
    log "Compose file validation passed"

    log "Starting AdGuard container via compose"
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate

    local state
    state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
    log "Container ${SERVICE_NAME} state: ${state}"
    [ "${state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"
    log "Container ${SERVICE_NAME} is running"

    open_firewall_admin_port
    wait_for_admin_panel_http
}

wait_for_setup_completion() {
    local answer=""
    local panel_http_ok=0

    log "Waiting for setup completion"
    log "Open http://localhost:${ADMIN_PANEL_PORT} and complete the AdGuard Home setup wizard."
    log "Ensure DNS is configured to listen on port 53 (tcp+udp)."

    while true; do
        scan_runtime_ports

        panel_http_ok=0
        if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}"; then
            log "Admin panel is reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}"
            panel_http_ok=1
        else
            log "Admin panel is not currently reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}"
        fi

        read -r -p "Have you completed setup and saved settings? [y/N]: " answer
        case "$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')" in
            y|yes)
                log "User confirmed setup completion; verifying gate conditions..."

                if [ "${panel_http_ok}" -ne 1 ]; then
                    log "Admin panel not reachable; attempting to sync port mapping from config and recreate container"
                    sync_admin_panel_mapping_from_config

                    if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}"; then
                        log "Admin panel is now reachable after container recreation"
                        panel_http_ok=1
                    else
                        log "Admin panel still not reachable after container recreation"
                    fi
                fi

                if [ "${panel_http_ok}" -ne 1 ]; then
                    log "Control panel is not reachable on localhost:${ADMIN_PANEL_PORT} yet."
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


load_default_rewrite_targets() {
    local host

    log "Loading default DNS rewrite targets..."
    REWRITE_HOSTS=()
    REWRITE_IPS=()

    for host in "${DEFAULT_REWRITE_DOMAINS[@]}"; do
        log "Registering rewrite: ${host} -> ${NETBIRD_DEVICE_IP}"
        REWRITE_HOSTS+=("${host}")
        REWRITE_IPS+=("${NETBIRD_DEVICE_IP}")
    done

    log "Loaded ${#REWRITE_HOSTS[@]} DNS rewrite target(s)"
}

apply_rewrites_via_api() {
    local idx
    local host
    local ip
    local payload
    local existing_rewrites
    local old_answer

    ensure_value ADGUARD_ADMIN_USER "Enter AdGuard admin username (for rewrite API)"
    ensure_secret_value ADGUARD_ADMIN_PASSWORD "Enter AdGuard admin password (for rewrite API)"

    log "Applying default DNS rewrites through AdGuard API"
    log "Fetching existing rewrites from AdGuard API at http://127.0.0.1:${ADMIN_PANEL_PORT}/control/rewrite/list"
    existing_rewrites="$(curl --silent --show-error --fail \
        -u "${ADGUARD_ADMIN_USER}:${ADGUARD_ADMIN_PASSWORD}" \
        "http://127.0.0.1:${ADMIN_PANEL_PORT}/control/rewrite/list" 2>/dev/null || echo '[]')"
    log "Fetched existing rewrites from AdGuard API"

    for idx in "${!REWRITE_HOSTS[@]}"; do
        host="${REWRITE_HOSTS[${idx}]}"
        ip="${REWRITE_IPS[${idx}]}"
        payload="{\"domain\":\"${host}\",\"answer\":\"${ip}\"}"

        log "Processing rewrite entry ${idx}: ${host} -> ${ip}"

        # Enforce exactly one rewrite per managed host to avoid flapping/Network changed errors.
        log "Checking for existing rewrite entries for ${host} and removing them..."
        while IFS= read -r old_answer; do
            [ -n "${old_answer}" ] || continue
            log "Deleting existing rewrite for ${host} with answer ${old_answer}"
            curl --silent --show-error --fail \
                -u "${ADGUARD_ADMIN_USER}:${ADGUARD_ADMIN_PASSWORD}" \
                -H 'Content-Type: application/json' \
                -X POST \
                -d "{\"domain\":\"${host}\",\"answer\":\"${old_answer}\"}" \
                "http://127.0.0.1:${ADMIN_PANEL_PORT}/control/rewrite/delete" >/dev/null || true
            log "Deleted existing rewrite for ${host} with answer ${old_answer}"
        done < <(printf '%s' "${existing_rewrites}" | jq -r --arg host "${host}" '.[] | select(.domain == $host) | .answer')

        log "Adding rewrite via API: ${payload}"
        if ! curl --silent --show-error --fail \
            -u "${ADGUARD_ADMIN_USER}:${ADGUARD_ADMIN_PASSWORD}" \
            -H 'Content-Type: application/json' \
            -X POST \
            -d "${payload}" \
            "http://127.0.0.1:${ADMIN_PANEL_PORT}/control/rewrite/add" >/dev/null; then
            log "Rewrite add API returned non-success for ${host}; continuing to validation"
        else
            log "Rewrite added successfully for ${host}"
        fi
    done
}

validate_rewrites() {
    local idx
    local host
    local expected_ip
    local resolved_ip

    if [ "${#REWRITE_HOSTS[@]}" -eq 0 ]; then
        log "No rewrite hosts to validate; skipping rewrite validation"
        return 0
    fi

    log "Validating DNS rewrites"
    for idx in "${!REWRITE_HOSTS[@]}"; do
        host="${REWRITE_HOSTS[${idx}]}"
        expected_ip="${REWRITE_IPS[${idx}]}"

        log "Resolving ${host} via AdGuard DNS at 127.0.0.1:53..."
        resolved_ip="$(query_dns_a "${host}" || true)"
        log "Resolution result for ${host}: ${resolved_ip:-<empty>}"

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

    log "Inspecting container ${SERVICE_NAME} state..."
    state="$(sudo docker inspect -f '{{.State.Status}}' "${SERVICE_NAME}" 2>/dev/null || true)"
    log "Container ${SERVICE_NAME} state: ${state}"
    [ "${state}" = "running" ] || fail "Container ${SERVICE_NAME} is not running"
    log "Container ${SERVICE_NAME} is confirmed running"

    log "Verifying admin panel is reachable at http://127.0.0.1:${ADMIN_PANEL_PORT}..."
    curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PANEL_PORT}" || fail "Control panel is not reachable on localhost:${ADMIN_PANEL_PORT}"
    log "Admin panel is reachable"

    log "Verifying port 53/tcp is listening..."
    is_port_listening_tcp 53 || fail "Port 53/tcp is not listening"
    log "Port 53/tcp is listening"

    log "Verifying port 53/udp is listening..."
    is_port_listening_udp 53 || fail "Port 53/udp is not listening"
    log "Port 53/udp is listening"

    log "Re-validating all DNS rewrite entries..."
    for idx in "${!REWRITE_HOSTS[@]}"; do
        host="${REWRITE_HOSTS[${idx}]}"
        expected_ip="${REWRITE_IPS[${idx}]}"

        log "Resolving ${host} via 127.0.0.1:53..."
        resolved_ip="$(query_dns_a "${host}" || true)"
        log "Resolution result for ${host}: ${resolved_ip:-<empty>}"

        [ "${resolved_ip}" = "${expected_ip}" ] || fail "Rewrite validation failed: ${host}, expected ${expected_ip}, got ${resolved_ip:-<empty>}"
        log "Rewrite re-verified: ${host} resolves to ${resolved_ip}"
    done
}

log "[1/8] Installing deployment dependencies"
ensure_ubuntu
require_cmd sudo
require_cmd apt

ensure_value NETBIRD_DEVICE_IP "Enter NETBIRD_DEVICE_IP (target IP for default DNS rewrites)"

log "Running apt update..."
sudo apt update -y
log "apt update complete"

log "Installing ca-certificates, curl, tar, dnsutils, jq..."
sudo apt install -y ca-certificates curl tar dnsutils jq
log "Core packages installed"

log "Installing container stack (docker.io, docker-compose-plugin)..."
install_container_stack

require_cmd curl
require_cmd tar
require_cmd docker
require_cmd dig
require_cmd ss
require_cmd awk
require_cmd grep
require_cmd jq
require_cmd netbird
resolve_compose_cmd

log "Enabling and restarting Docker daemon..."
sudo systemctl enable docker
sudo systemctl restart docker
log "Docker daemon enabled and restarted"

log "[2/9] Applying DNS stub-listener mitigation"
disable_systemd_resolved_stub_listener

log "[3/9] Applying NetBird DNS-port mitigation"
disable_netbird_dns_usage

log "[4/9] Using single-node runtime mode"

log "Creating install, work, and conf directories..."
sudo mkdir -p "${INSTALL_DIR}" "${WORK_DIR}" "${CONF_DIR}"
log "Directories created: ${INSTALL_DIR}, ${WORK_DIR}, ${CONF_DIR}"

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