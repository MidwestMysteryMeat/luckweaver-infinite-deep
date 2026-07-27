# Luckweaver: Infinite Deep

D&D meets Minecraft: a 1–4 player co-op voxel dungeon crawler with turn-based d20 combat
(luck bends every roll), biomes (caverns, flooded lakes, molten depths), swimming with
oxygen, flowing fluids, real block lighting, farming, cooking, camps, blacksmithing,
enchanting, use-leveled skills with allocatable points, doors and locks — and the whole
dungeon is destructible. Built in **Godot 4.3+**, pure GDScript, zero external assets.
See `GDD.md` for the full design.

## Run It (solo / LAN — no Steam needed)

1. Install [Godot 4.3 or newer](https://godotengine.org/download) (standard build).
2. Open this folder in Godot (Import → select `project.godot`).
3. Press **F5**. Pick a class, hit **Solo Run** — you're in the town hub; take the portal down.

### LAN multiplayer test (two instances on one PC)
- Instance 1: **Host LAN** → lobby → Start Run.
- Instance 2: **Join LAN**, address `127.0.0.1` → host starts when everyone's in.
- In the editor: Debug menu → *Run Multiple Instances* → 2 makes this one click.

## Steam Multiplayer Setup

The project is Steam-ready but ships without the binary addon (it's platform-specific).
Steam is **optional at runtime** — the code detects it and falls back to LAN/solo cleanly.

1. Download **GodotSteam GDExtension** matching your Godot version:
   https://github.com/GodotSteam/GodotSteam/releases (the *GDExtension* zip)
   and **GodotSteam MultiplayerPeer**:
   https://github.com/GodotSteam/MultiplayerPeer/releases
2. Extract both into `addons/` so you have `addons/godotsteam/...` — follow each zip's layout.
3. Restart the editor. The main menu will now show *Steam: online as <persona>* and enable
   **Host Steam / Join Steam** (friends list + lobby ID join).
4. `steam_appid.txt` contains `480` (Valve's Spacewar test app) — Steam must be running.
   For release, replace 480 with your real App ID here and in `autoload/steam_mgr.gd`.

### Shipping on Steam
- Export a Windows/Linux build (Project → Export). Include `steam_appid.txt` only in dev
  builds; retail launches through Steam get the ID from the client.
- Lobbies use Steam relay networking (no port forwarding for players).
- Set launch options in Steamworks to the exported binary; that's the whole integration.

## Controls

| Key | Action | Key | Action |
|---|---|---|---|
| WASD / Space / Shift | Move / jump (swim up) / sprint | E | Interact: fight/hunt/talk, benches, doors, campfires, portal, chests |
| LMB (hold) | Mine block | RMB | Place block/door/seeds/campfire · use potion · cast spell |
| 1–9, wheel | Hotbar | Tab | Inventory |
| K | Disciplines (skill levels + point allocation) | T | Chat |
| F5 | Quicksave (host) | Esc | Pause / release mouse |

## Architecture (for reviewers & contributors)

- **Autoload order matters** (`project.godot`): `Events` (signal bus) → `Db` (static data) →
  `SteamMgr` → `Net` (peer setup) → `Game` (authoritative session brain, all gameplay RPCs) →
  `SaveMgr`.
- **Netcode:** server-authoritative. Clients send `request_*` RPCs; the host validates against
  its own copy of inventories/positions and broadcasts results. Player movement is
  owner-authoritative (positions only). World state replicates as *seed + edit log*, replayed
  deterministically — late joiners and save files use the same path.
- **Voxels:** `voxel/voxel_world.gd` owns a 96×40×96 `PackedByteArray`, meshed per 16³ chunk by
  `voxel/mesher.gd` (face culling, baked directional shading into vertex colors, unshaded
  material, trimesh collision). Edits are small op dicts (`set`, `sphere`, `sphere_replace`,
  `line`, `column`, `box`) — JSON-safe by construction.
- **Combat:** `combat/encounter.gd` is a pure server-side turn-based d20 state machine
  (initiative, attack vs AC, crits/fumbles, luck advantage, enemy specials, NPC parley,
  boss phases). The client renders whatever state dict it's sent and returns action IDs —
  game logic never runs on clients. Enemy stats are built at spawn in
  `game.gd/_server_spawn_enemy` (floor curve × adaptive threat × elite rolls).
- **Fluids & light:** `voxel/voxel_world.gd` — Minecraft-style flow (levels, retraction,
  lava+water=obsidian+steam, acid dissolve) stepped by `{"t":"fluid"}` ops in the replicated
  edit log (deterministic on every peer), and block-light BFS (glow 15, decay 1/block) baked
  into vertex colors with localized repair after each edit.
- **Farming/cooking/camps:** crops random-tick server-side and need light ≥ 8
  (`game.gd/_server_tick_crops`); campfires are respawn points with a heal aura; cooking
  (`crafting/cooking.gd`) feeds a shared feast to everyone near the fire, with rare
  permanent boosts.
- **Crafting:** `crafting/spell_forge.gd` (rune+card+essence → spell meta), `alchemy.gd`
  (shared-property brewing), `skill_forge.gd` (passive merging). `effect_exec.gd` turns
  spell/potion metas into world ops, buffs, and damage — server side.
- **Saves:** `autoload/save_mgr.gd`, JSON at `user://saves/`. Town hub (floor 0) edit log is
  persistent across runs.

## Automated tests (headless, no display needed)

```powershell
# Full solo gameplay loop: mine → craft → cast → brew → merge → descend → gamble → save
godot --headless --path . res://tests/smoke.tscn        # prints SMOKE PASS, exit 0

# Real two-process ENet co-op: join, spawn barrier, replicated edits, chat
# (start the host, wait ~5s, start the client in a second terminal)
godot --headless --path . res://tests/mp_host.tscn
godot --headless --path . res://tests/mp_client.tscn    # prints MP CLIENT PASS
```

Both suites pass on Godot 4.6.2 as shipped. They double as living documentation of the
server API in `autoload/game.gd`.

## Suggested first play

Solo → Lucky Bard → mine the glowing herb blocks in town's garden → brew Luckroot + Gilded
Moss at the cauldron (Luck potion) → drink it → descend → pick a Dust Grifter and go all-in.

## Audio licensing

This repo contains **no audio**. The `audio_game/` music/SFX set is curated
from purchased packs licensed to the project owner only and is stripped from
version control (see `audio_game/ASSETS_PLACEHOLDER.md`). `audio_mgr.gd`
tolerates missing files; fresh clones run silent.

---

<sub>Support development — <a href="https://ko-fi.com/midwestmysterymeat">Ko-fi</a></sub>
