class_name StorageUI
extends Control
## Storage chest: 12 shared slots per chest. Click chest items to take, click
## your items to deposit. Contents live on the host; town chests persist.

var main
var chest_key := ""
var _chest_list: VBoxContainer
var _inv_list: VBoxContainer
var _items: Array = []


func _init(main_ref, key: String) -> void:
	main = main_ref
	chest_key = key
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(620, 0)
	root.add_child(UITheme.title("Storage Chest", 22))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	var left := VBoxContainer.new()
	left.add_child(UITheme.label("Inside (click to take)", 14, UITheme.NEON))
	_chest_list = VBoxContainer.new()
	var lp := UITheme.panel(UITheme.NEON)
	lp.add_child(_chest_list)
	left.add_child(lp)
	cols.add_child(left)
	var right := VBoxContainer.new()
	right.add_child(UITheme.label("Your satchel (click to deposit)", 14, UITheme.GOLD))
	_inv_list = VBoxContainer.new()
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(280, 320)
	scroll.add_child(_inv_list)
	var rp := UITheme.panel(UITheme.GOLD)
	rp.add_child(scroll)
	right.add_child(rp)
	cols.add_child(right)
	root.add_child(cols)
	var close := UITheme.button("Close", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))
	Events.chest_contents.connect(_on_contents)
	Events.my_record_changed.connect(_refresh_inv)
	Game.request_chest_open(chest_key)


func refresh() -> void:
	_refresh_inv()


func _on_contents(key: String, items: Array) -> void:
	if key != chest_key or not is_inside_tree():
		return
	_items = items
	for c in _chest_list.get_children():
		c.free()
	if _items.is_empty():
		_chest_list.add_child(UITheme.label("(empty)", 13, UITheme.DIM))
	for i in range(_items.size()):
		var it: Dictionary = _items[i]
		var b := UITheme.button("%s ×%d" % [Db.item_name(it), int(it.count)], 14)
		b.add_theme_color_override("font_color", Db.item_color(it))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := i
		b.pressed.connect(func(): Game.request_chest_take(chest_key, idx))
		_chest_list.add_child(b)


func _refresh_inv() -> void:
	if not is_inside_tree():
		return
	for c in _inv_list.get_children():
		c.free()
	var inv: Array = Game.my_rec().get("inv", [])
	for i in range(inv.size()):
		var e = inv[i]
		if e == null:
			continue
		var b := UITheme.button("%s ×%d" % [Db.item_name(e), int(e.count)], 13)
		b.add_theme_color_override("font_color", Db.item_color(e))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := i
		b.pressed.connect(func(): Game.request_chest_put(chest_key, idx))
		_inv_list.add_child(b)
