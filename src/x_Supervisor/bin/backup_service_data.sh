#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "Usage: backup_service_data.sh <service-id> <source-path> <backup-dir> <gamma-host> <gamma-ssh-host>" >&2
  exit 1
fi

service_id="$1"
source_path="$2"
backup_dir="$3"
gamma_host="$4"
gamma_ssh_host="$5"

local_host="$(hostname)"
mkdir -p "$backup_dir"

stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
archive="${backup_dir}/${service_id}-${stamp}.tar.gz"

if [ -d "$source_path" ]; then
  tar -czf "$archive" -C "$source_path" .
else
  tar -czf "$archive" --files-from /dev/null
fi

if [ "$gamma_host" = "$local_host" ] || [ -z "$gamma_ssh_host" ]; then
  exit 0
fi

ssh "$gamma_ssh_host" "mkdir -p '$backup_dir'"
rsync -a -e ssh "$archive" "${gamma_ssh_host}:${backup_dir}/"
