# C.O.R.E. Services 15–31 Implementation Plan

## Table of Contents
- [Pre-Deployment Checklist](#pre-deployment-checklist)
- [Phase 1 — *arr Suite + Jellyseerr](#phase-1--arr-suite--jellyseerr-services-1521)
- [Phase 2 — Security Tooling](#phase-2--security-tooling-services-2224)
- [Phase 3 — OSINT](#phase-3--osint-services-2527)
- [Phase 4 — Credentials](#phase-4--credentials-service-28)
- [Phase 5 — Phishing](#phase-5--phishing-services-2931)
- [Post-Deployment Supervisor Policy](#post-deployment-supervisor-policy)


---


## Pre-Deployment Checklist

**Storage — provision before any phase:**
- `/media/{movies,tv,music,books}` — shared with services 3 and 8
- `/downloads` — shared with service 8
- `/mnt/breach-data` — dedicated volume, ≥ 200 GB, separate disk

**Port reservation:**

| # | Service | Host Port |
|---|---|---|
| 15 | Prowlarr | 9696 |
| 16 | Radarr | 7878 |
| 17 | Sonarr | 8989 |
| 18 | Lidarr | 8686 |
| 19 | Readarr | 8787 |
| 20 | Bazarr | 6767 |
| 21 | Jellyseerr | 5055 |
| 22 | Greenbone GSA | 9392 |
| 23 | Reconmap | 5500 + 5501 |
| 24 | OWASP ZAP | 8090 |
| 25 | SpiderFoot | 5001 |
| 26 | IVRE web | 8091 |
| 27 | Maigret | CLI only |
| 28 | h8mail | CLI only |
| 29 | GoPhish admin | 3333 |
| 29 | GoPhish listener | 8880 |
| 30 | Evilginx3 | 80 + 443 (dedicated node) |
| 31 | BeEF panel | 3000 |
| 31 | BeEF hook | 6789 |

**Supervisor policy — apply before starting:**
- Register services 15–31 as alpha-only, no beta/gamma until explicitly configured.
- Add all new `.core` virtual hosts to DNS and Nginx provisioning scope.
- Flag service 30 (Evilginx3) as a topology exception: dedicated alpha, no Nginx on that node.


---


## Phase 1 — *arr Suite + Jellyseerr (Services 15–21)

**Estimated time:** 1–2 hours.

### Deployment Order

Deploy in this exact sequence — later services depend on earlier ones being API-accessible.

**1. Prowlarr (15)**

```bash
docker run -d --name core-prowlarr \
  -p 9696:9696 \
  -v prowlarr-config:/config \
  lscr.io/linuxserver/prowlarr:latest
```

- After deploy: add indexers in the Prowlarr UI.
- Sync will push to Radarr/Sonarr/Lidarr/Readarr once those are up.

**2. Radarr, Sonarr, Lidarr, Readarr (16–19) — deploy in parallel**

Same pattern for all four, adjust image and port per service:

```bash
docker run -d --name core-radarr \
  -p 7878:7878 \
  -v radarr-config:/config \
  -v /media/movies:/movies \
  -v /downloads:/downloads \
  lscr.io/linuxserver/radarr:latest
```

- Wire `/downloads` to the same path as qBittorrent (service 8).
- Wire `/movies`, `/tv`, `/music`, `/books` to the same paths as Jellyfin (service 3).
- After deploy: add qBittorrent as download client using `qbittorrent.core`, then connect Prowlarr sync.

**3. Bazarr (20)**

```bash
docker run -d --name core-bazarr \
  -p 6767:6767 \
  -v bazarr-config:/config \
  -v /media/movies:/movies \
  -v /media/tv:/tv \
  lscr.io/linuxserver/bazarr:latest
```

- After deploy: connect Sonarr at `sonarr.core` and Radarr at `radarr.core` with their API keys.

**4. Jellyseerr (21)**

```bash
docker run -d --name core-jellyseerr \
  -p 5055:5055 \
  -v jellyseerr-config:/app/config \
  fallenbagel/jellyseerr:latest
```

- First-run wizard: authenticate via Jellyfin, then add Radarr and Sonarr as media servers.
- Jellyseerr does not manage Lidarr or Readarr — those remain *arr-direct workflows.

### Nginx Virtual Hosts

```nginx
# Repeat pattern for all *arr and Jellyseerr
server {
    listen 443 ssl;
    server_name prowlarr.core;
    location / {
        proxy_pass http://127.0.0.1:9696;
        proxy_set_header Host $host;
    }
}
```

### Validation
- [ ] `prowlarr.core` shows indexers synced to all four *arr apps
- [ ] Radarr shows qBittorrent connected (green) and Prowlarr indexed
- [ ] Manual grab test: search a movie in Radarr → confirm it appears in qBittorrent
- [ ] `bazarr.core` shows Sonarr and Radarr connected
- [ ] `jellyseerr.core` — submit a movie request and confirm it appears in Radarr

### Supervisor Policy
Services 15–21 are a **collocated group** — assign all to the same alpha node as Jellyfin (3) and qBittorrent (8). Volume sharing makes cross-node placement impractical without a network filesystem.


---


## Phase 2 — Security Tooling (Services 22–24)

**Estimated time:** 2–6 hours (dominated by Greenbone feed sync).

### Deployment Order

**1. Greenbone CE (22) — start first, sync in background**

```bash
git clone https://github.com/greenbone/openvas-smb
cd openvas-smb
docker compose -f docker-compose.yml up -d
```

Use the official `greenbone-community-edition` compose file from the Greenbone GitHub.

- Initial NVT/CVE feed sync takes from minutes to hours depending on connection and CPU.
- Monitor with: `docker compose logs -f`
- Do not run scans until sync completes.
- Change the default `admin` password immediately after first login.
- Schedule weekly feed sync via cron — never during active scans.

**2. OWASP ZAP (24)**

```bash
docker run -d --name core-owasp-zap \
  -p 8090:8090 \
  ghcr.io/zaproxy/zaproxy:stable \
  zap.sh -daemon -host 0.0.0.0 -port 8090 \
  -config api.addrs.addr.name=.* \
  -config api.addrs.addr.regex=true \
  -config api.key=CHANGEME
```

- Nginx virtual host: `zap.core` → `localhost:8090`.
- Enforce HTTP auth at Nginx — ZAP has no native auth layer.

**3. Reconmap (23)**

```bash
git clone https://github.com/reconmap/reconmap
cd reconmap
docker compose up -d
```

- Reconmap ships app + MySQL + Minion worker in one compose stack.
- After first deploy, run DB migration:

```bash
docker exec -it reconmap-app php artisan migrate
```

- Nginx virtual host: `reconmap.core` → `localhost:5500`.

### Validation
- [ ] `greenbone.core` loads GSA dashboard — Feed Status shows recent sync date
- [ ] Create a test scan against a local mesh IP and confirm it runs
- [ ] `zap.core` responds and rejects requests without API key
- [ ] `reconmap.core` loads — create a test project and add a finding

### Supervisor Policy
Greenbone is RAM-heavy during scans. Assign to the node with the most available RAM. Reconmap and ZAP can share alpha with other services.


---


## Phase 3 — OSINT (Services 25–27)

**Estimated time:** 1–2 hours.

### Deployment Order

**1. SpiderFoot (25)**

```bash
docker run -d --name core-spiderfoot \
  -p 5001:5001 \
  -v spiderfoot-data:/var/lib/spiderfoot \
  ghcr.io/smicallef/spiderfoot -l 0.0.0.0:5001
```

- Nginx virtual host: `spiderfoot.core` → `localhost:5001`.
- SpiderFoot has **no native auth** — enforce HTTP auth at Nginx boundary.
- Modules requiring API keys self-disable; all others run immediately.

**2. IVRE (26)**

IVRE requires a MongoDB backend. Use the official compose stack:

```bash
git clone https://github.com/ivre/ivre
cd ivre
docker compose up -d
```

Services: `ivre/db` (MongoDB, internal only), `ivre/web` (UI on 8091), `ivre/client` (on-demand import).

Initialize the database after first deploy:

```bash
docker exec -it ivre-client ivre ipinfo --init
docker exec -it ivre-client ivre scancli --init
```

Data ingestion workflow:

```bash
# Run Nmap scan and export XML
nmap -oX results.xml <target>

# Copy into shared volume and import
docker exec -it ivre-client ivre nmap2db -r -s NodeScan /ivre-share/results.xml
```

- Nginx virtual host: `ivre.core` → `localhost:8091`.

**3. Maigret (27) — no persistent service**

Install as on-demand container via ttyd (service 7):

```bash
docker run --rm \
  -v maigret-reports:/reports \
  ghcr.io/soxoj/maigret:latest \
  USERNAME --html -o /reports/USERNAME.html
```

- Access reports by mounting `maigret-reports` into a static file server, or browse via ttyd.
- No Nginx virtual host required.

### Validation
- [ ] `spiderfoot.core` loads — run a test scan on a domain you control, confirm modules complete
- [ ] `ivre.core` loads — import a test Nmap XML and confirm host appears in the recon view
- [ ] Maigret in ttyd: `maigret testusername --print-found` returns results


---


## Phase 4 — Credentials (Service 28)

**Estimated time:** 15 min deploy. Days for dataset acquisition.

### Deployment

```bash
docker run -d --name core-h8mail \
  -v /mnt/breach-data:/breach:ro \
  ghcr.io/khast3x/h8mail:latest \
  tail -f /dev/null
```

Operational usage via ttyd:

```bash
# Single target, local only, plaintext output
docker exec core-h8mail h8mail -t target@email.com -bc /breach/ -sk

# Batch targets
docker exec core-h8mail h8mail -t targets.txt -bc /breach/ -sk -o results.txt
```

- `-sk` disables all API calls — local-only mode.
- `-bc` accepts the root of the BreachCompilation directory; h8mail walks it automatically.
- `-gz` enables search inside gzipped collections without manual extraction.

### Dataset Acquisition

Download and stage to `/mnt/breach-data/` on the alpha node:

| Dataset | Size | Coverage |
|---|---|---|
| BreachCompilation | ~44 GB | 1.4B credentials, structured by domain |
| COMB | ~100 GB | 3.2B credentials |
| Collection #1–5 | ~87 GB | varied breach sources |

- **Total: ~230 GB minimum.**
- Transfer over mesh only (Netbird) — never over plain LAN.
- Treat as **Critical** data class in Supervisor backup policy.
- Volume is mounted read-only into the container.

### Validation
- [ ] `docker exec core-h8mail h8mail -t known-leaked@email.com -bc /breach/ -sk` returns expected credentials
- [ ] Confirm volume is read-only: write attempt inside container must fail


---


## Phase 5 — Phishing (Services 29–31)

**Estimated time:** 1 hour for GoPhish and BeEF. Evilginx3 requires DNS pre-work.

### ⚠️ Evilginx3 Topology Constraint

Evilginx3 is its own reverse proxy and must own ports 80 and 443 on its node. It cannot coexist with Nginx on the same IP.

**Options:**
- **Option A (recommended):** Assign to a dedicated node with a public IP — no Nginx on that node, not under `.core` ingress.
- **Option B:** Assign a second IP on the alpha node — bind Nginx to the primary IP, Evilginx3 to the secondary.

Deploy GoPhish and BeEF first while DNS is being prepared for Evilginx3.

**1. GoPhish (29)**

```bash
docker run -d --name core-gophish \
  -p 3333:3333 \
  -p 8880:80 \
  -v gophish-data:/opt/gophish \
  gophish/gophish
```

- Nginx virtual host: `gophish.core` → `localhost:3333` (admin UI only).
- Port 8880 is the HTTP lure listener — expose externally for campaign delivery, not via `.core`.
- Change the default admin password on first login — GoPhish has no other auth.

**2. BeEF (31)**

```bash
docker run -d --name core-beef \
  -p 3000:3000 \
  -p 6789:6789 \
  -v beef-config:/beef/config \
  bcyber365/beef
```

- Nginx virtual host: `beef.core` → `localhost:3000`.
- Port 6789 delivers `hook.js` to victim browsers — plan external exposure accordingly.
- Edit `/beef/config/config.yaml` before starting: change `credentials.user` and `credentials.passwd`.

**3. Evilginx3 (30) — requires DNS pre-work first**

Pre-work:
1. Register a throwaway domain.
2. Create an `NS` record pointing `phish.yourdomain.com` to the Evilginx3 node's public IP — Evilginx3 acts as its own nameserver.
3. Create an `A` record for the NS hostname pointing to the same IP.
4. Wait for DNS propagation before deploying.

Deploy on the dedicated node:

```bash
docker run -d --name core-evilginx3 \
  --network host \
  -v evilginx-data:/app/data \
  ghcr.io/kgretzky/evilginx3 \
  -p /app/phishlets -c /app/data
```

Initial configuration inside the Evilginx3 CLI:
