class_name DungeonGenerator
extends RefCounted
## Deterministic floor generation: same (run_seed, floor) → same voxels on every
## peer. Floor 0 is the town hub; every 5th dungeon floor is a boss floor.
## Returns metadata the server uses to place entities:
## {"spawn": Vector3, "enemy_spawns": Array[Vector3], "boss_spawn": Variant, "has_boss": bool}


static func floor_seed(run_seed: int, fnum: int) -> int:
	return hash("%d:floor:%d" % [run_seed, fnum])


## Deterministic biome per floor. Floors 1-2 are classic delves; then the
## deep opens up: organic cavern warrens, flooded lake floors, molten depths.
static func biome_for(run_seed: int, fnum: int) -> String:
	if fnum <= 0:
		return "town"
	if fnum <= 2:
		return "delve"
	# Hash alone distributes poorly mod 100 across sequential floors; run it
	# through an RNG for proper mixing.
	var brng := RandomNumberGenerator.new()
	brng.seed = hash("%d:biome:%d" % [run_seed, fnum])
	var r := brng.randi_range(0, 99)
	if r < 40:
		return "delve"
	if r < 65:
		return "caverns"
	if r < 85:
		return "lakes"
	return "molten" if fnum >= 6 else "caverns"


static func generate(vw: VoxelWorld, run_seed: int, fnum: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = floor_seed(run_seed, fnum)
	_fill_base(vw)
	var info: Dictionary
	if fnum == 0:
		info = _gen_town(vw)
		info.biome = "town"
	else:
		var biome := biome_for(run_seed, fnum)
		info = _gen_dungeon(vw, rng, fnum, biome)
		info.biome = biome
	vw.compute_light_full()
	vw.mark_all_dirty()
	vw.flush_all()
	return info


static func _fill_base(vw: VoxelWorld) -> void:
	vw.data.fill(Blocks.STONE)
	# Bedrock shell so nothing escapes the volume.
	for x in range(VoxelWorld.SX):
		for z in range(VoxelWorld.SZ):
			vw.set_block(x, 0, z, Blocks.BEDROCK, false)
			vw.set_block(x, VoxelWorld.SY - 1, z, Blocks.BEDROCK, false)
	for y in range(VoxelWorld.SY):
		for x in range(VoxelWorld.SX):
			vw.set_block(x, y, 0, Blocks.BEDROCK, false)
			vw.set_block(x, y, VoxelWorld.SZ - 1, Blocks.BEDROCK, false)
		for z in range(VoxelWorld.SZ):
			vw.set_block(0, y, z, Blocks.BEDROCK, false)
			vw.set_block(VoxelWorld.SX - 1, y, z, Blocks.BEDROCK, false)


# ---------------------------------------------------------------- town (floor 0)

static func _gen_town(vw: VoxelWorld) -> Dictionary:
	var cx := VoxelWorld.SX / 2
	var cz := VoxelWorld.SZ / 2
	# Plaza: 44x44 open hall, floor at y=3, 8 tall.
	_carve_box(vw, cx - 22, 3, cz - 22, cx + 22, 11, cz + 22)
	# Brick floor with gold trim.
	for x in range(cx - 22, cx + 23):
		for z in range(cz - 22, cz + 23):
			var edge: bool = x == cx - 22 or x == cx + 22 or z == cz - 22 or z == cz + 22
			vw.set_block(x, 2, z, Blocks.GOLD_BLOCK if edge else Blocks.BRICK, false)
	# Glowstone pillars.
	for px in [cx - 20, cx + 20]:
		for pz in [cz - 20, cz + 20]:
			for y in range(3, 11):
				vw.set_block(px, y, pz, Blocks.GLOWSTONE, false)
	# Crafting benches along the north side; anvil + altar flank them.
	vw.set_block(cx - 16, 3, cz - 18, Blocks.BENCH_SMITH, false)
	vw.set_block(cx - 10, 3, cz - 18, Blocks.BENCH_SPELL, false)
	vw.set_block(cx - 4, 3, cz - 18, Blocks.BENCH_ALCH, false)
	vw.set_block(cx + 4, 3, cz - 18, Blocks.BENCH_SKILL, false)
	vw.set_block(cx + 10, 3, cz - 18, Blocks.BENCH_SHOP, false)
	vw.set_block(cx + 16, 3, cz - 18, Blocks.BENCH_ENCH, false)
	for bx in [cx - 16, cx - 10, cx - 4, cx + 4, cx + 10, cx + 16]:
		vw.set_block(bx, 5, cz - 18, Blocks.GLOWSTONE, false)
	# Herb garden (starter alchemy loop) on the west side.
	for i in range(5):
		vw.set_block(cx - 18, 3, cz - 6 + i * 3, Blocks.HERB_LUCK, false)
		vw.set_block(cx - 16, 3, cz - 6 + i * 3, Blocks.HERB_GLOOM, false)
		vw.set_block(cx - 14, 3, cz - 6 + i * 3, Blocks.HERB_CINDER, false)
		vw.set_block(cx - 18, 2, cz - 6 + i * 3, Blocks.DIRT, false)
		vw.set_block(cx - 16, 2, cz - 6 + i * 3, Blocks.DIRT, false)
		vw.set_block(cx - 14, 2, cz - 6 + i * 3, Blocks.DIRT, false)
	# Farm plot on the east side: tilled dirt, growing wheat, glowstone sun.
	for i in range(5):
		for j in range(2):
			var fx: int = cx + 14 + j * 2
			var fz: int = cz - 6 + i * 3
			vw.set_block(fx, 2, fz, Blocks.DIRT, false)
			vw.set_block(fx, 3, fz, [Blocks.CROP_1, Blocks.CROP_2, Blocks.CROP_RIPE][(i + j) % 3], false)
	vw.set_block(cx + 15, 6, cz - 1, Blocks.GLOWSTONE, false)
	# Camp by the plaza's heart.
	vw.set_block(cx - 2, 3, cz + 6, Blocks.CAMPFIRE, false)
	# Descent portal on the south side, framed in obsidian.
	vw.set_block(cx, 3, cz + 18, Blocks.PORTAL, false)
	for dx in [-1, 1]:
		vw.set_block(cx + dx, 3, cz + 18, Blocks.OBSIDIAN, false)
		vw.set_block(cx + dx, 4, cz + 18, Blocks.OBSIDIAN, false)
	vw.set_block(cx, 4, cz + 18, Blocks.OBSIDIAN, false)
	return {
		"spawn": Vector3(cx + 0.5, 4.2, cz + 0.5),
		"enemy_spawns": [],
		"boss_spawn": null,
		"has_boss": false,
	}


# ---------------------------------------------------------------- dungeon floors

static func _gen_dungeon(vw: VoxelWorld, rng: RandomNumberGenerator, fnum: int, biome := "delve") -> Dictionary:
	var has_boss := fnum % 5 == 0
	_scatter_veins(vw, rng, fnum)

	# Rooms: random rects on a shared base level; overlaps merge into caves.
	# Biome floors trade some rooms for their own terrain features.
	var rooms: Array = []
	var count := clampi(9 + fnum, 9, 22)
	if biome != "delve":
		count = maxi(count - 4, 6)
	for i in range(count):
		var w := rng.randi_range(6, 13)
		var d := rng.randi_range(6, 13)
		var h := rng.randi_range(4, 6)
		var x := rng.randi_range(3, VoxelWorld.SX - 4 - w)
		var z := rng.randi_range(3, VoxelWorld.SZ - 4 - d)
		var y := 3
		_carve_box(vw, x, y, z, x + w, y + h, z + d)
		rooms.append({"x": x, "y": y, "z": z, "w": w, "d": d, "h": h,
			"cx": x + w / 2, "cz": z + d / 2})

	# Corridors: chain the rooms, plus a couple of loops.
	for i in range(1, rooms.size()):
		_carve_corridor(vw, rooms[i - 1], rooms[i], rng, fnum)
	for i in range(2):
		var a: Dictionary = rooms[rng.randi_range(0, rooms.size() - 1)]
		var b: Dictionary = rooms[rng.randi_range(0, rooms.size() - 1)]
		_carve_corridor(vw, a, b, rng, fnum)

	# Biome terrain layered over the room skeleton.
	match biome:
		"caverns":
			_biome_caverns(vw, rng)
		"lakes":
			_biome_lakes(vw, rng, Blocks.WATER)
		"molten":
			_biome_lakes(vw, rng, Blocks.LAVA)

	# Farthest room from spawn hosts the portal (or the boss arena).
	var spawn_room: Dictionary = rooms[0]
	var far_i := 0
	var far_d := -1.0
	for i in range(1, rooms.size()):
		var dd := Vector2(rooms[i].cx - spawn_room.cx, rooms[i].cz - spawn_room.cz).length()
		if dd > far_d:
			far_d = dd
			far_i = i
	var portal_room: Dictionary = rooms[far_i]

	var enemy_spawns: Array = []
	for i in range(rooms.size()):
		var r: Dictionary = rooms[i]
		_decorate_room(vw, rng, r, fnum, i != 0)  # spawn room stays trap-free
		if i != 0:
			enemy_spawns.append(Vector3(r.cx + 0.5, r.y + 1.5, r.cz + 0.5))

	# Special rooms: alchemy lab, rune forge, gilded vault.
	if rooms.size() >= 4:
		_special_lab(vw, rng, rooms[1])
		_special_forge(vw, rng, rooms[2])
		if fnum >= 3:
			_special_vault(vw, rng, rooms[3])

	var boss_spawn = null
	if has_boss:
		# Boss arena: enlarge the portal room; portal spawns on boss death.
		_carve_box(vw, maxi(portal_room.x - 3, 2), 3, maxi(portal_room.z - 3, 2),
			mini(portal_room.x + portal_room.w + 3, VoxelWorld.SX - 3), 11,
			mini(portal_room.z + portal_room.d + 3, VoxelWorld.SZ - 3))
		boss_spawn = Vector3(portal_room.cx + 0.5, 4.5, portal_room.cz + 0.5)
	else:
		vw.set_block(portal_room.cx, portal_room.y, portal_room.cz, Blocks.PORTAL, false)
		vw.set_block(portal_room.cx, portal_room.y - 1, portal_room.cz, Blocks.OBSIDIAN, false)

	return {
		"spawn": Vector3(spawn_room.cx + 0.5, spawn_room.y + 1.2, spawn_room.cz + 0.5),
		"enemy_spawns": enemy_spawns,
		"boss_spawn": boss_spawn,
		"has_boss": has_boss,
		"portal_pos": [portal_room.cx, portal_room.y, portal_room.cz],
	}


# ---------------------------------------------------------------- biomes

## Organic cavern warrens: random-walk worm tunnels + blob chambers.
static func _biome_caverns(vw: VoxelWorld, rng: RandomNumberGenerator) -> void:
	for w in range(7):
		var p := Vector3(rng.randi_range(8, VoxelWorld.SX - 8),
			rng.randi_range(4, 14), rng.randi_range(8, VoxelWorld.SZ - 8))
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 0.2), rng.randf_range(-1, 1)).normalized()
		for step in range(55):
			_carve_sphere(vw, Vector3i(p), rng.randi_range(1, 2))
			dir = (dir + Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.25, 0.25),
				rng.randf_range(-0.5, 0.5))).normalized()
			p += dir * 1.5
			p.x = clampf(p.x, 4, VoxelWorld.SX - 5)
			p.y = clampf(p.y, 3, 20)
			p.z = clampf(p.z, 4, VoxelWorld.SZ - 5)
	for b in range(4):
		var c := Vector3i(rng.randi_range(12, VoxelWorld.SX - 12),
			rng.randi_range(4, 10), rng.randi_range(12, VoxelWorld.SZ - 12))
		_carve_sphere(vw, c, rng.randi_range(3, 5))
		vw.set_block(c.x, c.y + 3, c.z, Blocks.GLOWSTONE, false)


## Flooded basins (water) or molten pools (lava): ellipsoid lakes filled to a
## waterline, beached with sand / obsidian, kelp forests in the water.
static func _biome_lakes(vw: VoxelWorld, rng: RandomNumberGenerator, fluid: int) -> void:
	var lakes := rng.randi_range(2, 3) if fluid == Blocks.WATER else 2
	for L in range(lakes):
		var cx := rng.randi_range(18, VoxelWorld.SX - 18)
		var cz := rng.randi_range(18, VoxelWorld.SZ - 18)
		var rx := rng.randi_range(7, 12)
		var rz := rng.randi_range(7, 12)
		var depth := rng.randi_range(3, 4)
		var floor_y := 2
		var waterline := floor_y + depth
		for x in range(cx - rx - 2, cx + rx + 3):
			for z in range(cz - rz - 2, cz + rz + 3):
				var dx := float(x - cx) / rx
				var dz := float(z - cz) / rz
				var d := dx * dx + dz * dz
				if d > 1.35:
					continue
				# Air pocket above the lake so it reads as a cavern grotto.
				for y in range(waterline + 1, waterline + 6):
					if vw.get_block(x, y, z) != Blocks.BEDROCK:
						vw.set_block(x, y, z, Blocks.AIR, false)
				if d > 1.0:
					# Beach ring.
					if vw.get_block(x, waterline, z) != Blocks.BEDROCK:
						vw.set_block(x, waterline, z,
							Blocks.SAND if fluid == Blocks.WATER else Blocks.OBSIDIAN, false)
					continue
				for y in range(floor_y, waterline + 1):
					if vw.get_block(x, y, z) != Blocks.BEDROCK:
						vw.set_block(x, y, z, fluid, false)
				if fluid == Blocks.WATER and rng.randf() < 0.06:
					vw.set_block(x, floor_y, z, Blocks.KELP, false)
					vw.set_block(x, floor_y + 1, z, Blocks.KELP, false)
				if rng.randf() < 0.04:
					vw.set_block(x, floor_y - 1, z,
						Blocks.LUCKSTONE if fluid == Blocks.WATER else Blocks.GOLD_ORE, false)
		# Light over the grotto.
		vw.set_block(cx, waterline + 5, cz, Blocks.GLOWSTONE, false)


static func _carve_sphere(vw: VoxelWorld, c: Vector3i, r: int) -> void:
	for x in range(c.x - r, c.x + r + 1):
		for y in range(c.y - r, c.y + r + 1):
			for z in range(c.z - r, c.z + r + 1):
				if Vector3(x - c.x, y - c.y, z - c.z).length() <= r \
						and vw.get_block(x, y, z) != Blocks.BEDROCK:
					vw.set_block(x, y, z, Blocks.AIR, false)


static func _scatter_veins(vw: VoxelWorld, rng: RandomNumberGenerator, fnum: int) -> void:
	var veins := 160 + fnum * 10
	for i in range(veins):
		var p := Vector3i(rng.randi_range(2, VoxelWorld.SX - 3),
			rng.randi_range(2, VoxelWorld.SY - 3), rng.randi_range(2, VoxelWorld.SZ - 3))
		var roll := rng.randf()
		var id := Blocks.DIRT
		var size := rng.randi_range(2, 5)
		if roll < 0.30:
			id = Blocks.GOLD_ORE
			size = rng.randi_range(2, 4)
		elif roll < 0.38:
			id = Blocks.LUCKSTONE
			size = rng.randi_range(1, 3)
		elif roll < 0.55:
			id = Blocks.GRAVEL
		elif roll < 0.68:
			id = Blocks.SAND
		for j in range(size):
			var q: Vector3i = p + Vector3i(rng.randi_range(-1, 1), rng.randi_range(-1, 1), rng.randi_range(-1, 1))
			if vw.get_block_v(q) == Blocks.STONE:
				vw.set_block_v(q, id, false)


static func _carve_box(vw: VoxelWorld, x0: int, y0: int, z0: int, x1: int, y1: int, z1: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				if vw.get_block(x, y, z) != Blocks.BEDROCK:
					vw.set_block(x, y, z, Blocks.AIR, false)


static func _carve_corridor(vw: VoxelWorld, a: Dictionary, b: Dictionary, rng: RandomNumberGenerator = null, fnum := 0) -> void:
	# L-shaped, 2 wide, 3 tall, at base level.
	var y := 3
	var x0: int = mini(a.cx, b.cx)
	var x1: int = maxi(a.cx, b.cx)
	for x in range(x0, x1 + 1):
		_carve_box(vw, x, y, a.cz, x + 1, y + 2, a.cz + 1)
	var z0: int = mini(a.cz, b.cz)
	var z1: int = maxi(a.cz, b.cz)
	for z in range(z0, z1 + 1):
		_carve_box(vw, b.cx, y, z, b.cx + 1, y + 2, z + 1)
	# Corridor hazards: tripwires strung across the walkway, the odd trapped door.
	if rng == null:
		return
	if x1 - x0 > 6 and rng.randf() < 0.2 + fnum * 0.02:
		var wires := [Blocks.TRIP_EXPL, Blocks.TRIP_ACID, Blocks.TRIP_LAVA]
		var wx: int = rng.randi_range(x0 + 2, x1 - 2)
		vw.set_block(wx, y, a.cz, wires[rng.randi_range(0, 2)], false)
		vw.set_block(wx, y, a.cz + 1, wires[rng.randi_range(0, 2)], false)
	if fnum >= 2 and z1 - z0 > 6 and rng.randf() < 0.15:
		var dz: int = rng.randi_range(z0 + 2, z1 - 2)
		vw.set_block(b.cx, y, dz, Blocks.DOOR_TRAPPED if rng.randf() < 0.4 else Blocks.DOOR, false)
		vw.set_block(b.cx + 1, y, dz, Blocks.DOOR, false)


static func _decorate_room(vw: VoxelWorld, rng: RandomNumberGenerator, r: Dictionary, fnum: int, traps := true) -> void:
	# Glowstone corners so rooms read at a glance.
	for cx in [r.x + 1, r.x + r.w - 1]:
		for cz in [r.z + 1, r.z + r.d - 1]:
			vw.set_block(cx, r.y + r.h - 1, cz, Blocks.GLOWSTONE, false)
	# Chests — a cut of them are trapped (identical name; caveat emptor).
	if rng.randf() < 0.4:
		var chest_id: int = Blocks.CHEST_TRAPPED if rng.randf() < 0.3 + fnum * 0.02 else Blocks.CHEST
		vw.set_block(r.cx + rng.randi_range(-2, 2), r.y, r.cz + rng.randi_range(-2, 2), chest_id, false)
	# Traps, scaling with depth: floor traps, wall dart holes, trapped doors,
	# web nests, and old-school crusher pressure plates.
	var trap_rolls: int = (1 + fnum / 3) if traps else 0
	for t in range(trap_rolls):
		if rng.randf() > 0.35 + fnum * 0.02:
			continue
		var tid: int = Blocks.FLOOR_TRAPS[rng.randi_range(0, Blocks.FLOOR_TRAPS.size() - 1)]
		var tx: int = r.x + rng.randi_range(1, maxi(r.w - 1, 1))
		var tz: int = r.z + rng.randi_range(1, maxi(r.d - 1, 1))
		if vw.get_block(tx, r.y, tz) == Blocks.AIR:
			vw.set_block(tx, r.y, tz, tid, false)
			if tid == Blocks.WEB:  # webs nest in clumps
				vw.set_block(tx + 1, r.y, tz, Blocks.WEB, false)
				vw.set_block(tx, r.y + 1, tz, Blocks.WEB, false)
	# Dart holes hide in room walls at chest height.
	if traps and fnum >= 2 and rng.randf() < 0.25:
		var side: int = rng.randi_range(0, 1)
		var wx: int = r.x - 1 if side == 0 else r.x + r.w + 1
		var wz2: int = r.z + rng.randi_range(1, maxi(r.d - 1, 1))
		if Blocks.get_def(vw.get_block(wx, r.y + 1, wz2)).solid:
			vw.set_block(wx, r.y + 1, wz2, Blocks.DART_TRAP, false)
	# Herbs.
	if rng.randf() < 0.5:
		var herb: int = [Blocks.HERB_LUCK, Blocks.HERB_GLOOM, Blocks.HERB_CINDER][rng.randi_range(0, 2)]
		for i in range(rng.randi_range(1, 3)):
			vw.set_block(r.x + rng.randi_range(1, r.w - 1), r.y, r.z + rng.randi_range(1, r.d - 1), herb, false)
	# Fluid pools sunk into the floor: water early, lava deeper, acid deepest.
	# Sources sit below floor level, contained until someone breaks the rim.
	if rng.randf() < 0.3:
		var fluid := Blocks.WATER
		if fnum >= 4 and rng.randf() < 0.4:
			fluid = Blocks.ACID
		elif fnum >= 2 and rng.randf() < 0.5:
			fluid = Blocks.LAVA
		var lx: int = r.x + rng.randi_range(2, maxi(r.w - 2, 2))
		var lz: int = r.z + rng.randi_range(2, maxi(r.d - 2, 2))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if vw.get_block(lx + dx, r.y - 1, lz + dz) != Blocks.BEDROCK:
					vw.set_block(lx + dx, r.y - 1, lz + dz, fluid, false)
	# Wild farm nooks: dirt with sprouting wheat under a glowstone vein.
	if rng.randf() < 0.18:
		var wx: int = r.x + rng.randi_range(1, maxi(r.w - 1, 1))
		var wz: int = r.z + rng.randi_range(1, maxi(r.d - 1, 1))
		vw.set_block(wx, r.y - 1, wz, Blocks.DIRT, false)
		vw.set_block(wx, r.y, wz, Blocks.CROP_RIPE, false)
		vw.set_block(wx, r.y + 3, wz, Blocks.GLOWSTONE, false)
	# Vines.
	if rng.randf() < 0.35:
		for i in range(rng.randi_range(2, 5)):
			var vx: int = r.x + rng.randi_range(1, r.w - 1)
			var vz: int = r.z + rng.randi_range(1, r.d - 1)
			vw.set_block(vx, r.y + rng.randi_range(0, 2), vz, Blocks.VINE, false)


static func _special_lab(vw: VoxelWorld, rng: RandomNumberGenerator, r: Dictionary) -> void:
	vw.set_block(r.cx, r.y, r.cz, Blocks.BENCH_ALCH, false)
	for i in range(4):
		var herb: int = [Blocks.HERB_LUCK, Blocks.HERB_GLOOM, Blocks.HERB_CINDER][rng.randi_range(0, 2)]
		vw.set_block(r.x + rng.randi_range(1, r.w - 1), r.y, r.z + rng.randi_range(1, r.d - 1), herb, false)


static func _special_forge(vw: VoxelWorld, rng: RandomNumberGenerator, r: Dictionary) -> void:
	vw.set_block(r.cx, r.y, r.cz, Blocks.BENCH_SPELL, false)
	for i in range(3):
		vw.set_block(r.x + rng.randi_range(1, r.w - 1), r.y + rng.randi_range(0, 1),
			r.z + rng.randi_range(1, r.d - 1), Blocks.LUCKSTONE, false)


static func _special_vault(vw: VoxelWorld, rng: RandomNumberGenerator, r: Dictionary) -> void:
	# A sealed brick strongroom with a locked door — key or spell to enter.
	var cx: int = r.cx
	var cz: int = r.cz
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			for dy in range(0, 4):
				var edge: bool = abs(dx) == 2 or abs(dz) == 2 or dy == 3
				vw.set_block(cx + dx, r.y + dy, cz + dz,
					Blocks.BRICK if edge else Blocks.AIR, false)
	vw.set_block(cx - 2, r.y, cz, Blocks.DOOR_LOCKED, false)
	vw.set_block(cx, r.y, cz, Blocks.CHEST, false)
	vw.set_block(cx + 1, r.y, cz + 1, Blocks.GOLD_BLOCK, false)
	vw.set_block(cx - 1, r.y, cz - 1, Blocks.GOLD_BLOCK, false)
	vw.set_block(cx, r.y + 2, cz, Blocks.GLOWSTONE, false)
