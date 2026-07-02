extends Node
## Game — authoritative session state and every gameplay RPC. Autoload, so RPC
## node paths are identical on all peers. The server (peer 1) owns the truth:
## player records, inventories, edits, encounters, enemies, loot. Clients send
## request_* RPCs and render whatever state they're sent.

const REACH := 5.5
const PICKUP_RADIUS := 1.7
const INV_SIZE := 27
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
		rpc_id(pid, "cl_begin_run", run_seed, players, floor_num,
			edit_log if floor_num != 0 else [], town_log)
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
	for i in range(INV_SIZE):
		rec.inv.append(null)
	rec.inv[0] = {"id": "pick_rusty", "count": 1, "meta": {}}
	rec.inv[1] = {"id": "blade_rusty", "count": 1, "meta": {}}
	rec.inv[2] = {"id": "wood", "count": 20, "meta": {}}
	# Every Luckweaver gets their class's signature spell — usable in the
	# world AND mid-combat — plus homesteading basics.
	rec.inv[3] = {"id": "spell", "count": 1, "meta": SpellForge.class_spell(class_id)}
	rec.inv[4] = {"id": "seeds", "count": 4, "meta": {}}
	rec.inv[5] = {"id": "campfire", "count": 1, "meta": {}}
	match class_id:
		"rune_dealer":
			rec.inv[6] = {"id": "rune_ruin", "count": 2, "meta": {}}
			rec.inv[7] = {"id": "card_queen", "count": 2, "meta": {}}
			rec.inv[8] = {"id": "ess_ember", "count": 2, "meta": {}}
		"high_roller":
			rec.passives["bounty"] = 0.15
		"chaos_croupier":
			rec.inv[6] = {"id": "card_joker", "count": 2, "meta": {}}
			rec.inv[7] = {"id": "potion", "count": 1,
				"meta": {"name": "Volatile Solvent", "rarity": Db.Rarity.UNCOMMON,
					"effects": [{"prop": "volatile", "potency": 4}], "throwable": true}}
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
		floor_num = int(pending_load.floor_num)
		town_log = pending_load.get("town_log", [])
		edit_log = pending_load.get("edit_log", [])
		threat = float(pending_load.get("threat", 1.0))
		loot_rule = String(pending_load.get("loot_rule", loot_rule))
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
	rpc("cl_begin_run", run_seed, players, floor_num,
		edit_log if floor_num != 0 else [], town_log)


@rpc("authority", "call_local", "reliable")
func cl_begin_run(seed_v: int, precords: Dictionary, fnum: int, ops: Array, town_ops: Array) -> void:
	run_seed = seed_v
	floor_num = fnum
	players = precords
	town_log = town_ops
	edit_log = ops if fnum != 0 else town_ops
	in_run = true
	if is_server():
		_floor_ready = {}
		_floor_barrier_open = false
	Events.run_started.emit()  # main.gd builds the world node → world_registered()


## scenes/world.gd calls this from _ready once its nodes exist.
func world_registered(w, vw: VoxelWorld) -> void:
	world = w
	voxel = vw
	_local_load_floor()


func _local_load_floor() -> void:
	gen_info = DungeonGenerator.generate(voxel, run_seed, floor_num)
	var log_now: Array = town_log if floor_num == 0 else edit_log
	for op in log_now:
		voxel.apply_op(op)
	voxel.flush_all()
	Events.floor_loaded.emit(floor_num)
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
	# Spawn every player around the floor spawn point.
	var base: Vector3 = gen_info.spawn
	var i := 0
	for pid in players:
		var pos := base + Vector3((i % 2) * 1.2, 0, (i / 2) * 1.2)
		rpc("cl_spawn_player", pid, pos)
		i += 1
	# Enemies.
	enemies = {}
	pickups = {}
	if floor_num > 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = DungeonGenerator.floor_seed(run_seed, floor_num) ^ 0xBEEF
		var spawns: Array = gen_info.enemy_spawns.duplicate()
		var count: int = clampi(int((3 + floor_num) * threat) + int(party().n) - 1,
			3, mini(16, spawns.size()))
		for j in range(count):
			if spawns.is_empty():
				break
			var s: Vector3 = spawns.pop_at(rng.randi_range(0, spawns.size() - 1))
			_server_spawn_enemy(Db.pick_enemy_type(rng, floor_num, threat), s)
		if gen_info.has_boss and gen_info.boss_spawn != null:
			_server_spawn_enemy("pit_boss", gen_info.boss_spawn)
		# Ambient life: animals to hunt, the occasional lost explorer.
		var ambient := rng.randi_range(2, 4)
		for j in range(ambient):
			if spawns.is_empty():
				break
			var atype := Db.pick_ambient_type(rng, floor_num)
			if atype == "":
				break
			var s2: Vector3 = spawns.pop_at(rng.randi_range(0, spawns.size() - 1))
			_server_spawn_enemy(atype, s2)
		var biome_lines := {
			"delve": "worked stone and old torch smoke",
			"caverns": "wild caverns — the walls were never carved",
			"lakes": "black water — pack kelp and hold your breath",
			"molten": "molten depths — the air itself sears",
		}
		rpc("cl_notify", "Floor %d: %s." % [floor_num,
			biome_lines.get(String(gen_info.get("biome", "delve")), "something stirs in the dark")])
		# Populate the hamlet, if the floor has one.
		var settle: Dictionary = gen_info.get("settlement", {})
		if not settle.is_empty():
			var sspawns: Array = settle.spawns
			match String(settle.type):
				"allied":
					for s in sspawns.slice(0, 3):
						_server_spawn_enemy("villager", s)
					_server_spawn_enemy("town_guardian", sspawns[3])
					rpc("cl_notify", "Lantern light ahead — an allied hamlet trades here.")
				"cozy":
					for s in sspawns.slice(0, 3):
						_server_spawn_enemy("villager", s)
					rpc("cl_notify", "Warm smoke rises — a cozy hamlet welcomes travelers.")
				"hostile":
					for s in sspawns:
						_server_spawn_enemy("bandit", s)
					rpc("cl_notify", "A palisade of stolen goods — BANDITS hold this hamlet.")
				"ghost":
					for s in sspawns.slice(0, 3):
						_server_spawn_enemy("gloom_ghost", s)
					rpc("cl_notify", "Empty streets, cold hearths... a ghost town. Something still walks it.")
	else:
		# Town: citizens mill about the plaza, a hog roots by the garden.
		for j in range(3):
			_server_spawn_enemy("refuge_citizen", base + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10)))
		_server_spawn_enemy("gloom_hog", base + Vector3(-14, 0, -4))
		rpc("cl_notify", "Welcome to the Gilded Refuge. The portal waits south.")
	_scan_floor_features()


## Server: find gen-placed campfires and growing crops (they are part of the
## deterministic floor, not the edit log, so we discover them by scanning).
func _scan_floor_features() -> void:
	camps = {}
	crops = {}
	waystones = {}
	for y in range(VoxelWorld.SY):
		for z in range(VoxelWorld.SZ):
			for x in range(VoxelWorld.SX):
				var id: int = voxel.data[(y * VoxelWorld.SZ + z) * VoxelWorld.SX + x]
				if id == Blocks.CAMPFIRE:
					camps["%d,%d,%d" % [x, y, z]] = Vector3(x + 0.5, y + 0.5, z + 0.5)
				elif id == Blocks.CROP_1 or id == Blocks.CROP_2:
					crops["%d,%d,%d" % [x, y, z]] = Vector3i(x, y, z)
				elif id == Blocks.WAYSTONE:
					waystones["%d,%d,%d" % [x, y, z]] = {"pos": Vector3(x, y + 1, z),
						"name": "Town Waystone"}
	rpc("cl_waystones", waystones)


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
func _server_descend() -> void:
	if floor_num == 0:
		town_log = edit_log if floor_num == 0 else town_log
	save_now()
	_descending = false
	floor_num += 1
	edit_log = []
	enemies = {}
	pickups = {}
	encounters.clear()
	_floor_ready = {}
	_floor_barrier_open = false
	rpc("cl_change_floor", floor_num, [])


@rpc("authority", "call_local", "reliable")
func cl_change_floor(fnum: int, ops: Array) -> void:
	floor_num = fnum
	edit_log = ops
	if world != null:
		world.clear_entities()
		_local_load_floor()


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
	if floor_num == 0:
		town_log = edit_log
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
		if b == Blocks.WAYSTONE:
			waystones[key] = {"pos": Vector3(int(op.p[0]), int(op.p[1]) + 1, int(op.p[2])),
				"name": "Waystone %d·%d" % [floor_num, waystones.size() + 1]}
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
			var meta2: Dictionary = entry.meta
			if int(meta2.get("charges", 0)) <= 0:
				send_to(pid, "cl_notify", ["The spell is spent."])
				return
			meta2.charges = int(meta2.charges) - 1
			EffectExec.cast(self, pid, meta2, target)
			if int(meta2.charges) <= 0:
				rec.inv[slot] = null
				send_to(pid, "cl_notify", ["The spell crumbles to glitter."])
		"skill":
			var meta3: Dictionary = entry.meta
			for k in meta3.get("passives", {}):
				var v: float = float(meta3.passives[k])
				rec.passives[k] = maxf(float(rec.passives.get(k, 0.0)), v) if v > 1.0 else float(rec.passives.get(k, 0.0)) + v
			rec.skills.append(meta3)
			rec.inv[slot] = null
			send_to(pid, "cl_notify", ["Learned: %s" % meta3.get("name", "skill")])
		"cache":
			_consume(rec, slot, 1)
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var drops: Array = Db.roll_loot(rng, floor_num + 2, eff_luck(rec), float(rec.passives.get("loot_bonus", 0.0)) + 0.3)
			var gold_win := rng.randi_range(20, 60 + floor_num * 15)
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
				Db.prof_eff(rec, "spellcraft"))
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
			var meta2 := Alchemy.brew(ids, rng, Db.prof_eff(rec, "alchemy"))
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
		"cook":
			var slots2: Array = payload.slots
			if slots2.size() < 2 or slots2.size() > 3:
				return
			var ids2: Array = []
			for s in slots2:
				if _slot_kind(rec, int(s)) != "ingredient":
					return
				ids2.append(rec.inv[int(s)].id)
			var meal := Cooking.cook(ids2, rng, Db.prof_eff(rec, "cooking"))
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
			var q: int = eff / 10 + (1 if rng.randf() < 0.15 else 0)
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
			if not (gk in ["weapon", "armor"]) or _slot_kind(rec, es2) != "essence":
				return
			if rec.inv[es2].count < 2 or rec.gold < 30:
				send_to(pid, "cl_notify", ["Enchanting takes 2 matching essences and 30 gold."])
				return
			var element: String = Db.item_def(rec.inv[es2].id).element
			var epow: int = 1 + Db.prof_eff(rec, "enchanting") / 15
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
		var stock: Array = Db.shop_stock(run_seed, floor_num)
		if idx < 0 or idx >= stock.size():
			return
		var offer: Dictionary = stock[idx]
		if rec.gold < int(offer.price):
			send_to(pid, "cl_notify", ["The house doesn't do credit."])
			return
		if give_item(pid, offer.id, 1, offer.meta.duplicate(true)):
			rec.gold -= int(offer.price)
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
			if bid != Blocks.PORTAL or _descending:
				return
			_descending = true
			rpc("cl_notify", "%s pulls the lever — descending in 4..." % players[pid].name)
			get_tree().create_timer(4.0).timeout.connect(_server_descend)
		"chest":
			if bid != Blocks.CHEST:
				return
			_apply_edit({"t": "set", "p": p, "b": Blocks.CHEST_EMPTY})
			var rec: Dictionary = players[pid]
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var gold_win := rng.randi_range(10, 30 + floor_num * 10)
			reward_gold(pid, gold_win)
			var at := Vector3(int(p[0]) + 0.5, int(p[1]) + 1.2, int(p[2]) + 0.5)
			for d in Db.roll_loot(rng, floor_num, eff_luck(rec), float(rec.passives.get("loot_bonus", 0.0))):
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
			reward_gold(pid, rng3.randi_range(15, 40 + floor_num * 12))
			for d in Db.roll_loot(rng3, floor_num, eff_luck(players[pid]), 0.3):
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


func _server_start_encounter(pid: int, eid: int, ranged := false) -> void:
	var rec: Dictionary = players.get(pid, {})
	var e: Dictionary = enemies.get(eid, {})
	if rec.is_empty() or e.is_empty() or not e.alive or e.in_combat or rec.in_enc:
		return
	# Passive animals are hunted outright — no combat, just the harvest.
	if String(e.get("disp", "hostile")) == "passive":
		_server_hunt(pid, eid)
		return
	# Sneak attack: the foe is shrouded in smoke, or you struck from range
	# before it ever noticed you.
	var sneak := is_smoked(e.pos)
	if ranged:
		var pnode = world.get_player(pid)
		if pnode != null and pnode.global_position.distance_to(Vector3(e.pos)) > 8.0:
			sneak = true
	e.in_combat = true
	rec.in_enc = true
	var enc := Encounter.new(self, pid, eid)
	enc.sneak = sneak
	enc.opened_ranged = ranged
	encounters[pid] = enc
	enc.start()
	_sync_player(pid)


## Aimed bow shot in the world: consumes an arrow, opens the fight (possibly
## as a sneak attack) with the arrow as the first strike.
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
	if rec.is_empty() or not _consume_id(rec, "arrow", 1):
		send_to(pid, "cl_notify", ["No arrows left."])
		return
	_sync_player(pid)
	_server_start_encounter(pid, eid, true)


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
		grant_xp(by_pid, int(e.get("xp", 20 + floor_num * 10)))
		award_prof(by_pid, "combat", maxi(2, int(e.get("xp", 20)) / 10))
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
		var drops: Array = Db.roll_loot(rng, floor_num, eff_luck(rec), bonus)
		drops.append_array(Db.ENEMIES[e.type].get("drops", []).map(
			func(d): return {"id": d.id, "count": int(d.count), "meta": {}}))
		var node = world.get_player(by_pid)
		var at: Vector3 = e.pos if node == null else node.global_position
		for d in drops:
			server_spawn_pickup(at + Vector3(rng.randf_range(-1.2, 1.2), 0.6,
				rng.randf_range(-1.2, 1.2)), d, _next_loot_owner())
	if bool(e.get("boss", false)):
		rpc("cl_notify", "THE VAULT TYRANT FALLS. The way down opens...")
		var pp: Array = gen_info.get("portal_pos", [int(e.pos.x), 3, int(e.pos.z)])
		_apply_edit({"t": "set", "p": pp, "b": Blocks.PORTAL})
		for pid in players:
			give_item(pid, "gambit_cache", 1, {})
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
	var curve := 1.0 + 0.14 * floor_num
	if disp == "hostile":
		curve *= (1.0 + 0.3 * (float(pt.n) - 1.0)) * (1.0 + 0.04 * (float(pt.avg) - 1.0))
	var hp := int(def.hp * curve * (threat if disp == "hostile" else 1.0))
	var atk := int(def.atk) + floor_num / 3
	if disp == "hostile":
		atk += int((float(pt.avg) - 1.0) / 4.0)
	var ac := int(def.ac) + floor_num / 4
	var dmg: Array = [int(def.dmg[0]), int(def.dmg[1]), int(def.dmg[2]) + floor_num / 3]
	var ename: String = def.name
	var elite := ""
	var gold_mult := 1.0
	if disp == "hostile" and not def.boss \
			and randf() < clampf(0.06 + floor_num * 0.015 + (threat - 1.0) * 0.4, 0.0, 0.5):
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
		"pos": pos, "level": floor_num, "alive": true, "in_combat": false, "cooldown": 0.0}
	enemies[_next_eid] = e
	_next_eid += 1
	rpc("cl_spawn_enemy", e)


@rpc("authority", "call_local", "reliable")
func cl_spawn_enemy(e: Dictionary) -> void:
	if world != null:
		world.spawn_enemy(e)


@rpc("authority", "call_local", "reliable")
func cl_despawn_enemy(eid: int) -> void:
	if world != null:
		world.despawn_enemy(eid)


@rpc("authority", "unreliable")
func cl_enemy_positions(posmap: Dictionary) -> void:
	if world != null:
		world.update_enemy_positions(posmap)


func _process(delta: float) -> void:
	if not in_run or not is_server() or world == null:
		return
	# Fluid simulation: server metronome; each beat is an op in the log, so
	# every peer (and every save replay) steps the sim identically.
	_fluid_accum += delta
	if _fluid_accum >= 0.3:
		_fluid_accum = 0.0
		if voxel != null and voxel.has_active_fluids():
			_apply_edit({"t": "fluid", "p": [0, 0, 0]})
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
			enemy_defeated(eid, 1)


func _server_tick_camps_and_regen() -> void:
	_server_tick_enemy_statuses()
	for pid in players:
		var rec: Dictionary = players[pid]
		var p = world.get_player(pid)
		if p == null or int(rec.hp) <= 0:
			continue
		var heal := 0
		for b in rec.buffs:
			if b.k == "regen":
				heal += int(b.amt)
		for key in camps:
			if p.global_position.distance_to(camps[key]) < 6.0:
				heal += 1
				break
		if heal > 0 and int(rec.hp) < int(rec.max_hp):
			rec.hp = mini(int(rec.hp) + heal, int(rec.max_hp))
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
		if not e.in_combat:
			node.smoked = is_smoked(e.pos)
			node.tick_ai(players, world)
		e.pos = node.global_position
		posmap[eid] = e.pos
		# Contact starts combat — hostiles only; folk and critters just mingle.
		if String(e.get("disp", "hostile")) == "hostile" and not e.in_combat and e.cooldown <= 0.0:
			for pid in players:
				var p = world.get_player(pid)
				if p != null and not players[pid].in_enc and p.global_position.distance_to(e.pos) < 1.7:
					_server_start_encounter(pid, eid)
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
					_drown_accum += 0.2
					if _drown_accum >= 1.0:
						_drown_accum = 0.0
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
					hurt_player(pid, 10 + floor_num * 2, "an explosive tripwire")
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
					hurt_player(pid, 14 + floor_num * 2, "a blast glyph")
					rpc("cl_notify", "The glyph flares and DETONATES!")
				Blocks.TELE_TRAP:
					_apply_edit({"t": "set", "p": parr, "b": Blocks.AIR})
					var spots: Array = gen_info.get("enemy_spawns", [])
					var dest: Vector3 = spots[randi() % spots.size()] if not spots.is_empty() else gen_info.spawn
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
		"seed": run_seed, "floor_num": floor_num,
		"edit_log": edit_log if floor_num != 0 else [],
		"town_log": town_log, "players": by_name,
		"threat": threat, "loot_rule": loot_rule,
	})


func reset_session() -> void:
	in_run = false
	players = {}
	lobby = {}
	edit_log = []
	town_log = []
	enemies = {}
	pickups = {}
	encounters.clear()
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
		"skills": KEY_K, "map": KEY_M,
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
