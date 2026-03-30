# C.O.R.E qBittorrent

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized qBittorrent deployment exposed through C.O.R.E mesh ingress as service 6.
- What it does: Serves the qBittorrent WebUI (qbittorrent-nox/headless runtime profile) via `qbittorrent.core` over Nginx TLS while running torrent traffic on dedicated TCP/UDP ports. Provides torrent download capability to Seanime (service 8).
- Why this service exists in C.O.R.E: It replaces service slot 6 with a private, mesh-scoped download client that integrates with Seanime (service 8) using shared `/downloads` paths.

## Commands
- Start: `sudo docker compose -f /opt/core/qbittorrent/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/qbittorrent/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/qbittorrent/compose.yaml up -d --force-recreate`
- Status: `sudo docker compose -f /opt/core/qbittorrent/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-qbittorrent`
- Logs: `sudo docker logs -f core-qbittorrent` and `sudo tail -f /var/log/nginx/core-qbittorrent.error.log`
- Edit/Reload: edit `src/6_qBittorrent/deploy.sh`, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Service roles are Supervisor-managed. Current default assignment is alpha on `node-0`.
- Domain: `qbittorrent.core`
- Port(s):
	- External ingress: `443` and `80` (redirect)
	- Internal WebUI publish: `127.0.0.1:18081` -> container `8080` (default)
	- Torrent listener: host `6881/tcp` and `6881/udp` -> container `6881/tcp+udp` (default)
- Volumes/Data path:
	- Deploy script: `src/6_qBittorrent/deploy.sh`
	- Wipe script: `src/6_qBittorrent/wipe.sh`
	- Runtime root: `/opt/core/qbittorrent`
	- qBittorrent config volume: `/opt/core/qbittorrent/config`
	- Shared downloads volume: `/downloads` (default)
	- Download helpers created by deploy: `/downloads/incomplete`, `/downloads/watch`
	- Compose file (generated): `/opt/core/qbittorrent/compose.yaml`
	- Nginx site: `/etc/nginx/sites-available/qbittorrent.core`
	- TLS assets: `/etc/nginx/ssl/qbittorrent.core.crt` and `/etc/nginx/ssl/qbittorrent.core.key`
- Environment/config tweaks:
	- `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
	- `NETBIRD_FAILOVER_IP` (optional): accepted secondary IP for DNS validation.
	- `IMAGE_TAG` (optional): container image tag, default `lscr.io/linuxserver/qbittorrent:latest`.
	- `WEBUI_RUNTIME` (optional): WebUI runtime label, allowed values `qbittorrent` or `qbittorrent-nox`, default `qbittorrent-nox`.
	- `DOWNLOADS_DIR` (optional): host path mounted at `/downloads`, default `/downloads`.
	- `PUBLISHED_HTTP_PORT` (optional): local loopback WebUI port, default `18081`.
	- `CONTAINER_WEBUI_PORT` (optional): internal qBittorrent WebUI port, default `8080`.
	- `PUBLISHED_TORRENT_TCP_PORT` (optional): host torrent TCP port, default `6881`.
	- `PUBLISHED_TORRENT_UDP_PORT` (optional): host torrent UDP port, default `6881`.
	- `PUID` and `PGID` (optional): container runtime UID/GID, defaults `1000:1000`.
	- `TZ` (optional): container timezone, default `UTC`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- TLS is mandatory for `qbittorrent.core` ingress.
	- WebUI is loopback-only and exposed externally only through Nginx.
	- Torrent ports are intentionally published for peer connectivity.
	- Netbird connectivity is required before DNS and ingress validation can pass.

## Deployment sequence
1. Validate host/runtime prerequisites and install dependencies.
	- Enforce Ubuntu preflight.
	- Verify required commands (`sudo`, `apt`, `getent`, `awk`).
	- Prompt for required runtime value `NETBIRD_DEVICE_IP`.
	- Install runtime packages: `nginx`, `mkcert`, `curl`, `ca-certificates`, `docker.io`, and `docker-compose-plugin` (with fallback plugin install).
2. Provision runtime directories.
	- Create `/opt/core/qbittorrent`, `/opt/core/qbittorrent/config`, `/downloads`, `/downloads/incomplete`, and `/downloads/watch`.
	- Align ownership for qBittorrent config directory to `PUID:PGID`.
3. Generate container runtime definition.
	- Write `/opt/core/qbittorrent/compose.yaml` for `core-qbittorrent`.
	- Configure loopback WebUI publishing and host torrent TCP/UDP publishing.
4. Start and verify local qBittorrent runtime.
	- Stop and remove any existing container/stack to enforce clean recreate.
	- Launch with Docker Compose (`--force-recreate --pull always`).
	- Fail if container state is not `running`.
	- Validate local endpoint `http://127.0.0.1:18081/` (default).
5. Provision TLS certificate and key for `qbittorrent.core`.
	- Install local trust with `mkcert -install`.
	- Generate certificate pair and place into `/etc/nginx/ssl/` with restrictive permissions.
6. Write and validate Nginx ingress.
	- Generate `/etc/nginx/sites-available/qbittorrent.core` with HTTP to HTTPS redirect and reverse proxy rules.
	- Enable site, remove default site, run `nginx -t`, and restart Nginx.
7. Validate mesh DNS contract.
	- Require healthy Netbird runtime.
	- Resolve `qbittorrent.core` and enforce match against `NETBIRD_DEVICE_IP` (or optional failover IP).
8. Validate ingress runtime.
	- Validate `https://qbittorrent.core/` and accept healthy status codes.
	- Confirm deployment remains compatible with Supervisor namespace and role model (`core-qbittorrent`, `qbittorrent.core`, `/opt/core/qbittorrent`).

Validation checks:
- `sudo docker compose -f /opt/core/qbittorrent/compose.yaml ps`
- `sudo docker inspect -f '{{.State.Status}}' core-qbittorrent`
- `curl --fail http://127.0.0.1:18081/`
- `sudo nginx -t`
- `getent ahostsv4 qbittorrent.core`
- `curl --fail --insecure https://qbittorrent.core/`

Failure handling notes:
- Container not running: inspect `sudo docker logs core-qbittorrent` and rerun compose startup.
- Local endpoint failure: verify `PUBLISHED_HTTP_PORT` and container logs; ensure nothing else is using the same port.
- Torrent connectivity issues: verify host firewall/NAT for `PUBLISHED_TORRENT_TCP_PORT` and `PUBLISHED_TORRENT_UDP_PORT`.
- Nginx validation failure: inspect `/var/log/nginx/core-qbittorrent.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: update AdGuard rewrite and Netbird nameserver group so `qbittorrent.core` resolves to expected mesh IP.
- Netbird disconnected: restore mesh connectivity before rerunning final validation step.

## Files
- `src/6_qBittorrent/deploy.sh`: Idempotent deployment script for qBittorrent runtime, TLS ingress, and mesh validation.
- `src/6_qBittorrent/wipe.sh`: Cleanup script for runtime artifacts, ingress config, container/image, and optional package purge.
- `/opt/core/qbittorrent/compose.yaml`: Generated container orchestration definition.
- `/etc/nginx/sites-available/qbittorrent.core`: Generated ingress virtual host configuration.
- `/etc/nginx/ssl/qbittorrent.core.crt`: Generated TLS certificate used by Nginx.
- `/etc/nginx/ssl/qbittorrent.core.key`: Generated TLS private key used by Nginx.