class_name SkillsUI
extends Control
## Character disciplines panel (K). Shows each use-leveled skill with its XP
## progress and lets you spend earned skill points (+2 effective levels each).

var main
var _rows: VBoxContainer
var _points: Label


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(560, 0)
	root.add_child(UITheme.title("Disciplines", 24))
	root.add_child(UITheme.label("Skills grow as you use them. Level-ups grant points — spend them here.", 12, UITheme.DIM))
	_points = UITheme.label("", 16, UITheme.GOLD)
	root.add_child(_points)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	var pan := UITheme.panel(UITheme.NEON)
	pan.add_child(_rows)
	root.add_child(pan)

	var close := UITheme.button("Close (K)", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))
	Events.my_record_changed.connect(refresh)


func refresh() -> void:
	if not is_inside_tree():
		return
	var rec := Game.my_rec()
	if rec.is_empty():
		return
	var points := int(rec.get("skill_points", 0))
	_points.text = "Skill points: %d" % points
	for c in _rows.get_children():
		c.queue_free()
	var prof: Dictionary = rec.get("prof", {})
	for skill in Db.PROFS:
		var p: Dictionary = prof.get(skill, {"xp": 0, "lvl": 1})
		var alloc := int(rec.get("alloc", {}).get(skill, 0))
		var eff := Db.prof_eff(rec, skill)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var nm := UITheme.label(skill.capitalize(), 16)
		nm.custom_minimum_size = Vector2(120, 0)
		row.add_child(nm)
		var lvl := UITheme.label("lv %d%s" % [eff, " (+%d pts)" % alloc if alloc > 0 else ""], 14, UITheme.NEON)
		lvl.custom_minimum_size = Vector2(110, 0)
		row.add_child(lvl)
		row.add_child(UITheme.hbar(int(p.xp), Db.prof_xp_needed(int(p.lvl)), UITheme.GOLD, 160, 12))
		var plus := UITheme.button("+", 14)
		plus.disabled = points <= 0
		var sid: String = skill
		plus.pressed.connect(func(): Game.request_allocate(sid))
		row.add_child(plus)
		_rows.add_child(row)
		# Perk chips: unlocked at 1 / 3 / 5 allocated points.
		var bits: Array = []
		for perk in Db.PERKS.get(skill, []):
			bits.append("%s %s" % ["✦" if alloc >= int(perk.at) else "·",
				perk.name if alloc >= int(perk.at) else "%s (%d pts)" % [perk.name, int(perk.at)]])
		var pl := UITheme.label("   " + "   ".join(bits), 11,
			UITheme.GOLD if alloc > 0 else UITheme.DIM)
		_rows.add_child(pl)
