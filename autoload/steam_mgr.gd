extends Node
## SteamMgr — optional Steam layer. The GodotSteam GDExtension is accessed
## dynamically (Engine.get_singleton + call()) so the project parses and runs
## without the addon installed; Net falls back to ENet/offline in that case.

const APP_ID := 480  # Spacewar dev id — replace with your App ID for release.

var steam: Object = null
var enabled := false
var steam_id: int = 0
var persona := ""


func _ready() -> void:
	if not Engine.has_singleton("Steam"):
		print("[SteamMgr] GodotSteam not installed — LAN/solo only.")
		return
	steam = Engine.get_singleton("Steam")
	var init: Variant = steam.call("steamInitEx", true, APP_ID)
	if typeof(init) == TYPE_DICTIONARY and int(init.get("status", 1)) != 0:
		print("[SteamMgr] Steam init failed: %s" % [init])
		steam = null
		return
	enabled = true
	steam_id = steam.call("getSteamID")
	persona = str(steam.call("getPersonaName"))
	print("[SteamMgr] Steam online as %s (%d)" % [persona, steam_id])


func _process(_delta: float) -> void:
	if enabled:
		steam.call("run_callbacks")


func player_name() -> String:
	if enabled and persona != "":
		return persona
	return "Luckweaver_%d" % (randi() % 1000)
