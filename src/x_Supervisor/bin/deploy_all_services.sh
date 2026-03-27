#!/usr/bin/env bash
set -euo pipefail

# deploy_all_services.sh - Deploy service containers to all Netbird nodes
# Usage: deploy_all_services.sh [--skip-pull] [services-file] [nodes-file]

SKIP_PULL=""
arg_idx=1

if [ "${1:-}" = "--skip-pull" ]; then
  SKIP_PULL="--skip-pull"
  arg_idx=2
fi

SERVICES_FILE="${!arg_idx:-data/services.json}"
next_idx=$((arg_idx + 1))
NODES_FILE="${!next_idx:-data/nodes.json}"

if [ ! -f "$SERVICES_FILE" ] || [ ! -f "$NODES_FILE" ]; then
  echo "Error: services.json or nodes.json not found" >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd docker

local_host="$(hostname)"
failed_deployments=0
succeeded_deployments=0

deploy_to_node() {
  local node_id="$1"
  local hostname="$2"
  local ssh_host="$3"
  local service_id="$4"
  local container_name="core-${service_id}"

  echo "Deploying $service_id to $hostname..."

  if [ "$local_host" = "$hostname" ] || [ -z "$ssh_host" ]; then
    # Local deployment
    if [ "$SKIP_PULL" != "--skip-pull" ]; then
      if ! docker pull "$container_name:latest" 2>/dev/null; then
        echo "  [WARN] Failed to pull $container_name on $hostname"
        return 1
      fi
    fi

    if docker run -d \
      --name "$container_name" \
      --restart unless-stopped \
      -v "/opt/core/${service_id}:/data" \
      "$container_name:latest" >/dev/null 2>&1; then
      echo "  [OK] $service_id deployed locally"
      return 0
    else
      echo "  [ERROR] Failed to deploy $service_id locally"
      return 1
    fi
  else
    # Remote deployment via SSH
    if ssh "$ssh_host" "bash -lc '
      set -euo pipefail
      if [ \"$SKIP_PULL\" != \"--skip-pull\" ]; then
        docker pull \"$container_name:latest\" 2>/dev/null || true
      fi
      docker run -d \
        --name \"$container_name\" \
        --restart unless-stopped \
        -v \"/opt/core/${service_id}:/data\" \
        \"$container_name:latest\" >/dev/null 2>&1 && echo ok || echo fail
    '" | grep -q ok; then
      echo "  [OK] $service_id deployed to $hostname"
      return 0
    else
      echo "  [ERROR] Failed to deploy $service_id to $hostname"
      return 1
    fi
  fi
}

echo "=== C.O.R.E Service Deployment ==="
echo "Deploying containerized services to all Netbird nodes..."
echo ""

while IFS= read -r service_id; do
  while IFS='|' read -r node_id hostname ssh_host; do
    if deploy_to_node "$node_id" "$hostname" "$ssh_host" "$service_id"; then
      succeeded_deployments=$((succeeded_deployments + 1))
    else
      failed_deployments=$((failed_deployments + 1))
    fi
  done < <(jq -r '.[] | "\(.id)|\(.hostname)|\(.sshHost // "")"' "$NODES_FILE")
done < <(jq -r '.[] | select(.containerized == true) | .id' "$SERVICES_FILE")

echo ""
echo "=== Deployment Summary ==="
echo "Succeeded: $succeeded_deployments"
echo "Failed: $failed_deployments"

if [ $failed_deployments -gt 0 ]; then
  exit 1
fi
