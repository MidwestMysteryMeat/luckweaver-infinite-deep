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
		rotation.y -= event.relative.x * MOUSE_SENS
		_head.rotation.x = clampf(_head.rotation.x - event.relative.y * MOUSE_SENS,
			-PI / 2 + 0.05, PI / 2 - 0.05)
	for i in range(1, 10):
		if event.is_action_pressed("hotbar_%d" % i):
			selected_slot = i - 1
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			selected_slot = (selected_slot + 8) % 9
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			selected_slot = (selected_slot + 1) % 9
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


func _physics_process(delta: float) -> void:
	if is_local():
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
	if swimming:
		velocity.y -= GRAVITY * 0.25 * delta
		velocity.y = maxf(velocity.y, -2.0)
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
		elif swimming and Input.is_action_pressed("jump"):
			velocity.y = 3.5  # paddle upward
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
	var rec: Dictionary = Game.players.get(pid, {})
	var tool_speed := 0.5  # bare hands
	var e = rec.get("inv", [null])[selected_slot] if selected_slot < rec.get("inv", []).size() else null
	if e != null and Db.item_def(e.id).kind == "tool":
		tool_speed = float(Db.item_def(e.id).speed)
	else:
		# any pick anywhere in the hotbar still helps at half rate
		for i in range(9):
			var h = rec.get("inv", [])[i] if i < rec.get("inv", []).size() else null
			if h != null and Db.item_def(h.id).kind == "tool":
				tool_speed = maxf(tool_speed, float(Db.item_def(h.id).speed) * 0.5)
	tool_speed *= float(rec.get("passives", {}).get("mine_speed", 1.0))
	tool_speed *= 1.0 + Db.prof_eff(rec, "mining") * 0.015
	mining_progress += delta * tool_speed / maxf(def.hard, 0.1)
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
				return "E — Hunt %s" % ename
			"neutral":
				return "E — Talk to %s" % ename
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
