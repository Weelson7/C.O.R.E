#!/usr/bin/env bash
set -euo pipefail

# provision_ssh_keys.sh - distribute SSH keys to all Netbird nodes
# Usage: provision_ssh_keys.sh <nodes-file> <private-key-path> <remote-user> [--dry-run]

if [ "$#" -lt 3 ]; then
  echo "Usage: provision_ssh_keys.sh <nodes-file> <private-key-path> <remote-user> [--dry-run]" >&2
  exit 1
fi

nodes_file="$1"
private_key="$2"
remote_user="$3"
dry_run="${4:-}"

[ -f "$nodes_file" ] || {
  echo "Nodes file not found: $nodes_file" >&2
  exit 1
}

[ -f "$private_key" ] || {
  echo "Private key not found: $private_key" >&2
  exit 1
}

[ -r "$private_key" ] || {
  echo "Cannot read private key: $private_key" >&2
  exit 1
}

# Extract public key
public_key="${private_key}.pub"
if [ ! -f "$public_key" ]; then
  echo "Generating public key from private key..."
  ssh-keygen -y -f "$private_key" > "$public_key"
fi

echo "Provisioning SSH keys to Netbird nodes..."
echo "  Remote user: $remote_user"
echo "  Private key: $private_key"
echo "  Public key: $public_key"
[ -n "$dry_run" ] && echo "  [DRY RUN MODE]"
echo ""

# Track results
success_count=0
failure_count=0

while IFS=, read -r node_id node_addr; do
  [ -z "$node_id" ] && continue

  echo -n "  Node: $node_id ($node_addr)... "

  if [ -n "$dry_run" ]; then
    echo "SKIP (dry-run)"
    continue
  fi

  # Test SSH connection
  if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$private_key" "${remote_user}@${node_addr}" "true" 2>/dev/null; then
    echo "FAIL (no SSH access)"
    failure_count=$((failure_count + 1))
    continue
  fi

  # Create .ssh directory if needed
  ssh -o ConnectTimeout=5 -i "$private_key" "${remote_user}@${node_addr}" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null || {
    echo "FAIL (cannot create .ssh)"
    failure_count=$((failure_count + 1))
    continue
  }

  # Append public key
  cat "$public_key" | ssh -o ConnectTimeout=5 -i "$private_key" "${remote_user}@${node_addr}" \
    "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null || {
    echo "FAIL (cannot write authorized_keys)"
    failure_count=$((failure_count + 1))
    continue
  }

  echo "OK"
  success_count=$((success_count + 1))
done < <(jq -r '.[] | "\(.id),\(.address // .netbirdIp // .hostname // "")"' "$nodes_file" 2>/dev/null)

echo ""
echo "SSH provisioning complete: $success_count OK, $failure_count failed"

[ "$failure_count" -eq 0 ] || exit 1
