extends SceneTree
## Headless generator: writes the full roster of .bbmodel files (Blockbench's
## native JSON) into res://art/models/. Run:
##   godot --headless --script res://tools/gen_models.gd
##
## Conventions:
##  - 1 Blockbench unit = 1/16 m in-game (ModelDb divides by 16).
##  - Element names carry their tint as "part|#RRGGBB" — ModelDb parses it,
##    Blockbench shows plain geometry (texture/paint there as a later pass).
##  - Models stand on y=0, face -Z.

var made := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://art/models")
	_all_models()
	print("gen_models: wrote %d models to art/models/" % made)
	quit(0)


func _box(pname: String, hex: String, from: Array, to: Array) -> Dictionary:
	return {"name": "%s|%s" % [pname, hex], "box_uv": false, "rescale": false,
		"locked": false, "from": from, "to": to, "autouv": 0, "color": 0,
		"origin": [0, 0, 0], "uuid": _uuid(),
		"faces": {"north": {"uv": [0, 0, 1, 1], "texture": null},
			"east": {"uv": [0, 0, 1, 1], "texture": null},
			"south": {"uv": [0, 0, 1, 1], "texture": null},
			"west": {"uv": [0, 0, 1, 1], "texture": null},
			"up": {"uv": [0, 0, 1, 1], "texture": null},
			"down": {"uv": [0, 0, 1, 1], "texture": null}}}


func _uuid() -> String:
	return "%08x-%04x-%04x-%04x-%012x" % [randi(), randi() % 0xFFFF,
		randi() % 0xFFFF, randi() % 0xFFFF, randi() % 0xFFFFFFFF]


func _write(name: String, elements: Array) -> void:
	var model := {"meta": {"format_version": "4.5", "model_format": "free", "box_uv": false},
		"name": name, "model_identifier": name, "elements": elements,
		"outliner": elements.map(func(e): return e.uuid), "textures": []}
	var f := FileAccess.open("res://art/models/%s.bbmodel" % name, FileAccess.WRITE)
	f.store_string(JSON.stringify(model))
	f.close()
	made += 1


# ---------------------------------------------------------------- archetypes

## Humanoid: p = {skin, torso, legs, accent}; opts: crown, hood, big
func _humanoid(name: String, p: Dictionary, opts := {}) -> void:
	var s: float = 1.5 if opts.get("big", false) else 1.0
	var e := []
	e.append(_box("legL", p.legs, [-3.5 * s, 0, -1.5 * s], [-0.5 * s, 7 * s, 1.5 * s]))
	e.append(_box("legR", p.legs, [0.5 * s, 0, -1.5 * s], [3.5 * s, 7 * s, 1.5 * s]))
	e.append(_box("torso", p.torso, [-4 * s, 7 * s, -2 * s], [4 * s, 15 * s, 2 * s]))
	e.append(_box("armL", p.torso, [-6.5 * s, 7 * s, -1.5 * s], [-4 * s, 14.5 * s, 1.5 * s]))
	e.append(_box("armR", p.torso, [4 * s, 7 * s, -1.5 * s], [6.5 * s, 14.5 * s, 1.5 * s]))
	e.append(_box("head", p.skin, [-3 * s, 15 * s, -3 * s], [3 * s, 21 * s, 3 * s]))
	e.append(_box("belt", p.accent, [-4 * s, 7 * s, -2.2 * s], [4 * s, 9 * s, 2.2 * s]))
	if opts.get("hood", false):
		e.append(_box("hood", p.accent, [-3.5 * s, 17 * s, -3.5 * s], [3.5 * s, 22 * s, 3.5 * s]))
	if opts.get("crown", false):
		e.append(_box("crown", "#f5c542", [-3.2 * s, 21 * s, -3.2 * s], [3.2 * s, 23 * s, 3.2 * s]))
	_write(name, e)


func _quadruped(name: String, body: String, accent: String, s := 1.0) -> void:
	var e := []
	for lx in [-4.0, 2.0]:
		for lz in [-4.0, 3.0]:
			e.append(_box("leg", accent, [lx * s, 0, lz * s], [(lx + 2) * s, 4 * s, (lz + 2) * s]))
	e.append(_box("body", body, [-5 * s, 4 * s, -6 * s], [5 * s, 10 * s, 6 * s]))
	e.append(_box("head", body, [-3 * s, 6 * s, -10 * s], [3 * s, 11 * s, -6 * s]))
	e.append(_box("snout", accent, [-1.5 * s, 6 * s, -12 * s], [1.5 * s, 8.5 * s, -10 * s]))
	_write(name, e)


func _blob(name: String, hex: String, accent: String, s := 1.0) -> void:
	_write(name, [
		_box("base", hex, [-6 * s, 0, -6 * s], [6 * s, 5 * s, 6 * s]),
		_box("mid", hex, [-4.5 * s, 5 * s, -4.5 * s], [4.5 * s, 8.5 * s, 4.5 * s]),
		_box("top", accent, [-2.5 * s, 8.5 * s, -2.5 * s], [2.5 * s, 10.5 * s, 2.5 * s])])


func _wisp(name: String, hex: String, accent: String) -> void:
	_write(name, [
		_box("tail", hex, [-2, 0, -2], [2, 6, 2]),
		_box("body", hex, [-4, 6, -3], [4, 16, 3]),
		_box("head", accent, [-3, 16, -3], [3, 22, 3]),
		_box("eyeL", "#ff4033", [-2, 18, -3.4], [-1, 19, -3]),
		_box("eyeR", "#ff4033", [1, 18, -3.4], [2, 19, -3])])


func _weapon(name: String, blade_hex: String, blade_len: int, wide := 1.5) -> void:
	_write(name, [
		_box("grip", "#4a3320", [-0.8, 0, -0.8], [0.8, 5, 0.8]),
		_box("guard", "#7a6a50", [-2.5, 5, -1], [2.5, 6.5, 1]),
		_box("blade", blade_hex, [-wide, 6.5, -0.5], [wide, 6.5 + blade_len, 0.5])])


func _bow(name: String, wood_hex: String) -> void:
	_write(name, [
		_box("limbT", wood_hex, [-1, 10, -1], [1, 18, 1]),
		_box("mid", wood_hex, [-1.2, 6, -1.2], [1.2, 10, 1.2]),
		_box("limbB", wood_hex, [-1, -2, -1], [1, 6, 1]),
		_box("string", "#ddd8c8", [-0.2, -2, 1], [0.2, 18, 1.4])])


func _tool(name: String, head_hex: String, rod := false) -> void:
	var e := [_box("handle", "#4a3320", [-0.7, 0, -0.7], [0.7, 14, 0.7])]
	if rod:
		e.append(_box("tip", head_hex, [-0.5, 14, -0.5], [0.5, 22, 0.5]))
		e.append(_box("bobber", "#e04040", [-1, 8, 6], [1, 10, 8]))
		e.append(_box("line", "#ddd8c8", [-0.1, 9, 0.7], [0.1, 22, 7]))
	else:
		e.append(_box("head", head_hex, [-5, 13, -1], [5, 16, 1]))
	_write(name, e)


func _prop_writer() -> void:
	# Campfire
	_write("prop_campfire", [
		_box("logA", "#6b4a26", [-7, 0, -2], [7, 2, 2]),
		_box("logB", "#5d3f20", [-2, 0, -7], [2, 2, 7]),
		_box("flame", "#ff8c1a", [-2.5, 2, -2.5], [2.5, 8, 2.5]),
		_box("flame2", "#ffd23e", [-1.2, 6, -1.2], [1.2, 11, 1.2])])
	_write("prop_waystone", [
		_box("base", "#5b6a7a", [-5, 0, -5], [5, 3, 5]),
		_box("pillar", "#7c93ad", [-3, 3, -3], [3, 18, 3]),
		_box("gem", "#8cc0f5", [-1.5, 18, -1.5], [1.5, 22, 1.5])])
	_write("prop_anvil", [
		_box("base", "#3a3a42", [-4, 0, -3], [4, 4, 3]),
		_box("neck", "#4a4a55", [-2.5, 4, -2], [2.5, 7, 2]),
		_box("face", "#5a5a68", [-7, 7, -2.5], [7, 10, 2.5]),
		_box("horn", "#5a5a68", [7, 7.5, -1.5], [11, 9.5, 1.5])])
	_write("prop_altar", [
		_box("base", "#3a2a55", [-5, 0, -5], [5, 8, 5]),
		_box("top", "#54407a", [-6, 8, -6], [6, 10, 6]),
		_box("crystal", "#b07af5", [-1.5, 10, -1.5], [1.5, 16, 1.5])])
	_write("prop_cauldron", [
		_box("legs", "#2a2a30", [-4, 0, -4], [4, 3, 4]),
		_box("pot", "#3a3a44", [-5.5, 3, -5.5], [5.5, 10, 5.5]),
		_box("brew", "#33b3a6", [-4.5, 9, -4.5], [4.5, 10.5, 4.5])])
	_write("prop_rune_forge", [
		_box("base", "#4a3a66", [-6, 0, -4], [6, 8, 4]),
		_box("slab", "#8c46d9", [-7, 8, -5], [7, 10, 5]),
		_box("rune", "#c88cff", [-2, 10, -2], [2, 11, 2])])
	_write("prop_skill_forge", [
		_box("base", "#663a3a", [-6, 0, -4], [6, 8, 4]),
		_box("slab", "#d95946", [-7, 8, -5], [7, 10, 5])])
	_write("prop_trading_post", [
		_box("counter", "#6b4a26", [-8, 0, -3], [8, 8, 3]),
		_box("top", "#8a6236", [-9, 8, -4], [9, 10, 4]),
		_box("coin", "#f5c542", [-1.5, 10, -1], [1.5, 12, 1])])
	for cname in [["prop_chest", "#b3742a"], ["prop_chest_trapped", "#ad6e26"], ["prop_chest_store", "#996b33"]]:
		_write(cname[0], [
			_box("body", cname[1], [-6, 0, -4], [6, 6, 4]),
			_box("lid", cname[1], [-6, 6, -4], [6, 9, 4]),
			_box("latch", "#f5c542", [-1, 4.5, -4.6], [1, 7, -4])])
	_write("prop_door", [
		_box("panel", "#8a5c33", [-6, 0, -1], [6, 22, 1]),
		_box("knob", "#f5c542", [3.5, 10, -1.8], [5, 11.5, -1])])
	_write("prop_portal", [
		_box("baseL", "#2a1a3f", [-8, 0, -2], [-5, 20, 2]),
		_box("baseR", "#2a1a3f", [5, 0, -2], [8, 20, 2]),
		_box("lintel", "#2a1a3f", [-8, 20, -2], [8, 23, 2]),
		_box("veil", "#66e6f2", [-5, 0, -0.5], [5, 20, 0.5])])
	_write("prop_crusher_plate", [
		_box("plate", "#55525e", [-8, 4, -8], [8, 6, 8]),
		_box("s1", "#9a97a6", [-6, 0, -6], [-4, 4, -4]),
		_box("s2", "#9a97a6", [4, 0, -6], [6, 4, -4]),
		_box("s3", "#9a97a6", [-6, 0, 4], [-4, 4, 6]),
		_box("s4", "#9a97a6", [4, 0, 4], [6, 4, 6]),
		_box("s5", "#9a97a6", [-1, 0, -1], [1, 4, 1])])
	_write("prop_dart_hole", [
		_box("face", "#403a4d", [-8, 0, -1], [8, 16, 1]),
		_box("hole", "#0a0a0f", [-2, 6, -1.5], [2, 10, -1])])


func _item_writer() -> void:
	for b in [["item_potion_round", "#9a4de0"], ["item_potion_tall", "#33b3a6"], ["item_potion_flask", "#e04040"]]:
		_write(b[0], [
			_box("body", b[1], [-2.5, 0, -2.5], [2.5, 5, 2.5]),
			_box("neck", "#cfd8dc", [-1, 5, -1], [1, 8, 1]),
			_box("cork", "#8a5c33", [-1.2, 8, -1.2], [1.2, 9.5, 1.2])])
	_write("item_tome", [
		_box("cover", "#5b2d8f", [-4, 0, -5], [4, 2, 5]),
		_box("pages", "#e8e2d0", [-3.5, 2, -4.5], [3.5, 3, 4.5]),
		_box("clasp", "#f5c542", [3, 0.5, -1], [4.5, 2.5, 1])])
	_write("item_scroll", [
		_box("roll", "#e8e2d0", [-1.5, 0, -5], [1.5, 3, 5]),
		_box("bandA", "#b3742a", [-1.8, 0.5, -4], [1.8, 2.5, -3])])
	_write("item_rune", [
		_box("tile", "#6b7280", [-3, 0, -4], [3, 1.5, 4]),
		_box("glyph", "#ff5533", [-1.5, 1.5, -2.5], [1.5, 2.2, 2.5])])
	_write("item_sigil", [
		_box("card", "#d8d3e8", [-3, 0, -4.5], [3, 0.8, 4.5]),
		_box("mark", "#8c46d9", [-1.8, 0.8, -3], [1.8, 1.4, 3])])
	_write("item_essence", [
		_box("shardA", "#7ad0f5", [-1.5, 0, -1.5], [1.5, 7, 1.5]),
		_box("shardB", "#a8e2ff", [0.5, 2, 0.5], [3, 6, 3])])
	_write("item_cache", [
		_box("body", "#f5b83d", [-4, 0, -4], [4, 7, 4]),
		_box("band", "#8a5c33", [-4.3, 3, -4.3], [4.3, 4.5, 4.3])])
	_write("item_key", [
		_box("shaft", "#f5c542", [-0.7, 0, -0.7], [0.7, 8, 0.7]),
		_box("bow", "#f5c542", [-2.5, 8, -0.7], [2.5, 12, 0.7]),
		_box("teeth", "#f5c542", [0.7, 1, -0.7], [3, 2.5, 0.7])])
	_write("item_ingot", [
		_box("bar", "#c8ccd6", [-4, 0, -2], [4, 2.5, 2])])
	var fish_cols := {"gloomfin": "#66808f", "silver_darter": "#bfc9e0",
		"gilded_carp": "#f2cc4d", "void_eel": "#4d2673", "luckfish": "#4de599"}
	for fid in fish_cols:
		_write("item_fish_%s" % fid, [
			_box("body", fish_cols[fid], [-2, 0, -5], [2, 4, 3]),
			_box("tail", fish_cols[fid], [-1, 0.5, 3], [1, 3.5, 6]),
			_box("eye", "#111318", [-2.3, 2.5, -4], [-1.8, 3.1, -3.4])])
	_write("item_meat", [
		_box("cut", "#d97862", [-3, 0, -4], [3, 3, 4]),
		_box("fat", "#f0e3d8", [-3, 3, -4], [3, 4, 4])])
	_write("item_bomb", [
		_box("flask", "#3d4a33", [-2.5, 0, -2.5], [2.5, 5, 2.5]),
		_box("fuse", "#e8b04d", [-0.5, 5, -0.5], [0.5, 8, 0.5])])


func _fx_writer() -> void:
	_write("fx_arrow", [
		_box("shaft", "#8a6236", [-0.3, 0, -6], [0.3, 0.6, 6]),
		_box("headfx", "#c8ccd6", [-0.8, -0.2, -8], [0.8, 0.8, -6]),
		_box("fletch", "#e04040", [-1, -0.3, 4.5], [1, 0.9, 6])])
	_write("fx_smoke_puff", [
		_box("a", "#585862", [-4, 0, -4], [4, 6, 4]),
		_box("b", "#6a6a75", [-2.5, 5, -2.5], [2.5, 9, 2.5])])
	_write("fx_explosion", [
		_box("core", "#ffd23e", [-3, 0, -3], [3, 6, 3]),
		_box("burstX", "#ff8c1a", [-7, 2, -1], [7, 4, 1]),
		_box("burstZ", "#ff8c1a", [-1, 2, -7], [1, 4, 7])])
	_write("fx_beam", [
		_box("beam", "#fff2b3", [-1.5, 0, -1.5], [1.5, 24, 1.5])])
	_write("fx_gas_cloud", [
		_box("a", "#79b356", [-5, 0, -5], [5, 5, 5]),
		_box("b", "#8cc46a", [-3, 4, -3], [3, 8, 3])])


func _all_models() -> void:
	# --- player classes (id-matched: class_<id>)
	_humanoid("class_cardsharp", {"skin": "#d9b38c", "torso": "#5b2d8f", "legs": "#2d2d3a", "accent": "#8c46d9"}, {"hood": true})
	_humanoid("class_rune_dealer", {"skin": "#d9b38c", "torso": "#2d4d8f", "legs": "#333344", "accent": "#66a3e0"})
	_humanoid("class_high_roller", {"skin": "#d9b38c", "torso": "#f2cc4d", "legs": "#8a6236", "accent": "#f5e6b3"})
	_humanoid("class_chaos_croupier", {"skin": "#e0c4a0", "torso": "#b32d50", "legs": "#33222c", "accent": "#ff5c8a"})
	_humanoid("class_soul_banker", {"skin": "#c4b8c9", "torso": "#4a4a58", "legs": "#2a2a33", "accent": "#8f8fa3"})
	_humanoid("class_lucky_bard", {"skin": "#d9b38c", "torso": "#33a877", "legs": "#2d4436", "accent": "#4de599"})
	# --- hostiles (id-matched: mob_<type>)
	_quadruped("mob_gloom_rat", "#6e6478", "#4d4657", 0.6)
	_humanoid("mob_rattlebone", {"skin": "#d8d3c2", "torso": "#c9c4b2", "legs": "#b8b3a2", "accent": "#8a8577"})
	_humanoid("mob_cave_imp", {"skin": "#cc4d33", "torso": "#a63d28", "legs": "#7a2d1e", "accent": "#f2a30f"})
	_blob("mob_gloom_slime", "#734da6", "#9a70cc", 0.9)
	_humanoid("mob_dice_golem", {"skin": "#e8e8f0", "torso": "#d8d8e4", "legs": "#c4c4d4", "accent": "#333344"}, {"big": true})
	_write("mob_coin_bat", [
		_box("body", "#b3924d", [-2, 8, -2], [2, 12, 2]),
		_box("wingL", "#8f7433", [-8, 9, -1], [-2, 12, 0]),
		_box("wingR", "#8f7433", [2, 9, -1], [8, 12, 0]),
		_box("eyeL", "#ff4033", [-1.5, 10.5, -2.4], [-0.7, 11.3, -2])])
	_write("mob_mimic", [
		_box("body", "#b3742a", [-6, 0, -4], [6, 6, 4]),
		_box("lid", "#ad6e26", [-6, 7, -4], [6, 10, 4]),
		_box("teethT", "#f0ead8", [-5, 6, -4.2], [5, 7.2, -3.4]),
		_box("tongue", "#cc3355", [-2, 5.4, -5], [2, 6.4, -3])])
	_wisp("mob_vault_wraith", "#6f94ad", "#9dc4dd")
	_humanoid("mob_cursed_croupier", {"skin": "#b39dbf", "torso": "#7a2d4d", "legs": "#3a1a2a", "accent": "#cc3366"}, {"hood": true})
	_wisp("mob_tomb_howler", "#544d66", "#7a7394")
	_humanoid("mob_obsidian_brute", {"skin": "#33224d", "torso": "#291a3d", "legs": "#1f1430", "accent": "#8c46d9"}, {"big": true})
	_humanoid("mob_chameleon_stalker", {"skin": "#7d947d", "torso": "#69805f", "legs": "#556b4c", "accent": "#9ab38f"})
	_wisp("mob_gloom_ghost", "#c2d5e5", "#e2eef7")
	_humanoid("mob_bandit", {"skin": "#d9b38c", "torso": "#8a4d3d", "legs": "#4d332a", "accent": "#33222c"}, {"hood": true})
	# --- oozes
	_write("mob_acid_cube", [
		_box("cube", "#8ce599", [-8, 0, -8], [8, 16, 8]),
		_box("boneA", "#e8e2d0", [-3, 4, -2], [-1, 9, 0]),
		_box("boneB", "#d8d3c2", [2, 7, 1], [4, 10, 3])])
	_blob("mob_black_pudding", "#1a141f", "#2d2438", 1.15)
	_blob("mob_ochre_jelly", "#cc9933", "#e0b34d", 1.0)
	_blob("mob_ochre_jelly_lesser", "#cc9933", "#e0b34d", 0.55)
	# --- bosses
	_humanoid("boss_pit_boss", {"skin": "#e0c4a0", "torso": "#b3242e", "legs": "#33141a", "accent": "#f5c542"}, {"big": true, "crown": true})
	_humanoid("boss_drowned_king", {"skin": "#7fa3a8", "torso": "#3d6b73", "legs": "#294d54", "accent": "#66e6f2"}, {"big": true, "crown": true})
	_blob("boss_spore_tyrant", "#8f5e9e", "#c288d4", 2.0)
	_humanoid("boss_crypt_lich", {"skin": "#d8d3c2", "torso": "#3a2a55", "legs": "#291f3d", "accent": "#8c46d9"}, {"big": true, "hood": true})
	_humanoid("boss_adamant_colossus", {"skin": "#4de5b8", "torso": "#33997a", "legs": "#26735c", "accent": "#7affda"}, {"big": true})
	# --- neutrals & passives
	_humanoid("mob_villager", {"skin": "#d9b38c", "torso": "#8f8266", "legs": "#5c5443", "accent": "#b3a380"})
	_humanoid("mob_town_guardian", {"skin": "#d9b38c", "torso": "#4d6b99", "legs": "#33475e", "accent": "#8cb3e0"}, {"big": true})
	_humanoid("mob_lost_explorer", {"skin": "#d9b38c", "torso": "#5e7a66", "legs": "#3d5244", "accent": "#8fb399"}, {"hood": true})
	_quadruped("mob_gloom_hog", "#8f7080", "#6e5563", 1.0)
	_write("mob_luck_toad", [
		_box("body", "#66cc5c", [-4, 0, -4], [4, 5, 4]),
		_box("head", "#79d970", [-3, 5, -5], [3, 9, 1]),
		_box("eyeL", "#111318", [-2.5, 8, -5.4], [-1.5, 9, -4.6]),
		_box("eyeR", "#111318", [1.5, 8, -5.4], [2.5, 9, -4.6])])
	_write("mob_dust_moth", [
		_box("body", "#d9d3b8", [-1.5, 6, -3], [1.5, 9, 3]),
		_box("wingL", "#efe9d0", [-7, 7, -2], [-1.5, 8, 2]),
		_box("wingR", "#efe9d0", [1.5, 7, -2], [7, 8, 2])])
	# --- weapons
	_weapon("weapon_blade_rusty", "#8f8577", 10)
	_weapon("weapon_blade_copper", "#cc8050", 11)
	_weapon("weapon_blade_iron", "#a6a6b3", 12)
	_weapon("weapon_blade_silver", "#dde2f0", 12, 1.2)
	_weapon("weapon_blade_gilded", "#f2cc4d", 12)
	_weapon("weapon_blade_mythril", "#80d9f2", 14, 1.8)
	_weapon("weapon_blade_adamant", "#4de5b8", 16, 2.0)
	_weapon("weapon_maul_bone", "#e8e2d0", 6, 3.5)
	_bow("weapon_bow_short", "#8a6236")
	_bow("weapon_bow_gilded", "#d9a940")
	_bow("weapon_bow_ironwood", "#59503c")
	# --- tools
	_tool("tool_pick_rusty", "#8f8577")
	_tool("tool_pick_gilded", "#f2cc4d")
	_tool("tool_pick_mythril", "#80d9f2")
	_tool("tool_pole_wood", "#8a6236", true)
	_tool("tool_pole_gilded", "#d9a940", true)
	_tool("tool_pole_mythril", "#80d9f2", true)
	# --- props / items / fx
	_prop_writer()
	_item_writer()
	_fx_writer()
