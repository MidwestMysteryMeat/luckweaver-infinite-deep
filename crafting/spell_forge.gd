class_name SpellForge
extends RefCounted
## Spellcrafting: Rune (effect) + Card (power) + Essence (element) → spell meta.
## Metas are JSON-safe dicts stored on "spell" inventory items.
## meta = {name, effect, power, element, rarity, charges, combat, cursed}

const EFFECT_NAMES := {
	"explode": "Detonation", "transmute_gold": "Midas Bloom", "ice_path": "Glacier Road",
	"vines": "Wildgrowth", "lava_burst": "Cinder Geyser", "teleport": "Warp Step",
	"luck_buff": "Fortune's Kiss", "smoke_cloud": "Shroud", "glyph_trap": "Ward Glyph",
	"mend": "Benediction",
}
const ELEMENT_PREFIX := {
	"ember": "Blazing", "frost": "Frozen", "verdant": "Verdant",
	"void": "Umbral", "gilded": "Gilded",
}
## Element decides the spell's in-combat trick:
## smite (dice damage) | chill (foe skips a turn) | mend (heal) |
## hex (-2 foe attack, advantage) | fortune (+20 luck this battle).
const ELEMENT_COMBAT := {
	"ember": "smite", "frost": "chill", "verdant": "mend",
	"void": "hex", "gilded": "fortune",
}


## skill = the crafter's effective Spellcraft level: more power, more charges.
static func craft(rune_id: String, card_id: String, essence_id: String,
		rng: RandomNumberGenerator, skill := 1) -> Dictionary:
	var effect: String = Db.ITEMS[rune_id].effect
	var element: String = Db.ITEMS[essence_id].element
	var power: int = Db.ITEMS[card_id].power
	var cursed := false
	if card_id == "card_joker":
		power = rng.randi_range(1, 6)
		cursed = rng.randf() < 0.35
	if element == "void":
		power += 1
		if rng.randf() < 0.2:
			cursed = true
	power += skill / 15

	var meta := {
		"effect": effect, "power": power, "element": element,
		"charges": 2 + power + skill / 10, "combat": ELEMENT_COMBAT[element], "cursed": cursed,
	}
	# Named combos.
	var name := "%s %s" % [ELEMENT_PREFIX[element], EFFECT_NAMES[effect]]
	if effect == "explode" and element == "gilded":
		name = "Midas Detonation"
		meta["loot_rain"] = true
	elif effect == "teleport" and element == "verdant":
		name = "Fortune Warp"
		meta["combat"] = "fortune"
	elif effect == "luck_buff" and element == "frost":
		name = "Tidecaller's Boon"
		meta["gills"] = true  # world cast also grants water breathing
	if cursed:
		name = "Fiend's Pact: " + name
	meta.name = name
	meta.rarity = _rarity(power, cursed, rng)
	return meta


static func mutate(meta: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var m := meta.duplicate(true)
	var roll := rng.randf()
	if roll < 0.45:
		m.power = int(m.power) + 1
		m.charges = int(m.charges) + 2
		m.name = "Mutated " + String(m.name).trim_prefix("Mutated ")
	elif roll < 0.7:
		var combats := ["smite", "chill", "mend", "hex", "fortune"]
		m.combat = combats[rng.randi_range(0, combats.size() - 1)]
		m.name = String(m.name) + " (Twisted)"
	else:
		m.cursed = true
		m.power = int(m.power) + 2
		m.name = "Fiend's Pact: " + String(m.name).trim_prefix("Fiend's Pact: ")
	m.rarity = _rarity(int(m.power), bool(m.cursed), rng)
	return m


static func _rarity(power: int, cursed: bool, rng: RandomNumberGenerator) -> int:
	if cursed:
		return Db.Rarity.CURSED
	if power >= 5:
		return Db.Rarity.MYTHIC
	if power >= 4:
		return Db.Rarity.EPIC
	if power >= 3:
		return Db.Rarity.RARE
	return Db.Rarity.UNCOMMON if rng.randf() < 0.5 else Db.Rarity.COMMON


## Class signature spells — usable both in the world (effect) and mid-combat
## (combat). Everyone starts with theirs; charges are generous.
static func class_spell(class_id: String) -> Dictionary:
	var presets := {
		"cardsharp": {"name": "Seer's Brand", "effect": "luck_buff", "combat": "hex", "element": "void", "power": 1},
		"rune_dealer": {"name": "Runeburst", "effect": "explode", "combat": "smite", "element": "ember", "power": 1},
		"high_roller": {"name": "Golden Bulwark", "effect": "mend", "combat": "mend", "element": "gilded", "power": 2},
		"chaos_croupier": {"name": "Wild Warp", "effect": "teleport", "combat": "chill", "element": "frost", "power": 1},
		"soul_banker": {"name": "Soul Siphon", "effect": "mend", "combat": "smite", "element": "void", "power": 1},
		"lucky_bard": {"name": "Fortune's Tune", "effect": "luck_buff", "combat": "fortune", "element": "verdant", "power": 1, "aoe": true},
	}
	var m: Dictionary = presets.get(class_id, presets.cardsharp).duplicate(true)
	m.rarity = Db.Rarity.UNCOMMON
	m.charges = 8
	m.cursed = false
	return m
