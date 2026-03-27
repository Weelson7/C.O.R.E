#!/usr/bin/env bash
set -euo pipefail

# raft_consensus.sh - implement simplified Raft consensus for split-brain protection
# Usage: raft_consensus.sh <action> <nodes-file> <state-file> [node-id]
# Actions: vote, commit, quorum-check, become-leader, become-follower

if [ "$#" -lt 3 ]; then
  echo "Usage: raft_consensus.sh <action> <nodes-file> <state-file> [node-id]" >&2
  exit 1
fi

action="$1"
nodes_file="$2"
state_file="$3"
node_id="${4:-$(hostname)}"

[ -f "$nodes_file" ] || {
  echo "Nodes file not found: $nodes_file" >&2
  exit 1
}

total_nodes=$(jq 'length' "$nodes_file")
quorum=$((total_nodes / 2 + 1))

# Initialize consensus state if needed
ensure_consensus_state() {
  if ! jq -e '.consensus != null' "$state_file" >/dev/null 2>&1; then
    jq '. + {consensus: {term: 0, votedFor: null, leader: null, followers: []}}' "$state_file" >"${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
  fi
}

# Get current term
get_term() {
  jq -r '.consensus.term // 0' "$state_file"
}

# Increment term (on election timeout)
increment_term() {
  local new_term=$(($(get_term) + 1))
  jq --arg term "$new_term" '.consensus.term = ($term | tonumber)' "$state_file" >"${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
  echo "$new_term"
}

# Cast vote for leader in current term
vote_for() {
  local candidate="$1"
  local term=$(get_term)
  
  jq --arg candidate "$candidate" --arg term "$term" \
    '.consensus.term = ($term | tonumber) | .consensus.votedFor = $candidate' \
    "$state_file" >"${state_file}.tmp"
  
  mv "${state_file}.tmp" "$state_file"
  echo "Voted for $candidate in term $term"
}

# Check if we have quorum for an action
check_quorum() {
  local action_type="$1"
  local supporters=$(jq -r ".consensus.${action_type}Votes // [] | length" "$state_file")
  
  if [ "$supporters" -ge "$quorum" ]; then
    echo "✓ Quorum achieved: $supporters/$quorum nodes"
    return 0
  else
    echo "✗ Quorum not achieved: $supporters/$quorum nodes"
    return 1
  fi
}

# Attempt to become leader
become_leader() {
  local term=$(increment_term)
  
  # Vote for ourselves
  vote_for "$node_id"
  
  # Request votes from all other nodes (simulation - in production, send RPC)
  local votes=1  # Ourselves
  
  while read -r peer; do
    peer=$(echo "$peer" | tr -d '"')
    # Simulate vote request (in production: SSH RPC or HTTP call)
    if [ -n "$peer" ]; then
      votes=$((votes + 1))
    fi
  done < <(jq -r '.[] | select(.id != null) | .id' "$nodes_file")
  
  if [ "$votes" -ge "$quorum" ]; then
    jq --arg leader "$node_id" --arg term "$term" \
      '.consensus.leader = $leader | .consensus.term = ($term | tonumber)' \
      "$state_file" >"${state_file}.tmp"
    
    mv "${state_file}.tmp" "$state_file"
    echo "✓ Became leader in term $term (term=$term)"
    return 0
  else
    echo "✗ Failed to gain quorum (got $votes/$quorum votes)"
    return 1
  fi
}

# Set current leader (follower perspective)
set_leader() {
  local leader="$1"
  
  jq --arg leader "$leader" '.consensus.leader = $leader' "$state_file" >"${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
  
  echo "Set leader to: $leader"
}

# Get current leader
get_leader() {
  jq -r '.consensus.leader // "none"' "$state_file"
}

# Detect split-brain: multiple nodes claim leadership
detect_split_brain() {
  local leader_count
  leader_count=$(jq '[.nodes[]? | select(.role == "alpha")] | length' "$state_file")
  
  if [ "$leader_count" -gt 1 ]; then
    echo "⚠ SPLIT-BRAIN DETECTED: $leader_count nodes claiming leadership"
    jq '.split_brain_detected = true' "$state_file" >"${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
    return 1
  fi
  
  echo "✓ No split-brain detected"
  return 0
}

ensure_consensus_state

case "$action" in
  vote)
    vote_for "${5:-candidate}"
    ;;
  quorum-check)
    check_quorum "${5:-failover}"
    ;;
  become-leader)
    become_leader
    ;;
  set-leader)
    set_leader "${5:-}"
    ;;
  get-leader)
    get_leader
    ;;
  detect-split-brain)
    detect_split_brain
    ;;
  *)
    echo "Unknown action: $action" >&2
    exit 1
    ;;
esac
