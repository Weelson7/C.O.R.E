#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 6 ]; then
  echo "Usage: sync_service_data.sh <service-id> <source-host> <target-host> <source-path> <target-path> <target-ssh-host>" >&2
  exit 1
fi

service_id="$1"
source_host="$2"
target_host="$3"
source_path="$4"
target_path="$5"
target_ssh_host="$6"

local_host="$(hostname)"

if [ "$source_host" != "$local_host" ]; then
  echo "sync_service_data.sh expects source host to be local host" >&2
  exit 1
fi

if [ ! -d "$source_path" ]; then
  echo "Source path missing for ${service_id}: $source_path" >&2
  exit 1
fi

if [ "$target_host" = "$local_host" ] || [ -z "$target_ssh_host" ]; then
  mkdir -p "$target_path"
  rsync -a --delete "$source_path/" "$target_path/"
  exit 0
fi

ssh "$target_ssh_host" "mkdir -p '$target_path'"
rsync -a --delete -e ssh "$source_path/" "${target_ssh_host}:${target_path}/"
