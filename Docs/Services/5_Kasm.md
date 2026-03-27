# C.O.R.E Kasm

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized Kasm service runtime exposed through C.O.R.E mesh ingress.
- What it does: Runs a Kasm container (`core-kasm`) on a loopback-bound host port and publishes it at `https://kasm.core` through Nginx TLS and centralized ingress auth.
- Why this service exists in C.O.R.E: It provides private, mesh-scoped browser-desktop style access while staying aligned with the same Supervisor-compatible deployment contract as other services.

## Commands
- Start: `sudo docker compose -f /opt/core/kasm/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/kasm/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/kasm/compose.yaml up -d --force-recreate`
- Status: `sudo docker compose -f /opt/core/kasm/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-kasm`
- Logs: `sudo docker logs -f core-kasm` and `sudo tail -f /var/log/nginx/core-kasm.error.log`
- Edit/Reload: edit `src/5_Kasm/deploy.sh`, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Service roles are Supervisor-managed. Current default assignment is alpha on `node-0`.
- Domain: `kasm.core`
- Port(s): External ingress `443` and `80` (redirect), internal loopback publish `127.0.0.1:7443` by default.
- Volumes/Data path:
	- Deploy script: `src/5_Kasm/deploy.sh`
	- Runtime root: `/opt/core/kasm`
	- Profile/persistent data path: `/opt/core/kasm/profile`
	- Compose file (generated): `/opt/core/kasm/compose.yaml`
	- Nginx site: `/etc/nginx/sites-available/kasm.core`
	- Ingress auth file: `/etc/nginx/.htpasswd_core_kasm`
	- TLS assets: `/etc/nginx/ssl/kasm.core.crt` and `/etc/nginx/ssl/kasm.core.key`
- Environment/config tweaks:
	- `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
	- `NETBIRD_FAILOVER_IP` (optional): accepted secondary IP for DNS validation.
	- `HTPASSWD_USER` (required): ingress user account created/updated for centralized auth policy.
	- `IMAGE_TAG` (optional): Kasm image tag, default `lscr.io/linuxserver/kasm:latest`.
	- `PUBLISHED_HTTPS_PORT` (optional): loopback host port used by container, default `7443`.
	- `CONTAINER_PORT` (optional): in-container Kasm service port, default `3000`.
	- `KASM_BACKEND_SCHEME` (optional): backend proxy scheme (`https` or `http`), default `https`.
	- `PUID` and `PGID` (optional): container UID/GID, defaults `1000`.
	- `TZ` (optional): container timezone, default `UTC`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- TLS is mandatory for `kasm.core` ingress.
	- HTTP Basic Auth is enforced at ingress to satisfy centralized authentication policy.
	- Kasm container is exposed on loopback only and fronted by Nginx.
	- Netbird connectivity is required before DNS and ingress validation can pass.
	- Backend HTTPS proxy mode disables upstream certificate verification for local loopback termination (`proxy_ssl_verify off`).

## Deployment sequence
1. Validate host/runtime prerequisites and install dependencies.
	- Enforce Ubuntu preflight.
	- Verify required commands (`sudo`, `apt`, `getent`, `awk`, `grep`, `ss`).
	- Validate `PUBLISHED_HTTPS_PORT` and `CONTAINER_PORT` are numeric and in range.
	- Prompt for required runtime values `NETBIRD_DEVICE_IP` and `HTPASSWD_USER`.
	- Install runtime packages: `nginx`, `mkcert`, `apache2-utils`, `curl`, `ca-certificates`, `docker.io`, `docker-compose-plugin`, `iproute2`.
2. Provision runtime directories.
	- Create `/opt/core/kasm` and `/opt/core/kasm/profile`.
	- Stop/remove existing stack container if present so conflict scan is accurate.
3. Enforce no-port-conflict policy.
	- Scan host listeners with `ss` and fail if `PUBLISHED_HTTPS_PORT` is already in use.
	- Abort before writing runtime or starting container when a collision is detected.
4. Generate container runtime definition.
	- Write `/opt/core/kasm/compose.yaml` with `core-kasm` container, loopback port mapping, `shm_size`, and profile volume.
5. Start and verify local Kasm runtime.
	- Launch with Docker Compose.
	- Fail if container state is not `running`.
	- Validate local endpoint on configured backend scheme (`https://127.0.0.1:7443/` by default).
6. Provision TLS certificate and key for `kasm.core`.
	- Install local trust with `mkcert -install`.
	- Generate certificate pair and place into `/etc/nginx/ssl/` with restrictive permissions.
7. Write and validate Nginx ingress.
	- Create or update `/etc/nginx/.htpasswd_core_kasm` using `HTPASSWD_USER`.
	- Generate `/etc/nginx/sites-available/kasm.core` with HTTP to HTTPS redirect, websocket-capable proxying, and security headers.
	- Enable site, remove default site, run `nginx -t`, and restart Nginx.
8. Validate mesh DNS contract and ingress health.
	- Require healthy Netbird runtime.
	- Resolve `kasm.core` and enforce match against `NETBIRD_DEVICE_IP` (or optional failover IP).
	- Validate ingress endpoint `https://kasm.core/`.
	- Confirm deployment remains compatible with Supervisor namespace and role model (`core-kasm`, `kasm.core`, `/opt/core/kasm`).

Validation checks:
- `sudo docker compose -f /opt/core/kasm/compose.yaml ps`
- `sudo docker inspect -f '{{.State.Status}}' core-kasm`
- `curl --fail --insecure https://127.0.0.1:7443/`
- `sudo nginx -t`
- `getent ahostsv4 kasm.core`
- `curl --fail --insecure https://kasm.core/`

Failure handling notes:
- Port conflict on deploy: choose a free loopback publish port (`PUBLISHED_HTTPS_PORT`) and rerun.
- Container not running: inspect `sudo docker logs core-kasm` and rerun compose startup.
- Local endpoint failure: verify `KASM_BACKEND_SCHEME` and `CONTAINER_PORT` match the image runtime behavior.
- Nginx validation failure: inspect `/var/log/nginx/core-kasm.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: update AdGuard rewrite and Netbird nameserver group so `kasm.core` resolves to expected mesh IP.
- Netbird disconnected: restore mesh connectivity before rerunning final validation step.

## Files
- `src/5_Kasm/deploy.sh`: Idempotent deployment script for Kasm runtime, no-port-conflict checks, TLS ingress, and mesh validation.
- `src/5_Kasm/wipe.sh`: Cleanup script for runtime artifacts, ingress config, container/image, and optional package purge.
- `/opt/core/kasm/compose.yaml`: Generated container orchestration definition.
- `/etc/nginx/sites-available/kasm.core`: Generated ingress virtual host configuration.
- `/etc/nginx/.htpasswd_core_kasm`: Generated ingress authentication file.
- `/etc/nginx/ssl/kasm.core.crt`: Generated TLS certificate used by Nginx.
- `/etc/nginx/ssl/kasm.core.key`: Generated TLS private key used by Nginx.