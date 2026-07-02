class_name MapUI
extends Control
## Floor map (M): top-down render of the voxel floor straight from local data —
## walls dark, open floor by block color, fluids vivid, you and your waystones
## marked. No exploration fog: Luckweavers read stone like a book.

var main
var _tex: TextureRect
var _marker_info: Label


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.add_child(UITheme.title("Floor Map", 22))
	_tex = TextureRect.new()
	_tex.custom_minimum_size = Vector2(480, 480)
	_tex.stretch_mode = TextureRect.STRETCH_SCALE
	_tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.add_child(_tex)
	_marker_info = UITheme.label("● you   ◆ waystones   ▲ portal side", 13, UITheme.DIM)
	_marker_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_marker_info)
	var close := UITheme.button("Close (M)", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))


func refresh() -> void:
	var vw = Game.voxel
	if vw == null:
		return
	var img := Image.create(VoxelWorld.SX, VoxelWorld.SZ, false, Image.FORMAT_RGB8)
	for x in range(VoxelWorld.SX):
		for z in range(VoxelWorld.SZ):
			# Top-down: first non-air block from a sensible ceiling height.
			var col := Color(0.04, 0.03, 0.07)
			for y in range(14, -1, -1):
				var id: int = vw.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				var def := Blocks.get_def(id)
				col = def.color
				if y > 6:
					col = col.darkened(0.55)  # high solid = wall mass
				elif def.glow:
					col = col.lightened(0.2)
				break
			img.set_pixel(x, z, col)
	# Markers.
	for key in Game.waystones:
		var wp: Vector3 = Game.waystones[key].pos
		_blot(img, int(wp.x), int(wp.z), Color(0.4, 0.8, 1.0))
	var p = main.local_player()
	if p != null:
		_blot(img, int(p.global_position.x), int(p.global_position.z), Color(1, 1, 0.3))
	_tex.texture = ImageTexture.create_from_image(img)


func _blot(img: Image, x: int, z: int, col: Color) -> void:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var px := clampi(x + dx, 0, VoxelWorld.SX - 1)
			var pz := clampi(z + dz, 0, VoxelWorld.SZ - 1)
			img.set_pixel(px, pz, col)
