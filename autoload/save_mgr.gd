extends Node
## SaveMgr — JSON snapshots at user://saves/. Host-only. The world itself is
## never serialized: seed + edit logs regenerate it exactly (see VoxelWorld).

const SAVE_DIR := "user://saves"
const SLOT := "user://saves/slot1.json"
const CHARACTER := "user://saves/character.json"

var _char_dirty := {}
var _char_accum := 0.0


func _process(delta: float) -> void:
	# Throttled character autosave (queued by Game on every self-sync).
	if _char_dirty.is_empty():
		return
	_char_accum += delta
	if _char_accum >= 20.0:
		_char_accum = 0.0
		save_character(_char_dirty)
		_char_dirty = {}


## Your character travels with YOU, not the host's world: saved locally,
## carried into any lobby you join (drop-in / drop-out progression).
func save_character(rec: Dictionary) -> void:
	if rec.is_empty() or not rec.has("level"):
		return
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var snap := rec.duplicate(true)
	snap.erase("pid")
	snap.erase("in_enc")
	snap["buffs"] = []
	var f := FileAccess.open(CHARACTER, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(snap))
		f.close()


func queue_character(rec: Dictionary) -> void:
	_char_dirty = rec


func flush_character() -> void:
	if not _char_dirty.is_empty():
		save_character(_char_dirty)
		_char_dirty = {}


func load_character() -> Dictionary:
	if not FileAccess.file_exists(CHARACTER):
		return {}
	var f := FileAccess.open(CHARACTER, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func has_save() -> bool:
	return FileAccess.file_exists(SLOT)


func save_snapshot(snap: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	snap["version"] = 1
	snap["when"] = Time.get_datetime_string_from_system()
	var f := FileAccess.open(SLOT, FileAccess.WRITE)
	if f == null:
		push_warning("SaveMgr: cannot write %s" % SLOT)
		return
	f.store_string(JSON.stringify(snap))
	f.close()
	Events.notify.emit("Game saved.")


func load_latest() -> Dictionary:
	if not has_save():
		return {}
	var f := FileAccess.open(SLOT, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
