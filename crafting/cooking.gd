class_name Cooking
extends RefCounted
## Campfire cooking — alchemy's warm cousin. Combine 2-3 ingredients that have
## "food" props; props shared by ≥2 ingredients become the meal's effects.
## Meals are FEASTS: everyone near the fire when the pot comes off shares the
## buffs. Rich meals (high total tier) can grant small PERMANENT boosts.
##
## Food props: hearty (regen + temp max vigor), strength (+atk), iron (+AC),
## fortune (+luck). meal meta = {name, rarity, effects, perm: {stat: amt}}

const PROP_NAMES := {
	"hearty": "Hearty", "strength": "Ironblood", "iron": "Stoneskin", "fortune": "Lucky",
}
## Permanent boost per prop when the meal turns out exceptional.
const PERM := {
	"hearty": {"stat": "max_hp", "amt": 2, "txt": "+2 max HP, forever"},
	"strength": {"stat": "atk_perm", "amt": 1, "txt": "+1 attack, forever"},
	"iron": {"stat": "ac_perm", "amt": 1, "txt": "+1 AC, forever"},
	"fortune": {"stat": "luck", "amt": 1, "txt": "+1 luck, forever"},
}


## skill = the cook's effective Cooking level: more potency, better perm odds.
static func cook(ingredient_ids: Array, rng: RandomNumberGenerator, skill := 1) -> Dictionary:
	var counts := {}
	var potency := skill / 5
	for id in ingredient_ids:
		var def: Dictionary = Db.ITEMS[id]
		potency += int(def.tier)
		for p in def.get("food", []):
			counts[p] = counts.get(p, 0) + 1
	var effects: Array = []
	for p in counts:
		if counts[p] >= 2:
			effects.append({"prop": p, "potency": potency})
	if effects.is_empty():
		return {"name": "Charred Mess", "rarity": Db.Rarity.COMMON,
			"effects": [{"prop": "hearty", "potency": 1}], "perm": {}}

	var parts: Array = []
	for e in effects:
		parts.append(PROP_NAMES[e.prop])
	var name := "%s Stew" % " ".join(parts)
	var rarity := Db.Rarity.COMMON
	if potency >= 6:
		rarity = Db.Rarity.RARE
	elif potency >= 4:
		rarity = Db.Rarity.UNCOMMON

	# Exceptional meals bake a permanent boost from their strongest prop.
	var perm := {}
	if potency >= 6 and rng.randf() < 0.3 + skill * 0.004:
		var top: String = effects[0].prop
		perm = PERM[top].duplicate()
		name = "Legendary " + name
		rarity = Db.Rarity.MYTHIC
	return {"name": name, "rarity": rarity, "effects": effects, "perm": perm}


## Server-side: apply a cooked meal to one diner (buffs are 180s).
static func feed(g, pid: int, meal: Dictionary) -> void:
	var rec: Dictionary = g.players[pid]
	var now := Time.get_ticks_msec()
	for fx in meal.effects:
		var pot := int(fx.potency)
		match String(fx.prop):
			"hearty":
				rec.buffs.append({"k": "regen", "amt": 1, "until": now + 180000})
				rec.hp = mini(int(rec.hp) + pot * 4, int(rec.max_hp))
			"strength":
				rec.buffs.append({"k": "atk", "amt": 1 + pot / 3, "until": now + 180000})
			"iron":
				rec.buffs.append({"k": "ac", "amt": 1 + pot / 3, "until": now + 180000})
			"fortune":
				rec.buffs.append({"k": "luck", "amt": pot * 3, "until": now + 180000})
	var perm: Dictionary = meal.get("perm", {})
	if not perm.is_empty():
		match String(perm.stat):
			"max_hp":
				rec.max_hp += int(perm.amt)
				rec.hp += int(perm.amt)
			"atk_perm":
				rec.atk_perm = int(rec.get("atk_perm", 0)) + int(perm.amt)
			"ac_perm":
				rec.ac_perm = int(rec.get("ac_perm", 0)) + int(perm.amt)
			"luck":
				rec.luck += int(perm.amt)
		g.send_to(pid, "cl_notify", ["The meal changes you: %s" % perm.txt])
	g._sync_player(pid)
