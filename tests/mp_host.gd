extends Node
## Multiplayer smoke test — HOST half. Hosts a LAN lobby, starts the run once
## a client joins, verifies both players spawn, then holds the session open
## for the client's checks. Run alongside mp_client.tscn (see tests/run_mp.ps1).

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  host ok: %s" % what)
	else:
		_fails += 1
		printerr("  HOST FAIL: %s" % what)


func _ready() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[mp_host] hosting LAN")
	_check(Net.host_lan(), "LAN server opened")
	main.show_lobby()
	# Wait up to 30s for the client.
	var waited := 0.0
	while Game.lobby.size() < 2 and waited < 30.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(Game.lobby.size() == 2, "client joined the lobby")
	print("[mp_host] starting run")
	Game.request_start_run()
	# Barrier: both peers must report floor-ready before anyone spawns.
	waited = 0.0
	while waited < 40.0:
		if Game.world != null and Game.world.players_node.get_child_count() == 2:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(Game.world != null and Game.world.players_node.get_child_count() == 2,
		"both players spawned in the world")
	# Hold the table open while the client runs its checks, then report.
	await get_tree().create_timer(12.0).timeout
	if _fails == 0:
		print("MP HOST PASS")
		get_tree().quit(0)
	else:
		printerr("MP HOST FAIL (%d)" % _fails)
		get_tree().quit(1)
