class_name CombatUI
extends Control
## The battle screen (and NPC parley screen). Renders whatever encounter state
## dict the server sends and fires action ids back — zero game logic here.
## Centerpiece: big d20 results so every hit, crit, and fumble reads at a glance.

var main
var _title: Label
var _phase_lbl: Label
var _enemy_bar: ProgressBar
var _enemy_txt: Label
var _intent: Label
var _log: VBoxContainer
var _dice_row: HBoxContainer
var _actions: HBoxContainer
var _footer: Label


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	root.custom_minimum_size = Vector2(680, 0)

	_title = UITheme.title("", 26)
	root.add_child(_title)
	_phase_lbl = UITheme.label("", 14, UITheme.NEON)
	_phase_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_phase_lbl)

	_enemy_bar = UITheme.hbar(1, 1, UITheme.RED, 640, 20)
	root.add_child(_enemy_bar)
	_enemy_txt = UITheme.label("", 13, UITheme.DIM)
	_enemy_txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_enemy_txt)
	_intent = UITheme.label("", 13, UITheme.NEON)
	_intent.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_intent)
	root.add_child(HSeparator.new())

	_log = VBoxContainer.new()
	_log.custom_minimum_size = Vector2(0, 190)
	_log.alignment = BoxContainer.ALIGNMENT_END
	var logpan := UITheme.panel(UITheme.DIM)
	logpan.add_child(_log)
	root.add_child(logpan)

	_dice_row = HBoxContainer.new()
	_dice_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_row.add_theme_constant_override("separation", 16)
	root.add_child(_dice_row)

	_actions = HBoxContainer.new()
	_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_actions.add_theme_constant_override("separation", 8)
	root.add_child(_actions)

	_footer = UITheme.label("", 14, UITheme.GOLD)
	_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_footer)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))


func render(st: Dictionary) -> void:
	if String(st.phase) == "done":
		main.close_combat()
		return
	var tag := ""
	if st.get("boss", false):
		tag = "👑 "
	elif String(st.get("elite", "")) != "":
		tag = "★ "
	_title.text = "%s%s" % [tag, st.enemy_name]
	if st.get("boss", false):
		_phase_lbl.text = "— PHASE %d —" % int(st.get("boss_phase", 1))
	elif String(st.phase) == "npc":
		_phase_lbl.text = "· parley ·"
	else:
		_phase_lbl.text = "Your move" if String(st.phase) == "player" else ""
	_enemy_bar.max_value = st.enemy_max
	_enemy_bar.value = st.enemy_hp
	var ac_txt := ""
	if int(st.get("enemy_ac", -1)) >= 0:
		ac_txt = "   AC %d" % int(st.enemy_ac)
	_enemy_txt.text = "%d / %d%s" % [st.enemy_hp, st.enemy_max, ac_txt]
	_intent.text = String(st.get("intent", ""))

	for c in _log.get_children():
		c.free()
	for line in st.lines:
		_log.add_child(UITheme.label(str(line), 14))

	# Dice showcase: the last couple of rolls, huge.
	for c in _dice_row.get_children():
		c.free()
	for r in st.get("rolls", []):
		_dice_row.add_child(_die_panel(r))

	for c in _actions.get_children():
		c.free()
	for a in st.actions:
		var b := UITheme.button(str(a.label), 16)
		var aid := str(a.id)
		b.pressed.connect(func(): Game.request_enc_action(aid))
		_actions.add_child(b)

	var poison := ""
	if int(st.get("poison", 0)) > 0:
		poison = "   ☠ poison ×%d" % int(st.poison)
	_footer.text = "♥ %d/%d   🛡 AC %d   ◉ %d gold   ☘ luck %d%s" % \
		[st.hp, st.max_hp, st.get("ac", 10), st.gold, st.luck, poison]


func _die_panel(r: Dictionary) -> Control:
	var v := VBoxContainer.new()
	var who := UITheme.label("YOU" if String(r.who) == "you" else "FOE", 12, UITheme.DIM)
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(who)
	var outcome := String(r.get("txt", ""))
	var col := UITheme.NEON
	if outcome in ["CRIT!", "ROBBED!"]:
		col = UITheme.GOLD
	elif outcome in ["MISS", "FUMBLE", "CAUGHT"]:
		col = UITheme.RED
	var dice: Array = r.get("dice", [])
	var face := UITheme.label("🎲 %s" % " / ".join(dice.map(func(d): return str(d))), 30, col)
	face.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(face)
	var detail := UITheme.label("+%d = %d vs %d  %s" % [int(r.get("bonus", 0)),
		int(r.get("total", 0)), int(r.get("vs", 0)), outcome], 13, col)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(detail)
	var pan := UITheme.panel(col)
	pan.add_child(v)
	return pan
