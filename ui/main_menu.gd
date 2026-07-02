class_name MainMenuUI
extends Control
## Title screen: solo / host / join (Steam and LAN), continue from save.

var main  # scenes/main.gd
var _ip_edit: LineEdit
var _lobby_edit: LineEdit
var _status: Label
var _lobby_box: VBoxContainer


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.03, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	root.custom_minimum_size = Vector2(460, 0)

	root.add_child(UITheme.title("LUCKWEAVER"))
	root.add_child(UITheme.title("Infinite Deep", 20))
	var sub := UITheme.label("Fate favors you. Reshape the dungeon. Descend forever.", 14, UITheme.DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(sub)
	root.add_child(HSeparator.new())

	var solo := UITheme.button("🎲  Solo Run")
	solo.pressed.connect(func():
		Net.start_solo()
		main.show_lobby())
	root.add_child(solo)

	if SaveMgr.has_save():
		var cont := UITheme.button("♻  Continue Last Save (as host)")
		cont.pressed.connect(func():
			Game.pending_load = SaveMgr.load_latest()
			Net.start_solo()
			main.show_lobby())
		root.add_child(cont)

	root.add_child(HSeparator.new())

	var host_steam := UITheme.button("☁  Host Steam Lobby")
	host_steam.disabled = not SteamMgr.enabled
	host_steam.pressed.connect(func():
		if Net.host_steam():
			main.show_lobby())
	root.add_child(host_steam)

	var steam_row := HBoxContainer.new()
	_lobby_edit = UITheme.line_edit("Steam lobby ID")
	_lobby_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steam_row.add_child(_lobby_edit)
	var join_steam := UITheme.button("Join")
	join_steam.disabled = not SteamMgr.enabled
	join_steam.pressed.connect(func():
		var id := int(_lobby_edit.text.strip_edges())
		if id > 0 and Net.join_steam(id):
			main.show_lobby())
	steam_row.add_child(join_steam)
	var find := UITheme.button("Find Lobbies")
	find.disabled = not SteamMgr.enabled
	find.pressed.connect(func(): Net.request_lobby_list())
	steam_row.add_child(find)
	root.add_child(steam_row)

	_lobby_box = VBoxContainer.new()
	root.add_child(_lobby_box)

	root.add_child(HSeparator.new())

	var lan_row := HBoxContainer.new()
	_ip_edit = UITheme.line_edit("IP address (e.g. 127.0.0.1)")
	_ip_edit.text = "127.0.0.1"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_row.add_child(_ip_edit)
	var join_lan := UITheme.button("Join LAN")
	join_lan.pressed.connect(func():
		if Net.join_lan(_ip_edit.text.strip_edges()):
			main.show_lobby())
	lan_row.add_child(join_lan)
	var host_lan := UITheme.button("Host LAN")
	host_lan.pressed.connect(func():
		if Net.host_lan():
			main.show_lobby())
	lan_row.add_child(host_lan)
	root.add_child(lan_row)

	root.add_child(HSeparator.new())
	var steam_txt := "Steam: online as %s" % SteamMgr.persona if SteamMgr.enabled \
		else "Steam: not detected — LAN & solo available (see README to enable)"
	_status = UITheme.label(steam_txt, 13, UITheme.NEON if SteamMgr.enabled else UITheme.DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_status)

	var reset := UITheme.button("🗑 New Character (wipe progression)", 13)
	reset.pressed.connect(func():
		if FileAccess.file_exists(SaveMgr.CHARACTER):
			DirAccess.remove_absolute(SaveMgr.CHARACTER)
		_status.text = "Character wiped — next run starts fresh and empty-handed."
		_status.add_theme_color_override("font_color", UITheme.NEON))
	root.add_child(reset)

	var how := UITheme.button("📖 How to Play", 14)
	how.pressed.connect(func(): main._open_ui(GuideUI.new(main)))
	root.add_child(how)

	var quit := UITheme.button("Quit", 14)
	quit.pressed.connect(func(): main.get_tree().quit())
	root.add_child(quit)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))

	Events.net_error.connect(_on_net_error)
	Events.lobby_changed.connect(_refresh_lobby_list)


func _on_net_error(msg: String) -> void:
	if is_inside_tree():
		_status.text = "⚠ " + msg
		_status.add_theme_color_override("font_color", UITheme.RED)


func _refresh_lobby_list() -> void:
	if not is_inside_tree():
		return
	for c in _lobby_box.get_children():
		c.queue_free()
	for entry in Game.lobby_list:
		var b := UITheme.button("Join %s's table (lobby %d)" % [entry.host, entry.id], 14)
		b.pressed.connect(func():
			if Net.join_steam(int(entry.id)):
				main.show_lobby())
		_lobby_box.add_child(b)
