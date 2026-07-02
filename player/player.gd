class_name LLPlayer
extends CharacterBody3D
## First-person Luckweaver. The owning peer simulates movement and streams
## position/yaw to everyone else; all world/inventory actions go through
## Game's request_* RPCs and resolve on the server.

const SPEED := 5.0
const SPRINT := 8.0
const JUMP := 8.5
const GRAVITY := 22.0
const REACH := 5.0
const MOUSE_SENS := 0.0025
const NET_RATE := 1.0 / 15.0

var pid := 1
var locked := false          # UI open — ignore world input
var selected_slot := 0

var _head: Node3D
var _cam: Camera3D
var _label: Label3D
var _body_mesh: MeshInstance3D
var _body_model: Node3D = null
var _hand: Node3D = null
var _dodge_cd := 0
var _mine_swing_t := 0.0
var _net_accum := 0.0
var _net_pos := Vector3.ZERO
var _net_yaw := 0.0

# mining state
var mining_block := Vector3i(-999, -999, -999)
var mining_progress := 0.0


func _enter_tree() -> void:
	set_multiplayer_authority(pid)


func _ready() -> void:
	add_to_group("player")
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.7
	col.shape = cap
	col.position.y = 0.85
	add_child(col)

	_head = Node3D.new()
	_head.position.y = 1.5
	add_child(_head)

	var rec: Dictionary = Game.players.get(pid, {})
	var cls: Dictionary = Db.CLASSES.get(rec.get("class_id", "cardsharp"), Db.CLASSES.cardsharp)

	# Blockbench class model; capsule fallback if the art isn't there.
	var mdl := ModelDb.class_model(rec.get("class_id", "cardsharp"))
	_body_mesh = MeshInstance3D.new()
	if mdl != null:
		add_child(mdl)
		_body_model = mdl
		_body_mesh.visible = false
		add_child(_body_mesh)
	else:
		var cm := CapsuleMesh.new()
		cm.radius = 0.35
		cm.height = 1.7
		_body_mesh.mesh = cm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = cls.color
		mat.emission_enabled = true
		mat.emission = cls.color * 0.3
		_body_mesh.material_override = mat
		_body_mesh.position.y = 0.85
		add_child(_body_mesh)

	_label = Label3D.new()
	_label.text = rec.get("name", "?")
	_label.position.y = 2.2
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 48
	_label.pixel_size = 0.005
	add_child(_label)

	if is_local():
		_cam = Camera3D.new()
		_cam.fov = 80
		_head.add_child(_cam)
		_cam.make_current()
		# First-person weapon: a simple blade that arcs on every swing.
		_hand = Node3D.new()
		_hand.position = Vector3(0.45, -0.35, -0.6)
		_cam.add_child(_hand)
		var blade := MeshInstance3D.new()
		var bm2 := BoxMesh.new()
		bm2.size = Vector3(0.06, 0.5, 0.06)
		blade.mesh = bm2
		blade.position = Vector3(0, 0.25, 0)
		blade.rotation_degrees = Vector3(-25, 0, 0)
		var bmat2 := StandardMaterial3D.new()
		bmat2.albedo_color = Color(0.75, 0.75, 0.82)
		bmat2.emission_enabled = true
		bmat2.emission = Color(0.3, 0.3, 0.35)
		blade.material_override = bmat2
		_hand.add_child(blade)
		Events.my_record_changed.connect(_update_hand)
		_update_hand.call_deferred()
		_body_mesh.visible = false
		if _body_model != null:
			_body_model.visible = false  # first-person: hide own model
		_label.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_local() -> bool:
	return pid == multiplayer.get_unique_id()


func teleport_to(pos: Vector3) -> void:
	global_position = pos
	_net_pos = pos
	velocity = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if not is_local() or locked:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := float(SaveMgr.settings.sens)
		rotation.y -= event.relative.x * sens
		_head.rotation.x = clampf(_head.rotation.x - event.relative.y * sens,
			-PI / 2 + 0.05, PI / 2 - 0.05)
	for i in range(1, 10):
		if event.is_action_pressed("hotbar_%d" % i):
			selected_slot = i - 1
			_update_hand()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			selected_slot = (selected_slot + 8) % 9
			_update_hand()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			selected_slot = (selected_slot + 1) % 9
			_update_hand()
	if event.is_action_pressed("place"):
		_do_place_or_use()
	if event.is_action_pressed("interact"):
		_do_interact()
	# Real-time combat: LMB on a hostile = swing (mining stays hold-on-blocks).
	if event.is_action_pressed("mine"):
		var a := aim()
		if a.kind == "enemy":
			var node = a.get("node")
			if node != null and node.disp == "hostile":
				Game.request_melee(int(a.eid))
		_swing_anim()
	# Dodge: a quick burst-step in your movement direction (Ctrl).
	if event.is_action_pressed("dodge") and Time.get_ticks_msec() > _dodge_cd:
		_dodge_cd = Time.get_ticks_msec() + 1200
		var input2 := Input.get_vector("mv_left", "mv_right", "mv_fwd", "mv_back")
		var dir2 := (transform.basis * Vector3(input2.x, 0, input2.y))
		if dir2.length() < 0.1:
			dir2 = -transform.basis.z
		velocity += dir2.normalized() * 12.0
		AudioMgr.sfx("sfx_swing", -12.0)


func _swing_anim() -> void:
	if _hand == null:
		return
	var tw := _hand.create_tween()
	tw.tween_property(_hand, "rotation_degrees", Vector3(-70, 25, 0), 0.08)
	tw.tween_property(_hand, "rotation_degrees", Vector3.ZERO, 0.18)


var _held: Node3D = null
var _held_id := ""


## Swap the first-person model to whatever the hotbar has selected.
## Tracked by reference (queue_free renames make name lookups pile up models).
func _update_hand() -> void:
	if _hand == null:
		return
	var inv: Array = Game.my_rec().get("inv", [])
	var entry = inv[selected_slot] if selected_slot < inv.size() else null
	var new_id: String = entry.id if entry != null else ""
	if new_id == _held_id and (_held == null) == (new_id == ""):
		return  # same item — nothing to do
	_held_id = new_id
	if _held != null:
		_held.queue_free()
		_held = null
	var mdl: Node3D = ModelDb.item_model(entry) if entry != null else null
	if mdl != null:
		mdl.scale = Vector3(0.45, 0.45, 0.45)
		mdl.rotation_degrees = Vector3(-25, 10, 0)
		_hand.add_child(mdl)
		_held = mdl
	for c in _hand.get_children():
		if c is MeshInstance3D:
			c.visible = _held == null


func _physics_process(delta: float) -> void:
	if is_local():
		# Gamepad: right stick looks.
		if not locked:
			var jx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
			var jy := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
			if absf(jx) > 0.15:
				rotation.y -= jx * delta * 2.6
			if absf(jy) > 0.15:
				_head.rotation.x = clampf(_head.rotation.x - jy * delta * 2.0,
					-PI / 2 + 0.05, PI / 2 - 0.05)
		_local_move(delta)
		_local_mine(delta)
		_net_accum += delta
		if _net_accum >= NET_RATE and multiplayer.multiplayer_peer != null:
			_net_accum = 0.0
			rpc("net_state", global_position, rotation.y)
	else:
		global_position = global_position.lerp(_net_pos, minf(1.0, delta * 14.0))
		rotation.y = lerp_angle(rotation.y, _net_yaw, delta * 14.0)


func _local_move(delta: float) -> void:
	# Fluid physics: liquids slow you and let you swim; lava is like tar.
	var body_block: int = Game.voxel.get_block_v(Vector3i((global_position + Vector3(0, 0.8, 0)).floor())) \
		if Game.voxel != null else Blocks.AIR
	var in_kind := Blocks.fluid_kind(body_block)
	var swimming: bool = in_kind != "" and not Blocks.is_gas(body_block)
	var head_block: int = Game.voxel.get_block_v(Vector3i((global_position + Vector3(0, 1.5, 0)).floor())) \
		if Game.voxel != null else Blocks.AIR
	if swimming:
		velocity.y -= GRAVITY * 0.25 * delta
		velocity.y = maxf(velocity.y, -2.0)
		# Climbing out: at the surface against a wall, Space vaults you up.
		if Input.is_action_pressed("jump") and not locked:
			if Blocks.fluid_kind(head_block) == "":  # head above water
				velocity.y = 7.5 if is_on_wall() else 4.5
			else:
				velocity.y = 4.5
	else:
		velocity.y -= GRAVITY * delta
	var dir := Vector3.ZERO
	if not locked:
		var input := Input.get_vector("mv_left", "mv_right", "mv_fwd", "mv_back")
		dir = (transform.basis * Vector3(input.x, 0, input.y))
		dir.y = 0
		if dir.length() > 1.0:
			dir = dir.normalized()
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = JUMP
	var speed := SPRINT if Input.is_action_pressed("sprint") and not locked else SPEED
	if swimming:
		speed *= 0.3 if in_kind == "lava" else 0.55
	if body_block == Blocks.WEB:
		speed *= 0.25  # tangled in webbing
	# Status buffs: quickstep speeds you, sleep drops you, inversion gas
	# flips the world upside down.
	var rec: Dictionary = Game.players.get(pid, {})
	var asleep := false
	var inverted := false
	var now := Time.get_ticks_msec()
	for b in rec.get("buffs", []):
		if int(b.until) < now:
			continue
		match String(b.k):
			"swift":
				speed *= 1.35
			"sleep":
				asleep = true
			"invert":
				inverted = true
	if asleep:
		dir = Vector3.ZERO
	if rec.get("injuries", {}).has("legs"):
		speed *= 0.8
	if _cam != null:
		_cam.rotation.z = lerp_angle(_cam.rotation.z, PI if inverted else 0.0, 0.1)
	# Veilwalk: fade your avatar (mostly for your allies' benefit).
	var invis_now := false
	for b in rec.get("buffs", []):
		if b.k == "invis" and int(b.until) > now:
			invis_now = true
	_body_mesh.transparency = 0.85 if invis_now else 0.0
	if _body_model != null and not is_local():
		for c in _body_model.get_children():
			if c is GeometryInstance3D:
				c.transparency = 0.85 if invis_now else 0.0
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	move_and_slide()
	if global_position.y < -10:  # fell out somehow
		teleport_to(Game.gen_info.get("spawn", Vector3(48, 6, 48)))


@rpc("authority", "unreliable_ordered")
func net_state(pos: Vector3, yaw: float) -> void:
	_net_pos = pos
	_net_yaw = yaw


# ---------------------------------------------------------------- aiming

## {"kind": "block"/"enemy"/"none", ...}
func aim() -> Dictionary:
	if _cam == null:
		return {"kind": "none"}
	var from := _cam.global_position
	var to := from - _cam.global_transform.basis.z * REACH
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"kind": "none"}
	var collider: Object = hit.collider
	if collider is Node and (collider as Node).is_in_group("enemy"):
		return {"kind": "enemy", "eid": (collider as Node).get("eid"),
			"node": collider, "pos": hit.position}
	if collider is Node and (collider as Node).is_in_group("voxel"):
		var bpos := Vector3i((Vector3(hit.position) - Vector3(hit.normal) * 0.5).floor())
		var ppos := Vector3i((Vector3(hit.position) + Vector3(hit.normal) * 0.5).floor())
		return {"kind": "block", "block": bpos, "place": ppos, "pos": hit.position}
	return {"kind": "none"}


## Long-range aim for bow shots (20 blocks).
func _aim_far() -> Dictionary:
	if _cam == null:
		return {"kind": "none"}
	var from := _cam.global_position
	var to := from - _cam.global_transform.basis.z * 20.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and hit.collider is Node and (hit.collider as Node).is_in_group("enemy"):
		return {"kind": "enemy", "eid": (hit.collider as Node).get("eid")}
	return {"kind": "none"}


# ---------------------------------------------------------------- actions

func _local_mine(delta: float) -> void:
	if locked or not Input.is_action_pressed("mine"):
		mining_progress = 0.0
		return
	var a := aim()
	if a.kind != "block":
		mining_progress = 0.0
		return
	var bid: int = Game.voxel.get_block_v(a.block)
	var def := Blocks.get_def(bid)
	if def.hard < 0.0:
		mining_progress = 0.0
		return
	if a.block != mining_block:
		mining_block = a.block
		mining_progress = 0.0
	# Minecraft-style tool efficacy: the RIGHT tool in hand is fast, the
	# wrong one barely beats fists. Picks quarry stone/ore; blades chop
	# wood and plants; the tool must be the SELECTED item.
	var rec: Dictionary = Game.players.get(pid, {})
	var tool_speed := 0.4  # bare hands
	var e = rec.get("inv", [null])[selected_slot] if selected_slot < rec.get("inv", []).size() else null
	var woody: bool = bid in [Blocks.WOOD, Blocks.IRONWOOD_LOG, Blocks.SHROOM_STALK,
		Blocks.SHROOM_CAP, Blocks.DOOR, Blocks.VINE, Blocks.WEB,
		Blocks.CROP_1, Blocks.CROP_2, Blocks.CROP_RIPE]
	if e != null:
		var edef := Db.item_def(e.id)
		if edef.kind == "tool":
			tool_speed = float(edef.speed) * (0.5 if woody else 1.0)
		elif edef.kind == "weapon" and not edef.get("ranged", false):
			tool_speed = 1.6 if woody else 0.5
	tool_speed *= float(rec.get("passives", {}).get("mine_speed", 1.0))
	tool_speed *= 1.0 + Db.prof_eff(rec, "mining") * 0.015
	mining_progress += delta * tool_speed / maxf(def.hard, 0.1)
	_mine_swing_t -= delta
	if _mine_swing_t <= 0.0:
		_mine_swing_t = 0.34
		_swing_anim()
	if mining_progress >= 1.0:
		mining_progress = 0.0
		Game.request_break(a.block)


func _do_place_or_use() -> void:
	var rec: Dictionary = Game.players.get(pid, {})
	var inv: Array = rec.get("inv", [])
	var e = inv[selected_slot] if selected_slot < inv.size() else null
	var a := aim()
	if e == null:
		return
	var kind: String = Db.item_def(e.id).kind
	# Bow selected: loose an arrow at whatever enemy you're aiming at (long ray).
	if kind == "weapon" and Db.item_def(e.id).get("ranged", false):
		var far := _aim_far()
		if far.kind == "enemy":
			Game.request_bow(int(far.eid))
		return
	# Rod selected: cast into the water (or lava) you're looking at.
	if kind == "pole":
		if a.kind == "block":
			var fk := Blocks.fluid_kind(Game.voxel.get_block_v(a.block))
			if fk in ["water", "lava"]:
				Game.request_fish([a.block.x, a.block.y, a.block.z])
			else:
				# The ray hits the surface's solid neighbor; try the place cell.
				var pk := Blocks.fluid_kind(Game.voxel.get_block_v(a.place))
				if pk in ["water", "lava"]:
					Game.request_fish([a.place.x, a.place.y, a.place.z])
		return
	if kind == "block" or kind == "seed":
		if a.kind == "block":
			# Don't entomb yourself.
			var pc := Vector3(a.place) + Vector3(0.5, 0.5, 0.5)
			if pc.distance_to(global_position + Vector3(0, 0.9, 0)) > 1.2:
				Game.request_place(a.place, selected_slot)
	elif kind in ["potion", "spell", "cache", "skill"]:
		var target: Vector3 = a.get("pos", global_position - _cam.global_transform.basis.z * 3.0) \
			if a.kind != "none" else global_position - _cam.global_transform.basis.z * 3.0
		Game.request_use(selected_slot, target)


func _do_interact() -> void:
	var a := aim()
	if a.kind == "enemy":
		var node = a.get("node")
		if node != null and node.disp == "neutral":
			Events.open_bench.emit("npc:%d" % int(a.eid))
		else:
			Game.request_encounter(int(a.eid))
		return
	if a.kind != "block":
		return
	var bid: int = Game.voxel.get_block_v(a.block)
	var p := [a.block.x, a.block.y, a.block.z]
	match bid:
		Blocks.PORTAL:
			Game.request_interact("portal", p)
		Blocks.CHEST:
			Game.request_interact("chest", p)
		Blocks.CHEST_TRAPPED:
			Game.request_interact("chest_trapped", p)
		Blocks.DOOR_TRAPPED:
			Game.request_interact("door", p)
		Blocks.DOOR:
			# Golden Key in hand = lock it; empty hand = swing it open.
			if _holding("golden_key"):
				Game.request_interact("door_lock", p)
			else:
				Game.request_interact("door", p)
		Blocks.DOOR_OPEN, Blocks.DOOR_LOCKED:
			Game.request_interact("door", p)
		Blocks.CAMPFIRE:
			Events.open_bench.emit("cook")
		Blocks.WAYSTONE:
			Events.open_bench.emit("waystone")
		Blocks.CHEST_STORE:
			Events.open_bench.emit("chest:%d,%d,%d" % [a.block.x, a.block.y, a.block.z])
		Blocks.BENCH_SMITH:
			Events.open_bench.emit("smith")
		Blocks.BENCH_ENCH:
			Events.open_bench.emit("enchant")
		Blocks.BENCH_SPELL:
			Events.open_bench.emit("spell")
		Blocks.BENCH_ALCH:
			Events.open_bench.emit("brew")
		Blocks.BENCH_SKILL:
			Events.open_bench.emit("merge")
		Blocks.BENCH_SHOP:
			Events.open_bench.emit("shop")


func _holding(item_id: String) -> bool:
	var inv: Array = Game.my_rec().get("inv", [])
	var e = inv[selected_slot] if selected_slot < inv.size() else null
	return e != null and e.id == item_id


## HUD prompt for whatever we're looking at.
func aim_prompt() -> String:
	var a := aim()
	if a.kind == "enemy":
		var node = a.get("node")
		var ename: String = node.display_name if node != null else "?"
		# Seer's Eye: insight reveals defenses at a glance.
		if Game.my_rec().get("passives", {}).has("insight") and node != null:
			ename += "  (AC %d, ~%d HP)" % [node.known_ac, node.est_hp]
		match String(node.disp if node != null else "hostile"):
			"passive":
				if node != null and node.tamed:
					return "E — Pet %s" % ename
				return "E — Hunt %s (hold wheat to tame)" % ename
			"neutral":
				return "E — Trade with %s (LMB attacks)" % ename
			_:
				return "LMB — Attack %s" % ename
	if a.kind == "block":
		var bid: int = Game.voxel.get_block_v(a.block)
		if bid == Blocks.DOOR and _holding("golden_key"):
			return "E — Lock Door (Golden Key)"
		if bid == Blocks.CAMPFIRE:
			return "E — Cook at Campfire"
		if bid in Blocks.INTERACTIVE:
			return "E — %s" % Blocks.get_def(bid).name
	return ""
