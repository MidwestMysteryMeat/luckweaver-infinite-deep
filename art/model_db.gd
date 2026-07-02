class_name ModelDb
extends RefCounted
## Loads Blockbench .bbmodel files (native JSON) at runtime into Node3D box
## meshes. Element names carry tint as "part|#RRGGBB" (our generator's
## convention — repaint freely in Blockbench, the geometry is what matters).
## 1 Blockbench unit = 1/16 m. Anything unmodeled falls back to the old
## procedural capsules, so art can land piecemeal.

static var _cache := {}

## Mob type -> model file (art/models/<file>.bbmodel).
const MOBS := {
	"gloom_rat": "mob_gloom_rat", "rattlebone": "mob_rattlebone",
	"cave_imp": "mob_cave_imp", "gloom_slime": "mob_gloom_slime",
	"dice_golem": "mob_dice_golem", "coin_bat": "mob_coin_bat",
	"mimic": "mob_mimic", "vault_wraith": "mob_vault_wraith",
	"cursed_croupier": "mob_cursed_croupier", "tomb_howler": "mob_tomb_howler",
	"obsidian_brute": "mob_obsidian_brute", "chameleon_stalker": "mob_chameleon_stalker",
	"gloom_ghost": "mob_gloom_ghost", "bandit": "mob_bandit",
	"acid_cube": "mob_acid_cube", "black_pudding": "mob_black_pudding",
	"ochre_jelly": "mob_ochre_jelly", "pit_boss": "boss_pit_boss",
	"villager": "mob_villager", "town_guardian": "mob_town_guardian",
	"lost_explorer": "mob_lost_explorer", "refuge_citizen": "mob_villager",
	"gloom_hog": "mob_gloom_hog", "luck_toad": "mob_luck_toad",
	"dust_moth": "mob_dust_moth",
}


static func mob(type: String, alpha := 1.0) -> Node3D:
	if not MOBS.has(type):
		return null
	return load_model("res://art/models/%s.bbmodel" % MOBS[type], alpha)


static func class_model(class_id: String) -> Node3D:
	return load_model("res://art/models/class_%s.bbmodel" % class_id, 1.0)


static func load_model(path: String, alpha := 1.0) -> Node3D:
	if not FileAccess.file_exists(path):
		return null
	var parsed: Variant = _cache.get(path)
	if parsed == null:
		var f := FileAccess.open(path, FileAccess.READ)
		parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) != TYPE_DICTIONARY:
			return null
		_cache[path] = parsed
	var root := Node3D.new()
	root.name = "Model"
	var mats := {}
	for el in parsed.get("elements", []):
		var from: Array = el.from
		var to: Array = el.to
		var size := Vector3(float(to[0]) - float(from[0]), float(to[1]) - float(from[1]),
			float(to[2]) - float(from[2])) / 16.0
		if size.length() < 0.001:
			continue
		var center := Vector3(float(from[0]) + float(to[0]), float(from[1]) + float(to[1]),
			float(from[2]) + float(to[2])) / 32.0
		var hex := "#c0c0c0"
		var nm := String(el.get("name", ""))
		var bar := nm.rfind("|")
		if bar >= 0:
			hex = nm.substr(bar + 1)
		if not mats.has(hex):
			var m := StandardMaterial3D.new()
			var col := Color(hex)
			col.a = alpha
			m.albedo_color = col
			m.emission_enabled = true
			m.emission = Color(hex) * 0.25
			if alpha < 1.0:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mats[hex] = m
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		mi.material_override = mats[hex]
		mi.position = center
		root.add_child(mi)
	return root
