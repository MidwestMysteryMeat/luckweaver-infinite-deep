class_name CraftUI
extends Control
## One bench UI, three modes: "spell" (rune+card+essence), "brew" (2-3
## ingredients), "merge" (two skills/spells, or mutate one spell for gold).
## Selection is inventory slot indices; the craft itself resolves server-side.

var main
var mode := "spell"
var _picked: Array = []
var _list: VBoxContainer
var _picked_lbl: Label
var _hint: Label


func _init(main_ref, bench_mode: String) -> void:
	main = main_ref
	mode = bench_mode
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var titles := {"spell": "Rune Forge — Spell Making",
		"brew": "Cauldron — Alchemy", "merge": "Skill Forge",
		"cook": "Campfire — Cooking", "smith": "Anvil — Blacksmithing",
		"enchant": "Altar — Enchanting"}
	var hints := {
		"spell": "Pick one RUNE, one SIGIL, one ESSENCE.",
		"brew": "Pick 2-3 ingredients. Shared properties become the potion.",
		"merge": "Pick two skills/spells to merge — or one spell + Mutate (50g).",
		"cook": "Pick 2-3 foods. Everyone near the fire shares the feast — rich meals can grant permanent boosts.",
		"smith": "Forge gear from materials, or pick a weapon/armor and Improve it (3 Gold Dust).",
		"enchant": "Pick one weapon/armor and one essence (×2 needed, 30g).",
	}
	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(560, 0)
	root.add_child(UITheme.title(titles[mode], 24))
	_hint = UITheme.label(hints[mode], 13, UITheme.DIM)
	root.add_child(_hint)

	_list = VBoxContainer.new()
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(540, 320)
	scroll.add_child(_list)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pan := UITheme.panel(UITheme.NEON)
	pan.add_child(scroll)
	root.add_child(pan)

	_picked_lbl = UITheme.label("", 14, UITheme.GOLD)
	root.add_child(_picked_lbl)

	var row := HBoxContainer.new()
	var labels := {"spell": "Forge Spell", "brew": "Brew", "merge": "Merge",
		"cook": "Cook Feast", "smith": "Improve Gear (3 dust)", "enchant": "Enchant"}
	var craft := UITheme.button(labels[mode])
	craft.pressed.connect(_do_craft)
	row.add_child(craft)
	if mode == "merge":
		var mut := UITheme.button("Mutate Spell (50g)")
		mut.pressed.connect(_do_mutate)
		row.add_child(mut)
	if mode == "spell":
		var learn := UITheme.button("Learn Class Spell (100g)")
		learn.pressed.connect(func(): Game.request_craft("learn_spell", {}))
		row.add_child(learn)
	var close := UITheme.button("Close", 14)
	close.pressed.connect(func(): main.close_top_ui())
	row.add_child(close)
	root.add_child(row)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))
	Events.my_record_changed.connect(refresh)


func _wanted_kinds() -> Array:
	match mode:
		"spell":
			return ["rune", "card", "essence"]
		"brew", "cook":
			return ["ingredient"]
		"smith", "enchant":
			return ["weapon", "armor", "essence"] if mode == "enchant" else ["weapon", "armor"]
		_:
			return ["skill", "spell"]


func refresh() -> void:
	if not is_inside_tree():
		return
	for c in _list.get_children():
		c.queue_free()
	# Smithing shows recipes first.
	if mode == "smith":
		var eff := Db.prof_eff(Game.my_rec(), "smithing")
		_list.add_child(UITheme.label("Recipes (Smithing %d):" % eff, 14, UITheme.NEON))
		for r in Db.SMITH_RECIPES:
			var mats: Array = []
			for m in r.mats:
				mats.append("%d %s" % [r.mats[m], Db.item_def(m).name])
			var locked: bool = eff < int(r.lvl)
			var b2 := UITheme.button("⚒ %s — %s%s" % [Db.item_def(r.id).name,
				", ".join(mats), "  (needs lv %d)" % int(r.lvl) if locked else ""], 13)
			b2.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b2.disabled = locked
			var rid: String = r.id
			b2.pressed.connect(func(): Game.request_craft("smith", {"recipe": rid}))
			_list.add_child(b2)
		_list.add_child(UITheme.label("Your gear (pick one, then Improve):", 14, UITheme.NEON))
	var inv: Array = Game.my_rec().get("inv", [])
	var kinds := _wanted_kinds()
	for i in range(inv.size()):
		var e = inv[i]
		if e == null:
			continue
		var def := Db.item_def(e.id)
		if not (def.kind in kinds):
			continue
		var tag: String = "▶ " if i in _picked else "   "
		var b := UITheme.button("%s%s  (%s) ×%d" % [tag, Db.item_name(e), def.kind, e.count], 14)
		b.add_theme_color_override("font_color", Db.item_color(e))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := i
		b.pressed.connect(func(): _toggle(idx))
		_list.add_child(b)
	_picked_lbl.text = "Selected: %d" % _picked.size()


func _toggle(i: int) -> void:
	if i in _picked:
		_picked.erase(i)
	else:
		_picked.append(i)
	var caps := {"merge": 2, "enchant": 2, "smith": 1}
	var cap: int = caps.get(mode, 3)
	while _picked.size() > cap:
		_picked.pop_front()
	refresh()


func _do_craft() -> void:
	var inv: Array = Game.my_rec().get("inv", [])
	match mode:
		"spell":
			var rune := -1
			var card := -1
			var ess := -1
			for i in _picked:
				match Db.item_def(inv[i].id).kind:
					"rune": rune = i
					"card": card = i
					"essence": ess = i
			if rune < 0 or card < 0 or ess < 0:
				_hint.text = "Need one rune, one card, one essence."
				return
			Game.request_craft("spell", {"rune": rune, "card": card, "essence": ess})
		"brew", "cook":
			if _picked.size() < 2:
				_hint.text = "Need at least two ingredients."
				return
			Game.request_craft(mode, {"slots": _picked.duplicate()})
		"merge":
			if _picked.size() != 2:
				_hint.text = "Pick exactly two."
				return
			Game.request_craft("merge", {"a": _picked[0], "b": _picked[1]})
		"smith":
			if _picked.size() != 1:
				_hint.text = "Pick one piece of gear to improve (recipes forge directly)."
				return
			Game.request_craft("improve", {"slot": _picked[0]})
		"enchant":
			if _picked.size() != 2:
				_hint.text = "Pick one gear piece and one essence."
				return
			var gear := -1
			var ess := -1
			for i in _picked:
				var k: String = Db.item_def(inv[i].id).kind
				if k in ["weapon", "armor"]:
					gear = i
				elif k == "essence":
					ess = i
			if gear < 0 or ess < 0:
				_hint.text = "Need one gear piece and one essence."
				return
			Game.request_craft("enchant", {"gear": gear, "essence": ess})
	_picked = []
	refresh()


func _do_mutate() -> void:
	if _picked.size() != 1:
		_hint.text = "Pick exactly one spell to mutate."
		return
	Game.request_craft("mutate", {"slot": _picked[0]})
	_picked = []
	refresh()
