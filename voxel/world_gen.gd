class_name WorldGen
extends RefCounted
## Infinite deterministic terrain, one 16×H×16 column at a time. Pure function
## of (seed, column) — every peer that generates a column gets identical bytes,
## which is what keeps multiplayer and saves exact without streaming world data.
##
## Layout: bedrock floor → deep stone (ores & caves thicken with depth) →
## dirt → grass surface (~y 36-50) with trees and water-filled dells → sky.
## The Gilded Refuge town is stamped into the columns around the origin.

const H := 64            # world height (y 0..63)
const SURFACE := 42      # mean surface level
const WATER_LEVEL := 38  # dells below this flood into lakes
const TOWN_R := 14       # town plaza half-extent around origin
const TOWN_Y := 41       # plaza ground level (brick at TOWN_Y, walk on +1)

static var _seed_cached := -2147483647
static var _nh: FastNoiseLite      # heightmap
static var _nc: FastNoiseLite      # caves


static func setup(seed_v: int) -> void:
	if _seed_cached == seed_v:
		return
	_seed_cached = seed_v
	_nh = FastNoiseLite.new()
	_nh.seed = seed_v
	_nh.frequency = 0.011
	_nc = FastNoiseLite.new()
	_nc.seed = seed_v + 7
	_nc.frequency = 0.065


static func surface_y(seed_v: int, x: int, z: int) -> int:
	setup(seed_v)
	if absi(x) <= TOWN_R + 2 and absi(z) <= TOWN_R + 2:
		return TOWN_Y  # town sits on a flattened shelf
	return clampi(SURFACE + int(_nh.get_noise_2d(float(x), float(z)) * 12.0), 30, H - 10)


## Deterministic per-cell hash → [0,1).
static func _h01(seed_v: int, x: int, y: int, z: int, salt: int) -> float:
	return float(absi(hash(Vector4i(x, y, z, seed_v * 31 + salt))) % 10000) / 10000.0


static func _is_tree(seed_v: int, x: int, z: int) -> bool:
	if absi(x) <= TOWN_R + 4 and absi(z) <= TOWN_R + 4:
		return false  # keep the town square clear
	return _h01(seed_v, x, 0, z, 11) < 0.012


## Fixed town furniture in absolute world coords (benches, waystone, camp,
## a farm plot, and a fishing pond). Game registers these at run start.
static func town_features() -> Dictionary:
	var f := {}
	var gy := TOWN_Y + 1
	f[Vector3i(-10, gy, -12)] = Blocks.BENCH_SMITH
	f[Vector3i(-6, gy, -12)] = Blocks.BENCH_SPELL
	f[Vector3i(-2, gy, -12)] = Blocks.BENCH_ALCH
	f[Vector3i(2, gy, -12)] = Blocks.BENCH_SKILL
	f[Vector3i(6, gy, -12)] = Blocks.BENCH_ENCH
	f[Vector3i(10, gy, -12)] = Blocks.BENCH_SHOP
	f[Vector3i(0, gy, -6)] = Blocks.WAYSTONE
	f[Vector3i(4, gy, 4)] = Blocks.CAMPFIRE
	for i in range(4):  # farm row
		f[Vector3i(-9 + i * 2, TOWN_Y, 6)] = Blocks.DIRT
		f[Vector3i(-9 + i * 2, gy, 6)] = [Blocks.CROP_1, Blocks.CROP_2, Blocks.CROP_RIPE, Blocks.CROP_1][i]
	for px in range(8, 11):  # pond
		for pz in range(8, 11):
			f[Vector3i(px, TOWN_Y, pz)] = Blocks.WATER
	for lx in [-12, 12]:
		for lz in [-12, 12]:
			f[Vector3i(lx, gy + 3, lz)] = Blocks.GLOWSTONE
	return f


## Fills a 16×H×16 column (index = (y*16 + lz)*16 + lx). Pure & deterministic.
static func fill_column(seed_v: int, ck: Vector2i, data: PackedByteArray) -> void:
	setup(seed_v)
	var bx := ck.x * 16
	var bz := ck.y * 16
	for lx in range(16):
		for lz in range(16):
			var x := bx + lx
			var z := bz + lz
			var s := surface_y(seed_v, x, z)
			var in_town: bool = absi(x) <= TOWN_R and absi(z) <= TOWN_R
			for y in range(H):
				var id := Blocks.AIR
				if y == 0:
					id = Blocks.BEDROCK
				elif y < s - 3:
					id = Blocks.STONE
					# Caves: 3D noise worms, thicker with depth (never under town).
					if not in_town and y > 2 and _nc.get_noise_3d(float(x), float(y) * 1.4, float(z)) \
							> 0.52 - minf(float(36 - y) * 0.004, 0.12):
						id = Blocks.AIR
					elif id == Blocks.STONE:
						id = _ore_for(seed_v, x, y, z)
				elif y < s:
					id = Blocks.DIRT
				elif y == s:
					id = Blocks.BRICK if in_town else \
						(Blocks.GRASS if s >= WATER_LEVEL else Blocks.DIRT)
				elif y <= WATER_LEVEL and s < WATER_LEVEL and not in_town:
					id = Blocks.WATER  # flooded dell → lake
				data[(y * 16 + lz) * 16 + lx] = id
			# Cave dressing: herbs / glow / webs, denser as bands deepen.
			if not in_town:
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
					var th := 4 + int(_h01(seed_v, ax, 0, az, 5) * 3.0)
					if ax == x and az == z:
						for ty in range(ts + 1, mini(ts + th, H - 3)):
							data[(ty * 16 + lz) * 16 + lx] = Blocks.WOOD
					var canopy_y := ts + th
					for cy in range(canopy_y - 2, mini(canopy_y + 1, H - 1)):
						if absi(ax - x) + absi(az - z) + absi(cy - canopy_y) <= 3:
							var i2 := (cy * 16 + lz) * 16 + lx
							if data[i2] == Blocks.AIR:
								data[i2] = Blocks.LEAVES
	# Town furniture intersecting this column.
	if bx <= TOWN_R and bx + 15 >= -TOWN_R and bz <= TOWN_R and bz + 15 >= -TOWN_R:
		var feats := town_features()
		for p in feats:
			var v: Vector3i = p
			if v.x >= bx and v.x < bx + 16 and v.z >= bz and v.z < bz + 16:
				data[(v.y * 16 + (v.z - bz)) * 16 + (v.x - bx)] = feats[p]


static func _ore_for(seed_v: int, x: int, y: int, z: int) -> int:
	var r := _h01(seed_v, x, y, z, 3)
	if r < 0.010 and y < 34:
		return Blocks.COPPER_ORE
	if r < 0.016 and y < 26:
		return Blocks.IRON_ORE
	if r < 0.020 and y < 18:
		return Blocks.SILVER_ORE
	if r < 0.023 and y < 9:
		return Blocks.ADAMANT_ORE
	if r < 0.030 and y < 30:
		return Blocks.GOLD_ORE
	if r < 0.033 and y < 14:
		return Blocks.LUCKSTONE
	if r < 0.045:
		return Blocks.GRAVEL
	if r < 0.055 and y < 20:
		return Blocks.IRONWOOD_LOG
	return Blocks.STONE
