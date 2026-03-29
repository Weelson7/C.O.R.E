# C.O.R.E ncdu-web-viewer

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- Operational status: Functional.
- What it is: A web-based disk usage analyzer wrapped in a containerized HTTP service, exposed through Nginx ingress.
- What it does: Provides an interactive disk usage visualization and analysis interface scoped to the alpha node's filesystem, allowing operators to identify storage hotspots and manage disk capacity.
- Why this service exists in C.O.R.E: Disk monitoring is essential for cluster operational health. ncdu-web-viewer provides a low-friction, visual mechanism for exploring filesystem usage across assigned node roles without requiring direct CLI access.

## Commands
- Start: `sudo docker compose -f /opt/core/ncdu-web-viewer/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/ncdu-web-viewer/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/ncdu-web-viewer/compose.yaml up -d --build --force-recreate`
- Status: `sudo docker compose -f /opt/core/ncdu-web-viewer/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-ncdu-web-viewer`
- Logs: `sudo docker logs -f core-ncdu-web-viewer` and `sudo tail -f /var/log/nginx/core-ncdu-web-viewer.error.log`
- Edit/Reload: edit `src/13_ncdu-web-viewer/deploy.sh` or container configuration, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`

## Runtime parameters
- Node(s): Service roles are Supervisor-managed per [Architecture.md § 3.2](../Architecture.md#32-supervisor-bootstrap). By default the Supervisor node (node 0) is alpha; beta and gamma are optional per-service assignments.
- Domain: `ncdu.core`
- Port(s): External `443` (TLS) and `80` (redirect), internal HTTP loopback `127.0.0.1:3000` by default.
- Volumes/Data path:
	- Container runtime context: `/opt/core/ncdu-web-viewer`
	- Nginx site: `/etc/nginx/sites-available/ncdu.core`
	- TLS assets: `/etc/nginx/ssl/ncdu.core.crt` and `/etc/nginx/ssl/ncdu.core.key`
	- Auth file: `/etc/nginx/.htpasswd_core`
	- Scanned filesystem root: `/mnt/scan` (mounted into container, typically host root or dedicated scan path)
- Environment/config tweaks:
	- `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
	- `HTPASSWD_USER` (required): HTTP Basic Auth account to create/update.
	- `HTTP_PORT` (optional, default `3000`): backend listen port and loopback publish target.
	- `SCAN_PATH` (optional, default `/`): filesystem path to scan and present to the UI.
	- `IMAGE_TAG` (optional): Docker image tag, default `core/ncdu-web-viewer:local`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- Mesh-only administrative surface expected by policy per [Architecture.md § 8.1](../Architecture.md#81-access-model).
	- TLS is mandatory for `ncdu.core` ingress per [Architecture.md § 8.2](../Architecture.md#82-proxy-and-service-security-baseline).
	- HTTP Basic Auth enforced at Nginx boundary.
	- Container binds on loopback only (`127.0.0.1`) and is not directly mesh-exposed.
	- Security headers enforced by Nginx: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`.
	- Filesystem scan scope is restricted to mounted paths only; escape attempts are blocked by container isolation.

## Deployment sequence
1. Install host dependencies (`nginx`, `mkcert`, `docker.io`, `docker-compose-plugin`, auth and validation tooling) to satisfy deploy contract prerequisites.
	- Preflight checks ensure Ubuntu host and required commands are present before deployment proceeds.
2. Generate TLS materials for `ncdu.core` via `mkcert`, then place certificate and key under `/etc/nginx/ssl/` with restrictive permissions.
3. Prepare filesystem mount configuration:
	 - Determine scan target (`SCAN_PATH`); default is host root `/` but may be scoped to a specific mount or storage volume.
	 - Ensure the path is readable from the container runtime context.
4. Generate runtime artifacts in `/opt/core/ncdu-web-viewer`:
	 - `/opt/core/ncdu-web-viewer/Dockerfile` - ncdu HTTP wrapper container recipe
	 - `/opt/core/ncdu-web-viewer/compose.yaml` - container orchestration definition
5. Create or update ingress auth credentials in `/etc/nginx/.htpasswd_core` for the specified operator account.
6. Write Nginx site config at `/etc/nginx/sites-available/ncdu.core`, enable it, remove legacy/default links, validate syntax (`nginx -t`), and restart Nginx.
7. Build and start containerized service with `docker compose up -d --build`, then verify:
	 - Container state is `running`
	 - Local HTTP endpoint `http://127.0.0.1:${HTTP_PORT}` responds to health checks
8. Validate mesh and naming contract:
	 - Netbird must be connected (`netbird status`)
	 - `ncdu.core` must resolve and match `NETBIRD_DEVICE_IP`
	 - Ingress endpoint `https://ncdu.core/` must be reachable and authenticated

Validation checks:
- `sudo nginx -t`
- `sudo docker compose -f /opt/core/ncdu-web-viewer/compose.yaml ps`
- `curl --fail http://127.0.0.1:3000/` (should return 200 with HTML)
- `curl --fail --insecure https://ncdu.core/` (should return 401 before auth, 200 after)
- `getent ahostsv4 ncdu.core` (should resolve to `NETBIRD_DEVICE_IP`)

Failure handling notes:
- TLS generation failure: rerun `mkcert -install` and ensure generated `.pem` files exist in working or script directories.
- Container not running: inspect `sudo docker logs core-ncdu-web-viewer` and rebuild with `sudo docker compose -f /opt/core/ncdu-web-viewer/compose.yaml up -d --build`.
- Nginx validation failure: inspect `/var/log/nginx/core-ncdu-web-viewer.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: correct AdGuard rewrite and Netbird nameserver group so `ncdu.core` resolves to expected mesh IP.
- Netbird disconnected: restore mesh connectivity before declaring deployment complete.
- Scan returns no data: verify mount path is readable and contains accessible files; check container logs for access errors.

## Files
- `src/13_ncdu-web-viewer/deploy.sh`: Idempotent deployment script implementing the architecture contract and containerized ncdu runtime.
- `/opt/core/ncdu-web-viewer/Dockerfile`: Generated container build recipe for ncdu HTTP wrapper.
- `/opt/core/ncdu-web-viewer/compose.yaml`: Generated container orchestration definition for the ncdu-web-viewer.
- `/etc/nginx/sites-available/ncdu.core`: Ingress virtual host definition for the service.
