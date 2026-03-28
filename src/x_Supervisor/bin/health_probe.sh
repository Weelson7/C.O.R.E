#!/usr/bin/env bash
set -euo pipefail

# health_probe.sh - active health check for service endpoints
# Usage: health_probe.sh <service-id> <domain> <port>

if [ "$#" -lt 3 ]; then
  echo "Usage: health_probe.sh <service-id> <domain> <port>" >&2
  exit 1
fi

service_id="$1"
domain="$2"
port="$3"

TIMEOUT=5
MAX_RETRIES=3

expected_health_marker() {
  case "$service_id" in
    1_Indexer)
      printf '"service":"indexer"'
      ;;
    *)
      printf ''
      ;;
  esac
}

looks_like_adguard_response() {
  local headers_file="$1"
  local body_file="$2"

  if [ "$service_id" = "2_Adguard" ]; then
    return 1
  fi

  if grep -qi 'adguard[[:space:]]*home' "$body_file"; then
    return 0
  fi

  if grep -qi '^location:[[:space:]].*/login\.html' "$headers_file"; then
    return 0
  fi

  if grep -qi '^server:[[:space:]]*AdGuardHome' "$headers_file"; then
    return 0
  fi

  return 1
}

response_matches_service() {
  local headers_file="$1"
  local body_file="$2"
  local expected

  if looks_like_adguard_response "$headers_file" "$body_file"; then
    return 1
  fi

  expected="$(expected_health_marker)"
  if [ -n "$expected" ] && ! grep -Fq "$expected" "$body_file"; then
    return 1
  fi

  return 0
}

probe_scheme() {
  local scheme="$1"
  local target="$domain:$port"
  local attempt=1
  local insecure=()

  if [ "$scheme" = "https" ]; then
    insecure=(-k)
  fi

  while [ $attempt -le $MAX_RETRIES ]; do
    local headers_file body_file
    headers_file="$(mktemp)"
    body_file="$(mktemp)"

    if curl -fsS --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT + 2))" \
      -D "$headers_file" -o "$body_file" "${insecure[@]}" "${scheme}://${target}/health" >/dev/null 2>&1; then
      if response_matches_service "$headers_file" "$body_file"; then
        rm -f "$headers_file" "$body_file"
        return 0
      fi
    fi

    rm -f "$headers_file" "$body_file"
    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

probe_http() {
  probe_scheme "http"
}

probe_https() {
  probe_scheme "https"
}

probe_docker() {
  local container_name="core-${service_id}"

  if ! docker inspect "$container_name" >/dev/null 2>&1; then
    return 1
  fi

  # Check if container is running
  if ! docker inspect "$container_name" 2>/dev/null | jq -r '.[0].State.Running' | grep -q true; then
    return 1
  fi

  # Attempt container native health check
  if docker inspect "$container_name" 2>/dev/null | jq -r '.[0].State.Health.Status // "none"' | grep -q "healthy"; then
    return 0
  fi

  return 1
}

# Try HTTP first (common for services)
if probe_http; then
  exit 0
fi

# Try HTTPS as fallback
if probe_https; then
  exit 0
fi

# Try Docker native health check
if probe_docker; then
  exit 0
fi

exit 1
