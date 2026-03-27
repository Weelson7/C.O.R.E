# C.O.R.E Jellyfin

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized Jellyfin media server exposed through C.O.R.E mesh ingress.
- What it does: Serves the Jellyfin web app and media streaming endpoints behind Nginx TLS for the `jellyfin.core` virtual host.
- Why this service exists in C.O.R.E: It provides private, mesh-scoped media access with the same deployment and validation contract used by the other C.O.R.E services.

## Commands
- Start: `sudo docker compose -f /opt/core/jellyfin/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/jellyfin/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/jellyfin/compose.yaml up -d --force-recreate`
- Status: `sudo docker compose -f /opt/core/jellyfin/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-jellyfin`
- Logs: `sudo docker logs -f core-jellyfin` and `sudo tail -f /var/log/nginx/core-jellyfin.error.log`
- Edit/Reload: edit `src/3_Jellyfin/deploy.sh`, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Service roles are Supervisor-managed. Current default assignment is alpha on `node-0`.
- Domain: `jellyfin.core`
- Port(s): External ingress `443` and `80` (redirect), internal loopback publish `127.0.0.1:8096` by default.
- Volumes/Data path:
	- Deploy script: `src/3_Jellyfin/deploy.sh`
	- Runtime root: `/opt/core/jellyfin`
	- Jellyfin config volume: `/opt/core/jellyfin/config`
	- Jellyfin cache volume: `/opt/core/jellyfin/cache`
	- Media mount: `/srv/media` (default)
	- Compose file (generated): `/opt/core/jellyfin/compose.yaml`
	- Nginx site: `/etc/nginx/sites-available/jellyfin.core`
	- Ingress auth file: `/etc/nginx/.htpasswd_core_jellyfin`
	- TLS assets: `/etc/nginx/ssl/jellyfin.core.crt` and `/etc/nginx/ssl/jellyfin.core.key`
- Environment/config tweaks:
	- `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
	- `NETBIRD_FAILOVER_IP` (optional): accepted secondary IP for DNS validation.
	- `HTPASSWD_USER` (required): ingress user account created/updated for centralized auth policy.
	- `IMAGE_TAG` (optional): Jellyfin image tag, default `jellyfin/jellyfin:latest`.
	- `PUBLISHED_HTTP_PORT` (optional): local loopback port mapped to container `8096`, default `8096`.
	- `MEDIA_DIR` (optional): host media library path mounted read-only to `/media`, default `/srv/media`.
	- `TZ` (optional): container timezone, default `UTC`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- TLS is mandatory for `jellyfin.core` ingress.
	- HTTP Basic Auth is enforced at ingress to satisfy centralized authentication policy.
	- Jellyfin container is exposed on loopback only and fronted by Nginx.
	- Netbird connectivity is required before DNS and ingress validation can pass.
	- Media directory is mounted read-only inside the container.

## Deployment sequence
1. Validate host/runtime prerequisites and install dependencies.
	- Enforce Ubuntu preflight.
	- Verify required commands (`sudo`, `apt`, `getent`, `awk`).
	- Prompt for required runtime values `NETBIRD_DEVICE_IP` and `HTPASSWD_USER`.
	- Install runtime packages: `nginx`, `mkcert`, `apache2-utils`, `curl`, `ca-certificates`, `docker.io`, `docker-compose-plugin`.
2. Provision runtime directories.
	- Create `/opt/core/jellyfin`, `/opt/core/jellyfin/config`, `/opt/core/jellyfin/cache`, and media directory (`/srv/media` by default).
3. Generate container runtime definition.
	- Write `/opt/core/jellyfin/compose.yaml` with `core-jellyfin` container, loopback port mapping, and persistent mounts.
4. Start and verify local Jellyfin runtime.
	- Launch with Docker Compose.
	- Fail if container state is not `running`.
	- Validate local endpoint `http://127.0.0.1:8096/web/index.html`.
5. Provision TLS certificate and key for `jellyfin.core`.
	- Install local trust with `mkcert -install`.
	- Generate certificate pair and place into `/etc/nginx/ssl/` with restrictive permissions.
6. Enforce centralized ingress authentication.
	- Create or update `/etc/nginx/.htpasswd_core_jellyfin` using `HTPASSWD_USER`.
7. Write and validate Nginx ingress.
	- Generate `/etc/nginx/sites-available/jellyfin.core` with HTTP->HTTPS redirect and reverse proxy rules.
	- Enable site, remove default site, run `nginx -t`, and restart Nginx.
8. Validate mesh DNS contract and ingress health.
	- Require healthy Netbird runtime.
	- Resolve `jellyfin.core` and enforce match against `NETBIRD_DEVICE_IP` (or optional failover IP).
	- Validate ingress endpoint `https://jellyfin.core/web/index.html`.
	- Confirm deployment remains compatible with Supervisor namespace and role model (`core-jellyfin`, `jellyfin.core`, `/opt/core/jellyfin`).

Validation checks:
- `sudo docker compose -f /opt/core/jellyfin/compose.yaml ps`
- `sudo docker inspect -f '{{.State.Status}}' core-jellyfin`
- `curl --fail http://127.0.0.1:8096/web/index.html`
- `sudo nginx -t`
- `getent ahostsv4 jellyfin.core`
- `curl --fail --insecure https://jellyfin.core/web/index.html`

Failure handling notes:
- Container not running: inspect `sudo docker logs core-jellyfin` and rerun compose startup.
- Local endpoint failure: confirm port mapping and check whether another service is occupying `PUBLISHED_HTTP_PORT`.
- Nginx validation failure: inspect `/var/log/nginx/core-jellyfin.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: update AdGuard rewrite and Netbird nameserver group so `jellyfin.core` resolves to expected mesh IP.
- Auth prompt/update failure: ensure `apache2-utils` is installed and rerun deploy to refresh `/etc/nginx/.htpasswd_core_jellyfin`.
- Netbird disconnected: restore mesh connectivity before rerunning final validation step.

## Files
- `src/3_Jellyfin/deploy.sh`: Idempotent deployment script for Jellyfin runtime, TLS ingress, and mesh validation.
- `/opt/core/jellyfin/compose.yaml`: Generated container orchestration definition.
- `/etc/nginx/sites-available/jellyfin.core`: Generated ingress virtual host configuration.
- `/etc/nginx/.htpasswd_core_jellyfin`: Generated ingress authentication file.
- `/etc/nginx/ssl/jellyfin.core.crt`: Generated TLS certificate used by Nginx.
- `/etc/nginx/ssl/jellyfin.core.key`: Generated TLS private key used by Nginx.