class_name VoxelWorld
extends Node3D
## Owns the voxel grid for the current floor: block data, block light, fluids,
## chunk nodes, and edit ops.
##
## Determinism contract: ops are JSON-safe dicts replayed in log order on every
## peer, and apply_op (including gravity cascade and fluid_step) is a pure
## function of grid state — so seed + log always reproduces the same world.
## Light is DERIVED state (recomputed locally per peer, never synced).
##
## Fluids are Minecraft-style: liquids (water/lava/acid) fall, then spread with
## thinning levels and retract when cut off; lava ticks half-speed; lava+water
## makes obsidian and steam; acid dissolves soft blocks. Gases (steam) rise and
## dissipate. The server emits {"t":"fluid"} ops on a timer; each op advances
## the simulation exactly one step on every peer.

const SX := 96
const SY := 40
const SZ := 96
const CH := 16
const MAX_LIGHT := 15
const LIGHT_REPAIR_R := 14  # box radius for localized light rebuilds

## Block ids that area ops (explosions, transmutes) never overwrite.
const PROTECTED := [Blocks.BEDROCK, Blocks.CHEST, Blocks.BENCH_SPELL,
	Blocks.BENCH_ALCH, Blocks.BENCH_SKILL, Blocks.BENCH_SHOP, Blocks.PORTAL,
	Blocks.BENCH_SMITH, Blocks.BENCH_ENCH]

const DIRS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const HORIZ := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

var data := PackedByteArray()
var light := PackedByteArray()
var chunks := {}       # Vector3i chunk coord -> {"mesh": MeshInstance3D, "shape": CollisionShape3D}
var dirty := {}        # Vector3i chunk coord -> true
var fluid_cells := {}  # int cell index -> true (active fluid/gas cells)
var _fluid_steps := 0


func _ready() -> void:
	data.resize(SX * SY * SZ)
	light.resize(SX * SY * SZ)
	_create_chunk_nodes()


func _process(_delta: float) -> void:
	flush_dirty(10)


# ---------------------------------------------------------------- basics

func idx(x: int, y: int, z: int) -> int:
	return (y * SZ + z) * SX + x


func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < SX and y >= 0 and y < SY and z >= 0 and z < SZ


func get_block(x: int, y: int, z: int) -> int:
	if not in_bounds(x, y, z):
		return Blocks.AIR
	return data[idx(x, y, z)]


func get_block_v(p: Vector3i) -> int:
	return get_block(p.x, p.y, p.z)


func light_at(x: int, y: int, z: int) -> int:
	if not in_bounds(x, y, z):
		return 0
	return light[idx(x, y, z)]


func set_block(x: int, y: int, z: int, id: int, mark := true) -> void:
	if not in_bounds(x, y, z):
		return
	var i := idx(x, y, z)
	if data[i] == id:
		return
	data[i] = id
	# Fluid bookkeeping: track this cell, wake sleeping fluid neighbors.
	if Blocks.fluid_kind(id) != "":
		fluid_cells[i] = true
	else:
		fluid_cells.erase(i)
	for d in DIRS:
		var nx: int = x + d.x
		var ny: int = y + d.y
		var nz: int = z + d.z
		if in_bounds(nx, ny, nz) and Blocks.fluid_kind(data[idx(nx, ny, nz)]) != "":
			fluid_cells[idx(nx, ny, nz)] = true
	if mark:
		_mark_dirty(x, y, z)


func set_block_v(p: Vector3i, id: int, mark := true) -> void:
	set_block(p.x, p.y, p.z, id, mark)


func has_active_fluids() -> bool:
	return not fluid_cells.is_empty()


func _mark_dirty(x: int, y: int, z: int) -> void:
	var cc := Vector3i(x / CH, y / CH, z / CH)
	dirty[cc] = true
	if x % CH == 0: dirty[cc + Vector3i(-1, 0, 0)] = true
	if x % CH == CH - 1: dirty[cc + Vector3i(1, 0, 0)] = true
	if y % CH == 0: dirty[cc + Vector3i(0, -1, 0)] = true
	if y % CH == CH - 1: dirty[cc + Vector3i(0, 1, 0)] = true
	if z % CH == 0: dirty[cc + Vector3i(0, 0, -1)] = true
	if z % CH == CH - 1: dirty[cc + Vector3i(0, 0, 1)] = true


# ---------------------------------------------------------------- chunks

func _create_chunk_nodes() -> void:
	for cx in range(SX / CH):
		for cy in range(SY / CH):
			for cz in range(SZ / CH):
				var cc := Vector3i(cx, cy, cz)
				var body := StaticBody3D.new()
				body.name = "C_%d_%d_%d" % [cx, cy, cz]
				body.position = Vector3(cc * CH)
				body.add_to_group("voxel")
				var mi := MeshInstance3D.new()
				body.add_child(mi)
				var cs := CollisionShape3D.new()
				body.add_child(cs)
				add_child(body)
				chunks[cc] = {"mesh": mi, "shape": cs}


func mark_all_dirty() -> void:
	for cc in chunks:
		dirty[cc] = true


func flush_dirty(budget: int) -> void:
	if dirty.is_empty():
		return
	var done := 0
	var keys := dirty.keys()
	for cc in keys:
		if done >= budget:
			break
		dirty.erase(cc)
		if not chunks.has(cc):
			continue
		_rebuild_chunk(cc)
		done += 1


func flush_all() -> void:
	while not dirty.is_empty():
		flush_dirty(9999)


func _rebuild_chunk(cc: Vector3i) -> void:
	var built := Mesher.build(self, cc * CH, CH)
	var ch: Dictionary = chunks[cc]
	ch.mesh.mesh = built.mesh
	if built.faces.size() > 0:
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(built.faces)
		ch.shape.shape = shape
	else:
		ch.shape.shape = null


# ---------------------------------------------------------------- lighting
# Block light only (no sky underground): glow blocks emit 15, light decays 1
# per cell through non-opaque space. Full rebuild at floor gen; localized
# box repair (radius >= max light range shy of a hair) after edits.

func compute_light_full() -> void:
	light.fill(0)
	var queue: Array = []
	for i in range(data.size()):
		if Blocks.get_def(data[i]).glow:
			light[i] = MAX_LIGHT
			queue.append(i)
	_propagate(queue)


func _propagate(queue: Array) -> void:
	var head := 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		var lv := int(light[i]) - 1
		if lv <= 0:
			continue
		var x := i % SX
		var z := (i / SX) % SZ
		var y := i / (SX * SZ)
		for d in DIRS:
			var nx: int = x + d.x
			var ny: int = y + d.y
			var nz: int = z + d.z
			if not in_bounds(nx, ny, nz):
				continue
			var ni := idx(nx, ny, nz)
			if int(light[ni]) >= lv:
				continue
			var ndef := Blocks.get_def(data[ni])
			if ndef.opaque and not ndef.glow:
				continue
			light[ni] = lv
			queue.append(ni)


## Recompute light in a box around an edit: zero it, reseed from glow cells
## inside and true values on the boundary shell, re-propagate, and re-mesh
## only the chunks whose light actually changed.
func repair_light(center: Vector3i, extra := 0) -> void:
	var r := LIGHT_REPAIR_R + extra
	var mn := Vector3i(maxi(center.x - r, 0), maxi(center.y - r, 0), maxi(center.z - r, 0))
	var mx := Vector3i(mini(center.x + r, SX - 1), mini(center.y + r, SY - 1), mini(center.z + r, SZ - 1))
	var old := {}
	var queue: Array = []
	for y in range(mn.y, mx.y + 1):
		for z in range(mn.z, mx.z + 1):
			for x in range(mn.x, mx.x + 1):
				var i := idx(x, y, z)
				old[i] = int(light[i])
				light[i] = 0
				if Blocks.get_def(data[i]).glow:
					light[i] = MAX_LIGHT
					queue.append(i)
	# Boundary shell: cells just outside the box shine back in.
	for y in range(mn.y - 1, mx.y + 2):
		for z in range(mn.z - 1, mx.z + 2):
			for x in range(mn.x - 1, mx.x + 2):
				var inside: bool = x >= mn.x and x <= mx.x and y >= mn.y and y <= mx.y \
					and z >= mn.z and z <= mx.z
				if inside or not in_bounds(x, y, z):
					continue
				if int(light[idx(x, y, z)]) > 1:
					queue.append(idx(x, y, z))
	_propagate(queue)
	for i in old:
		if int(light[i]) != int(old[i]):
			var x := int(i) % SX
			var z := (int(i) / SX) % SZ
			var y := int(i) / (SX * SZ)
			dirty[Vector3i(x / CH, y / CH, z / CH)] = true


# ---------------------------------------------------------------- ops

## Applies one JSON-safe edit op. Deterministic across peers.
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
			# Only converts `from` cells — crushers sweep through air without
			# chewing permanent holes in the architecture.
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
				# Unbreakable-by-hand blocks survive area magic unless flagged
				# magic_break (locked doors, fluids). Walls/floors/ceilings are
				# ordinary blocks and always yield to spells.
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
					continue  # plain fill only writes into empty space
				set_block(x, y, z, b)


## Gravity cascade for falls-type blocks in an AABB — deterministic scan order.
func _resolve_falls(mn: Vector3i, mx: Vector3i) -> void:
	for x in range(maxi(mn.x, 0), mini(mx.x, SX - 1) + 1):
		for z in range(maxi(mn.z, 0), mini(mx.z, SZ - 1) + 1):
			for y in range(maxi(mn.y, 1), SY):
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

## One deterministic simulation step over all awake fluid/gas cells, in sorted
## cell order. Cells that do nothing go back to sleep (set_block re-wakes them).
func fluid_step() -> void:
	_fluid_steps += 1
	var idxs := fluid_cells.keys()
	idxs.sort()
	var glow_touched := false
	var bounds_mn := Vector3i(SX, SY, SZ)
	var bounds_mx := Vector3i(-1, -1, -1)
	for i in idxs:
		var id: int = data[i]
		var kind := Blocks.fluid_kind(id)
		if kind == "":
			fluid_cells.erase(i)
			continue
		var x := int(i) % SX
		var z := (int(i) / SX) % SZ
		var y := int(i) / (SX * SZ)
		var changed: bool
		if Blocks.is_gas(id):
			changed = _step_gas(x, y, z, id)
		else:
			if kind == "lava" and _fluid_steps % 2 == 1:
				continue  # lava is sluggish
			changed = _step_liquid(x, y, z, id, kind)
		if changed:
			if Blocks.get_def(id).glow:
				glow_touched = true
			bounds_mn = Vector3i(mini(bounds_mn.x, x), mini(bounds_mn.y, y), mini(bounds_mn.z, z))
			bounds_mx = Vector3i(maxi(bounds_mx.x, x), maxi(bounds_mx.y, y), maxi(bounds_mx.z, z))
		else:
			fluid_cells.erase(i)  # settled; neighbors will wake it if needed
	if glow_touched and bounds_mx.x >= 0:
		var c := (bounds_mn + bounds_mx) / 2
		repair_light(c, maxi(bounds_mx.x - bounds_mn.x, maxi(bounds_mx.y - bounds_mn.y, bounds_mx.z - bounds_mn.z)) / 2)


func _step_gas(x: int, y: int, z: int, id: int) -> bool:
	var lvl := Blocks.fluid_level(id)
	# Steam rises...
	if get_block(x, y + 1, z) == Blocks.AIR:
		set_block(x, y, z, Blocks.AIR)
		set_block(x, y + 1, z, id)
		return true
	# ...seeps sideways under ceilings...
	for d in HORIZ:
		if get_block(x + d.x, y, z + d.z) == Blocks.AIR and get_block(x + d.x, y + 1, z + d.z) != Blocks.AIR:
			if _det_chance(x, y, z, 2):
				set_block(x, y, z, Blocks.AIR)
				set_block(x + d.x, y, z + d.z, Blocks.fluid_id("steam", maxi(lvl - 1, 1)))
				return true
	# ...and dissipates.
	set_block(x, y, z, Blocks.fluid_id("steam", lvl - 1))  # level 0 -> AIR
	return true


func _step_liquid(x: int, y: int, z: int, id: int, kind: String) -> bool:
	var lvl := Blocks.fluid_level(id)
	var maxlvl := Blocks.fluid_max(kind)
	var is_source := lvl == maxlvl
	var changed := false

	# Lava + water = obsidian, and steam boils off above.
	if kind == "lava":
		for d in DIRS:
			if Blocks.fluid_kind(get_block(x + d.x, y + d.y, z + d.z)) == "water":
				set_block(x + d.x, y + d.y, z + d.z, Blocks.OBSIDIAN)
				if get_block(x + d.x, y + d.y + 1, z + d.z) == Blocks.AIR:
					set_block(x + d.x, y + d.y + 1, z + d.z, Blocks.STEAM_3)
				set_block(x, y, z, Blocks.OBSIDIAN if is_source else Blocks.AIR)
				return true

	# Acid eats soft blocks around it — and stays awake while any remain.
	if kind == "acid":
		for d in DIRS:
			var nid := get_block(x + d.x, y + d.y, z + d.z)
			if nid in Blocks.DISSOLVES:
				changed = true  # keep gnawing next step even if this roll fails
				if _det_chance(x + d.x, y + d.y, z + d.z, 3):
					set_block(x + d.x, y + d.y, z + d.z, Blocks.AIR)

	# Fall.
	var below := get_block(x, y - 1, z)
	if below == Blocks.AIR:
		set_block(x, y - 1, z, Blocks.fluid_id(kind, maxi(maxlvl - 1, 1)))
		if not is_source:
			set_block(x, y, z, Blocks.AIR)
		return true

	# Retract when cut off from anything stronger.
	if not is_source:
		var fed := false
		if Blocks.fluid_kind(get_block(x, y + 1, z)) == kind:
			fed = true
		for d in HORIZ:
			var nid := get_block(x + d.x, y, z + d.z)
			if Blocks.fluid_kind(nid) == kind and Blocks.fluid_level(nid) > lvl:
				fed = true
				break
		if not fed:
			set_block(x, y, z, Blocks.fluid_id(kind, lvl - 1))  # level 0 -> AIR
			return true

	# Spread.
	if lvl > 1:
		for d in HORIZ:
			if get_block(x + d.x, y, z + d.z) == Blocks.AIR:
				set_block(x + d.x, y, z + d.z, Blocks.fluid_id(kind, lvl - 1))
				changed = true
	return changed


## Deterministic pseudo-chance (1 in 2^bits) tied to cell + step counter, so
## every peer replaying the op stream rolls identically.
func _det_chance(x: int, y: int, z: int, bits: int) -> bool:
	var h := hash(Vector4i(x, y, z, _fluid_steps))
	return (h & ((1 << bits) - 1)) == 0
