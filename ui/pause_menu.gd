class_name PauseMenu
extends Control
## Esc menu. Multiplayer never pauses the tree; this just frees the mouse.

var main


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	root.custom_minimum_size = Vector2(320, 0)
	root.add_child(UITheme.title("Paused", 26))

	var resume := UITheme.button("Resume")
	resume.pressed.connect(func(): main.close_top_ui())
	root.add_child(resume)

	var settings := UITheme.button("Settings")
	settings.pressed.connect(func(): main._open_ui(SettingsUI.new(main)))
	root.add_child(settings)

	if Game.is_server():
		var save := UITheme.button("Save Game (F5)")
		save.pressed.connect(func(): Game.save_now())
		root.add_child(save)

	var leave := UITheme.button("Leave to Menu")
	leave.pressed.connect(func():
		main.close_top_ui()
		Game.leave_to_menu())
	root.add_child(leave)

	var quit := UITheme.button("Quit Game")
	quit.pressed.connect(func():
		if Game.is_server() and Game.in_run:
			Game.save_now()
		main.get_tree().quit())
	root.add_child(quit)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))
