# C.O.R.E Seanime

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- Operational status: Functional.
- What it is: A containerized self-hosted anime library and tracking web service exposed through C.O.R.E Nginx ingress.
- What it does: Provides anime browsing and tracking workflows from a single mesh-scoped endpoint with persistent data/config mounts.
- Why this service exists in C.O.R.E: It replaces service slot 6 with a media-aligned workload while preserving Supervisor-managed role semantics and container portability.

## Commands
- Start: `sudo docker compose -f /opt/core/seanime/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/seanime/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/seanime/compose.yaml up -d --force-recreate`
- Status: `sudo docker compose -f /opt/core/seanime/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-seanime`
- Logs: `sudo docker logs -f core-seanime` and `sudo tail -f /var/log/nginx/core-seanime.error.log`
- Edit/Reload: edit `src/6_Seanime/deploy.sh`, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Service roles are Supervisor-managed per [Architecture.md § 3.2](../Architecture.md#32-supervisor-bootstrap). By default the Supervisor node (node 0) is alpha; beta and gamma are optional per-service assignments.
- Domain: `seanime.core`
- Port(s): External `443` (TLS) and `80` (redirect), internal HTTP loopback `127.0.0.1:14321` mapped to container `4321`.
- Volumes/Data path:
	- Container runtime context: `/opt/core/seanime`
	- Persistent data: `/opt/core/seanime/data`
	- Persistent config: `/opt/core/seanime/config`
	- Media mount: `${MEDIA_LIBRARY_PATH}` to `/media/anime` (read-only)
	- Nginx site: `/etc/nginx/sites-available/seanime.core`
	- TLS assets: `/etc/nginx/ssl/seanime.core.crt` and `/etc/nginx/ssl/seanime.core.key`
	- Auth file: `/etc/nginx/.htpasswd_core`
- Environment/config tweaks:
	- `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
	- `HTPASSWD_USER` (required): HTTP Basic Auth account to create/update.
	- `PUBLISHED_HTTP_PORT` (optional, default `14321`): host loopback port exposed to Nginx.
	- `CONTAINER_PORT` (optional, default `4321`): Seanime container service port.
	- `MEDIA_LIBRARY_PATH` (optional, default `/srv/media/anime`): host path mounted read-only at `/media/anime`.
	- `IMAGE_TAG` (optional): container image tag, default `docker.io/umagistr/seanime:latest`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- Mesh-only administrative surface expected by policy per [Architecture.md § 8.1](../Architecture.md#81-access-model).
	- TLS is mandatory for `seanime.core` ingress per [Architecture.md § 8.2](../Architecture.md#82-proxy-and-service-security-baseline).
	- HTTP Basic Auth enforced at Nginx boundary.
	- Container binds on loopback only (`127.0.0.1`) and is not directly mesh-exposed.
	- Security headers enforced by Nginx: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`.

## Deployment sequence
1. Install host dependencies (`nginx`, `mkcert`, `docker.io`, `docker-compose-plugin`, auth and validation tooling) to satisfy deploy contract prerequisites.
	- Preflight checks ensure Ubuntu host, required commands, and port validity before deployment proceeds.
2. Generate TLS materials for `seanime.core` via `mkcert`, then place certificate and key under `/etc/nginx/ssl/` with restrictive permissions.
3. Create runtime directories under `/opt/core/seanime` and validate `MEDIA_LIBRARY_PATH` accessibility.
4. Generate runtime artifact `/opt/core/seanime/compose.yaml` for container execution.
5. Create or update ingress auth credentials in `/etc/nginx/.htpasswd_core` for the specified operator account.
6. Write Nginx site config at `/etc/nginx/sites-available/seanime.core`, enable it, validate syntax (`nginx -t`), and restart Nginx.
7. Pull/start Seanime container with `docker compose up -d`, then verify local HTTP health on loopback port.
8. Validate mesh and naming contract:
	 - Netbird must be connected (`netbird status`)
	 - `seanime.core` must resolve and match `NETBIRD_DEVICE_IP`
	 - Ingress endpoint `https://seanime.core/` must be reachable and authenticated

Validation checks:
- `sudo nginx -t`
- `sudo docker compose -f /opt/core/seanime/compose.yaml ps`
- `curl --fail http://127.0.0.1:14321/`
- `curl --fail --insecure https://seanime.core/` (should return 401 before auth, 200 after auth)
- `getent ahostsv4 seanime.core`

Failure handling notes:
- TLS generation failure: rerun `mkcert -install` and ensure generated `.pem` files exist.
- Container not running: inspect `sudo docker logs core-seanime` and rerun `sudo docker compose -f /opt/core/seanime/compose.yaml up -d`.
- Nginx validation failure: inspect `/var/log/nginx/core-seanime.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: correct AdGuard rewrite and Netbird nameserver group so `seanime.core` resolves to expected mesh IP.
- Library mount errors: verify `MEDIA_LIBRARY_PATH` exists, is readable, and contains anime media files.

## Files
- `src/6_Seanime/deploy.sh`: Idempotent deployment script implementing C.O.R.E deployment contract for Seanime.
- `src/6_Seanime/wipe.sh`: Removal script for runtime artifacts, ingress config, and optional package purge.
- `/opt/core/seanime/compose.yaml`: Generated container orchestration definition.
- `/etc/nginx/sites-available/seanime.core`: Ingress virtual host definition for the service.