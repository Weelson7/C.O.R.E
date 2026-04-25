# 🧩 Custom Modpack — NeoForge 1.21.1
> **Server:** Ubuntu, 24 GB RAM (16 GB dedicated) | 1 TB storage (256 GB dedicated)  
> **Mod Loader:** NeoForge 1.21.1  
> **Total Mods:** 130

---

## 🎨 Recommended Shader Packs (Client-Side Only)

| Tier | Shader | Notes |
|------|--------|-------|
| 🌟 High Quality | **Complementary Reimagined** (+ optional Euphoria Patches) | Full Distant Horizons support via Iris, stunning lighting, colored shadows, SSAO. Best DH transition blending. |
| ⚡ Performance | **BSL Shaders** (v8.2.09p1+) | Lightweight, solid DH compatibility, great default look with lower GPU overhead. |

> Both packs must be installed as `.zip` files into the client's `shaderpacks/` folder and loaded via **Iris Shaders** (already in the modpack).  
> ⚠️ Shader packs require **Iris v1.8.0+** and **Sodium v0.6.0+** and **Distant Horizons v2.1.0+** — confirm these version constraints before shipping.

---

## 📚 Libraries & APIs

| Mod | Side | Notes |
|-----|------|-------|
| Architectury API | Both | Cross-loader abstraction layer |
| Atlas API | Both | — |
| Biolith | Both | — |
| Caelus API | Both | Elytra slot abstraction |
| Cloth Config API | Both | Config screen API |
| Cristel Lib | Both | — |
| Curios API | Both | Accessory slots framework |
| Framework | Both | — |
| FTB Library | Both | FTB mod base library |
| GeckoLib | Both | Animation library |
| GlitchCore | Both | — |
| GTBC's SpellLib/API | Both | Required for GTBC Geomancy Plus |
| Iron's Lib | Both | Required for Iron's mods |
| Lithostitched | Both | — |
| Lodestone | Both | — |
| Modonomicon | Both | In-game guidebook framework |
| Placebo | Both | Forge utility library |
| Puzzles Lib | Both | — |
| Resourceful Config | Both | — |
| Resourceful Lib | Both | — |
| Ritchie's Projectile Library | Both | Projectile system |
| Sable | Both | — |
| ShatterLib / OctoLib | Both | — |
| SmartBrainLib | Both | AI brain library for mobs |
| YUNG's API | Both | Required for all YUNG's mods |
| Ace's Spell Utils | Both | Spell utility library |
| Apothic Attributes | Both | Attribute system extension |
| Balm | Both | Multi-loader abstraction |
| Citadel | Both | Required for Alex's Mobs / Ice and Fire |
| Jupiter | Both | Utility library |
| TerraBlender (NeoForge) | Both | Biome blending API — required for BoP, Terralith, Regions Unexplored |
| Uranus | Both | Utility library |
| Cupboard | Both | Required for Let's Do: Vinery |

---

## ⚡ Performance & Utilities

### Server-Side
| Mod | Side | Notes |
|-----|------|-------|
| Almost Unified | Server | Unifies duplicate resources from multiple mods |
| Clumps | Server | Merges XP orbs to reduce lag |
| Connectivity | Server | Reduces connection timeouts |
| FerriteCore | Both | Reduces RAM usage via memory optimization |
| FTB Essentials | Server | Player commands (home, back, etc.) |
| ModernFix | Both | Startup time + memory improvements |
| NoisiumForked | Server | Faster world gen noise calculations |
| Saturn | Both | Memory allocation optimizations |
| Smooth Chunk Save | Server | Async chunk saving to reduce I/O lag |

### Client-Side Only ⚠️
> These must be marked **client-only** in your modpack manifest. Do NOT load them on the server.

| Mod | Notes |
|-----|-------|
| Distant Horizons | LOD chunk rendering — client only |
| EntityCulling | Hides entities behind walls — client only |
| ImmediatelyFast | Render batching optimization — client only |
| Iris Shaders | Shader loader — client only |
| Sodium | Rendering engine replacement — client only |
| playerAnimator | Player animation library — primarily client |

---

## 🌍 World Generation

| Mod | Notes |
|-----|-------|
| Biomes O' Plenty | Additional biomes — uses TerraBlender |
| Explorify | Extra vanilla-style structures and biome tweaks |
| Geophilic | Vanilla biome enhancement |
| Regions Unexplored | Large biome expansion — uses TerraBlender |
| Repurposed Structures | Adds variants of vanilla structures |
| Tectonic | Terrain height and shape overhaul |
| Terralith | Terrain + biome overhaul — uses TerraBlender |
| Waystones | Fast travel waypoints |

---

## 🏰 Structures & Dungeons

| Mod | Notes |
|-----|-------|
| Dungeons and Taverns | Underground dungeons and inns |
| Explorify | (also listed in World Gen) |
| Towns and Towers | Expanded villages and outposts |
| When Dungeon Arise — Forge! | Large custom dungeons |
| YUNG's Better Dungeons | Revamped vanilla dungeons |
| YUNG's Better Mineshafts | Revamped mineshafts |
| YUNG's Better Nether Fortresses | Revamped Nether Fortresses |
| YUNG's Better Ocean Monuments | Revamped Ocean Monuments |
| YUNG's Better Strongholds | Revamped Strongholds |

---

## 🎁 Loot Integrations

| Mod | Notes |
|-----|-------|
| Loot Integrations | Core loot injection framework |
| Loot Integrations: Dungeons and Taverns | Addon |
| Loot Integrations: Ice and Fire | Addon |
| Loot Integrations: Towns and Towers | Addon |
| Loot Integrations: When Dungeon Arise & Co | Addon |
| YUNG Structure Addon for Loot Integrations | Addon for YUNG's structures |

---

## 🐉 Mobs & Creatures

| Mod | Notes |
|-----|-------|
| Alex's Mobs Unofficial Port | Large variety of new animals and monsters |
| Creeper Overhaul | Biome-specific creeper variants |
| Goblin Traders | Goblin merchant NPCs |
| Guard Villagers | Villager guards |
| Ice and Fire Community Edition | Community-maintained Ice and Fire (dragons, etc.) |
| Illager Invasion | Enhanced illager events |
| Mowzie's Mobs | High-quality custom boss mobs |

---

## ✨ Magic & Spells

| Mod | Notes |
|-----|-------|
| Ars Creo | Ars Nouveau × Create integration |
| Ars Elemental | Ars Nouveau addon — new elements |
| Ars Nouveau | Core magic mod |
| Ars Occultas | Ars Nouveau addon |
| Ars 'n Spells | Ars Nouveau × Iron's Spells compat |
| GTBC Geomancy Plus | Geomancy spell system |
| Ice and Fire: Spellbooks | Iron's Spellbooks × Ice and Fire compat |
| Iron's Spells 'n Spellbooks | Spell book RPG magic system |
| Malum | Dark magic / ritual mod |
| Occultism | Occult rituals, demons, storage |
| Reliquified Ars Nouveau | ⚠️ See Compatibility Notes |

---

## ⚔️ Combat & RPG

| Mod | Notes |
|-----|-------|
| Artifacts | Equipment with unique abilities |
| Better Combat | Weapon combo system |
| Brutal Bosses | Random boss spawning |
| Champions Unofficial | Elite mobs with modifiers |
| Codex of Champions | Champions documentation/guidebook |
| Elytra Slot | Dedicated elytra curio slot |
| Charm of Undying | Totem in curio slot |
| Ice and Fire Dragons × Better Combat | Compat addon |
| Iron's Gems 'n Jewelry | Gem and jewelry RPG items |
| Relics | Powerful relic items |
| Reliquified Artifacts | ⚠️ See Compatibility Notes |
| Spartan Weaponry Unofficial | Large variety of weapons |

---

## ⚙️ Create Ecosystem

| Mod | Notes |
|-----|-------|
| Create | Core Create mod |
| Cable Facades | Aesthetic cable covers |
| CBC Enhanced Shells | Addon for Create Big Cannons |
| Create Aeronautics | Airships and flying contraptions |
| Create Aeronautics: Burner Fuel | Addon |
| Create Aeronautics: Compatibility | Addon |
| Create Aeronautics: Covers | Addon |
| Create Aeronautics: Portable Engine Liquid | Addon |
| Create Big Cannons | Artillery cannons |
| Create: Bits 'n Bobs | Create Structures |
| Create: Better Create | QoL tweaks for Create |
| Create: Create O' Plenty | BoP integration for Create |
| Create Deco | Decorative Create blocks |
| Create: Easy Structures| Create structures|
| Create: Enchantment Industry | Enchantment automation via Create |
| Create: Garnished | Food automation compat |
| Create Goggles (Create Plus) | Create engineer goggles |
| Create: Hypertubes | Fast-travel tubes |
| Create Nuclear | Nuclear reactors |
| Create: Oxidized | Rust/oxidation blocks |
| Create: Renewables | Renewable energy sources |
| Create: Structures | Pre-built Create structures in world |
| Delightful Creators [Forge] | Farmer's Delight × Create compat |
| Steam 'n' Rails NeoForge | Trains and rails |
| Ycurrency | Economy/currency system |

---

## 🍖 Food & Farming

| Mod | Notes |
|-----|-------|
| Aquaculture 2 | Expanded fishing |
| Aquaculture Delight | Farmer's Delight × Aquaculture compat |
| Alex's Delight | Farmer's Delight × Alex's Mobs compat |
| Brewin' And Chewin' | Brewing and snack foods |
| Farmer's Delight | Expanded cooking and farming |

---

## 🏡 Decoration & Lifestyle

| Mod | Notes |
|-----|-------|
| [Let's Do] Vinery | Wine-making, vineyards, and decorations |

---

## 🗺️ UI & Quality of Life

| Mod | Notes |
|-----|-------|
| JEI (Just Enough Items) | Recipe viewer |
| Waystones | (also listed under World Gen) |

---

## 🛠️ Server Config Tweaks

### `server.properties`
```properties
# Reduce view distance — DH handles LODs client-side
view-distance=8
simulation-distance=6

# With this many mobs mods, keep spawn caps reasonable
max-tick-time=60000

# Required for Create contraptions and Aeronautics
sync-chunk-writes=false
```

### JVM Launch Flags (for 16 GB dedicated heap)
```bash
java -Xms8G -Xmx16G   -XX:+UseG1GC   -XX:+ParallelRefProcEnabled   -XX:MaxGCPauseMillis=200   -XX:+UnlockExperimentalVMOptions   -XX:+DisableExplicitGC   -XX:+AlwaysPreTouch   -XX:G1NewSizePercent=30   -XX:G1MaxNewSizePercent=40   -XX:G1HeapRegionSize=8M   -XX:G1ReservePercent=20   -XX:G1HeapWastePercent=5   -XX:G1MixedGCCountTarget=4   -XX:InitiatingHeapOccupancyPercent=15   -XX:G1MixedGCLiveThresholdPercent=90   -XX:G1RSetUpdatingPauseTimePercent=5   -XX:SurvivorRatio=32   -XX:+PerfDisableSharedMem   -XX:MaxTenuringThreshold=1   -Dusing.aikars.flags=https://mcflags.emc.gs   -jar server.jar nogui
```

### `config/ferrite-core.toml` (FerriteCore)
```toml
replaceNeighborLookup = true
replacePropertyMap = true
```

### `config/modernfix-common.toml` (ModernFix)
```toml
[fixes]
  [fixes.bugfix]
    enable_all = true
  [fixes.performance]
    enable_all = true
    # Disable if causing issues with mods that do early class loading
    [fixes.performance.dynamic_resources]
      enabled = true
```

### `config/clumps.cfg` (Clumps)
```toml
# Increase max XP merge radius with many mobs
xpOrbMaxValue = 2500
```

### `config/smoothchunk.json`
```json
{
  "chunkSaveDelay": 420
}
```

### `config/create-server.toml` (Create)
```toml
# Reduce contraption stress on server tick time
[kinetics.contraptions]
maxBlocksMoved = 1024
```

### `config/iceandfire/iaf-common.json`
```json
{
  "generateDragonSkeletons": true,
  "generateDragonRoosts": true,
  "generateDragonCaves": true
}
```

### `config/alexsmobs-common.toml`
```toml
# Keep rare/high-load spawns in check
gorillaSpawnWeight = 18
crimsonMosquitoSpawnWeight = 10
```

### `config/mowziesmobs-common.toml`
```toml
# Lower helper count and burst damage pressure
[tools_and_abilities]
supernova_cost = 80

[tools_and_abilities.sol_visage]
max_followers = 6
```

### `config/terrablender.toml`
```toml
# Adjust biome region sizes for server perf
overworld_region_size = 4
```

### `config/waystones-common.toml`
```toml
# Reduce wild generation density and keep inventory-button cooldown
chunksBetweenWildWaystones = 40
```

### `config/ars_nouveau-server.toml` (Ars Nouveau)
```toml
[mana]
baseRegen = 5
baseMax = 100
```

### `config/occultism-server.toml` (Occultism)
```toml
# Limit ritual costs to prevent server-side abuse
[rituals]
  maxActiveRituals = 5
```

---

## 📦 Storage Estimate

| Category | Estimated Size |
|----------|---------------|
| Server JARs + mods | ~2–3 GB |
| World data (early game, ~20h) | ~5–10 GB |
| World data (mature server) | ~30–80 GB |
| DH LOD cache (client only) | N/A server |
| Backups (recommended 3×) | ~30–50 GB |
| **Total headroom in 256 GB** | ✅ Comfortable for months |

