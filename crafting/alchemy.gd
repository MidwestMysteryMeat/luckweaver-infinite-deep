class_name Alchemy
extends RefCounted
## Elder-Scrolls-style brewing: properties shared by ≥2 ingredients become the
## potion's effects. Potency scales with ingredient tiers.
## potion meta = {name, rarity, effects: [{prop, potency}], throwable}

const PROP_NAMES := {
	"heal": "Mending", "luck": "Luck", "volatile": "Volatile",
	"stone": "Stoneblood", "swift": "Quickstep", "toxic": "Risk",
	"gills": "Tidecaller", "smoke": "Smokeshroud",
}


## skill = the brewer's effective Alchemy level: more potency.
static func brew(ingredient_ids: Array, rng: RandomNumberGenerator, skill := 1) -> Dictionary:
	var counts := {}
	var potency := skill / 5
	for id in ingredient_ids:
		var def: Dictionary = Db.ITEMS[id]
		potency += int(def.tier)
		for p in def.props:
			counts[p] = counts.get(p, 0) + 1
	var effects: Array = []
	for p in counts:
		if counts[p] >= 2:
			effects.append({"prop": p, "potency": potency})
	if effects.is_empty():
		# Murky Sludge: a weak random effect from what went in.
		var pool: Array = counts.keys()
		effects.append({"prop": pool[rng.randi_range(0, pool.size() - 1)], "potency": 1})
		return {"name": "Murky Sludge", "rarity": Db.Rarity.COMMON,
			"effects": effects, "throwable": false}

	# Bombs & flasks: volatile explodes, smoke shrouds, toxic gasses — all
	# thrown. Anything else is a drinkable elixir.
	var throwable := false
	var bomb_word := ""
	var parts: Array = []
	for e in effects:
		parts.append(PROP_NAMES[e.prop])
		match String(e.prop):
			"volatile":
				throwable = true
				bomb_word = "Blast Flask"
			"smoke":
				throwable = true
				if bomb_word == "":
					bomb_word = "Smoke Bomb"
			"toxic":
				if bomb_word == "":
					bomb_word = "Gas Flask"
	var name := "%s Elixir" % " & ".join(parts)
	if throwable or bomb_word != "":
		throwable = true
		name = "%s (%s)" % [bomb_word, " & ".join(parts)]
	var rarity := Db.Rarity.COMMON
	if potency >= 8:
		rarity = Db.Rarity.EPIC
	elif potency >= 6:
		rarity = Db.Rarity.RARE
	elif potency >= 4:
		rarity = Db.Rarity.UNCOMMON
	return {"name": name, "rarity": rarity, "effects": effects, "throwable": throwable}
