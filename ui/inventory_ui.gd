class_name InventoryUI
extends Control
## Minecraft-style inventory: character panel up top (stats + what you're
## effectively wearing/wielding), a 2×9 storage grid, and the 9-slot hotbar
## as its own separated row. Click one slot, then another, to swap.

const SLOT := Vector2(58, 58)

var main
var _char: Label
var _grid: GridContainer
var _hotbar_grid: GridContainer
var _info: Label
var _pending := -1


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)

	# Character panel.
	var cpan := PanelContainer.new()
	var cstyle := StyleBoxFlat.new()
	cstyle.bg_color = Color(0.13, 0.13, 0.15)
	cstyle.border_color = Color(0.35, 0.35, 0.4)
	cstyle.set_border_width_all(2)
	cstyle.set_content_margin_all(10)
	cpan.add_theme_stylebox_override("panel", cstyle)
	_char = UITheme.label("", 14)
	cpan.add_child(_char)
	root.add_child(cpan)

	_grid = _make_grid()
	root.add_child(_grid)
	root.add_child(UITheme.label(" ", 4))  # gap, Minecraft-style
	_hotbar_grid = _make_grid()
	root.add_child(_hotbar_grid)

	_info = UITheme.label("", 13, UITheme.NEON)
	_info.custom_minimum_size = Vector2(560, 36)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	root.add_child(_info)

	var pan := PanelContainer.new()
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.2, 0.2, 0.22)
	pstyle.border_color = Color(0.08, 0.08, 0.09)
	pstyle.set_border_width_all(3)
	pstyle.set_content_margin_all(12)
	pan.add_theme_stylebox_override("panel", pstyle)
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))
	Events.my_record_changed.connect(refresh)


func _make_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 9
	g.add_theme_constant_override("h_separation", 4)
	g.add_theme_constant_override("v_separation", 4)
	return g


func refresh() -> void:
	if not is_inside_tree():
		return
	var rec := Game.my_rec()
	if rec.is_empty():
		return
	# Character summary: stats + effective loadout.
	var w: Dictionary = Game.weapon_of(rec)
	var armor: Dictionary = Game.armor_of(rec)
	var wname: String = w.def.name if not w.is_empty() else "Fists"
	_char.text = "%s   ♥ %d/%d   ✦ %d/%d mana   ⚔ +%d (%s)   🛡 AC %d   ☘ %d luck\nWielding: %s   Armor: +%d" % [
		Db.CLASSES[rec.class_id].name, rec.hp, rec.max_hp,
		int(rec.get("mana", 0)), int(rec.get("max_mana", 40)),
		Game.atk_bonus_of(rec, w), wname, Game.player_ac(rec), Game.eff_luck(rec),
		wname, int(armor.ac)]
	for c in _grid.get_children():
		c.queue_free()
	for c in _hotbar_grid.get_children():
		c.queue_free()
	var inv: Array = rec.get("inv", [])
	for i in range(9, inv.size()):
		_grid.add_child(_slot(inv, i))
	for i in range(9):
		_hotbar_grid.add_child(_slot(inv, i))


func _slot(inv: Array, i: int) -> Button:
	var e = inv[i] if i < inv.size() else null
	var b := Button.new()
	b.custom_minimum_size = SLOT
	b.clip_text = true
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.28, 0.28, 0.3)
	sb.border_color = Color(0.12, 0.12, 0.13) if i != _pending else Color(1, 0.85, 0.3)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(2)
	b.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate()
	sbh.bg_color = Color(0.36, 0.36, 0.4)
	b.add_theme_stylebox_override("hover", sbh)
	b.add_theme_stylebox_override("pressed", sbh)
	b.add_theme_font_size_override("font_size", 10)
	if e != null:
		b.text = "%s%s" % [Db.item_name(e), "\n×%d" % int(e.count) if int(e.count) > 1 else ""]
		b.add_theme_color_override("font_color", Db.item_color(e))
	var idx := i
	b.pressed.connect(func(): _click(idx))
	b.mouse_entered.connect(func(): _hover(idx))
	return b


func _click(i: int) -> void:
	if _pending < 0:
		_pending = i
	else:
		if _pending != i:
			Game.request_swap(_pending, i)
		_pending = -1
	refresh()


func _hover(i: int) -> void:
	var inv: Array = Game.my_rec().get("inv", [])
	var e = inv[i] if i < inv.size() else null
	if e == null:
		_info.text = ""
		return
	var def := Db.item_def(e.id)
	var meta: Dictionary = e.get("meta", {})
	var bits: Array = [Db.item_name(e), def.kind]
	if meta.has("rarity"):
		bits.append(Db.RARITY_NAMES[int(meta.rarity)])
	if def.kind == "spell" or e.id == "spell":
		bits.append("cast: %d mana" % (6 + int(meta.get("power", 1)) * 4))
	if meta.has("effects"):
		for fx in meta.effects:
			bits.append("%s %d" % [fx.prop, fx.potency])
	if meta.has("passives"):
		for k in meta.passives:
			bits.append("%s %.2f" % [k, float(meta.passives[k])])
	if def.kind == "ingredient":
		bits.append("props: %s" % ", ".join(def.props))
	_info.text = "  •  ".join(bits.map(func(x): return str(x)))
