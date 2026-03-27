# C.O.R.E x_Supervisor

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [UI console](#ui-console)
- [Run cycle](#run-cycle)
- [Current behavior and limits](#current-behavior-and-limits)
- [Files](#files)

## Infos
- What it is: A Bash-based control-plane orchestrator under `src/x_Supervisor/bin/supervisor.sh`.
- What it does: Reads and mutates `services.json`, `nodes.json`, and `state.json` to run node discovery, role-based failover, and optional execution of runtime actions.
- Why this service exists in C.O.R.E: It centralizes alpha/beta/gamma service placement and failover policy in one automation loop.

## Commands
- CLI entrypoint: `src/x_Supervisor/bin/supervisor.sh`
- Usage:
  - `supervisor.sh init`
  - `supervisor.sh discover-nodes`
  - `supervisor.sh run-cycle [--execute]`
  - `supervisor.sh status-json`
  - `supervisor.sh set-node-health <node-id> <true|false>`
  - `supervisor.sh set-service-status <service-id> <healthy|degraded|down|failover-active|unknown>`
  - `supervisor.sh assign-role <service-id> <alpha|beta|gamma> <node-id|none>`
  - `supervisor.sh set-force-active <node-id|none>`
  - `supervisor.sh set-maintenance <node|service> <id> <on|off>`
  - `supervisor.sh deploy-all-services [--skip-pull]`
- Action mode:
  - `run-cycle` without `--execute` performs planning/state mutation and event logging.
  - `run-cycle --execute` also performs side-effect actions (containers, DNS rewrites, ingress, replication, backups, probes).

## Runtime parameters
- Node(s):
  - Active/primary/sub-supervisor IDs are in `state.json` under `.supervisor.activeNodeId`, `.primaryNodeId`, `.subSupervisorNodeId`.
  - Node health and role-service indexes are in `nodes.json` (`healthy`, `alphaServices`, `betaServices`, `gammaServices`).
  - Discovery source is `netbird_discovery.sh`, merged into `nodes.json` by `discover-nodes` and `run-cycle`.
- Domain:
  - Per-service domain lives in `services.json` as `.domain`.
  - DNS rewrite target is active alpha node `netbirdIp`.
- Port(s):
  - Health probe script checks `/health` (HTTPS first for action validator, HTTP then HTTPS for probe script depending on tool).
  - Nginx routing helper currently applies only for `1_Indexer` and `2_Adguard` in execute mode.
- Volumes/Data path:
  - Runtime data root: `src/x_Supervisor/data`
  - Service registry: `services.json`
  - Node registry: `nodes.json`
  - Supervisor state/policy: `state.json`
  - DNS rewrites file: `dns_rewrites.json`
  - Event/audit log: `events.log` (JSON lines)
  - Local backup target used by supervisor loop: `src/x_Supervisor/data/backups`
- Environment/config tweaks:
  - Promotion timeout: `.policy.promotionTimeoutSeconds` (currently `1200` = 20 minutes).
  - Gamma retention months policy value: `.policy.gammaRetentionMonths`.
  - Auto supervisor takeover toggle: `.supervisor.automaticTakeover`.
  - Manual active supervisor override: `.supervisor.forceActiveNodeId`.
  - Maintenance scopes: `.supervisor.maintenance.nodes` and `.supervisor.maintenance.services`.
- Security constraints:
  - Remote actions use SSH/rsync/docker without a built-in RBAC layer.
  - Audit events are appended in JSON-lines format via `log_event` with `ts`, `level`, `event`, `actor`, `reason`, `outcome`.

## UI console
- Location:
  - `src/x_Supervisor/index.html`
  - `src/x_Supervisor/app.js`
  - `src/x_Supervisor/style.css`
- Purpose:
  - Read-only/command-generation operator console for Supervisor data.
  - Displays current state from `data/services.json`, `data/nodes.json`, `data/state.json`, and `data/events.log`.
- Navigation/views currently implemented:
  - Dashboard
  - Services
  - Nodes
  - Cluster
  - Remediation
  - Events
  - Actions
  - Runbook
- Data refresh model:
  - Manual refresh via top-right Refresh button.
  - Automatic refresh every 15 seconds in the browser.
- Operator Actions panel behavior:
  - Generates shell commands into a read-only output box.
  - Does not execute backend commands directly.
  - Command templates currently include:
    - `bin/supervisor.sh assign-role ...`
    - `bin/supervisor.sh set-node-health ...`
    - `bin/supervisor.sh set-force-active ...`
    - `bin/supervisor.sh run-cycle --execute`
    - `bin/node_remediation.sh assess-and-remediate ...`
    - `bin/node_remediation.sh quarantine ...`
    - `bin/cleanup_backups.sh ...`
    - `bin/ha_cluster.sh init ...`
    - `bin/ha_cluster.sh health ...`
- UI runtime notes:
  - The UI expects files to be served over HTTP (not opened via `file://`) because it uses `fetch`.
  - If JSON files are missing or unreachable, the banner switches to a critical error state.
  - Event list renders last entries from `events.log` as JSON lines.

## Run cycle
`supervisor.sh run-cycle` executes the following sequence:

1. Merge discovered Netbird nodes into `nodes.json`.
2. Detect recovered old-alpha nodes and emit recovery events.
3. Apply supervisor takeover rules (force override first, then auto takeover if active is unhealthy and sub is healthy/non-maintenance).
4. Evaluate per-service alpha health and promote beta to alpha once timeout is reached.
5. Recompute `alphaServices`/`betaServices`/`gammaServices` indexes on nodes.
6. Process demotion actions for services marked `failover-active`.
7. Process service actions (container start, DNS rewrite, ingress, beta sync, gamma backup, health probe).
8. Append cycle completion event.

With `--execute`, side-effect scripts are called:
- `orchestrate_container.sh`
- `write_dns_rewrite.sh`
- `apply_nginx_site.sh`
- `sync_service_data.sh`
- `backup_service_data.sh`
- `health_probe.sh`

## Current behavior and limits
- Discovery:
  - Discovery merges by node key precedence (`id`, then `netbirdIp`, then `hostname`).
  - Nodes missing from discovery are retained and marked `healthy: false`.
- Failover:
  - Promotion supports alpha -> beta only.
  - On promotion, service status becomes `failover-active`, beta slot is set to `null`, and prior alpha is tracked in `state.serviceState.<id>.lastPromotionFrom`.
- Recovery:
  - Current implementation logs recovery detection events.
  - Recovery detection does not automatically run reverse sync or role reassignment.
- Ingress:
  - Automatic ingress action in supervisor loop is scoped to Indexer and AdGuard only.
- Backups/sync:
  - Replication and backup actions execute only when current alpha hostname equals local hostname.
  - Backup cadence semantics (daily incremental + weekly full) are policy metadata; cadence enforcement scheduler is external to `supervisor.sh`.
- Audit immutability:
  - `events.log` is append-only by implementation convention, not cryptographically immutable.

## Files
- `src/x_Supervisor/bin/supervisor.sh`: Main orchestration CLI.
- `src/x_Supervisor/bin/*.sh`: Action helpers for DNS, ingress, container lifecycle, backup/sync, health, and node operations.
- `src/x_Supervisor/index.html`: Supervisor web console shell with tabs, tables, and action forms.
- `src/x_Supervisor/app.js`: UI data loading, rendering, tab control, and command generation logic.
- `src/x_Supervisor/style.css`: Console visual theme, layout, badges, tables, and responsive behavior.
- `src/x_Supervisor/data/services.json`: Service registry and role assignments.
- `src/x_Supervisor/data/nodes.json`: Node registry and service index lists.
- `src/x_Supervisor/data/state.json`: Supervisor control state, policy, maintenance, and failover metadata.
- `src/x_Supervisor/data/events.log`: JSON-lines audit/event stream.
- `Docs/Services/x_Supervisor.md`: This implementation-aligned service document.
