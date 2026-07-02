class_name VoxelWorld
extends Node3D
## INFINITE voxel world: unbounded X/Z in streamed 16×H×16 columns, generated
## on demand by WorldGen (pure function of seed+column, so every peer's world
## matches bit-for-bit). Mesh/collision exist only for columns near players;
## data persists in memory once generated.
##
## Determinism contract (unchanged from the floor era): ops are JSON-safe
## dicts replayed in log order; apply_op (gravity cascade, fluid_step) is a
## pure function of grid state. Light is derived, local, never synced.

const H := WorldGen.H
const CH := 16
const SECTIONS := H / 16          # vertical mesh sections per column
const STREAM_R := 3               # columns loaded around each player
const LIGHT_REPAIR_R := 14

const PROTECTED := [Blocks.BEDROCK, Blocks.CHEST, Blocks.BENCH_SPELL,
	Blocks.BENCH_ALCH, Blocks.BENCH_SKILL, Blocks.BENCH_SHOP, Blocks.PORTAL,
	Blocks.BENCH_SMITH, Blocks.BENCH_ENCH]

const DIRS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const HORIZ := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

var world_seed := 0
var columns := {}      # Vector2i -> {"data": PBA, "light": PBA, "lit": bool}
var chunks := {}       # Vector3i(cx, sy, cz) -> {"body","mesh","shape"} (streamed-in only)
var dirty := {}        # Vector3i section keys
var built := {}        # Vector3i sections whose collision has been applied ≥ once
var fluid_cells := {}  # Vector3i cell -> true (awake fluid/gas cells)
var _fluid_steps := 0
var _stream_accum := 0.0


func _ready() -> void:
	Blocks.material()
	Blocks.material_translucent()


func _process(delta: float) -> void:
	flush_dirty(10)
	_stream_accum += delta
	if _stream_accum >= 0.4:
		_stream_accum = 0.0
		_stream_tick()


# ---------------------------------------------------------------- columns

static func column_key(x: int, z: int) -> Vector2i:
	return Vector2i(int(floor(float(x) / 16.0)), int(floor(float(z) / 16.0)))


## MAIN THREAD: generates the column if missing. Workers must never gen.
func ensure_column(ck: Vector2i) -> Dictionary:
	var col: Variant = columns.get(ck)
	if col != null:
		return col
	var data := PackedByteArray()
	data.resize(16 * H * 16)
	WorldGen.fill_column(world_seed, ck, data)
	var light := PackedByteArray()
	light.resize(16 * H * 16)
	var c := {"data": data, "light": light, "lit": false}
	columns[ck] = c
	# Wake any generated fluids (lakes settle after one step and sleep).
	var bx := ck.x * 16
	var bz := ck.y * 16
	for i in range(data.size()):
		if Blocks.fluid_kind(data[i]) != "":
			fluid_cells[Vector3i(bx + (i % 16), i / 256, bz + ((i / 16) % 16))] = true
	return c


func get_block(x: int, y: int, z: int) -> int:
	if y < 0 or y >= H:
		return Blocks.AIR
	var ck := column_key(x, z)
	var col: Variant = columns.get(ck)
	if col == null:
		if OS.get_thread_caller_id() != OS.get_main_thread_id():
			return Blocks.AIR  # workers never generate
		col = ensure_column(ck)
	return col.data[(y * 16 + (z - ck.y * 16)) * 16 + (x - ck.x * 16)]


func get_block_v(p: Vector3i) -> int:
	return get_block(p.x, p.y, p.z)


func light_at(x: int, y: int, z: int) -> int:
	if y < 0 or y >= H:
		return 15 if y >= H else 0  # open sky above, void below
	var ck := column_key(x, z)
	var col: Variant = columns.get(ck)
	if col == null:
		return 8  # unloaded: assume dim so meshes at seams aren't black
	return col.light[(y * 16 + (z - ck.y * 16)) * 16 + (x - ck.x * 16)]


func _set_light(x: int, y: int, z: int, v: int) -> void:
	var col: Variant = columns.get(column_key(x, z))
	if col == null or y < 0 or y >= H:
		return
	var ck := column_key(x, z)
	col.light[(y * 16 + (z - ck.y * 16)) * 16 + (x - ck.x * 16)] = v


func set_block(x: int, y: int, z: int, id: int, mark := true) -> void:
	if y < 0 or y >= H:
		return
	var ck := column_key(x, z)
	var col := ensure_column(ck)
	var i := (y * 16 + (z - ck.y * 16)) * 16 + (x - ck.x * 16)
	if col.data[i] == id:
		return
	col.data[i] = id
	var cell := Vector3i(x, y, z)
	if Blocks.fluid_kind(id) != "":
		fluid_cells[cell] = true
	else:
		fluid_cells.erase(cell)
	for d in DIRS:
		var n: Vector3i = cell + d
		if Blocks.fluid_kind(get_block(n.x, n.y, n.z)) != "":
			fluid_cells[n] = true
	if mark:
		_mark_dirty(x, y, z)


func set_block_v(p: Vector3i, id: int, mark := true) -> void:
	set_block(p.x, p.y, p.z, id, mark)


func has_active_fluids() -> bool:
	return not fluid_cells.is_empty()


func _mark_dirty(x: int, y: int, z: int) -> void:
	var sk := Vector3i(int(floor(float(x) / 16.0)), y / 16, int(floor(float(z) / 16.0)))
	dirty[sk] = true
	if posmod(x, 16) == 0: dirty[sk + Vector3i(-1, 0, 0)] = true
	if posmod(x, 16) == 15: dirty[sk + Vector3i(1, 0, 0)] = true
	if y % 16 == 0 and sk.y > 0: dirty[sk + Vector3i(0, -1, 0)] = true
	if y % 16 == 15 and sk.y < SECTIONS - 1: dirty[sk + Vector3i(0, 1, 0)] = true
	if posmod(z, 16) == 0: dirty[sk + Vector3i(0, 0, -1)] = true
	if posmod(z, 16) == 15: dirty[sk + Vector3i(0, 0, 1)] = true


# ---------------------------------------------------------------- streaming

## Called by the streaming tick and by tests: load columns (data, light,
## meshes) around the given world positions; drop far meshes (data stays).
func stream_around(positions: Array) -> void:
	var want := {}
	for pos in positions:
		var pck := column_key(int(pos.x), int(pos.z))
		for dx in range(-STREAM_R, STREAM_R + 1):
			for dz in range(-STREAM_R, STREAM_R + 1):
				want[Vector2i(pck.x + dx, pck.y + dz)] = true
	for ck in want:
		var col := ensure_column(ck)
		if not col.lit:
			_light_column(ck)
			col.lit = true
		if not chunks.has(Vector3i(ck.x, 0, ck.y)):
			for sy in range(SECTIONS):
				var sk := Vector3i(ck.x, sy, ck.y)
				var body := StaticBody3D.new()
				body.name = "C_%d_%d_%d" % [ck.x, sy, ck.y]
				body.position = Vector3(ck.x * 16, sy * 16, ck.y * 16)
				body.add_to_group("voxel")
				var mi := MeshInstance3D.new()
				body.add_child(mi)
				var cs := CollisionShape3D.new()
				body.add_child(cs)
				add_child(body)
				chunks[sk] = {"body": body, "mesh": mi, "shape": cs}
				dirty[sk] = true
	# Unload far meshes.
	for sk in chunks.keys():
		var ck2 := Vector2i(sk.x, sk.z)
		var near := false
		for pos in positions:
			var pck2 := column_key(int(pos.x), int(pos.z))
			if absi(ck2.x - pck2.x) <= STREAM_R + 2 and absi(ck2.y - pck2.y) <= STREAM_R + 2:
				near = true
				break
		if not near:
			chunks[sk].body.queue_free()
			chunks.erase(sk)
			dirty.erase(sk)
			built.erase(sk)


func _stream_tick() -> void:
	var positions := []
	var players := get_node_or_null("../Players")
	if players != null:
		for p in players.get_children():
			positions.append(p.global_position)
	if positions.is_empty():
		positions.append(Vector3(0, WorldGen.SURFACE, 0))
	stream_around(positions)


func flush_dirty(budget: int) -> void:
	if dirty.is_empty():
		return
	var batch: Array = []
	for sk in dirty.keys():
		if batch.size() >= budget:
			break
		dirty.erase(sk)
		if chunks.has(sk):
			batch.append(sk)
	if batch.is_empty():
		return
	# Pre-ensure neighbor columns on the main thread so workers never generate.
	for sk in batch:
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				ensure_column(Vector2i(sk.x + dx, sk.z + dz))
	if batch.size() == 1:
		_apply_built(batch[0], Mesher.build(self, batch[0] * CH, CH))
		return
	var results := []
	results.resize(batch.size())
	var task := WorkerThreadPool.add_group_task(func(i):
		results[i] = Mesher.build(self, batch[i] * CH, CH), batch.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(task)
	for i in range(batch.size()):
		if chunks.has(batch[i]):
			_apply_built(batch[i], results[i])


func flush_all() -> void:
	while not dirty.is_empty():
		flush_dirty(9999)


## MAIN THREAD ONLY: worker-built arrays → mesh + collision.
func _apply_built(sk: Vector3i, b: Dictionary) -> void:
	var ch: Dictionary = chunks[sk]
	ch.mesh.mesh = Mesher.make_mesh(b)
	if b.faces.size() > 0:
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(b.faces)
		ch.shape.shape = shape
	else:
		ch.shape.shape = null
	built[sk] = true


## Is the terrain under a world position solid ground to simulate on? False
## while the column is still generating/meshing — players freeze in place for
## a beat instead of falling through the not-yet-collidable world.
func ready_at(pos: Vector3) -> bool:
	var ck := column_key(int(floor(pos.x)), int(floor(pos.z)))
	if not columns.has(ck):
		return false
	var sy := clampi(int(pos.y) / 16, 0, SECTIONS - 1)
	# The player's own section AND the one below (ground near a boundary).
	for s in [sy, maxi(sy - 1, 0)]:
		var sk := Vector3i(ck.x, s, ck.y)
		if not chunks.has(sk):
			return false  # not streamed in yet
		if not built.has(sk) and dirty.has(sk):
			return false  # created but no collision applied yet
	return true


# ---------------------------------------------------------------- lighting
# Skylight pours straight down until the first opaque block; glow blocks emit
# 15. BFS spreads through loaded columns only (seams brighten as areas load).

func _light_column(ck: Vector2i) -> void:
	var col: Dictionary = columns[ck]
	var bx := ck.x * 16
	var bz := ck.y * 16
	var queue: Array = []
	for lx in range(16):
		for lz in range(16):
			for y in range(H - 1, -1, -1):
				var id: int = col.data[(y * 16 + lz) * 16 + lx]
				var def := Blocks.get_def(id)
				if def.opaque:
					if def.glow:
						col.light[(y * 16 + lz) * 16 + lx] = 15
						queue.append(Vector3i(bx + lx, y, bz + lz))
					break
				col.light[(y * 16 + lz) * 16 + lx] = 15
				queue.append(Vector3i(bx + lx, y, bz + lz))
			# glow blocks below the skylight line
			for y in range(H):
				var id2: int = col.data[(y * 16 + lz) * 16 + lx]
				if Blocks.get_def(id2).glow and col.light[(y * 16 + lz) * 16 + lx] < 15:
					col.light[(y * 16 + lz) * 16 + lx] = 15
					queue.append(Vector3i(bx + lx, y, bz + lz))
	_propagate(queue)


func _propagate(queue: Array) -> void:
	var head := 0
	while head < queue.size():
		var c: Vector3i = queue[head]
		head += 1
		var lv := light_at(c.x, c.y, c.z) - 1
		if lv <= 0:
			continue
		for d in DIRS:
			var n: Vector3i = c + d
			if n.y < 0 or n.y >= H or not columns.has(column_key(n.x, n.z)):
				continue
			if light_at(n.x, n.y, n.z) >= lv:
				continue
			var ndef := Blocks.get_def(get_block(n.x, n.y, n.z))
			if ndef.opaque and not ndef.glow:
				continue
			_set_light(n.x, n.y, n.z, lv)
			queue.append(n)


## Localized rebuild after an edit: re-derive skylight + glow inside a box,
## reseed from its shell, re-propagate; only changed sections re-mesh.
func repair_light(center: Vector3i, extra := 0) -> void:
	var r := LIGHT_REPAIR_R + extra
	var mn := Vector3i(center.x - r, maxi(center.y - r, 0), center.z - r)
	var mx := Vector3i(center.x + r, mini(center.y + r, H - 1), center.z + r)
	var old := {}
	var queue: Array = []
	for x in range(mn.x, mx.x + 1):
		for z in range(mn.z, mx.z + 1):
			if not columns.has(column_key(x, z)):
				continue
			# Skylight within the box: open to sky if nothing opaque above box.
			var sky := true
			for y in range(mx.y + 1, H):
				if Blocks.get_def(get_block(x, y, z)).opaque:
					sky = false
					break
			for y in range(mx.y, mn.y - 1, -1):
				var c := Vector3i(x, y, z)
				old[c] = light_at(x, y, z)
				var def := Blocks.get_def(get_block(x, y, z))
				var lv := 0
				if def.glow:
					lv = 15
				elif sky and not def.opaque:
					lv = 15
				if def.opaque and not def.glow:
					sky = false
				_set_light(x, y, z, lv)
				if lv > 1:
					queue.append(c)
	# Shell reseed.
	for x in range(mn.x - 1, mx.x + 2):
		for z in range(mn.z - 1, mx.z + 2):
			for y in range(maxi(mn.y - 1, 0), mini(mx.y + 1, H - 1) + 1):
				var inside: bool = x >= mn.x and x <= mx.x and z >= mn.z and z <= mx.z \
					and y >= mn.y and y <= mx.y
				if not inside and columns.has(column_key(x, z)) \
						and light_at(x, y, z) > 1:
					queue.append(Vector3i(x, y, z))
	_propagate(queue)
	for c in old:
		if light_at(c.x, c.y, c.z) != int(old[c]):
			dirty[Vector3i(int(floor(float(c.x) / 16.0)), c.y / 16,
				int(floor(float(c.z) / 16.0)))] = true


# ---------------------------------------------------------------- ops

func apply_op(op: Dictionary) -> void:
	if String(op.t) == "fluid":
		fluid_step()
		return
	var p := _op_pos(op)
	var light_extra := 0
	match String(op.t):
		"set":
			set_block(p.x, p.y, p.z, int(op.b))
			_resolve_falls(p - Vector3i(1, 0, 1), p + Vector3i(1, 3, 1))
		"sphere":
			var r := float(op.r)
			_sphere(p, r, int(op.b), [])
			var ri := int(ceil(r))
			light_extra = ri
			_resolve_falls(p - Vector3i(ri, ri, ri), p + Vector3i(ri, ri + 4, ri))
		"sphere_replace":
			var rr := float(op.r)
			_sphere(p, rr, int(op.b), op.get("from", []))
			light_extra = int(ceil(rr))
		"line":
			var d := Vector3i(int(op.d[0]), int(op.d[1]), int(op.d[2]))
			for i in range(int(op.len)):
				var q: Vector3i = p + d * i
				if get_block_v(q) == Blocks.AIR or int(op.b) == Blocks.AIR:
					set_block_v(q, int(op.b))
			light_extra = int(op.len)
		"column":
			for i in range(int(op.h)):
				var q := Vector3i(p.x, p.y + i, p.z)
				if get_block_v(q) == Blocks.AIR or int(op.b) == Blocks.AIR:
					set_block_v(q, int(op.b))
			light_extra = int(op.h)
		"box":
			var q := Vector3i(int(op.q[0]), int(op.q[1]), int(op.q[2]))
			for x in range(p.x, q.x + 1):
				for y in range(p.y, q.y + 1):
					for z in range(p.z, q.z + 1):
						set_block(x, y, z, int(op.b))
			light_extra = maxi(q.x - p.x, maxi(q.y - p.y, q.z - p.z))
		"box_replace":
			var q2 := Vector3i(int(op.q[0]), int(op.q[1]), int(op.q[2]))
			var from_id := int(op.from)
			for x in range(p.x, q2.x + 1):
				for y in range(p.y, q2.y + 1):
					for z in range(p.z, q2.z + 1):
						if get_block(x, y, z) == from_id:
							set_block(x, y, z, int(op.b))
			light_extra = maxi(q2.x - p.x, maxi(q2.y - p.y, q2.z - p.z))
	repair_light(p, light_extra)


func _op_pos(op: Dictionary) -> Vector3i:
	var a: Array = op.p
	return Vector3i(int(a[0]), int(a[1]), int(a[2]))


func _sphere(c: Vector3i, r: float, b: int, only_from: Array) -> void:
	var ri := int(ceil(r))
	for x in range(c.x - ri, c.x + ri + 1):
		for y in range(c.y - ri, c.y + ri + 1):
			for z in range(c.z - ri, c.z + ri + 1):
				if Vector3(x - c.x, y - c.y, z - c.z).length() > r:
					continue
				var cur := get_block(x, y, z)
				if cur in PROTECTED:
					continue
				var cdef := Blocks.get_def(cur)
				if cur != Blocks.AIR and cdef.hard < 0.0 and not cdef.get("magic_break", false):
					continue
				if not only_from.is_empty():
					var ok := false
					for f in only_from:
						if cur == int(f):
							ok = true
							break
					if not ok:
						continue
				elif b != Blocks.AIR and cur != Blocks.AIR:
					continue
				set_block(x, y, z, b)


func _resolve_falls(mn: Vector3i, mx: Vector3i) -> void:
	for x in range(mn.x, mx.x + 1):
		for z in range(mn.z, mx.z + 1):
			for y in range(maxi(mn.y, 1), H):
				var id := get_block(x, y, z)
				if not Blocks.get_def(id).falls:
					continue
				var ny := y
				while ny > 0 and get_block(x, ny - 1, z) == Blocks.AIR:
					ny -= 1
				if ny != y:
					set_block(x, y, z, Blocks.AIR)
					set_block(x, ny, z, id)


# ---------------------------------------------------------------- fluid sim

func fluid_step() -> void:
	_fluid_steps += 1
	var cells := fluid_cells.keys()
	cells.sort()
	var glow_touched := false
	var bounds_mn := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var bounds_mx := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for c in cells:
		var id := get_block(c.x, c.y, c.z)
		var kind := Blocks.fluid_kind(id)
		if kind == "":
			fluid_cells.erase(c)
			continue
		var changed: bool
		if Blocks.is_gas(id):
			changed = _step_gas(c.x, c.y, c.z, id)
		else:
			if kind == "lava" and _fluid_steps % 2 == 1:
				continue
			changed = _step_liquid(c.x, c.y, c.z, id, kind)
		if changed:
			if Blocks.get_def(id).glow:
				glow_touched = true
			bounds_mn = Vector3i(mini(bounds_mn.x, c.x), mini(bounds_mn.y, c.y), mini(bounds_mn.z, c.z))
			bounds_mx = Vector3i(maxi(bounds_mx.x, c.x), maxi(bounds_mx.y, c.y), maxi(bounds_mx.z, c.z))
		else:
			fluid_cells.erase(c)
	if glow_touched and bounds_mx.x > -(1 << 29):
		var c2 := (bounds_mn + bounds_mx) / 2
		repair_light(c2, maxi(bounds_mx.x - bounds_mn.x,
			maxi(bounds_mx.y - bounds_mn.y, bounds_mx.z - bounds_mn.z)) / 2)


func _step_gas(x: int, y: int, z: int, id: int) -> bool:
	var lvl := Blocks.fluid_level(id)
	if get_block(x, y + 1, z) == Blocks.AIR and y + 1 < H:
		set_block(x, y, z, Blocks.AIR)
		set_block(x, y + 1, z, id)
		return true
	for d in HORIZ:
		if get_block(x + d.x, y, z + d.z) == Blocks.AIR \
				and get_block(x + d.x, y + 1, z + d.z) != Blocks.AIR:
			if _det_chance(x, y, z, 2):
				set_block(x, y, z, Blocks.AIR)
				set_block(x + d.x, y, z + d.z, Blocks.fluid_id(String(Blocks.get_def(id).gas), maxi(lvl - 1, 1)))
				return true
	set_block(x, y, z, Blocks.fluid_id(String(Blocks.get_def(id).gas), lvl - 1))
	return true


func _step_liquid(x: int, y: int, z: int, id: int, kind: String) -> bool:
	var lvl := Blocks.fluid_level(id)
	var maxlvl := Blocks.fluid_max(kind)
	var is_source := lvl == maxlvl
	var changed := false
	if kind == "lava":
		for d in DIRS:
			if Blocks.fluid_kind(get_block(x + d.x, y + d.y, z + d.z)) == "water":
				set_block(x + d.x, y + d.y, z + d.z, Blocks.OBSIDIAN)
				if get_block(x + d.x, y + d.y + 1, z + d.z) == Blocks.AIR:
					set_block(x + d.x, y + d.y + 1, z + d.z, Blocks.STEAM_3)
				set_block(x, y, z, Blocks.OBSIDIAN if is_source else Blocks.AIR)
				return true
	if kind == "acid":
		for d in DIRS:
			var nid := get_block(x + d.x, y + d.y, z + d.z)
			if nid in Blocks.DISSOLVES:
				changed = true
				if _det_chance(x + d.x, y + d.y, z + d.z, 3):
					set_block(x + d.x, y + d.y, z + d.z, Blocks.AIR)
	var below := get_block(x, y - 1, z)
	if below == Blocks.AIR and y > 0:
		set_block(x, y - 1, z, Blocks.fluid_id(kind, maxi(maxlvl - 1, 1)))
		if not is_source:
			set_block(x, y, z, Blocks.AIR)
		return true
	if not is_source:
		var fed := false
		if Blocks.fluid_kind(get_block(x, y + 1, z)) == kind:
			fed = true
		for d in HORIZ:
			var nid2 := get_block(x + d.x, y, z + d.z)
			if Blocks.fluid_kind(nid2) == kind and Blocks.fluid_level(nid2) > lvl:
				fed = true
				break
		if not fed:
			set_block(x, y, z, Blocks.fluid_id(kind, lvl - 1))
			return true
	if lvl > 1:
		for d in HORIZ:
			if get_block(x + d.x, y, z + d.z) == Blocks.AIR:
				set_block(x + d.x, y, z + d.z, Blocks.fluid_id(kind, lvl - 1))
				changed = true
	return changed


func _det_chance(x: int, y: int, z: int, bits: int) -> bool:
	return (hash(Vector4i(x, y, z, _fluid_steps)) & ((1 << bits) - 1)) == 0
