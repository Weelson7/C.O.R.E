# C.O.R.E AdGuard Home

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized DNS control-plane service based on AdGuard Home, deployed as a single-node runtime.
- What it does: Hosts DNS filtering/rewrites for `.core` service discovery and provides an operator-driven setup and validation flow.
- Why this service exists in C.O.R.E: It is the local DNS authority used to map service hostnames (for example `index.core`) to mesh-reachable node IPs.

## Commands
- Start: `sudo docker compose -f /opt/core/adguard/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/adguard/compose.yaml down`
- Restart: `sudo docker rm -f core-adguard ; sudo docker compose -f /opt/core/adguard/compose.yaml up -d`
- Status: `sudo docker ps --filter name=core-adguard` and `sudo docker inspect -f '{{.State.Status}}' core-adguard`
- Logs: `sudo docker logs -f core-adguard`
- Edit/Reload: edit `src/2_Adguard/deploy.sh`, rerun deploy script, then validate DNS/ports in AdGuard UI and local checks.

## Runtime parameters
- Node(s): Service roles are Supervisor-managed from Netbird-discovered nodes. Current deploy script activates a single local runtime instance.
- Domain: DNS authority role for `.core` host rewrites (service UI exposed on local host).
- Port(s): `53/tcp`, `53/udp`, `80/tcp`, `3000/tcp`, `443/tcp`.
- Volumes/Data path:
	- Deploy script: `src/2_Adguard/deploy.sh`
	- Build/runtime root: `/opt/core/adguard`
	- Build context: `/opt/core/adguard/build`
	- Runtime work dir: `/opt/core/adguard/work`
	- Runtime config dir: `/opt/core/adguard/conf`
	- Compose file (generated): `/opt/core/adguard/compose.yaml`
	- Generated archive: `/opt/core/adguard/build/AdGuardHome_linux_amd64.tar.gz`
	- Container image build file (generated): `/opt/core/adguard/build/Dockerfile`
- Environment/config tweaks:
	- `ADGUARD_VERSION` (optional): release tag used for download, default `v0.107.59`.
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- Script requires `sudo` for package install, file placement, Docker, and service operations.
	- DNS service binds standard DNS ports (`53/tcp+udp`), so host firewall/policy alignment is required.
	- Wizard completion and rewrite validation are operator-gated loops to prevent blind success reporting.

## Deployment sequence
1. Validate host/runtime prerequisites and install dependencies.
	- Enforce Ubuntu preflight.
	- Verify required commands (`sudo`, `apt`, `curl`, `tar`, `docker`, `dig`, `ss`, `awk`, `grep`).
	- Install runtime packages: `ca-certificates`, `curl`, `tar`, `docker.io`, `docker-compose-plugin`, `dnsutils`.
	- Enable and restart Docker service.
2. Apply single-node runtime mode.
	- Create required directories under `/opt/core/adguard`.
	- No scenario prompt/branching is used.
3. Download and prepare AdGuard Home artifacts.
	- Download selected release archive from GitHub.
	- Extract binary payload into `/opt/core/adguard/build/AdGuardHome`.
	- Generate runtime Dockerfile in build context.
4. Build and start container runtime.
	- Build image tag `core/adguard:local`.
	- Generate compose file and start `core-adguard` container.
	- Verify container state is `running`.
5. Complete setup wizard gate with live scans.
	- Operator completes initial setup at `http://localhost:3000`.
	- Script scans `tcp/3000`, `tcp/53`, `udp/53` and loops until setup is confirmed and DNS ports are active.
6. Capture and validate rewrite targets.
	- Operator enters rewrite count and host/IP pairs.
	- For each rewrite, script loops on DNS query validation (`dig @127.0.0.1 -p 53 ... A`) until expected IP is returned.
7. Final runtime and config validation.
	- Recheck container running state.
	- Recheck control panel and DNS port listeners.
	- Re-validate every captured rewrite entry.

Validation checks:
- `sudo docker ps --filter name=core-adguard`
- `sudo docker inspect -f '{{.State.Status}}' core-adguard`
- `curl --fail http://127.0.0.1:3000`
- `ss -lnt | grep -E '(^|:)53$|(^|:)3000$'`
- `ss -lnu | grep -E '(^|:)53$'`
- `dig +short @127.0.0.1 -p 53 <service.core> A`

Failure handling notes:
- Download/extract failure: verify outbound HTTPS access to GitHub release URL and rerun deploy.
- Container not running: inspect `sudo docker logs core-adguard` and rerun deploy.
- Setup gate not passing: confirm AdGuard wizard has been saved and DNS listeners are enabled on port 53 (tcp+udp).
- Rewrite mismatch loops: correct rewrite entries in AdGuard UI and rerun validation prompt.
- Port conflicts on host: stop conflicting DNS/web services before redeploying.

## Files
- `src/2_Adguard/deploy.sh`: Idempotent Ubuntu-targeted deployment and operator validation workflow.
- `/opt/core/adguard/build/Dockerfile`: Generated container build recipe for AdGuard runtime image.
- `/opt/core/adguard/compose.yaml`: Generated compose definition for single-node runtime.
- `/opt/core/adguard/work`: Persistent AdGuard runtime/work data volume.
- `/opt/core/adguard/conf`: Persistent AdGuard configuration volume.