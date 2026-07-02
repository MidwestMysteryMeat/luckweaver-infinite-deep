class_name Blocks
extends RefCounted
## Static voxel block registry. Block ids are bytes stored in VoxelWorld.data.
## hard < 0 means unbreakable. drop is an item id ("" = nothing).
## drop_gold [min,max] pays raw gold on mining. falls = affected by gravity cascade.

const AIR := 0
const BEDROCK := 1
const STONE := 2
const DIRT := 3
const WOOD := 4
const GOLD_ORE := 5
const LUCKSTONE := 6
const GLOWSTONE := 7
const ICE := 8
const OBSIDIAN := 9
const LAVA := 10
const WATER := 11
const VINE := 12
const GOLD_BLOCK := 13
const SAND := 14
const GRAVEL := 15
const HERB_LUCK := 16
const HERB_GLOOM := 17
const HERB_CINDER := 18
const CHEST := 19
const CHEST_EMPTY := 20
const BENCH_SPELL := 21
const BENCH_ALCH := 22
const BENCH_SKILL := 23
const BENCH_SHOP := 24
const PORTAL := 25
const BRICK := 26
const DOOR := 27
const DOOR_OPEN := 28
const DOOR_LOCKED := 29
# Fluids: id encodes kind + level (source = max level, lower = thinner flow).
const WATER_F3 := 30
const WATER_F2 := 31
const WATER_F1 := 32
const LAVA_F2 := 33
const LAVA_F1 := 34
const ACID := 35
const ACID_F3 := 36
const ACID_F2 := 37
const ACID_F1 := 38
const STEAM_3 := 39
const STEAM_2 := 40
const STEAM_1 := 41
const CAMPFIRE := 42
const CROP_1 := 43
const CROP_2 := 44
const CROP_RIPE := 45
const BENCH_SMITH := 46
const BENCH_ENCH := 47
const KELP := 48
# Traps (server-triggered; see Game._server_tick_traps)
const SPIKES := 49
const WEB := 50
const TRIP_EXPL := 51
const TRIP_ACID := 52
const TRIP_LAVA := 53
const RUNE_TRAP := 54
const DART_TRAP := 55
const TELE_TRAP := 56
const CHEST_TRAPPED := 57
const DOOR_TRAPPED := 58
# Gases (spread like steam; effects on contact)
const GAS_POISON_2 := 59
const GAS_POISON_1 := 60
const GAS_SLEEP_2 := 61
const GAS_SLEEP_1 := 62
const GAS_INVERT_2 := 63
const GAS_INVERT_1 := 64
const SMOKE_3 := 65
const SMOKE_2 := 66
const SMOKE_1 := 67
const CRUSH_TRIGGER := 68
const WAYSTONE := 69
const COPPER_ORE := 70
const IRON_ORE := 71
const SILVER_ORE := 72
const ADAMANT_ORE := 73
const IRONWOOD_LOG := 74
const SHROOM_STALK := 75
const SHROOM_CAP := 76
const CHEST_STORE := 77

const DEFS := {
	AIR: {"name": "Air", "color": Color(0, 0, 0, 0), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	BEDROCK: {"name": "Bedrock", "color": Color(0.09, 0.08, 0.12), "hard": -1.0, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": ""},
	STONE: {"name": "Stone", "color": Color(0.38, 0.36, 0.42), "hard": 1.2, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "stone"},
	DIRT: {"name": "Dirt", "color": Color(0.35, 0.25, 0.17), "hard": 0.6, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "dirt"},
	WOOD: {"name": "Wood", "color": Color(0.45, 0.32, 0.18), "hard": 0.9, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "wood"},
	GOLD_ORE: {"name": "Gold Ore", "color": Color(0.75, 0.6, 0.2), "hard": 1.8, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "gold_dust", "drop_gold": [4, 14]},
	LUCKSTONE: {"name": "Luckstone", "color": Color(0.3, 0.75, 0.5), "hard": 2.2, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "luck_shard"},
	GLOWSTONE: {"name": "Glowstone", "color": Color(0.95, 0.85, 0.45), "hard": 0.8, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "glowstone"},
	ICE: {"name": "Ice", "color": Color(0.6, 0.8, 0.95), "hard": 0.5, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": ""},
	OBSIDIAN: {"name": "Obsidian", "color": Color(0.16, 0.1, 0.24), "hard": 4.0, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "obsidian"},
	LAVA: {"name": "Lava", "color": Color(0.95, 0.35, 0.08), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "fluid": "lava", "level": 3},
	WATER: {"name": "Water", "color": Color(0.2, 0.35, 0.7), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "fluid": "water", "level": 4},
	VINE: {"name": "Vine", "color": Color(0.2, 0.55, 0.2), "hard": 0.2, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	GOLD_BLOCK: {"name": "Gold Block", "color": Color(0.95, 0.78, 0.25), "hard": 2.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "", "drop_gold": [40, 70]},
	SAND: {"name": "Sand", "color": Color(0.8, 0.72, 0.5), "hard": 0.5, "solid": true, "opaque": true, "glow": false, "falls": true, "drop": "sand"},
	GRAVEL: {"name": "Gravel", "color": Color(0.5, 0.48, 0.46), "hard": 0.6, "solid": true, "opaque": true, "glow": false, "falls": true, "drop": "gravel"},
	HERB_LUCK: {"name": "Luckroot", "color": Color(0.45, 0.9, 0.5), "hard": 0.2, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "luckroot"},
	HERB_GLOOM: {"name": "Gloomcap", "color": Color(0.55, 0.4, 0.75), "hard": 0.2, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "gloomcap"},
	HERB_CINDER: {"name": "Cinder Bloom", "color": Color(0.95, 0.5, 0.25), "hard": 0.2, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "cinder_bloom"},
	CHEST: {"name": "Ancient Chest", "color": Color(0.7, 0.45, 0.15), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	CHEST_EMPTY: {"name": "Empty Chest", "color": Color(0.35, 0.25, 0.12), "hard": 0.8, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "wood"},
	BENCH_SPELL: {"name": "Rune Forge", "color": Color(0.55, 0.25, 0.85), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	BENCH_ALCH: {"name": "Alchemy Cauldron", "color": Color(0.2, 0.7, 0.65), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	BENCH_SKILL: {"name": "Skill Forge", "color": Color(0.85, 0.35, 0.35), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	BENCH_SHOP: {"name": "Trading Post", "color": Color(0.85, 0.7, 0.3), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	PORTAL: {"name": "Descent Portal", "color": Color(0.4, 0.9, 0.95), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	BRICK: {"name": "Dungeon Brick", "color": Color(0.28, 0.24, 0.34), "hard": 1.5, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "brick"},
	# Doors: E toggles open/closed; a Golden Key locks/unlocks. Locked doors
	# resist hands (hard -1) but magic_break lets spells and solvents through.
	DOOR: {"name": "Door", "color": Color(0.55, 0.4, 0.22), "hard": 1.0, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "door", "magic_break": true},
	DOOR_OPEN: {"name": "Open Door", "color": Color(0.55, 0.4, 0.22, 0.4), "hard": 1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "door", "magic_break": true},
	DOOR_LOCKED: {"name": "Locked Door", "color": Color(0.5, 0.33, 0.15), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "door", "magic_break": true},
	# --- fluid flow levels (see FLUIDS table + VoxelWorld.fluid_step)
	WATER_F3: {"name": "Water", "color": Color(0.24, 0.4, 0.75), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "fluid": "water", "level": 3},
	WATER_F2: {"name": "Water", "color": Color(0.28, 0.44, 0.78), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "fluid": "water", "level": 2},
	WATER_F1: {"name": "Water", "color": Color(0.34, 0.5, 0.82), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "fluid": "water", "level": 1},
	LAVA_F2: {"name": "Lava", "color": Color(0.92, 0.42, 0.12), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "fluid": "lava", "level": 2},
	LAVA_F1: {"name": "Lava", "color": Color(0.88, 0.5, 0.18), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "fluid": "lava", "level": 1},
	ACID: {"name": "Acid", "color": Color(0.35, 0.85, 0.15), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "fluid": "acid", "level": 4},
	ACID_F3: {"name": "Acid", "color": Color(0.42, 0.85, 0.2), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "fluid": "acid", "level": 3},
	ACID_F2: {"name": "Acid", "color": Color(0.5, 0.85, 0.25), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "fluid": "acid", "level": 2},
	ACID_F1: {"name": "Acid", "color": Color(0.58, 0.85, 0.3), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "fluid": "acid", "level": 1},
	STEAM_3: {"name": "Steam", "color": Color(0.85, 0.88, 0.92), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "steam", "level": 3},
	STEAM_2: {"name": "Steam", "color": Color(0.8, 0.83, 0.88), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "steam", "level": 2},
	STEAM_1: {"name": "Steam", "color": Color(0.75, 0.78, 0.84), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "steam", "level": 1},
	CAMPFIRE: {"name": "Campfire", "color": Color(0.95, 0.6, 0.2), "hard": 0.8, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "campfire"},
	# Crops grow on dirt when block light >= 8 (see Game crop tick).
	CROP_1: {"name": "Sprout", "color": Color(0.4, 0.65, 0.3), "hard": 0.1, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "seeds"},
	CROP_2: {"name": "Dungeon Wheat (growing)", "color": Color(0.6, 0.7, 0.3), "hard": 0.1, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "seeds"},
	CROP_RIPE: {"name": "Dungeon Wheat (ripe)", "color": Color(0.85, 0.78, 0.35), "hard": 0.1, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "wheat"},
	BENCH_SMITH: {"name": "Blacksmith Anvil", "color": Color(0.35, 0.35, 0.42), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	BENCH_ENCH: {"name": "Enchanting Altar", "color": Color(0.45, 0.2, 0.7), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	KELP: {"name": "Gloamkelp", "color": Color(0.25, 0.6, 0.5), "hard": 0.2, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "kelp"},
	# --- traps: walk-in blocks are non-solid; break them to disarm
	SPIKES: {"name": "Spike Block", "color": Color(0.6, 0.58, 0.62), "hard": 0.8, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "stone"},
	WEB: {"name": "Spider Web", "color": Color(0.85, 0.85, 0.88), "hard": 0.3, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	TRIP_EXPL: {"name": "Tripwire", "color": Color(0.45, 0.42, 0.4), "hard": 0.2, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	TRIP_ACID: {"name": "Tripwire", "color": Color(0.42, 0.48, 0.4), "hard": 0.2, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	TRIP_LAVA: {"name": "Tripwire", "color": Color(0.48, 0.42, 0.4), "hard": 0.2, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	RUNE_TRAP: {"name": "Blast Glyph", "color": Color(0.85, 0.35, 0.25), "hard": 0.2, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": ""},
	DART_TRAP: {"name": "Dart Hole", "color": Color(0.25, 0.22, 0.3), "hard": 1.5, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "brick"},
	TELE_TRAP: {"name": "Warp Glyph", "color": Color(0.6, 0.35, 0.9), "hard": 0.2, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": ""},
	CHEST_TRAPPED: {"name": "Ancient Chest", "color": Color(0.68, 0.43, 0.17), "hard": -1.0, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": ""},
	DOOR_TRAPPED: {"name": "Door", "color": Color(0.55, 0.4, 0.23), "hard": 1.0, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "door", "magic_break": true},
	# --- gases
	GAS_POISON_2: {"name": "Poison Gas", "color": Color(0.45, 0.7, 0.3), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "poison_gas", "level": 2},
	GAS_POISON_1: {"name": "Poison Gas", "color": Color(0.5, 0.72, 0.38), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "poison_gas", "level": 1},
	GAS_SLEEP_2: {"name": "Sleep Gas", "color": Color(0.75, 0.6, 0.85), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "sleep_gas", "level": 2},
	GAS_SLEEP_1: {"name": "Sleep Gas", "color": Color(0.78, 0.65, 0.86), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "sleep_gas", "level": 1},
	GAS_INVERT_2: {"name": "Inversion Gas", "color": Color(0.85, 0.45, 0.75), "hard": -1.0, "solid": false, "opaque": false, "glow": true, "falls": false, "drop": "", "magic_break": true, "gas": "invert_gas", "level": 2},
	GAS_INVERT_1: {"name": "Inversion Gas", "color": Color(0.87, 0.5, 0.78), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "invert_gas", "level": 1},
	SMOKE_3: {"name": "Smoke", "color": Color(0.3, 0.3, 0.34), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "smoke", "level": 3},
	SMOKE_2: {"name": "Smoke", "color": Color(0.35, 0.35, 0.38), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "smoke", "level": 2},
	SMOKE_1: {"name": "Smoke", "color": Color(0.4, 0.4, 0.43), "hard": -1.0, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": "", "magic_break": true, "gas": "smoke", "level": 1},
	# Pressure plate that arms an old-school crusher: a plane of spikes
	# descends from the ceiling (or closes in from a wall). See Game crushers.
	CRUSH_TRIGGER: {"name": "Pressure Plate", "color": Color(0.34, 0.32, 0.38), "hard": 0.4, "solid": false, "opaque": false, "glow": false, "falls": false, "drop": ""},
	# Waystone: placeable teleport bookmark. E = travel between your waystones.
	WAYSTONE: {"name": "Waystone", "color": Color(0.55, 0.75, 0.95), "hard": 1.2, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "waystone"},
	# Metal ores by depth; drops are ready ingots.
	COPPER_ORE: {"name": "Copper Ore", "color": Color(0.55, 0.38, 0.28), "hard": 1.5, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "copper_ingot"},
	IRON_ORE: {"name": "Iron Ore", "color": Color(0.5, 0.48, 0.52), "hard": 2.0, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "iron_ingot"},
	SILVER_ORE: {"name": "Silver Ore", "color": Color(0.7, 0.73, 0.8), "hard": 2.4, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "silver_ingot"},
	ADAMANT_ORE: {"name": "Adamant Ore", "color": Color(0.35, 0.65, 0.55), "hard": 3.5, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "adamant_ingot"},
	IRONWOOD_LOG: {"name": "Ironwood", "color": Color(0.35, 0.3, 0.22), "hard": 1.6, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "ironwood"},
	SHROOM_STALK: {"name": "Shroom Stalk", "color": Color(0.75, 0.7, 0.6), "hard": 0.6, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "gloomcap"},
	SHROOM_CAP: {"name": "Shroom Cap", "color": Color(0.6, 0.35, 0.55), "hard": 0.5, "solid": true, "opaque": true, "glow": true, "falls": false, "drop": "sootcap"},
	# Player storage: shared per-chest inventory (see Game.chest_store).
	CHEST_STORE: {"name": "Storage Chest", "color": Color(0.6, 0.42, 0.2), "hard": 1.0, "solid": true, "opaque": true, "glow": false, "falls": false, "drop": "chest_store"},
}

## Alpha < 1 renders on the translucent mesh pass (see Mesher) — water you can
## see into, drifting gas, gauzy webs, ghost-light ice.
const ALPHA := {
	WATER: 0.55, WATER_F3: 0.55, WATER_F2: 0.5, WATER_F1: 0.45,
	ACID: 0.6, ACID_F3: 0.6, ACID_F2: 0.55, ACID_F1: 0.5,
	ICE: 0.7, WEB: 0.45, DOOR_OPEN: 0.35,
	GAS_POISON_2: 0.4, GAS_POISON_1: 0.3, GAS_SLEEP_2: 0.4, GAS_SLEEP_1: 0.3,
	GAS_INVERT_2: 0.45, GAS_INVERT_1: 0.35,
	SMOKE_3: 0.6, SMOKE_2: 0.5, SMOKE_1: 0.35,
	STEAM_3: 0.4, STEAM_2: 0.3, STEAM_1: 0.2,
}

## kind -> {level: id}. Source = highest level; lower levels are thinning flow.
const FLUIDS := {
	"water": {4: WATER, 3: WATER_F3, 2: WATER_F2, 1: WATER_F1},
	"lava": {3: LAVA, 2: LAVA_F2, 1: LAVA_F1},
	"acid": {4: ACID, 3: ACID_F3, 2: ACID_F2, 1: ACID_F1},
	"steam": {3: STEAM_3, 2: STEAM_2, 1: STEAM_1},
	"poison_gas": {2: GAS_POISON_2, 1: GAS_POISON_1},
	"sleep_gas": {2: GAS_SLEEP_2, 1: GAS_SLEEP_1},
	"invert_gas": {2: GAS_INVERT_2, 1: GAS_INVERT_1},
	"smoke": {3: SMOKE_3, 2: SMOKE_2, 1: SMOKE_1},
}

## Trap ids the generator sprinkles onto floors/walls/doors.
const FLOOR_TRAPS := [SPIKES, TRIP_EXPL, TRIP_ACID, TRIP_LAVA, RUNE_TRAP, TELE_TRAP, WEB, CRUSH_TRIGGER]

## Soft blocks that acid eats through.
const DISSOLVES := [DIRT, SAND, GRAVEL, VINE, WOOD, HERB_LUCK, HERB_GLOOM, HERB_CINDER]


static func fluid_kind(id: int) -> String:
	var def := get_def(id)
	return String(def.get("fluid", def.get("gas", "")))


static func is_gas(id: int) -> bool:
	return get_def(id).has("gas")


static func fluid_level(id: int) -> int:
	return int(get_def(id).get("level", 0))


static func fluid_id(kind: String, level: int) -> int:
	var t: Dictionary = FLUIDS.get(kind, {})
	return int(t.get(level, AIR))


static func fluid_max(kind: String) -> int:
	var t: Dictionary = FLUIDS.get(kind, {})
	var m := 0
	for l in t:
		m = maxi(m, int(l))
	return m

## Block ids that open a UI / respond to E.
const INTERACTIVE := [CHEST, BENCH_SPELL, BENCH_ALCH, BENCH_SKILL, BENCH_SHOP, PORTAL,
	DOOR, DOOR_OPEN, DOOR_LOCKED, CAMPFIRE, BENCH_SMITH, BENCH_ENCH,
	CHEST_TRAPPED, DOOR_TRAPPED, WAYSTONE, CHEST_STORE]

static var _mat: StandardMaterial3D = null
static var _mat_trans: StandardMaterial3D = null


static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _mat


static func material_translucent() -> StandardMaterial3D:
	if _mat_trans == null:
		_mat_trans = StandardMaterial3D.new()
		_mat_trans.vertex_color_use_as_albedo = true
		_mat_trans.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat_trans.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat_trans.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return _mat_trans


static func get_def(id: int) -> Dictionary:
	return DEFS.get(id, DEFS[AIR])


static func is_solid(id: int) -> bool:
	return get_def(id).solid


static func is_breakable(id: int) -> bool:
	return get_def(id).hard >= 0.0
