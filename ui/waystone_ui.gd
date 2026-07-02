class_name WaystoneUI
extends Control
## Waystone travel: pick any attuned waystone on this floor and fold space.

var main
var _list: VBoxContainer


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(380, 0)
	root.add_child(UITheme.title("Waystone", 22))
	root.add_child(UITheme.label("Place more waystones to bookmark the floor.", 12, UITheme.DIM))
	_list = VBoxContainer.new()
	var pan := UITheme.panel(UITheme.NEON)
	pan.add_child(_list)
	root.add_child(pan)
	var close := UITheme.button("Close", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))


func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	if Game.waystones.is_empty():
		_list.add_child(UITheme.label("No other waystones hum on this floor.", 13, UITheme.DIM))
		return
	for key in Game.waystones:
		var ws: Dictionary = Game.waystones[key]
		var b := UITheme.button("◆ %s  (%d, %d)" % [ws.name, int(ws.pos.x), int(ws.pos.z)], 14)
		var k: String = key
		b.pressed.connect(func():
			Game.request_waystone_tp(k)
			main.close_top_ui())
		_list.add_child(b)
