extends Node
## Headless smoke test for the INFINITE world: boot → spawn on the surface
## town → determinism + infinity checks → mine/place/doors/farm/cook/fluids/
## light → craft chain → dig DOWN through depth bands → real-time combat →
## fishing at the town pond → storage/binding → death drops → save round-trip.
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
	print("[smoke] solo host + start run (surface town at origin)")
	Net.start_solo()
	main.show_lobby()
	Game.request_set_class("lucky_bard")
	Game.request_set_loot_rule("shared_gold")
	Game.request_start_run()
	await get_tree().process_frame
	_check(Game.in_run, "run started")
	var p = Game.world.get_player(1)
	_check(p != null, "player spawned")
	var sy := int(p.global_position.y)
	var sx := int(p.global_position.x)
	var sz := int(p.global_position.z)
	_check(Game.voxel.get_block(sx, sy - 1, sz) == Blocks.BRICK, "standing on the town plaza")
	_check(_count_item("pick_rusty") == 0, "Minecraft rule: empty-handed start")
	_check(not Game.camps.is_empty() and not Game.waystones.is_empty(),
		"town campfire + waystone registered from worldgen")

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
	_check(Game.voxel.get_block(300, surf, 300) in [Blocks.GRASS, Blocks.DIRT, Blocks.BRICK],
		"surface heightmap holds (grass at y=%d)" % surf)

	print("[smoke] mining, placing, tool rules")
	var bp := Vector3i(sx + 2, sy - 1, sz)
	Game.request_break(bp)
	_check(Game.voxel.get_block_v(bp) == Blocks.AIR, "block broken + logged")
	Game.request_place(bp, _find_slot("brick"))
	_check(Game.voxel.get_block_v(bp) == Blocks.BRICK, "block placed back")
	_check(Game.edit_log.size() >= 2, "edits recorded in the world log")

	print("[smoke] doors, locks, magic breach")
	var dp := Vector3i(sx + 2, sy, sz + 2)
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
	var lp := Vector3i(sx - 4, sy + 1, sz - 4)
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": Blocks.GLOWSTONE})
	_check(Game.voxel.light_at(lp.x, lp.y + 1, lp.z) >= 14, "glowstone lights neighbors")
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": 0})
	_check(Game.voxel.light_at(lp.x, lp.y + 1, lp.z) == 15, "open surface cell back to skylight")

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

	print("[smoke] fluids: pour, fuse, dissolve")
	var wp := Vector3i(sx + 6, sy + 2, sz + 6)
	Game._apply_edit({"t": "set", "p": [wp.x, wp.y, wp.z], "b": Blocks.WATER})
	for i in range(8):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
	_check(Blocks.fluid_kind(Game.voxel.get_block(wp.x, wp.y - 1, wp.z)) == "water"
		or Blocks.fluid_kind(Game.voxel.get_block(wp.x, sy, wp.z)) == "water", "water flows down")
	var lavap := Vector3i(sx + 12, sy, sz)
	Game._apply_edit({"t": "set", "p": [lavap.x, lavap.y, lavap.z], "b": Blocks.LAVA})
	Game._apply_edit({"t": "set", "p": [lavap.x + 3, lavap.y, lavap.z], "b": Blocks.WATER})
	var made_obsidian := false
	for i in range(16):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
		for dx in range(-1, 5):
			if Game.voxel.get_block(lavap.x + dx, lavap.y, lavap.z) == Blocks.OBSIDIAN:
				made_obsidian = true
	_check(made_obsidian, "lava + water fuses into obsidian")

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

	print("[smoke] fishing at the town pond")
	Game.give_item(1, "pole_wood", 1, {})
	Game.request_fish([9, WorldGen.TOWN_Y, 9])
	_check(Game.fishing.has(1), "line cast into the pond")
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
		_check(false, "no citizen found in town")

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
