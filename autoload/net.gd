extends Node
## Net — creates/joins sessions over three transports behind one interface:
## Steam (SteamMultiplayerPeer + Steam lobby), ENet (LAN), Offline (solo).
## Gameplay code never cares which is active; it talks to Game's RPCs.

const PORT := 24545
const MAX_PLAYERS := 4

enum Mode { NONE, OFFLINE, ENET, STEAM }

var mode: int = Mode.NONE
var lobby_id: int = 0
var _steam_connected := false


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func active() -> bool:
	return mode != Mode.NONE


# ---------------------------------------------------------------- hosting

func start_solo() -> void:
	leave()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE
	Game.host_started()


func host_lan() -> bool:
	leave()
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, MAX_PLAYERS - 1) != OK:
		Events.net_error.emit("Could not open port %d." % PORT)
		return false
	multiplayer.multiplayer_peer = peer
	mode = Mode.ENET
	Game.host_started()
	return true


func host_steam() -> bool:
	if not SteamMgr.enabled:
		Events.net_error.emit("Steam is not available.")
		return false
	leave()
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		Events.net_error.emit("GodotSteam MultiplayerPeer addon missing (see README).")
		return false
	var peer: MultiplayerPeer = ClassDB.instantiate("SteamMultiplayerPeer")
	if peer.call("create_host", 0) != OK:
		Events.net_error.emit("Steam host failed.")
		return false
	multiplayer.multiplayer_peer = peer
	mode = Mode.STEAM
	_hook_steam_signals()
	# Public lobby so friends can find it; metadata marks it as ours.
	SteamMgr.steam.call("createLobby", 2, MAX_PLAYERS)
	Game.host_started()
	return true


# ---------------------------------------------------------------- joining

func join_lan(ip: String) -> bool:
	leave()
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(ip, PORT) != OK:
		Events.net_error.emit("Could not connect to %s." % ip)
		return false
	multiplayer.multiplayer_peer = peer
	mode = Mode.ENET
	return true


func join_steam(target_lobby: int) -> bool:
	if not SteamMgr.enabled:
		Events.net_error.emit("Steam is not available.")
		return false
	leave()
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		Events.net_error.emit("GodotSteam MultiplayerPeer addon missing (see README).")
		return false
	mode = Mode.STEAM
	_hook_steam_signals()
	SteamMgr.steam.call("joinLobby", target_lobby)
	return true


## Async lobby search; result arrives on the Steam "lobby_match_list" signal
## (hooked in _hook_steam_signals, forwarded via Events).
func request_lobby_list() -> void:
	if not SteamMgr.enabled:
		return
	_hook_steam_signals()
	SteamMgr.steam.call("addRequestLobbyListDistanceFilter", 3)  # worldwide
	SteamMgr.steam.call("requestLobbyList")


# ---------------------------------------------------------------- steam callbacks

func _hook_steam_signals() -> void:
	if _steam_connected or not SteamMgr.enabled:
		return
	_steam_connected = true
	var s: Object = SteamMgr.steam
	if s.has_signal("lobby_created"):
		s.connect("lobby_created", _on_lobby_created)
	if s.has_signal("lobby_joined"):
		s.connect("lobby_joined", _on_lobby_joined)
	if s.has_signal("lobby_match_list"):
		s.connect("lobby_match_list", _on_lobby_match_list)


func _on_lobby_created(result: int, new_lobby_id: int) -> void:
	if result != 1:
		Events.net_error.emit("Steam lobby creation failed.")
		return
	lobby_id = new_lobby_id
	SteamMgr.steam.call("setLobbyData", lobby_id, "game", "luck_and_loot")
	SteamMgr.steam.call("setLobbyData", lobby_id, "host", SteamMgr.persona)
	SteamMgr.steam.call("setLobbyJoinable", lobby_id, true)
	Events.notify.emit("Steam lobby up — ID %d" % lobby_id)


func _on_lobby_joined(joined_lobby: int, _perms: int, _locked: bool, response: int) -> void:
	if response != 1:
		Events.net_error.emit("Could not join Steam lobby (code %d)." % response)
		mode = Mode.NONE
		return
	lobby_id = joined_lobby
	var owner_id: int = SteamMgr.steam.call("getLobbyOwner", joined_lobby)
	if owner_id == SteamMgr.steam_id:
		return  # we created this lobby — we are the host
	var peer: MultiplayerPeer = ClassDB.instantiate("SteamMultiplayerPeer")
	if peer.call("create_client", owner_id, 0) != OK:
		Events.net_error.emit("Steam connect failed.")
		return
	multiplayer.multiplayer_peer = peer


func _on_lobby_match_list(lobbies: Array) -> void:
	var ours: Array = []
	for lid in lobbies:
		if str(SteamMgr.steam.call("getLobbyData", lid, "game")) == "luck_and_loot":
			ours.append({"id": lid, "host": str(SteamMgr.steam.call("getLobbyData", lid, "host"))})
	Game.lobby_list = ours
	Events.lobby_changed.emit()


# ---------------------------------------------------------------- lifecycle

func leave() -> void:
	if mode == Mode.STEAM and lobby_id != 0 and SteamMgr.enabled:
		SteamMgr.steam.call("leaveLobby", lobby_id)
	lobby_id = 0
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.NONE


func _on_connected_ok() -> void:
	Game.client_connected()


func _on_connection_failed() -> void:
	mode = Mode.NONE
	Events.net_error.emit("Connection failed.")


func _on_server_disconnected() -> void:
	mode = Mode.NONE
	if Game.players.has(multiplayer.get_unique_id()):
		SaveMgr.save_character(Game.players[multiplayer.get_unique_id()])
	Game.reset_session()
	Events.net_error.emit("Host disconnected.")
	Events.left_game.emit()
