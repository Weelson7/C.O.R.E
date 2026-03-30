# C.O.R.E Indexer

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- Operational status: Functional.
- What it is: A mesh-scoped service index composed of a static frontend and a Flask API backend, exposed through Nginx ingress.
- What it does: Serves a static service catalog via `/api/sites`, actively probing each registered `.core` service for reachability on every request (10-second TTL cache), and delivers health state to the index UI.
- Why this service exists in C.O.R.E: It provides a single operational entry point for cluster services under the `.core` namespace and makes service reachability status visible at a glance.

## Commands
- Start: `sudo docker compose -f /opt/core/indexer/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/indexer/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/indexer/compose.yaml up -d --build --force-recreate`
- Status: `sudo docker compose -f /opt/core/indexer/compose.yaml ps` and `sudo docker inspect -f '{{.State.Status}}' core-indexer`
- Logs: `sudo docker logs -f core-indexer` and `sudo tail -f /var/log/nginx/core-indexer.error.log`
- Edit/Reload: edit `src/1_Indexer/deploy.sh` or frontend files, rerun deploy script, then `sudo nginx -t ; sudo systemctl reload nginx`
- Wipe: `sudo bash src/1_Indexer/wipe.sh` (interactive) or `FORCE=true sudo bash src/1_Indexer/wipe.sh` (unattended)

## Runtime parameters
- Node(s): Service roles are Supervisor-managed. By default the Supervisor node (node 0) is alpha; beta and gamma are optional per-service assignments.
- Domain: `index.core`
- Port(s): External `443` (TLS) and `80` (redirect), internal API loopback `127.0.0.1:5001` by default.
- Volumes/Data path:
    - Host static UI: `/var/www/core-indexer`
    - Container build/runtime context: `/opt/core/indexer`
    - Nginx site: `/etc/nginx/sites-available/index.core`
    - TLS assets: `/etc/nginx/ssl/index.core.crt` and `/etc/nginx/ssl/index.core.key`
    - Auth file: `/etc/nginx/.htpasswd_core`
- Environment/config tweaks:
    - `NETBIRD_DEVICE_IP` (required): expected mesh IP for DNS contract check.
    - `NETBIRD_FAILOVER_IP` (optional): secondary mesh IP accepted as valid during DNS validation.
    - `HTPASSWD_USER` (required): HTTP Basic Auth account to create/update.
    - `HTPASSWD_PASSWORD` (optional at invocation): HTTP Basic Auth password; prompted interactively if unset.
    - `API_PORT` (optional, default `5001`): backend listen port and loopback publish target.
    - `API_SOURCE_DIR` (optional): source folder synced into `/opt/core/indexer`.
    - `API_ENTRYPOINT` (optional): backend entrypoint filename used in Dockerfile `CMD` and fallback generation logic.
    - `IMAGE_TAG` (optional, default `core/indexer:local`): Docker image tag.
    - `STRICT_DNS_VALIDATION` (optional, default `false`): when `true`, deployment fails if `index.core` does not resolve at step 8.
    - `API_HEALTH_RETRIES` (optional, default `30`): number of health check attempts for local and ingress endpoints.
    - `API_HEALTH_DELAY_SECONDS` (optional, default `2`): seconds between health check attempts.
    - `DOCKER_COMPOSE_PLUGIN_VERSION` (optional, default `v2.29.7`): compose plugin version used for manual fallback install.
    - `FORCE` (optional, default `false`): set to `true` in `wipe.sh` to skip interactive confirmation.
    - `PURGE_PACKAGES` (optional, default `true`): set to `false` in `wipe.sh` to skip apt package removal.
- Security constraints:
    - Both scripts are Ubuntu-only and exit when the host OS is not Ubuntu.
    - Mesh-only administrative surface expected by policy.
    - TLS is mandatory for `index.core` ingress.
    - HTTP Basic Auth enforced at Nginx boundary.
    - API container binds on loopback only (`127.0.0.1`) and is not directly mesh-exposed.
    - Security headers enforced by Nginx: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`.

## Deployment sequence
1. Install host dependencies (`nginx`, `mkcert`, `docker.io`, `docker-compose-plugin`, auth and validation tooling) to satisfy deploy contract prerequisites.
    - Preflight checks ensure Ubuntu host and required commands are present before deployment proceeds.
    - If `docker-compose-plugin` is unavailable via apt, the compose plugin is downloaded and installed manually from GitHub for the detected host architecture (`x86_64` or `aarch64`).
2. Generate TLS materials for `index.core` via `mkcert`, then place certificate and key under `/etc/nginx/ssl/` with restrictive permissions (`640` cert, `600` key).
3. Copy static frontend assets (`index.html`, `style.css`, `logic.js`) to `/var/www/core-indexer` for Nginx static delivery. `logo.png` is copied if present in the script directory.
4. Sync API source into `/opt/core/indexer` via `rsync --delete`, then generate runtime artifacts:
    - `/opt/core/indexer/Dockerfile`: installs Flask via inline `pip install` and sets the entrypoint to the API file.
    - `/opt/core/indexer/compose.yaml`: binds the container on `127.0.0.1:${API_PORT}` with restart policy `unless-stopped`.
    - If the API entrypoint file is absent after the rsync, a minimal fallback `app.py` is generated with stub `/api/sites` and `/health` endpoints.
5. Create or update ingress auth credentials in `/etc/nginx/.htpasswd_core` for the specified operator account.
6. Write Nginx site config at `/etc/nginx/sites-available/index.core`, enable it, remove legacy/default site symlinks, validate syntax (`nginx -t`), and restart Nginx.
7. Build and start containerized backend with `docker compose up -d --build`, then verify:
    - Container state is `running` via `docker inspect`
    - Local API endpoint `http://127.0.0.1:${API_PORT}/api/sites` returns success
8. Validate mesh and naming contract:
    - Netbird must be connected (`netbird status`)
    - `index.core` must resolve via `getent ahostsv4` and match `NETBIRD_DEVICE_IP` or `NETBIRD_FAILOVER_IP`
    - If `getent` returns no results, a direct DNS-only curl reachability check is attempted as fallback
    - If `STRICT_DNS_VALIDATION=true` and DNS is unresolved, deployment fails
    - Authenticated ingress endpoint `https://index.core/api/sites` must return success (via DNS or `--resolve` IP override depending on DNS state)

Validation checks:
- `sudo nginx -t`
- `sudo docker compose -f /opt/core/indexer/compose.yaml ps`
- `curl --fail http://127.0.0.1:5001/api/sites`
- `curl --fail --insecure -u <user>:<pass> https://index.core/api/sites`
- `getent ahostsv4 index.core`

Failure handling notes:
- TLS generation failure: rerun `mkcert -install` and ensure generated `.pem` files exist in working or script directories.
- Container not running: inspect `sudo docker logs core-indexer` and rebuild with `sudo docker compose -f /opt/core/indexer/compose.yaml up -d --build`.
- Nginx validation failure: inspect `/var/log/nginx/core-indexer.error.log`, fix config, rerun `sudo nginx -t`.
- DNS mismatch/unresolved: correct AdGuard rewrite and Netbird nameserver group so `index.core` resolves to expected mesh IP.
- Netbird disconnected: restore mesh connectivity before declaring deployment complete.
- Full teardown: run `wipe.sh` to remove all artifacts, then redeploy from scratch with `deploy.sh`.

## Files
- `src/1_Indexer/deploy.sh`: Idempotent deployment script implementing the architecture contract and containerized API runtime.
- `src/1_Indexer/wipe.sh`: Teardown script that removes all Indexer artifacts, container workload, ingress config, TLS material, and optionally purges installed packages.
- `src/1_Indexer/app.py`: Flask API backend serving the static service catalog at `/api/sites` with active per-service health probing and a 10-second TTL cache.
- `src/1_Indexer/index.html`: C.O.R.E index UI shell and telemetry layout.
- `src/1_Indexer/style.css`: Branding-compliant visual system and status semantics.
- `src/1_Indexer/logic.js`: Frontend data fetch, card rendering, and incident-state mapping.
- `src/1_Indexer/logo.png`: Canonical C.O.R.E brand mark used in the service header (copied to web root if present).
- `/opt/core/indexer/Dockerfile`: Generated backend container build recipe.
- `/opt/core/indexer/compose.yaml`: Generated container orchestration definition for the indexer API.
- `/etc/nginx/sites-available/index.core`: Ingress virtual host definition for the service.