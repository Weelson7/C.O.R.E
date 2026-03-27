#!/usr/bin/env bash
set -euo pipefail

# orchestrate_container.sh - manage container lifecycle for services
# Usage: orchestrate_container.sh <start|stop> <service-id> <node-id> [target-hostname] [target-ssh-host]

if [ "$#" -lt 3 ]; then
  echo "Usage: orchestrate_container.sh <start|stop> <service-id> <node-id> [target-hostname] [target-ssh-host]" >&2
  exit 1
fi

action="$1"
service_id="$2"
node_id="$3"
target_hostname="${4:-}"
target_ssh_host="${5:-}"

CONTAINER_NAME="core-${service_id}"
local_host="$(hostname)"

validate_action() {
  if [ "$action" != "start" ] && [ "$action" != "stop" ]; then
    echo "action must be 'start' or 'stop'" >&2
    exit 1
  fi
}

container_exists() {
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

is_running() {
  docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].State.Running' | grep -q true
}

start_local() {
  if ! container_exists; then
    echo "Container $CONTAINER_NAME does not exist on $local_host" >&2
    exit 1
  fi

  if is_running; then
    echo "Container $CONTAINER_NAME already running on $local_host" >&2
    return 0
  fi

  docker start "$CONTAINER_NAME"
}

stop_local() {
  if ! container_exists; then
    echo "Container $CONTAINER_NAME does not exist on $local_host" >&2
    return 1
  fi

  if ! is_running; then
    echo "Container $CONTAINER_NAME already stopped on $local_host" >&2
    return 0
  fi

  docker stop "$CONTAINER_NAME"
}

execute_remote() {
  local cmd="$1"
  ssh "$target_ssh_host" "bash -lc '
    set -euo pipefail
    CONTAINER_NAME=\"$CONTAINER_NAME\"
    
    if [ \"$cmd\" = \"start\" ]; then
      docker inspect \"\$CONTAINER_NAME\" >/dev/null 2>&1 || exit 1
      docker start \"\$CONTAINER_NAME\" 2>/dev/null || true
    elif [ \"$cmd\" = \"stop\" ]; then
      docker inspect \"\$CONTAINER_NAME\" >/dev/null 2>&1 || exit 0
      docker stop \"\$CONTAINER_NAME\" 2>/dev/null || true
    fi
  '"
}

validate_action

# Determine if execution is local or remote
if [ "$local_host" = "$target_hostname" ] || [ -z "$target_ssh_host" ]; then
  case "$action" in
    start) start_local ;;
    stop) stop_local ;;
  esac
else
  execute_remote "$action"
fi
