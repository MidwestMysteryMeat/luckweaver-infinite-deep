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
	_marker_info = UITheme.label("48×48 around YOU (center dot) · bright = open floor · dark = rock · cyan = waystone · gold = portal", 13, UITheme.DIM)
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
	# Player-centered 48×48 window, blown up — reads like a minimap page,
	# and the same approach will pan seamlessly on the infinite world.
	# Infinite world: an unbounded window centered wherever you stand, scanned
	# around YOUR depth — surface shows terrain, underground shows your cave level.
	var p0 = main.local_player()
	var cx := 0
	var cz := 0
	var cy := WorldGen.SURFACE
	if p0 != null:
		cx = int(p0.global_position.x)
		cz = int(p0.global_position.z)
		cy = int(p0.global_position.y)
	var img := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	for mx in range(48):
		for mz in range(48):
			var x := cx - 24 + mx
			var z := cz - 24 + mz
			var col := Color(0.06, 0.05, 0.09)
			for y in range(mini(cy + 4, WorldGen.H - 1), maxi(cy - 12, 0), -1):
				var id: int = vw.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				var def := Blocks.get_def(id)
				if y > cy + 1:
					col = Color(0.09, 0.08, 0.12)  # overhead rock
				else:
					col = def.color.lightened(0.25)
					if def.glow:
						col = col.lightened(0.3)
				break
			img.set_pixel(mx, mz, col)
	# Markers (window-relative): gold = portal down, cyan = waystones, ● = you.
	var pp: Array = Game.gen_info.get("portal_pos", [])
	if pp.size() == 3:
		_blot(img, int(pp[0]) - cx + 24, int(pp[2]) - cz + 24, Color(1.0, 0.75, 0.1))
	for key in Game.waystones:
		var wp: Vector3 = Game.waystones[key].pos
		_blot(img, int(wp.x) - cx + 24, int(wp.z) - cz + 24, Color(0.4, 0.8, 1.0))
	if p0 != null:
		_blot(img, int(p0.global_position.x) - cx + 24, int(p0.global_position.z) - cz + 24,
			Color(1, 1, 0.3))
	_tex.texture = ImageTexture.create_from_image(img)


func _blot(img: Image, x: int, z: int, col: Color) -> void:
	if x < -1 or z < -1 or x > 48 or z > 48:
		return  # off this window
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var px := clampi(x + dx, 0, 47)
			var pz := clampi(z + dz, 0, 47)
			img.set_pixel(px, pz, col)
