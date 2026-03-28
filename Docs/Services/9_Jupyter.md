# Jupyter

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized JupyterLab runtime exposed as `jupyter.core`.
- What it does: Provides browser-based notebooks for automation, data analysis, and operational experiments while keeping kernel traffic internal to one container.
- Why this service exists in C.O.R.E: It is the interactive compute and notebook surface in the numbered service set (`0-12`), aligned with mesh-scoped access, Supervisor-managed placement, and standardized container runtime policy.

## Commands
- Start: `cd /opt/core/jupyter && sudo docker compose -f compose.yaml up -d`
- Stop: `cd /opt/core/jupyter && sudo docker compose -f compose.yaml down`
- Restart: `cd /opt/core/jupyter && sudo docker compose -f compose.yaml restart`
- Status: `sudo docker ps --filter name=core-jupyter` and `sudo docker compose -f /opt/core/jupyter/compose.yaml ps`
- Logs: `sudo docker logs -f core-jupyter`
- Edit/Reload: `sudoedit /opt/core/jupyter/compose.yaml && sudo docker compose -f /opt/core/jupyter/compose.yaml up -d` and `sudo nginx -t && sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Any Supervisor-assigned alpha node, with optional beta/gamma assignments per standard role semantics.
- Domain: `jupyter.core`
- Port(s): External ingress `443`/`80` via Nginx; local container binding `127.0.0.1:18888 -> 8888` by default (`PUBLISHED_HTTP_PORT` and `CONTAINER_PORT` are overridable).
- Volumes/Data path: `/opt/core/jupyter/workspace` mapped to notebook root (`/home/jovyan/work` by default), and `/opt/core/jupyter/config` mapped to `/home/jovyan/.jupyter`.
- Environment/config tweaks: `IMAGE_TAG`, `PUBLISHED_HTTP_PORT`, `CONTAINER_PORT`, `JUPYTER_LAB_ROOT_DIR`, `JUPYTER_TOKEN`, `JUPYTER_EXTRA_ARGS`, `PUID`, `PGID`, `TZ`, `NETBIRD_DEVICE_IP`, `NETBIRD_FAILOVER_IP`, `HTPASSWD_USER`, `HTPASSWD_PASSWORD`.
- Security constraints: Mesh-first access model, TLS termination at Nginx, HTTP basic auth gate at ingress, loopback-only container port publish, and DNS rewrite validation against Netbird/AdGuard expectations.

## Deployment sequence
1. Install dependencies (`nginx`, `mkcert`, `apache2-utils`, `curl`, `docker`) and validate required binaries.
2. Create runtime directories under `/opt/core/jupyter`, stop prior stack if present, and remove stale `core-jupyter` container.
3. Enforce explicit host port conflict checks before startup (`PUBLISHED_HTTP_PORT` must be free).
4. Generate compose runtime with a single loopback-mapped notebook endpoint; this keeps Jupyter kernel traffic internal and avoids host port sprawl.
5. Start container, confirm `running` state, and run local health probe on `http://127.0.0.1:<PUBLISHED_HTTP_PORT>/api`.
6. Issue TLS cert/key for `jupyter.core` with mkcert and install into `/etc/nginx/ssl`.
7. Generate and enable Nginx vhost with TLS + basic auth + websocket proxy settings, then validate and reload Nginx.
8. Validate mesh DNS resolution (`getent ahostsv4`) against primary/failover Netbird IP policy and confirm ingress health at `https://jupyter.core/api`.
9. Validation checks: local health endpoint reachable, container running, DNS maps to expected mesh IP, and ingress endpoint answers over TLS.
10. Failure handling notes: deploy script exits on first contract failure (`set -euo pipefail`) with actionable error messages; wipe script supports safe teardown and optional package purge.

## Files
- `src/9_Jupyter/deploy.sh`: Idempotent deploy workflow for container runtime, ingress config, TLS, auth, and mesh/DNS validation.
- `src/9_Jupyter/wipe.sh`: Controlled teardown of Jupyter runtime, ingress artifacts, and optional package removal.