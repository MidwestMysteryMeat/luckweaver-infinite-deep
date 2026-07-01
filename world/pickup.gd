class_name LLPickup
extends Node3D
## Dropped loot, dressed to be seen across a dark room: a spinning gem-cut
## core, a vertical light beam, and a pulsing glow — all tinted by rarity.
## Round-robin drops show their owner's name. Collection is server-side
## proximity (Game); this node is pure presentation.

var item := {}
var owner_name := ""
var _t := 0.0
var _base_y := 0.0
var _core: MeshInstance3D
var _core_mat: StandardMaterial3D


func _ready() -> void:
	var col: Color = Db.item_color(item) if not item.is_empty() else Color.GOLD
	var meta: Dictionary = item.get("meta", {}) if not item.is_empty() else {}
	var rare: bool = meta.has("rarity") and int(meta.rarity) >= Db.Rarity.RARE

	# Gem core: a squashed octahedron-ish prism (box rotated 45°).
	_core = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.32, 0.44, 0.32) * (1.35 if rare else 1.0)
	_core.mesh = bm
	_core.rotation_degrees = Vector3(45, 0, 45)
	_core_mat = StandardMaterial3D.new()
	_core_mat.albedo_color = col
	_core_mat.emission_enabled = true
	_core_mat.emission = col
	_core_mat.emission_energy_multiplier = 1.4 if rare else 0.8
	_core.material_override = _core_mat
	add_child(_core)

	# Beacon beam so drops read across a dark room.
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.12
	cyl.height = 2.6 if rare else 1.6
	beam.mesh = cyl
	beam.position.y = cyl.height * 0.5
	var bmat := StandardMaterial3D.new()
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bmat.albedo_color = Color(col.r, col.g, col.b, 0.28)
	bmat.emission_enabled = true
	bmat.emission = col
	bmat.emission_energy_multiplier = 0.6
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam.material_override = bmat
	add_child(beam)

	var label := Label3D.new()
	var lname: String = Db.item_name(item) if not item.is_empty() else "?"
	if int(item.get("count", 1)) > 1:
		lname += " ×%d" % int(item.count)
	if owner_name != "":
		lname += "\n(%s's)" % owner_name
	label.text = lname
	label.position.y = 0.75
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 28
	label.pixel_size = 0.004
	label.modulate = col.lightened(0.3)
	add_child(label)
	_base_y = position.y


func _process(delta: float) -> void:
	_t += delta
	_core.rotate_y(delta * 2.2)
	_core.position.y = 0.35 + sin(_t * 2.5) * 0.12
	_core_mat.emission_energy_multiplier = 1.0 + sin(_t * 4.0) * 0.4
