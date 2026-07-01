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

	# Server-validated edit, replicated back to us.
	var p = Game.world.get_player(me)
	var bp := Vector3i(int(p.global_position.x), 2, int(p.global_position.z))
	var before: int = Game.voxel.get_block_v(bp)
	_check(before != Blocks.AIR, "solid block under my spawn")
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
