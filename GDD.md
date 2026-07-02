# Luckweaver: Infinite Deep — Game Design Document

*(formerly "Luck & Loot: Infinite Gambit" — the casino theming has been retired in favor of
straight dark-fantasy RPG styling; the luck-bends-fate mechanic remains the core hook.)*

**Genre:** Turn-based Fantasy RPG (d20) · Voxel Destructible Procedural Dungeon Crawler ·
Survival-crafting (fluids, lighting, farming, cooking, camps, smithing, enchanting)
**Players:** 1–4 (Steam co-op via GodotSteam, LAN/ENet fallback, solo offline)
**Engine:** Godot 4.3+ (Forward+), pure GDScript, zero external assets (procedural meshes + vertex colors)

---

## Core Fantasy

D&D meets Minecraft. You are a **Luckweaver** — an adventurer whose luck literally bends the
dice. Every wall, floor, and vein of ore is a voxel you can mine, blast, transmute, or reshape
with crafted spells and potions. Combat is classic turn-based fantasy — d20 to-hit, dice
damage, crits and fumbles — with your luck stat leaning on every roll.

## Core Loop

1. **Explore & reshape** a procedurally generated voxel dungeon floor (mine, tunnel, blast).
2. **Fight** a varied bestiary in turn-based d20 combat; **hunt** animals; **parley, trade,
   or rob** neutral folk.
3. **Craft** spells (rune + card + essence), potions (2–3 ingredients), merged skills — and
   **cook feasts** at camps, **farm** wheat under torchlight.
4. **Loot, level, mutate**, then take the portal down. Every 5th floor is a **Pit Boss**
   multi-phase battle. Floors are infinite; difficulty curves *and adapts*.

## Key Systems

### Turn-Based d20 Combat (server-authoritative)
- **Initiative:** d20 + luck/10 each side — lose it and the foe swings first.
- **Attack:** d20 + attack bonus (class + level/2 + weapon + feast buffs) vs the foe's AC.
  Damage is weapon dice (1d6 rusty blade → 3d6+2 mythril greatblade; 1d12 bone maul).
- **Nat 20 = crit** (double dice, Soul Strike passives stack on top). **Nat 1 = fumble**
  (the foe gets a free jab — and enemy fumbles hand *you* a counter).
- **Luck bends every roll:** advantage procs (roll twice, keep high), crit range widens
  (19+ at 40 luck, 18+ at 70), *Loaded Dice* rerolls one miss per battle, flee is a
  luck-modified opposed d20.
- **Defend** (+4 AC for a round), **combat spells** (smite / chill / mend / hex / fortune),
  **potions** drinkable mid-fight.
- **Enemy specials** roll each enemy turn: flurries, venom (3-turn DoT), luck drain,
  gold theft, self-mending, curses (disadvantage on your next strike).
- **Boss:** The Pit Boss — phases at 2/3 and 1/3 HP; hits harder, tricks more often.

### Bestiary: variety, randomization, adaptive difficulty
- **Hostiles:** Gloom Rat, Rattlebone Skeleton, Cave Imp, Gloom Slime, Dice Golem, Coin Bat,
  Mimic, Vault Wraith, Cursed Croupier, Tomb Howler, Obsidian Brute — each with its own AC,
  damage dice, special, and look (shape/size/color). Deeper floors unlock nastier entries.
- **Elites** roll at spawn — *Gilded* (rich), *Cursed* (vicious), *Ancient* (armored) —
  with boosted stats, auras, and better loot.
- **Passive animals** (Gloom Hog, Luck Toad, Dust Moth) are hunted with one clean strike
  for meat/eggs — luck can double the yield.
- **Neutral folk** (Lost Explorer, Refuge Citizens) talk, trade — or you can **rob them on
  an opposed d20** and eat the consequences when it goes wrong.
- **Difficulty curve:** enemy stats scale with floor; spawn weights shift toward the deep-floor
  roster as you descend.
- **Adaptive threat (0.7–1.4):** win fights above 70% HP and the dungeon ratchets up (more HP,
  more elites, bigger packs); get downed and it eases off. Persisted in saves.

### Voxel World: destruction, fluids, light, farming
- 96×40×96 voxel floor, 16³ chunks, face-culled ArrayMesh + trimesh collision.
- Free mining/placing, gravity blocks (sand/gravel cascade), unbreakable bedrock shell.
- **Fluids (Minecraft-style):** water, lava, and acid **flow** — fall, spread with thinning
  levels, retract when cut off. Lava is sluggish; lava+water fuses obsidian and boils off
  **steam that rises** and dissipates; **acid dissolves** soft blocks and hurts to stand in.
  Swimming slows you; you can paddle up. The server steps the sim via `fluid` ops in the
  replicated edit log, so all peers, late joiners, and saves stay bit-identical.
- **Block lighting (Minecraft-style):** glowstone/lava/campfires emit light 15, decaying per
  block through air; darkness is real. Light is baked into vertex colors at meshing and
  repaired locally after every edit.
- **Farming:** plant seeds on dirt; crops random-tick and only grow at **light ≥ 8** —
  torch your fields. Harvest wheat + more seeds; feed the cooking system.
- **Doors:** placeable, open/close with E, **lock/unlock with a Golden Key**. Locked doors
  resist hands but **spells and solvents breach them** — as they do walls, floors, ceilings.
- All edits are ops in a replicated **edit log**: deterministic replay for late joiners and saves.

### Biomes, Swimming & Oxygen
- Each floor rolls a **biome**: *Delves* (worked rooms), *Caverns* (organic worm-tunnel
  warrens), *Lakes* (flooded grottos with kelp forests, sand beaches, luckstone beds), and
  *Molten* depths (lava pools, obsidian shores) from floor 6.
- **Swimming:** liquids slow you, space paddles up. Your **oxygen** (20s) drains while your
  head is submerged; at zero you drown (3 dmg/s). Covered by: surfacing, **Tidecaller
  potions** (brew 2 Gloamkelp), the **Tidecaller's Boon** spell (fortune rune + frost
  essence), or **Tideborn-enchanted armor**.

### Blacksmithing & Enchanting (Skyrim-style)
- **Anvil:** forge weapons and armor (head/body slots) from mined and hunted materials —
  stone, wood, bone, hides, gold dust, obsidian, luck shards. Higher Smithing unlocks better
  recipes and bakes **quality** into the piece (Fine → Superior → Exquisite → Legendary:
  +damage/+AC). **Improve** existing gear with gold dust, capped by your skill.
- **Enchanting Altar:** 2 matching essences + 30 gold. Weapons: Flamebrand (+fire dice),
  Frostbite (freeze chance), Souleater (lifesteal), Goldtouched (+gold on kill), Thornheart
  (heal on hit). Armor: Bulwark (+AC), **Tideborn** (water breathing), Dread (-foe attack),
  Fortunate (+luck), Mending (heal after victories). Power scales with Enchanting skill.

### Disciplines: skills level by use
Seven disciplines — **Combat, Mining, Smithing, Alchemy, Cooking, Spellcraft, Enchanting** —
gain XP whenever you use them (every swing won, block mined, potion brewed...). Higher levels
mean better everything: faster mining, stronger potions/meals/spells, finer gear, bigger
enchants, higher attack. Character level-ups grant **skill points**; spend them in the
Disciplines panel (**K**) — each point is +2 effective levels in one discipline.

### Traps & Hazards (procedural on floors, walls, and doors)
- **Tripwires** (explosive / acid-flood / lava-vent), **blast glyphs**, **warp glyphs**
  (teleport you across the floor), **spike blocks**, **spider webs** (slow to a crawl),
  **dart holes** in walls (sting + sleep), **trapped chests** (gas eruptions — they look
  identical to real ones), **trapped doors** (poison vents from the frame), and **pressure
  plates** that arm old-school **crushers**: a plane of spikes grinds down from the ceiling
  or closes in from a wall, sweeping the room. Trap density scales with depth; every trap is
  a block — spot it and mine it to disarm.
- **Gases:** poison (damage), sleep (drops you where you stand), **inversion gas** (flips
  your vision upside down), and smoke — all spread and dissipate through the fluid sim.

### Bows, Sneak Attacks, Bombs
- **Bows & arrows** (smithable): a Shoot action in combat, and aimed shots in the world that
  open fights at range. Strike from beyond 8 blocks — or from inside **smoke** — for a
  **sneak attack**: a free opening strike with doubled dice before initiative.
- **Alchemy bombs:** sootcaps brew **Smoke Bombs** (blind stalkers, set up sneaks), toxic
  brews throw as **Gas Flasks** (poison clouds), volatile as **Blast Flasks** (explosions
  that leave live acid). Spell counterparts: **Rune of Veils** (smoke/sleep/poison clouds by
  essence) and **Rune of Snares** (place your own blast glyph).

### Oozes
D&D-style slimes: the **Gelatinous Cube** (engulfs you in caustic jelly), the **Black
Pudding** (its acid pits your armor, shredding AC), and the **Ochre Jelly** (splits into a
lesser jelly when cut below half).

### Drop-in / drop-out progression
Your character is saved **locally** and travels with you: join any friend's lobby and your
level, disciplines, gear, and gold come along (pick a different class and you start that
class fresh). Difficulty and loot scale live with **party size and average level** on top of
the adaptive threat system.

### Stealth, Spirits & Status Warfare
- **Chameleon Stalkers** fade into the walls (near-invisible until their eyes give them
  away); **Gloom Ghosts** drift straight through walls and shrug off physical blows.
- **Every mob has resistances and weaknesses** (physical/fire/frost/poison/dark): oozes
  shrug poison but melt to fire, brutes shrug fire but crack to frost, skeletons splinter
  to maces but ignore venom. Damage is tagged and the log calls out resists and weak hits.
- **Status effects go both ways:** burn, poison, and sleep afflict enemies too — put a pack
  to sleep with gas, ignite them with Flamebrand or fire spells, poison them with flasks.
  Statuses tick in combat *and* in the open world.
- **Player stealth:** the **Veilwalk** spell (veil rune + void essence) and the smithable
  **Shadow Cloak** hide you from stalking eyes; smoke does too.
- **Injuries:** massive hits can wound a body part — head (-luck), arms (-attack), legs
  (slower), body (-AC). Healing potions mend one; Benediction-class spells cure all.
- **Second Dawn** (soul rune): resurrection — calls a recently-fallen ally to your side,
  fully healed, with the gold the reaper took returned.
- **Battlefield shaping spells:** Wall of Fire / Ice / Thorns / Obsidian / Gold (wall rune ×
  essence), **Breach** (melt a corridor through solid rock), **Ghoststep** (phase through
  the wall in front of you).

### Dungeon Towns
Some floors hide a **hamlet** — brick huts, a lamplit square, a campfire, and a **town
waystone**: *Allied* (villagers trade, a Town Guardian keeps the peace), *Cozy* (extra
hearths, a shop, herbs), *Hostile* (bandits hold it — take it back), or *Ghost towns*
(empty streets, restless dead, unguarded chests... mostly). Villagers, explorers, and
guardians offer **quests** — kill contracts and gathering jobs paying gold and XP.

### Maps & Waystones
- **M** opens the floor map — a live top-down render of the terrain with you and every
  waystone marked.
- **Waystones** are placeable, smithable teleport bookmarks: press E on any waystone to
  travel between all attuned stones on the floor. Towns come with one.

### Friendly Fire
A host lobby toggle: when on, area spells, bombs, and gas clouds harm allies caught in
the blast (half damage). Choose your Chaos Warlocks wisely.

### Fishing
Craft a rod (Gloomwood → Gilded → **Mythril, which fishes lava**), aim at any open water —
lakes, frozen ponds, dungeon pools — and cast (RMB). Grubs dug from dirt are bait; luck,
rod tier, bait, and your **Fishing discipline** all tilt the catch: junk, five fish species
by rarity (Gloomfin → **Luckfish**, which grants permanent luck when filleted... or kept
alive to sell), or sunken treasure. **Keep fish alive** for the market or *use* them to
fillet meat for cooking.

### Materials & Crafting Tiers
Metal rarities gate progression down the floors: **copper** (anywhere) → **iron** (floor 3+)
→ **silver** (floor 5+, its blades carry the *dark* tag that cuts ghosts) → **adamant**
(floor 9+). **Ironwood** grows in the deep for warbows. All feed tiered anvil recipes
(weapons, plate, helms, rods) unlocked by Smithing level. Camp gear is craftable too:
storage chests, doors, campfires, glowstone lanterns.

### Death & Storage
- **Corpse runs:** death drops your inventory where you fell — fight back to it. Spells,
  enchanted gear, and **soul-bound** items stay with you (bind anything at the Enchanting
  Altar with a Luck Shard + 30g).
- **Storage Chests** (craft: 6 wood): 12 shared slots per chest, placeable anywhere —
  camps, hamlets, your town base. Town chests persist across the whole run.

### Tutorial & Handbook
- **H** opens the **Luckweaver's Handbook**: five pages covering movement, d20 combat,
  benches, survival systems, and the Deep.
- Fresh characters get **tutorial breadcrumbs** on the HUD in town (mine → craft → descend).
- **M** opens the live floor map.

### More Biomes
Fungal grottos (giant mushrooms, spore-sleep pockets, herbs), **crypts** (brick ruins, webs,
undead, chests among the dead), and **frozen halls** (iced floors, ice-sheeted ponds) join
delves, caverns, lakes, and the molten depths.

### Camps & Cooking
- Place a **campfire**: it lights the room, becomes a **respawn point**, and slowly heals
  anyone resting within its glow.
- **Cook 2–3 food ingredients** at the fire (same shared-property rule as alchemy):
  Hearty (regen), Ironblood (+attack), Stoneskin (+AC), Lucky (+luck) — 3-minute buffs served
  as a **feast to everyone at the fire**. Rich meals can roll **Legendary** and grant a
  **permanent** boost (+2 max HP, +1 attack, +1 AC, or +1 luck).

### Spell Making
`Rune (effect) + Card (power) + Essence (element)` at a **Rune Forge** bench.
World effects: explode, transmute-to-gold, ice path, vine growth, lava burst, teleport,
luck buff, mend. The essence also sets the spell's **combat trick** (smite/chill/mend/
hex/fortune). Named combos: **Jackpot Explosion** (ruin+gilded: destruction + loot rain),
**Fortune Warp** (fate+verdant); Jokers can roll **Cursed** spells with backlash. Spells have
rarity tiers, charges, and can be **mutated** (rerolled) for gold.
**Every class starts with a signature spell usable in the world and in battle:** Marked Deck,
Runeburst, Golden Bulwark, Wild Warp, Soul Siphon, Fortune's Tune (party-wide luck song).

### Alchemy
Elder-Scrolls-style: each ingredient has 2 properties; properties shared by ≥2 ingredients
become the potion's effects (heal, luck, volatile, stoneskin, swift, toxic). Volatile potions
are **throwable** and melt voxels. No shared properties → Murky Sludge.

### Skill Crafting
Merge two skills/spells at the **Skill Forge**: passives union and amplify
(mine speed, luck-on-dig, card insight, reroll tokens, wager refund, loot bonus, soul power).
Special combo: mining + luck passives → **Loaded Dice Drill**.

### Progression
- 6 classes: Cardsharp Rogue, Rune Dealer, High Roller Paladin, Chaos Croupier, Soul Banker, Lucky Bard.
- Rarities: Common → Uncommon → Rare → Epic → Mythic → **Cursed**.
- XP/levels (+HP, +luck), 8 mutations (blessing/curse hybrids), Gambit Cache loot boxes, shop vendor.

### World
- **Floor 0: town hub** — persistent across runs (its edit log is saved), holds all crafting
  benches, shop, and the descent portal. Players can reshape and decorate it permanently.
- Dungeon floors: BSP-ish rooms + L-corridors, ore veins, herb gardens, glowstone, lava pools,
  chests, hidden **alchemy labs**, **rune forges**, and **gilded vaults**; portal in the farthest
  room (boss floors: portal appears only when the boss falls).

### Multiplayer (Steam-ready)
- Godot high-level multiplayer; **SteamMultiplayerPeer** (GodotSteam) with Steam lobbies, or
  ENet on LAN; solo uses an offline peer — one code path for all three.
- Server-authoritative: inventories, stats, edits, encounters, loot all resolve on host.
- World sync = seed + edit log (tiny payloads); late join fully supported; shared world edits,
  chat, name labels.
- **Loot rules, set by the host in the lobby:** *Free for all*, *Round robin* (drops are
  assigned to players in turn and beam-labeled with their owner), or *Shared gold*
  (every payout splits evenly). Loot drops into the world as glowing, rarity-colored
  beacons you walk over to collect.

### Save System
JSON snapshot: run seed, floor, per-floor edit log, persistent town log, full player records
(matched by name on load). Autosaves on descend; F5 quicksave (host).

## Controls
WASD + mouse, Space jump, Shift sprint, LMB mine, RMB place/use, E interact, Tab inventory,
1–9 hotbar, T chat, F5 quicksave, Esc pause.

## Folder Structure

```
MINEDND/
├── project.godot            engine config, autoload order
├── steam_appid.txt          480 (Spacewar) for development
├── scenes/                  main.tscn (only scene file), main.gd (UI orchestrator), world.gd
├── autoload/                events.gd, db.gd, steam_mgr.gd, net.gd, game.gd, save_mgr.gd
├── voxel/                   blocks.gd, mesher.gd, voxel_world.gd
├── dungeon/                 dungeon_generator.gd
├── player/                  player.gd
├── combat/                  encounter.gd (all four games, wagers, boss phases)
├── crafting/                spell_forge.gd, alchemy.gd, skill_forge.gd, effect_exec.gd
├── world/                   enemy.gd, pickup.gd
└── ui/                      ui_theme.gd, main_menu.gd, lobby_ui.gd, hud.gd, inventory_ui.gd,
                             craft_ui.gd, gamble_ui.gd, shop_ui.gd, pause_menu.gd
```

## Key Tech Decisions

| Decision | Rationale |
|---|---|
| Godot 4.3+ over Unity | Fully text-authorable project, free Steam export, built-in high-level netcode |
| Chunked voxels, vertex colors, unshaded material | No assets, no lights; fast rebuilds on destruction |
| Seed + edit-log world replication | Bytes instead of megabytes; deterministic across peers; doubles as save format |
| All RPCs on autoload singletons + fixed node names | Identical node paths on every peer — Godot RPC requirement |
| GodotSteam accessed via `Engine.get_singleton("Steam")` + `ClassDB.instantiate("SteamMultiplayerPeer")` | Project parses and runs even before the addon is installed; LAN/solo need nothing |
| Server-authoritative everything | Cheat-resistant, single source of truth, trivial late-join |
| UI built 100% in code | No fragile .tscn diffs; one minimal main.tscn only |
