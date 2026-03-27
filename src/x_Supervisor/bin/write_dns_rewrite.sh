#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REWRITES_FILE="${ROOT_DIR}/data/dns_rewrites.json"

if [ "$#" -lt 2 ]; then
  echo "Usage: write_dns_rewrite.sh <domain> <target-ip>" >&2
  exit 1
fi

domain="$1"
target_ip="$2"

command -v jq >/dev/null 2>&1 || {
  echo "Missing jq" >&2
  exit 1
}

jq --arg domain "$domain" --arg ip "$target_ip" '
  map(select(.domain != $domain)) + [{domain:$domain,targetIp:$ip,updatedAt:(now|todateiso8601)}]
' "$REWRITES_FILE" >"${REWRITES_FILE}.tmp"

mv "${REWRITES_FILE}.tmp" "$REWRITES_FILE"

if [ -n "${ADGUARD_URL:-}" ] && [ -n "${ADGUARD_USER:-}" ] && [ -n "${ADGUARD_PASS:-}" ]; then
  curl -fsS -u "${ADGUARD_USER}:${ADGUARD_PASS}" \
    -H "Content-Type: application/json" \
    -X POST "${ADGUARD_URL%/}/control/rewrite/add" \
    -d "{\"domain\":\"${domain}\",\"answer\":\"${target_ip}\"}" >/dev/null || true
fi
