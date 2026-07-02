extends Node
## Headless smoke test — drives a solo run end-to-end without input:
##   boot → town → mine/place → doors+locks → farming → cooking feast →
##   fluids (water/lava→obsidian+steam, acid dissolve) → lighting →
##   spellcraft → alchemy → skill merge → descend → hunt → turn-based combat
##   with d20 rolls → adaptive threat → save round-trip.
## Run:  godot --headless res://tests/smoke.tscn
## Prints "SMOKE PASS" and exits 0, or reports failures and exits 1.

var _fails := 0
var _st := {}  # last encounter state (lambdas capture locals by value; members work)


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
	# Fresh character: earlier runs leave a persistent character.json (that's
	# the drop-in progression feature), which would skew slot-based checks.
	if FileAccess.file_exists(SaveMgr.CHARACTER):
		DirAccess.remove_absolute(SaveMgr.CHARACTER)
	var main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	_run_test(main)


func _run_test(main) -> void:
	print("[smoke] solo host + start run")
	Net.start_solo()
	main.show_lobby()
	Game.request_set_class("lucky_bard")
	Game.request_set_loot_rule("shared_gold")
	Game.request_start_run()
	await get_tree().process_frame
	_check(Game.in_run, "run started")
	_check(Game.floor_num == 0, "in town (floor 0)")
	_check(Game.loot_rule == "shared_gold", "loot rule set from lobby")
	var p = Game.world.get_player(1)
	_check(p != null, "player spawned")
	_check(_find_slot("spell") >= 0, "class signature spell in satchel")
	_check(not Game.camps.is_empty(), "town campfire discovered as a camp")

	print("[smoke] mining and placing")
	var bp := Vector3i(int(p.global_position.x), 2, int(p.global_position.z))
	Game.request_break(bp)
	_check(Game.voxel.get_block_v(bp) == Blocks.AIR, "block broken + replicated")
	Game.request_place(bp, _find_slot("brick"))
	_check(Game.voxel.get_block_v(bp) == Blocks.BRICK, "block placed back")

	print("[smoke] doors: place, lock, magic-breach")
	var dp := bp + Vector3i(2, 1, 0)
	Game.give_item(1, "door", 1, {})
	Game.give_item(1, "golden_key", 1, {})
	Game.request_place(dp, _find_slot("door"))
	_check(Game.voxel.get_block_v(dp) == Blocks.DOOR, "door placed")
	var dparr := [dp.x, dp.y, dp.z]
	Game.request_interact("door", dparr)
	_check(Game.voxel.get_block_v(dp) == Blocks.DOOR_OPEN, "door opens")
	Game.request_interact("door", dparr)
	_check(Game.voxel.get_block_v(dp) == Blocks.DOOR, "door closes")
	Game.request_interact("door_lock", dparr)
	_check(Game.voxel.get_block_v(dp) == Blocks.DOOR_LOCKED, "golden key locks it")
	_check(not Blocks.is_breakable(Blocks.DOOR_LOCKED), "locked door resists hands")
	Game._apply_edit({"t": "sphere", "p": dparr, "r": 1.0, "b": 0})
	_check(Game.voxel.get_block_v(dp) == Blocks.AIR, "spells breach locked doors (magic_break)")

	print("[smoke] lighting: glowstone brightens, removal darkens")
	var lp := Vector3i(int(p.global_position.x) + 4, 4, int(p.global_position.z))
	var before_light: int = Game.voxel.light_at(lp.x, lp.y + 1, lp.z)
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": Blocks.GLOWSTONE})
	_check(Game.voxel.light_at(lp.x, lp.y + 1, lp.z) == 14, "glowstone lights neighbors to 14")
	Game._apply_edit({"t": "set", "p": [lp.x, lp.y, lp.z], "b": 0})
	_check(Game.voxel.light_at(lp.x, lp.y + 1, lp.z) == before_light, "light repairs after removal")

	print("[smoke] farming: plant on dirt, grow in light, harvest wheat")
	var fp := Vector3i(int(p.global_position.x) - 3, 3, int(p.global_position.z))
	Game._apply_edit({"t": "set", "p": [fp.x, fp.y - 1, fp.z], "b": Blocks.DIRT})
	Game._apply_edit({"t": "set", "p": [fp.x, fp.y + 2, fp.z], "b": Blocks.GLOWSTONE})
	Game.give_item(1, "seeds", 2, {})
	Game.request_place(fp, _find_slot("seeds"))
	_check(Game.voxel.get_block_v(fp) == Blocks.CROP_1, "seeds planted on dirt")
	_check(Game.crops.has("%d,%d,%d" % [fp.x, fp.y, fp.z]), "crop tracked for growth")
	_check(Game.voxel.light_at(fp.x, fp.y, fp.z) >= 8, "farm plot is lit enough to grow")
	for i in range(60):  # force growth ticks
		Game._server_tick_crops()
		if Game.voxel.get_block_v(fp) == Blocks.CROP_RIPE:
			break
	_check(Game.voxel.get_block_v(fp) == Blocks.CROP_RIPE, "crop grew to ripe in light")
	Game.request_break(fp)
	_check(_count_item("wheat") >= 1, "harvest yields wheat")

	print("[smoke] cooking: campfire feast with shared buffs")
	Game.give_item(1, "hog_meat", 1, {})
	Game.give_item(1, "wheat", 1, {})
	var pre_buffs: int = Game.my_rec().buffs.size()
	Game.request_craft("cook", {"slots": [_find_slot("hog_meat"), _find_slot("wheat")]})
	_check(Game.my_rec().buffs.size() > pre_buffs, "feast buffs applied to diners")

	print("[smoke] fluids: water falls+spreads, lava+water=obsidian+steam, acid eats dirt")
	var wp := Vector3i(int(p.global_position.x) + 6, 6, int(p.global_position.z) + 4)
	Game._apply_edit({"t": "set", "p": [wp.x, wp.y, wp.z], "b": Blocks.WATER})
	for i in range(8):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
	_check(Blocks.fluid_kind(Game.voxel.get_block(wp.x, wp.y - 1, wp.z)) == "water"
		or Blocks.fluid_kind(Game.voxel.get_block(wp.x, 3, wp.z)) == "water", "water flows down")
	# Lava and water meeting sideways on open floor: obsidian + steam above.
	var lavap := Vector3i(wp.x + 8, 3, wp.z)
	Game._apply_edit({"t": "set", "p": [lavap.x, lavap.y, lavap.z], "b": Blocks.LAVA})
	Game._apply_edit({"t": "set", "p": [lavap.x + 3, lavap.y, lavap.z], "b": Blocks.WATER})
	var made_obsidian := false
	var made_steam := false
	for i in range(16):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
		for dx in range(-1, 5):
			for dy in range(0, 3):
				var b := Game.voxel.get_block(lavap.x + dx, lavap.y + dy, lavap.z)
				if b == Blocks.OBSIDIAN:
					made_obsidian = true
				if Blocks.fluid_kind(b) == "steam":
					made_steam = true
	_check(made_obsidian, "lava + water fuses into obsidian")
	_check(made_steam, "steam boils off and rises")
	var ap := Vector3i(wp.x - 3, 5, wp.z + 3)
	Game._apply_edit({"t": "set", "p": [ap.x, ap.y - 1, ap.z], "b": Blocks.DIRT})
	Game._apply_edit({"t": "set", "p": [ap.x, ap.y, ap.z], "b": Blocks.ACID})
	var dissolved := false
	for i in range(40):
		Game._apply_edit({"t": "fluid", "p": [0, 0, 0]})
		if Game.voxel.get_block(ap.x, ap.y - 1, ap.z) != Blocks.DIRT:
			dissolved = true
			break
	_check(dissolved, "acid dissolves soft blocks")

	print("[smoke] spellcraft / alchemy / skill merge")
	Game.give_item(1, "rune_ruin", 1, {})
	Game.give_item(1, "card_king", 1, {})
	Game.give_item(1, "ess_gilded", 1, {})
	Game.request_craft("spell", {"rune": _find_slot("rune_ruin"),
		"card": _find_slot("card_king"), "essence": _find_slot("ess_gilded")})
	var sp := _find_slot_meta_name("Midas Detonation")
	_check(sp >= 0, "Midas Detonation forged (gilded+ruin combo)")
	_check(int(Game.my_rec().prof.spellcraft.xp) > 0 or int(Game.my_rec().prof.spellcraft.lvl) > 1,
		"spellcraft skill gained use-XP")
	Game.give_item(1, "luckroot", 1, {})
	Game.give_item(1, "gilded_moss", 1, {})
	Game.request_craft("brew", {"slots": [_find_slot("luckroot"), _find_slot("gilded_moss")]})
	_check(_find_slot("potion") >= 0, "potion brewed")
	Game.give_item(1, "skill", 1, Db.BASE_SKILLS.prospector.duplicate(true))
	Game.give_item(1, "skill", 1, Db.BASE_SKILLS.loaded_dice.duplicate(true))
	var sa := _find_slot("skill")
	Game.request_craft("merge", {"a": sa, "b": _find_slot("skill", sa + 1)})
	var merged := _find_slot("skill")
	_check(merged >= 0 and Game.my_rec().inv[merged].meta.name == "Fatedelver's Drill",
		"mine+luck merge => Fatedelver's Drill")
	Game.request_use(merged, Vector3.ZERO)

	print("[smoke] blacksmithing: forge, improve, skill XP")
	Game.give_item(1, "stone", 3, {})
	Game.give_item(1, "gold_dust", 3, {})
	var blades_before := _count_item("blade_rusty")
	Game.request_craft("smith", {"recipe": "blade_rusty"})
	_check(_count_item("blade_rusty") == blades_before + 1, "blade forged at the anvil")
	_check(int(Game.my_rec().prof.smithing.xp) > 0 or int(Game.my_rec().prof.smithing.lvl) > 1,
		"smithing gained use-XP")
	var bslot := _find_slot("blade_rusty")
	Game.request_craft("improve", {"slot": bslot})
	_check(int(Game.my_rec().inv[bslot].meta.get("quality", 0)) == 1, "gear improved to Fine quality")

	print("[smoke] enchanting: Flamebrand blade")
	Game.give_item(1, "ess_ember", 2, {})
	Game.my_rec().gold = maxi(int(Game.my_rec().gold), 100)
	Game.request_craft("enchant", {"gear": bslot, "essence": _find_slot("ess_ember")})
	var bmeta: Dictionary = Game.my_rec().inv[bslot].meta
	_check(String(bmeta.get("ench", "")) == "ember" and "Flamebrand" in String(bmeta.get("name", "")),
		"weapon enchanted (Flamebrand)")
	_check(int(Game.my_rec().prof.enchanting.xp) > 0, "enchanting gained use-XP")

	print("[smoke] skill points: allocate into mining")
	Game.my_rec().skill_points = 2
	var eff_before := Db.prof_eff(Game.my_rec(), "mining")
	Game.request_allocate("mining")
	_check(int(Game.my_rec().skill_points) == 1, "point spent")
	_check(Db.prof_eff(Game.my_rec(), "mining") == eff_before + 2, "allocation = +2 effective levels")

	print("[smoke] oxygen: submerge, drain, gills")
	var head := Vector3i((p.global_position + Vector3(0, 1.4, 0)).floor())
	Game._apply_edit({"t": "set", "p": [head.x, head.y, head.z], "b": Blocks.WATER})
	for i in range(15):
		Game._server_tick_hazards()
	_check(float(Game.my_rec().breath) < Game.BREATH_MAX, "breath drains underwater")
	Game.my_rec().buffs.append({"k": "gills", "amt": 1, "until": Time.get_ticks_msec() + 60000})
	Game._server_tick_hazards()
	_check(float(Game.my_rec().breath) == Game.BREATH_MAX, "gills restore breathing")
	Game._apply_edit({"t": "set", "p": [head.x, head.y, head.z], "b": 0})

	print("[smoke] water-breathing potion from kelp")
	Game.my_rec().buffs = []  # clear the test gills buff
	Game.give_item(1, "kelp", 2, {})
	var k1 := _find_slot("kelp")
	Game.request_craft("brew", {"slots": [k1, k1]})  # one stack, two doses
	var gill_pot := -1
	var inv_now: Array = Game.my_rec().inv
	for i in range(inv_now.size()):
		if inv_now[i] != null and inv_now[i].id == "potion":
			for fx in inv_now[i].meta.get("effects", []):
				if String(fx.prop) == "gills":
					gill_pot = i
	_check(gill_pot >= 0, "kelp brews a Tidecaller potion")
	if gill_pot >= 0:
		Game.request_use(gill_pot, p.global_position)
		_check(Game.has_gills(Game.my_rec()), "drinking it grants water breathing")

	print("[smoke] traps: tripwire detonates, gas sedates, crusher descends")
	var tp := Vector3i((p.global_position + Vector3(0, 0.1, 0)).floor())
	var hp_pre: int = int(Game.my_rec().hp)
	Game._apply_edit({"t": "set", "p": [tp.x, tp.y, tp.z], "b": Blocks.TRIP_EXPL})
	Game._server_tick_traps()
	_check(Game.voxel.get_block_v(tp) == Blocks.AIR, "tripwire consumed on trigger")
	_check(int(Game.my_rec().hp) < hp_pre, "explosion hurt the trespasser")
	Game.my_rec().hp = Game.my_rec().max_hp
	var gp := tp + Vector3i(0, 1, 0)
	Game._apply_edit({"t": "set", "p": [gp.x, gp.y, gp.z], "b": Blocks.GAS_SLEEP_2})
	Game._server_tick_traps()
	var sleepy := false
	for b in Game.my_rec().buffs:
		if b.k == "sleep":
			sleepy = true
	_check(sleepy, "sleep gas applies the sleep status")
	Game._apply_edit({"t": "set", "p": [gp.x, gp.y, gp.z], "b": 0})
	Game.my_rec().buffs = []
	Game._arm_crusher(tp + Vector3i(0, 0, 3))
	_check(not Game._crushers.is_empty(), "crusher armed")
	for i in range(12):
		Game._server_tick_crushers()
	_check(Game._crushers.is_empty(), "crusher swept through and reset")

	print("[smoke] alchemy bombs: sootcap smoke bomb blinds stalkers")
	Game.give_item(1, "sootcap", 2, {})
	var sc := _find_slot("sootcap")
	Game.request_craft("brew", {"slots": [sc, sc]})
	var bomb := -1
	var inv_b: Array = Game.my_rec().inv
	for i in range(inv_b.size()):
		if inv_b[i] != null and inv_b[i].id == "potion" and inv_b[i].meta.get("throwable", false) \
				and "Smoke" in String(inv_b[i].meta.name):
			bomb = i
	_check(bomb >= 0, "Smoke Bomb brewed from sootcaps")
	# Aim well clear of the puddle the oxygen test left behind.
	var throw_at: Vector3 = p.global_position + Vector3(-7, 2, -7)
	if bomb >= 0:
		Game.request_use(bomb, throw_at)
		_check(Game.is_smoked(throw_at), "thrown bomb fills the air with smoke")

	print("[smoke] character persistence round-trip")
	Game.my_rec().gold = 777
	SaveMgr.save_character(Game.my_rec())
	var chr := SaveMgr.load_character()
	_check(int(chr.get("gold", 0)) == 777 and chr.has("prof"), "character saved with progression")
	var visitor := Game._record_for(9, "Visitor", String(chr.class_id), chr)
	_check(int(visitor.gold) == 777 and int(visitor.pid) == 9, "visiting character joins with its progression")
	var pt := Game.party()
	_check(int(pt.n) >= 1 and float(pt.avg) >= 1.0, "party scaling snapshot works (n=%d avg=%.1f)" % [pt.n, pt.avg])

	print("[smoke] waystones, injuries, resistances, statuses, settlements, FF")
	Game.give_item(1, "waystone", 1, {})
	var wsp := Vector3i(int(p.global_position.x) + 3, 3, int(p.global_position.z) - 3)
	Game.request_place(wsp, _find_slot("waystone"))
	_check(not Game.waystones.is_empty(), "placed waystone registered + synced")
	var wkey: String = Game.waystones.keys()[0]
	Game.request_waystone_tp(wkey)
	_check(p.global_position.distance_to(Vector3(Game.waystones[wkey].pos)) < 4.0,
		"waystone teleport moved the player")
	# Injuries + cure.
	Game.my_rec().injuries = {"arms": true}
	Game.give_item(1, "luckroot", 1, {})
	Game.give_item(1, "gloomcap", 1, {})
	Game.request_craft("brew", {"slots": [_find_slot("luckroot"), _find_slot("gloomcap")]})
	var heal_pot := -1
	var inv_h: Array = Game.my_rec().inv
	for i in range(inv_h.size()):
		if inv_h[i] != null and inv_h[i].id == "potion":
			for fx in inv_h[i].meta.get("effects", []):
				if String(fx.prop) == "heal":
					heal_pot = i
	if heal_pot >= 0:
		Game.request_use(heal_pot, p.global_position)
		_check(Game.my_rec().injuries.is_empty(), "healing potion cured the injury")
	# Friendly fire toggle.
	Game.request_set_ff(true)
	_check(Game.friendly_fire, "friendly fire setting flips")
	Game.request_set_ff(false)
	# Settlement variety across depths.
	var stypes := {}
	for f in range(2, 80):
		var st2 := DungeonGenerator.settlement_for(Game.run_seed, f)
		if st2 != "":
			stypes[st2] = true
	_check(stypes.size() >= 3, "settlement types vary across depths (%s)" % [stypes.keys()])
	# Enemy resist/weak math via a spawned skeleton (weak: physical, resist: poison).
	Game._server_spawn_enemy("rattlebone", p.global_position + Vector3(6, 1, 0))
	var skel := -1
	for eid in Game.enemies:
		if Game.enemies[eid].type == "rattlebone" and Game.enemies[eid].alive:
			skel = eid
	Game.enemies[skel].pos = p.global_position + Vector3(6, 1, 0)
	EffectExec._damage_enemies_near(Game, Vector3(Game.enemies[skel].pos), 2.0, 10, "poison", "poison", 3)
	_check(int(Game.enemies[skel].hp) == int(Game.enemies[skel].max) - 5,
		"poison resist halved the damage")
	_check(int(Game.enemies[skel].get("status", {}).get("poison", 0)) == 0,
		"poison status resisted outright")
	EffectExec._damage_enemies_near(Game, Vector3(Game.enemies[skel].pos), 2.0, 10, "fire", "burn", 2)
	_check(int(Game.enemies[skel].get("status", {}).get("burn", 0)) == 2, "burn status stuck")
	# Invisibility spell meta path.
	var rngv := RandomNumberGenerator.new()
	rngv.randomize()
	var veil := SpellForge.craft("rune_veil", "card_queen", "ess_void", rngv)
	_check(String(veil.effect) == "invisibility" and veil.name == "Veilwalk",
		"veil+void combo = Veilwalk (invisibility)")
	var wall := SpellForge.craft("rune_wall", "card_queen", "ess_frost", rngv)
	_check(wall.name == "Wall of Ice", "wall spells named by element")

	print("[smoke] biomes: depths vary")
	var seen := {}
	for f in range(3, 60):
		seen[DungeonGenerator.biome_for(Game.run_seed, f)] = true
	_check(seen.has("delve") and seen.has("caverns") and seen.has("lakes"),
		"delve/caverns/lakes all occur across depths (%s)" % [seen.keys()])

	print("[smoke] descending to floor 1")
	Game._server_descend()
	await get_tree().process_frame
	_check(Game.floor_num == 1, "on floor 1")
	var hostiles := 0
	var ambient := 0
	for eid in Game.enemies:
		if String(Game.enemies[eid].get("disp", "hostile")) == "hostile":
			hostiles += 1
		else:
			ambient += 1
	_check(hostiles > 0, "hostile mobs spawned (%d)" % hostiles)
	_check(ambient > 0, "ambient mobs spawned (%d passive/neutral)" % ambient)

	print("[smoke] hunting a passive animal")
	var prey := -1
	for eid in Game.enemies:
		if String(Game.enemies[eid].get("disp", "")) == "passive" and Game.enemies[eid].alive:
			prey = eid
			break
	if prey >= 0:
		Game._server_hunt(1, prey)
		_check(not Game.enemies[prey].alive, "hunt kills instantly")
		_check(not Game.pickups.is_empty(), "hunt drops food pickups into the world")
	else:
		print("  (no passive spawn this seed — skipping hunt check)")

	print("[smoke] turn-based combat: d20s, AC, crits")
	var foe := -1
	for eid in Game.enemies:
		var e: Dictionary = Game.enemies[eid]
		if String(e.get("disp", "hostile")) == "hostile" and e.alive:
			foe = eid
			break
	Events.enc_state.connect(_on_enc_state)
	var threat_before: float = Game.threat
	Game._server_start_encounter(1, foe)
	_check(Game.encounters.has(1) or not Game.enemies[foe].alive, "encounter open")
	_check(String(_st.get("phase", "")) in ["player", "done"], "player turn pushed to client")
	_check(not _st.get("actions", []).is_empty() or String(_st.phase) == "done", "actions offered")
	Game.give_item(1, "bow_short", 1, {})
	Game.give_item(1, "arrow", 5, {})
	if Game.encounters.has(1):
		var arrows_pre := _count_item("arrow")
		Game.request_enc_action("shoot")
		_check(_count_item("arrow") == arrows_pre - 1, "bow shot spent an arrow")
	var ehp_start: int = int(Game.enemies[foe].hp)
	for i in range(60):
		if not Game.encounters.has(1):
			break
		Game.request_enc_action("attack")
	var fought: bool = int(Game.enemies[foe].hp) < ehp_start or not Game.enemies[foe].alive \
		or int(Game.my_rec().hp) < int(Game.my_rec().max_hp)
	_check(fought, "dice drew blood on one side or the other")
	var saw_roll := false
	for r in _st.get("rolls", []):
		if int(r.get("dice", [0])[0]) >= 1:
			saw_roll = true
	_check(saw_roll, "d20 results streamed to the UI")
	_check(Game.threat >= 0.7 and Game.threat <= 1.4,
		"adaptive threat in bounds (%.2f, was %.2f)" % [Game.threat, threat_before])
	if Game.encounters.has(1):
		Game.request_enc_action("flee")
	Events.enc_state.disconnect(_on_enc_state)

	print("[smoke] fishing: cast, catch, fillet")
	Game.give_item(1, "pole_wood", 1, {})
	var pool_at := Vector3i(int(p.global_position.x) + 2, 3, int(p.global_position.z) + 2)
	Game._apply_edit({"t": "set", "p": [pool_at.x, pool_at.y - 1, pool_at.z], "b": Blocks.WATER})
	Game.request_fish([pool_at.x, pool_at.y - 1, pool_at.z])
	_check(Game.fishing.has(1), "line cast into open water")
	if Game.fishing.has(1):
		Game.fishing[1].until = 0  # yank the bobber instantly
	Game._server_tick_fishing()
	_check(not Game.fishing.has(1), "catch resolved")
	_check(int(Game.my_rec().prof.fishing.xp) > 0, "fishing skill gained use-XP")
	var live := _find_slot("fish_live")
	if live >= 0:
		var meat_pre := _count_item("fish_meat")
		Game.request_use(live, p.global_position)
		_check(_count_item("fish_meat") > meat_pre, "live fish filleted into meat")
	else:
		print("  (junk/treasure bite this cast — fillet path not exercised)")

	print("[smoke] storage chest: deposit + withdraw, spellbinding")
	Game.give_item(1, "chest_store", 1, {})
	var csp := Vector3i(int(p.global_position.x) - 2, 3, int(p.global_position.z) + 2)
	Game.request_place(csp, _find_slot("chest_store"))
	var ckey := "%d,%d,%d" % [csp.x, csp.y, csp.z]
	_check(Game.chest_store.has(ckey), "placed chest registered")
	Game.give_item(1, "bone", 3, {})
	Game.request_chest_put(ckey, _find_slot("bone"))
	_check(Game.chest_store[ckey].size() == 1, "item deposited")
	Game.request_chest_take(ckey, 0)
	_check(Game.chest_store[ckey].is_empty() and _count_item("bone") >= 3, "item withdrawn")
	# Soul-binding via luck shard.
	Game.give_item(1, "luck_shard", 1, {})
	Game.my_rec().gold = maxi(int(Game.my_rec().gold), 50)
	var bind_gear := _find_slot("blade_rusty")
	Game.request_craft("enchant", {"gear": bind_gear, "essence": _find_slot("luck_shard")})
	_check(bool(Game.my_rec().inv[bind_gear].meta.get("spellbound", false)), "gear soul-bound")

	print("[smoke] death drops (corpse run), bound gear survives")
	Game.give_item(1, "gravel", 5, {})
	var pickups_pre: int = Game.pickups.size()
	Game.hurt_player(1, 99999, "the test reaper")
	_check(Game.pickups.size() > pickups_pre, "inventory dropped at death site")
	_check(_find_slot("blade_rusty") >= 0 and bool(Game.my_rec().inv[_find_slot("blade_rusty")].meta.get("spellbound", false)),
		"soul-bound blade stayed through death")
	_check(_count_item("gravel") == 0, "unbound items gone from satchel")

	print("[smoke] new biomes & recipes present")
	var seen2 := {}
	for f in range(3, 90):
		seen2[DungeonGenerator.biome_for(Game.run_seed, f)] = true
	_check(seen2.has("fungal") and seen2.has("crypt"), "fungal + crypt biomes occur (%s)" % [seen2.keys()])
	var has_iron := false
	for r3 in Db.SMITH_RECIPES:
		if r3.id == "blade_iron":
			has_iron = true
	_check(has_iron and Db.item_def("blade_silver").get("dtag", "") == "dark",
		"metal tiers + silver anti-spirit tag wired")

	print("[smoke] save round-trip")
	Game.save_now()
	var snap := SaveMgr.load_latest()
	_check(int(snap.get("floor_num", -1)) == Game.floor_num, "snapshot floor matches")
	_check(snap.has("threat") and snap.has("loot_rule"), "threat + loot rule persisted")

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


func _find_slot_meta_name(mname: String) -> int:
	var inv: Array = Game.my_rec().get("inv", [])
	for i in range(inv.size()):
		if inv[i] != null and inv[i].get("meta", {}).get("name", "") == mname:
			return i
	return -1


func _count_item(id: String) -> int:
	var n := 0
	for e in Game.my_rec().get("inv", []):
		if e != null and e.id == id:
			n += e.count
	return n
