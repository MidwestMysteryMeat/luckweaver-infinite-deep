# Luckweaver: Infinite Deep — Feature Inventory & Roadmap

*Updated 2026-07-01. This is the living source of truth for what exists, what's missing,
and what's next. Companion docs: `GDD.md` (design detail), `README.md` (setup/architecture).*

---

## 1. Completion assessment

**Overall: ~70% of a shippable Early Access feature set. ~35% of a 1.0.**

| Area | Done | Notes |
|---|---|---|
| Voxel world (mining, placing, fluids, light, gravity blocks) | 95% | Missing: partial blocks, fluid buckets-from-world |
| Procedural generation (7 biomes, towns, traps, vaults, boss floors) | 85% | Missing: multi-level room stacking, mega-structures |
| **Combat (REAL-TIME d20)** | 80% | Live swings/bows/spells, enemy AI swings, crits/fumbles/resists/statuses. Missing: attack animations, telegraphs, dodge/block input, hit sounds |
| Mobs (11 hostile, 3 passive, 4 neutral, oozes, ghosts, stealth, elites, boss) | 75% | Missing: 3–4 more bosses, ranged enemies, pack AI |
| NPCs (villagers, guardians, explorers, quests, trade, rob) | 65% | Missing: quest persistence, reputation, recruitable NPCs |
| Crafting (smith/alchemy/cooking/spellcraft/enchant/skills, 4 metal tiers) | 90% | Missing: item repair, recipe discovery UI |
| Progression (levels, 8 disciplines, skill points, mutations, injuries) | 85% | Missing: perk trees per discipline (points are flat +2 now) |
| Survival (oxygen, farming, fishing, camps, cooking, storage) | 90% | Missing: hunger (deliberate?), taming/pets |
| Multiplayer (Steam-ready, 12 players, drop-in/out persistence, loot rules, FF) | 85% | Missing: Steam addon binaries installed + live Steam soak test, text→voice? |
| UI (HUD, map, handbook, benches, skills, storage, parley) | 75% | Missing: settings menu (sensitivity/volume), gamepad support, drag-drop inventory |
| **Audio** | **0%** | Nothing. Biggest single gap. |
| **3D art** | 10% | Everything is capsules/boxes — see §4 model list; Blockbench pipeline planned |
| Saves (world + traveling characters + town chests) | 90% | Missing: multiple save slots, cloud saves |
| Onboarding (handbook, tutorial breadcrumbs) | 60% | Missing: dedicated tutorial floor, contextual popups |

## 2. Complete feature inventory (what EXISTS today)

**World:** 96×40×96 voxel floors · 16³ chunk meshing w/ translucent pass · block-light BFS
(glow 15) · flowing water/lava/acid + rising steam/gases · gravity blocks · deterministic
seed+edit-log replication (late join & saves free) · biomes: delve, caverns, lakes, fungal,
crypt, frozen, molten · dungeon towns (allied/cozy/hostile/ghost) · traps: tripwires (expl/
acid/lava), blast & warp glyphs, spikes, webs, dart holes, gas chests/doors, crusher plates
(ceiling + wall) · ores by depth (gold, copper, iron, silver, adamant, luckstone) · farming
(light-gated crops) · fishing (3 rods, bait, 5 species, lava fishing, live-vs-fillet) ·
camps (respawn + heal aura) · storage chests (town-persistent) · waystones + floor map ·
doors + Golden Key locks · destructible everything (magic breaches locked doors).

**Combat (real-time):** LMB melee & bow strikes, d20 + atk vs AC, nat 20 crit (soul-strike
stacking), nat 1 fumble, luck advantage + widened crit range, weapon damage tags (silver=dark),
per-mob resist/weak, statuses both ways (burn/poison/sleep), enemy specials (multiattack,
venom, gold theft, luck drain, self-heal, curse, engulf, acid spit, split), sneak attacks
(unaware/smoke = 2×), boss HP phases, floating damage numbers, friendly-fire toggle.

**Magic:** rune+sigil+essence spellcraft (12 runes: explode, transmute, ice path, vines,
lava, teleport, luck, veils, snares, breach, walls, souls) · named combos (Midas Detonation,
Tidecaller's Boon, Veilwalk, Ghoststep, Wall of X, Second Dawn resurrection) · cursed spells ·
spell mutation · class signature spells · alchemy (shared-prop brewing, throwable bombs:
blast/smoke/gas flasks) · cooking feasts (shared buffs, permanent boosts) · skill merging.

**Character:** 6 classes · levels + 8 use-leveled disciplines + allocatable skill points ·
8 mutations · body-slot injuries (curable) · corpse-run death drops + soul-binding · oxygen ·
gear: 6+ weapons, 3 bows, 10 armor pieces, quality tiers (Fine→Legendary), 10 enchants ·
traveling characters (drop-in/out with progression) · party+level-scaled difficulty & loot ·
adaptive threat (0.7–1.4).

**Multiplayer:** 12 players · Steam lobbies (GodotSteam, addon drop-in) / ENet LAN / offline ·
server-authoritative everything · loot rules (FFA / round-robin / shared gold) · chat.

## 3. What's MISSING (prioritized roadmap)

### Phase A — "Feels like a game" (next)
1. **Audio** — mining ticks, swings/hits/crits, ambient drones per biome, boss stingers, UI
   clicks. Procedural (AudioStreamGenerator) or CC0 packs; hook points already exist (Events).
2. **3D models via Blockbench pipeline** (§4/§5) — replace capsules with real voxel models.
3. **Combat game-feel** — swing animation/arc, hit flash on mobs, screen shake on crit,
   attack telegraph on bosses, dodge-step (double-tap), block/parry on RMB with shield item.
4. **Settings menu** — mouse sensitivity, FOV, volume, keybinds.

### Phase B — depth
5. **More bosses** (per 5-floor milestone: Drowned King/lakes, Spore Tyrant/fungal, Lich of
   the Crypt, Adamant Colossus) with signature drops gating progression.
6. **Ranged/caster enemies** + pack AI (flanking, fleeing at low HP).
7. **Discipline perk trees** — skill points buy named perks, not flat levels.
8. **Quest persistence + reputation** with settlements; recruit rescued villagers to town.
9. **Pets/taming** (feed a Gloom Hog → follower), **fishing trophies/aquarium**.
10. **Events** — timed invasions ("the Tyrant's tax collectors"), Blood-Moon-style floors.

### Phase C — release polish
11. Steam soak test (addon binaries, lobby list UX, invites, rich presence), achievements.
12. Multiple save slots, options for world size/difficulty presets, gamepad, key rebinding UI.
13. Performance: greedy meshing, threaded chunk builds, light-update batching.
14. Localization scaffolding; accessibility (colorblind palettes, text size).

## 4. Complete 3D model list (Blockbench targets)

Style: chunky voxel/box models, 16–32 voxel scale, flat palette + emissive accents —
matches the world's vertex-color aesthetic. Rigging: simple bone per body part (Blockbench
supports this natively; export glTF for Godot).

**Player classes (6):** Shadowblade Rogue, Runesmith, Vault Crusader, Chaos Warlock,
Soul Warden, Fortune Bard — one base humanoid rig + per-class heads/torsos/palettes.

**Hostile mobs (14):** Gloom Rat, Rattlebone Skeleton, Cave Imp, Gloom Slime, Rune Golem,
Coin Bat, Mimic (chest form + open form), Vault Wraith, Cursed Hexer, Tomb Howler,
Obsidian Brute, Chameleon Stalker, Gloom Ghost, Bandit.

**Oozes (3):** Gelatinous Cube (translucent w/ suspended bones), Black Pudding, Ochre Jelly
(+ Lesser Jelly variant).

**Boss (1 now, 4 planned):** The Vault Tyrant (large, crowned, gilded) · [Drowned King,
Spore Tyrant, Crypt Lich, Adamant Colossus].

**Neutral/passive (6):** Villager (2–3 palette variants), Town Guardian, Lost Explorer,
Gloom Hog, Luck Toad, Dust Moth.

**Weapons (10):** Rusty/Copper/Iron/Silver/Gilded/Mythril/Adamant blades, Bone Maul,
Shortbow, Ironwood Warbow (+ arrow, + quiver).

**Tools (6):** Rusty/Gilded/Mythril picks, 3 fishing rods (+ bobber).

**Armor (10, worn overlays or icons):** hide cap/jerkin, bone mail, copper/iron/gilded/
obsidian/adamant plate, iron helm, gilded helm, shadow cloak.

**Props/blocks needing meshes (not cubes) (14):** campfire, waystone, anvil, enchanting
altar, cauldron, rune forge, skill forge, trading post, storage chest, loot chest (+trapped
+empty), door, portal, crusher spike plate, dart hole face.

**Items/pickups (12):** potion bottles (3 shapes), spell scroll/tome, skill scroll, runes,
sigils/cards, essences (crystal shards), gambit cache, golden key, ingots, fish (5 species),
meat/food, bomb flasks.

**FX meshes (5):** arrow projectile, smoke puff, gas cloud billboard set, explosion flash,
resurrection beam.

**Total: ~90 models** (~25 critical-path for the first visual pass: player rig, top 8 mobs,
boss, 4 weapons, campfire/waystone/anvil/chest/portal).

## 5. Blockbench × Claude pipeline (planned)

`.bbmodel` is plain JSON (elements = boxes with from/to/faces + texture refs). The pipeline:
1. Claude Code **generates `.bbmodel` files directly** into `art/models/` (scripted,
   parameterized: palette, proportions), or via a **Blockbench MCP/plugin** (Blockbench has a
   full JS plugin API that can call external processes) for iterative editing.
2. Human pass in Blockbench (pose, tweak, animate).
3. Export glTF → `res://art/` → a `ModelDb` maps mob/item ids → scenes, falling back to the
   current procedural capsules for anything unmodeled (no breakage while art lands).

## 6. Player count

Now **12 players** (`Net.MAX_PLAYERS`). Difficulty scales by party size (capped ×2.5 HP so
big lobbies see bigger packs, not sponges; pack size cap 24). Note: 12-way voxel edit storms
are untested at scale — the edit log design handles it, but a soak test is on Phase C.
