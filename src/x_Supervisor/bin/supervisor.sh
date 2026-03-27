#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
SERVICES_FILE="${DATA_DIR}/services.json"
NODES_FILE="${DATA_DIR}/nodes.json"
STATE_FILE="${DATA_DIR}/state.json"
EVENTS_FILE="${DATA_DIR}/events.log"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[x_supervisor] missing command: $1" >&2
    exit 1
  }
}

usage() {
  cat <<'USAGE'
Usage:
  supervisor.sh init
  supervisor.sh discover-nodes
  supervisor.sh run-cycle [--execute]
  supervisor.sh status-json
  supervisor.sh set-node-health <node-id> <true|false>
  supervisor.sh set-service-status <service-id> <healthy|degraded|down|failover-active|unknown>
  supervisor.sh assign-role <service-id> <alpha|beta|gamma> <node-id|none>
  supervisor.sh set-force-active <node-id|none>
  supervisor.sh set-maintenance <node|service> <id> <on|off>
  supervisor.sh deploy-all-services [--skip-pull]
USAGE
}

ensure_files() {
  [ -f "$SERVICES_FILE" ] || {
    echo "Missing $SERVICES_FILE" >&2
    exit 1
  }
  [ -f "$NODES_FILE" ] || {
    echo "Missing $NODES_FILE" >&2
    exit 1
  }
  [ -f "$STATE_FILE" ] || {
    echo "Missing $STATE_FILE" >&2
    exit 1
  }
  [ -f "$EVENTS_FILE" ] || touch "$EVENTS_FILE"
}

log_event() {
  local level="$1"
  local event="$2"
  local actor="$3"
  local reason="$4"
  local outcome="$5"
  local ts

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  jq -cn \
    --arg ts "$ts" \
    --arg level "$level" \
    --arg event "$event" \
    --arg actor "$actor" \
    --arg reason "$reason" \
    --arg outcome "$outcome" \
    '{ts:$ts,level:$level,event:$event,actor:$actor,reason:$reason,outcome:$outcome}' >>"$EVENTS_FILE"
}

set_json_file() {
  local file="$1"
  local filter="$2"
  shift 2
  jq "$filter" "$@" >"${file}.tmp"
  mv "${file}.tmp" "$file"
}

merge_discovered_nodes() {
  local discovered
  discovered="$(${SCRIPT_DIR}/netbird_discovery.sh)"

  jq --argjson discovered "$discovered" '
    def key(n):
      if (n.id // "") != "" then ("id:" + n.id)
      elif (n.netbirdIp // "") != "" then ("ip:" + n.netbirdIp)
      else ("host:" + (n.hostname // "")) end;

    def normalize_existing(n):
      {
        id: (n.id // ""),
        hostname: (n.hostname // ""),
        netbirdIp: (n.netbirdIp // ""),
        healthy: (n.healthy // false),
        isSupervisor: (n.isSupervisor // false),
        isSubSupervisor: (n.isSubSupervisor // false),
        sshHost: (n.sshHost // ""),
        alphaServices: (n.alphaServices // []),
        betaServices: (n.betaServices // []),
        gammaServices: (n.gammaServices // [])
      };

    def merge_node(existing; discovered):
      existing
      + {
          id: (if existing.id != "" then existing.id else (discovered.id // "") end),
          hostname: (if (discovered.hostname // "") != "" then discovered.hostname else existing.hostname end),
          netbirdIp: (if (discovered.netbirdIp // "") != "" then discovered.netbirdIp else existing.netbirdIp end),
          healthy: (discovered.healthy // true)
        };

    (map(normalize_existing(.)) | map({k:key(.),v:.}) | from_entries) as $existingMap
    | ($discovered | map({k:key(.),v:.}) | from_entries) as $discoveredMap
    | ($existingMap + $discoveredMap | keys[]) as $k
    | [
        ($existingMap[$k] // {
          id: "",
          hostname: "",
          netbirdIp: "",
          healthy: false,
          isSupervisor: false,
          isSubSupervisor: false,
          sshHost: "",
          alphaServices: [],
          betaServices: [],
          gammaServices: []
        }) as $existing
        | ($discoveredMap[$k] // null) as $new
        | if $new == null then
            $existing + {healthy:false}
          else
            merge_node($existing; $new)
          end
      ]
    | map(select((.id != "") or (.hostname != "") or (.netbirdIp != "")))
  ' "$NODES_FILE" >"${NODES_FILE}.tmp"

  mv "${NODES_FILE}.tmp" "$NODES_FILE"
  log_event "info" "discover_nodes" "system" "netbird discovery completed" "nodes merged"
}

recompute_node_assignments() {
  jq --argjson services "$(cat "$SERVICES_FILE")" '
    map(.alphaServices=[] | .betaServices=[] | .gammaServices=[]) as $nodes
    | reduce $services[] as $svc ($nodes;
        (if ($svc.roleAssignments.alpha != null) then
          map(if .id == $svc.roleAssignments.alpha then .alphaServices += [$svc.id] else . end)
        else . end)
        | (if ($svc.roleAssignments.beta != null) then
            map(if .id == $svc.roleAssignments.beta then .betaServices += [$svc.id] else . end)
          else . end)
        | (if ($svc.roleAssignments.gamma != null) then
            map(if .id == $svc.roleAssignments.gamma then .gammaServices += [$svc.id] else . end)
          else . end)
      )
  ' "$NODES_FILE" >"${NODES_FILE}.tmp"

  mv "${NODES_FILE}.tmp" "$NODES_FILE"
}

detect_and_reconcile_recovery() {
  # Detect when old alpha node recovers after failover and perform reverse sync
  # This prevents data loss and inconsistency
  jq --argjson nodes "$(cat "$NODES_FILE")" --argjson services "$(cat "$SERVICES_FILE")" '
    reduce .[] as $svc (
      {actions:[]};
      ($svc.id) as $sid
      | ($svc.roleAssignments.alpha) as $current_alpha
      | ((.serviceState[$sid].lastPromotionFrom // "") | tostring) as $old_alpha_id
      | (if ($old_alpha_id != "") then ($nodes | map(select(.id == $old_alpha_id)) | .[0]) else null end) as $old_alpha_node
      | if ($old_alpha_node != null) and ($old_alpha_node.healthy == true) then
          .actions += [{
            event:"recovery_detected",
            service:$sid,
            oldAlpha:$old_alpha_id,
            currentAlpha:$current_alpha,
            reason:"old alpha node recovery after failover detected"
          }]
        else . end
    )
  ' "$STATE_FILE" | jq -c '.actions[]' | while IFS= read -r action; do
    local event service old_alpha current_alpha reason
    event="$(echo "$action" | jq -r '.event')"
    service="$(echo "$action" | jq -r '.service')"
    old_alpha="$(echo "$action" | jq -r '.oldAlpha')"
    current_alpha="$(echo "$action" | jq -r '.currentAlpha')"
    reason="$(echo "$action" | jq -r '.reason')"

    if [ "$event" = "recovery_detected" ]; then
      log_event "warning" "alpha_recovery_detected" "system" "$reason" "service=$service old_alpha=$old_alpha current=$current_alpha"
    fi
  done
}

apply_supervisor_takeover() {
  local active primary sub force auto
  force="$(jq -r '.supervisor.forceActiveNodeId // empty' "$STATE_FILE")"

  if [ -n "$force" ]; then
    set_json_file "$STATE_FILE" '.supervisor.activeNodeId = $node' --arg node "$force" "$STATE_FILE"
    log_event "warning" "supervisor_override" "operator" "force active supervisor" "active node set to override"
    return
  fi

  auto="$(jq -r '.supervisor.automaticTakeover' "$STATE_FILE")"
  [ "$auto" = "true" ] || return

  active="$(jq -r '.supervisor.activeNodeId' "$STATE_FILE")"
  primary="$(jq -r '.supervisor.primaryNodeId' "$STATE_FILE")"
  sub="$(jq -r '.supervisor.subSupervisorNodeId' "$STATE_FILE")"

  local active_healthy sub_healthy sub_maintenance
  active_healthy="$(jq -r --arg id "$active" 'map(select(.id==$id)) | .[0].healthy // false' "$NODES_FILE")"
  sub_healthy="$(jq -r --arg id "$sub" 'map(select(.id==$id)) | .[0].healthy // false' "$NODES_FILE")"
  sub_maintenance="$(jq -r --arg id "$sub" '.supervisor.maintenance.nodes | index($id) != null' "$STATE_FILE")"

  if [ "$active_healthy" != "true" ] && [ "$sub_healthy" = "true" ] && [ "$sub_maintenance" != "true" ]; then
    set_json_file "$STATE_FILE" '.supervisor.activeNodeId = $node' --arg node "$sub" "$STATE_FILE"
    log_event "critical" "supervisor_failover" "system" "active supervisor unhealthy" "sub-supervisor takeover activated"
    return
  fi

  if [ "$active" != "$primary" ]; then
    local primary_healthy
    primary_healthy="$(jq -r --arg id "$primary" 'map(select(.id==$id)) | .[0].healthy // false' "$NODES_FILE")"
    if [ "$primary_healthy" = "true" ]; then
      log_event "info" "supervisor_recovered" "system" "primary supervisor back online" "active remains unchanged by policy"
    fi
  fi
}

apply_service_failover() {
  local now timeout
  now="$(date +%s)"
  timeout="$(jq -r '.policy.promotionTimeoutSeconds' "$STATE_FILE")"

  jq --argjson now "$now" --argjson timeout "$timeout" --argjson nodes "$(cat "$NODES_FILE")" --argjson state "$(cat "$STATE_FILE")" '
    def nodeHealthy(id):
      ($nodes | map(select(.id == id)) | .[0].healthy) // false;

    def nodeMaintenance(id):
      ($state.supervisor.maintenance.nodes | index(id)) != null;

    def serviceMaintenance(id):
      ($state.supervisor.maintenance.services | index(id)) != null;

    reduce .[] as $svc (
      {services:[], serviceState:($state.serviceState // {}), events:[]};
      ($svc.id) as $sid
      | ($svc.roleAssignments.alpha) as $alpha
      | ($svc.roleAssignments.beta) as $beta
      | ($svc.roleAssignments.gamma) as $gamma
      | ($svc.status // "unknown") as $svcStatus
      | (.serviceState[$sid].alphaDownSince // null) as $alphaDownSince
      | (if ($alpha != null and (nodeHealthy($alpha) | not) and (serviceMaintenance($sid) | not) and (nodeMaintenance($alpha) | not)) then true else false end) as $alphaIsDown
      | if $alphaIsDown then
          if $alphaDownSince == null then
            .serviceState[$sid].alphaDownSince = $now
            | .events += [{
                level:"warning",
                event:"alpha_down_detected",
                actor:"system",
                reason:("alpha down for " + $sid),
                outcome:"started downtime timer"
              }]
            | .services += [$svc]
          else
            if (($now - $alphaDownSince) >= $timeout) and ($beta != null) and (nodeHealthy($beta)) and (nodeMaintenance($beta) | not) then
              .serviceState[$sid].alphaDownSince = null
              | .serviceState[$sid].lastPromotionFrom = $alpha
              | .serviceState[$sid].lastPromotionTo = $beta
              | .serviceState[$sid].lastPromotionAt = $now
              | .events += [{
                  level:"critical",
                  event:"service_promoted",
                  actor:"system",
                  reason:("alpha down >= timeout for " + $sid),
                  outcome:("promoted " + $beta + " to alpha")
                }]
              | .services += [
                  $svc
                  | .roleAssignments.alpha = $beta
                  | .roleAssignments.beta = null
                  | .status = "failover-active"
                ]
            else
              .services += [$svc]
            end
          end
        else
          .serviceState[$sid].alphaDownSince = null
          | .services += [
              if $svcStatus == "failover-active" then $svc else ($svc | .status = "healthy") end
            ]
        end
    )
  ' "$SERVICES_FILE" >"${DATA_DIR}/cycle_result.json"

  jq '.services' "${DATA_DIR}/cycle_result.json" >"${SERVICES_FILE}.tmp"
  mv "${SERVICES_FILE}.tmp" "$SERVICES_FILE"

  jq --argjson base "$(cat "$STATE_FILE")" '.serviceState' "${DATA_DIR}/cycle_result.json" >"${DATA_DIR}/service_state.tmp"
  jq --argjson svcState "$(cat "${DATA_DIR}/service_state.tmp")" '.serviceState = $svcState' "$STATE_FILE" >"${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"

  jq -c '.events[]' "${DATA_DIR}/cycle_result.json" | while IFS= read -r event; do
    local level name reason outcome
    level="$(echo "$event" | jq -r '.level')"
    name="$(echo "$event" | jq -r '.event')"
    reason="$(echo "$event" | jq -r '.reason')"
    outcome="$(echo "$event" | jq -r '.outcome')"
    log_event "$level" "$name" "system" "$reason" "$outcome"
  done

  rm -f "${DATA_DIR}/service_state.tmp" "${DATA_DIR}/cycle_result.json"
}

execute_demote_actions() {
  local execute="$1"
  local local_host
  local_host="$(hostname)"

  run_action() {
    local event_name="$1"
    local reason="$2"
    shift 2

    if "$@"; then
      log_event "info" "$event_name" "system" "$reason" "applied"
    else
      log_event "error" "$event_name" "system" "$reason" "failed"
    fi
  }

  # Find services where alpha role was reassigned (e.g., beta -> alpha)
  jq --argjson nodes "$(cat "$NODES_FILE")" '
    map(
      select(
        (.roleAssignments.alpha != null) and 
        (.status == "failover-active")
      ) | 
      {
        id: .id,
        containerized: .containerized,
        currentAlpha: .roleAssignments.alpha,
        oldAlpha: ($serviceState[.id].lastPromotionFrom // ""),
        domain: .domain
      }
    )
  ' --argjson serviceState "$(jq '.serviceState // {}' "$STATE_FILE")" "$SERVICES_FILE" | jq -c '.[]' | while IFS= read -r service_obj; do
    local service_id containerized domain old_alpha_id
    service_id="$(echo "$service_obj" | jq -r '.id')"
    containerized="$(echo "$service_obj" | jq -r '.containerized')"
    domain="$(echo "$service_obj" | jq -r '.domain')"
    old_alpha_id="$(echo "$service_obj" | jq -r '.oldAlpha // empty')"

    [ -n "$old_alpha_id" ] || continue

      local old_alpha_host old_alpha_ssh
      old_alpha_host="$(jq -r --arg id "$old_alpha_id" 'map(select(.id==$id)) | .[0].hostname // empty' "$NODES_FILE")"
      old_alpha_ssh="$(jq -r --arg id "$old_alpha_id" 'map(select(.id==$id)) | .[0].sshHost // empty' "$NODES_FILE")"

      if [ "$execute" = "true" ] && [ "$containerized" = "true" ]; then
        run_action "container_stop" "stop demoted container core-$service_id on $old_alpha_id" "${SCRIPT_DIR}/orchestrate_container.sh" "stop" "$service_id" "$old_alpha_id" "$old_alpha_host" "$old_alpha_ssh"
      else
        log_event "info" "container_stop" "system" "stop demoted container core-$service_id" "target $old_alpha_id"
      fi
  done
}

execute_actions() {
  local execute="$1"
  local local_host
  local backup_root
  local_host="$(hostname)"
  backup_root="${ROOT_DIR}/data/backups"

  run_action() {
    local event_name="$1"
    local reason="$2"
    shift 2

    if "$@"; then
      log_event "info" "$event_name" "system" "$reason" "applied"
    else
      log_event "error" "$event_name" "system" "$reason" "failed"
    fi
  }

  while IFS= read -r service_id; do
    local alpha beta gamma domain containerized storage
    alpha="$(jq -r --arg id "$service_id" 'map(select(.id==$id)) | .[0].roleAssignments.alpha // empty' "$SERVICES_FILE")"
    beta="$(jq -r --arg id "$service_id" 'map(select(.id==$id)) | .[0].roleAssignments.beta // empty' "$SERVICES_FILE")"
    gamma="$(jq -r --arg id "$service_id" 'map(select(.id==$id)) | .[0].roleAssignments.gamma // empty' "$SERVICES_FILE")"
    domain="$(jq -r --arg id "$service_id" 'map(select(.id==$id)) | .[0].domain // empty' "$SERVICES_FILE")"
    containerized="$(jq -r --arg id "$service_id" 'map(select(.id==$id)) | .[0].containerized // false' "$SERVICES_FILE")"
    storage="$(jq -r --arg id "$service_id" 'map(select(.id==$id)) | .[0].storageLocation // empty' "$SERVICES_FILE")"

    [ -n "$alpha" ] || continue

    local alpha_host alpha_ip beta_host beta_ssh gamma_host gamma_ssh
    alpha_host="$(jq -r --arg id "$alpha" 'map(select(.id==$id)) | .[0].hostname // empty' "$NODES_FILE")"
    alpha_ip="$(jq -r --arg id "$alpha" 'map(select(.id==$id)) | .[0].netbirdIp // empty' "$NODES_FILE")"

    beta_host="$(jq -r --arg id "$beta" 'map(select(.id==$id)) | .[0].hostname // empty' "$NODES_FILE")"
    beta_ssh="$(jq -r --arg id "$beta" 'map(select(.id==$id)) | .[0].sshHost // empty' "$NODES_FILE")"
    gamma_host="$(jq -r --arg id "$gamma" 'map(select(.id==$id)) | .[0].hostname // empty' "$NODES_FILE")"
    gamma_ssh="$(jq -r --arg id "$gamma" 'map(select(.id==$id)) | .[0].sshHost // empty' "$NODES_FILE")"

    if [ "$containerized" = "true" ]; then
      if [ "$execute" = "true" ]; then
        local alpha_ssh
        alpha_ssh="$(jq -r --arg id "$alpha" 'map(select(.id==$id)) | .[0].sshHost // empty' "$NODES_FILE")"
        run_action "container_start" "start container core-$service_id on alpha=$alpha" "${SCRIPT_DIR}/orchestrate_container.sh" "start" "$service_id" "$alpha" "$alpha_host" "$alpha_ssh"
      else
        log_event "info" "container_start" "system" "start container core-$service_id on alpha" "target $alpha"
      fi
    fi

    if [ -n "$domain" ] && [ -n "$alpha_ip" ]; then
      if [ "$execute" = "true" ]; then
        run_action "dns_rewrite" "set DNS rewrite for $domain -> $alpha_ip" "${SCRIPT_DIR}/write_dns_rewrite.sh" "$domain" "$alpha_ip"
      else
        log_event "info" "dns_rewrite" "system" "set DNS rewrite for $domain" "target $alpha_ip"
      fi
    fi

    if [ "$service_id" = "1_Indexer" ] || [ "$service_id" = "2_Adguard" ]; then
      if [ "$execute" = "true" ] && [ -n "$domain" ] && [ -n "$alpha_host" ]; then
        run_action "nginx_route" "ensure ingress for $service_id on $alpha_host" "${SCRIPT_DIR}/apply_nginx_site.sh" "$domain" "$alpha_host"
      else
        log_event "info" "nginx_route" "system" "ensure ingress for $service_id" "active host $alpha"
      fi
    fi

    if [ "$execute" = "true" ] && [ -n "$storage" ] && [ -n "$beta" ] && [ "$alpha_host" = "$local_host" ]; then
      run_action "rsync_beta" "sync $service_id alpha->beta" "${SCRIPT_DIR}/sync_service_data.sh" "$service_id" "$alpha_host" "$beta_host" "$storage" "$storage" "$beta_ssh"
    fi

    if [ "$execute" = "true" ] && [ -n "$storage" ] && [ -n "$gamma" ] && [ "$alpha_host" = "$local_host" ]; then
      run_action "backup_gamma" "archive $service_id alpha->gamma" "${SCRIPT_DIR}/backup_service_data.sh" "$service_id" "$storage" "$backup_root" "$gamma_host" "$gamma_ssh"
    fi

    if [ "$execute" = "true" ] && [ -n "$domain" ]; then
      run_action "health_probe" "verify endpoint for $service_id: $domain" "${SCRIPT_DIR}/health_probe.sh" "$service_id" "$domain" "443"
    fi
  done < <(jq -r '.[].id' "$SERVICES_FILE")
}

status_json() {
  jq -n \
    --argjson services "$(cat "$SERVICES_FILE")" \
    --argjson nodes "$(cat "$NODES_FILE")" \
    --argjson state "$(cat "$STATE_FILE")" \
    '{services:$services,nodes:$nodes,state:$state}'
}

set_node_health() {
  local node_id="$1"
  local healthy="$2"

  if [ "$healthy" != "true" ] && [ "$healthy" != "false" ]; then
    echo "healthy must be true or false" >&2
    exit 1
  fi

  set_json_file "$NODES_FILE" 'map(if .id == $id then .healthy = ($v == "true") else . end)' --arg id "$node_id" --arg v "$healthy" "$NODES_FILE"
  log_event "warning" "node_health_override" "operator" "set node health" "$node_id -> $healthy"
}

set_service_status() {
  local service_id="$1"
  local status="$2"

  set_json_file "$SERVICES_FILE" 'map(if .id == $id then .status = $status else . end)' --arg id "$service_id" --arg status "$status" "$SERVICES_FILE"
  log_event "info" "service_status_override" "operator" "set service status" "$service_id -> $status"
}

assign_role() {
  local service_id="$1"
  local role="$2"
  local node_id="$3"
  local value

  value="$node_id"
  if [ "$node_id" = "none" ]; then
    value=""
  fi

  set_json_file "$SERVICES_FILE" '
    map(
      if .id == $sid then
        .roleAssignments[$role] = (if $val == "" then null else $val end)
      else . end
    )
  ' --arg sid "$service_id" --arg role "$role" --arg val "$value" "$SERVICES_FILE"

  recompute_node_assignments
  log_event "info" "role_assignment" "operator" "manual role assignment" "$service_id $role -> $node_id"
}

set_force_active() {
  local node_id="$1"
  local value
  value="$node_id"
  if [ "$node_id" = "none" ]; then
    value=""
  fi

  set_json_file "$STATE_FILE" '.supervisor.forceActiveNodeId = (if $val == "" then null else $val end)' --arg val "$value" "$STATE_FILE"
  log_event "warning" "force_active_supervisor" "operator" "set force active node" "$node_id"
}

set_maintenance() {
  local scope="$1"
  local id="$2"
  local mode="$3"

  if [ "$scope" != "node" ] && [ "$scope" != "service" ]; then
    echo "scope must be node or service" >&2
    exit 1
  fi

  if [ "$mode" != "on" ] && [ "$mode" != "off" ]; then
    echo "mode must be on or off" >&2
    exit 1
  fi

  if [ "$scope" = "node" ]; then
    if [ "$mode" = "on" ]; then
      set_json_file "$STATE_FILE" '.supervisor.maintenance.nodes |= (if index($id) then . else . + [$id] end)' --arg id "$id" "$STATE_FILE"
    else
      set_json_file "$STATE_FILE" '.supervisor.maintenance.nodes |= map(select(. != $id))' --arg id "$id" "$STATE_FILE"
    fi
  else
    if [ "$mode" = "on" ]; then
      set_json_file "$STATE_FILE" '.supervisor.maintenance.services |= (if index($id) then . else . + [$id] end)' --arg id "$id" "$STATE_FILE"
    else
      set_json_file "$STATE_FILE" '.supervisor.maintenance.services |= map(select(. != $id))' --arg id "$id" "$STATE_FILE"
    fi
  fi

  log_event "info" "maintenance_mode" "operator" "maintenance toggle" "$scope $id -> $mode"
}

run_cycle() {
  local execute="false"
  if [ "${1:-}" = "--execute" ]; then
    execute="true"
  fi

  merge_discovered_nodes
  detect_and_reconcile_recovery
  apply_supervisor_takeover
  apply_service_failover
  recompute_node_assignments
  execute_demote_actions "$execute"
  execute_actions "$execute"
  log_event "info" "cycle_complete" "system" "supervisor cycle finished" "execute=$execute"
}

main() {
  require_cmd jq
  ensure_files

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    init)
      ensure_files
      log_event "info" "init" "system" "initialized data files" "ok"
      ;;
    discover-nodes)
      merge_discovered_nodes
      recompute_node_assignments
      ;;
    run-cycle)
      run_cycle "$@"
      ;;
    deploy-all-services)
      "${SCRIPT_DIR}/deploy_all_services.sh" "${1:-}"
      ;;
    status-json)
      status_json
      ;;
    set-node-health)
      [ "$#" -eq 2 ] || usage
      set_node_health "$1" "$2"
      ;;
    set-service-status)
      [ "$#" -eq 2 ] || usage
      set_service_status "$1" "$2"
      ;;
    assign-role)
      [ "$#" -eq 3 ] || usage
      assign_role "$1" "$2" "$3"
      ;;
    set-force-active)
      [ "$#" -eq 1 ] || usage
      set_force_active "$1"
      ;;
    set-maintenance)
      [ "$#" -eq 3 ] || usage
      set_maintenance "$1" "$2" "$3"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
