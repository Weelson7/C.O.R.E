# C.O.R.E Minecraft

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A heavily modded Minecraft Java server running NeoForge `1.21.1`.
- What it does: Hosts a persistent multiplayer world with a curated modpack baseline defined in `modpack.md`.
- Why this service exists in C.O.R.E: It adds a game workload to the numbered services while keeping deployment and exposure mesh-scoped through Netbird.

## Commands
- Setup host/runtime: `cd src/25_Minecraft && ./setup.sh`
- Start server: `cd src/25_Minecraft && ./run.sh`
- Stop server: `pkill -f 'neoforge-21.1.228-server.jar'`
- Status: `pgrep -af 'neoforge-21.1.228-server.jar'` and `ss -lntp | grep 25565`
- Logs: `tail -f src/25_Minecraft/logs/latest.log`
- Edit/Reload: update `server.properties` or configs, then restart with `./run.sh`

## Runtime parameters
- Node(s): Supervisor-assigned alpha node on Ubuntu with 24 GB RAM and 1 TB disk, reserving 16 GB RAM and 256 GB storage for Minecraft service data.
- Domain: `minecraft.core` (Netbird mesh DNS target).
- Port(s): Minecraft TCP `25565`.
- Volumes/Data path:
  - Service root: `src/25_Minecraft`
  - Mods payload: `src/25_Minecraft/mods` (target: 125 server-safe JARs)
  - Config payload: `src/25_Minecraft/config` (full exported server config)
  - World defaults: `src/25_Minecraft/defaultconfigs`
- Environment/config tweaks:
  - Java heap: `-Xms8G -Xmx16G` in `run.sh`
  - `server.properties`: `view-distance=8`, `simulation-distance=6`
  - `ferritecore.toml`: `enable_all=true`
  - `modernfix.toml`: `performance=true`
- Security constraints:
  - Mesh-first exposure model through Netbird.
  - Keep only server-compatible mods in `mods/`; client-only mods stay off the server.
  - Do not expose management interfaces outside C.O.R.E policy.

## Deployment sequence
1. Run `setup.sh` to validate Ubuntu host prerequisites, install Java runtime, and prepare service layout.
2. Place NeoForge server jar `neoforge-21.1.228-server.jar` in `src/25_Minecraft`.
3. Copy validated modpack payload from `modpack.md` baseline:
   - Upload all server JARs into `mods/`.
   - Zip and extract your complete `/config/` into `config/`.
   - Copy known-good defaults into `defaultconfigs/` for new world generation.
4. Confirm `eula.txt` is set to `eula=true` and `server.properties` has the requested distances.
5. Start the service using `./run.sh` and verify the Java process binds TCP `25565`.
6. Configure DNS rewrite and policy so `minecraft.core` resolves to the selected Netbird node IP.
7. Validation checks:
   - `java -version` reports Java 21 runtime.
   - `pgrep -af 'neoforge-21.1.228-server.jar'` returns a live process.
   - `ss -lntp | grep 25565` shows listening state.
   - From a mesh peer, connect to `minecraft.core:25565`.
8. Failure handling notes:
   - Out-of-memory during startup: reduce mod set or lower startup concurrency, keep `-Xmx16G` fixed to dedicated budget.
   - Crash during mod loading: inspect `logs/latest.log`, remove incompatible or client-only mods, restart.
   - DNS/connectivity issue: verify Netbird status, mesh ACLs, and rewrite target for `minecraft.core`.

## Files
- `src/25_Minecraft/run.sh`: Production JVM launch script for NeoForge `1.21.1` with fixed G1GC tuning and 16 GB max heap.
- `src/25_Minecraft/setup.sh`: Ubuntu setup and validation script for Java runtime, service directory layout, and baseline checks.
- `src/25_Minecraft/eula.txt`: Mojang EULA acknowledgement file.
- `src/25_Minecraft/server.properties`: baseline render/simulation settings for performance.
- `modpack.md`: canonical mod and compatibility source used when populating `mods/` and `config/`.
