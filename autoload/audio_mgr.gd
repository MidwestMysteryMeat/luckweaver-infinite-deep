extends Node
## AudioMgr — music, biome ambience, and SFX. Purely client-side: it reacts to
## the same replicated events/state everything else renders from.
## Curated files live in res://audio_game/ (picked from the audio/ packs —
## swap any .wav to re-skin a sound).

const DIR := "res://audio_game/"

var _music: AudioStreamPlayer
var _amb: AudioStreamPlayer
var _pool: Array = []
var _pi := 0
var _streams := {}
var _music_key := ""
var _amb_key := ""
var _hurt_at := 0
var _last_hp := -1


func _ready() -> void:
	_music = AudioStreamPlayer.new()
	_music.volume_db = -10.0
	_music.finished.connect(func(): _music.play())
	add_child(_music)
	_amb = AudioStreamPlayer.new()
	_amb.volume_db = -14.0
	_amb.finished.connect(func(): _amb.play())
	add_child(_amb)
	for i in range(6):
		var p := AudioStreamPlayer.new()
		p.volume_db = -6.0
		add_child(p)
		_pool.append(p)
	apply_settings()
	Events.floor_loaded.connect(_on_floor)
	Events.notify.connect(_on_notify)
	Events.my_record_changed.connect(_on_record)
	Events.left_game.connect(func():
		_music.stop()
		_amb.stop()
		_music_key = ""
		_amb_key = "")


var _sfx_offset := 0.0


func apply_settings() -> void:
	_music.volume_db = -18.0 + float(SaveMgr.settings.vol_music)
	_amb.volume_db = -20.0 + float(SaveMgr.settings.vol_music)
	_sfx_offset = float(SaveMgr.settings.vol_sfx)


func _load(key: String) -> AudioStream:
	if not _streams.has(key):
		var path := DIR + key + ".wav"
		_streams[key] = load(path) if ResourceLoader.exists(path) else null
	return _streams[key]


func sfx(key: String, vol := -6.0) -> void:
	var s := _load(key)
	if s == null:
		return
	var p: AudioStreamPlayer = _pool[_pi]
	_pi = (_pi + 1) % _pool.size()
	p.stream = s
	p.volume_db = vol + _sfx_offset
	p.play()


## Positional one-shot in the world; frees itself when done.
func sfx3d(key: String, pos: Vector3, vol := 0.0) -> void:
	var s := _load(key)
	if s == null or Game.world == null:
		sfx(key)
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.volume_db = vol + _sfx_offset
	p.max_distance = 30.0
	Game.world.add_child(p)
	p.global_position = pos
	p.play()
	p.finished.connect(p.queue_free)


func play_music(key: String) -> void:
	if key == _music_key:
		return
	_music_key = key
	_music.stream = _load(key)
	if _music.stream != null:
		_music.play()


func play_amb(key: String) -> void:
	if key == _amb_key:
		return
	_amb_key = key
	_amb.stream = _load(key)
	if _amb.stream != null:
		_amb.play()


func _on_floor(fnum: int) -> void:
	if fnum == 0:
		play_music("music_town")
		play_amb("amb_delve")
		return
	# Rotate tracks by depth so the loop doesn't wear a groove.
	var track := "music_boss" if fnum % 5 == 0 else \
		("music_deep" if fnum % 2 == 0 else "music_town")
	play_music(track)
	var amb_map := {"delve": "amb_delve", "caverns": "amb_caverns",
		"lakes": "amb_lakes", "molten": "amb_molten", "fungal": "amb_caverns",
		"crypt": "amb_delve", "frozen": "amb_caverns"}
	play_amb(amb_map.get(String(Game.gen_info.get("biome", "delve")), "amb_delve"))


## Light keyword routing for one-line feedback sounds.
func _on_notify(text: String) -> void:
	if text.begins_with("Level "):
		sfx("sfx_levelup", -4.0)
	elif "gold" in text:
		sfx("sfx_coin", -8.0)
	elif "cast your line" in text:
		sfx("sfx_splash")
	elif "forged" in text.to_lower() or "Brewed" in text or "Enchanted" in text or "serves" in text:
		sfx("sfx_magic", -8.0)


func _on_record() -> void:
	var hp := int(Game.my_rec().get("hp", -1))
	if _last_hp > 0 and hp < _last_hp and Time.get_ticks_msec() - _hurt_at > 350:
		_hurt_at = Time.get_ticks_msec()
		sfx("sfx_hurt", -4.0)
	_last_hp = hp
