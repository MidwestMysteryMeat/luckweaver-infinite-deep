extends Node
## Multiplayer smoke test — CLIENT half. Joins the host, waits for the run,
## then proves the co-op contract: both player records present, both player
## nodes visible, a client-requested voxel edit validated by the server and
## replicated back, and chat relayed.

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  client ok: %s" % what)
	else:
		_fails += 1
		printerr("  CLIENT FAIL: %s" % what)


func _ready() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[mp_client] joining 127.0.0.1")
	_check(Net.join_lan("127.0.0.1"), "connect initiated")
	main.show_lobby()
	await Events.run_started
	print("[mp_client] run started, waiting for spawn")
	var waited := 0.0
	var me := multiplayer.get_unique_id()
	while waited < 40.0:
		if Game.world != null and Game.world.get_player(me) != null \
				and Game.world.players_node.get_child_count() == 2:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(Game.world != null and Game.world.get_player(me) != null, "my player spawned")
	_check(Game.world.players_node.get_child_count() == 2, "I can see the host's player")
	_check(Game.players.size() == 2, "both player records synced")

	# Server-validated edit, replicated back to us. Biome terrain slopes and
	# floods, so probe around the spawn point for a solid, breakable block
	# with a placeable drop instead of assuming the block underfoot is one.
	var p = Game.world.get_player(me)
	var px := int(p.global_position.x)
	var py := int(p.global_position.y)
	var pz := int(p.global_position.z)
	var bp := Vector3i(px, py - 1, pz)
	var found_ground := false
	for dxz: Array in [[0, 0], [1, 0], [0, 1], [-1, 0], [0, -1], [2, 0], [0, 2], [2, 2]]:
		for dy: int in [-1, -2, -3, 0]:
			var cand := Vector3i(px + int(dxz[0]), py + dy, pz + int(dxz[1]))
			var cid: int = Game.voxel.get_block_v(cand)
			if cid == Blocks.AIR or not Blocks.is_breakable(cid):
				continue
			var cdrop := String(Blocks.get_def(cid).get("drop", ""))
			if cdrop != "" and String(Db.item_def(cdrop).get("kind", "")) == "block":
				bp = cand
				found_ground = true
				break
		if found_ground:
			break
	_check(found_ground, "solid block near my spawn")
	Game.request_break(bp)
	await get_tree().create_timer(1.5).timeout
	_check(Game.voxel.get_block_v(bp) == Blocks.AIR, "my edit validated by host and replicated back")
	_check(_count_item_in(Game.my_rec()) > 0, "mining drop landed in my server-side inventory")

	# Chat relay.
	Events.chat_line.connect(_on_chat)
	Game.request_chat("gl hf")
	await get_tree().create_timer(1.0).timeout
	_check(_chat_seen, "chat relayed through host")

	if _fails == 0:
		print("MP CLIENT PASS")
		get_tree().quit(0)
	else:
		printerr("MP CLIENT FAIL (%d)" % _fails)
		get_tree().quit(1)


var _chat_seen := false


func _on_chat(_who: String, text: String) -> void:
	if text == "gl hf":
		_chat_seen = true


func _count_item_in(rec: Dictionary) -> int:
	var n := 0
	for e in rec.get("inv", []):
		if e != null and Db.item_def(e.id).kind == "block":
			n += e.count
	return n
