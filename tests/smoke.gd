extends Node
## Headless smoke test for the INFINITE BIOME world: boot → spawn in the wild
## → determinism + infinity + biome checks → village discovery (waystone,
## benches, folk) → dungeon stamping → day/night → mine/place/doors/farm/
## cook/fluids/light → craft chain → depth bands → real-time combat (knockback,
## stolen-gold recovery) → fishing → storage/binding → death drops → save.
## Prints "SMOKE PASS" and exits 0.

var _fails := 0
var _st := {}


func _on_enc_state(s: Dictionary) -> void:
	_st = s


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok: %s" % what)
	else:
		_fails += 1
		printerr("  FAIL: %s" % what)


func _ready() -> void:
	print("[smoke] booting main scene...")
	if FileAccess.file_exists(SaveMgr.CHARACTER):
		DirAccess.remove_absolute(SaveMgr.CHARACTER)
	var main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	_run_test(main)


func _run_test(main) -> void:
	print("[smoke] solo host + start run (wilderness spawn)")
	Net.start_solo()
	main.show_lobby()
	Game.request_set_class("lucky_bard")
	Game.request_set_loot_rule("shared_gold")
	Game.request_start_run()
	# World build is sliced across frames now — wait for the spawn.
	var boot_wait := 0.0
	while boot_wait < 30.0:
		if Game.world != null and Game.world.get_player(1) != null:
			break
		await get_tree().create_timer(0.1).timeout
		boot_wait += 0.1
	_check(Game.in_run, "run started")
	var p = Game.world.get_player(1)
	_check(p != null, "player spawned")
	var sy := int(p.global_position.y)
	var sx := int(p.global_position.x)
	var sz := int(p.global_position.z)
	_check(Blocks.is_solid(Game.voxel.get_block(sx, sy - 1, sz)), "standing on solid wild ground")
	_check(_count_item("pick_rusty") == 0, "Minecraft rule: empty-handed start")
	_check(WorldGen.biome_name(Game.run_seed, sx, sz) != "", "spawn has a biome name")

	print("[smoke] INFINITE + deterministic generation")
	var far := Game.voxel.get_block(10000, 30, -8000)
	_check(far == Blocks.STONE or far == Blocks.AIR or Blocks.get_def(far).name != "",
		"world exists 10,000 blocks away (block id %d)" % far)
	_check(Game.voxel.get_block(10000, 0, -8000) == Blocks.BEDROCK, "bedrock floors the far world")
	var a := PackedByteArray()
	a.resize(16 * WorldGen.H * 16)
	var b := PackedByteArray()
	b.resize(16 * WorldGen.H * 16)
	WorldGen.fill_column(Game.run_seed, Vector2i(37, -12), a)
	WorldGen.fill_column(Game.run_seed, Vector2i(37, -12), b)
	_check(a == b, "same column generates bit-identical twice (multiplayer-safe)")
	var surf := WorldGen.surface_y(Game.run_seed, 300, 300)
	_check(Blocks.is_solid(Game.voxel.get_block(300, surf, 300)),
		"surface heightmap holds (ground at y=%d)" % surf)
	var biomes := {}
	for bx in range(0, 2400, 120):
		biomes[WorldGen.biome_at(Game.run_seed, bx, bx / 2)] = true
	_check(biomes.size() >= 2, "multiple biomes within 2,400 blocks (%d found)" % biomes.size())

	print("[smoke] village discovery: waystone, benches, folk")
	var vill := {}
	for vcx in range(-2, 3):
		for vcz in range(-2, 3):
			vill = WorldGen.village_in_cell(Game.run_seed, vcx, vcz)
			if not vill.is_empty():
				break
		if not vill.is_empty():
			break
	_check(not vill.is_empty(), "a village generates near spawn")
	if not vill.is_empty():
		var va: Vector2i = vill.anchor
		var enemies_pre: int = Game.enemies.size()
		p.teleport_to(Vector3(float(va.x) + 0.5, float(vill.ground) + 2.0, float(va.y) + 0.5))
		Game.voxel.stream_around([p.global_position])
		Game.voxel.flush_all()
		Game._server_discover_villages()
		_check(not Game.waystones.is_empty(), "village waystone registered on discovery")
		_check(not Game.camps.is_empty(), "village campfire registered as a camp")
		_check(Game.enemies.size() > enemies_pre, "village folk woke up (%s)" % vill.variant)
		_check(Game.voxel.get_block(va.x, int(vill.ground) + 1, va.y) == Blocks.WAYSTONE,
			"waystone block stamped into the world")

	print("[smoke] dungeons stamp into the deep")
	var dung := {}
	for dcx in range(-4, 5):
		for dcz in range(-4, 5):
			dung = WorldGen.dungeon_in_cell(Game.run_seed, dcx, dcz)
			if not dung.is_empty():
				break
		if not dung.is_empty():
			break
	_check(not dung.is_empty(), "a dungeon complex generates nearby")
	if not dung.is_empty():
		var danchor: Vector3i = dung.anchor
		var dblocks: Dictionary = dung.blocks
		var probe: Vector3i = dblocks.keys()[0]
		_check(Game.voxel.get_block_v(probe) == int(dblocks[probe]),
			"dungeon blocks present in the world (anchor y=%d)" % danchor.y)

	print("[smoke] day/night cycle")
	Game.world_time = Game.DAY_LEN * 0.25
	_check(not Game.is_night() and Game.daylight() > 0.9, "noon is bright")
	Game.world_time = Game.DAY_LEN * 0.75
	_check(Game.is_night(), "midnight is dark")
	Game.world_time = Game.DAY_LEN * 0.25
	# Back near the spawn point for the block-editing suite.
	p.teleport_to(Vector3(float(sx) + 0.5, float(sy), float(sz) + 0.5))

	print("[smoke] mining, placing, tool rules")
	# Biome terrain slopes and floods — probe the spawn ring for a solid,
	# breakable ground block that drops a placeable item instead of assuming
	# the old flat-world (+2, -1) offset is one.
	var bp := Vector3i(sx + 2, sy - 1, sz)
	var found_ground := false
	for dxz: Array in [[2, 0], [0, 2], [-2, 0], [0, -2], [2, 2], [-2, -2], [3, 0], [0, 3]]:
		for dy: int in [-1, -2, 0, -3]:
			var cand := Vector3i(sx + int(dxz[0]), sy + dy, sz + int(dxz[1]))
			var cid: int = Game.voxel.get_block_v(cand)
			if cid == Blocks.AIR or not Blocks.is_breakable(cid):
				continue
			var cdrop := String(Blocks.get_def(cid).get("drop", ""))
			if cdrop != "" and String(Db.item_def(cdrop).get("kind", "")) == "block":
				bp = cand
				found_ground = true
				break
		if found_ground:
			break
	_check(found_ground, "solid ground near spawn to mine")
	Game.request_break(bp)
	_check(Game.voxel.get_block_v(bp) == Blocks.AIR, "block broken + logged")
	var mined_slot := -1  # place back whatever the ground dropped
	var inv0: Array = Game.my_rec().get("inv", [])
	for i in range(inv0.size()):
		if inv0[i] != null and Db.item_def(inv0[i].id).kind == "block":
			mined_slot = i
			break
	_check(mined_slot >= 0, "mining dropped a placeable block")
	Game.request_place(bp, mined_slot)
	_check(Game.voxel.get_block_v(bp) != Blocks.AIR, "block placed back")
	_check(Game.edit_log.size() >= 2, "edits recorded in the world log")

	print("[smoke] doors, locks, magic breach")
	var dp := Vector3i(sx + 2, sy, sz + 2)
	# Spawn terrain varies with the run seed; make the interaction cell
	# deterministic instead of assuming this offset always starts as air.
	Game._apply_edit({"t": "set", "p": [dp.x, dp.y, dp.z], "b": Blocks.AIR})
	Game.give_item(1, "door", 1, {})
	Game.give_item(1, "golden_key", 1, {})
	Game.request_place(dp, _find_slot("door"))
	var dparr := [dp.x, dp.y, dp.z]
	Game.request_interact("door", dparr)
	_check(Game.voxel.get_block_v(dp) == Blocks.DOOR_OPEN, "door opens")
	Game.request_interact("door", dparr)
	Game.request_interact("door_lock", dparr)
	_check(Game.voxel.get_block_v(dp) == Blocks.DOOR_LOCKED, "golden key locks it")
	Game._apply_edit({"t": "sphere", "p": dparr, "r": 1.0, "b": 0})
	_check(Game.voxel.get_block_v(dp) == Blocks.AIR, "spells breach locked doors")

	print("[smoke] lighting: glowstone + skylight repair")
	var lp := Vector3i(sx - 4, maxi(sy - 3, 2), sz - 4)
	var light_neighbor := lp + Vector3i(1, 0, 0)
	# Build a tiny roofed cavity so the assertion is independent of randomly
	# generated leaves/terrain and measures block light rather than skylight.
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y + 1, lp.z], "b": Blocks.STONE})
	Game._apply_edit({"t": "set",
		"p": [light_neighbor.x, light_neighbor.y + 1, light_neighbor.z], "b": Blocks.STONE})
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": Blocks.AIR})
	Game._apply_edit({"t": "set", "p": [light_neighbor.x, light_neighbor.y, light_neighbor.z],
		"b": Blocks.AIR})
	var light_pre: int = Game.voxel.light_at(
		light_neighbor.x, light_neighbor.y, light_neighbor.z)
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": Blocks.GLOWSTONE})
	_check(Game.voxel.light_at(light_neighbor.x, light_neighbor.y, light_neighbor.z) >= 14,
		"glowstone lights neighbors")
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": 0})
	_check(Game.voxel.light_at(light_neighbor.x, light_neighbor.y, light_neighbor.z) >= light_pre - 1,
		"light repaired after the glowstone is mined")

	print("[smoke] farming on the town plot")
	var fp := Vector3i(sx - 3, sy, sz + 3)
	Game._apply_edit({"t": "set", "p": [fp.x, fp.y - 1, fp.z], "b": Blocks.DIRT})
	Game._apply_edit({"t": "set", "p": [fp.x, fp.y, fp.z], "b": 0})
	Game.give_item(1, "seeds", 2, {})
	Game.request_place(fp, _find_slot("seeds"))
	_check(Game.voxel.get_block_v(fp) == Blocks.CROP_1, "seeds planted on dirt")
	for i in range(60):
		Game._server_tick_crops()
		if Game.voxel.get_block_v(fp) == Blocks.CROP_RIPE:
			break
	_check(Game.voxel.get_block_v(fp) == Blocks.CROP_RIPE, "crop grew under the open sky")
	Game.request_break(fp)
	_check(_count_item("wheat") >= 1, "harvest yields wheat")

	print("[smoke] cooking feast at the town campfire")
	Game.give_item(1, "hog_meat", 1, {})
	Game.give_item(1, "wheat", 1, {})
	var pre_buffs: int = Game.my_rec().buffs.size()
	Game.request_craft("cook", {"slots": [_find_slot("hog_meat"), _find_slot("wheat")]})
	_check(Game.my_rec().buffs.size() > pre_buffs, "feast buffs applied")

	print("[smoke] fluids: pour, fuse, dissolve (controlled basin in open air)")
	# Generated oceans/lava can leave a large deterministic work queue. Put that
	# queue to sleep while this focused basin test runs so its cells are not
	# delayed behind unrelated streamed terrain, then restore it afterward.
	var sleeping_fluids := Game.voxel.fluid_cells.duplicate()
	Game.voxel.fluid_cells.clear()
	var fy := sy + 28  # high platform: no trees, ponds, or slopes interfering
	Game._apply_edit({"t": "box", "p": [sx + 4, fy - 1, sz + 4], "q": [sx + 14, fy - 1, sz + 9], "b": Blocks.STONE})
	Game._apply_edit({"t": "box", "p": [sx + 4, fy, sz + 4], "q": [sx + 14, fy + 3, sz + 9], "b": Blocks.AIR})
	var wp := Vector3i(sx + 6, fy + 2, sz + 6)
	Game._apply_edit({"t": "set", "p": [wp.x, wp.y, wp.z], "b": Blocks.WATER})
	for i in range(8):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
	_check(Blocks.fluid_kind(Game.voxel.get_block(wp.x, wp.y - 1, wp.z)) == "water"
		or Blocks.fluid_kind(Game.voxel.get_block(wp.x, fy, wp.z)) == "water", "water flows down")
	var lavap := Vector3i(sx + 10, fy, sz + 6)
	Game._apply_edit({"t": "set", "p": [lavap.x, lavap.y, lavap.z], "b": Blocks.LAVA})
	Game._apply_edit({"t": "set", "p": [lavap.x + 3, lavap.y, lavap.z], "b": Blocks.WATER})
	var made_obsidian := false
	for i in range(16):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
		for dx in range(-1, 5):
			for dy in range(-1, 2):
				if Game.voxel.get_block(lavap.x + dx, lavap.y + dy, lavap.z) == Blocks.OBSIDIAN:
					made_obsidian = true
	_check(made_obsidian, "lava + water fuses into obsidian")
	for cell in sleeping_fluids:
		Game.voxel.fluid_cells[cell] = true

	print("[smoke] craft chain: spell (mana), potion, skill merge, smith, enchant")
	Game.give_item(1, "rune_ruin", 1, {})
	Game.give_item(1, "card_king", 1, {})
	Game.give_item(1, "ess_gilded", 1, {})
	Game.request_craft("spell", {"rune": _find_slot("rune_ruin"),
		"card": _find_slot("card_king"), "essence": _find_slot("ess_gilded")})
	var sp := _find_slot("spell")
	_check(sp >= 0, "spell forged")
	var mana_pre := int(Game.my_rec().mana)
	Game.request_use(sp, p.global_position + Vector3(4, -1, 4))
	_check(int(Game.my_rec().mana) < mana_pre, "casting draws mana (not charges)")
	Game.give_item(1, "luckroot", 1, {})
	Game.give_item(1, "gilded_moss", 1, {})
	Game.request_craft("brew", {"slots": [_find_slot("luckroot"), _find_slot("gilded_moss")]})
	_check(_find_slot("potion") >= 0, "potion brewed")
	Game.give_item(1, "skill", 1, Db.BASE_SKILLS.prospector.duplicate(true))
	Game.give_item(1, "skill", 1, Db.BASE_SKILLS.loaded_dice.duplicate(true))
	var ska := _find_slot("skill")
	Game.request_craft("merge", {"a": ska, "b": _find_slot("skill", ska + 1)})
	_check(_find_slot("skill") >= 0, "skills merged")
	Game.give_item(1, "stone", 3, {})
	Game.give_item(1, "wood", 2, {})
	Game.give_item(1, "gold_dust", 3, {})
	Game.request_craft("smith", {"recipe": "blade_rusty"})
	var bslot := _find_slot("blade_rusty")
	_check(bslot >= 0, "blade forged at the anvil")
	Game.give_item(1, "luck_shard", 1, {})
	Game.my_rec().gold = maxi(int(Game.my_rec().gold), 200)
	Game.request_craft("enchant", {"gear": bslot, "essence": _find_slot("luck_shard")})
	_check(bool(Game.my_rec().inv[bslot].meta.get("spellbound", false)), "gear soul-bound")

	print("[smoke] depth bands: dig down, the world gets meaner")
	_check(Db.band_at(p.global_position.y) == 0, "surface is band 0")
	_check(Db.band_at(20.0) >= 2 and Db.band_at(6.0) > Db.band_at(20.0),
		"bands deepen with depth (y20=%d, y6=%d)" % [Db.band_at(20.0), Db.band_at(6.0)])
	Game._server_spawn_enemy("gloom_rat", Vector3(sx + 40, 10, sz))
	var deep_rat := -1
	for eid in Game.enemies:
		if Game.enemies[eid].type == "gloom_rat":
			deep_rat = eid
	_check(int(Game.enemies[deep_rat].level) >= 3, "deep spawn scaled by band (lvl %d)" % int(Game.enemies[deep_rat].level))
	var found_ore := false
	for x in range(sx + 30, sx + 80):
		for y in range(4, 26):
			if Game.voxel.get_block(x, y, sz + 40) in [Blocks.COPPER_ORE, Blocks.IRON_ORE,
					Blocks.GOLD_ORE, Blocks.SILVER_ORE, Blocks.ADAMANT_ORE]:
				found_ore = true
				break
		if found_ore:
			break
	_check(found_ore, "metal ores seam the deep stone")

	print("[smoke] world spawner + real-time combat")
	Game._server_tick_spawner()
	Game._server_spawn_enemy("rattlebone", p.global_position + Vector3(1.5, 0.5, 0))
	var foe := -1
	for eid in Game.enemies:
		var e: Dictionary = Game.enemies[eid]
		if e.type == "rattlebone" and e.alive:
			foe = eid
	Game.world.spawn_enemy(Game.enemies[foe])
	var fnode = Game.world.get_enemy(foe)
	fnode.global_position = p.global_position + Vector3(1.5, 0.5, 0)
	Game.enemies[foe].pos = fnode.global_position
	var ehp: int = int(Game.enemies[foe].hp)
	for i in range(80):
		if not Game.enemies[foe].alive:
			break
		Game._melee_cd.erase(1)
		Game.request_melee(foe)
	_check(not Game.enemies[foe].alive or int(Game.enemies[foe].hp) < ehp, "live d20 strikes land")
	_check(int(Game.my_rec().prof.combat.xp) > 0, "combat discipline gained XP")

	print("[smoke] fishing (dig a pool, fill it, cast)")
	var pool := Vector3i(sx + 8, sy - 1, sz + 8)
	Game._apply_edit({"t": "set", "p": [pool.x, pool.y - 1, pool.z], "b": Blocks.STONE})
	Game._apply_edit({"t": "set", "p": [pool.x, pool.y, pool.z], "b": Blocks.WATER})
	Game.give_item(1, "pole_wood", 1, {})
	Game.request_fish([pool.x, pool.y, pool.z])
	_check(Game.fishing.has(1), "line cast into the pool")
	if Game.fishing.has(1):
		Game.fishing[1].until = 0
	Game._server_tick_fishing()
	_check(int(Game.my_rec().prof.fishing.xp) > 0, "fishing skill gained XP")

	print("[smoke] storage chest + death drops")
	var csp := Vector3i(sx - 5, sy + 1, sz - 5)
	Game._apply_edit({"t": "set", "p": [csp.x, csp.y, csp.z], "b": Blocks.AIR})
	Game._apply_edit({"t": "set", "p": [csp.x, csp.y, csp.z], "b": Blocks.CHEST_STORE})
	var ckey := "%d,%d,%d" % [csp.x, csp.y, csp.z]
	_check(Game.chest_store.has(ckey), "placed chest registered")
	Game.give_item(1, "bone", 3, {})
	Game.request_chest_put(ckey, _find_slot("bone"))
	_check(Game.chest_store[ckey].size() == 1, "item deposited")
	Game.request_chest_take(ckey, 0)
	_check(Game.chest_store[ckey].is_empty(), "item withdrawn")
	Game.give_item(1, "gravel", 5, {})
	var pickups_pre: int = Game.pickups.size()
	Game.hurt_player(1, 99999, "the test reaper")
	_check(Game.pickups.size() > pickups_pre, "death drops inventory at the corpse")
	_check(_find_slot("blade_rusty") >= 0, "soul-bound blade survived death")

	print("[smoke] npc trade + quest (simple)")
	Game._server_spawn_enemy("refuge_citizen", p.global_position + Vector3(2, 0.5, 0))
	var folk := -1
	for eid in Game.enemies:
		if String(Game.enemies[eid].get("disp", "")) == "neutral" and Game.enemies[eid].alive:
			folk = eid
	if folk >= 0:
		Game.request_npc_quest(folk)
		_check(Game.quests.has(1), "one-click quest accepted")
		Game.my_rec().gold = 500
		Game.request_npc_trade(folk, 0)
		_check(int(Game.my_rec().gold) < 500, "simple trade works")
	else:
		_check(false, "no neutral folk to trade with")

	print("[smoke] thieves return stolen gold on death")
	Game._server_spawn_enemy("cave_imp", p.global_position + Vector3(-2, 0.5, 0))
	var imp := -1
	for eid in Game.enemies:
		if Game.enemies[eid].type == "cave_imp" and Game.enemies[eid].alive:
			imp = eid
	Game.enemies[imp]["stolen"] = 25
	var gold_pre: int = int(Game.my_rec().gold)
	Game.enemy_defeated(imp, 1)
	_check(int(Game.my_rec().gold) >= gold_pre + 25, "recovered the imp's stolen 25 gold")

	print("[smoke] save round-trip (single world log)")
	Game.save_now()
	var snap := SaveMgr.load_latest()
	_check(snap.get("edit_log", []).size() == Game.edit_log.size(), "full edit log persisted")
	_check(snap.players.has(Game.my_rec().name), "player in snapshot")

	if _fails == 0:
		print("SMOKE PASS")
		get_tree().quit(0)
	else:
		printerr("SMOKE FAIL (%d checks failed)" % _fails)
		get_tree().quit(1)


func _find_slot(id: String, from := 0) -> int:
	var inv: Array = Game.my_rec().get("inv", [])
	for i in range(from, inv.size()):
		if inv[i] != null and inv[i].id == id:
			return i
	return -1


func _count_item(id: String) -> int:
	var n := 0
	for e in Game.my_rec().get("inv", []):
		if e != null and e.id == id:
			n += e.count
	return n
