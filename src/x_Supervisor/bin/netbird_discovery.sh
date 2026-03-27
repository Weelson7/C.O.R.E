#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

extract_local_ip() {
  netbird status 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true
}

discover_from_json() {
  local raw
  raw="$(netbird status --json 2>/dev/null || true)"
  [ -n "$raw" ] || return 1

  echo "$raw" | jq -c '
    [
      ((.peers // .Peers // .peerConnections // .PeerConnections // [])[]?)
      | {
          id: (.id // .peerID // .publicKey // .hostname // .name // ""),
          hostname: (.hostname // .name // .fqdn // ""),
          netbirdIp: (.ip // .allowedIP // .address // ""),
          healthy: true,
          isSupervisor: false,
          isSubSupervisor: false,
          sshHost: "",
          alphaServices: [],
          betaServices: [],
          gammaServices: []
        }
    ]
    | map(select(.id != "" or .hostname != "" or .netbirdIp != ""))
  '
}

discover_fallback() {
  local local_ip
  local host

  host="$(hostname)"
  local_ip="$(extract_local_ip)"

  jq -cn --arg host "$host" --arg ip "$local_ip" '
    [
      {
        id: "node-0",
        hostname: $host,
        netbirdIp: $ip,
        healthy: true,
        isSupervisor: true,
        isSubSupervisor: false,
        sshHost: "",
        alphaServices: [],
        betaServices: [],
        gammaServices: []
      }
    ]
  '
}

main() {
  require_cmd jq
  require_cmd netbird

  if discover_from_json >/tmp/core-supervisor-netbird.json 2>/dev/null; then
    if [ "$(jq 'length' /tmp/core-supervisor-netbird.json)" -gt 0 ]; then
      cat /tmp/core-supervisor-netbird.json
      rm -f /tmp/core-supervisor-netbird.json
      exit 0
    fi
  fi

  rm -f /tmp/core-supervisor-netbird.json
  discover_fallback
}

main "$@"
