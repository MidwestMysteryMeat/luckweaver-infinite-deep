class_name NpcUI
extends Control
## Minecraft-simple villager window: their wares as buy buttons, one quest
## button, done. No dialogue trees — toasts carry the flavor.

var main
var eid := 0


func _init(main_ref, enemy_id: int) -> void:
	main = main_ref
	eid = enemy_id
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var node = Game.world.get_enemy(eid) if Game.world != null else null
	var ename: String = node.display_name if node != null else "Villager"
	var etype: String = node.type if node != null else "villager"

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(340, 0)
	root.add_child(UITheme.title(ename, 20))
	var rep := int(Game.my_rec().get("rep", 0))
	if rep > 0:
		root.add_child(UITheme.label("Reputation %d — %d%% off" % [rep, mini(rep * 5, 25)], 12, UITheme.NEON))

	var trades: Array = Db.ENEMIES.get(etype, {}).get("trades", [])
	for i in range(trades.size()):
		var id: String = trades[i]
		var price := int(Db.item_def(id).value * 1.2 * (1.0 - minf(rep * 0.05, 0.25)))
		var b := UITheme.button("%s — %d g" % [Db.item_def(id).name, price], 14)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := i
		b.pressed.connect(func(): Game.request_npc_trade(eid, idx))
		root.add_child(b)

	var qb := UITheme.button("📜 Quest", 14)
	qb.pressed.connect(func(): Game.request_npc_quest(eid))
	root.add_child(qb)
	var close := UITheme.button("Close", 14)
	close.pressed.connect(func(): main.close_top_ui())
	root.add_child(close)

	var pan := UITheme.panel()
	pan.add_child(root)
	add_child(UITheme.center_wrap(pan))
