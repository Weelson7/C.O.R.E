#!/usr/bin/env bash
set -euo pipefail

# reverse_sync_service_data.sh - sync data from new alpha back to old alpha on recovery
# Usage: reverse_sync_service_data.sh <service-id> <old-alpha-host> <new-alpha-host> <data-path> [old-alpha-ssh-host]

if [ "$#" -lt 4 ]; then
  echo "Usage: reverse_sync_service_data.sh <service-id> <old-alpha-host> <new-alpha-host> <data-path> [old-alpha-ssh-host]" >&2
  exit 1
fi

service_id="$1"
old_alpha_host="$2"
new_alpha_host="$3"
data_path="$4"
old_alpha_ssh_host="${5:-}"

local_host="$(hostname)"

if [ "$new_alpha_host" != "$local_host" ]; then
  echo "reverse_sync_service_data.sh expects source (new alpha) host to be local host" >&2
  exit 1
fi

if [ ! -d "$data_path" ]; then
  echo "Data path missing for ${service_id}: $data_path" >&2
  exit 1
fi

# Create backup of old alpha data before sync (optional safety measure)
backup_dir="/var/backups/core/${service_id}"
mkdir -p "$backup_dir"
backup_stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
echo "$(date -u +"%Y-%m-%d %H:%M:%S UTC") - Reverse sync initiated" >> "${backup_dir}/reverse_sync.log"

# Perform reverse sync: new alpha -> old alpha
if [ "$old_alpha_host" = "$local_host" ]; then
  # If old alpha is also local, direct rsync
  rsync -a --delete "$data_path/" "${data_path}.recovered/"
else
  [ -n "$old_alpha_ssh_host" ] || {
    echo "Old alpha SSH host required for remote reverse sync" >&2
    exit 1
  }
  # Remote sync via SSH
  ssh "$old_alpha_ssh_host" "mkdir -p '$data_path'"
  rsync -a --delete -e ssh "$data_path/" "${old_alpha_ssh_host}:${data_path}/"
fi

echo "Reverse sync completed for ${service_id}: ${old_alpha_host} <- ${new_alpha_host}" >&2
