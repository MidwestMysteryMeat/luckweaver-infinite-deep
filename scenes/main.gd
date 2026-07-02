extends Node
## Main — root of the only scene. Orchestrates menu ↔ lobby ↔ world and the
## in-game UI stack (inventory / benches / gambling table / pause). Owns
## mouse-capture state; gameplay lives in the autoloads and LLWorld.

var ui_layer: CanvasLayer
var menu: MainMenuUI
var lobby: LobbyUI
var hud: HUD
var world: LLWorld
var _ui_stack: Array = []  # open modal Controls, top = last
var _combat: CombatUI = null


func _ready() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	Events.run_started.connect(_on_run_started)
	Events.left_game.connect(_on_left_game)
	Events.enc_state.connect(_on_enc_state)
	Events.open_bench.connect(_on_open_bench)
	Events.net_error.connect(_on_net_error)
	show_menu()


func _on_net_error(_msg: String) -> void:
	if not Game.in_run and menu == null:
		show_menu()


# ---------------------------------------------------------------- screens

func _clear_screen() -> void:
	for c in ui_layer.get_children():
		c.free()
	menu = null
	lobby = null
	hud = null
	_ui_stack = []
	_combat = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func show_menu() -> void:
	_clear_screen()
	if world != null:
		world.queue_free()
		world = null
	menu = MainMenuUI.new(self)
	ui_layer.add_child(menu)


func show_lobby() -> void:
	_clear_screen()
	lobby = LobbyUI.new(self)
	ui_layer.add_child(lobby)


func _on_run_started() -> void:
	_clear_screen()
	if world != null:
		world.free()
	world = LLWorld.new()
	add_child(world)  # world._ready registers with Game and loads the floor
	hud = HUD.new(self)
	ui_layer.add_child(hud)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_left_game() -> void:
	show_menu()


func local_player():
	if world == null:
		return null
	return world.get_player(multiplayer.get_unique_id())


func set_player_locked(v: bool) -> void:
	var p = local_player()
	if p != null:
		p.locked = v


# ---------------------------------------------------------------- UI stack

func _open_ui(ctrl: Control) -> void:
	_ui_stack.append(ctrl)
	ui_layer.add_child(ctrl)
	if ctrl.has_method("refresh"):
		ctrl.refresh()
	set_player_locked(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_top_ui() -> void:
	if _ui_stack.is_empty():
		return
	var top: Control = _ui_stack.pop_back()
	if top == _combat:
		_combat = null
	top.queue_free()
	if _ui_stack.is_empty():
		set_player_locked(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func close_combat() -> void:
	if _combat != null and _combat in _ui_stack:
		_ui_stack.erase(_combat)
		_combat.queue_free()
		_combat = null
	if _ui_stack.is_empty():
		set_player_locked(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_enc_state(st: Dictionary) -> void:
	if _combat == null:
		if String(st.phase) == "done":
			return
		_combat = CombatUI.new(self)
		_open_ui(_combat)
	_combat.render(st)


func _on_open_bench(kind: String) -> void:
	if kind == "shop":
		_open_ui(ShopUI.new(self))
	elif kind == "waystone":
		_open_ui(WaystoneUI.new(self))
	else:
		_open_ui(CraftUI.new(self, kind))


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not Game.in_run or hud == null:
		return
	if event.is_action_pressed("pause"):
		if _combat != null:
			return  # can't Esc out of a fight — flee like everyone else
		if not _ui_stack.is_empty():
			close_top_ui()
		elif hud.chat_open():
			pass
		else:
			_open_ui(PauseMenu.new(self))
		return
	if event.is_action_pressed("inv"):
		if _ui_stack.is_empty():
			_open_ui(InventoryUI.new(self))
		elif _ui_stack.size() == 1 and _ui_stack[0] is InventoryUI:
			close_top_ui()
		return
	if event.is_action_pressed("skills"):
		if _ui_stack.is_empty():
			_open_ui(SkillsUI.new(self))
		elif _ui_stack.size() == 1 and _ui_stack[0] is SkillsUI:
			close_top_ui()
		return
	if event.is_action_pressed("map"):
		if _ui_stack.is_empty():
			_open_ui(MapUI.new(self))
		elif _ui_stack.size() == 1 and _ui_stack[0] is MapUI:
			close_top_ui()
		return
	if event.is_action_pressed("chat") and _ui_stack.is_empty() and not hud.chat_open():
		hud.open_chat()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("quicksave") and Game.is_server():
		Game.save_now()
