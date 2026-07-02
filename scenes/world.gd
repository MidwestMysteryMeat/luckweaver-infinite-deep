class_name LLWorld
extends Node3D
## The in-game 3D scene, built entirely in code by scenes/main.gd when a run
## starts. Owns the VoxelWorld and the entity containers; Game drives it.

var voxel: VoxelWorld
var players_node: Node3D
var enemies_node: Node3D
var pickups_node: Node3D
var _env: Environment


func _ready() -> void:
	name = "World"
	voxel = VoxelWorld.new()
	voxel.name = "Voxel"
	add_child(voxel)
	players_node = Node3D.new()
	players_node.name = "Players"
	add_child(players_node)
	enemies_node = Node3D.new()
	enemies_node.name = "Enemies"
	add_child(enemies_node)
	pickups_node = Node3D.new()
	pickups_node.name = "Pickups"
	add_child(pickups_node)
	_build_environment()
	Game.world_registered(self, voxel)


func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.fog_enabled = true
	_env.glow_enabled = true
	_env.glow_intensity = 0.4
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)
	_apply_daylight()


## Day/night: sky, fog, ambient, and the voxel material's tint all follow the
## world clock (blocks are unshaded, so tinting the shared material IS the
## sunset). Caves barely notice; the surface swings from noon to starlight.
func _process(_delta: float) -> void:
	_apply_daylight()


func _apply_daylight() -> void:
	var dl := Game.daylight()
	_env.background_color = Color(0.012, 0.014, 0.055).lerp(Color(0.42, 0.62, 0.92), dl)
	_env.fog_light_color = Color(0.03, 0.03, 0.09).lerp(Color(0.55, 0.62, 0.8), dl)
	_env.ambient_light_color = Color(0.2, 0.19, 0.3).lerp(Color(0.55, 0.55, 0.62), dl)
	_env.fog_density = lerpf(0.03, 0.012, dl)
	var tint := Color(0.34, 0.37, 0.55).lerp(Color(1, 1, 1), dl)
	Blocks.material().albedo_color = tint
	Blocks.material_translucent().albedo_color = tint


# ---------------------------------------------------------------- players

func spawn_player(pid: int, pos: Vector3) -> void:
	var existing := players_node.get_node_or_null(str(pid))
	if existing != null:
		existing.teleport_to(pos)
		return
	var p := LLPlayer.new()
	p.name = str(pid)
	p.pid = pid
	players_node.add_child(p)
	p.teleport_to(pos)


func remove_player(pid: int) -> void:
	var p := players_node.get_node_or_null(str(pid))
	if p != null:
		p.queue_free()


func get_player(pid: int):
	return players_node.get_node_or_null(str(pid))


# ---------------------------------------------------------------- enemies

func spawn_enemy(e: Dictionary) -> void:
	var eid := int(e.id)
	if enemies_node.get_node_or_null(str(eid)) != null:
		return
	var node := LLEnemy.new()
	node.name = str(eid)
	node.setup(e)
	enemies_node.add_child(node)
	node.global_position = Vector3(e.pos)
	if bool(e.get("boss", false)):
		AudioMgr.sfx3d("sfx_growl", Vector3(e.pos), 4.0)


func despawn_enemy(eid: int) -> void:
	var n := enemies_node.get_node_or_null(str(eid))
	if n != null:
		n.die()


func get_enemy(eid: int):
	return enemies_node.get_node_or_null(str(eid))


func update_enemy_positions(posmap: Dictionary) -> void:
	if Game.is_server():
		return  # server enemies move themselves
	for eid in posmap:
		var n := enemies_node.get_node_or_null(str(int(eid)))
		if n != null:
			n.net_target = Vector3(posmap[eid])


# ---------------------------------------------------------------- pickups

func spawn_pickup(k: Dictionary) -> void:
	var kid := int(k.id)
	if pickups_node.get_node_or_null(str(kid)) != null:
		return
	var n := LLPickup.new()
	n.name = str(kid)
	n.item = k.item
	n.owner_name = String(k.get("owner_name", ""))
	pickups_node.add_child(n)
	n.global_position = Vector3(k.pos)


func take_pickup(kid: int) -> void:
	var n := pickups_node.get_node_or_null(str(kid))
	if n != null:
		n.queue_free()


## Floating damage number over a mob — the heartbeat of real-time combat.
func spawn_hit_fx(eid: int, dmg: int, txt: String) -> void:
	var n := enemies_node.get_node_or_null(str(eid))
	if n == null:
		return
	n.est_hp = maxi(n.est_hp - dmg, 0)  # keeps Seer's Eye estimates honest
	AudioMgr.sfx3d("sfx_crit" if txt == "CRIT!" else ("sfx_swing" if dmg <= 0 else "sfx_hit"),
		n.global_position, -10.0 if dmg <= 0 else -2.0)
	# Hit punch: the mob recoils; telegraphs blow up big and red instead.
	if dmg > 0:
		var base_scale: Vector3 = n.scale
		var tw2 := n.create_tween()
		tw2.tween_property(n, "scale", base_scale * 1.18, 0.06)
		tw2.tween_property(n, "scale", base_scale, 0.12)
		# Impact spark: an additive burst at the wound — gold for crits.
		var spark := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.16
		sm.height = 0.32
		spark.mesh = sm
		var smat := StandardMaterial3D.new()
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		smat.albedo_color = Color(1.0, 0.85, 0.25, 0.9) if txt == "CRIT!" \
			else Color(1.0, 0.3, 0.2, 0.85)
		spark.material_override = smat
		spark.position = Vector3(randf_range(-0.2, 0.2), 1.0, randf_range(-0.2, 0.2))
		n.add_child(spark)
		var tw3 := spark.create_tween()
		tw3.set_parallel(true)
		tw3.tween_property(spark, "scale", Vector3.ONE * (4.0 if txt == "CRIT!" else 2.4), 0.18)
		tw3.tween_property(smat, "albedo_color:a", 0.0, 0.2)
		tw3.chain().tween_callback(spark.queue_free)
	var label := Label3D.new()
	label.text = txt if dmg <= 0 else ("%d %s" % [dmg, txt]).strip_edges()
	label.font_size = 64 if txt == "CRIT!" else 44
	label.pixel_size = 0.006
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1, 0.85, 0.2) if txt == "CRIT!" else \
		(Color(0.7, 0.7, 0.8) if dmg <= 0 else Color(1, 0.35, 0.25))
	label.position = Vector3(randf_range(-0.3, 0.3), 2.2, 0)
	n.add_child(label)
	var tw := label.create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "position:y", 3.4, 0.8)
	tw.tween_property(label, "modulate:a", 0.0, 0.8)
	tw.chain().tween_callback(label.queue_free)


func clear_entities() -> void:
	# queue_free + immediate rename: freed nodes linger until end of frame,
	# and str(eid) lookups must not find corpses.
	for n in enemies_node.get_children():
		n.name = "dead_%s" % n.name
		n.queue_free()
	for n in pickups_node.get_children():
		n.name = "gone_%s" % n.name
		n.queue_free()
