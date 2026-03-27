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

probe_http() {
  local target="$domain:$port"
  local attempt=1

  while [ $attempt -le $MAX_RETRIES ]; do
    if curl -fsS --connect-timeout "$TIMEOUT" "http://${target}/health" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

probe_https() {
  local target="$domain:$port"
  local attempt=1

  while [ $attempt -le $MAX_RETRIES ]; do
    if curl -fsS --connect-timeout "$TIMEOUT" -k "https://${target}/health" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
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
