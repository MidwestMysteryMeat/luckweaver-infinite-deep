class_name LLWorld
extends Node3D
## The in-game 3D scene, built entirely in code by scenes/main.gd when a run
## starts. Owns the VoxelWorld and the entity containers; Game drives it.

var voxel: VoxelWorld
var players_node: Node3D
var enemies_node: Node3D
var pickups_node: Node3D


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
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.03, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.35, 0.5)
	env.fog_enabled = true
	env.fog_light_color = Color(0.12, 0.07, 0.18)
	env.fog_density = 0.025
	env.glow_enabled = true
	env.glow_intensity = 0.4
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


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
	for n in enemies_node.get_children():
		n.free()
	for n in pickups_node.get_children():
		n.free()
