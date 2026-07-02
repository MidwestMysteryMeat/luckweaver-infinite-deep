class_name ShopUI
extends Control
## The House Counter: buy from deterministic per-floor stock, sell anything
## at half value. All transactions validated server-side.

var main
var _buy_list: VBoxContainer
var _sell_list: VBoxContainer
var _gold: Label


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(680, 0)
	root.add_child(UITheme.title("The House Counter", 24))
	_gold = UITheme.label("", 16, UITheme.GOLD)
	root.add_child(_gold)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)

	var left := VBoxContainer.new()
	left.add_child(UITheme.label("For sale", 16, UITheme.NEON))
	_buy_list = VBoxContainer.new()
	var lpan := UITheme.panel(UITheme.NEON)
	lpan.add_child(_buy_list)
	left.add_child(lpan)
	cols.add_child(left)

	var right := VBoxContainer.new()
	right.add_child(UITheme.label("Sell (half value)", 16, UITheme.RED))
	_sell_list = VBoxContainer.new()
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(300, 340)
	scroll.add_child(_sell_list)
	var rpan := UITheme.panel(UITheme.RED)
	rpan.add_child(scroll)
	right.add_child(rpan)
	cols.add_child(right)

	root.add_child(cols)
	var close := UITheme.button("Close", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))
	Events.my_record_changed.connect(refresh)


func refresh() -> void:
	if not is_inside_tree():
		return
	_gold.text = "Your purse: ◉ %d" % Game.my_rec().get("gold", 0)
	for c in _buy_list.get_children():
		c.queue_free()
	var p0 = main.local_player()
	var stock: Array = Db.shop_stock(Game.run_seed,
		Db.band_at(p0.global_position.y) if p0 != null else 0)
	for i in range(stock.size()):
		var offer: Dictionary = stock[i]
		var b := UITheme.button("%s — %d g" % [Db.item_def(offer.id).name, offer.price], 14)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := i
		b.pressed.connect(func(): Game.request_shop("buy", idx))
		_buy_list.add_child(b)
	for c in _sell_list.get_children():
		c.queue_free()
	var inv: Array = Game.my_rec().get("inv", [])
	for i in range(inv.size()):
		var e = inv[i]
		if e == null:
			continue
		var v: int = maxi(1, int(Db.item_def(e.id).value / 2)) * int(e.count)
		var b := UITheme.button("%s ×%d — %d g" % [Db.item_name(e), e.count, v], 13)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", Db.item_color(e))
		var idx := i
		b.pressed.connect(func(): Game.request_shop("sell", idx))
		_sell_list.add_child(b)
