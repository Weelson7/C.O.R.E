# C.O.R.E Suwayomi

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized Suwayomi Server deployment exposed through C.O.R.E mesh ingress.
- What it does: Serves the Suwayomi web UI/API behind Nginx TLS for `suwayomi.core`, with optional Tachiyomi extension APK bootstrap and extension-repo configuration.
- Why this service exists in C.O.R.E: It provides private, mesh-scoped manga/comic source aggregation under the same Supervisor-compatible deployment and validation contract used by other C.O.R.E services.

## Commands
- Start: `sudo docker compose -f /opt/core/suwayomi/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/suwayomi/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/suwayomi/compose.yaml up -d --force-recreate`
- Status: `sudo docker compose -f /opt/core/suwayomi/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-suwayomi`
- Logs: `sudo docker logs -f core-suwayomi` and `sudo tail -f /var/log/nginx/core-suwayomi.error.log`
- Edit/Reload: edit `src/4_Suwayomi/deploy.sh`, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Service roles are Supervisor-managed. Current default assignment is alpha on `node-0`.
- Domain: `suwayomi.core`
- Port(s): External ingress `443` and `80` (redirect), internal loopback publish `127.0.0.1:4567` by default.
- Volumes/Data path:
	- Deploy script: `src/4_Suwayomi/deploy.sh`
	- Runtime root: `/opt/core/suwayomi`
	- Primary data volume: `/opt/core/suwayomi/data`
	- Downloads path: `/opt/core/suwayomi/downloads`
	- Extension APK staging path: `/opt/core/suwayomi/data/extensions`
	- Compose file (generated): `/opt/core/suwayomi/compose.yaml`
	- Nginx site: `/etc/nginx/sites-available/suwayomi.core`
	- Ingress auth file: `/etc/nginx/.htpasswd_core_suwayomi`
	- TLS assets: `/etc/nginx/ssl/suwayomi.core.crt` and `/etc/nginx/ssl/suwayomi.core.key`
- Environment/config tweaks:
	- `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
	- `NETBIRD_FAILOVER_IP` (optional): accepted secondary IP for DNS validation.
	- `HTPASSWD_USER` (required): ingress user account created/updated for centralized auth policy.
	- `IMAGE_TAG` (optional): Suwayomi image tag, default `ghcr.io/suwayomi/suwayomi-server:latest`.
	- `PUBLISHED_HTTP_PORT` (optional): local loopback port mapped to container `4567`, default `4567`.
	- `TZ` (optional): container timezone, default `UTC`.
	- `EXTENSION_REPOS` (optional): extension repo index URL passed to container, default `https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json`.
	- `TACHIYOMI_EXTENSION_URL` (optional): direct `.apk` URL to bootstrap one Tachiyomi extension package into `/opt/core/suwayomi/data/extensions`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- TLS is mandatory for `suwayomi.core` ingress.
	- HTTP Basic Auth is enforced at ingress to satisfy centralized authentication policy.
	- Suwayomi container is exposed on loopback only and fronted by Nginx.
	- Netbird connectivity is required before DNS and ingress validation can pass.
	- Extension bootstrap requires `.apk` URL validation before any file is staged.

## Deployment sequence
1. Validate host/runtime prerequisites and install dependencies.
	- Enforce Ubuntu preflight.
	- Verify required commands (`sudo`, `apt`, `getent`, `awk`, `grep`).
	- Prompt for required runtime values `NETBIRD_DEVICE_IP` and `HTPASSWD_USER`.
	- Install runtime packages: `nginx`, `mkcert`, `apache2-utils`, `curl`, `ca-certificates`, `docker.io`, `docker-compose-plugin`.
2. Provision runtime directories.
	- Create `/opt/core/suwayomi`, `/opt/core/suwayomi/data`, `/opt/core/suwayomi/downloads`, and `/opt/core/suwayomi/data/extensions`.
3. Generate container runtime definition.
	- Write `/opt/core/suwayomi/compose.yaml` with `core-suwayomi` container, loopback port mapping, persistent mounts, and extension repo environment.
4. Start and verify local Suwayomi runtime.
	- Launch with Docker Compose.
	- Fail if container state is not `running`.
	- Validate local endpoint `http://127.0.0.1:4567/`.
5. Bootstrap Tachiyomi extension settings.
	- If `TACHIYOMI_EXTENSION_URL` is provided, validate `.apk` suffix, download package, stage under `/opt/core/suwayomi/data/extensions`, restart container, and re-check local health.
	- If not provided, keep extension bootstrap optional and continue with extension repo defaults.
6. Provision TLS certificate and key for `suwayomi.core`.
	- Install local trust with `mkcert -install`.
	- Generate certificate pair and place into `/etc/nginx/ssl/` with restrictive permissions.
7. Write and validate Nginx ingress.
	- Create/update `/etc/nginx/.htpasswd_core_suwayomi` using `HTPASSWD_USER`.
	- Generate `/etc/nginx/sites-available/suwayomi.core` with HTTP to HTTPS redirect and reverse proxy rules.
	- Enable site, remove default site, run `nginx -t`, and restart Nginx.
8. Validate mesh DNS contract and ingress health.
	- Require healthy Netbird runtime.
	- Resolve `suwayomi.core` and enforce match against `NETBIRD_DEVICE_IP` (or optional failover IP).
	- Validate ingress endpoint `https://suwayomi.core/`.
	- Confirm deployment remains compatible with Supervisor namespace and role model (`core-suwayomi`, `suwayomi.core`, `/opt/core/suwayomi`).

Validation checks:
- `sudo docker compose -f /opt/core/suwayomi/compose.yaml ps`
- `sudo docker inspect -f '{{.State.Status}}' core-suwayomi`
- `curl --fail http://127.0.0.1:4567/`
- `sudo nginx -t`
- `getent ahostsv4 suwayomi.core`
- `curl --fail --insecure https://suwayomi.core/`

Failure handling notes:
- Container not running: inspect `sudo docker logs core-suwayomi` and rerun compose startup.
- Local endpoint failure: confirm port mapping and check whether another service is occupying `PUBLISHED_HTTP_PORT`.
- Extension bootstrap failure: validate the `TACHIYOMI_EXTENSION_URL` is reachable and points to a valid `.apk` artifact.
- Nginx validation failure: inspect `/var/log/nginx/core-suwayomi.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: update AdGuard rewrite and Netbird nameserver group so `suwayomi.core` resolves to expected mesh IP.
- Netbird disconnected: restore mesh connectivity before rerunning final validation step.

## Files
- `src/4_Suwayomi/deploy.sh`: Idempotent deployment script for Suwayomi runtime, optional extension bootstrap, TLS ingress, and mesh validation.
- `src/4_Suwayomi/wipe.sh`: Cleanup script for runtime artifacts, ingress config, container/image, and optional package purge.
- `/opt/core/suwayomi/compose.yaml`: Generated container orchestration definition.
- `/etc/nginx/sites-available/suwayomi.core`: Generated ingress virtual host configuration.
- `/etc/nginx/.htpasswd_core_suwayomi`: Generated ingress authentication file.
- `/etc/nginx/ssl/suwayomi.core.crt`: Generated TLS certificate used by Nginx.
- `/etc/nginx/ssl/suwayomi.core.key`: Generated TLS private key used by Nginx.