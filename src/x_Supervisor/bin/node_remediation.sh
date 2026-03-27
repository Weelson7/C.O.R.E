#!/usr/bin/env bash
set -euo pipefail

# node_remediation.sh - handle bad node states with reboot policies and cooldown
# Usage: node_remediation.sh <action> <nodes-file> <state-file> <node-id> [--force]

if [ "$#" -lt 4 ]; then
  echo "Usage: node_remediation.sh <action> <nodes-file> <state-file> <node-id> [--force]" >&2
  exit 1
fi

action="$1"
nodes_file="$2"
state_file="$3"
node_id="$4"
force="${5:-}"

REBOOT_COOLDOWN_MINUTES=30
REBOOT_MAX_ATTEMPTS=3
HEALTH_CHECK_RETRIES=5

# Initialize remediation state if needed
ensure_remediation_state() {
  if ! jq -e '.remediation != null' "$state_file" >/dev/null 2>&1; then
    jq '. + {remediation: {cooldowns: {}, attempts: {}, lastRemediation: {}, quarantined: []}}' "$state_file" >"${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
  fi
}

# Check if reboot is on cooldown
is_reboot_on_cooldown() {
  local node="$1"
  local last_reboot=$(jq -r ".remediation.cooldowns[\"$node\"] // null" "$state_file")
  
  if [ "$last_reboot" = "null" ] || [ -z "$last_reboot" ]; then
    return 1  # Not on cooldown
  fi
  
  local now=$(date +%s)
  local last_reboot_seconds=$(date -d "$last_reboot" +%s 2>/dev/null || echo 0)
  local elapsed=$((now - last_reboot_seconds))
  local cooldown_seconds=$((REBOOT_COOLDOWN_MINUTES * 60))
  
  if [ "$elapsed" -lt "$cooldown_seconds" ]; then
    local remaining=$((cooldown_seconds - elapsed))
    echo "Node $node is on reboot cooldown for $remaining more seconds"
    return 0  # On cooldown
  fi
  
  return 1  # Cooldown expired
}

# Reset cooldown
reset_cooldown() {
  local node="$1"
  
  jq --arg node "$node" '.remediation.cooldowns[$node] = null' "$state_file" >"${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

# Record reboot attempt
record_reboot_attempt() {
  local node="$1"
  
  local attempts=$(jq -r ".remediation.attempts[\"$node\"] // 0" "$state_file")
  attempts=$((attempts + 1))
  
  jq --arg node "$node" --arg attempts "$attempts" \
    '.remediation.attempts[$node] = ($attempts | tonumber) | .remediation.lastRemediation[$node] = (now | todateiso8601)' \
    "$state_file" >"${state_file}.tmp"
  
  mv "${state_file}.tmp" "$state_file"
  echo "$attempts"
}

# Check if max reboot attempts exceeded
is_max_attempts_exceeded() {
  local node="$1"
  local attempts=$(jq -r ".remediation.attempts[\"$node\"] // 0" "$state_file")
  
  if [ "$attempts" -ge "$REBOOT_MAX_ATTEMPTS" ]; then
    echo "Node $node has exceeded max reboot attempts ($attempts/$REBOOT_MAX_ATTEMPTS)"
    return 0
  fi
  
  return 1
}

# Issue soft reboot (graceful shutdown)
soft_reboot() {
  local node="$1"
  local node_addr
  node_addr=$(jq -r ".[] | select(.id == \"$node\") | (.sshHost // .address // .netbirdIp // .hostname // \"\")" "$nodes_file")
  
  [ -z "$node_addr" ] && {
    echo "Node not found: $node" >&2
    return 1
  }
  
  echo "Issuing soft reboot to $node ($node_addr)..."
  
  # SSH into node and schedule reboot
  if ssh -o ConnectTimeout=10 "root@${node_addr}" "shutdown -r +5 'Supervisor initiated soft reboot'" 2>/dev/null; then
    echo "✓ Soft reboot queued on $node (+5 min delay)"
    record_reboot_attempt "$node"
    return 0
  else
    echo "✗ Failed to issue soft reboot to $node" >&2
    return 1
  fi
}

# Issue hard reboot (immediate)
hard_reboot() {
  local node="$1"
  local node_addr
  node_addr=$(jq -r ".[] | select(.id == \"$node\") | (.sshHost // .address // .netbirdIp // .hostname // \"\")" "$nodes_file")
  
  [ -z "$node_addr" ] && {
    echo "Node not found: $node" >&2
    return 1
  }
  
  echo "Issuing HARD reboot to $node ($node_addr)..."
  
  if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "root@${node_addr}" "reboot -f" 2>/dev/null; then
    echo "✓ Hard reboot initiated on $node (immediate)"
    record_reboot_attempt "$node"
    return 0
  else
    echo "✗ Failed to issue hard reboot to $node" >&2
    return 1
  fi
}

# Quarantine node (isolate from failover pool)
quarantine_node() {
  local node="$1"
  
  jq --arg node "$node" '.remediation.quarantined += [$node] | .remediation.quarantined |= unique' \
    "$state_file" >"${state_file}.tmp"
  
  mv "${state_file}.tmp" "$state_file"
  echo "✓ Node $node quarantined"
}

# Remove node from quarantine
unquarantine_node() {
  local node="$1"
  
  jq --arg node "$node" '.remediation.quarantined -= [$node]' "$state_file" >"${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
  
  reset_cooldown "$node"
  echo "✓ Node $node removed from quarantine"
}

# Assess node health and apply remediation
assess_and_remediate() {
  local node="$1"
  local node_addr
  node_addr=$(jq -r ".[] | select(.id == \"$node\") | (.address // .netbirdIp // .hostname // \"\")" "$nodes_file")
  
  [ -z "$node_addr" ] && {
    echo "Node not found: $node" >&2
    return 1
  }
  
  echo "Assessing health of $node ($node_addr)..."
  
  # Try ICMP ping first
  local healthy=0
  for i in $(seq 1 "$HEALTH_CHECK_RETRIES"); do
    if ping -c 1 -W 2 "$node_addr" >/dev/null 2>&1; then
      echo "  ✓ Ping OK (attempt $i/$HEALTH_CHECK_RETRIES)"
      healthy=1
      break
    fi
  done
  
  if [ "$healthy" -eq 1 ]; then
    echo "✓ Node $node is healthy"
    return 0
  fi
  
  echo "✗ Node $node health check failed"
  
  # Apply remediation
  if [ -n "$force" ] && [ "$force" = "--force" ]; then
    hard_reboot "$node"
    quarantine_node "$node"
    return 1
  else
    if is_reboot_on_cooldown "$node"; then
      return 1
    fi
    
    if is_max_attempts_exceeded "$node"; then
      echo "Max reboot attempts exceeded, quarantining node"
      quarantine_node "$node"
      return 2
    fi
    
    soft_reboot "$node"
    return 1
  fi
}

ensure_remediation_state

case "$action" in
  assess-and-remediate)
    assess_and_remediate "$node_id"
    ;;
  soft-reboot)
    [ -n "$force" ] && {
      echo "Error: soft-reboot does not support --force" >&2
      exit 1
    }
    if is_reboot_on_cooldown "$node_id"; then
      exit 1
    fi
    soft_reboot "$node_id"
    ;;
  hard-reboot)
    hard_reboot "$node_id"
    ;;
  quarantine)
    quarantine_node "$node_id"
    ;;
  unquarantine)
    unquarantine_node "$node_id"
    ;;
  *)
    echo "Unknown action: $action" >&2
    exit 1
    ;;
esac
