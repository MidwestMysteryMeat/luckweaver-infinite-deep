class_name WorldGen
extends RefCounted
## Infinite deterministic terrain, one 16×H×16 column at a time. Pure function
## of (seed, column) — every peer that generates a column gets identical bytes,
## which is what keeps multiplayer and saves exact without streaming world data.
##
## The overworld is a biome quilt: continent noise carves OCEANS and raises
## MOUNTAINS; temperature and moisture pick desert / tundra / swamp / forest /
## plains between them. VILLAGES (allied, cozy, hostile, ghost) generate on a
## sparse deterministic grid with houses, doors, crafting benches, and folk.
## Below: ~100 blocks of stone, caves widening with depth, ore tiers, brick
## DUNGEON complexes, and lava lakes at the bottom of the world.

const H := 160            # world height (y 0..159)
const SURFACE := 116      # mean inland ground level
const WATER_LEVEL := 112  # oceans and lakes fill to here
const SNOW_LINE := 140    # mountains wear snow above this
const BAND_TOP := 104     # Db.band_at: y >= BAND_TOP is "the surface", band 0

# Biomes.
const B_OCEAN := 0
const B_BEACH := 1
const B_PLAINS := 2
const B_FOREST := 3
const B_DESERT := 4
const B_TUNDRA := 5
const B_SWAMP := 6
const B_MOUNTAIN := 7

const BIOME_NAMES := {B_OCEAN: "the Sunken Sea", B_BEACH: "the Shorelands",
	B_PLAINS: "the Meadowreach", B_FOREST: "the Elderwood",
	B_DESERT: "the Ashen Dunes", B_TUNDRA: "the Frostveil",
	B_SWAMP: "the Mirkfen", B_MOUNTAIN: "the Titan Spires"}

# Structure grids (block-space cell sizes).
const VCELL := 160        # villages
const VILLAGE_R := 17     # village footprint half-extent (Chebyshev)
const DCELL := 96         # underground dungeon complexes
const RCELL := 56         # small surface ruins

static var _seed_cached := -2147483647
static var _nh: FastNoiseLite      # surface detail
static var _nc: FastNoiseLite      # caves
static var _ncont: FastNoiseLite   # continents / elevation
static var _nt: FastNoiseLite      # temperature
static var _nm: FastNoiseLite      # moisture
static var _vcache := {}           # Vector2i vcell -> {} or {anchor, ground, variant}
static var _feat_cache := {}       # String key -> Dictionary{Vector3i: block id}


static func setup(seed_v: int) -> void:
	if _seed_cached == seed_v:
		return
	_seed_cached = seed_v
	_vcache = {}
	_feat_cache = {}
	_nh = FastNoiseLite.new()
	_nh.seed = seed_v
	_nh.frequency = 0.012
	_nc = FastNoiseLite.new()
	_nc.seed = seed_v + 7
	_nc.frequency = 0.055
	_ncont = FastNoiseLite.new()
	_ncont.seed = seed_v + 47
	_ncont.frequency = 0.0016
	_nt = FastNoiseLite.new()
	_nt.seed = seed_v + 13
	_nt.frequency = 0.0028
	_nm = FastNoiseLite.new()
	_nm.seed = seed_v + 29
	_nm.frequency = 0.0036


## Deterministic per-cell hash → [0,1).
static func _h01(seed_v: int, x: int, y: int, z: int, salt: int) -> float:
	return float(absi(hash(Vector4i(x, y, z, seed_v * 31 + salt))) % 10000) / 10000.0


# ---------------------------------------------------------------- heightmap

## Raw terrain height before biome shaping.
static func _raw_h(x: int, z: int) -> int:
	var cont := _ncont.get_noise_2d(float(x), float(z))
	var h := float(SURFACE) + cont * 30.0 + _nh.get_noise_2d(float(x), float(z)) * 9.0
	if cont > 0.42:
		h += (cont - 0.42) * 95.0  # mountain ranges
	return clampi(int(h), 40, H - 14)


static func biome_at(seed_v: int, x: int, z: int) -> int:
	setup(seed_v)
	var h := _raw_h(x, z)
	if h < WATER_LEVEL - 2:
		return B_OCEAN
	if h <= WATER_LEVEL + 1:
		return B_BEACH
	if _ncont.get_noise_2d(float(x), float(z)) > 0.45:
		return B_MOUNTAIN
	var t := _nt.get_noise_2d(float(x), float(z))
	var m := _nm.get_noise_2d(float(x), float(z))
	if t > 0.35:
		return B_DESERT
	if t < -0.38:
		return B_TUNDRA
	if m > 0.32:
		return B_SWAMP
	if m < -0.25:
		return B_PLAINS
	return B_FOREST


static func biome_name(seed_v: int, x: int, z: int) -> String:
	return String(BIOME_NAMES[biome_at(seed_v, x, z)])


## Biome-shaped ground height (still ignores villages).
static func _height(seed_v: int, x: int, z: int) -> int:
	var h := _raw_h(x, z)
	if biome_at(seed_v, x, z) == B_SWAMP:
		# Fens hug the waterline; dips below it become pools.
		h = WATER_LEVEL + 1 + (h - WATER_LEVEL - 1) / 3
	return h


static func surface_y(seed_v: int, x: int, z: int) -> int:
	setup(seed_v)
	var v := _village_of(seed_v, x, z)
	if not v.is_empty():
		return int(v.ground)  # villages sit on a flattened shelf
	return _height(seed_v, x, z)


# ---------------------------------------------------------------- villages

## The village (if any) whose footprint covers (x, z).
static func _village_of(seed_v: int, x: int, z: int) -> Dictionary:
	var cx := int(floor(float(x) / float(VCELL)))
	var cz := int(floor(float(z) / float(VCELL)))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var v := village_in_cell(seed_v, cx + dx, cz + dz)
			if v.is_empty():
				continue
			var a: Vector2i = v.anchor
			if absi(x - a.x) <= VILLAGE_R and absi(z - a.y) <= VILLAGE_R:
				return v
	return {}


## Deterministic village record for a cell ({} if the cell has none).
## The spawn cell (0,0) always TRIES to host one so a fresh world has a
## findable settlement a few minutes' walk from spawn.
static func village_in_cell(seed_v: int, cx: int, cz: int) -> Dictionary:
	setup(seed_v)
	var key := Vector2i(cx, cz)
	if _vcache.has(key):
		return _vcache[key]
	var out := {}
	var forced: bool = cx == 0 and cz == 0
	if forced or _h01(seed_v, cx, 0, cz, 41) < 0.55:
		# Try a few candidate sites; take the first on dry, unfrozen land.
		for attempt in range(8 if forced else 3):
			var ax := cx * VCELL + 40 + int(_h01(seed_v, cx, attempt, cz, 43) * float(VCELL - 80))
			var az := cz * VCELL + 40 + int(_h01(seed_v, cx, attempt, cz, 44) * float(VCELL - 80))
			if forced and absi(ax) < 48 and absi(az) < 48:
				continue  # keep the spawn area wild
			var g := _height(seed_v, ax, az)
			if g > WATER_LEVEL and g < SNOW_LINE - 8:
				var r := _h01(seed_v, ax, 1, az, 45)
				var variant := "allied"
				if r > 0.87:
					variant = "ghost"
				elif r > 0.7:
					variant = "hostile"
				elif r > 0.5:
					variant = "cozy"
				out = {"anchor": Vector2i(ax, az), "ground": g, "variant": variant,
					"cell": key}
				break
	_vcache[key] = out
	return out


## All villages whose anchors lie within r blocks of pos (for the server's
## discovery/registration pass).
static func villages_near(seed_v: int, pos: Vector3, r: float) -> Array:
	var found: Array = []
	var c0 := Vector2i(int(floor((pos.x - r) / float(VCELL))), int(floor((pos.z - r) / float(VCELL))))
	var c1 := Vector2i(int(floor((pos.x + r) / float(VCELL))), int(floor((pos.z + r) / float(VCELL))))
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var v := village_in_cell(seed_v, cx, cz)
			if v.is_empty():
				continue
			var a: Vector2i = v.anchor
			if Vector2(pos.x, pos.z).distance_to(Vector2(a)) <= r:
				found.append(v)
	return found


## Full block dictionary for a village, cached: houses (plank walls, doors,
## glowstone lamps, a chest), the plaza (waystone + campfire), crafting
## benches, a farm and pond. Hostile villages hoard gold instead of benches;
## ghost villages are broken and webbed.
static func village_features(seed_v: int, v: Dictionary) -> Dictionary:
	var a: Vector2i = v.anchor
	var key := "V%d,%d" % [a.x, a.y]
	if _feat_cache.has(key):
		return _feat_cache[key]
	var g: int = v.ground
	var variant := String(v.variant)
	var f := {}
	var lively: bool = variant == "allied" or variant == "cozy"
	# Plaza.
	f[Vector3i(a.x, g + 1, a.y)] = Blocks.WAYSTONE
	f[Vector3i(a.x + 3, g + 1, a.y + 3)] = Blocks.CAMPFIRE
	if lively:
		var benches := [Blocks.BENCH_SMITH, Blocks.BENCH_SPELL, Blocks.BENCH_ALCH,
			Blocks.BENCH_SKILL, Blocks.BENCH_ENCH, Blocks.BENCH_SHOP]
		for i in range(benches.size()):
			f[Vector3i(a.x - 10 + i * 4, g + 1, a.y - 9)] = benches[i]
		for i in range(4):  # farm row
			f[Vector3i(a.x - 8 + i * 2, g, a.y + 6)] = Blocks.DIRT
			f[Vector3i(a.x - 8 + i * 2, g + 1, a.y + 6)] = [Blocks.CROP_1,
				Blocks.CROP_2, Blocks.CROP_RIPE, Blocks.CROP_1][i]
		for px in range(6, 9):  # pond
			for pz in range(6, 9):
				f[Vector3i(a.x + px, g, a.y + pz)] = Blocks.WATER
	elif variant == "hostile":
		f[Vector3i(a.x - 2, g + 1, a.y - 8)] = Blocks.GOLD_BLOCK
		f[Vector3i(a.x + 2, g + 1, a.y - 8)] = Blocks.CHEST_TRAPPED
		f[Vector3i(a.x, g + 1, a.y - 8)] = Blocks.CHEST
	# Lamp posts at the corners.
	for lx in [-12, 12]:
		for lz in [-12, 12]:
			f[Vector3i(a.x + lx, g + 1, a.y + lz)] = Blocks.WOOD
			f[Vector3i(a.x + lx, g + 2, a.y + lz)] = Blocks.WOOD
			f[Vector3i(a.x + lx, g + 3, a.y + lz)] = Blocks.GLOWSTONE
	# Houses: 6×6 footprint, plank walls, brick floor, flat log roof, a door
	# facing the plaza, glowstone on the ceiling, a chest in the corner.
	var sites := [Vector2i(-14, -4), Vector2i(9, -6), Vector2i(-6, 9),
		Vector2i(8, 8), Vector2i(-13, 8)]
	var houses := 3 + int(_h01(seed_v, a.x, 2, a.y, 46) * 3.0)  # 3-5
	for hi in range(mini(houses, sites.size())):
		var o: Vector2i = sites[hi]
		_stamp_house(f, seed_v, Vector3i(a.x + o.x, g, a.y + o.y), variant, hi)
	_feat_cache[key] = f
	return f


static func _stamp_house(f: Dictionary, seed_v: int, at: Vector3i, variant: String, salt: int) -> void:
	var broken: bool = variant == "ghost"
	for x in range(6):
		for z in range(6):
			f[Vector3i(at.x + x, at.y, at.z + z)] = Blocks.BRICK  # floor
			for y in range(1, 5):
				var wall: bool = x == 0 or x == 5 or z == 0 or z == 5
				var p := Vector3i(at.x + x, at.y + y, at.z + z)
				if y == 4:
					if not (broken and _h01(seed_v, p.x, p.y, p.z, 47) < 0.35):
						f[p] = Blocks.WOOD  # roof
				elif wall:
					var corner: bool = (x == 0 or x == 5) and (z == 0 or z == 5)
					if broken and not corner and _h01(seed_v, p.x, p.y, p.z, 48) < 0.3:
						f[p] = Blocks.AIR  # crumbled wall
					else:
						f[p] = Blocks.WOOD if corner else Blocks.PLANK
				else:
					f[p] = Blocks.WEB if broken and _h01(seed_v, p.x, p.y, p.z, 49) < 0.15 \
						else Blocks.AIR  # hollow interior
	# Doorway (2 high) in the wall nearest the plaza — houses ring the anchor,
	# so aim the door back toward local (0,0)... approximately: face +x/-x/+z/-z
	# by which offset dominates. Door block low, air above.
	var dx: int = 5 if at.x < 0 else 0
	f[Vector3i(at.x + dx, at.y + 1, at.z + 2)] = Blocks.DOOR_LOCKED if variant == "hostile" \
		else Blocks.DOOR
	f[Vector3i(at.x + dx, at.y + 2, at.z + 2)] = Blocks.AIR
	# Light + loot.
	f[Vector3i(at.x + 2, at.y + 4, at.z + 2)] = Blocks.GLOWSTONE
	var chest := Blocks.CHEST_STORE
	if variant == "hostile" or broken:
		chest = Blocks.CHEST_TRAPPED if _h01(seed_v, at.x, salt, at.z, 50) < 0.4 else Blocks.CHEST
	f[Vector3i(at.x + 4, at.y + 1, at.z + 4)] = chest


# ---------------------------------------------------------------- dungeons

## Underground brick complex for a dungeon cell ({} if none): a run of rooms
## joined by corridors, lit sparsely, stocked with chests and floor traps.
static func dungeon_in_cell(seed_v: int, cx: int, cz: int) -> Dictionary:
	setup(seed_v)
	var key := "D%d,%d" % [cx, cz]
	if _feat_cache.has(key):
		return _feat_cache[key]
	var out := {}
	if _h01(seed_v, cx, 3, cz, 51) < 0.5:
		var ax := cx * DCELL + 20 + int(_h01(seed_v, cx, 4, cz, 52) * float(DCELL - 40))
		var az := cz * DCELL + 20 + int(_h01(seed_v, cx, 5, cz, 53) * float(DCELL - 40))
		var ay := 14 + int(_h01(seed_v, cx, 6, cz, 54) * 70.0)  # y 14..84 — bands 3..11
		var f := {}
		var rooms := 2 + int(_h01(seed_v, cx, 7, cz, 55) * 3.0)  # 2-4
		var px := ax
		var halls: Array = []
		for ri in range(rooms):
			var w := 7 + int(_h01(seed_v, px, ri, az, 56) * 4.0)  # 7-10 wide
			_stamp_room(f, seed_v, Vector3i(px, ay, az), w, ri)
			var nx := px + w + 3
			halls.append([px + w / 2, nx + 2])
			px = nx
		halls.pop_back()  # no corridor past the last room
		# Corridors last so they punch through the room walls they meet.
		for h in halls:
			for x in range(int(h[0]), int(h[1]) + 1):
				for y in range(1, 4):
					for z in range(-1, 2):
						var p := Vector3i(x, ay + y, az + z)
						if y < 3 and z == 0:
							f[p] = Blocks.AIR
						elif not f.has(p):
							f[p] = Blocks.BRICK
		out = {"anchor": Vector3i(ax, ay, az), "blocks": f}
	_feat_cache[key] = out
	return out


static func _stamp_room(f: Dictionary, seed_v: int, at: Vector3i, w: int, salt: int) -> void:
	var half := w / 2
	for x in range(-half, half + 1):
		for z in range(-half, half + 1):
			for y in range(0, 6):
				var p := Vector3i(at.x + x + half, at.y + y, at.z + z)
				var shell: bool = absi(x) == half or absi(z) == half or y == 0 or y == 5
				f[p] = Blocks.BRICK if shell else Blocks.AIR
	# Dressing: a glowstone eye, loot, and old-school floor traps.
	f[Vector3i(at.x + half, at.y + 5, at.z)] = Blocks.GLOWSTONE
	f[Vector3i(at.x + half + 1, at.y + 1, at.z + half - 1)] = \
		Blocks.CHEST_TRAPPED if _h01(seed_v, at.x, salt, at.z, 57) < 0.35 else Blocks.CHEST
	for t in range(3):
		var tx := at.x + half + int(_h01(seed_v, at.x, salt * 4 + t, at.z, 58) * float(w - 2)) - half + 1
		var tz := at.z + int(_h01(seed_v, at.x, salt * 4 + t, at.z, 59) * float(w - 2)) - half + 1
		var trap_i := int(_h01(seed_v, tx, salt, tz, 60) * float(Blocks.FLOOR_TRAPS.size()))
		f[Vector3i(tx, at.y + 1, tz)] = Blocks.FLOOR_TRAPS[trap_i % Blocks.FLOOR_TRAPS.size()]


# ---------------------------------------------------------------- ruins

static func ruin_in_cell(seed_v: int, cx: int, cz: int) -> Dictionary:
	setup(seed_v)
	var key := "R%d,%d" % [cx, cz]
	if _feat_cache.has(key):
		return _feat_cache[key]
	var out := {}
	if _h01(seed_v, cx, 8, cz, 61) < 0.14:
		var ax := cx * RCELL + 10 + int(_h01(seed_v, cx, 9, cz, 62) * float(RCELL - 20))
		var az := cz * RCELL + 10 + int(_h01(seed_v, cx, 10, cz, 63) * float(RCELL - 20))
		var g := _height(seed_v, ax, az)
		if g > WATER_LEVEL and _village_of(seed_v, ax, az).is_empty():
			var f := {}
			# A broken ring of brick — a collapsed tower with something inside.
			for x in range(-3, 4):
				for z in range(-3, 4):
					if absi(x) != 3 and absi(z) != 3:
						continue
					var hh := 1 + int(_h01(seed_v, ax + x, 0, az + z, 64) * 4.0)
					for y in range(1, hh + 1):
						f[Vector3i(ax + x, g + y, az + z)] = Blocks.BRICK
			f[Vector3i(ax, g + 1, az)] = Blocks.CHEST if _h01(seed_v, ax, 11, az, 65) < 0.7 \
				else Blocks.CHEST_TRAPPED
			out = {"anchor": Vector2i(ax, az), "blocks": f}
	_feat_cache[key] = out
	return out


# ---------------------------------------------------------------- trees

## Cheap hash first (max density), biome check only for candidates.
static func _is_tree(seed_v: int, x: int, z: int) -> bool:
	var r := _h01(seed_v, x, 0, z, 11)
	if r >= 0.034:
		return false
	var b := biome_at(seed_v, x, z)
	var density := 0.0
	match b:
		B_FOREST: density = 0.034
		B_SWAMP: density = 0.02
		B_TUNDRA: density = 0.012
		B_PLAINS: density = 0.005
		B_MOUNTAIN: density = 0.006
	if r >= density:
		return false
	return _village_of(seed_v, x, z).is_empty()


# ---------------------------------------------------------------- column fill

## Fills a 16×H×16 column (index = (y*16 + lz)*16 + lx). Pure & deterministic.
static func fill_column(seed_v: int, ck: Vector2i, data: PackedByteArray) -> void:
	setup(seed_v)
	var bx := ck.x * 16
	var bz := ck.y * 16
	for lx in range(16):
		for lz in range(16):
			var x := bx + lx
			var z := bz + lz
			var biome := biome_at(seed_v, x, z)
			var s := surface_y(seed_v, x, z)
			var in_village: bool = not _village_of(seed_v, x, z).is_empty()
			var sandy: bool = biome == B_DESERT or biome == B_BEACH
			for y in range(H):
				var id := Blocks.AIR
				if y == 0:
					id = Blocks.BEDROCK
				elif y < s - 3:
					id = Blocks.STONE
					# Caves: 3D noise worms widening with depth (not under villages).
					if not in_village and y > 2 and _nc.get_noise_3d(float(x), float(y) * 1.4, float(z)) \
							> 0.52 - minf(float(BAND_TOP - y) * 0.0016, 0.15):
						id = Blocks.LAVA if y <= 10 else Blocks.AIR  # lava lakes at the bottom
					elif id == Blocks.STONE:
						id = _ore_for(seed_v, x, y, z)
				elif y < s:
					id = Blocks.SAND if sandy else Blocks.DIRT
				elif y == s:
					if in_village:
						id = Blocks.GRASS
					elif sandy:
						id = Blocks.SAND
					elif biome == B_MOUNTAIN:
						id = Blocks.SNOW if s >= SNOW_LINE else Blocks.STONE
					elif biome == B_TUNDRA:
						id = Blocks.SNOW
					elif s < WATER_LEVEL:
						id = Blocks.DIRT  # lake / sea floor
					else:
						id = Blocks.GRASS
				elif y <= WATER_LEVEL and s < WATER_LEVEL and not in_village:
					id = Blocks.ICE if biome == B_TUNDRA and y == WATER_LEVEL \
						else Blocks.WATER  # oceans, lakes, fen pools (frozen up north)
				data[(y * 16 + lz) * 16 + lx] = id
			# Sea-floor kelp forests.
			if biome == B_OCEAN and s < WATER_LEVEL - 4 and _h01(seed_v, x, 1, z, 22) < 0.06:
				var kh := 1 + int(_h01(seed_v, x, 2, z, 22) * 3.0)
				for ky in range(s + 1, mini(s + 1 + kh, WATER_LEVEL)):
					data[(ky * 16 + lz) * 16 + lx] = Blocks.KELP
			# Cave dressing: herbs / glow / webs / traps, denser as bands deepen.
			if not in_village:
				for y in range(3, s - 4):
					if data[(y * 16 + lz) * 16 + lx] != Blocks.AIR:
						continue
					if data[((y - 1) * 16 + lz) * 16 + lx] == Blocks.AIR:
						continue
					var r := _h01(seed_v, x, y, z, 23)
					var band := Db.band_at(float(y))
					if r < 0.006:
						data[(y * 16 + lz) * 16 + lx] = Blocks.GLOWSTONE
					elif r < 0.012:
						data[(y * 16 + lz) * 16 + lx] = [Blocks.HERB_LUCK,
							Blocks.HERB_GLOOM, Blocks.HERB_CINDER][int(r * 1000.0) % 3]
					elif r < 0.012 + 0.002 * band:
						data[(y * 16 + lz) * 16 + lx] = [Blocks.WEB, Blocks.SPIKES,
							Blocks.TRIP_EXPL, Blocks.CHEST][int(r * 10000.0) % 4]
			# Trees: this cell may hold trunk or canopy of a tree rooted within 2.
			for ax in range(x - 2, x + 3):
				for az in range(z - 2, z + 3):
					if not _is_tree(seed_v, ax, az):
						continue
					var ts := surface_y(seed_v, ax, az)
					if ts < WATER_LEVEL:
						continue
					var tall: bool = biome_at(seed_v, ax, az) in [B_FOREST, B_TUNDRA]
					var th := (5 if tall else 4) + int(_h01(seed_v, ax, 0, az, 5) * 3.0)
					if ax == x and az == z:
						for ty in range(ts + 1, mini(ts + th, H - 3)):
							data[(ty * 16 + lz) * 16 + lx] = Blocks.WOOD
					var canopy_y := ts + th
					for cy in range(canopy_y - 2, mini(canopy_y + 1, H - 1)):
						if absi(ax - x) + absi(az - z) + absi(cy - canopy_y) <= 3:
							var i2 := (cy * 16 + lz) * 16 + lx
							if data[i2] == Blocks.AIR:
								data[i2] = Blocks.LEAVES
	# Structures intersecting this column (villages, dungeons, ruins) — each is
	# a cached pure dict of absolute-coord blocks; stamp the overlap.
	_stamp_overlap(data, bx, bz, _collect_features(seed_v, bx, bz))


static func _collect_features(seed_v: int, bx: int, bz: int) -> Array:
	var dicts: Array = []
	var vc := Vector2i(int(floor(float(bx) / float(VCELL))), int(floor(float(bz) / float(VCELL))))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var v := village_in_cell(seed_v, vc.x + dx, vc.y + dz)
			if not v.is_empty():
				var a: Vector2i = v.anchor
				if a.x + 21 >= bx and a.x - 21 < bx + 16 and a.y + 21 >= bz and a.y - 21 < bz + 16:
					dicts.append(village_features(seed_v, v))
	var dc := Vector2i(int(floor(float(bx) / float(DCELL))), int(floor(float(bz) / float(DCELL))))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var d := dungeon_in_cell(seed_v, dc.x + dx, dc.y + dz)
			if not d.is_empty():
				dicts.append(d.blocks)
	var rc := Vector2i(int(floor(float(bx) / float(RCELL))), int(floor(float(bz) / float(RCELL))))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var ru := ruin_in_cell(seed_v, rc.x + dx, rc.y + dz)
			if not ru.is_empty():
				dicts.append(ru.blocks)
	return dicts


static func _stamp_overlap(data: PackedByteArray, bx: int, bz: int, dicts: Array) -> void:
	for f in dicts:
		for p in f:
			var v: Vector3i = p
			if v.x >= bx and v.x < bx + 16 and v.z >= bz and v.z < bz + 16 \
					and v.y > 0 and v.y < H:
				data[(v.y * 16 + (v.z - bz)) * 16 + (v.x - bx)] = f[p]


static func _ore_for(seed_v: int, x: int, y: int, z: int) -> int:
	var r := _h01(seed_v, x, y, z, 3)
	if r < 0.010 and y < 100:
		return Blocks.COPPER_ORE
	if r < 0.016 and y < 78:
		return Blocks.IRON_ORE
	if r < 0.020 and y < 52:
		return Blocks.SILVER_ORE
	if r < 0.023 and y < 26:
		return Blocks.ADAMANT_ORE
	if r < 0.030 and y < 88:
		return Blocks.GOLD_ORE
	if r < 0.033 and y < 42:
		return Blocks.LUCKSTONE
	if r < 0.045:
		return Blocks.GRAVEL
	if r < 0.055 and y < 66:
		return Blocks.IRONWOOD_LOG
	return Blocks.STONE
