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
	"drowned_king": "boss_drowned_king", "spore_tyrant": "boss_spore_tyrant",
	"crypt_lich": "boss_crypt_lich", "adamant_colossus": "boss_adamant_colossus",
	"bone_archer": "mob_rattlebone", "gloom_shaman": "mob_cursed_croupier",
	"acid_lobber": "mob_ochre_jelly", "frost_wisp": "mob_vault_wraith",
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


## Model for an inventory entry (held items, world drops); null = no model.
static func item_model(entry: Dictionary) -> Node3D:
	var id := String(entry.get("id", ""))
	var meta: Dictionary = entry.get("meta", {})
	var file := ""
	if id.begins_with("blade_") or id.begins_with("maul_") or id.begins_with("bow_"):
		file = "weapon_" + id
	elif id.begins_with("pick_") or id.begins_with("pole_"):
		file = "tool_" + id
	elif id.begins_with("rune_"):
		file = "item_rune"
	elif id.begins_with("card_"):
		file = "item_sigil"
	elif id.begins_with("ess_"):
		file = "item_essence"
	elif id.ends_with("_ingot"):
		file = "item_ingot"
	elif id == "fish_live":
		file = "item_fish_" + String(meta.get("species", "gloomfin"))
	elif id in ["hog_meat", "fish_meat", "toad_leg"]:
		file = "item_meat"
	elif id == "potion":
		file = "item_bomb" if meta.get("throwable", false) else "item_potion_round"
	elif id == "spell":
		file = "item_tome"
	elif id == "skill":
		file = "item_scroll"
	elif id == "gambit_cache":
		file = "item_cache"
	elif id == "golden_key":
		file = "item_key"
	if file == "":
		return null
	return load_model("res://art/models/%s.bbmodel" % file, 1.0)


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
	# Textured path (Minecraft-style): embedded palette PNG + face UVs.
	var texs: Array = parsed.get("textures", [])
	if not texs.is_empty():
		var src := String(texs[0].get("source", ""))
		if src.begins_with("data:image/png;base64,"):
			var img := Image.new()
			if img.load_png_from_buffer(Marshalls.base64_to_raw(src.substr(22))) == OK:
				return _build_textured(parsed, ImageTexture.create_from_image(img), alpha)

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


const _DIRS := {
	"up": [Vector3(0, 1, 0), [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]],
	"down": [Vector3(0, -1, 0), [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0)]],
	"east": [Vector3(1, 0, 0), [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)]],
	"west": [Vector3(-1, 0, 0), [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(0, 0, 1)]],
	"south": [Vector3(0, 0, 1), [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 0, 1)]],
	"north": [Vector3(0, 0, -1), [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]],
}


## One ArrayMesh for the whole model, UV-mapped into the embedded palette
## texture (nearest filtering = crisp pixels).
static func _build_textured(parsed: Dictionary, tex: ImageTexture, alpha: float) -> Node3D:
	var res_w := float(parsed.get("resolution", {}).get("width", 32))
	var res_h := float(parsed.get("resolution", {}).get("height", 32))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for el in parsed.get("elements", []):
		var mn := Vector3(float(el.from[0]), float(el.from[1]), float(el.from[2])) / 16.0
		var mx := Vector3(float(el.to[0]), float(el.to[1]), float(el.to[2])) / 16.0
		var sz := mx - mn
		if sz.length() < 0.001:
			continue
		var faces: Dictionary = el.get("faces", {})
		for dir in _DIRS:
			var fd: Dictionary = faces.get(dir, {})
			var uv: Array = fd.get("uv", [0, 0, res_w, res_h])
			var u0 := float(uv[0]) / res_w
			var v0 := float(uv[1]) / res_h
			var u1 := float(uv[2]) / res_w
			var v1 := float(uv[3]) / res_h
			var fuv := [Vector2(u0, v1), Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1)]
			var base := verts.size()
			var corners: Array = _DIRS[dir][1]
			for vi in range(4):
				var c: Vector3 = corners[vi]
				verts.append(mn + c * sz)
				normals.append(_DIRS[dir][0])
				uvs.append(fuv[vi])
			indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1, 1, 1, alpha)
	mesh.surface_set_material(0, mat)
	var root := Node3D.new()
	root.name = "Model"
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)
	return root
