class_name HUD
extends Control
## In-run overlay: stat bars, hotbar, crosshair, interact prompt, mining
## progress, toasts, and chat. Reads Game.my_rec(); never mutates anything.

var main
var _hp: ProgressBar
var _breath: ProgressBar
var _hp_text: Label
var _gold: Label
var _luck: Label
var _level: Label
var _floor: Label
var _prompt: Label
var _mine_bar: ProgressBar
var _toast_box: VBoxContainer
var _chat_box: VBoxContainer
var _chat_edit: LineEdit
var _hotbar: HBoxContainer
var _slots: Array = []
var _prompt_hint := ""
var _tutorial: Label


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# --- top-left stats
	var stats := VBoxContainer.new()
	stats.position = Vector2(16, 12)
	_hp = UITheme.hbar(100, 100, UITheme.RED, 220, 18)
	stats.add_child(_hp)
	_hp_text = UITheme.label("", 13)
	stats.add_child(_hp_text)
	_gold = UITheme.label("", 16, UITheme.GOLD)
	stats.add_child(_gold)
	_luck = UITheme.label("", 14, UITheme.NEON)
	stats.add_child(_luck)
	_level = UITheme.label("", 13, UITheme.DIM)
	stats.add_child(_level)
	_breath = UITheme.hbar(20, 20, Color(0.4, 0.7, 0.95), 220, 10)
	_breath.visible = false
	stats.add_child(_breath)
	add_child(stats)

	# --- tutorial line (top-center)
	_tutorial = UITheme.label("", 15, UITheme.NEON)
	_tutorial.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_tutorial.position += Vector2(-300, 14)
	_tutorial.custom_minimum_size = Vector2(600, 0)
	_tutorial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_tutorial)

	# --- top-right floor
	_floor = UITheme.label("", 18, UITheme.GOLD)
	_floor.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_floor.position = Vector2(-260, 14)
	_floor.custom_minimum_size = Vector2(240, 0)
	_floor.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_floor)

	# --- crosshair
	var cross := UITheme.label("+", 22, Color(1, 1, 1, 0.7))
	cross.set_anchors_preset(Control.PRESET_CENTER)
	add_child(cross)

	# --- interact prompt + mining bar (center-bottom)
	var midv := VBoxContainer.new()
	midv.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	midv.position += Vector2(-150, -150)
	midv.custom_minimum_size = Vector2(300, 0)
	_prompt = UITheme.label("", 16, UITheme.NEON)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	midv.add_child(_prompt)
	_mine_bar = UITheme.hbar(0, 1, UITheme.GOLD, 200, 8)
	_mine_bar.visible = false
	midv.add_child(_mine_bar)
	add_child(midv)

	# --- hotbar (bottom-center)
	_hotbar = HBoxContainer.new()
	_hotbar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hotbar.position += Vector2(-9 * 33, -70)
	for i in range(9):
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(58, 58)
		slot.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.DIM))
		var v := VBoxContainer.new()
		var nm := UITheme.label("", 10)
		nm.clip_text = true
		nm.custom_minimum_size = Vector2(50, 0)
		var ct := UITheme.label("", 11, UITheme.GOLD)
		v.add_child(nm)
		v.add_child(ct)
		slot.add_child(v)
		_hotbar.add_child(slot)
		_slots.append({"panel": slot, "name": nm, "count": ct})
	add_child(_hotbar)

	# --- toasts (right side)
	_toast_box = VBoxContainer.new()
	_toast_box.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_toast_box.position += Vector2(-420, -100)
	_toast_box.custom_minimum_size = Vector2(400, 0)
	add_child(_toast_box)

	# --- chat (bottom-left)
	var chatv := VBoxContainer.new()
	chatv.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chatv.position += Vector2(16, -220)
	chatv.custom_minimum_size = Vector2(380, 200)
	_chat_box = VBoxContainer.new()
	_chat_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_box.alignment = BoxContainer.ALIGNMENT_END
	chatv.add_child(_chat_box)
	_chat_edit = UITheme.line_edit("T to chat...")
	_chat_edit.visible = false
	_chat_edit.text_submitted.connect(_send_chat)
	chatv.add_child(_chat_edit)
	add_child(chatv)

	Events.notify.connect(_toast)
	Events.chat_line.connect(_chat)
	Events.my_record_changed.connect(_refresh_stats)
	Events.floor_loaded.connect(func(f): _floor.text = _floor_name(f))


func _floor_name(f: int) -> String:
	if f == 0:
		return "🏛 The Gilded Refuge"
	var biomes := {"delve": "⛏", "caverns": "🕳", "lakes": "🌊", "molten": "🔥"}
	var icon: String = biomes.get(String(Game.gen_info.get("biome", "delve")), "⛏")
	if f % 5 == 0:
		return "👑 Floor %d — THE VAULT TYRANT" % f
	return "%s Floor %d" % [icon, f]


func _process(_delta: float) -> void:
	var p = main.local_player()
	if p == null:
		return
	_refresh_stats()
	_tutorial.text = _prompt_hint
	_prompt.text = p.aim_prompt() if not p.locked else ""
	_mine_bar.visible = p.mining_progress > 0.01
	_mine_bar.value = p.mining_progress
	_refresh_hotbar(p)


func _refresh_stats() -> void:
	var rec := Game.my_rec()
	if rec.is_empty():
		return
	_hp.max_value = rec.max_hp
	_hp.value = rec.hp
	_hp_text.text = "%d / %d HP" % [rec.hp, rec.max_hp]
	_gold.text = "◉ %d gold" % rec.gold
	_luck.text = "☘ luck %d" % Game.eff_luck(rec)
	var muts := ""
	if not rec.mutations.is_empty():
		muts = "  |  " + ", ".join(rec.mutations.map(func(m): return Db.MUTATIONS[m].name))
	var pts := int(rec.get("skill_points", 0))
	if pts > 0:
		muts += "  |  ✦ %d skill point%s (K)" % [pts, "s" if pts > 1 else ""]
	var inj: Dictionary = rec.get("injuries", {})
	if not inj.is_empty():
		muts += "  |  🩸 injured: %s" % ", ".join(inj.keys())
	_level.text = "lv %d (%d/%d xp)%s" % [rec.level, rec.xp, Db.xp_for_level(int(rec.level)), muts]
	var breath := float(rec.get("breath", 20.0))
	_breath.visible = breath < 19.5
	_breath.value = breath
	# Tutorial breadcrumbs for fresh Luckweavers (H opens the full handbook).
	if int(rec.level) == 1 and Game.floor_num == 0:
		var inv: Array = rec.get("inv", [])
		var mined := false
		for it in inv:
			if it != null and it.id in ["stone", "brick", "dirt"]:
				mined = true
		var step := "Hold LMB on a wall to MINE — then press H for the handbook"
		if mined and int(rec.xp) == 0:
			step = "Visit the ANVIL / CAULDRON (north wall) — then take the south PORTAL down"
		elif int(rec.xp) > 0:
			step = "You've drawn blood. The portal south leads deeper — good luck"
		_prompt_hint = "✦ TUTORIAL: %s" % step
	else:
		_prompt_hint = ""


func _refresh_hotbar(p) -> void:
	var rec := Game.my_rec()
	var inv: Array = rec.get("inv", [])
	for i in range(9):
		var s: Dictionary = _slots[i]
		var e = inv[i] if i < inv.size() else null
		if e == null:
			s.name.text = ""
			s.count.text = str(i + 1)
			s.name.add_theme_color_override("font_color", UITheme.DIM)
		else:
			s.name.text = Db.item_name(e)
			s.name.add_theme_color_override("font_color", Db.item_color(e))
			s.count.text = "×%d" % e.count if e.count > 1 else ""
		var style := UITheme.panel_style(UITheme.GOLD if i == p.selected_slot else UITheme.DIM)
		style.set_content_margin_all(4)
		s.panel.add_theme_stylebox_override("panel", style)


func _toast(text: String) -> void:
	var l := UITheme.label(text, 15, UITheme.GOLD)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_toast_box.add_child(l)
	if _toast_box.get_child_count() > 6:
		_toast_box.get_child(0).free()
	var tw := create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)


func _chat(who: String, text: String) -> void:
	var l := UITheme.label("%s: %s" % [who, text], 13)
	_chat_box.add_child(l)
	if _chat_box.get_child_count() > 8:
		_chat_box.get_child(0).free()


func chat_open() -> bool:
	return _chat_edit.visible


func open_chat() -> void:
	_chat_edit.visible = true
	_chat_edit.grab_focus()
	main.set_player_locked(true)


func _send_chat(text: String) -> void:
	_chat_edit.visible = false
	_chat_edit.text = ""
	main.set_player_locked(false)
	if text.strip_edges() != "":
		Game.request_chat(text.strip_edges())
