class_name SkillForge
extends RefCounted
## Skill crafting: merge two skills (or spells) into one skill whose passives
## are the amplified union of both. skill meta = {name, rarity, passives: {}}
##
## Passive keys: mine_speed (multiplier), luck_dig, insight, reroll,
## bounty (0-1 gold bonus), loot_bonus (0-1), soul_strike (crit bonus).

## Spells contribute a passive flavored by their combat trick.
const SPELL_PASSIVE := {
	"smite": {"soul_strike": 0.5},
	"chill": {"reroll": 1.0},
	"mend": {"luck_dig": 1.0},
	"hex": {"insight": 1.0},
	"fortune": {"luck_dig": 1.0},
}


static func merge(meta_a: Dictionary, meta_b: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var pa := _passives_of(meta_a)
	var pb := _passives_of(meta_b)
	var merged := {}
	for k in pa:
		merged[k] = float(pa[k])
	for k in pb:
		if merged.has(k):
			merged[k] = maxf(merged[k], float(pb[k])) * 1.15
		else:
			merged[k] = float(pb[k])
	# Cap runaway stacking.
	if merged.has("bounty"):
		merged.bounty = minf(merged.bounty, 0.6)
	if merged.has("loot_bonus"):
		merged.loot_bonus = minf(merged.loot_bonus, 1.0)

	var name := _mash_name(String(meta_a.get("name", "Skill")), String(meta_b.get("name", "Skill")), rng)
	# The showcase combo: mining prowess fused with fate.
	if merged.has("mine_speed") and (merged.has("luck_dig") or merged.has("reroll")):
		name = "Fatedelver's Drill"
	var rarity: int = maxi(int(meta_a.get("rarity", 0)), int(meta_b.get("rarity", 0)))
	rarity = mini(rarity + 1, Db.Rarity.MYTHIC)
	return {"name": name, "rarity": rarity, "passives": merged}


static func _passives_of(meta: Dictionary) -> Dictionary:
	if meta.has("passives"):
		return meta.passives
	# It's a spell: derive a passive from its combat effect.
	return SPELL_PASSIVE.get(String(meta.get("combat", "fortune")), {"luck_dig": 1.0})


static func _mash_name(a: String, b: String, rng: RandomNumberGenerator) -> String:
	var wa: PackedStringArray = a.split(" ")
	var wb: PackedStringArray = b.split(" ")
	var first := String(wa[0])
	var last := String(wb[wb.size() - 1])
	if first == last:
		last = ["Gambit", "Fortune", "Hustle"][rng.randi_range(0, 2)]
	return "%s %s" % [first, last]
