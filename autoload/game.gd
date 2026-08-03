extends Node
## Game — authoritative session state and every gameplay RPC. Autoload, so RPC
## node paths are identical on all peers. The server (peer 1) owns the truth:
## player records, inventories, edits, encounters, enemies, loot. Clients send
## request_* RPCs and render whatever state they're sent.

const REACH := 5.5
const PICKUP_RADIUS := 1.7
const INV_SIZE := 36  # Minecraft-true: 27 storage + 9 hotbar
const BREATH_MAX := 20.0

# ---- session ----
var in_run := false
var run_seed := 0
var floor_num := 0
var players := {}        # pid -> record (mirrored everywhere; server writes)
var lobby := {}          # pid -> {"name", "class_id"} pre-run
var lobby_list: Array = []  # steam lobby search results (Net fills)
var edit_log: Array = [] # ops for the current floor
var town_log: Array = [] # persistent floor-0 ops
var pending_load := {}   # save snapshot to restore when hosting
var loot_rule := "ffa"   # ffa | round_robin | shared_gold (host sets in lobby)
var friendly_fire := false  # host lobby setting: area effects harm allies
var waystones := {}      # "x,y,z" -> {"pos": Vector3, "name": String} (synced)
var last_deaths := {}    # pid -> {"gold": lost, "t": msec} for Second Dawn (server)
var quests := {}         # pid -> {"type","target","n","done","reward"} (server)
var fishing := {}        # pid -> {"until","lava","bait","pole"} (server)
var chest_store := {}    # "x,y,z" -> Array of item entries (server, this floor)
var town_chests := {}    # persisted floor-0 chest contents

## Adaptive difficulty: rises when players win fights healthy, falls on deaths.
## Multiplies enemy HP/attack and elite odds. Range 0.7 – 1.4, persisted in saves.
var threat := 1.0

# ---- server-only ----
var enemies := {}        # eid -> {"id","type","hp","max","pos","level","alive","in_combat","cooldown"}
var pickups := {}        # kid -> {"id","pos","item"}
var encounters := {}     # pid -> Encounter
var gen_info := {}       # current floor gen metadata
var camps := {}          # "x,y,z" -> Vector3 campfire positions (server, per floor)
var crops := {}          # "x,y,z" -> Vector3i growing crop cells (server, per floor)
var _next_eid := 1
var _next_kid := 1
var _rr_cursor := 0      # round-robin loot assignment cursor
var _fluid_accum := 0.0
var _slow_accum := 0.0   # 1s tick: regen, camp aura
var _crop_accum := 0.0
var _drown_accum := 0.0
var _crushers: Array = []     # active crusher traps (server)
var _dart_cooldowns := {}     # "x,y,z" -> until_msec
var _crush_accum := 0.0
var _floor_ready := {}   # pid -> true (barrier while loading a floor)
var _descending := false
var _tick := 0.0
var _villages_seen := {} # "x,z" anchor keys already discovered/registered (server)

## Day/night: a full cycle every DAY_LEN seconds. The server owns the clock
## and rebroadcasts it; every peer advances locally between syncs.
const DAY_LEN := 1200.0
var world_time := 240.0  # start late morning
var _time_accum := 0.0


## 0..1 sunlight right now (1 = noon, 0.1 = deep night).
func daylight() -> float:
	var phase := fposmod(world_time / DAY_LEN, 1.0)
	return clampf(sin(phase * TAU) * 1.15 + 0.42, 0.1, 1.0)


func is_night() -> bool:
	return daylight() < 0.32


@rpc("authority", "unreliable")
func cl_time(t: float) -> void:
	world_time = t

# ---- scene refs (registered by scenes/world.gd) ----
var world = null         # LLWorld
var voxel: VoxelWorld = null


func _ready() -> void:
	_setup_input()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


# ================================================================ helpers

func is_server() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id()


func my_rec() -> Dictionary:
	return players.get(my_id(), {})


## RPC sender pid; 0 means a direct local call on the server.
func _sender() -> int:
	var pid := multiplayer.get_remote_sender_id()
	return pid if pid != 0 else my_id()


## Targeted send that also works when the target is ourselves (solo/host).
func send_to(pid: int, method: StringName, args: Array) -> void:
	if pid == my_id():
		callv(method, args)
	else:
		callv("rpc_id", [pid, method] + args)


func eff_luck(rec: Dictionary) -> int:
	var l: int = rec.luck
	for b in rec.buffs:
		if b.k == "luck":
			l += int(b.amt)
	if rec.get("injuries", {}).has("head"):
		l -= 5
	return clampi(l, 0, 90)


# ================================================================ lobby

func host_started() -> void:
	reset_session()
	var chr := SaveMgr.load_character()
	lobby[1] = {"name": SteamMgr.player_name(),
		"class_id": String(chr.get("class_id", "cardsharp")), "chr": chr}
	Events.lobby_changed.emit()


func client_connected() -> void:
	rpc_id(1, "sv_register", SteamMgr.player_name(), SaveMgr.load_character())


## chr = the joiner's locally-saved character (may be {}); their progression
## travels with them into any lobby.
@rpc("any_peer", "reliable")
func sv_register(pname: String, chr := {}) -> void:
	if not is_server():
		return
	var pid := _sender()
	var cls := String(chr.get("class_id", "cardsharp"))
	if not Db.CLASSES.has(cls):
		cls = "cardsharp"
	if in_run:
		# Late join: give them everything they need to build the floor.
		lobby[pid] = {"name": pname, "class_id": cls, "chr": chr}
		players[pid] = _record_for(pid, pname, cls, chr)
		rpc_id(pid, "cl_begin_run", run_seed, players, 0, edit_log, [])
		rpc("cl_sync_player", pid, players[pid])
	else:
		lobby[pid] = {"name": pname, "class_id": cls, "chr": chr}
		rpc("cl_lobby_state", lobby)
	Events.lobby_changed.emit()


## A visiting character is used as-is (patched); picking a different class in
## the lobby than the saved character starts that class fresh.
func _record_for(pid: int, pname: String, class_id: String, chr: Dictionary) -> Dictionary:
	if chr.has("level") and String(chr.get("class_id", "")) == class_id:
		var rec: Dictionary = chr.duplicate(true)
		rec.pid = pid
		rec.name = pname
		rec.in_enc = false
		rec.buffs = []
		rec.breath = BREATH_MAX
		rec.die_hard_used = false
		if not rec.has("prof"):
			rec.prof = Db.new_profs()
		if not rec.has("skill_points"):
			rec.skill_points = 0
		if not rec.has("alloc"):
			rec.alloc = {}
		if not rec.has("atk_perm"):
			rec.atk_perm = 0
			rec.ac_perm = 0
		if not rec.has("injuries"):
			rec.injuries = {}
		if not rec.has("mana"):
			rec.mana = 40
			rec.max_mana = 40 + (int(rec.get("level", 1)) - 1) * 5
		while rec.inv.size() < INV_SIZE:  # older 27-slot characters
			rec.inv.append(null)
		return rec
	return _new_record(pid, pname, class_id)


@rpc("authority", "call_local", "reliable")
func cl_lobby_state(state: Dictionary) -> void:
	lobby = state
	Events.lobby_changed.emit()


@rpc("any_peer", "call_local", "reliable")
func sv_set_class(class_id: String) -> void:
	if not is_server():
		return
	var pid := _sender()
	if lobby.has(pid) and Db.CLASSES.has(class_id):
		lobby[pid].class_id = class_id
		if in_run and players.has(pid):
			pass  # class locked once running
		else:
			rpc("cl_lobby_state", lobby)
			Events.lobby_changed.emit()


func request_set_class(class_id: String) -> void:
	if is_server():
		sv_set_class(class_id)
	else:
		rpc_id(1, "sv_set_class", class_id)


## Host-only lobby setting: how drops and gold are shared (see reward_gold /
## _next_loot_owner). Broadcast so every client's lobby UI shows it.
func request_set_loot_rule(rule: String) -> void:
	if is_server() and rule in ["ffa", "round_robin", "shared_gold"]:
		loot_rule = rule
		rpc("cl_loot_rule", rule)


@rpc("authority", "call_local", "reliable")
func cl_loot_rule(rule: String) -> void:
	loot_rule = rule
	Events.lobby_changed.emit()


func request_set_ff(on: bool) -> void:
	if is_server():
		friendly_fire = on
		rpc("cl_ff", on)


@rpc("authority", "call_local", "reliable")
func cl_ff(on: bool) -> void:
	friendly_fire = on
	Events.lobby_changed.emit()


@rpc("authority", "call_local", "reliable")
func cl_waystones(ws: Dictionary) -> void:
	waystones = ws
	Events.players_changed.emit()


func request_waystone_tp(key: String) -> void:
	if is_server():
		sv_waystone_tp(key)
	else:
		rpc_id(1, "sv_waystone_tp", key)


# ---------------------------------------------------------------- storage chests

func request_chest_open(key: String) -> void:
	if is_server():
		sv_chest_open(key)
	else:
		rpc_id(1, "sv_chest_open", key)


@rpc("any_peer", "reliable")
func sv_chest_open(key: String) -> void:
	if not is_server():
		return
	send_to(_sender(), "cl_chest", [key, chest_store.get(key, [])])


func request_chest_put(key: String, slot: int) -> void:
	if is_server():
		sv_chest_put(key, slot)
	else:
		rpc_id(1, "sv_chest_put", key, slot)


@rpc("any_peer", "reliable")
func sv_chest_put(key: String, slot: int) -> void:
	if not is_server() or not chest_store.has(key):
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty() or slot < 0 or slot >= INV_SIZE or rec.inv[slot] == null:
		return
	var arr: Array = chest_store[key]
	if arr.size() >= 12:
		send_to(pid, "cl_notify", ["The chest is full."])
		return
	arr.append(rec.inv[slot])
	rec.inv[slot] = null
	_sync_player(pid)
	rpc("cl_chest", key, arr)


func request_chest_take(key: String, idx: int) -> void:
	if is_server():
		sv_chest_take(key, idx)
	else:
		rpc_id(1, "sv_chest_take", key, idx)


@rpc("any_peer", "reliable")
func sv_chest_take(key: String, idx: int) -> void:
	if not is_server() or not chest_store.has(key):
		return
	var pid := _sender()
	var arr: Array = chest_store[key]
	if idx < 0 or idx >= arr.size():
		return
	var it: Dictionary = arr[idx]
	if give_item(pid, it.id, it.count, it.get("meta", {})):
		arr.remove_at(idx)
		rpc("cl_chest", key, arr)


@rpc("authority", "call_local", "reliable")
func cl_chest(key: String, items: Array) -> void:
	Events.chest_contents.emit(key, items)


# ---------------------------------------------------------------- fishing

func request_fish(p: Array) -> void:
	if is_server():
		sv_fish(p)
	else:
		rpc_id(1, "sv_fish", p)


@rpc("any_peer", "reliable")
func sv_fish(p: Array) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty() or fishing.has(pid):
		return
	var kind := Blocks.fluid_kind(voxel.get_block(int(p[0]), int(p[1]), int(p[2])))
	var pole := 0.0
	var has_mythril := false
	for e in rec.inv:
		if e != null and Db.item_def(e.id).kind == "pole":
			pole = maxf(pole, float(Db.item_def(e.id).power))
			if e.id == "pole_mythril":
				has_mythril = true
	if pole <= 0.0:
		send_to(pid, "cl_notify", ["You need a fishing rod."])
		return
	if kind != "water" and not (kind == "lava" and has_mythril):
		send_to(pid, "cl_notify", ["Cast into open water — or lava, with a Mythril Rod."])
		return
	var bait: bool = _consume_id(rec, "grub", 1)
	fishing[pid] = {"until": Time.get_ticks_msec() + randi_range(2000, 4500),
		"lava": kind == "lava", "bait": bait, "pole": pole}
	_sync_player(pid)
	send_to(pid, "cl_notify", ["You cast your line%s..." % (" (grub wriggling)" if bait else "")])


## Resolved on the 1s tick: junk, fish by rarity weights (shifted by luck,
## pole, bait, and Fishing skill), or sunken treasure.
func _server_tick_fishing() -> void:
	var now := Time.get_ticks_msec()
	for pid in fishing.keys():
		var f: Dictionary = fishing[pid]
		if now < int(f.until):
			continue
		fishing.erase(pid)
		var rec: Dictionary = players.get(pid, {})
		if rec.is_empty():
			continue
		award_prof(pid, "fishing", 6)
		var score: float = eff_luck(rec) * 0.3 + float(f.pole) * 8.0 \
			+ (15.0 if f.bait else 0.0) + Db.prof_eff(rec, "fishing") \
			+ float(rec.passives.get("fish_bonus", 0.0))
		var roll := randf() * 100.0
		if roll < maxf(28.0 - score * 0.2, 6.0):
			var junk: String = ["kelp", "bone", "gravel"][randi() % 3]
			give_item(pid, junk, 1, {})
			send_to(pid, "cl_notify", ["...just some %s." % Db.item_def(junk).name.to_lower()])
			continue
		if roll > 94.0:
			reward_gold(pid, randi_range(20, 60))
			if randf() < 0.3:
				give_item(pid, "gambit_cache", 1, {})
			send_to(pid, "cl_notify", ["Your hook drags up SUNKEN TREASURE!"])
			continue
		# Weighted species pick, habitat-filtered, rarity shifted by score.
		var pool: Array = []
		for fid in Db.FISH:
			var fd: Dictionary = Db.FISH[fid]
			if bool(f.lava) != (String(fd.habitat) == "lava"):
				continue
			pool.append({"id": fid, "w": float(fd.weight) + score * 0.15 * float(fd.rarity)})
		var total := 0.0
		for c in pool:
			total += c.w
		var r2 := randf() * total
		var caught := ""
		for c in pool:
			r2 -= c.w
			if r2 <= 0.0:
				caught = c.id
				break
		if caught == "":
			caught = pool[0].id
		var fd2: Dictionary = Db.FISH[caught]
		give_item(pid, "fish_live", 1, {"species": caught, "name": "Live %s" % fd2.name,
			"rarity": int(fd2.rarity)})
		send_to(pid, "cl_notify", ["Caught: %s! Keep it alive, or use it to fillet." % fd2.name])


@rpc("any_peer", "reliable")
func sv_waystone_tp(key: String) -> void:
	if not is_server() or not waystones.has(key):
		return
	var pid := _sender()
	rpc("cl_teleport", pid, Vector3(waystones[key].pos) + Vector3(1, 0.5, 0))
	send_to(pid, "cl_notify", ["The waystone hums — and the dungeon folds around you."])


func _on_peer_connected(_pid: int) -> void:
	pass  # client introduces itself via sv_register


func _on_peer_disconnected(pid: int) -> void:
	if not is_server():
		return
	lobby.erase(pid)
	if players.has(pid):
		players.erase(pid)
		encounters.erase(pid)
		rpc("cl_remove_player", pid)
	rpc("cl_lobby_state", lobby)
	Events.lobby_changed.emit()


# ================================================================ run start / floors

func _new_record(pid: int, pname: String, class_id: String) -> Dictionary:
	var c: Dictionary = Db.CLASSES[class_id]
	var rec := {
		"pid": pid, "name": pname, "class_id": class_id,
		"hp": c.hp, "max_hp": c.hp, "gold": c.gold, "luck": c.luck,
		"atk_perm": 0, "ac_perm": 0, "breath": BREATH_MAX,
		"prof": Db.new_profs(), "skill_points": 0, "alloc": {}, "injuries": {},
		"level": 1, "xp": 0, "mutations": [], "passives": {}, "buffs": [],
		"skills": [], "in_enc": false, "die_hard_used": false,
		"inv": [],
	}
	# Minecraft rule: you start with NOTHING. Punch stone, chop wood, forge
	# your way up. Classes differ by stats, passives, and their signature
	# spell — which the Rune Forge will teach for a handful of gold.
	for i in range(INV_SIZE):
		rec.inv.append(null)
	rec["mana"] = 40
	rec["max_mana"] = 40
	match class_id:
		"high_roller":
			rec.passives["bounty"] = 0.15
		"soul_banker":
			rec.passives["soul_strike"] = 0.5
		"lucky_bard":
			rec.passives["luck_dig"] = 1.0
	return rec


## Host presses Start Run in the lobby.
func request_start_run() -> void:
	if not is_server() or in_run:
		return
	run_seed = randi()
	floor_num = 0
	town_log = []
	players = {}
	for pid in lobby:
		players[pid] = _record_for(pid, lobby[pid].name, lobby[pid].class_id,
			lobby[pid].get("chr", {}))
	# Restore a save if one was queued from the menu.
	if not pending_load.is_empty():
		run_seed = int(pending_load.seed)
		floor_num = 0
		edit_log = pending_load.get("town_log", []) + pending_load.get("edit_log", [])
		threat = float(pending_load.get("threat", 1.0))
		loot_rule = String(pending_load.get("loot_rule", loot_rule))
		town_chests = pending_load.get("town_chests", {})
		town_pop = int(pending_load.get("town_pop", 0))
		world_time = float(pending_load.get("world_time", 240.0))
		var saved_quests: Dictionary = pending_load.get("quests", {})
		for pid in players:
			if saved_quests.has(players[pid].name):
				quests[pid] = saved_quests[players[pid].name]
		var saved: Dictionary = pending_load.get("players", {})
		for pid in players:
			# A traveling character beats the world-save copy of that player.
			if lobby[pid].get("chr", {}).has("level"):
				continue
			var pname: String = players[pid].name
			if saved.has(pname):
				var rec: Dictionary = saved[pname]
				rec.pid = pid
				rec.in_enc = false
				rec.buffs = []
				# Patch records from older save versions.
				if not rec.has("prof"):
					rec.prof = Db.new_profs()
				if not rec.has("skill_points"):
					rec.skill_points = 0
				if not rec.has("alloc"):
					rec.alloc = {}
				if not rec.has("atk_perm"):
					rec.atk_perm = 0
					rec.ac_perm = 0
				rec.breath = BREATH_MAX
				players[pid] = rec
		pending_load = {}
	else:
		edit_log = []
	rpc("cl_begin_run", run_seed, players, 0, edit_log, [])


@rpc("authority", "call_local", "reliable")
func cl_begin_run(seed_v: int, precords: Dictionary, _fnum: int, ops: Array, _town_ops: Array) -> void:
	run_seed = seed_v
	floor_num = 0
	players = precords
	town_log = []
	edit_log = ops
	in_run = true
	if is_server():
		_floor_ready = {}
		_floor_barrier_open = false
	Events.run_started.emit()  # main.gd builds the world node → world_registered()


## World-space anchor: everyone spawns on the town plaza at the origin.
func spawn_point() -> Vector3:
	# First dry land walking east from the origin — (0,0) might be mid-ocean.
	# Deterministic, so every peer computes the identical spawn.
	for dx in range(0, 2000, 8):
		var s := WorldGen.surface_y(run_seed, dx, 0)
		if s > WorldGen.WATER_LEVEL:
			return Vector3(float(dx) + 0.5, float(s) + 1.6, 0.5)
	return Vector3(0.5, float(WorldGen.surface_y(run_seed, 0, 0)) + 1.6, 0.5)


func player_band(pid: int) -> int:
	var p = world.get_player(pid) if world != null else null
	return Db.band_at(p.global_position.y) if p != null else 0


## scenes/world.gd calls this from _ready once its nodes exist.
func world_registered(w, vw: VoxelWorld) -> void:
	world = w
	voxel = vw
	_local_load_floor()


## Infinite world boot: seed the generator, replay every edit ever made (this
## regenerates exactly the columns those edits touched), stream in the spawn
## area, and report ready. The mesh build is SLICED across frames — one long
## synchronous build starves ENet and the connection times out on tall worlds;
## players can't fall through meanwhile (ready_at freezes them until built).
func _local_load_floor() -> void:
	voxel.world_seed = run_seed
	WorldGen.setup(run_seed)
	for op in edit_log:
		voxel.apply_op(op)
	voxel.stream_around([spawn_point()])
	while not voxel.dirty.is_empty():
		voxel.flush_dirty(24)
		await get_tree().process_frame
	gen_info = {"spawn": spawn_point()}
	Events.floor_loaded.emit(0)
	if is_server():
		sv_floor_ready()
	else:
		rpc_id(1, "sv_floor_ready")


@rpc("any_peer", "reliable")
func sv_floor_ready() -> void:
	if not is_server():
		return
	var pid := _sender()
	_floor_ready[pid] = true
	if not players.has(pid):
		return
	# Late joiner catching up mid-floor: just spawn them into the live world.
	if _all_ready_consumed():
		_server_populate_floor()
	elif world != null and world.get_player(1) != null:
		_spawn_one_late(pid)


var _floor_barrier_open := true

func _all_ready_consumed() -> bool:
	if _floor_barrier_open:
		return false
	for pid in players:
		if not _floor_ready.has(pid):
			return false
	_floor_barrier_open = true
	return true


func _server_populate_floor() -> void:
	# Spawn every player in the wild; villages register themselves as they're
	# discovered, and the world spawner handles mobs — no floors, just depth.
	var base: Vector3 = gen_info.spawn
	var i := 0
	for pid in players:
		var pos := base + Vector3((i % 2) * 1.2, 0, (i / 2) * 1.2)
		rpc("cl_spawn_player", pid, pos)
		i += 1
	_restore_world_state()
	rpc("cl_notify", "You wake in %s. Villages dot the wilds — and the Deep is under your feet."
		% WorldGen.biome_name(run_seed, 0, 0))
	return


## Session bootstrap: persisted chests come back, pets rejoin their owners.
## Village furniture registers on DISCOVERY (see _server_discover_villages).
func _restore_world_state() -> void:
	camps = {}
	crops = {}
	waystones = {}
	_villages_seen = {}
	for ck in town_chests:
		chest_store[ck] = town_chests[ck]
	rpc("cl_waystones", waystones)
	var base: Vector3 = gen_info.spawn
	for pet in _carry_pets:
		_server_spawn_enemy(String(pet.type), base + Vector3(randf_range(-2, 2), 0.5, randf_range(-2, 2)))
		var new_eid := _next_eid - 1
		enemies[new_eid].tamed = true
		enemies[new_eid].owner_pid = int(pet.owner)
		enemies[new_eid].name = String(pet.name)
		rpc("cl_tame", new_eid, String(pet.name), int(pet.owner))
	_carry_pets = []


## Server: when a player first comes near a village, register its furniture
## (camps, crops, waystone) and wake its folk — friendly or otherwise.
func _server_discover_villages() -> void:
	for pid in players:
		var p = world.get_player(pid)
		if p == null or Db.band_at(p.global_position.y) != 0:
			continue
		for v in WorldGen.villages_near(run_seed, p.global_position, 72.0):
			var a: Vector2i = v.anchor
			var vkey := "%d,%d" % [a.x, a.y]
			if _villages_seen.has(vkey):
				continue
			_villages_seen[vkey] = true
			_register_village(v)


func _register_village(v: Dictionary) -> void:
	var a: Vector2i = v.anchor
	var g: int = v.ground
	var variant := String(v.variant)
	var vname: String = {"allied": "an ALLIED village", "cozy": "a COZY hamlet",
		"hostile": "a BANDIT camp", "ghost": "a GHOST town"}[variant]
	var feats := WorldGen.village_features(run_seed, v)
	for p in feats:
		var c: Vector3i = p
		var key := "%d,%d,%d" % [c.x, c.y, c.z]
		match int(feats[p]):
			Blocks.CAMPFIRE:
				camps[key] = Vector3(c) + Vector3(0.5, 0.5, 0.5)
			Blocks.CROP_1, Blocks.CROP_2:
				crops[key] = c
			Blocks.WAYSTONE:
				waystones[key] = {"pos": Vector3(c) + Vector3(0, 1, 0),
					"name": "%s Village (%d, %d)" % [variant.capitalize(), a.x, a.y]}
	rpc("cl_waystones", waystones)
	rpc("cl_notify", "You've found %s!" % vname)
	# Populate by disposition.
	var center := Vector3(float(a.x) + 0.5, float(g) + 1.5, float(a.y) + 0.5)
	var folk: Array = []
	match variant:
		"allied":
			folk = ["refuge_citizen", "refuge_citizen", "refuge_citizen", "villager",
				"town_guardian", "gloom_hog"]
			for j in range(mini(town_pop, 6)):
				folk.append("villager")
		"cozy":
			folk = ["refuge_citizen", "refuge_citizen", "villager"]
		"hostile":
			folk = ["bandit", "bandit", "bandit", "bandit"]
		"ghost":
			folk = ["gloom_ghost", "gloom_ghost", "tomb_howler"]
	for f in folk:
		_server_spawn_enemy(String(f),
			center + Vector3(randf_range(-9, 9), 0, randf_range(-9, 9)))


func _spawn_one_late(pid: int) -> void:
	# Send the newcomer everyone already in the world, then announce them.
	for opid in players:
		if opid == pid:
			continue
		var p = world.get_player(opid)
		if p != null:
			rpc_id(pid, "cl_spawn_player", opid, p.global_position)
	for eid in enemies:
		var e: Dictionary = enemies[eid]
		if e.alive:
			rpc_id(pid, "cl_spawn_enemy", e)
	for kid in pickups:
		rpc_id(pid, "cl_spawn_pickup", pickups[kid])
	rpc("cl_spawn_player", pid, gen_info.spawn)
	rpc("cl_notify", "%s joins the table." % players[pid].name)


@rpc("authority", "call_local", "reliable")
func cl_spawn_player(pid: int, pos: Vector3) -> void:
	if world != null:
		world.spawn_player(pid, pos)
	Events.players_changed.emit()


@rpc("authority", "call_local", "reliable")
func cl_remove_player(pid: int) -> void:
	players.erase(pid)
	if world != null:
		world.remove_player(pid)
	Events.players_changed.emit()


## Server: move everyone one floor down.
var _carry_pets: Array = []  # tamed companions ride along between floors
var town_pop := 0            # villagers recruited to the Refuge (persisted)


# (Floors are history: the world is one infinite volume. Descending is
# digging; town storage lives in the same edit log as everything else.)

## Server world spawner: keeps mob pressure around every player, scaled to
## the DEPTH they're at. Runs on a slow cadence; despawns strays.
var _spawner_accum := 0.0

func _server_tick_spawner() -> void:
	_server_discover_villages()
	var night := is_night()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for pid in players:
		var p = world.get_player(pid)
		if p == null:
			continue
		var band := Db.band_at(p.global_position.y)
		var nearby := 0
		var boss_alive := false
		for eid in enemies:
			var e: Dictionary = enemies[eid]
			if not e.alive:
				continue
			if bool(e.get("boss", false)):
				boss_alive = true
			if String(e.get("disp", "hostile")) == "hostile" \
					and Vector3(e.pos).distance_to(p.global_position) < 48.0:
				nearby += 1
		# Surface is calm by day, dangerous after dark (Minecraft rules).
		var want: int = ((3 if night else 1) if band == 0 else 3 + band) + int(party().n) / 2
		if nearby >= want:
			continue
		var pos := _find_spawn_spot(p.global_position, rng)
		if pos == Vector3.ZERO:
			continue
		if band >= 3 and not boss_alive and rng.randf() < 0.05:
			_server_spawn_enemy(Db.boss_for("delve", band * 7), pos)
			rpc("cl_notify", "The Deep shudders — something ENORMOUS stirs nearby...")
		elif rng.randf() < 0.2:
			var at := Db.pick_ambient_type(rng, maxi(band, 1))
			if at != "":
				_server_spawn_enemy(at, pos)
		elif band > 0 or (night and rng.randf() < 0.65) or rng.randf() < 0.1:
			_server_spawn_enemy(Db.pick_enemy_type(rng, maxi(band, 1), threat), pos)
	# Despawn strays far from everyone (never pets).
	for eid in enemies.keys():
		var e2: Dictionary = enemies[eid]
		if not e2.alive or bool(e2.get("tamed", false)) or bool(e2.get("boss", false)):
			continue
		var near := false
		for pid2 in players:
			var p2 = world.get_player(pid2)
			if p2 != null and p2.global_position.distance_to(Vector3(e2.pos)) < 90.0:
				near = true
				break
		if not near:
			e2.alive = false
			rpc("cl_despawn_enemy", eid)


## A standable air pocket 14-26 blocks out, near the player's depth.
func _find_spawn_spot(around: Vector3, rng: RandomNumberGenerator) -> Vector3:
	for attempt in range(6):
		var a := rng.randf() * TAU
		var dist := rng.randf_range(14.0, 26.0)
		var x := int(around.x + cos(a) * dist)
		var z := int(around.z + sin(a) * dist)
		var top := clampi(int(around.y) + 6, 2, WorldGen.H - 3)
		for y in range(top, maxi(int(around.y) - 10, 1), -1):
			if voxel.get_block(x, y, z) == Blocks.AIR \
					and voxel.get_block(x, y + 1, z) == Blocks.AIR \
					and Blocks.is_solid(voxel.get_block(x, y - 1, z)):
				return Vector3(x + 0.5, float(y) + 0.5, z + 0.5)
	return Vector3.ZERO


# ================================================================ voxel edits

func request_break(bpos: Vector3i) -> void:
	var arr := [bpos.x, bpos.y, bpos.z]
	if is_server():
		sv_break(arr)
	else:
		rpc_id(1, "sv_break", arr)


@rpc("any_peer", "reliable")
func sv_break(p: Array) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty() or not _within_reach(pid, p):
		return
	var bid: int = voxel.get_block(int(p[0]), int(p[1]), int(p[2]))
	if not Blocks.is_breakable(bid):
		return
	var def: Dictionary = Blocks.get_def(bid)
	_apply_edit({"t": "set", "p": p, "b": Blocks.AIR})
	# Drops. Crops and herbs have farming-specific yields.
	if bid == Blocks.CROP_RIPE:
		give_item(pid, "wheat", randi_range(1, 2), {})
		give_item(pid, "seeds", randi_range(1, 3), {})
	elif bid == Blocks.CROP_1 or bid == Blocks.CROP_2:
		give_item(pid, "seeds", 1, {})
	elif bid in [Blocks.HERB_LUCK, Blocks.HERB_GLOOM, Blocks.HERB_CINDER] and randf() < 0.3:
		give_item(pid, "seeds", 1, {})
	elif bid == Blocks.DIRT and randf() < 0.2:
		give_item(pid, "grub", 1, {})  # bait lives in the dirt
	var drop: String = def.get("drop", "")
	if drop != "" and not (bid in [Blocks.CROP_RIPE, Blocks.CROP_1, Blocks.CROP_2]):
		give_item(pid, drop, 1, {})
	if def.has("drop_gold"):
		var g := randi_range(int(def.drop_gold[0]), int(def.drop_gold[1]))
		if rec.mutations.has("cursed_veins"):
			g = int(g * 0.75)
		rec.gold += g
		send_to(pid, "cl_notify", ["+%d gold" % g])
	if rec.mutations.has("golden_touch") and bid == Blocks.STONE and randf() < 0.06:
		rec.gold += 5
		send_to(pid, "cl_notify", ["Golden Touch: +5 gold"])
	if rec.passives.has("luck_dig") and randf() < 0.05:
		rec.buffs.append({"k": "luck", "amt": 5, "until": Time.get_ticks_msec() + 30000})
		send_to(pid, "cl_notify", ["Fortune hums in the rubble (+5 luck, 30s)"])
	award_prof(pid, "mining", 1)
	_sync_player(pid)


func request_place(bpos: Vector3i, slot: int) -> void:
	var arr := [bpos.x, bpos.y, bpos.z]
	if is_server():
		sv_place(arr, slot)
	else:
		rpc_id(1, "sv_place", arr, slot)


@rpc("any_peer", "reliable")
func sv_place(p: Array, slot: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty() or not _within_reach(pid, p):
		return
	if slot < 0 or slot >= INV_SIZE or rec.inv[slot] == null:
		return
	var entry: Dictionary = rec.inv[slot]
	var def: Dictionary = Db.item_def(entry.id)
	if voxel.get_block(int(p[0]), int(p[1]), int(p[2])) != Blocks.AIR:
		return
	if def.kind == "seed":
		# Farming: seeds take root on dirt; they'll only grow in light >= 8.
		if voxel.get_block(int(p[0]), int(p[1]) - 1, int(p[2])) != Blocks.DIRT:
			send_to(pid, "cl_notify", ["Seeds need tilled dirt below."])
			return
		_consume(rec, slot, 1)
		_apply_edit({"t": "set", "p": p, "b": Blocks.CROP_1})
	elif def.kind == "block":
		_consume(rec, slot, 1)
		_apply_edit({"t": "set", "p": p, "b": int(def.block)})
	else:
		return
	_sync_player(pid)


func _within_reach(pid: int, p: Array) -> bool:
	var node = world.get_player(pid) if world != null else null
	if node == null:
		return false
	var bp := Vector3(int(p[0]) + 0.5, int(p[1]) + 0.5, int(p[2]) + 0.5)
	return node.global_position.distance_to(bp) <= REACH + 1.5


## Server-side: record + broadcast + apply an op everywhere.
func _apply_edit(op: Dictionary) -> void:
	edit_log.append(op)
	# Track camps and crops as they're placed/destroyed.
	if String(op.t) == "set":
		var key := "%d,%d,%d" % [int(op.p[0]), int(op.p[1]), int(op.p[2])]
		var b := int(op.b)
		if b == Blocks.CAMPFIRE:
			camps[key] = Vector3(int(op.p[0]) + 0.5, int(op.p[1]) + 0.5, int(op.p[2]) + 0.5)
		elif camps.has(key):
			camps.erase(key)
		if b == Blocks.CROP_1 or b == Blocks.CROP_2:
			crops[key] = Vector3i(int(op.p[0]), int(op.p[1]), int(op.p[2]))
		elif crops.has(key):
			crops.erase(key)
		if b == Blocks.CHEST_STORE:
			if not chest_store.has(key):
				chest_store[key] = []
		elif chest_store.has(key):
			# Chest broken: its contents spill out.
			for it in chest_store[key]:
				server_spawn_pickup(Vector3(int(op.p[0]) + 0.5, int(op.p[1]) + 0.8,
					int(op.p[2]) + 0.5), it, 0)
			chest_store.erase(key)
		if b == Blocks.WAYSTONE:
			waystones[key] = {"pos": Vector3(int(op.p[0]), int(op.p[1]) + 1, int(op.p[2])),
				"name": "Waystone %d" % (waystones.size() + 1)}
			rpc("cl_waystones", waystones)
		elif waystones.has(key):
			waystones.erase(key)
			rpc("cl_waystones", waystones)
	rpc("cl_apply_edit", op)


@rpc("authority", "call_local", "reliable")
func cl_apply_edit(op: Dictionary) -> void:
	if not is_server():
		edit_log.append(op)
	if voxel != null:
		voxel.apply_op(op)
	# World SFX keyed off the op itself — identical on every peer.
	if in_run and op.has("p"):
		var at := Vector3(int(op.p[0]) + 0.5, int(op.p[1]) + 0.5, int(op.p[2]) + 0.5)
		match String(op.t):
			"set":
				match int(op.b):
					Blocks.AIR:
						AudioMgr.sfx3d("sfx_break", at, -6.0)
					Blocks.DOOR_OPEN, Blocks.DOOR:
						AudioMgr.sfx3d("sfx_door", at, -4.0)
					Blocks.CHEST_EMPTY:
						AudioMgr.sfx3d("sfx_chest", at, -2.0)
			"sphere":
				if int(op.b) == Blocks.AIR and float(op.r) >= 1.5:
					AudioMgr.sfx3d("sfx_explosion", at, 2.0)


# ================================================================ inventory & items

func _find_space(rec: Dictionary, id: String, meta: Dictionary) -> int:
	var def: Dictionary = Db.item_def(id)
	for i in range(INV_SIZE):
		var e = rec.inv[i]
		if e != null and e.id == id and e.count < def.stack and e.meta.is_empty() and meta.is_empty():
			return i
	for i in range(INV_SIZE):
		if rec.inv[i] == null:
			return i
	return -1


func give_item(pid: int, id: String, count: int, meta: Dictionary) -> bool:
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return false
	var i := _find_space(rec, id, meta)
	if i < 0:
		send_to(pid, "cl_notify", ["Inventory full!"])
		return false
	if rec.inv[i] == null:
		rec.inv[i] = {"id": id, "count": count, "meta": meta}
	else:
		rec.inv[i].count += count
	_sync_player(pid)
	return true


func _consume(rec: Dictionary, slot: int, n: int) -> void:
	var e: Dictionary = rec.inv[slot]
	e.count -= n
	if e.count <= 0:
		rec.inv[slot] = null


func _count_of(rec: Dictionary, id: String) -> int:
	var n := 0
	for e in rec.inv:
		if e != null and e.id == id:
			n += int(e.count)
	return n


func _has_item(rec: Dictionary, id: String) -> bool:
	for e in rec.inv:
		if e != null and e.id == id:
			return true
	return false


func _consume_id(rec: Dictionary, id: String, n: int) -> bool:
	var have := 0
	for e in rec.inv:
		if e != null and e.id == id:
			have += e.count
	if have < n:
		return false
	var left := n
	for i in range(INV_SIZE):
		var e = rec.inv[i]
		if e != null and e.id == id:
			var take: int = mini(left, e.count)
			_consume(rec, i, take)
			left -= take
			if left == 0:
				break
	return true


func request_swap(a: int, b: int) -> void:
	if is_server():
		sv_swap(a, b)
	else:
		rpc_id(1, "sv_swap", a, b)


@rpc("any_peer", "reliable")
func sv_swap(a: int, b: int) -> void:
	if not is_server():
		return
	var rec: Dictionary = players.get(_sender(), {})
	if rec.is_empty() or a < 0 or b < 0 or a >= INV_SIZE or b >= INV_SIZE:
		return
	var tmp = rec.inv[a]
	rec.inv[a] = rec.inv[b]
	rec.inv[b] = tmp
	_sync_player(int(rec.pid))


func request_use(slot: int, target: Vector3) -> void:
	if is_server():
		sv_use(slot, target)
	else:
		rpc_id(1, "sv_use", slot, target)


@rpc("any_peer", "reliable")
func sv_use(slot: int, target: Vector3) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty() or slot < 0 or slot >= INV_SIZE or rec.inv[slot] == null:
		return
	var entry: Dictionary = rec.inv[slot]
	var kind: String = Db.item_def(entry.id).kind
	match kind:
		"potion":
			var meta: Dictionary = entry.meta
			_consume(rec, slot, 1)
			if meta.get("throwable", false):
				EffectExec.throw_potion(self, pid, meta, target)
			else:
				EffectExec.drink(self, pid, meta)
		"spell":
			# Spells are MANA-based tomes now: permanent, but every cast draws
			# from your pool (regenerates over time, faster at campfires).
			var meta2: Dictionary = entry.meta
			var cost: int = 6 + int(meta2.get("power", 1)) * 4
			if int(rec.get("mana", 0)) < cost:
				send_to(pid, "cl_notify", ["Not enough mana (%d needed)." % cost])
				return
			rec.mana = int(rec.mana) - cost
			EffectExec.cast(self, pid, meta2, target)
		"skill":
			var meta3: Dictionary = entry.meta
			for k in meta3.get("passives", {}):
				var v: float = float(meta3.passives[k])
				rec.passives[k] = maxf(float(rec.passives.get(k, 0.0)), v) if v > 1.0 else float(rec.passives.get(k, 0.0)) + v
			rec.skills.append(meta3)
			rec.inv[slot] = null
			send_to(pid, "cl_notify", ["Learned: %s" % meta3.get("name", "skill")])
		"fish":
			# Fillet the catch: rarer fish yield more meat.
			var species: String = String(entry.meta.get("species", "gloomfin"))
			var cuts: int = 2 + int(Db.FISH.get(species, {}).get("rarity", 0))
			_consume(rec, slot, 1)
			give_item(pid, "fish_meat", cuts, {})
			if species == "luckfish":
				rec.luck += 1
				send_to(pid, "cl_notify", ["The Luckfish's last gift: +1 luck, forever."])
			send_to(pid, "cl_notify", ["Filleted: %d Fish Fillets." % cuts])
		"cache":
			_consume(rec, slot, 1)
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var cband := player_band(pid)
			var drops: Array = Db.roll_loot(rng, cband + 2, eff_luck(rec), float(rec.passives.get("loot_bonus", 0.0)) + 0.3)
			var gold_win := rng.randi_range(20, 60 + cband * 15)
			rec.gold += gold_win
			for d in drops:
				give_item(pid, d.id, d.count, d.meta)
			send_to(pid, "cl_notify", ["Cache cracked: +%d gold, %d items!" % [gold_win, drops.size()]])
		_:
			return
	_sync_player(pid)


# ================================================================ crafting

## kind: "spell" {rune, card, essence: slots} | "brew" {slots: []} |
## "merge" {a, b: slots} | "mutate" {slot}
func request_craft(kind: String, payload: Dictionary) -> void:
	if is_server():
		sv_craft(kind, payload)
	else:
		rpc_id(1, "sv_craft", kind, payload)


@rpc("any_peer", "reliable")
func sv_craft(kind: String, payload: Dictionary) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	match kind:
		"spell":
			var rs: int = payload.rune
			var cs: int = payload.card
			var es: int = payload.essence
			if not (_slot_kind(rec, rs) == "rune" and _slot_kind(rec, cs) == "card" and _slot_kind(rec, es) == "essence"):
				return
			var meta := SpellForge.craft(rec.inv[rs].id, rec.inv[cs].id, rec.inv[es].id, rng,
				Db.prof_eff(rec, "spellcraft") + int(rec.passives.get("spell_bonus", 0.0)))
			_consume(rec, rs, 1)
			_consume(rec, cs, 1)
			_consume(rec, es, 1)
			give_item(pid, "spell", 1, meta)
			award_prof(pid, "spellcraft", 10)
			rpc("cl_notify", "%s forged %s!" % [rec.name, meta.name])
		"brew":
			var slots: Array = payload.slots
			if slots.size() < 2 or slots.size() > 3:
				return
			var ids: Array = []
			for s in slots:
				if _slot_kind(rec, int(s)) != "ingredient":
					return
				ids.append(rec.inv[int(s)].id)
			var meta2 := Alchemy.brew(ids, rng,
				Db.prof_eff(rec, "alchemy") + int(rec.passives.get("alch_bonus", 0.0)))
			for s in slots:
				_consume(rec, int(s), 1)
			give_item(pid, "potion", 1, meta2)
			award_prof(pid, "alchemy", 8)
			send_to(pid, "cl_notify", ["Brewed: %s" % meta2.name])
		"merge":
			var a: int = payload.a
			var b: int = payload.b
			var ka := _slot_kind(rec, a)
			var kb := _slot_kind(rec, b)
			if not (ka in ["skill", "spell"] and kb in ["skill", "spell"] and a != b):
				return
			var meta3 := SkillForge.merge(rec.inv[a].meta, rec.inv[b].meta, rng)
			rec.inv[a] = null
			rec.inv[b] = null
			give_item(pid, "skill", 1, meta3)
			award_prof(pid, "spellcraft", 6)
			rpc("cl_notify", "%s forged the skill %s!" % [rec.name, meta3.name])
		"mutate":
			var s2: int = payload.slot
			if _slot_kind(rec, s2) != "spell" or rec.gold < 50:
				send_to(pid, "cl_notify", ["Need a spell and 50 gold."])
				return
			rec.gold -= 50
			rec.inv[s2].meta = SpellForge.mutate(rec.inv[s2].meta, rng)
			award_prof(pid, "spellcraft", 5)
			send_to(pid, "cl_notify", ["The spell writhes: %s" % rec.inv[s2].meta.name])
		"learn_spell":
			# The Rune Forge teaches your class's signature spell (mana-cast).
			if rec.gold < 100:
				send_to(pid, "cl_notify", ["Learning your signature spell costs 100 gold."])
				return
			var sig := SpellForge.class_spell(String(rec.class_id))
			for it in rec.inv:
				if it != null and it.id == "spell" and String(it.meta.get("name", "")) == String(sig.name):
					send_to(pid, "cl_notify", ["You already know %s." % sig.name])
					return
			rec.gold -= 100
			give_item(pid, "spell", 1, sig)
			send_to(pid, "cl_notify", ["Learned: %s — cast it with RMB (costs mana)." % sig.name])
		"cook":
			var slots2: Array = payload.slots
			if slots2.size() < 2 or slots2.size() > 3:
				return
			var ids2: Array = []
			for s in slots2:
				if _slot_kind(rec, int(s)) != "ingredient":
					return
				ids2.append(rec.inv[int(s)].id)
			var meal := Cooking.cook(ids2, rng,
				Db.prof_eff(rec, "cooking") + int(rec.passives.get("cook_bonus", 0.0)))
			award_prof(pid, "cooking", 8)
			for s in slots2:
				_consume(rec, int(s), 1)
			# A feast: every Luckweaver near the fire eats.
			var cook_node = world.get_player(pid)
			var diners: Array = []
			for opid in players:
				var op = world.get_player(opid)
				if op != null and cook_node != null \
						and op.global_position.distance_to(cook_node.global_position) < 8.0:
					Cooking.feed(self, opid, meal)
					diners.append(players[opid].name)
			rpc("cl_notify", "%s serves %s — %s feast!" % [rec.name, meal.name, " & ".join(diners)])
		"smith":
			var recipe := {}
			for r in Db.SMITH_RECIPES:
				if r.id == String(payload.recipe):
					recipe = r
					break
			if recipe.is_empty():
				return
			var eff := Db.prof_eff(rec, "smithing")
			if eff < int(recipe.lvl):
				send_to(pid, "cl_notify", ["Needs Smithing %d." % int(recipe.lvl)])
				return
			for mat in recipe.mats:
				if _count_of(rec, mat) < int(recipe.mats[mat]):
					send_to(pid, "cl_notify", ["Missing materials."])
					return
			for mat in recipe.mats:
				_consume_id(rec, mat, int(recipe.mats[mat]))
			var q: int = eff / 10 + int(rec.passives.get("smith_quality", 0.0)) \
				+ (1 if rng.randf() < 0.15 else 0)
			var smeta := {}
			if q > 0:
				smeta = {"quality": q,
					"name": Db.quality_prefix(q) + Db.item_def(recipe.id).name,
					"rarity": clampi(q, 0, Db.Rarity.MYTHIC)}
			give_item(pid, recipe.id, int(recipe.get("count", 1)), smeta)
			award_prof(pid, "smithing", 12)
			send_to(pid, "cl_notify", ["Forged: %s%s" % [Db.quality_prefix(q), Db.item_def(recipe.id).name]])
		"improve":
			var gs: int = payload.slot
			var gkind := _slot_kind(rec, gs)
			if not (gkind in ["weapon", "armor"]):
				return
			if _count_of(rec, "gold_dust") < 3:
				send_to(pid, "cl_notify", ["Improving takes 3 Gold Dust."])
				return
			var eff2 := Db.prof_eff(rec, "smithing")
			var cur_q := int(rec.inv[gs].meta.get("quality", 0))
			if cur_q >= 1 + eff2 / 10:
				send_to(pid, "cl_notify", ["Your smithing can't refine this further yet."])
				return
			_consume_id(rec, "gold_dust", 3)
			var meta_i: Dictionary = rec.inv[gs].meta
			meta_i.quality = cur_q + 1
			var base_name: String = Db.item_def(rec.inv[gs].id).name
			meta_i.name = Db.quality_prefix(cur_q + 1) + base_name
			if meta_i.has("ench"):
				var et: Dictionary = Db.ENCH_WEAPON if gkind == "weapon" else Db.ENCH_ARMOR
				meta_i.name = "%s %s" % [et[meta_i.ench].name, meta_i.name]
			award_prof(pid, "smithing", 8)
			send_to(pid, "cl_notify", ["Refined to %s." % meta_i.name])
		"enchant":
			var ga: int = payload.gear
			var es2: int = payload.essence
			var gk := _slot_kind(rec, ga)
			if not (gk in ["weapon", "armor"]):
				return
			# Luck Shard instead of an essence = SPELLBIND: the item stays with
			# you through death.
			if rec.inv[es2] != null and rec.inv[es2].id == "luck_shard":
				if rec.gold < 30:
					send_to(pid, "cl_notify", ["Binding takes a Luck Shard and 30 gold."])
					return
				_consume(rec, es2, 1)
				rec.gold -= 30
				var bmeta: Dictionary = rec.inv[ga].meta
				bmeta.spellbound = true
				bmeta.name = "Bound " + String(bmeta.get("name", Db.item_def(rec.inv[ga].id).name)).trim_prefix("Bound ")
				award_prof(pid, "enchanting", 10)
				send_to(pid, "cl_notify", ["%s is soul-bound — death cannot take it." % bmeta.name])
				_sync_player(pid)
				return
			if _slot_kind(rec, es2) != "essence":
				return
			if rec.inv[es2].count < 2 or rec.gold < 30:
				send_to(pid, "cl_notify", ["Enchanting takes 2 matching essences and 30 gold."])
				return
			var element: String = Db.item_def(rec.inv[es2].id).element
			var epow: int = 1 + (Db.prof_eff(rec, "enchanting")
				+ int(rec.passives.get("ench_bonus", 0.0))) / 15
			_consume(rec, es2, 2)
			rec.gold -= 30
			var gmeta: Dictionary = rec.inv[ga].meta
			gmeta.ench = element
			gmeta.epow = epow
			var etable: Dictionary = Db.ENCH_WEAPON if gk == "weapon" else Db.ENCH_ARMOR
			var base2: String = String(gmeta.get("name", Db.item_def(rec.inv[ga].id).name))
			gmeta.name = "%s %s" % [etable[element].name, base2]
			gmeta.rarity = maxi(int(gmeta.get("rarity", 0)), Db.Rarity.RARE)
			award_prof(pid, "enchanting", 12)
			send_to(pid, "cl_notify", ["Enchanted: %s (%s)." % [gmeta.name, etable[element].desc]])


func _slot_kind(rec: Dictionary, slot: int) -> String:
	if slot < 0 or slot >= INV_SIZE or rec.inv[slot] == null:
		return ""
	return Db.item_def(rec.inv[slot].id).kind


# ================================================================ shop

func request_shop(action: String, idx: int) -> void:
	if is_server():
		sv_shop(action, idx)
	else:
		rpc_id(1, "sv_shop", action, idx)


@rpc("any_peer", "reliable")
func sv_shop(action: String, idx: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	if action == "buy":
		var stock: Array = Db.shop_stock(run_seed, player_band(pid))
		if idx < 0 or idx >= stock.size():
			return
		var offer: Dictionary = stock[idx]
		# Reputation discount, capped at 25%.
		var price := int(int(offer.price) * (1.0 - minf(int(rec.get("rep", 0)) * 0.05, 0.25)))
		if rec.gold < price:
			send_to(pid, "cl_notify", ["The house doesn't do credit."])
			return
		if give_item(pid, offer.id, 1, offer.meta.duplicate(true)):
			rec.gold -= price
	elif action == "sell":
		if idx < 0 or idx >= INV_SIZE or rec.inv[idx] == null:
			return
		var e: Dictionary = rec.inv[idx]
		var v: int = maxi(1, int(Db.item_def(e.id).value / 2)) * e.count
		rec.inv[idx] = null
		rec.gold += v
		send_to(pid, "cl_notify", ["Sold for %d gold." % v])
	_sync_player(pid)


# ================================================================ interactions

## kind: "portal" | "chest" (pos = block coords array)
func request_interact(kind: String, p: Array) -> void:
	if is_server():
		sv_interact(kind, p)
	else:
		rpc_id(1, "sv_interact", kind, p)


@rpc("any_peer", "reliable")
func sv_interact(kind: String, p: Array) -> void:
	if not is_server():
		return
	var pid := _sender()
	if not players.has(pid) or not _within_reach(pid, p):
		return
	var bid: int = voxel.get_block(int(p[0]), int(p[1]), int(p[2]))
	match kind:
		"portal":
			return  # extinct: the world is seamless — dig to descend
		"chest":
			if bid != Blocks.CHEST:
				return
			_apply_edit({"t": "set", "p": p, "b": Blocks.CHEST_EMPTY})
			var rec: Dictionary = players[pid]
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var chband := Db.band_at(float(p[1]))
			var gold_win := rng.randi_range(10, 30 + chband * 10)
			reward_gold(pid, gold_win)
			var at := Vector3(int(p[0]) + 0.5, int(p[1]) + 1.2, int(p[2]) + 0.5)
			for d in Db.roll_loot(rng, chband, eff_luck(rec), float(rec.passives.get("loot_bonus", 0.0))):
				server_spawn_pickup(at + Vector3(rng.randf_range(-0.8, 0.8), 0,
					rng.randf_range(-0.8, 0.8)), d, _next_loot_owner())
			rpc("cl_notify", "%s cracks a Gambit Chest (+%d gold)." % [rec.name, gold_win])
		"chest_trapped":
			if bid != Blocks.CHEST_TRAPPED:
				return
			_apply_edit({"t": "set", "p": p, "b": Blocks.CHEST_EMPTY})
			var gases := [Blocks.GAS_POISON_2, Blocks.GAS_SLEEP_2, Blocks.GAS_INVERT_2]
			spawn_gas_cloud(Vector3(int(p[0]) + 0.5, int(p[1]) + 1.0, int(p[2]) + 0.5), 2.0,
				gases[randi() % gases.size()])
			rpc("cl_notify", "%s springs a trapped chest — gas erupts!" % players[pid].name)
			var rng3 := RandomNumberGenerator.new()
			rng3.randomize()
			reward_gold(pid, rng3.randi_range(15, 40 + Db.band_at(float(p[1])) * 12))
			for d in Db.roll_loot(rng3, Db.band_at(float(p[1])), eff_luck(players[pid]), 0.3):
				give_item(pid, d.id, d.count, d.meta)
		"door":
			var has_key := _has_item(players[pid], "golden_key")
			match bid:
				Blocks.DOOR_TRAPPED:
					_apply_edit({"t": "set", "p": p, "b": Blocks.DOOR_OPEN})
					spawn_gas_cloud(Vector3(int(p[0]) + 0.5, int(p[1]) + 1.0, int(p[2]) + 0.5),
						1.6, Blocks.GAS_POISON_2)
					send_to(pid, "cl_notify", ["The hinge clicks wrong — poison gas vents from the frame!"])
				Blocks.DOOR:
					# Golden Key selected → lock; otherwise open.
					if bool(players[pid].get("_want_lock", false)) and has_key:
						pass  # (reserved)
					_apply_edit({"t": "set", "p": p, "b": Blocks.DOOR_OPEN})
				Blocks.DOOR_OPEN:
					_apply_edit({"t": "set", "p": p, "b": Blocks.DOOR})
				Blocks.DOOR_LOCKED:
					if has_key:
						_apply_edit({"t": "set", "p": p, "b": Blocks.DOOR})
						send_to(pid, "cl_notify", ["The Golden Key turns — unlocked."])
					else:
						send_to(pid, "cl_notify", ["Locked tight. Find a Golden Key — or bring a spell."])
		"door_lock":
			if bid != Blocks.DOOR:
				return
			if _has_item(players[pid], "golden_key"):
				_apply_edit({"t": "set", "p": p, "b": Blocks.DOOR_LOCKED})
				send_to(pid, "cl_notify", ["The Golden Key turns — locked. Magic can still breach it."])
			else:
				send_to(pid, "cl_notify", ["You need a Golden Key to lock doors."])


# ================================================================ real-time combat
# Combat is REAL-TIME: swings, arrows, and spells resolve instantly with the
# same d20 math as ever (roll + attack bonus vs AC, nat-20 crits, nat-1
# fumbles, luck advantage, resist/weak tags, statuses). Enemies chase and
# swing back on their own cooldowns. Parley (encounter.gd) remains turn-menus
# for neutral folk only.

const MELEE_RANGE := 2.8
const MELEE_CD_MS := 900
const ENEMY_ATK_RANGE := 1.9

var _melee_cd := {}      # pid -> until_msec (server)
var _reroll_cd := {}     # pid -> until_msec (Weighted Fate passive)

func _crit_floor_for(rec: Dictionary) -> int:
	var l := eff_luck(rec)
	if l >= 70:
		return 18
	if l >= 40:
		return 19
	return 20


## Best melee weapon {def, meta} (quality/ench folded in by callers); {} = fists.
func weapon_of(rec: Dictionary) -> Dictionary:
	var best := {}
	var best_avg := -1.0
	for entry in rec.inv:
		if entry == null:
			continue
		var def: Dictionary = Db.item_def(entry.id)
		if def.kind != "weapon" or def.get("ranged", false):
			continue
		var meta: Dictionary = entry.get("meta", {})
		var avg: float = def.dmg[0] * (def.dmg[1] + 1) * 0.5 + def.dmg[2] \
			+ int(meta.get("quality", 0)) + int(meta.get("epow", 0)) * 2
		if avg > best_avg:
			best_avg = avg
			best = {"def": def, "meta": meta}
	return best


func atk_bonus_of(rec: Dictionary, w: Dictionary) -> int:
	var c: Dictionary = Db.CLASSES[rec.class_id]
	var b: int = int(c.atk) + int(rec.level) / 2 + int(rec.get("atk_perm", 0)) \
		+ int(rec.passives.get("atk_perm", 0.0)) + Db.prof_eff(rec, "combat") / 8
	if not w.is_empty():
		b += int(w.def.get("atk", 0))
	if rec.get("injuries", {}).has("arms"):
		b -= 2
	for buff in rec.buffs:
		if buff.k == "atk":
			b += int(buff.amt)
	return b


func player_ac(rec: Dictionary) -> int:
	var armor := armor_of(rec)
	var ac: int = 10 + int(Db.CLASSES[rec.class_id].def) + int(rec.get("ac_perm", 0)) \
		+ int(armor.ac) + int(armor.ench.get("ember", 0))
	if rec.get("injuries", {}).has("body"):
		ac -= 1
	for b in rec.buffs:
		if b.k == "stone":
			ac += 6
		elif b.k == "ac":
			ac += int(b.amt)
	return ac


func request_melee(eid: int) -> void:
	if is_server():
		sv_melee(eid)
	else:
		rpc_id(1, "sv_melee", eid)


@rpc("any_peer", "reliable")
func sv_melee(eid: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	var e: Dictionary = enemies.get(eid, {})
	if rec.is_empty() or e.is_empty() or not e.alive:
		return
	if String(e.get("disp", "hostile")) == "passive":
		_server_hunt(pid, eid)
		return
	var now := Time.get_ticks_msec()
	if now < int(_melee_cd.get(pid, 0)):
		return
	var node = world.get_player(pid)
	if node == null or node.global_position.distance_to(Vector3(e.pos)) > MELEE_RANGE + 1.0:
		return
	_melee_cd[pid] = now + MELEE_CD_MS
	var w := weapon_of(rec)
	_strike(pid, eid, w, false)


## One d20 strike (melee or arrow) from a player against a mob.
func _strike(pid: int, eid: int, w: Dictionary, ranged: bool) -> void:
	var rec: Dictionary = players[pid]
	var e: Dictionary = enemies[eid]
	var sneak: bool = not bool(e.get("aware", false)) \
		and String(e.get("disp", "hostile")) == "hostile"
	e.aware = true
	e.disp = "hostile" if String(e.get("disp", "")) != "passive" else e.disp
	var d20 := randi_range(1, 20)
	if randf() * 100.0 < eff_luck(rec) * 0.4:  # luck advantage
		d20 = maxi(d20, randi_range(1, 20))
	var bonus := atk_bonus_of(rec, w)
	if d20 == 1:
		rpc("cl_hit_fx", eid, 0, "FUMBLE")
		send_to(pid, "cl_notify", ["Natural 1 — your swing goes wide!"])
		return
	var crit: bool = d20 >= _crit_floor_for(rec)
	if not crit and d20 + bonus < int(e.ac):
		# Weighted Fate: one automatic reroll of a miss, every 8s.
		var now2 := Time.get_ticks_msec()
		if rec.passives.has("reroll") and now2 > int(_reroll_cd.get(pid, 0)):
			_reroll_cd[pid] = now2 + 8000
			d20 = randi_range(1, 20)
			crit = d20 >= _crit_floor_for(rec)
			if d20 == 1 or (not crit and d20 + bonus < int(e.ac)):
				rpc("cl_hit_fx", eid, 0, "MISS")
				return
			send_to(pid, "cl_notify", ["Weighted Fate — the miss tumbles back into a hit!"])
		else:
			rpc("cl_hit_fx", eid, 0, "MISS")
			return
	var dd: Array = [1, 4, 0]  # fists
	if not w.is_empty():
		dd = w.def.dmg.duplicate()
		dd[2] = int(dd[2]) + int(w.meta.get("quality", 0))
	var dmg := int(dd[2])
	for i in range(int(dd[0]) * (2 if crit else 1)):
		dmg += randi_range(1, int(dd[1]))
	if crit:
		dmg = int(dmg * (1.0 + float(rec.passives.get("soul_strike", 0.0))))
	if sneak:
		dmg *= 2
		send_to(pid, "cl_notify", ["SNEAK ATTACK — it never saw you."])
	# Enchants.
	if not w.is_empty():
		match String(w.meta.get("ench", "")):
			"ember":
				dmg += randi_range(1, 4) * int(w.meta.get("epow", 1))
				_enemy_status(e, "burn", 2, pid)
			"void":
				rec.hp = mini(int(rec.hp) + 2 * int(w.meta.get("epow", 1)), int(rec.max_hp))
			"frost":
				if randf() < 0.12 * int(w.meta.get("epow", 1)):
					_enemy_status(e, "sleep", 1, pid)
			"verdant":
				rec.hp = mini(int(rec.hp) + int(w.meta.get("epow", 1)), int(rec.max_hp))
	# Resist / weak by damage tag.
	var tag: String = w.def.get("dtag", "physical") if not w.is_empty() else "physical"
	var def2: Dictionary = Db.ENEMIES[e.type]
	if tag in def2.get("resist", []):
		dmg = maxi(1, dmg / 2)
	elif tag in def2.get("weak", []):
		dmg = int(dmg * 1.5)
	e.hp = int(e.hp) - dmg
	rpc("cl_hit_fx", eid, dmg, "CRIT!" if crit else "")
	send_to(pid, "cl_strike_punch", [crit])
	# Knockback: landed hits shove the mob back (bosses hold their ground).
	var en = world.get_enemy(eid) if world != null else null
	var pn = world.get_player(pid) if world != null else null
	if en != null and pn != null and not bool(e.get("boss", false)):
		var kdir: Vector3 = en.global_position - pn.global_position
		kdir.y = 0.0
		if kdir.length() > 0.05:
			en.knock(kdir.normalized() * (2.5 + minf(float(dmg) * 0.12, 2.5)) + Vector3.UP * 2.5)
	award_prof(pid, "combat", 1)
	_sync_player(pid)
	# Boss phases: rage steps at 2/3 and 1/3 HP.
	if bool(e.get("boss", false)):
		var frac := float(e.hp) / float(e.max)
		var want := 3 if frac <= 0.33 else (2 if frac <= 0.66 else 1)
		if want > int(e.get("phase", 1)):
			e.phase = want
			e.atk = int(e.atk) + 1
			rpc("cl_notify", "— PHASE %d — %s roars, and the vault trembles!" % [want, e.name])
	if int(e.hp) <= 0:
		# Goldtouched pays out on the kill.
		if not w.is_empty() and String(w.meta.get("ench", "")) == "gilded":
			reward_gold(pid, 10 * int(w.meta.get("epow", 1)))
		var mend := int(armor_of(rec).ench.get("verdant", 0))
		if mend > 0:
			rec.hp = mini(int(rec.hp) + mend * 3, int(rec.max_hp))
		# Elite gold multiplier (Gilded x3, Cursed x1.5, Ancient x2) is stored
		# on the enemy at spawn but was only ever read by encounter.gd, which
		# nothing reaches — so on the live kill path elites paid normal gold.
		# Same shape as encounter.gd's payout.
		var kill_gold := randi_range(2, 12) + int(e.get("level", 0)) * 4
		kill_gold = int(kill_gold * float(e.get("gold_mult", 1.0)))
		reward_gold(pid, kill_gold)
		enemy_defeated(eid, pid)


func _enemy_status(e: Dictionary, kind: String, turns: int, by_pid: int = -1) -> void:
	var def: Dictionary = Db.ENEMIES[e.type]
	if (kind == "burn" and "fire" in def.get("resist", [])) \
			or (kind == "poison" and "poison" in def.get("resist", [])):
		return
	if not e.has("status"):
		e["status"] = {}
	e.status[kind] = maxi(int(e.status.get(kind, 0)), turns)
	# Remember who applied it so a kill by damage-over-time credits them
	# rather than defaulting to the host. Latest applier wins.
	if by_pid >= 0:
		e["dot_by"] = by_pid


@rpc("authority", "call_local", "reliable")
func cl_hit_fx(eid: int, dmg: int, txt: String) -> void:
	if world != null:
		world.spawn_hit_fx(eid, dmg, txt)


## Game-feel: FOV kick on YOUR landed hit; camera shake + red flash when hurt.
@rpc("authority", "call_local", "unreliable")
func cl_strike_punch(crit: bool) -> void:
	var p = world.get_player(multiplayer.get_unique_id()) if world != null else null
	if p != null:
		p.strike_punch(crit)


@rpc("authority", "call_local", "unreliable")
func cl_hurt_fx(frac: float) -> void:
	var p = world.get_player(multiplayer.get_unique_id()) if world != null else null
	if p != null:
		p.hurt_kick(frac)
	Events.player_hurt.emit(frac)


## One enemy swing at a player: d20 + atk vs the player's AC, plus specials.
@rpc("authority", "call_local", "unreliable")
func cl_lunge(eid: int) -> void:
	var n = world.get_enemy(eid) if world != null else null
	if n != null:
		n.play_lunge()


func _enemy_strike(eid: int, pid: int) -> void:
	var e: Dictionary = enemies[eid]
	var rec: Dictionary = players[pid]
	rpc("cl_lunge", eid)
	# Sleeping/frozen mobs don't swing (statuses tick down on the 1s tick).
	if int(e.get("status", {}).get("sleep", 0)) > 0:
		return
	var swings := 1
	var spec := String(e.special)
	var use_spec: bool = spec != "" and randf() < float(e.spec_chance)
	if use_spec and spec == "multiattack":
		swings = 2
	for s in range(swings):
		var d20 := randi_range(1, 20)
		var ac := player_ac(rec)
		if d20 == 1 or (d20 < 20 and d20 + int(e.atk) < ac):
			send_to(pid, "cl_notify", ["%s swings at you — deflected (AC %d)." % [e.name, ac]])
			continue
		var dd: Array = e.dmg
		var dmg := int(dd[2])
		for i in range(int(dd[0]) * (2 if d20 == 20 else 1)):
			dmg += randi_range(1, int(dd[1]))
		hurt_player(pid, dmg, e.name)
		send_to(pid, "cl_notify", ["%s hits you for %d%s" % [e.name, dmg, " — CRITICAL!" if d20 == 20 else "."]])
	if use_spec:
		match spec:
			"poison", "engulf", "acid_spit":
				rec.buffs.append({"k": "poison", "amt": 2, "until": Time.get_ticks_msec() + 6000})
				send_to(pid, "cl_notify", ["Venom seeps in — you are POISONED."])
			"gold_steal":
				var take: int = mini(int(rec.gold), randi_range(8, 20 + int(e.get("level", 0)) * 4))
				rec.gold = int(rec.gold) - take
				e["stolen"] = int(e.get("stolen", 0)) + take
				send_to(pid, "cl_notify", ["%s snatches %d gold!" % [e.name, take]])
			"luck_drain":
				rec.buffs.append({"k": "luck", "amt": -8, "until": Time.get_ticks_msec() + 30000})
				send_to(pid, "cl_notify", ["%s siphons your fortune." % e.name])
			"heal_self":
				e.hp = mini(int(e.hp) + int(e.max) / 6, int(e.max))
			"curse":
				rec.buffs.append({"k": "atk", "amt": -2, "until": Time.get_ticks_msec() + 15000})
				send_to(pid, "cl_notify", ["A black sigil saps your strength."])
	_sync_player(pid)


# ================================================================ encounters

func request_encounter(eid: int) -> void:
	if is_server():
		sv_encounter(eid)
	else:
		rpc_id(1, "sv_encounter", eid)


@rpc("any_peer", "reliable")
func sv_encounter(eid: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	_server_start_encounter(pid, eid)


## Parley/hunt only in the real-time era: passive = hunt, neutral = talk menu.
## Hostiles are fought live with LMB/bows/spells.
func _server_start_encounter(pid: int, eid: int, _ranged := false) -> void:
	var rec: Dictionary = players.get(pid, {})
	var e: Dictionary = enemies.get(eid, {})
	if rec.is_empty() or e.is_empty() or not e.alive or e.in_combat or rec.in_enc:
		return
	if String(e.get("disp", "hostile")) == "passive":
		# Offer wheat to tame it into a loyal follower; otherwise it's dinner.
		if bool(e.get("tamed", false)):
			send_to(pid, "cl_notify", ["%s nuzzles you happily." % e.name])
			return
		if _consume_id(rec, "wheat", 1):
			e.tamed = true
			e.owner_pid = pid
			e.name = "%s's %s" % [rec.name, e.name]
			rpc("cl_tame", eid, e.name, pid)
			send_to(pid, "cl_notify", ["It munches the wheat — %s now follows you!" % e.name])
			_sync_player(pid)
			return
		_server_hunt(pid, eid)
		return
	# Text parley is gone — neutrals use the Minecraft-simple trade window
	# (sv_npc_trade / sv_npc_quest); hostiles just get hit.
	return


# ---------------------------------------------------------------- npc (simple)

func request_npc_trade(eid: int, idx: int) -> void:
	if is_server():
		sv_npc_trade(eid, idx)
	else:
		rpc_id(1, "sv_npc_trade", eid, idx)


@rpc("any_peer", "reliable")
func sv_npc_trade(eid: int, idx: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	var e: Dictionary = enemies.get(eid, {})
	if rec.is_empty() or e.is_empty() or not e.alive or String(e.get("disp", "")) != "neutral":
		return
	var trades: Array = Db.ENEMIES[e.type].get("trades", [])
	if idx < 0 or idx >= trades.size():
		return
	var id: String = trades[idx]
	var price := int(Db.item_def(id).value * 1.2 * (1.0 - minf(int(rec.get("rep", 0)) * 0.05, 0.25)))
	if rec.gold < price:
		send_to(pid, "cl_notify", ["Not enough gold (%d needed)." % price])
		return
	if give_item(pid, id, 1, {}):
		rec.gold -= price
		send_to(pid, "cl_notify", ["Bought %s for %d gold." % [Db.item_def(id).name, price]])
	_sync_player(pid)


func request_npc_quest(eid: int) -> void:
	if is_server():
		sv_npc_quest(eid)
	else:
		rpc_id(1, "sv_npc_quest", eid)


## One-click quests: none → take one; done → turn in; else → progress toast.
@rpc("any_peer", "reliable")
func sv_npc_quest(eid: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	var e: Dictionary = enemies.get(eid, {})
	if rec.is_empty() or e.is_empty() or not e.alive:
		return
	var q: Dictionary = quests.get(pid, {})
	var rep := int(rec.get("rep", 0))
	if q.is_empty():
		var kill_types: Array = []
		for t in Db.ENEMIES:
			var d2: Dictionary = Db.ENEMIES[t]
			if String(d2.get("disposition", "hostile")) == "hostile" and not d2.boss \
					and maxi(player_band(pid), 1) >= int(d2.min_floor) and int(d2.min_floor) < 99:
				kill_types.append(t)
		if randf() < 0.6 and not kill_types.is_empty():
			var kt: String = kill_types[randi() % kill_types.size()]
			q = {"type": "kill", "target": kt, "n": randi_range(2, 4) + rep / 2, "done": 0,
				"reward": int((60 + player_band(pid) * 25) * (1.0 + rep * 0.2))}
			send_to(pid, "cl_notify", ["QUEST: slay %d %ss → %d gold." % [int(q.n), Db.ENEMIES[kt].name, int(q.reward)]])
		else:
			var wants := ["wheat", "hog_meat", "kelp", "luckroot", "bone"]
			var w: String = wants[randi() % wants.size()]
			q = {"type": "gather", "target": w, "n": randi_range(3, 5), "done": 0,
				"reward": int((50 + player_band(pid) * 20) * (1.0 + rep * 0.2))}
			send_to(pid, "cl_notify", ["QUEST: bring %d %s → %d gold." % [int(q.n), Db.item_def(w).name, int(q.reward)]])
		quests[pid] = q
	elif q.type == "kill" and int(q.done) >= int(q.n):
		reward_gold(pid, int(q.reward))
		grant_xp(pid, int(q.reward) / 2)
		quests.erase(pid)
		quest_completed(pid, String(e.type))
		send_to(pid, "cl_notify", ["QUEST COMPLETE: +%d gold." % int(q.reward)])
	elif q.type == "gather" and _count_of(rec, String(q.target)) >= int(q.n):
		_consume_id(rec, String(q.target), int(q.n))
		reward_gold(pid, int(q.reward))
		grant_xp(pid, int(q.reward) / 2)
		quests.erase(pid)
		quest_completed(pid, String(e.type))
		send_to(pid, "cl_notify", ["QUEST COMPLETE: +%d gold." % int(q.reward)])
	else:
		var need: String = Db.ENEMIES[q.target].name if q.type == "kill" else Db.item_def(q.target).name
		send_to(pid, "cl_notify", ["Quest: %d/%d %s." % [int(q.done) if q.type == "kill"
			else _count_of(rec, String(q.target)), int(q.n), need]])


## Aimed bow shot: consumes an arrow and resolves as a live ranged strike
## (double damage if the target never saw you).
func request_bow(eid: int) -> void:
	if is_server():
		sv_bow(eid)
	else:
		rpc_id(1, "sv_bow", eid)


@rpc("any_peer", "reliable")
func sv_bow(eid: int) -> void:
	if not is_server():
		return
	var pid := _sender()
	var rec: Dictionary = players.get(pid, {})
	var e: Dictionary = enemies.get(eid, {})
	if rec.is_empty() or e.is_empty() or not e.alive:
		return
	if not _consume_id(rec, "arrow", 1):
		send_to(pid, "cl_notify", ["No arrows left."])
		return
	# Best bow (ranged weapon) for the shot.
	var best := {}
	var best_avg := -1.0
	for entry in rec.inv:
		if entry == null:
			continue
		var def: Dictionary = Db.item_def(entry.id)
		if def.kind != "weapon" or not def.get("ranged", false):
			continue
		var avg: float = def.dmg[0] * (def.dmg[1] + 1) * 0.5 + def.dmg[2]
		if avg > best_avg:
			best_avg = avg
			best = {"def": def, "meta": entry.get("meta", {})}
	if best.is_empty():
		return
	_strike(pid, eid, best, true)


## Ochre Jelly split: a quarter-strength copy oozes off nearby (server).
func spawn_split(eid: int) -> void:
	var e: Dictionary = enemies.get(eid, {})
	if e.is_empty():
		return
	var child: Dictionary = e.duplicate(true)
	child.id = _next_eid
	_next_eid += 1
	child.hp = maxi(int(e.max) / 4, 8)
	child.max = child.hp
	child.name = "Lesser " + String(e.name)
	child.xp = int(e.xp) / 3
	child.special = ""
	child.in_combat = false
	child.split_done = true
	child.pos = Vector3(e.pos) + Vector3(randf_range(-2, 2), 0.5, randf_range(-2, 2))
	enemies[int(child.id)] = child
	rpc("cl_spawn_enemy", child)


func _server_hunt(pid: int, eid: int) -> void:
	var e: Dictionary = enemies[eid]
	var rec: Dictionary = players[pid]
	e.alive = false
	rpc("cl_despawn_enemy", eid)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var lucky: bool = rng.randf() * 100.0 < eff_luck(rec) * 0.5
	for d in Db.ENEMIES[e.type].get("drops", []):
		var count := int(d.count) * (2 if lucky else 1)
		server_spawn_pickup(e.pos + Vector3(rng.randf_range(-0.6, 0.6), 0.5,
			rng.randf_range(-0.6, 0.6)), {"id": d.id, "count": count, "meta": {}},
			_next_loot_owner())
	grant_xp(pid, int(e.xp))
	send_to(pid, "cl_notify", ["You hunt the %s.%s" % [e.name, " A lucky, clean strike — double yield!" if lucky else ""]])


func request_enc_action(action: String) -> void:
	if is_server():
		sv_enc_action(action)
	else:
		rpc_id(1, "sv_enc_action", action)


@rpc("any_peer", "reliable")
func sv_enc_action(action: String) -> void:
	if not is_server():
		return
	var pid := _sender()
	if encounters.has(pid):
		encounters[pid].handle(action)


@rpc("authority", "reliable")
func cl_enc_state(state: Dictionary) -> void:
	Events.enc_state.emit(state)


func push_enc_state(pid: int, state: Dictionary) -> void:
	send_to(pid, "cl_enc_state", [state])


func encounter_over(pid: int) -> void:
	encounters.erase(pid)
	if players.has(pid):
		players[pid].in_enc = false
		_sync_player(pid)


func enemy_defeated(eid: int, by_pid: int) -> void:
	var e: Dictionary = enemies.get(eid, {})
	if e.is_empty():
		return
	e.alive = false
	rpc("cl_despawn_enemy", eid)
	var rec: Dictionary = players.get(by_pid, {})
	if not rec.is_empty():
		grant_xp(by_pid, int(e.get("xp", 30)))
		award_prof(by_pid, "combat", maxi(2, int(e.get("xp", 20)) / 10))
		# Thieves cough up everything they snatched (cave imps, coin bats...).
		var stolen := int(e.get("stolen", 0))
		if stolen > 0:
			rec.gold = int(rec.gold) + stolen
			send_to(by_pid, "cl_notify", ["You recover %d stolen gold from %s!" % [stolen, e.name]])
			_sync_player(by_pid)
		# Quest progress: kill contracts.
		var q: Dictionary = quests.get(by_pid, {})
		if not q.is_empty() and q.type == "kill" and String(q.target) == String(e.type):
			q.done = int(q.done) + 1
			send_to(by_pid, "cl_notify", ["Quest: %d/%d %s." % [int(q.done), int(q.n), e.name]])
		# Adaptive threat: comfortable wins ratchet the dungeon up.
		var hp_frac: float = float(rec.hp) / float(rec.max_hp)
		if hp_frac > 0.7:
			threat = minf(threat + 0.03, 1.4)
		elif hp_frac < 0.3:
			threat = maxf(threat - 0.02, 0.7)
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var pt := party()
		var bonus: float = float(rec.passives.get("loot_bonus", 0.0)) \
			+ (0.5 if e.get("elite", "") != "" else 0.0) \
			+ (float(pt.n) - 1.0) * 0.08 + (float(pt.avg) - 1.0) * 0.01
		var drops: Array = Db.roll_loot(rng, int(e.get("level", 0)), eff_luck(rec), bonus)
		drops.append_array(Db.ENEMIES[e.type].get("drops", []).map(
			func(d): return {"id": d.id, "count": int(d.count), "meta": {}}))
		var node = world.get_player(by_pid)
		var at: Vector3 = e.pos if node == null else node.global_position
		for d in drops:
			server_spawn_pickup(at + Vector3(rng.randf_range(-1.2, 1.2), 0.6,
				rng.randf_range(-1.2, 1.2)), d, _next_loot_owner())
	if bool(e.get("boss", false)):
		rpc("cl_notify", "%s FALLS. The Deep grows quiet... for now." % String(e.name).to_upper())
		for pid in players:
			give_item(pid, "gambit_cache", 1, {})
		# Signature drops beam down at the corpse for whoever claims them.
		for d in Db.BOSS_DROPS.get(String(e.type), []):
			server_spawn_pickup(Vector3(e.pos) + Vector3(randf_range(-1, 1), 0.8,
				randf_range(-1, 1)), {"id": d.id, "count": int(d.count), "meta": {}}, 0)
	else:
		rpc("cl_notify", "%s slays %s!" % [rec.get("name", "?"), e.get("name", "a foe")])


## Loot-rule owner for the next drop: 0 = anyone (ffa), else a specific pid.
func _next_loot_owner() -> int:
	if loot_rule != "round_robin" or players.is_empty():
		return 0
	var pids: Array = players.keys()
	pids.sort()
	_rr_cursor = (_rr_cursor + 1) % pids.size()
	return pids[_rr_cursor]


## Gold payouts honoring loot rules and passives. Kills, chests, caches all
## route through here so shared_gold splits everything evenly.
func reward_gold(pid: int, amount: int) -> void:
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	amount = int(amount * (1.0 + float(rec.passives.get("bounty", 0.0))))
	if rec.mutations.has("cursed_veins"):
		amount = int(amount * 0.75)
	if loot_rule == "shared_gold" and players.size() > 1:
		var share := maxi(1, amount / players.size())
		for opid in players:
			players[opid].gold += share
			_sync_player(opid)
		rpc("cl_notify", "The party splits %d gold (%d each)." % [amount, share])
	else:
		rec.gold += amount
		_sync_player(pid)


func grant_xp(pid: int, amount: int) -> void:
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	rec.xp += amount
	while rec.xp >= Db.xp_for_level(int(rec.level)):
		rec.xp -= Db.xp_for_level(int(rec.level))
		rec.level += 1
		rec.max_hp += 10
		rec.hp = rec.max_hp
		rec.max_mana = int(rec.get("max_mana", 40)) + 5
		rec.mana = rec.max_mana
		rec.luck += 1
		rec.skill_points = int(rec.get("skill_points", 0)) + 1
		send_to(pid, "cl_notify", ["Level %d! +10 HP, +1 luck, +1 skill point (K to spend)." % int(rec.level)])
	_sync_player(pid)


## Use-based discipline XP (smithing, alchemy, mining...). Levels notify.
func award_prof(pid: int, skill: String, amount: int) -> void:
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	if not rec.has("prof"):
		rec.prof = Db.new_profs()
	var p: Dictionary = rec.prof.get(skill, {"xp": 0, "lvl": 1})
	p.xp = int(p.xp) + amount
	var leveled := false
	while int(p.xp) >= Db.prof_xp_needed(int(p.lvl)) and int(p.lvl) < 50:
		p.xp = int(p.xp) - Db.prof_xp_needed(int(p.lvl))
		p.lvl = int(p.lvl) + 1
		leveled = true
	rec.prof[skill] = p
	if leveled:
		send_to(pid, "cl_notify", ["%s rose to %d." % [skill.capitalize(), int(p.lvl)]])
		_sync_player(pid)


func request_allocate(skill: String) -> void:
	if is_server():
		sv_allocate(skill)
	else:
		rpc_id(1, "sv_allocate", skill)


@rpc("any_peer", "reliable")
func sv_allocate(skill: String) -> void:
	if not is_server():
		return
	var rec: Dictionary = players.get(_sender(), {})
	if rec.is_empty() or not (skill in Db.PROFS) or int(rec.get("skill_points", 0)) <= 0:
		return
	rec.skill_points = int(rec.skill_points) - 1
	rec.alloc[skill] = int(rec.get("alloc", {}).get(skill, 0)) + 1
	# Perk thresholds: named perks unlock at 1 / 3 / 5 points.
	for perk in Db.PERKS.get(skill, []):
		if int(rec.alloc[skill]) == int(perk.at):
			rec.passives[perk.key] = float(rec.passives.get(perk.key, 0.0)) + float(perk.val)
			send_to(int(rec.pid), "cl_notify", ["PERK UNLOCKED: %s — %s!" % [perk.name, perk.desc]])
	send_to(int(rec.pid), "cl_notify", ["%s mastery deepens (+2 effective levels)." % skill.capitalize()])
	_sync_player(int(rec.pid))


## Best-armor scan: total AC (base + smith quality) and enchant powers.
func armor_of(rec: Dictionary) -> Dictionary:
	var best := {}  # slot -> {"ac": int, "ench": String, "epow": int}
	for e in rec.get("inv", []):
		if e == null:
			continue
		var def: Dictionary = Db.item_def(e.id)
		if def.kind != "armor":
			continue
		var meta: Dictionary = e.get("meta", {})
		var ac: int = int(def.ac) + int(meta.get("quality", 0))
		var slot: String = def.slot
		if not best.has(slot) or ac > int(best[slot].ac):
			best[slot] = {"ac": ac, "ench": String(meta.get("ench", "")),
				"epow": int(meta.get("epow", 0))}
	var out := {"ac": 0, "ench": {}}
	for slot in best:
		out.ac += int(best[slot].ac)
		if best[slot].ench != "":
			out.ench[best[slot].ench] = maxi(int(out.ench.get(best[slot].ench, 0)), int(best[slot].epow))
	return out


func has_gills(rec: Dictionary) -> bool:
	for b in rec.get("buffs", []):
		if b.k == "gills":
			return true
	return armor_of(rec).ench.has("frost")  # Tideborn armor enchant


## Server: apply damage to a player, honoring die-hard; handles defeat.
func hurt_player(pid: int, dmg: int, why: String) -> void:
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	# Stoneskin buff blocks damage entirely.
	for b in rec.buffs:
		if b.k == "stone":
			send_to(pid, "cl_notify", ["Stoneblood shrugs it off."])
			return
	rec.hp -= dmg
	send_to(pid, "cl_hurt_fx", [clampf(float(dmg) / float(rec.max_hp), 0.0, 1.0)])
	# Heavy hits can wound a body part: head (-luck), arms (-attack),
	# legs (slower), body (-AC). Healing cures (see EffectExec / Cooking).
	if dmg >= int(rec.max_hp) / 4 and randf() < 0.35:
		var slots := ["head", "arms", "legs", "body"]
		var slot: String = slots[randi() % slots.size()]
		if not rec.get("injuries", {}).has(slot):
			if not rec.has("injuries"):
				rec.injuries = {}
			rec.injuries[slot] = true
			send_to(pid, "cl_notify", ["INJURY: your %s — find healing to mend it." % slot])
	if rec.hp <= 0:
		if rec.mutations.has("die_hard") and not rec.die_hard_used:
			rec.die_hard_used = true
			rec.hp = 1
			send_to(pid, "cl_notify", ["Die Hard! You refuse the reaper."])
		else:
			var lost := int(rec.gold) - int(rec.gold / 2)
			last_deaths[pid] = {"gold": lost, "t": Time.get_ticks_msec()}
			rec.hp = rec.max_hp
			rec.gold = int(rec.gold / 2)
			rec.buffs = []
			threat = maxf(threat - 0.12, 0.7)  # the dungeon eases off after a kill
			# Corpse run: everything drops where you fell — except spells,
			# enchanted gear, and spellbound items (bind treasures at the altar).
			var death_node = world.get_player(pid)
			if death_node != null:
				var dpos: Vector3 = death_node.global_position
				var dropped := 0
				for i in range(INV_SIZE):
					var it = rec.inv[i]
					if it == null:
						continue
					var m: Dictionary = it.get("meta", {})
					if Db.item_def(it.id).kind == "spell" or m.has("ench") \
							or m.get("spellbound", false):
						continue
					server_spawn_pickup(dpos + Vector3(randf_range(-1.5, 1.5), 0.6,
						randf_range(-1.5, 1.5)), it, pid)
					rec.inv[i] = null
					dropped += 1
				if dropped > 0:
					send_to(pid, "cl_notify", ["Your gear lies where you fell (%d items) — go reclaim it." % dropped])
			if encounters.has(pid):
				encounters[pid].abort()
			# Wake at the nearest campfire if the party has set one up.
			var node = world.get_player(pid)
			var respawn: Vector3 = gen_info.spawn
			if node != null:
				var best := INF
				for key in camps:
					var d: float = Vector3(camps[key]).distance_to(node.global_position)
					if d < best:
						best = d
						respawn = Vector3(camps[key]) + Vector3(1, 0.7, 0)
			rpc("cl_notify", "%s falls (%s) — they wake %s, pockets lighter." %
				[rec.name, why, "by a campfire" if respawn != gen_info.spawn else "at the floor gate"])
			if node != null:
				rpc("cl_teleport", pid, respawn)
	_sync_player(pid)


@rpc("authority", "call_local", "reliable")
func cl_teleport(pid: int, pos: Vector3) -> void:
	if world != null:
		var node = world.get_player(pid)
		if node != null:
			node.teleport_to(pos)


# ================================================================ enemies (server tick + replication)

## Party snapshot for difficulty & loot scaling.
func party() -> Dictionary:
	var n := maxi(players.size(), 1)
	var total := 0
	for pid in players:
		total += int(players[pid].get("level", 1))
	return {"n": n, "avg": maxf(float(total) / n, 1.0)}


## Builds a fully-statted mob: base def → floor curve → adaptive threat →
## party size & level scaling → optional elite modifier.
## Passive/neutral mobs skip the scaling and elites.
func _server_spawn_enemy(type: String, pos: Vector3) -> void:
	var def: Dictionary = Db.ENEMIES[type]
	var disp := String(def.get("disposition", "hostile"))
	var pt := party()
	var band := Db.band_at(pos.y)  # depth is the difficulty axis now
	var curve := 1.0 + 0.14 * band
	if disp == "hostile":
		# Party scaling capped so 12-player lobbies get bigger packs, not sponges.
		curve *= minf(1.0 + 0.3 * (float(pt.n) - 1.0), 2.5) * (1.0 + 0.04 * (float(pt.avg) - 1.0))
	var hp := int(def.hp * curve * (threat if disp == "hostile" else 1.0))
	var atk := int(def.atk) + band / 3
	if disp == "hostile":
		atk += int((float(pt.avg) - 1.0) / 4.0)
	var ac := int(def.ac) + band / 4
	var dmg: Array = [int(def.dmg[0]), int(def.dmg[1]), int(def.dmg[2]) + band / 3]
	var ename: String = def.name
	var elite := ""
	var gold_mult := 1.0
	if disp == "hostile" and not def.boss \
			and randf() < clampf(0.06 + band * 0.015 + (threat - 1.0) * 0.4, 0.0, 0.5):
		elite = Db.ELITES.keys()[randi() % Db.ELITES.size()]
		var em: Dictionary = Db.ELITES[elite]
		hp = int(hp * float(em.hp))
		atk += int(em.atk)
		ac += int(em.ac)
		gold_mult = float(em.gold)
		ename = "%s %s" % [em.name, ename]
	if bool(def.boss):
		atk += int((threat - 1.0) * 4.0)
	var e := {"id": _next_eid, "type": type, "name": ename, "elite": elite,
		"disp": disp, "guard": int(def.get("guard", 10)),
		"hp": hp, "max": hp, "ac": ac, "atk": atk, "dmg": dmg,
		"xp": int(int(def.xp) * curve), "special": def.special,
		"spec_chance": def.spec_chance, "boss": def.boss, "gold_mult": gold_mult,
		"pos": pos, "level": band, "alive": true, "in_combat": false, "cooldown": 0.0}
	enemies[_next_eid] = e
	_next_eid += 1
	rpc("cl_spawn_enemy", e)


@rpc("authority", "call_local", "reliable")
func cl_spawn_enemy(e: Dictionary) -> void:
	if world != null:
		world.spawn_enemy(e)


@rpc("authority", "call_local", "reliable")
func cl_tame(eid: int, new_name: String, owner_pid: int) -> void:
	var n = world.get_enemy(eid) if world != null else null
	if n != null:
		n.display_name = new_name
		n.tamed = true
		n.owner_pid = owner_pid
	AudioMgr.sfx("sfx_magic", -8.0)


@rpc("authority", "call_local", "reliable")
func cl_despawn_enemy(eid: int) -> void:
	if world != null:
		world.despawn_enemy(eid)


@rpc("authority", "unreliable")
func cl_enemy_positions(posmap: Dictionary) -> void:
	if world != null:
		world.update_enemy_positions(posmap)


func _process(delta: float) -> void:
	if in_run:
		world_time += delta
		if is_server() and multiplayer.multiplayer_peer != null:
			_time_accum += delta
			if _time_accum >= 7.0:
				_time_accum = 0.0
				rpc("cl_time", world_time)
	if not in_run or not is_server() or world == null:
		return
	# Fluid simulation: server metronome; each beat is an op in the log, so
	# every peer (and every save replay) steps the sim identically.
	_fluid_accum += delta
	if _fluid_accum >= 0.3:
		_fluid_accum = 0.0
		if voxel != null and voxel.has_active_fluids():
			_apply_edit({"t": "fluid", "p": [0, 0, 0]})
	# World spawner: mob pressure follows the players, scaled by depth.
	_spawner_accum += delta
	if _spawner_accum >= 8.0:
		_spawner_accum = 0.0
		_server_tick_spawner()
	# Crops random-tick like Minecraft: growth needs block light >= 8.
	_crop_accum += delta
	if _crop_accum >= 3.0:
		_crop_accum = 0.0
		_server_tick_crops()
	# 1s tick: regen buffs + campfire rest aura.
	_slow_accum += delta
	if _slow_accum >= 1.0:
		_slow_accum = 0.0
		_server_tick_camps_and_regen()
	_crush_accum += delta
	if _crush_accum >= 0.7:
		_crush_accum = 0.0
		_server_tick_crushers()
	_tick += delta
	if _tick < 0.2:
		return
	_tick = 0.0
	_server_tick_enemies()
	_server_tick_hazards()
	_server_tick_traps()
	_server_tick_pickups()
	_server_tick_buffs()


func _server_tick_crops() -> void:
	for key in crops.keys():
		var c: Vector3i = crops[key]
		var id: int = voxel.get_block_v(c)
		if id != Blocks.CROP_1 and id != Blocks.CROP_2:
			crops.erase(key)
			continue
		if voxel.light_at(c.x, c.y, c.z) < 8:
			continue  # too dark to grow — bring glowstone or a campfire
		if randf() < 0.25:
			var next: int = Blocks.CROP_2 if id == Blocks.CROP_1 else Blocks.CROP_RIPE
			_apply_edit({"t": "set", "p": [c.x, c.y, c.z], "b": next})


## 1s tick: out-of-combat enemy DoTs resolve here (burn/poison/sleep decay).
func _server_tick_enemy_statuses() -> void:
	for eid in enemies.keys():
		var e: Dictionary = enemies[eid]
		if not e.alive or e.in_combat or not e.has("status"):
			continue
		var st: Dictionary = e.status
		if int(st.get("burn", 0)) > 0:
			st.burn = int(st.burn) - 1
			e.hp = int(e.hp) - 4
		if int(st.get("poison", 0)) > 0:
			st.poison = int(st.poison) - 1
			e.hp = int(e.hp) - 3
		if int(st.get("sleep", 0)) > 0:
			st.sleep = int(st.sleep) - 1
		if int(e.hp) <= 0:
			# Credit whoever applied the burn/poison. This was hardcoded to
			# peer 1, handing the host every client's damage-over-time kill.
			enemy_defeated(eid, int(e.get("dot_by", 1)))


var _ambush_t := 150.0

## Timed floor events, one of five every couple of minutes: ambushes, gold
## rushes, cave-ins, gas leaks, and wandering merchants.
func _server_tick_ambush() -> void:
	if players.is_empty():
		return
	_ambush_t -= 1.0
	if _ambush_t > 0.0:
		return
	_ambush_t = randf_range(120.0, 200.0)
	var pids: Array = players.keys()
	var target: int = pids[randi() % pids.size()]
	var p = world.get_player(target)
	if p == null:
		return
	var at: Vector3 = p.global_position
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	match randi() % 5:
		0, 1:  # ambush (most common)
			rpc("cl_notify", "⚠ AMBUSH — the dark closes in on %s!" % players[target].name)
			for i in range(2 + party().n / 2):
				var a := randf() * TAU
				_server_spawn_enemy(Db.pick_enemy_type(rng, maxi(player_band(target), 1), threat),
					at + Vector3(cos(a) * 6.0, 1.0, sin(a) * 6.0))
		2:  # gold rush
			rpc("cl_notify", "✨ GOLD RUSH — a rich vein splits the stone near %s!" % players[target].name)
			_apply_edit({"t": "sphere_replace", "p": [int(at.x) + 4, int(at.y), int(at.z)],
				"r": 2.5, "from": [Blocks.STONE, Blocks.BRICK, Blocks.DIRT], "b": Blocks.GOLD_ORE})
		3:  # cave-in: gravel pours from above and cascades down
			rpc("cl_notify", "⚠ CAVE-IN above %s — the ceiling gives way!" % players[target].name)
			_apply_edit({"t": "sphere", "p": [int(at.x), int(at.y) + 5, int(at.z)],
				"r": 2.0, "b": Blocks.GRAVEL})
			hurt_player(target, 6, "falling rock")
		4:  # gas leak or merchant
			if randf() < 0.5:
				rpc("cl_notify", "☠ GAS LEAK — something hisses out of the cracked floor!")
				spawn_gas_cloud(at + Vector3(3, 1, 0), 2.2,
					[Blocks.GAS_POISON_2, Blocks.GAS_SLEEP_2][randi() % 2])
			else:
				rpc("cl_notify", "🏮 A wandering merchant's lantern bobs toward %s." % players[target].name)
				_server_spawn_enemy("lost_explorer", at + Vector3(5, 1, 2))


func _server_tick_camps_and_regen() -> void:
	_server_tick_enemy_statuses()
	_server_tick_fishing()
	_server_tick_ambush()
	for pid in players:
		var rec: Dictionary = players[pid]
		var p = world.get_player(pid)
		if p == null or int(rec.hp) <= 0:
			continue
		var heal := 0
		var mana_regen := 2
		for b in rec.buffs:
			if b.k == "regen":
				heal += int(b.amt)
			elif b.k == "poison":
				hurt_player(pid, int(b.amt), "poison")
		for key in camps:
			if p.global_position.distance_to(camps[key]) < 6.0:
				heal += 1
				mana_regen += 3
				break
		var changed := false
		if heal > 0 and int(rec.hp) < int(rec.max_hp):
			rec.hp = mini(int(rec.hp) + heal, int(rec.max_hp))
			changed = true
		if int(rec.get("mana", 0)) < int(rec.get("max_mana", 40)):
			rec.mana = mini(int(rec.get("mana", 0)) + mana_regen, int(rec.get("max_mana", 40)))
			changed = true
		if changed:
			_sync_player(pid)


func _server_tick_enemies() -> void:
	var posmap := {}
	for eid in enemies:
		var e: Dictionary = enemies[eid]
		if not e.alive:
			continue
		e.cooldown = maxf(0.0, float(e.cooldown) - 0.2)
		var node = world.get_enemy(eid)
		if node == null:
			continue
		# World status effects: gases sedate/poison mobs, lava ignites them.
		var epos := Vector3i(Vector3(e.pos).floor())
		var ekind := Blocks.fluid_kind(voxel.get_block_v(epos + Vector3i(0, 1, 0)))
		if not e.has("status"):
			e["status"] = {}
		match ekind:
			"sleep_gas":
				e.status.sleep = maxi(int(e.status.get("sleep", 0)), 2)
			"poison_gas":
				e.status.poison = maxi(int(e.status.get("poison", 0)), 3)
			"lava":
				e.status.burn = maxi(int(e.status.get("burn", 0)), 2)
		if int(e.status.get("sleep", 0)) > 0:
			posmap[eid] = e.pos
			continue  # out cold — no wandering, no ambushes
		# De-aggro: lose track of players who get far enough away.
		if bool(e.get("aware", false)):
			var still_near := false
			for pid2 in players:
				var pn2 = world.get_player(pid2)
				if pn2 != null and pn2.global_position.distance_to(Vector3(e.pos)) < 14.0:
					still_near = true
					break
			if not still_near:
				e.aware = false
		if not e.in_combat:
			node.smoked = is_smoked(e.pos)
			node.tick_ai(players, world)
		e.pos = node.global_position
		posmap[eid] = e.pos
		# Provoked neutrals fight like hostiles.
	# Real-time attacks: hostiles swing at whoever is in reach, on their
		# own cooldown (e.cooldown doubles as attack timer).
		if String(e.get("disp", "hostile")) == "hostile" and e.cooldown <= 0.0:
			var reach := 7.5 if bool(Db.ENEMIES[e.type].get("ranged", false)) else ENEMY_ATK_RANGE
			for pid in players:
				var p = world.get_player(pid)
				if p == null or p.global_position.distance_to(Vector3(e.pos)) > reach:
					continue
				e.aware = true
				# Bosses TELEGRAPH: a marked wind-up, then the blow lands.
				if bool(e.get("boss", false)) and not bool(e.get("windup", false)):
					e.windup = true
					e.cooldown = 0.8
					rpc("cl_hit_fx", eid, 0, "⚠ WINDUP")
					send_to(pid, "cl_notify", ["%s rears back — MOVE!" % e.name])
					break
				e.windup = false
				e.cooldown = 1.6
				_enemy_strike(eid, pid)
				break
	if not posmap.is_empty():
		rpc("cl_enemy_positions", posmap)


func _server_tick_hazards() -> void:
	for pid in players:
		var p = world.get_player(pid)
		if p == null:
			continue
		var bp: Vector3 = p.global_position
		var under := voxel.get_block(int(floor(bp.x)), int(floor(bp.y - 0.2)), int(floor(bp.z)))
		var at := voxel.get_block(int(floor(bp.x)), int(floor(bp.y + 0.3)), int(floor(bp.z)))
		var kinds := [Blocks.fluid_kind(under), Blocks.fluid_kind(at)]
		if "lava" in kinds:
			hurt_player(pid, 6, "lava")
		elif "acid" in kinds:
			hurt_player(pid, 4, "acid")
		# Oxygen: head submerged in liquid drains breath; gills negate it.
		var rec: Dictionary = players[pid]
		var head := voxel.get_block(int(floor(bp.x)), int(floor(bp.y + 1.4)), int(floor(bp.z)))
		var head_kind := Blocks.fluid_kind(head)
		var old_breath := int(rec.get("breath", BREATH_MAX))
		if head_kind != "" and not Blocks.is_gas(head):
			if has_gills(rec):
				rec.breath = BREATH_MAX
			else:
				rec.breath = float(rec.get("breath", BREATH_MAX)) - 0.2
				if float(rec.breath) <= 0.0:
					rec.breath = 0.0
					# Per-player drown cadence (was a shared accumulator).
					rec["_drown"] = float(rec.get("_drown", 0.0)) + 0.2
					if float(rec["_drown"]) >= 1.0:
						rec["_drown"] = 0.0
						hurt_player(pid, 3, "drowning")
		else:
			rec.breath = minf(float(rec.get("breath", BREATH_MAX)) + 1.0, BREATH_MAX)
		if int(rec.breath) != old_breath:
			_sync_player(pid)


# ================================================================ traps & gases

## Contact triggers: tripwires, glyphs, spikes, webs handled here; gas contact
## applies status buffs. All world consequences go through the edit log.
func _server_tick_traps() -> void:
	var now := Time.get_ticks_msec()
	for pid in players:
		var p = world.get_player(pid)
		if p == null or players[pid].in_enc:
			continue
		var rec: Dictionary = players[pid]
		var bp: Vector3 = p.global_position
		var feet := Vector3i(int(floor(bp.x)), int(floor(bp.y + 0.1)), int(floor(bp.z)))
		var body := Vector3i(feet.x, feet.y + 1, feet.z)
		for cell in [feet, body]:
			var bid: int = voxel.get_block_v(cell)
			var parr := [cell.x, cell.y, cell.z]
			match bid:
				Blocks.TRIP_EXPL:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.AIR})
					_apply_edit({"t": "sphere", "p": parr, "r": 2.5, "b": Blocks.AIR})
					hurt_player(pid, 10 + Db.band_at(float(parr[1])) * 2, "an explosive tripwire")
					rpc("cl_notify", "A tripwire SNAPS — the wall detonates!")
				Blocks.TRIP_ACID:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.ACID})
					_apply_edit({"t": "set", "p": [parr[0] + 1, parr[1], parr[2]], "b": Blocks.ACID})
					rpc("cl_notify", "A tripwire snaps — acid floods the floor!")
				Blocks.TRIP_LAVA:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.LAVA})
					rpc("cl_notify", "A tripwire snaps — lava pours from the ceiling!")
				Blocks.RUNE_TRAP:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.AIR})
					_apply_edit({"t": "sphere", "p": parr, "r": 3.0, "b": Blocks.AIR})
					hurt_player(pid, 14 + Db.band_at(float(parr[1])) * 2, "a blast glyph")
					rpc("cl_notify", "The glyph flares and DETONATES!")
				Blocks.TELE_TRAP:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.AIR})
					var wrng := RandomNumberGenerator.new()
					wrng.randomize()
					var dest := _find_spawn_spot(p.global_position, wrng)
					if dest == Vector3.ZERO:
						dest = gen_info.spawn
					rpc("cl_teleport", pid, dest)
					send_to(pid, "cl_notify", ["The floor swallows you — a warp glyph spits you out elsewhere."])
				Blocks.CRUSH_TRIGGER:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.AIR})
					_arm_crusher(cell)
			# Gas contact.
			match Blocks.fluid_kind(bid):
				"poison_gas":
					hurt_player(pid, 2, "poison gas")
				"sleep_gas":
					_set_buff(rec, "sleep", 1, now + 2500)
					_sync_player(pid)
				"invert_gas":
					_set_buff(rec, "invert", 1, now + 15000)
					_sync_player(pid)
		# Spikes bite whoever stands in them (slow cadence via hazard damage).
		if voxel.get_block_v(feet) == Blocks.SPIKES:
			hurt_player(pid, 3, "spikes")
		# Dart holes in nearby walls: sleep dart + sting, per-trap cooldown.
		for dx in range(-3, 4):
			for dy in range(-1, 2):
				for dz in range(-3, 4):
					var dc := Vector3i(feet.x + dx, feet.y + dy, feet.z + dz)
					if voxel.get_block_v(dc) != Blocks.DART_TRAP:
						continue
					var key := "%d,%d,%d" % [dc.x, dc.y, dc.z]
					if int(_dart_cooldowns.get(key, 0)) > now:
						continue
					_dart_cooldowns[key] = now + 4000
					hurt_player(pid, 4, "a sleep dart")
					_set_buff(rec, "sleep", 1, now + 2000)
					_sync_player(pid)
					send_to(pid, "cl_notify", ["A dart hisses from the wall — your eyelids drag."])


func _set_buff(rec: Dictionary, k: String, amt: int, until: int) -> void:
	for b in rec.buffs:
		if b.k == k:
			b.until = maxi(int(b.until), until)
			return
	rec.buffs.append({"k": k, "amt": amt, "until": until})


## Old-school crushers: a plane of spikes descends from the ceiling or closes
## in from the side, then everything resets to air.
func _arm_crusher(at: Vector3i) -> void:
	var vertical := randf() < 0.6
	var c := {}
	if vertical:
		c = {"axis": "y", "cur": at.y + 5, "end": at.y + 1, "dir": -1,
			"min": Vector3i(at.x - 3, 0, at.z - 3), "max": Vector3i(at.x + 3, 0, at.z + 3), "prev": -999}
		rpc("cl_notify", "Stone grinds above — the SPIKED CEILING is coming down!")
	else:
		c = {"axis": "x", "cur": at.x - 4, "end": at.x + 4, "dir": 1,
			"min": Vector3i(0, at.y, at.z - 2), "max": Vector3i(0, at.y + 2, at.z + 2), "prev": -999}
		rpc("cl_notify", "The wall shrieks — SPIKES close in from the side!")
	_crushers.append(c)


func _server_tick_crushers() -> void:
	for i in range(_crushers.size() - 1, -1, -1):
		var c: Dictionary = _crushers[i]
		# Clear the previous plane (the wall of spikes moves, not grows).
		if int(c.prev) != -999:
			_crusher_plane(c, int(c.prev), Blocks.AIR)
		if int(c.cur) == int(c.end) + int(c.dir):
			_crushers.remove_at(i)
			continue
		_crusher_plane(c, int(c.cur), Blocks.SPIKES)
		# Anyone caught in the plane is impaled.
		for pid in players:
			var p = world.get_player(pid)
			if p == null:
				continue
			var cell := Vector3i((p.global_position + Vector3(0, 0.5, 0)).floor())
			var hit: bool = (c.axis == "y" and cell.y == int(c.cur) \
				and cell.x >= c.min.x and cell.x <= c.max.x and cell.z >= c.min.z and cell.z <= c.max.z) \
				or (c.axis == "x" and cell.x == int(c.cur) \
				and cell.y >= c.min.y and cell.y <= c.max.y and cell.z >= c.min.z and cell.z <= c.max.z)
			if hit:
				hurt_player(pid, 15, "the crusher")
		c.prev = c.cur
		c.cur = int(c.cur) + int(c.dir)


func _crusher_plane(c: Dictionary, coord: int, block: int) -> void:
	var from_id: int = Blocks.AIR if block == Blocks.SPIKES else Blocks.SPIKES
	if c.axis == "y":
		_apply_edit({"t": "box_replace", "p": [c.min.x, coord, c.min.z],
			"q": [c.max.x, coord, c.max.z], "b": block, "from": from_id})
	else:
		_apply_edit({"t": "box_replace", "p": [coord, c.min.y, c.min.z],
			"q": [coord, c.max.y, c.max.z], "b": block, "from": from_id})


## Sphere of gas blocks — smoke bombs, gas flasks, spells. Fills open air;
## with overwrite it also displaces other gases (smoke wins over poison so a
## smoke bomb still shrouds you inside someone's gas cloud).
func spawn_gas_cloud(at: Vector3, radius: float, gas_id: int, overwrite := false) -> void:
	var from := [Blocks.AIR]
	if overwrite:
		for id in Blocks.DEFS:
			if Blocks.DEFS[id].has("gas"):
				from.append(id)
	_apply_edit({"t": "sphere_replace", "p": [int(floor(at.x)), int(floor(at.y)), int(floor(at.z))],
		"r": radius, "from": from, "b": gas_id})


## True if a position sits in (or beside) smoke — hides you from stalkers
## and sets up sneak attacks.
func is_smoked(at: Vector3) -> bool:
	var c := Vector3i(at.floor())
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if Blocks.fluid_kind(voxel.get_block(c.x + dx, c.y + dy, c.z + dz)) == "smoke":
					return true
	return false


func _server_tick_pickups() -> void:
	var taken: Array = []
	for kid in pickups:
		var k: Dictionary = pickups[kid]
		for pid in players:
			if int(k.get("owner", 0)) != 0 and int(k.owner) != pid:
				continue  # round-robin: reserved for its assignee
			var p = world.get_player(pid)
			if p != null and p.global_position.distance_to(k.pos) < PICKUP_RADIUS:
				if give_item(pid, k.item.id, k.item.count, k.item.meta):
					taken.append(kid)
				break
	for kid in taken:
		pickups.erase(kid)
		rpc("cl_take_pickup", kid)


func _server_tick_buffs() -> void:
	var now := Time.get_ticks_msec()
	for pid in players:
		var rec: Dictionary = players[pid]
		var before: int = rec.buffs.size()
		rec.buffs = rec.buffs.filter(func(b): return int(b.until) > now)
		if rec.buffs.size() != before:
			_sync_player(pid)


# ================================================================ pickups

func server_spawn_pickup(pos: Vector3, item: Dictionary, owner_pid := 0) -> void:
	var owner_name := ""
	if owner_pid != 0 and players.has(owner_pid):
		owner_name = players[owner_pid].name
	var k := {"id": _next_kid, "pos": pos, "item": item,
		"owner": owner_pid, "owner_name": owner_name}
	pickups[_next_kid] = k
	_next_kid += 1
	rpc("cl_spawn_pickup", k)


@rpc("authority", "call_local", "reliable")
func cl_spawn_pickup(k: Dictionary) -> void:
	if world != null:
		world.spawn_pickup(k)


@rpc("authority", "call_local", "reliable")
func cl_take_pickup(kid: int) -> void:
	if world != null:
		world.take_pickup(kid)
	AudioMgr.sfx("sfx_pickup", -8.0)


# ================================================================ sync / chat / notify

func _sync_player(pid: int) -> void:
	if players.has(pid):
		rpc("cl_sync_player", pid, players[pid])


@rpc("authority", "call_local", "reliable")
func cl_sync_player(pid: int, rec: Dictionary) -> void:
	players[pid] = rec
	Events.players_changed.emit()
	if pid == my_id():
		SaveMgr.queue_character(rec)  # progression rides with the player
		Events.my_record_changed.emit()


@rpc("authority", "call_local", "reliable")
func cl_notify(text: String) -> void:
	Events.notify.emit(text)


func request_chat(text: String) -> void:
	if is_server():
		sv_chat(text)
	else:
		rpc_id(1, "sv_chat", text)


@rpc("any_peer", "reliable")
func sv_chat(text: String) -> void:
	if not is_server():
		return
	var pid := _sender()
	var who: String = players.get(pid, {}).get("name", lobby.get(pid, {}).get("name", "?"))
	rpc("cl_chat", who, text.substr(0, 200))


@rpc("authority", "call_local", "reliable")
func cl_chat(who: String, text: String) -> void:
	Events.chat_line.emit(who, text)


# ================================================================ save / reset

func save_now() -> void:
	if not is_server() or not in_run:
		return
	var by_name := {}
	for pid in players:
		by_name[players[pid].name] = players[pid]
	SaveMgr.save_snapshot({
		"seed": run_seed, "floor_num": 0,
		"edit_log": edit_log,
		"town_log": [], "players": by_name,
		"threat": threat, "loot_rule": loot_rule,
		"town_chests": chest_store,
		"quests": _quests_by_name(),
		"town_pop": town_pop,
		"world_time": world_time,
	})


## Quest chains & reputation: each completion deepens your standing —
## bigger contracts, shop discounts, and sometimes a new Refuge citizen.
func quest_completed(pid: int, giver_type: String) -> void:
	var rec: Dictionary = players.get(pid, {})
	if rec.is_empty():
		return
	rec.rep = int(rec.get("rep", 0)) + 1
	send_to(pid, "cl_notify", ["Reputation %d — traders now offer %d%% off." %
		[int(rec.rep), mini(int(rec.rep) * 5, 25)]])
	if giver_type == "villager" and town_pop < 8 and randf() < 0.35:
		town_pop += 1
		rpc("cl_notify", "Word spreads — another villager will settle in allied villages you find!")
	_sync_player(pid)


func _quests_by_name() -> Dictionary:
	var out := {}
	for pid in quests:
		if players.has(pid):
			out[players[pid].name] = quests[pid]
	return out


func reset_session() -> void:
	in_run = false
	players = {}
	lobby = {}
	edit_log = []
	town_log = []
	enemies = {}
	pickups = {}
	encounters.clear()
	# Per-run server state. Left behind, a new run inherited the previous
	# run's chest contents (keyed by raw coordinates, so they resurface on any
	# coordinate collision — the deterministic spawn village guarantees one)
	# and its active quest, and the next save_now() persisted the stale
	# chest_store as the new save's town_chests.
	chest_store = {}
	quests = {}
	fishing = {}
	last_deaths = {}
	_crushers = []
	world = null
	voxel = null
	gen_info = {}
	_floor_ready = {}
	_floor_barrier_open = false


func leave_to_menu() -> void:
	if in_run and players.has(my_id()):
		SaveMgr.save_character(players[my_id()])
	if is_server() and in_run:
		save_now()
	Net.leave()
	reset_session()
	Events.left_game.emit()


# ================================================================ input map

func _setup_input() -> void:
	var keys := {
		"mv_fwd": KEY_W, "mv_back": KEY_S, "mv_left": KEY_A, "mv_right": KEY_D,
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "interact": KEY_E,
		"inv": KEY_TAB, "chat": KEY_T, "pause": KEY_ESCAPE, "quicksave": KEY_F5,
		"skills": KEY_K, "map": KEY_M, "guide": KEY_H, "dodge": KEY_CTRL,
	}
	for i in range(1, 10):
		keys["hotbar_%d" % i] = KEY_0 + i
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = keys[action]
			InputMap.action_add_event(action, ev)
	for action in ["mine", "place"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var mb := InputEventMouseButton.new()
			mb.button_index = MOUSE_BUTTON_LEFT if action == "mine" else MOUSE_BUTTON_RIGHT
			InputMap.action_add_event(action, mb)
	# Gamepad: left stick moves (axes on the mv_ actions), face buttons map to
	# the core verbs, right stick looks (polled in player.gd).
	var pads := {"jump": JOY_BUTTON_A, "dodge": JOY_BUTTON_B, "interact": JOY_BUTTON_X,
		"inv": JOY_BUTTON_Y, "pause": JOY_BUTTON_START, "map": JOY_BUTTON_BACK}
	for action in pads:
		var jb := InputEventJoypadButton.new()
		jb.button_index = pads[action]
		InputMap.action_add_event(action, jb)
	var axes := {"mv_left": [JOY_AXIS_LEFT_X, -1.0], "mv_right": [JOY_AXIS_LEFT_X, 1.0],
		"mv_fwd": [JOY_AXIS_LEFT_Y, -1.0], "mv_back": [JOY_AXIS_LEFT_Y, 1.0],
		"mine": [JOY_AXIS_TRIGGER_RIGHT, 1.0], "place": [JOY_AXIS_TRIGGER_LEFT, 1.0]}
	for action in axes:
		var jm := InputEventJoypadMotion.new()
		jm.axis = axes[action][0]
		jm.axis_value = axes[action][1]
		InputMap.action_add_event(action, jm)
