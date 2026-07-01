class_name InventoryUI
extends Control
## 27-slot grid (first 9 = hotbar). Click one slot then another to swap
## (server-validated). Hover text comes from item metas.

var main
var _grid: GridContainer
var _info: Label
var _pending := -1  # first slot of a swap


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.add_child(UITheme.title("Satchel", 24))
	root.add_child(UITheme.label("Slots 1-9 are your hotbar. Click two slots to swap.", 12, UITheme.DIM))
	_grid = GridContainer.new()
	_grid.columns = 9
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	root.add_child(_grid)
	_info = UITheme.label("", 13, UITheme.NEON)
	_info.custom_minimum_size = Vector2(620, 40)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	root.add_child(_info)
	var close := UITheme.button("Close (Tab)", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))
	Events.my_record_changed.connect(refresh)


func refresh() -> void:
	if not is_inside_tree():
		return
	for c in _grid.get_children():
		c.free()
	var inv: Array = Game.my_rec().get("inv", [])
	for i in range(inv.size()):
		var e = inv[i]
		var b := UITheme.button("", 12)
		b.custom_minimum_size = Vector2(64, 52)
		if e != null:
			b.text = "%s%s" % [Db.item_name(e), "\n×%d" % e.count if e.count > 1 else ""]
			b.add_theme_color_override("font_color", Db.item_color(e))
		else:
			b.text = "·"
		if i == _pending:
			b.add_theme_color_override("font_color", UITheme.GOLD)
			b.text = "▶ " + b.text
		var idx := i
		b.pressed.connect(func(): _click(idx))
		b.mouse_entered.connect(func(): _hover(idx))
		_grid.add_child(b)


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
	var bits: Array = [Db.item_name(e), "kind: %s" % def.kind]
	if meta.has("rarity"):
		bits.append(Db.RARITY_NAMES[int(meta.rarity)])
	if meta.has("charges"):
		bits.append("%d charges" % int(meta.charges))
	if meta.has("effects"):
		for fx in meta.effects:
			bits.append("%s %d" % [fx.prop, fx.potency])
	if meta.has("passives"):
		for k in meta.passives:
			bits.append("%s %.2f" % [k, float(meta.passives[k])])
	if def.kind == "ingredient":
		bits.append("props: %s" % ", ".join(def.props))
	_info.text = "  •  ".join(bits.map(func(x): return str(x)))
