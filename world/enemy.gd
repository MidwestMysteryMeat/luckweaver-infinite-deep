class_name LLEnemy
extends CharacterBody3D
## A dungeon mob. The server simulates the AI (tick_ai, called from Game's
## server tick) and broadcasts positions; clients just interpolate.
## Visuals come from the spawn record: shape/size per type, elite auras,
## disposition-tinted name labels. Hostiles stalk; folk and critters wander.

const GRAVITY := 22.0

var eid := 0
var type := "gloom_rat"
var display_name := ""
var elite := ""
var disp := "hostile"
var smoked := false  # set by the server tick: smoke clouds blind stalkers
var net_target := Vector3.ZERO
var _wander_dir := Vector3.ZERO
var _wander_t := 0.0
var _bob := 0.0
var _mesh: MeshInstance3D
var _mesh_base_y := 0.8


var known_ac := 10
var est_hp := 10


func setup(e: Dictionary) -> void:
	eid = int(e.id)
	type = String(e.type)
	display_name = String(e.get("name", type))
	elite = String(e.get("elite", ""))
	disp = String(e.get("disp", "hostile"))
	known_ac = int(e.get("ac", 10))
	est_hp = int(e.get("hp", 10))


func _ready() -> void:
	add_to_group("enemy")
	var def: Dictionary = Db.ENEMIES[type]
	var size := float(def.get("size", 1.0))

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4 * size
	cap.height = 1.6 * size
	col.shape = cap
	col.position.y = 0.8 * size
	add_child(col)

	# Blockbench model first; procedural shapes as fallback while art lands.
	var alpha := 1.0
	if def.get("ghost", false):
		alpha = 0.35
	elif def.get("stealth", false):
		alpha = 0.15
	var mdl := ModelDb.mob(type, alpha)
	if mdl != null:
		var msc := float(def.get("size", 1.0))
		mdl.scale = Vector3(msc, msc, msc)
		if elite != "":
			mdl.scale *= 1.15
		add_child(mdl)
		_mesh = MeshInstance3D.new()  # bob target stub (invisible)
		_mesh.visible = false
		add_child(_mesh)
		_attach_label(def)
		net_target = global_position
		return

	_mesh = MeshInstance3D.new()
	var color: Color = def.color
	if elite != "":
		color = color.lerp(Db.ELITES[elite].color, 0.55)
	match String(def.get("shape", "capsule")):
		"box":
			var bm := BoxMesh.new()
			bm.size = Vector3(0.9, 1.2, 0.9) * size
			_mesh.mesh = bm
			_mesh_base_y = 0.6 * size
		"sphere":
			var sm := SphereMesh.new()
			sm.radius = 0.45 * size
			sm.height = 0.9 * size
			_mesh.mesh = sm
			_mesh_base_y = 0.5 * size
		"blob":
			var bl := SphereMesh.new()
			bl.radius = 0.55 * size
			bl.height = 0.7 * size
			_mesh.mesh = bl
			_mesh_base_y = 0.35 * size
		"tall":
			var tc := CapsuleMesh.new()
			tc.radius = 0.28 * size
			tc.height = 1.9 * size
			_mesh.mesh = tc
			_mesh_base_y = 0.95 * size
		_:
			var cm := CapsuleMesh.new()
			cm.radius = 0.4 * size
			cm.height = 1.6 * size
			_mesh.mesh = cm
			_mesh_base_y = 0.8 * size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color * (0.9 if bool(def.boss) or elite != "" else 0.3)
	# Chameleons fade into the walls; ghosts are barely there at all.
	if def.get("stealth", false) or def.get("ghost", false):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.25 if def.get("ghost", false) else 0.12
	_mesh.material_override = mat
	_mesh.position.y = _mesh_base_y
	add_child(_mesh)
	# Glowing eyes — the one thing you can always spot.
	for side in [-0.12, 0.12]:
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new()
		em.radius = 0.06 * size
		em.height = 0.12 * size
		eye.mesh = em
		var emat := StandardMaterial3D.new()
		var ecol := Color(1, 0.9, 0.3) if disp != "hostile" else Color(1, 0.25, 0.2)
		emat.albedo_color = ecol
		emat.emission_enabled = true
		emat.emission = ecol * 2.0
		eye.material_override = emat
		eye.position = Vector3(side * size, _mesh_base_y * 1.5, -0.3 * size)
		add_child(eye)

	_attach_label(def)
	net_target = global_position


func _attach_label(def: Dictionary) -> void:
	var label := Label3D.new()
	var tag := ""
	if bool(def.boss):
		tag = "👑 "
	elif elite != "":
		tag = "★ "
	label.text = tag + display_name
	label.position.y = 1.9 * float(def.get("size", 1.0)) + 0.3
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.pixel_size = 0.005
	match disp:
		"passive":
			label.modulate = Color(0.6, 0.9, 0.6)
		"neutral":
			label.modulate = Color(0.95, 0.9, 0.55)
		_:
			label.modulate = Color(def.color).lightened(0.4)
	add_child(label)


func _physics_process(delta: float) -> void:
	_bob += delta * 3.0
	_mesh.position.y = _mesh_base_y + sin(_bob) * 0.06
	if not Game.is_server():
		global_position = global_position.lerp(net_target, minf(1.0, delta * 8.0))


## Server-only: wander; hostiles also stalk the nearest player within 10 blocks.
func tick_ai(players: Dictionary, world) -> void:
	var delta := 0.2  # Game ticks us at 5 Hz
	_wander_t -= delta
	if _wander_t <= 0.0:
		_wander_t = randf_range(2.0, 5.0)
		var a := randf() * TAU
		_wander_dir = Vector3(cos(a), 0, sin(a)) * (0.0 if randf() < 0.3 else 1.0)
	var dir := _wander_dir
	var speed := 1.6
	if disp == "hostile" and not smoked:
		var nearest = null
		var nd := 10.0
		for pid in players:
			var p = world.get_player(pid)
			if p != null and not players[pid].in_enc and not _is_invisible(players[pid]):
				var d: float = p.global_position.distance_to(global_position)
				if d < nd:
					nd = d
					nearest = p
		if nearest != null:
			dir = (nearest.global_position - global_position)
			dir.y = 0
			dir = dir.normalized()
			speed = 2.2
	# Ghosts drift straight through walls; the living walk and climb.
	if Db.ENEMIES[type].get("ghost", false):
		global_position += dir * speed * 0.6 * delta
		return
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	velocity.y -= GRAVITY * delta
	if is_on_wall() and is_on_floor():
		velocity.y = 7.0
	move_and_slide()


## Veilwalk buffs and Shadow Cloaks hide players from stalking eyes.
func _is_invisible(rec: Dictionary) -> bool:
	var now := Time.get_ticks_msec()
	for b in rec.get("buffs", []):
		if b.k == "invis" and int(b.until) > now:
			return true
	for it in rec.get("inv", []):
		if it != null and Db.item_def(it.id).get("stealth", false):
			return true
	return false


func die() -> void:
	set_physics_process(false)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(0.05, 2.5, 0.05), 0.4)
	tw.tween_callback(queue_free)
