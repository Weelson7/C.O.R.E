# C.O.R.E. Implementation Plan — Service 3 Restructure & Services 15–25


## Table of Contents
- [Service Index Changes](#service-index-changes)
- [Logic Checks](#logic-checks)
- [Pre-Deployment Checklist](#pre-deployment-checklist)
- [Phase 1 — Service 3: JellyArr](#phase-1--service-3-jellyarr)
- [Phase 2 — Security Tooling (15–17)](#phase-2--security-tooling-services-1517)
- [Phase 3 — OSINT (18–20)](#phase-3--osint-services-1820)
- [Phase 4 — Credentials (21)](#phase-4--credentials-service-21)
- [Phase 5 — Phishing (22–24)](#phase-5--phishing-services-2224)
- [Phase 6 — Minecraft (25)](#phase-6--minecraft-service-25)
- [Post-Deployment Supervisor Policy](#post-deployment-supervisor-policy)


---


## Service Index Changes


Service 3 is restructured from `Jellyfin` (standalone) to `JellyArr` (composite suite).
Services previously planned as 15–21 are folded into service 3.
Security, OSINT, credentials, and phishing services are renumbered accordingly.


### Full Updated Index


| # | Service | Category | Change |
|---|---|---|---|
| 0 | Netbird | Infrastructure | unchanged |
| 1 | Indexer | Infrastructure | unchanged |
| 2 | AdGuard | Infrastructure | unchanged |
| **3** | **JellyArr** | **Media Suite** | **restructured** |
| 4 | Suwayomi | Media | unchanged |
| 5 | KASM | Dev / Remote | unchanged |
| 6 | qBittorrent | Downloads | unchanged — standalone |
| 7 | ttyd | Dev / Shell | unchanged |
| 8 | Seanime | Media | unchanged |
| 9 | Jupyter | Dev | unchanged |
| 10 | OnlyOffice | Productivity | unchanged |
| 11 | Doom | Entertainment | unchanged |
| 12 | Seafile | Storage | unchanged |
| 13 | ncdu-web-viewer | Ops | unchanged |
| 14 | Music Assistant | Media | unchanged |
| 15 | Greenbone CE | Security | new |
| 16 | Reconmap | Security | new |
| 17 | OWASP ZAP | Security | new |
| 18 | SpiderFoot | OSINT | new |
| 19 | IVRE | OSINT | new |
| 20 | Maigret | OSINT | new |
| 21 | h8mail | OSINT / Credentials | new |
| 22 | GoPhish | Phishing | new |
| 23 | Evilginx3 | Phishing | new |
| 24 | BeEF | Phishing | new |
| 25 | Minecraft | Gaming | new |


### Service 3 — JellyArr Internal Components


JellyArr is a single C.O.R.E. service (one compose stack, one deploy.sh, one Supervisor entry).
It contains the following internal containers, all on network `jellyarr-net`:


| Container | Domain | Port |
|---|---|---|
| core-jellyarr-qbittorrent | qbittorrent-arr.core | 8082 |
| core-jellyarr-prowlarr | prowlarr.core | 9696 |
| core-jellyarr-radarr | radarr.core | 7878 |
| core-jellyarr-sonarr | sonarr.core | 8989 |
| core-jellyarr-lidarr | lidarr.core | 8686 |
| core-jellyarr-readarr | readarr.core | 8787 |
| core-jellyarr-bazarr | bazarr.core | 6767 |
| core-jellyarr-jellyfin | jellyfin.core | 8096 |
| core-jellyarr-jellyseerr | jellyarr.core | 5055 |


> `jellyarr.core` (Jellyseerr) is the user-facing entry point for the entire suite.
> `jellyfin.core` remains the direct media playback endpoint.
> All other *arr domains are operator-facing only.


---


## Logic Checks


These three checks must pass before any phase begins.


### ✅ Logic Check 1 — qBittorrent Port and Path Isolation


JellyArr deploys its own dedicated qBittorrent instance. It must not conflict with service 6.


| | Service 6 (standalone) | JellyArr internal |
|---|---|---|
| Container name | `core-qbittorrent` | `core-jellyarr-qbittorrent` |
| WebUI host port | existing (do not change) | **8082** |
| Download path | `/downloads` (existing) | `/media/jellyarr/downloads` |
| Docker network | service-6 network | `jellyarr-net` (isolated) |


**Check:** confirm `ss -tlnp \| grep 8082` returns empty before deploying JellyArr.
**Check:** confirm `/media/jellyarr/` does not exist yet and can be created fresh.


### ✅ Logic Check 2 — Service 3 Rename Impact


The existing `3_Jellyfin.md` doc and `jellyfin.core` nginx virtual host must be handled.


- `3_Jellyfin.md` → archive as `3_Jellyfin.DEPRECATED.md`, replace with `3_JellyArr.md`
- `jellyfin.core` nginx block → keep, redirect to port 8096 inside the new compose network
- Supervisor policy entry for service 3 → rename from `jellyfin` to `jellyarr`
- Container name `core-jellyfin` → becomes `core-jellyarr-jellyfin` (compose-scoped)


**Check:** after deploy, `jellyfin.core` must still resolve and serve Jellyfin — existing bookmarks must not break.
**Check:** Supervisor service entry for `3` must reference `jellyarr`, not `jellyfin`.


### ✅ Logic Check 3 — Nginx Virtual Host Coverage


JellyArr adds 9 new `.core` virtual hosts in a single deployment. All must be wired before the compose stack starts.


**Pre-deploy:** create and test all 9 nginx server blocks:

```bash
nginx -t  # must pass before docker compose up
```

**Check:** every domain in the JellyArr component table above resolves via AdGuard (service 2) to the alpha node IP.
**Check:** `curl -sk https://jellyarr.core` returns HTTP 200 or 302 — not a connection refused or nginx 502.
If any block fails: remove the failing block, run `nginx -t` again, reload, then debug the container before re-adding.


---


## Pre-Deployment Checklist


**Folder structure — create on alpha node before any phase:**

```bash
mkdir -p /media/jellyarr/{downloads,movies,tv,music,books}
mkdir -p /media/jellyarr/config/{qbittorrent,prowlarr,radarr,sonarr,lidarr,readarr,bazarr,jellyfin,jellyseerr}
mkdir -p /mnt/breach-data
```


**Port reservation — confirm none are in use:**

```bash
ss -tlnp | grep -E '8082|9696|7878|8989|8686|8787|6767|8096|5055|9392|5500|5501|8090|5001|8091|3333|8880|3000|6789'
```

Expected: no output. Any hit must be resolved before proceeding.


**Supervisor policy — apply before starting:**
- Register service 3 as `jellyarr` (replace `jellyfin` entry).
- Register services 15–25 as alpha-only, no beta/gamma until explicitly configured.
- Add all new `.core` virtual hosts to DNS scope.
- Flag service 23 (Evilginx3) as topology exception: dedicated node, no Nginx.


**Architecture.md update — required before starting (§13 governance):**
- Update §5.1: service inventory now spans 0–24, with service 3 redefined as JellyArr.
- Add composite service definition: "a C.O.R.E. service may consist of multiple internal containers managed under a single compose stack and Supervisor entry."
- Add topology exception entry for service 23.


---


## Phase 1 — Service 3: JellyArr


**Estimated time:** 1–2 hours.
**Reference:** https://github.com/automation-avenue/arr-new


### Step 1 — Create the compose file


Path: `/opt/core/services/3_jellyarr/docker-compose.yml`


```yaml
name: jellyarr

networks:
  jellyarr-net:
    driver: bridge

volumes:
  qbittorrent-config:
  prowlarr-config:
  radarr-config:
  sonarr-config:
  lidarr-config:
  readarr-config:
  bazarr-config:
  jellyfin-config:
  jellyseerr-config:

services:

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: core-jellyarr-qbittorrent
    networks: [jellyarr-net]
    ports:
      - "8082:8080"
    volumes:
      - qbittorrent-config:/config
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
      - WEBUI_PORT=8080
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: core-jellyarr-prowlarr
    networks: [jellyarr-net]
    ports:
      - "9696:9696"
    volumes:
      - prowlarr-config:/config
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: core-jellyarr-radarr
    networks: [jellyarr-net]
    ports:
      - "7878:7878"
    volumes:
      - radarr-config:/config
      - /media/jellyarr/movies:/movies
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: core-jellyarr-sonarr
    networks: [jellyarr-net]
    ports:
      - "8989:8989"
    volumes:
      - sonarr-config:/config
      - /media/jellyarr/tv:/tv
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: core-jellyarr-lidarr
    networks: [jellyarr-net]
    ports:
      - "8686:8686"
    volumes:
      - lidarr-config:/config
      - /media/jellyarr/music:/music
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  readarr:
    image: lscr.io/linuxserver/readarr:develop
    container_name: core-jellyarr-readarr
    networks: [jellyarr-net]
    ports:
      - "8787:8787"
    volumes:
      - readarr-config:/config
      - /media/jellyarr/books:/books
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: core-jellyarr-bazarr
    networks: [jellyarr-net]
    ports:
      - "6767:6767"
    volumes:
      - bazarr-config:/config
      - /media/jellyarr/movies:/movies
      - /media/jellyarr/tv:/tv
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: core-jellyarr-jellyfin
    networks: [jellyarr-net]
    ports:
      - "8096:8096"
    volumes:
      - jellyfin-config:/config
      - /media/jellyarr/movies:/data/movies
      - /media/jellyarr/tv:/data/tv
      - /media/jellyarr/music:/data/music
      - /media/jellyarr/books:/data/books
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: core-jellyarr-jellyseerr
    networks: [jellyarr-net]
    ports:
      - "5055:5055"
    volumes:
      - jellyseerr-config:/app/config
    environment:
      - TZ=Europe/Brussels
    restart: unless-stopped
```


### Step 2 — Deploy the stack


```bash
cd /opt/core/services/3_jellyarr
docker compose up -d
docker compose ps   # all 9 containers must show "running"
```


### Step 3 — Configure internal wiring (in this order)


**a. qBittorrent**
- Open `qbittorrent-arr.core` → Tools → WebUI → change default password.
- Create categories: `radarr`, `sonarr`, `lidarr`, `readarr`.
- Set default save path to `/downloads`.


**b. Prowlarr**
- Open `prowlarr.core` → add indexers.
- Do not add *arr apps yet — wait until they are configured.


**c. Radarr / Sonarr / Lidarr / Readarr**
- Each: Settings → Download Clients → add qBittorrent at `http://core-jellyarr-qbittorrent:8080` (internal container hostname).
- Each: Settings → General → copy API key.
- Return to Prowlarr → Settings → Apps → add each *arr using its internal hostname and API key.


**d. Bazarr**
- Settings → Sonarr → host: `core-jellyarr-sonarr`, port: `8989`, API key from Sonarr.
- Settings → Radarr → host: `core-jellyarr-radarr`, port: `7878`, API key from Radarr.


**e. Jellyfin**
- First-run wizard: set admin credentials.
- Add libraries pointing to `/data/movies`, `/data/tv`, `/data/music`, `/data/books`.


**f. Jellyseerr**
- First-run wizard → sign in with Jellyfin at `http://core-jellyarr-jellyfin:8096`.
- Add Radarr: host `core-jellyarr-radarr`, port `7878`, API key.
- Add Sonarr: host `core-jellyarr-sonarr`, port `8989`, API key.


### Nginx Virtual Hosts


Add one `server` block per component. Pattern — repeat for all 9 domains:

```nginx
server {
    listen 443 ssl;
    server_name jellyarr.core;
    location / {
        proxy_pass http://127.0.0.1:5055;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> WebSocket headers (`Upgrade`, `Connection`) are required for Jellyfin and Jellyseerr.
> Operator-facing *arr domains (prowlarr, radarr, sonarr, lidarr, readarr, bazarr) should have HTTP auth enforced at the Nginx boundary in addition to their native auth.


### Validation
- [ ] `docker compose ps` shows all 9 containers as `running (healthy)`
- [ ] `jellyarr.core` loads Jellyseerr login
- [ ] `jellyfin.core` loads Jellyfin — libraries visible
- [ ] `prowlarr.core` shows all *arr apps connected (green)
- [ ] `radarr.core` shows qBittorrent connected (green)
- [ ] Manual grab test: search a movie in Radarr → appears in `qbittorrent-arr.core` download queue
- [ ] `bazarr.core` shows Sonarr and Radarr connected
- [ ] Submit a request in Jellyseerr → appears in Radarr/Sonarr queue
- [ ] `jellyfin.core` still resolves correctly (Logic Check 2 confirmation)
- [ ] `curl -sk https://jellyarr.core` returns 200 or 302 (Logic Check 3 confirmation)


### Rollback
```bash
docker compose down
# volumes are preserved — data is not lost
# fix the issue, then docker compose up -d again
```


---


## Phase 2 — Security Tooling (Services 15–17)


**Estimated time:** 2–6 hours (dominated by Greenbone feed sync).


### Service 15 — Greenbone CE


Start first. Feed sync runs in the background while you deploy 16 and 17.

```bash
git clone https://github.com/greenbone/greenbone-community-edition
cd greenbone-community-edition
docker compose up -d
```

- Monitor sync: `docker compose logs -f`
- Do not run scans until sync completes — GSA Feed Status page shows the sync state.
- Change the default `admin` password immediately after first login.
- Schedule weekly feed sync via cron — never overlap with active scans.
- Nginx virtual host: `greenbone.core` → `localhost:9392`


### Service 16 — Reconmap


```bash
git clone https://github.com/reconmap/reconmap
cd reconmap
docker compose up -d
docker exec -it reconmap-app php artisan migrate
```

- Nginx virtual host: `reconmap.core` → `localhost:5500`
- HTTP auth enforced at Nginx — Reconmap has its own auth but add the Nginx layer per security baseline.


### Service 17 — OWASP ZAP


```bash
docker run -d --name core-owasp-zap \
  -p 8090:8090 \
  ghcr.io/zaproxy/zaproxy:stable \
  zap.sh -daemon -host 0.0.0.0 -port 8090 \
  -config api.addrs.addr.name=.* \
  -config api.addrs.addr.regex=true \
  -config api.key=CHANGEME
```

- Nginx virtual host: `zap.core` → `localhost:8090`
- HTTP auth enforced at Nginx — ZAP has no native auth layer.


### Validation
- [ ] `greenbone.core` loads — Feed Status shows recent sync date
- [ ] Test scan runs against a local mesh IP and completes
- [ ] `reconmap.core` loads — create a project, add a finding
- [ ] `zap.core` rejects requests missing the API key


### Supervisor Policy
Greenbone is RAM-heavy during active scans. Assign service 15 to the node with the most available RAM. Services 16 and 17 can share alpha with other services.


---


## Phase 3 — OSINT (Services 18–20)


**Estimated time:** 1–2 hours.


### Service 18 — SpiderFoot


```bash
docker run -d --name core-spiderfoot \
  -p 5001:5001 \
  -v spiderfoot-data:/var/lib/spiderfoot \
  ghcr.io/smicallef/spiderfoot -l 0.0.0.0:5001
```

- Nginx virtual host: `spiderfoot.core` → `localhost:5001`
- **SpiderFoot has no native auth.** HTTP auth at Nginx is mandatory.
- Modules requiring API keys self-disable — all keyless modules run immediately.


### Service 19 — IVRE


```bash
git clone https://github.com/ivre/ivre
cd ivre
docker compose up -d

# Initialize databases
docker exec -it ivre-client ivre ipinfo --init
docker exec -it ivre-client ivre scancli --init
```

Data ingestion (run after each scan):

```bash
# Export Nmap scan to XML, then import
docker exec -it ivre-client ivre nmap2db -r -s NodeScan /ivre-share/results.xml
```

- MongoDB is internal only — not exposed outside the compose network.
- Nginx virtual host: `ivre.core` → `localhost:8091`


### Service 20 — Maigret


No persistent service — on-demand via ttyd (service 7):

```bash
docker run --rm \
  -v maigret-reports:/reports \
  ghcr.io/soxoj/maigret:latest \
  USERNAME --html -o /reports/USERNAME.html
```

- Reports land in `maigret-reports` volume — mount into a static file server or browse directly via ttyd.
- No Nginx virtual host required.


### Validation
- [ ] `spiderfoot.core` loads — run a test scan on a domain you control, confirm HTTP auth gate works
- [ ] `ivre.core` loads — import a test Nmap XML, confirm host appears in the web view
- [ ] Maigret in ttyd: `maigret testusername --print-found` returns results


---


## Phase 4 — Credentials (Service 21)


**Estimated time:** 15 min deploy. Days for dataset acquisition.


### Service 21 — h8mail


```bash
docker run -d --name core-h8mail \
  -v /mnt/breach-data:/breach:ro \
  ghcr.io/khast3x/h8mail:latest \
  tail -f /dev/null
```

Operational usage via ttyd:

```bash
# Single target — local only, plaintext output
docker exec core-h8mail h8mail -t target@email.com -bc /breach/ -sk

# Batch
docker exec core-h8mail h8mail -t targets.txt -bc /breach/ -sk -o results.txt
```

- `-sk` disables all API calls — fully local.
- `-bc` accepts the BreachCompilation root; h8mail walks subdirectories automatically.
- `-gz` enables search inside gzipped collections without extraction.


### Dataset Acquisition


Stage to `/mnt/breach-data/` on the alpha node, in priority order:


| Dataset | Size | Records |
|---|---|---|
| BreachCompilation | ~44 GB | 1.4B — structured by email domain |
| COMB | ~100 GB | 3.2B |
| Collection #1–5 | ~87 GB | varied |


- Total: **~230 GB minimum.**
- Transfer over Netbird mesh only — never over plain LAN.
- Data class: **Critical.**
- Volume mounted read-only — the container must never write to breach data.


### Validation
- [ ] `docker exec core-h8mail h8mail -t known-leaked@email.com -bc /breach/ -sk` returns expected credentials
- [ ] Write test: `docker exec core-h8mail touch /breach/test` — must return `Permission denied`


---


## Phase 5 — Phishing (Services 22–24)


**Estimated time:** 1 hour for 22 and 24. Service 23 requires DNS pre-work.


### ⚠️ Service 23 (Evilginx3) — Topology Constraint


Evilginx3 owns ports 80 and 443 on its node. It cannot share a node with Nginx.


**Option A (recommended):** dedicated node with a public IP — no Nginx, not under `.core` ingress.
**Option B:** second IP on the alpha node — bind Nginx to primary IP, Evilginx3 to secondary IP.


Deploy services 22 and 24 first while DNS propagates for service 23.


### Service 22 — GoPhish


```bash
docker run -d --name core-gophish \
  -p 3333:3333 \
  -p 8880:80 \
  -v gophish-data:/opt/gophish \
  gophish/gophish
```

- Nginx virtual host: `gophish.core` → `localhost:3333` (admin panel only).
- Port 8880 is the HTTP lure listener — expose externally for campaign delivery, not via `.core`.
- Change the default admin password immediately on first login — no other auth layer exists.


### Service 24 — BeEF


```bash
docker run -d --name core-beef \
  -p 3000:3000 \
  -p 6789:6789 \
  -v beef-config:/beef/config \
  bcyber365/beef
```

- Edit `config.yaml` before starting: change `credentials.user` and `credentials.passwd`.
- Nginx virtual host: `beef.core` → `localhost:3000`
- Port 6789 delivers `hook.js` to victim browsers — plan external exposure accordingly.


### Service 23 — Evilginx3 (after DNS propagation)


**DNS pre-work:**
1. Register a throwaway domain.
2. `NS` record: `phish.yourdomain.com` → Evilginx3 node public IP (Evilginx3 acts as nameserver).
3. `A` record: NS hostname → same public IP.
4. Wait for propagation — verify with `dig NS phish.yourdomain.com`.

**Deploy on dedicated node:**

```bash
docker run -d --name core-evilginx3 \
  --network host \
  -v evilginx-data:/app/data \
  ghcr.io/kgretzky/evilginx3 \
  -p /app/phishlets -c /app/data
```

**Initial CLI configuration:**
: config domain phish.yourdomain.com
: config ipv4 <node public IP>
: phishlets hostname <target> <subdomain>.phish.yourdomain.com
: phishlets enable <target>

text

TLS certificates are requested from Let's Encrypt automatically once phishlets are enabled.


### Validation
- [ ] `gophish.core` loads — create a test campaign targeting an internal mesh address
- [ ] `beef.core` loads — `http://<node>:6789/hook.js` returns JavaScript content
- [ ] Evilginx3: `phishlets` shows target as `enabled` with valid TLS cert issued
- [ ] Evilginx3 node: confirm Nginx is not running (`systemctl status nginx` → inactive or not found)


---


## Phase 6 — Minecraft (Service 25)


**Estimated time:** 30–60 minutes for baseline setup (excluding large mod uploads).


### Scope
- Runtime target: NeoForge `1.21.1`.
- Host profile: Ubuntu server, `24 GB` RAM total with `16 GB` dedicated to Minecraft.
- Storage profile: `1 TB` total with `256 GB` dedicated to Minecraft runtime data.
- Exposure model: mesh-first via Netbird, published as `minecraft.core` for C.O.R.E peers.
- Source of truth for mod and config payload: `modpack.md`.


### Required Service Structure (Repository)
- `src/25_Minecraft/run.sh`
- `src/25_Minecraft/setup.sh`
- `src/25_Minecraft/eula.txt`
- `src/25_Minecraft/server.properties`
- `src/25_Minecraft/mods/` (125 JARs)
- `src/25_Minecraft/config/` (full exported config set)
- `src/25_Minecraft/defaultconfigs/` (fresh-world defaults)


### Validation
- [ ] `./run.sh` launches NeoForge server with `-Xmx16G` and stable tick progression.
- [ ] `eula.txt` contains `eula=true` before first production start.
- [ ] `server.properties` enforces `view-distance=8` and `simulation-distance=6`.
- [ ] `mods/` and `config/` payloads match the current `modpack.md` baseline.
- [ ] Netbird peers can resolve and connect to `minecraft.core:25565`.


---


## Post-Deployment Supervisor Policy


### Collocated Group


| Group | Services | Constraint |
|---|---|---|
| JellyArr suite | 3 (all internal containers) | All on same alpha — shared volume mounts |
| Evilginx3 | 23 | Dedicated alpha — no Nginx on node |
| Greenbone | 15 | Prefer highest-RAM node for scan performance |
| All others | 16–22, 24, 25 | No placement constraint |


### Backup Priority


| Priority | Services | Pre-backup hook |
|---|---|---|
| Critical | 3, 15, 16, 22 | Stop container → rsync → start |
| Critical (read-only) | 21 | No rsync — protect source dataset |
| High | 18, 19 | `mongodump` (IVRE), volume rsync (SpiderFoot) |
| Recoverable | 17, 20, 24 | No hook needed |


### Pre-backup Hook Pattern (service 3)


```bash
docker compose -f /opt/core/services/3_jellyarr/docker-compose.yml stop
rsync -a /media/jellyarr/ <beta-node>:/media/jellyarr/
rsync -a /var/lib/docker/volumes/jellyarr_*/ <beta-node>:/backup/jellyarr/volumes/
docker compose -f /opt/core/services/3_jellyarr/docker-compose.yml start
```


### Architecture.md — Required Updates (§13)


The following changes alter service definitions and topology — both require explicit spec update:


1. **§5.1:** Update service inventory span to 0–24. Add definition: *"A C.O.R.E. service may consist of multiple internal containers managed under a single compose stack, a single Supervisor policy entry, and a shared colocation constraint."*
2. **§5.2:** Add `docker compose` as the deployment mechanism for composite services alongside single `docker run` services.
3. **§10 / topology:** Document service 23 (Evilginx3) as the first named topology exception: dedicated node, no Nginx ingress, external-facing trust boundary.
Prepared using Claude Sonnet 4.6 Thinking
Also make sure that Jellyseer is the landing on JellyArr.core, no need to write the code in itself, just its specs

Rewrite the full plan, no need for http auth as there is native auth
Completed 1 step
text
# C.O.R.E. Implementation Plan — Service 3 (JellyArr) & Services 15–25


## Table of Contents
- [Service Index](#service-index)
- [Logic Checks](#logic-checks)
- [Pre-Deployment Checklist](#pre-deployment-checklist)
- [Phase 1 — Service 3: JellyArr](#phase-1--service-3-jellyarr)
- [Phase 2 — Security Tooling (15–17)](#phase-2--security-tooling-services-1517)
- [Phase 3 — OSINT (18–20)](#phase-3--osint-services-1820)
- [Phase 4 — Credentials (21)](#phase-4--credentials-service-21)
- [Phase 5 — Phishing (22–24)](#phase-5--phishing-services-2224)
- [Phase 6 — Minecraft (25)](#phase-6--minecraft-service-25)
- [Post-Deployment Supervisor Policy](#post-deployment-supervisor-policy)


---


## Service Index


Service 3 is restructured from `Jellyfin` (standalone) to `JellyArr` (composite suite).
Services 15–25 are new additions.


| # | Service | Category |
|---|---|---|
| 0 | Netbird | Infrastructure |
| 1 | Indexer | Infrastructure |
| 2 | AdGuard | Infrastructure |
| **3** | **JellyArr** | **Media Suite** |
| 4 | Suwayomi | Media |
| 5 | KASM | Dev / Remote |
| 6 | qBittorrent | Downloads |
| 7 | ttyd | Dev / Shell |
| 8 | Seanime | Media |
| 9 | Jupyter | Dev |
| 10 | OnlyOffice | Productivity |
| 11 | Doom | Entertainment |
| 12 | Seafile | Storage |
| 13 | ncdu-web-viewer | Ops |
| 14 | Music Assistant | Media |
| 15 | Greenbone CE | Security |
| 16 | Reconmap | Security |
| 17 | OWASP ZAP | Security |
| 18 | SpiderFoot | OSINT |
| 19 | IVRE | OSINT |
| 20 | Maigret | OSINT |
| 21 | h8mail | OSINT / Credentials |
| 22 | GoPhish | Phishing |
| 23 | Evilginx3 | Phishing |
| 24 | BeEF | Phishing |
| 25 | Minecraft | Gaming |


### Service 3 — JellyArr Internal Components


JellyArr is one C.O.R.E. service: one compose stack, one deploy.sh, one Supervisor entry.
All internal containers share the `jellyarr-net` bridge network.


| Container | Domain | Port | Role |
|---|---|---|---|
| core-jellyarr-jellyseerr | **jellyarr.core** | 5055 | **Suite landing — request portal** |
| core-jellyarr-jellyfin | jellyfin.core | 8096 | Media playback |
| core-jellyarr-qbittorrent | qbittorrent-arr.core | 8082 | Dedicated downloader |
| core-jellyarr-prowlarr | prowlarr.core | 9696 | Indexer aggregator |
| core-jellyarr-radarr | radarr.core | 7878 | Movie automation |
| core-jellyarr-sonarr | sonarr.core | 8989 | TV automation |
| core-jellyarr-lidarr | lidarr.core | 8686 | Music automation |
| core-jellyarr-readarr | readarr.core | 8787 | Books automation |
| core-jellyarr-bazarr | bazarr.core | 6767 | Subtitle sync |


### jellyarr.core — Landing Specs


- **Bound service:** Jellyseerr (`core-jellyarr-jellyseerr`)
- **Domain:** `jellyarr.core`
- **Port:** 5055
- **Role:** primary user-facing entry point for the entire suite — media discovery, requests, and approval flows
- **Auth:** Jellyfin SSO — users authenticate through their Jellyfin account; no separate credential set
- **Nginx:** `jellyarr.core` proxies to `localhost:5055`; WebSocket headers required (`Upgrade`, `Connection`)
- **Access scope:** all mesh users; operator-only *arr domains are separate


---


## Logic Checks


All three must pass before Phase 1 begins.


### ✅ Logic Check 1 — qBittorrent Isolation


JellyArr's internal qBittorrent must not conflict with service 6.


| | Service 6 | JellyArr internal |
|---|---|---|
| Container name | `core-qbittorrent` | `core-jellyarr-qbittorrent` |
| Host port | existing — do not change | 8082 |
| Download path | `/downloads` | `/media/jellyarr/downloads` |
| Network | service-6 bridge | `jellyarr-net` — isolated |


**Check:** `ss -tlnp | grep 8082` must return empty before deploy.
**Check:** `/media/jellyarr/` must not exist yet — create it fresh in pre-deployment.


### ✅ Logic Check 2 — Service 3 Rename Continuity


- `3_Jellyfin.md` → archive as `3_Jellyfin.DEPRECATED.md`, replace with `3_JellyArr.md`
- `jellyfin.core` nginx block → keep, redirect to port 8096 on the new compose network
- Supervisor entry for service 3 → rename from `jellyfin` to `jellyarr`


**Check:** after deploy, `jellyfin.core` must still resolve and serve Jellyfin — no bookmark breakage.
**Check:** Supervisor service entry `3` references `jellyarr`, not `jellyfin`.


### ✅ Logic Check 3 — Nginx Coverage Before Stack Start


All 9 virtual host blocks must be created and tested before `docker compose up`.


```bash
nginx -t  # must pass cleanly
```

**Check:** all 9 `.core` domains resolve via AdGuard to the alpha node IP.
**Check:** `curl -sk https://jellyarr.core` returns 200 or 302, not 502 or connection refused.

If any block fails: remove it, reload Nginx, debug the container independently, then re-add.


---


## Pre-Deployment Checklist


**Create directory structure on alpha node:**

```bash
mkdir -p /media/jellyarr/{downloads,movies,tv,music,books}
mkdir -p /media/jellyarr/config/{qbittorrent,prowlarr,radarr,sonarr,lidarr,readarr,bazarr,jellyfin,jellyseerr}
mkdir -p /mnt/breach-data
```


**Confirm no port conflicts:**

```bash
ss -tlnp | grep -E '8082|9696|7878|8989|8686|8787|6767|8096|5055|9392|5500|5501|8090|5001|8091|3333|8880|3000|6789'
```

Expected: no output. Resolve any conflict before proceeding.


**Supervisor policy — apply before any phase:**
- Replace service 3 entry: `jellyfin` → `jellyarr`
- Register services 15–25 as alpha-only, no beta/gamma until explicitly configured
- Add all new `.core` virtual hosts to DNS scope
- Flag service 23 (Evilginx3) as topology exception: dedicated node, no Nginx


**Architecture.md update — required before starting (§13):**
- §5.1: service inventory now spans 0–24; service 3 redefined as JellyArr
- Add: *"A C.O.R.E. service may consist of multiple internal containers managed under a single compose stack and a single Supervisor policy entry."*
- §5.2: add `docker compose` as the deployment mechanism for composite services
- §10: document service 23 as the first topology exception — dedicated node, external-facing trust boundary


---


## Phase 1 — Service 3: JellyArr


**Estimated time:** 1–2 hours.
**Reference:** https://github.com/automation-avenue/arr-new


### Compose Stack


Path: `/opt/core/services/3_jellyarr/docker-compose.yml`

```yaml
name: jellyarr

networks:
  jellyarr-net:
    driver: bridge

services:

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: core-jellyarr-qbittorrent
    networks: [jellyarr-net]
    ports: ["8082:8080"]
    volumes:
      - /media/jellyarr/config/qbittorrent:/config
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
      - WEBUI_PORT=8080
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: core-jellyarr-prowlarr
    networks: [jellyarr-net]
    ports: ["9696:9696"]
    volumes:
      - /media/jellyarr/config/prowlarr:/config
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: core-jellyarr-radarr
    networks: [jellyarr-net]
    ports: ["7878:7878"]
    volumes:
      - /media/jellyarr/config/radarr:/config
      - /media/jellyarr/movies:/movies
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: core-jellyarr-sonarr
    networks: [jellyarr-net]
    ports: ["8989:8989"]
    volumes:
      - /media/jellyarr/config/sonarr:/config
      - /media/jellyarr/tv:/tv
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: core-jellyarr-lidarr
    networks: [jellyarr-net]
    ports: ["8686:8686"]
    volumes:
      - /media/jellyarr/config/lidarr:/config
      - /media/jellyarr/music:/music
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  readarr:
    image: lscr.io/linuxserver/readarr:develop
    container_name: core-jellyarr-readarr
    networks: [jellyarr-net]
    ports: ["8787:8787"]
    volumes:
      - /media/jellyarr/config/readarr:/config
      - /media/jellyarr/books:/books
      - /media/jellyarr/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: core-jellyarr-bazarr
    networks: [jellyarr-net]
    ports: ["6767:6767"]
    volumes:
      - /media/jellyarr/config/bazarr:/config
      - /media/jellyarr/movies:/movies
      - /media/jellyarr/tv:/tv
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: core-jellyarr-jellyfin
    networks: [jellyarr-net]
    ports: ["8096:8096"]
    volumes:
      - /media/jellyarr/config/jellyfin:/config
      - /media/jellyarr/movies:/data/movies
      - /media/jellyarr/tv:/data/tv
      - /media/jellyarr/music:/data/music
      - /media/jellyarr/books:/data/books
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: core-jellyarr-jellyseerr
    networks: [jellyarr-net]
    ports: ["5055:5055"]
    volumes:
      - /media/jellyarr/config/jellyseerr:/app/config
    environment:
      - TZ=Europe/Brussels
    restart: unless-stopped
```


### Nginx Virtual Hosts


One block per component. Pattern — repeat for all 9 domains, adjust `server_name` and `proxy_pass` port:

```nginx
server {
    listen 443 ssl;
    server_name jellyarr.core;
    location / {
        proxy_pass http://127.0.0.1:5055;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> WebSocket headers (`Upgrade`, `Connection`) are required on `jellyarr.core` and `jellyfin.core`.
> All other *arr blocks do not require them.


### Deployment Sequence


```bash
# 1. Run Logic Check 3 — nginx must pass before stack starts
nginx -t

# 2. Start the full stack
cd /opt/core/services/3_jellyarr
docker compose up -d

# 3. Confirm all 9 containers are running
docker compose ps
```


### Internal Wiring (in this order)


**a. qBittorrent**
- Open `qbittorrent-arr.core` → change default credentials.
- Create categories: `radarr`, `sonarr`, `lidarr`, `readarr`.
- Default save path: `/downloads`.

**b. Prowlarr**
- Open `prowlarr.core` → add indexers.
- Do not connect *arr apps yet — wait until each is configured.

**c. Radarr / Sonarr / Lidarr / Readarr**
- Each: Settings → Download Clients → add qBittorrent at `http://core-jellyarr-qbittorrent:8080`.
- Each: Settings → General → copy API key.
- Return to Prowlarr → Settings → Apps → add each *arr using its internal hostname and API key.

**d. Bazarr**
- Sonarr: host `core-jellyarr-sonarr`, port `8989`, API key.
- Radarr: host `core-jellyarr-radarr`, port `7878`, API key.

**e. Jellyfin**
- First-run wizard: set admin credentials.
- Add libraries: `/data/movies`, `/data/tv`, `/data/music`, `/data/books`.

**f. Jellyseerr**
- First-run wizard → sign in with Jellyfin at `http://core-jellyarr-jellyfin:8096`.
- Add Radarr: host `core-jellyarr-radarr`, port `7878`, API key.
- Add Sonarr: host `core-jellyarr-sonarr`, port `8989`, API key.


### Validation
- [ ] `docker compose ps` — all 9 containers show `running`
- [ ] `jellyarr.core` loads Jellyseerr login (suite landing confirmed)
- [ ] `jellyfin.core` loads Jellyfin — libraries visible
- [ ] `prowlarr.core` shows all *arr apps connected (green)
- [ ] `radarr.core` shows qBittorrent connected (green)
- [ ] Manual grab test: search a movie in Radarr → appears in `qbittorrent-arr.core`
- [ ] `bazarr.core` shows Sonarr and Radarr connected
- [ ] Submit a request in Jellyseerr → appears in Radarr or Sonarr queue
- [ ] `jellyfin.core` resolves correctly — Logic Check 2 confirmed
- [ ] `curl -sk https://jellyarr.core` returns 200 or 302 — Logic Check 3 confirmed


### Rollback

```bash
docker compose down
# Volumes are preserved — data is not lost
# Fix the issue, then docker compose up -d
```


---


## Phase 2 — Security Tooling (Services 15–17)


**Estimated time:** 2–6 hours (dominated by Greenbone feed sync).


### Service 15 — Greenbone CE


Start first — feed sync runs in the background while 16 and 17 are deployed.

```bash
git clone https://github.com/greenbone/greenbone-community-edition
cd greenbone-community-edition
docker compose up -d
```

- Monitor sync: `docker compose logs -f`
- Do not run scans until Feed Status in the GSA dashboard shows a current sync date.
- Change the default `admin` password immediately after first login.
- Schedule weekly feed sync via cron — never overlap with active scans.
- Nginx virtual host: `greenbone.core` → `localhost:9392`


### Service 16 — Reconmap


```bash
git clone https://github.com/reconmap/reconmap
cd reconmap
docker compose up -d
docker exec -it reconmap-app php artisan migrate
```

- Nginx virtual host: `reconmap.core` → `localhost:5500`


### Service 17 — OWASP ZAP


```bash
docker run -d --name core-owasp-zap \
  -p 8090:8090 \
  ghcr.io/zaproxy/zaproxy:stable \
  zap.sh -daemon -host 0.0.0.0 -port 8090 \
  -config api.addrs.addr.name=.* \
  -config api.addrs.addr.regex=true \
  -config api.key=CHANGEME
```

- Nginx virtual host: `zap.core` → `localhost:8090`


### Validation
- [ ] `greenbone.core` loads — Feed Status shows current sync date
- [ ] Test scan runs against a local mesh IP and completes without errors
- [ ] `reconmap.core` loads — create a project and add a finding
- [ ] `zap.core` responds and rejects requests missing the API key


### Supervisor Policy
Assign service 15 to the highest-RAM node available — Greenbone is memory-intensive during active scans.
Services 16 and 17 have no placement constraint.


---


## Phase 3 — OSINT (Services 18–20)


**Estimated time:** 1–2 hours.


### Service 18 — SpiderFoot


```bash
docker run -d --name core-spiderfoot \
  -p 5001:5001 \
  -v spiderfoot-data:/var/lib/spiderfoot \
  ghcr.io/smicallef/spiderfoot -l 0.0.0.0:5001
```

- Nginx virtual host: `spiderfoot.core` → `localhost:5001`
- Modules requiring API keys self-disable on startup — all keyless modules run immediately.


### Service 19 — IVRE


```bash
git clone https://github.com/ivre/ivre
cd ivre
docker compose up -d

docker exec -it ivre-client ivre ipinfo --init
docker exec -it ivre-client ivre scancli --init
```

Data ingestion workflow:

```bash
# After each Nmap scan
docker exec -it ivre-client ivre nmap2db -r -s NodeScan /ivre-share/results.xml
```

- MongoDB runs on `ivre-net` only — not exposed outside the compose network.
- Nginx virtual host: `ivre.core` → `localhost:8091`


### Service 20 — Maigret


No persistent service. Run on-demand via ttyd (service 7):

```bash
docker run --rm \
  -v maigret-reports:/reports \
  ghcr.io/soxoj/maigret:latest \
  USERNAME --html -o /reports/USERNAME.html
```

- Reports land in the `maigret-reports` volume — browse via ttyd or mount into a static file server.
- No Nginx virtual host required.


### Validation
- [ ] `spiderfoot.core` loads — run a test scan on a domain you control, confirm modules complete
- [ ] `ivre.core` loads — import a test Nmap XML, confirm host appears in the recon view
- [ ] Maigret in ttyd: `maigret testusername --print-found` returns results


---


## Phase 4 — Credentials (Service 21)


**Estimated time:** 15 min deploy. Days for dataset acquisition.


### Service 21 — h8mail


```bash
docker run -d --name core-h8mail \
  -v /mnt/breach-data:/breach:ro \
  ghcr.io/khast3x/h8mail:latest \
  tail -f /dev/null
```

Operational usage via ttyd:

```bash
# Single target — local only, plaintext output
docker exec core-h8mail h8mail -t target@email.com -bc /breach/ -sk

# Batch
docker exec core-h8mail h8mail -t targets.txt -bc /breach/ -sk -o results.txt
```

- `-sk` disables all API calls — fully local, zero network dependency.
- `-bc` accepts the BreachCompilation root; h8mail walks subdirectories automatically.
- `-gz` enables search inside gzipped archives without manual extraction.
- No Nginx virtual host — CLI only via ttyd.


### Dataset Acquisition


Stage all datasets to `/mnt/breach-data/` on the alpha node:


| Dataset | Size | Records |
|---|---|---|
| BreachCompilation | ~44 GB | 1.4B — structured by email domain |
| COMB | ~100 GB | 3.2B |
| Collection #1–5 | ~87 GB | varied |


- **Total: ~230 GB minimum.** Provision on a separate disk.
- Transfer over Netbird mesh only — never over plain LAN.
- Data class: **Critical.**
- Volume is read-only inside the container — the stack must never write to breach data.


### Validation
- [ ] `docker exec core-h8mail h8mail -t known-leaked@email.com -bc /breach/ -sk` returns expected credentials
- [ ] Write test: `docker exec core-h8mail touch /breach/test` — must return `Permission denied`


---


## Phase 5 — Phishing (Services 22–24)


**Estimated time:** 1 hour for 22 and 24. Service 23 requires DNS propagation.


### ⚠️ Service 23 — Topology Constraint


Evilginx3 owns ports 80 and 443 on its node. It cannot coexist with Nginx on the same IP.

- **Option A (recommended):** dedicated node with public IP — no Nginx, not under `.core` ingress.
- **Option B:** second IP on the alpha node — bind Nginx to primary, Evilginx3 to secondary.

Deploy services 22 and 24 while DNS propagates for service 23.


### Service 22 — GoPhish


```bash
docker run -d --name core-gophish \
  -p 3333:3333 \
  -p 8880:80 \
  -v gophish-data:/opt/gophish \
  gophish/gophish
```

- Nginx virtual host: `gophish.core` → `localhost:3333` (admin panel only).
- Port 8880 is the HTTP lure listener — expose externally for campaign delivery, not via `.core`.
- Change the default admin credentials on first login.


### Service 24 — BeEF


```bash
docker run -d --name core-beef \
  -p 3000:3000 \
  -p 6789:6789 \
  -v beef-config:/beef/config \
  bcyber365/beef
```

- Edit `config.yaml` before starting: change `credentials.user` and `credentials.passwd`.
- Nginx virtual host: `beef.core` → `localhost:3000`
- Port 6789 delivers `hook.js` to victim browsers — plan external exposure accordingly.


### Service 23 — Evilginx3


**DNS pre-work:**
1. Register a throwaway domain.
2. `NS` record: `phish.yourdomain.com` → Evilginx3 node public IP.
3. `A` record: NS hostname → same public IP.
4. Verify propagation: `dig NS phish.yourdomain.com` must return the node IP.

**Deploy on dedicated node:**

```bash
docker run -d --name core-evilginx3 \
  --network host \
  -v evilginx-data:/app/data \
  ghcr.io/kgretzky/evilginx3 \
  -p /app/phishlets -c /app/data
```

**Initial CLI configuration:**
: config domain phish.yourdomain.com
: config ipv4 <node public IP>
: phishlets hostname <target> <subdomain>.phish.yourdomain.com
: phishlets enable <target>

text

TLS certificates are requested from Let's Encrypt automatically once phishlets are enabled.


### Validation
- [ ] `gophish.core` loads — create a test campaign targeting an internal mesh address
- [ ] `beef.core` loads — `http://<node>:6789/hook.js` returns JavaScript content
- [ ] Evilginx3: `phishlets` shows target as `enabled` with valid TLS cert
- [ ] Service 23 node: `systemctl status nginx` → inactive or not installed


---


## Phase 6 — Minecraft (Service 25)


**Estimated time:** 30–60 minutes for baseline setup (excluding large mod uploads).


### Scope
- Runtime target: NeoForge `1.21.1`.
- Host profile: Ubuntu server, `24 GB` RAM total with `16 GB` dedicated to Minecraft.
- Storage profile: `1 TB` total with `256 GB` dedicated to Minecraft runtime data.
- Exposure model: mesh-first via Netbird, published as `minecraft.core` for C.O.R.E peers.
- Source of truth for mod and config payload: `modpack.md`.


### Required Service Structure (Repository)
- `src/25_Minecraft/run.sh`
- `src/25_Minecraft/setup.sh`
- `src/25_Minecraft/eula.txt`
- `src/25_Minecraft/server.properties`
- `src/25_Minecraft/mods/` (125 JARs)
- `src/25_Minecraft/config/` (full exported config set)
- `src/25_Minecraft/defaultconfigs/` (fresh-world defaults)


### Validation
- [ ] `./run.sh` launches NeoForge server with `-Xmx16G` and stable tick progression.
- [ ] `eula.txt` contains `eula=true` before first production start.
- [ ] `server.properties` enforces `view-distance=8` and `simulation-distance=6`.
- [ ] `mods/` and `config/` payloads match the current `modpack.md` baseline.
- [ ] Netbird peers can resolve and connect to `minecraft.core:25565`.


---


## Post-Deployment Supervisor Policy


### Collocated Groups and Placement


| Group | Services | Constraint |
|---|---|---|
| JellyArr suite | 3 (all internal containers) | All on same alpha — shared volume mounts |
| Evilginx3 | 23 | Dedicated alpha — no Nginx on that node |
| Greenbone | 15 | Assign to highest-RAM node |
| All others | 16–22, 24, 25 | No placement constraint |


### Backup Priority and Pre-backup Hooks


| Priority | Services | Pre-backup hook |
|---|---|---|
| Critical | 3, 15, 16, 22 | Stop → rsync → start |
| Critical (read-only source) | 21 | No rsync — preserve source dataset independently |
| High | 18, 19 | `mongodump` for IVRE; volume rsync for SpiderFoot |
| Recoverable | 17, 20, 24 | No hook needed |


**Service 3 backup hook pattern:**

```bash
docker compose -f /opt/core/services/3_jellyarr/docker-compose.yml stop
rsync -a /media/jellyarr/ <beta-node>:/media/jellyarr/
docker compose -f /opt/core/services/3_jellyarr/docker-compose.yml start
```


### Architecture.md — Required Updates (§13)


Both changes alter core definitions and require explicit spec update before this rollout is closed:

1. **§5.1:** Update service inventory to 0–24. Add: *"A C.O.R.E. service may consist of multiple internal containers managed under a single compose stack and a single Supervisor policy entry."*
2. **§5.2:** Add `docker compose` as the deployment mechanism for composite services.
3. **§10:** Add service 23 (Evilginx3) as a named topology exception: dedicated node, no Nginx, external-facing trust boundary distinct from the `.core` mesh surface.