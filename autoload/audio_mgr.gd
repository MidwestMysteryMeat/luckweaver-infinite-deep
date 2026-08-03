# NOTE: the audio files under audio_game/ are NOT in the repo — owner-licensed
# packs stripped from version control (see audio_game/ASSETS_PLACEHOLDER.md).
# All loads below must tolerate missing files (fresh clones run silent).
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


var _depth_accum := 0.0


func _process(delta: float) -> void:
	_check_depth(delta)


func _on_floor(_fnum: int) -> void:
	play_music("music_town")
	play_amb("amb_delve")


## Seamless world: music and ambience track how deep you actually are.
func _check_depth(delta: float) -> void:
	_depth_accum += delta
	if _depth_accum < 3.0 or not Game.in_run or Game.world == null:
		return
	_depth_accum = 0.0
	var p = Game.world.get_player(Game.my_id())
	if p == null:
		return
	var band := Db.band_at(p.global_position.y)
	var amb := ""
	if band == 0:
		play_music("music_town")
		amb = "amb_delve"
	elif band <= 2:
		play_music("music_deep")
		amb = "amb_caverns"
	else:
		play_music("music_boss")
		amb = "amb_molten" if band >= 4 else "amb_lakes"

	# A named biome overrides the depth band, but ONLY when it is one we have a
	# track for. This used to call play_amb a second time unconditionally with
	# gen_info.biome, which has only held "spawn" since the infinite-world
	# rewrite — so the lookup always fell back to amb_delve, the depth
	# ambiences never played, and the two calls restarted the stream twice
	# every three seconds.
	var amb_map := {"delve": "amb_delve", "caverns": "amb_caverns",
		"lakes": "amb_lakes", "molten": "amb_molten", "fungal": "amb_caverns",
		"crypt": "amb_delve", "frozen": "amb_caverns"}
	var biome := String(Game.gen_info.get("biome", ""))
	if amb_map.has(biome):
		amb = amb_map[biome]
	play_amb(amb)


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
