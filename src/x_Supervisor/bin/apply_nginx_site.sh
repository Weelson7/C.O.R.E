#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: apply_nginx_site.sh <domain> <target-hostname> [target-ssh-host]" >&2
  exit 1
fi

domain="$1"
target_host="$2"
target_ssh_host="${3:-}"

site_file="/etc/nginx/sites-available/${domain}"
site_link="/etc/nginx/sites-enabled/${domain}"

run_local() {
  [ -f "$site_file" ] || {
    echo "Nginx site file missing: $site_file" >&2
    exit 1
  }

  sudo ln -sf "$site_file" "$site_link"
  sudo nginx -t
  sudo systemctl reload nginx
}

local_host="$(hostname)"

if [ "$local_host" = "$target_host" ] || [ -z "$target_ssh_host" ]; then
  run_local
  exit 0
fi

ssh "$target_ssh_host" "bash -lc '
  set -euo pipefail
  [ -f "$site_file" ]
  sudo ln -sf "$site_file" "$site_link"
  sudo nginx -t
  sudo systemctl reload nginx
'"
