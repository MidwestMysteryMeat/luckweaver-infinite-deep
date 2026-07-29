# ASSETS_NEEDED — replacement manifest

This repo ships **code + model sources, no media**. Fresh clones boot and play
fine: audio is silent (every load tolerates a missing file) and 3D art renders
from the checked-in Blockbench sources, falling back to procedural
capsules/boxes for anything unmodeled. This file lists exactly what you can
supply to fill the gaps, where it goes, and how it gets picked up.

- **Audio**: drop `.wav` files into `audio_game/` using the names below. No
  wiring needed — `autoload/audio_mgr.gd` loads `res://audio_game/<key>.wav`
  by name at runtime. See `audio_game/ASSETS_PLACEHOLDER.md` for why the
  originals are absent (owner-licensed packs, stripped from git).
- **3D art**: `.bbmodel` (Blockbench native JSON) files in `art/models/`.
  ~90 generated sources are already checked in and load directly at runtime —
  no export/import step. Repaint or replace them in Blockbench.

---

## 1. Audio

### How it works

`AudioMgr` (autoload, `autoload/audio_mgr.gd`) is purely client-side and
reacts to replicated game events. It exposes:

- `sfx(key, vol)` — one-shot from a 6-player pool (UI, self-events)
- `sfx3d(key, pos, vol)` — positional one-shot in the world (max distance 30 m)
- `play_music(key)` / `play_amb(key)` — looping music / ambience beds
  (they restart on `finished`, so supply loopable files)

Every key resolves to `res://audio_game/<key>.wav` — the `.wav` extension is
hard-coded, so **files must be WAV** (16-bit PCM recommended; Godot imports
them on first open). Missing files are skipped silently, so you can add
sounds piecemeal. Volume sliders (`vol_music`, `vol_sfx` in Settings) offset
everything, so master your files at a consistent level.

### Sound set (22 files)

Music & ambience are driven by depth band and biome (`_check_depth` polls
every 3 s); SFX fire from the events listed. All are "optional" in the sense
that the game runs silent without them — the **Required** column marks what a
complete-feeling build needs vs. nice-to-have polish.

| Event / hook | File (in `audio_game/`) | Suggested sound | Format | Required? |
|---|---|---|---|---|
| Town hub / surface band, floor load | `music_town.wav` | Calm tavern/hub theme, loopable | WAV loop | Required |
| Depth bands 1–2 | `music_deep.wav` | Tense delving theme, loopable | WAV loop | Required |
| Depth bands 3+ (boss depths) | `music_boss.wav` | Driving boss/danger theme, loopable | WAV loop | Required |
| Delve + crypt biomes (default ambience) | `amb_delve.wav` | Cave wind, distant drips, loopable | WAV loop | Required |
| Caverns / fungal / frozen biomes | `amb_caverns.wav` | Deep cavern rumble, echoes, loopable | WAV loop | Required |
| Flooded-lakes biome | `amb_lakes.wav` | Water lapping, underground lake, loopable | WAV loop | Optional |
| Molten biome (band 4+) | `amb_molten.wav` | Lava bubbling, heat roar, loopable | WAV loop | Optional |
| UI button press (every themed button) | `sfx_click.wav` | Short dry click/tick | WAV one-shot | Required |
| Melee swing, dodge burst, 0-damage miss | `sfx_swing.wav` | Whoosh | WAV one-shot | Required |
| Damage dealt to a mob (floating number) | `sfx_hit.wav` | Fleshy/solid impact | WAV one-shot | Required |
| Critical hit ("CRIT!") | `sfx_crit.wav` | Heavier impact + sting | WAV one-shot | Required |
| Own HP drops (any source, 350 ms debounce) | `sfx_hurt.wav` | Player grunt/pain | WAV one-shot | Required |
| Block broken / mined (set to AIR, 3D) | `sfx_break.wav` | Rock crumble | WAV one-shot | Required |
| Door opened/closed (3D) | `sfx_door.wav` | Wooden door creak/thud | WAV one-shot | Optional |
| Chest looted (3D) | `sfx_chest.wav` | Latch + lid open | WAV one-shot | Optional |
| Explosion carve, radius ≥ 1.5 (bombs, 3D) | `sfx_explosion.wav` | Boom with tail | WAV one-shot | Required |
| Boss spawns in view (3D) | `sfx_growl.wav` | Monster roar/growl | WAV one-shot | Optional |
| Item pickup collected | `sfx_pickup.wav` | Soft pop/blip | WAV one-shot | Required |
| Notify: gold gained (text contains "gold") | `sfx_coin.wav` | Coin clink | WAV one-shot | Optional |
| Notify: level up (text starts "Level ") | `sfx_levelup.wav` | Ascending fanfare/chime | WAV one-shot | Optional |
| Notify: fishing cast ("cast your line") | `sfx_splash.wav` | Water splash | WAV one-shot | Optional |
| Crafting success (forged/brewed/enchanted/cooked) + taming | `sfx_magic.wav` | Magical shimmer | WAV one-shot | Optional |

Notes for sound designers:

- Music/ambience loop by restart, not crossfade — bake seamless loop points.
- `sfx_swing` triple-duty: melee attack, dodge, and whiffed hits. Keep it
  short and neutral.
- The notify-keyword hooks (`_on_notify` in `audio_mgr.gd`) key off message
  text; adding new keyed sounds means one `elif` there.

## 2. 3D art (Blockbench models)

### Pipeline — how a `.bbmodel` becomes an in-game mesh

There is **no export step**. `art/model_db.gd` (`ModelDb`) parses the
`.bbmodel` JSON directly at runtime:

1. **Generate (already done)** — `tools/gen_models.gd` is a headless Godot
   script (`godot --headless --script res://tools/gen_models.gd`) that wrote
   all 90 sources in `art/models/`, each with an embedded base64 32×32
   palette PNG and per-face UVs.
2. **Edit** — open any `.bbmodel` in [Blockbench](https://www.blockbench.net/)
   (free) and reshape/repaint it. Optional: install
   `art/blockbench/claude_bridge.js` as a Blockbench plugin (File ▸ Plugins ▸
   Load Plugin from File) to get a Tools ▸ "Ask Claude (model edit)" action
   that rewrites the open model's elements from a text prompt (needs your own
   Anthropic API key).
3. **Save** — save over the file in `art/models/`. Next run picks it up.
4. **Load** — at runtime `ModelDb.load_model()` builds either:
   - **Textured path**: if the model has an embedded texture, one `ArrayMesh`
     UV-mapped into it with nearest filtering (crisp Minecraft-style pixels);
   - **Tint path**: otherwise, one `BoxMesh` per element, colored from the
     element name.

Conventions (break these and the model won't read correctly):

- **1 Blockbench unit = 1/16 m** in-game; models stand on `y = 0`, face `-Z`.
- Element names are `part|#RRGGBB` — the hex suffix is the part tint used by
  the untextured path (and the palette generator). Keep the suffix when
  renaming parts.
- File naming: `<category>_<id>.bbmodel` with categories `mob_`, `boss_`,
  `class_`, `item_`, `weapon_`, `tool_`, `prop_`, `fx_`.
- Missing model = automatic fallback to the old procedural capsule/box
  (mobs get their `Db.ENEMIES` color/shape), so art can land piecemeal.

### Where models are used

- **Enemies** (`world/enemy.gd`) — `ModelDb.mob(type)` via the `MOBS` table
  in `art/model_db.gd`; ghost/stealth mobs render the same model transparent;
  elites scale it up 15%.
- **Player classes** (`player/player.gd`) — `ModelDb.class_model(class_id)` →
  `class_<id>.bbmodel`, shown for other players' bodies.
- **Held items & world drops** (`player/player.gd`, `world/pickup.gd`) —
  `ModelDb.item_model(entry)` routes item ids to files (weapons/tools by id,
  fish by species, categories like runes/scrolls/potions to shared models).

### Model inventory (90 sources, all checked in)

Target format is always **`.bbmodel` in `art/models/`** — column omitted
where obvious. Status legend: **wired** = loaded by runtime code today;
**staged** = source exists, no code path loads it yet (safe to improve now,
it lights up when the feature wires in).

#### Enemies — all 33 roster types covered (27 files, some shared)

| Entity | bbmodel source (exists?) | Status |
|---|---|---|
| gloom_rat | `mob_gloom_rat` (yes) | wired |
| rattlebone / bone_archer | `mob_rattlebone` (yes, shared) | wired |
| cave_imp | `mob_cave_imp` (yes) | wired |
| gloom_slime | `mob_gloom_slime` (yes) | wired |
| dice_golem | `mob_dice_golem` (yes) | wired |
| coin_bat | `mob_coin_bat` (yes) | wired |
| mimic | `mob_mimic` (yes) | wired |
| vault_wraith / frost_wisp | `mob_vault_wraith` (yes, shared) | wired |
| cursed_croupier / gloom_shaman | `mob_cursed_croupier` (yes, shared) | wired |
| tomb_howler | `mob_tomb_howler` (yes) | wired |
| obsidian_brute | `mob_obsidian_brute` (yes) | wired |
| chameleon_stalker | `mob_chameleon_stalker` (yes) | wired |
| gloom_ghost | `mob_gloom_ghost` (yes) | wired |
| bandit | `mob_bandit` (yes) | wired |
| acid_cube | `mob_acid_cube` (yes) | wired |
| black_pudding | `mob_black_pudding` (yes) | wired |
| ochre_jelly / acid_lobber | `mob_ochre_jelly` (yes, shared) | wired |
| villager / refuge_citizen | `mob_villager` (yes, shared) | wired |
| town_guardian | `mob_town_guardian` (yes) | wired |
| lost_explorer | `mob_lost_explorer` (yes) | wired |
| gloom_hog | `mob_gloom_hog` (yes) | wired |
| luck_toad | `mob_luck_toad` (yes) | wired |
| dust_moth | `mob_dust_moth` (yes) | wired |
| Boss: pit_boss | `boss_pit_boss` (yes) | wired |
| Boss: drowned_king | `boss_drowned_king` (yes) | wired |
| Boss: spore_tyrant | `boss_spore_tyrant` (yes) | wired |
| Boss: crypt_lich | `boss_crypt_lich` (yes) | wired |
| Boss: adamant_colossus | `boss_adamant_colossus` (yes) | wired |
| (split-jelly variant) | `mob_ochre_jelly_lesser` (yes) | staged |

To give a shared type its own look, add a dedicated file and a one-line entry
in the `MOBS` table in `art/model_db.gd`.

#### Player classes (6/6)

| Entity | bbmodel source (exists?) | Status |
|---|---|---|
| cardsharp | `class_cardsharp` (yes) | wired |
| rune_dealer | `class_rune_dealer` (yes) | wired |
| high_roller | `class_high_roller` (yes) | wired |
| chaos_croupier | `class_chaos_croupier` (yes) | wired |
| soul_banker | `class_soul_banker` (yes) | wired |
| lucky_bard | `class_lucky_bard` (yes) | wired |

#### Weapons & tools (17/17 item ids covered)

| Entity / item id | bbmodel source (exists?) | Status |
|---|---|---|
| blade_rusty / copper / iron / silver / gilded / mythril / adamant | `weapon_blade_<tier>` (yes, all 7) | wired |
| maul_bone | `weapon_maul_bone` (yes) | wired |
| bow_short / ironwood / gilded | `weapon_bow_<tier>` (yes, all 3) | wired |
| pick_rusty / gilded / mythril | `tool_pick_<tier>` (yes, all 3) | wired |
| pole_wood / gilded / mythril (fishing) | `tool_pole_<tier>` (yes, all 3) | wired |

#### Items (18 files; 16 wired)

| Entity / item family | bbmodel source (exists?) | Status |
|---|---|---|
| runes (`rune_*`) | `item_rune` (yes) | wired |
| cards (`card_*`) | `item_sigil` (yes) | wired |
| essences (`ess_*`) | `item_essence` (yes) | wired |
| ingots (`*_ingot`) | `item_ingot` (yes) | wired |
| live fish, per species | `item_fish_gloomfin` / `_silver_darter` / `_gilded_carp` / `_void_eel` / `_luckfish` (yes, all 5) | wired |
| meats (hog_meat, fish_meat, toad_leg) | `item_meat` (yes) | wired |
| potion (drinkable) | `item_potion_round` (yes) | wired |
| potion (throwable bomb) | `item_bomb` (yes) | wired |
| spell | `item_tome` (yes) | wired |
| skill | `item_scroll` (yes) | wired |
| gambit_cache | `item_cache` (yes) | wired |
| golden_key | `item_key` (yes) | wired |
| potion variants | `item_potion_tall`, `item_potion_flask` (yes) | staged |

#### Props & FX (20 files, all staged)

Interactable blocks (chests, doors, portals, forges, campfires…) currently
render as textured voxel cubes in the chunk mesher; these prop sources are
staged for a future block-entity pass. FX are procedural today.

| Entity / block | bbmodel source (exists?) | Status |
|---|---|---|
| chest / trapped chest / store chest | `prop_chest`, `prop_chest_trapped`, `prop_chest_store` (yes) | staged |
| door | `prop_door` (yes) | staged |
| portal | `prop_portal` (yes) | staged |
| campfire | `prop_campfire` (yes) | staged |
| anvil | `prop_anvil` (yes) | staged |
| cauldron | `prop_cauldron` (yes) | staged |
| altar | `prop_altar` (yes) | staged |
| rune forge / skill forge | `prop_rune_forge`, `prop_skill_forge` (yes) | staged |
| trading post | `prop_trading_post` (yes) | staged |
| waystone | `prop_waystone` (yes) | staged |
| crusher plate / dart hole (traps) | `prop_crusher_plate`, `prop_dart_hole` (yes) | staged |
| arrow / beam / explosion / gas cloud / smoke puff | `fx_arrow`, `fx_beam`, `fx_explosion`, `fx_gas_cloud`, `fx_smoke_puff` (yes) | staged |

---

**Summary**: 22 audio files (all absent by design — supply your own WAVs),
90 model sources (all present; 67 load in-game today, 23 staged for future
wiring, everything else falls back to procedural shapes).
