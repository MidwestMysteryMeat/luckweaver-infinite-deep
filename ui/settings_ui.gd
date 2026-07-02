class_name SettingsUI
extends Control
## Settings: mouse sensitivity + music/SFX volume. Persisted to user://saves.

var main


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(420, 0)
	root.add_child(UITheme.title("Settings", 24))

	root.add_child(_slider_row("Mouse sensitivity", 0.0008, 0.008,
		float(SaveMgr.settings.sens), func(v): SaveMgr.settings.sens = v))
	root.add_child(_slider_row("Music volume", -40.0, 6.0,
		float(SaveMgr.settings.vol_music), func(v):
			SaveMgr.settings.vol_music = v
			AudioMgr.apply_settings()))
	root.add_child(_slider_row("SFX volume", -40.0, 6.0,
		float(SaveMgr.settings.vol_sfx), func(v):
			SaveMgr.settings.vol_sfx = v
			AudioMgr.apply_settings()))
	root.add_child(UITheme.label("Keys: WASD·Space·Shift · LMB attack/mine · RMB use · Ctrl dodge\nE interact · Tab satchel · K skills · M map · H handbook", 12, UITheme.DIM))

	var close := UITheme.button("Save & Close", 14)
	close.pressed.connect(func():
		SaveMgr.save_settings()
		main.close_top_ui())
	root.add_child(close)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))


func _slider_row(label: String, mn: float, mx: float, val: float, on_change: Callable) -> Control:
	var row := VBoxContainer.new()
	row.add_child(UITheme.label(label, 14, UITheme.NEON))
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = (mx - mn) / 100.0
	s.value = val
	s.custom_minimum_size = Vector2(380, 20)
	s.value_changed.connect(on_change)
	row.add_child(s)
	return row
