class_name LobbyUI
extends Control
## Pre-run staging: shows connected players, class picker, host's Start button.

var main
var _list: VBoxContainer
var _class_pick: OptionButton
var _loot_pick: OptionButton
var _loot_desc: Label
var _start: Button
var _class_ids: Array = []

const LOOT_RULES := [
	{"id": "ffa", "label": "Free for all", "desc": "first hands on it keep it"},
	{"id": "round_robin", "label": "Round robin", "desc": "drops are assigned in turn"},
	{"id": "shared_gold", "label": "Shared gold", "desc": "gold splits evenly, items FFA"},
]


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.03, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	root.custom_minimum_size = Vector2(520, 0)
	root.add_child(UITheme.title("The Table Is Set"))

	if Net.mode == Net.Mode.STEAM:
		root.add_child(UITheme.label("Steam lobby ID (share with friends): %d" % Net.lobby_id, 14, UITheme.NEON))
	elif Net.mode == Net.Mode.ENET:
		root.add_child(UITheme.label("Hosting LAN on port %d" % Net.PORT, 14, UITheme.NEON))

	_list = VBoxContainer.new()
	var pan := UITheme.panel(UITheme.NEON)
	pan.add_child(_list)
	root.add_child(pan)

	var row := HBoxContainer.new()
	row.add_child(UITheme.label("Class: ", 16))
	_class_pick = OptionButton.new()
	_class_ids = Db.CLASSES.keys()
	for cid in _class_ids:
		_class_pick.add_item(Db.CLASSES[cid].name)
	_class_pick.item_selected.connect(func(i):
		Game.request_set_class(_class_ids[i]))
	row.add_child(_class_pick)
	root.add_child(row)

	# Loot rules — host decides how the spoils are shared.
	var lrow := HBoxContainer.new()
	lrow.add_child(UITheme.label("Loot rule: ", 16))
	_loot_pick = OptionButton.new()
	for r in LOOT_RULES:
		_loot_pick.add_item(r.label)
	_loot_pick.disabled = not Game.is_server()
	_loot_pick.item_selected.connect(func(i):
		Game.request_set_loot_rule(LOOT_RULES[i].id))
	lrow.add_child(_loot_pick)
	_loot_desc = UITheme.label("", 12, UITheme.DIM)
	lrow.add_child(_loot_desc)
	root.add_child(lrow)

	_start = UITheme.button("▶  Start the Run")
	_start.visible = Game.is_server()
	_start.pressed.connect(func(): Game.request_start_run())
	root.add_child(_start)

	var back := UITheme.button("Leave", 14)
	back.pressed.connect(func(): Game.leave_to_menu())
	root.add_child(back)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))
	Events.lobby_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	if not is_inside_tree() and _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	for pid in Game.lobby:
		var e: Dictionary = Game.lobby[pid]
		var cname: String = Db.CLASSES.get(e.class_id, {}).get("name", "?")
		var tag := "♛ " if pid == 1 else "• "
		_list.add_child(UITheme.label("%s%s — %s" % [tag, e.name, cname], 16,
			UITheme.GOLD if pid == Game.my_id() else UITheme.TEXT))
	if Game.lobby.is_empty():
		_list.add_child(UITheme.label("Connecting to the table...", 14, UITheme.DIM))
	for i in range(LOOT_RULES.size()):
		if LOOT_RULES[i].id == Game.loot_rule:
			_loot_pick.select(i)
			_loot_desc.text = "(%s)" % LOOT_RULES[i].desc
