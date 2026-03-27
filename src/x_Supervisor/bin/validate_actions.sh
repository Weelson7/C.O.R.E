#!/usr/bin/env bash
set -euo pipefail

# validate_actions.sh - post-execution validation and retry for actions
# Usage: validate_actions.sh <action-type> <service-id> <domain|node> [port] [max-retries]

if [ "$#" -lt 3 ]; then
  echo "Usage: validate_actions.sh <action-type> <service-id> <domain|node> [port] [max-retries]" >&2
  exit 1
fi

action_type="$1"
service_id="$2"
target="$3"
port="${4:-443}"
max_retries="${5:-3}"

RETRY_DELAY=5
TIMEOUT=10

validate_dns() {
  local domain="$1"
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if dig +short "$domain" 2>/dev/null | grep -qE '^[0-9.]+$'; then
      echo "DNS validation passed: $domain resolves"
      return 0
    fi
    echo "[attempt $attempt] DNS not yet resolved for $domain; retrying..."
    sleep $RETRY_DELAY
    attempt=$((attempt + 1))
  done

  echo "DNS validation FAILED after $max_retries attempts for $domain"
  return 1
}

validate_endpoint() {
  local domain="$1"
  local port="$2"
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if curl -fsS --connect-timeout $TIMEOUT "https://${domain}:${port}/health" >/dev/null 2>&1; then
      echo "HTTP health check passed: $domain:$port/health"
      return 0
    fi

    if curl -fsS --connect-timeout $TIMEOUT "http://${domain}:${port}/health" >/dev/null 2>&1; then
      echo "HTTP health check passed (insecure): $domain:$port/health"
      return 0
    fi

    echo "[attempt $attempt] Health check failed for $domain:$port; retrying..."
    sleep $RETRY_DELAY
    attempt=$((attempt + 1))
  done

  echo "Endpoint validation FAILED after $max_retries attempts for $domain:$port"
  return 1
}

validate_service_containers() {
  local service_id="$1"
  local node="$2"
  local container="core-${service_id}"
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if docker inspect "$container" 2>/dev/null | jq -r '.[0].State.Running' | grep -q "true"; then
      echo "Container validation passed: $container running on $node"
      return 0
    fi
    echo "[attempt $attempt] Container $container not running; retrying..."
    sleep $RETRY_DELAY
    attempt=$((attempt + 1))
  done

  echo "Container validation FAILED after $max_retries attempts for $container"
  return 1
}

validate_nginx() {
  local domain="$1"
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if nginx -t 2>&1 | grep -q "successful\|ok"; then
      if curl -fsS -k --connect-timeout $TIMEOUT "https://${domain}/" >/dev/null 2>&1 || \
         curl -fsS --connect-timeout $TIMEOUT "http://${domain}/" >/dev/null 2>&1; then
        echo "Nginx validation passed: $domain routable"
        return 0
      fi
    fi
    echo "[attempt $attempt] Nginx not ready for $domain; retrying..."
    sleep $RETRY_DELAY
    attempt=$((attempt + 1))
  done

  echo "Nginx validation FAILED after $max_retries attempts for $domain"
  return 1
}

# Execute validation based on action type
case "$action_type" in
  dns)
    validate_dns "$target" || exit 1
    ;;
  endpoint)
    validate_endpoint "$target" "$port" || exit 1
    ;;
  container)
    validate_service_containers "$service_id" "$target" || exit 1
    ;;
  nginx)
    validate_nginx "$target" || exit 1
    ;;
  *)
    echo "Unknown action type: $action_type" >&2
    exit 1
    ;;
esac

echo "✓ Validation complete for $action_type"
