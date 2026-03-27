#!/usr/bin/env bash
set -euo pipefail

# ha_cluster.sh - orchestrate high-availability clustering for supervisor instances
# Usage: ha_cluster.sh <action> <cluster-config> [cluster-name]
# Actions: init, join, health, failover-leader, elect-leader, status

if [ "$#" -lt 2 ]; then
  echo "Usage: ha_cluster.sh <action> <cluster-config> [cluster-name]" >&2
  exit 1
fi

action="$1"
cluster_config="$2"
cluster_name="${3:-default}"

if [ "$action" != "init" ] && [ ! -f "$cluster_config" ]; then
  echo "Cluster config not found: $cluster_config" >&2
  exit 1
fi

local_hostname=$(hostname)
local_ip=$(hostname -I | awk '{print $1}')

# Initialize cluster state
init_cluster() {
  local name="$1"
  
  cat > "$cluster_config" <<EOF
{
  "cluster_name": "$name",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "members": [
    {
      "hostname": "$local_hostname",
      "ip": "$local_ip",
      "role": "leader",
      "state": "healthy",
      "last_heartbeat": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
  ],
  "leader": {
    "hostname": "$local_hostname",
    "ip": "$local_ip",
    "elected_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  },
  "quorum": 1,
  "version": "1.0.0"
}
EOF
  
  echo "✓ HA cluster initialized: $name"
}

# Add member to cluster
join_cluster() {
  local peer_ip="$1"
  local peer_hostname="${2:-$(ssh "$peer_ip" hostname 2>/dev/null || echo "unknown")}"
  
  [ -z "$peer_ip" ] && {
    echo "Error: peer IP required" >&2
    return 1
  }
  
  echo "Joining cluster via peer: $peer_ip"
  
  # Fetch cluster config from peer
  if ! scp -q "$peer_ip:$cluster_config" "${cluster_config}.remote" 2>/dev/null; then
    echo "✗ Failed to fetch cluster config from $peer_ip" >&2
    return 1
  fi
  
  # Merge local member into remote config
  jq --arg hostname "$local_hostname" \
     --arg ip "$local_ip" \
     '.members += [{
       "hostname": $hostname,
       "ip": $ip,
       "role": "member",
       "state": "joining",
       "last_heartbeat": now | todate
     }] | .members |= unique_by(.hostname) | .quorum = (.members | length / 2 | ceil)' \
    "${cluster_config}.remote" > "$cluster_config"
  
  rm -f "${cluster_config}.remote"
  
  # Sync updated config back to peer
  if scp -q "$cluster_config" "$peer_ip:$cluster_config.merged" 2>/dev/null; then
    ssh "$peer_ip" "mv $cluster_config.merged $cluster_config" 2>/dev/null || true
    echo "✓ Joined cluster as member"
  else
    echo "✗ Failed to sync cluster config to $peer_ip" >&2
    return 1
  fi
  
  return 0
}

# Perform regular health check
health_check() {
  echo "Performing cluster health check..."
  
  local healthy_count=0
  local total_count=$(jq '.members | length' "$cluster_config")
  
  while IFS=, read -r hostname ip; do
    local state="unknown"
    
    # Try to reach member
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      state="healthy"
      healthy_count=$((healthy_count + 1))
    else
      state="unhealthy"
    fi
    
    echo "  $hostname ($ip): $state"
      done < <(jq -r '.members[] | "\(.hostname),\(.ip)"' "$cluster_config")
  
  local quorum=$(jq '.quorum' "$cluster_config")
  if [ "$healthy_count" -ge "$quorum" ]; then
    echo "✓ Cluster is healthy ($healthy_count/$total_count members)"
    return 0
  else
    echo "✗ Cluster is UNHEALTHY ($healthy_count/$total_count members, quorum=$quorum)"
    return 1
  fi
}

# Elect new leader
elect_leader() {
  echo "Initiating leader election..."
  
  local members=$(jq -r '.members[] | select(.state == "healthy") | .hostname' "$cluster_config")
  local member_count=$(echo "$members" | wc -l)
  
  if [ "$member_count" -lt 1 ]; then
    echo "✗ No healthy members available for election" >&2
    return 1
  fi
  
  # Simple election: first healthy member wins (in production: use Raft)
  local elected=$(echo "$members" | head -1)
  local elected_ip=$(jq -r ".members[] | select(.hostname == \"$elected\") | .ip" "$cluster_config")
  
  jq --arg hostname "$elected" \
     --arg ip "$elected_ip" \
     '.leader = {hostname: $hostname, ip: $ip, elected_at: (now | todate)}' \
    "$cluster_config" > "${cluster_config}.tmp"
  
  mv "${cluster_config}.tmp" "$cluster_config"
  
  echo "✓ Leader elected: $elected ($elected_ip)"
}

# Failover if leader is unhealthy
failover_leader() {
  local current_leader=$(jq -r '.leader.hostname' "$cluster_config")
  local current_leader_ip=$(jq -r '.leader.ip' "$cluster_config")
  
  echo "Checking leader health: $current_leader ($current_leader_ip)"
  
  if ping -c 1 -W 2 "$current_leader_ip" >/dev/null 2>&1; then
    echo "✓ Leader is healthy"
    return 0
  fi
  
  echo "✗ Leader is unhealthy, triggering failover..."
  
  # Mark leader as unhealthy
  jq ".members[] |= if .hostname == \"$current_leader\" then .state = \"unhealthy\" else . end" \
    "$cluster_config" > "${cluster_config}.tmp"
  
  mv "${cluster_config}.tmp" "$cluster_config"
  
  # Elect new leader
  elect_leader
}

# Get cluster status
cluster_status() {
  echo "Cluster: $(jq -r '.cluster_name' "$cluster_config")"
  echo "Members: $(jq '.members | length' "$cluster_config")"
  echo "Leader: $(jq -r '.leader.hostname' "$cluster_config") ($(jq -r '.leader.ip' "$cluster_config"))"
  echo "Quorum: $(jq '.quorum' "$cluster_config")"
  echo ""
  echo "Member List:"
  jq -r '.members[] | "  \(.hostname): \(.state) (\(.role))"' "$cluster_config"
}

case "$action" in
  init)
    init_cluster "$cluster_name"
    ;;
  join)
    join_cluster "${3:-}" "${4:-}"
    ;;
  health)
    health_check
    ;;
  elect-leader)
    elect_leader
    ;;
  failover-leader)
    failover_leader
    ;;
  status)
    cluster_status
    ;;
  *)
    echo "Unknown action: $action" >&2
    exit 1
    ;;
esac
