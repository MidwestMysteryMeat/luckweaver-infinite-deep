class_name Mesher
extends RefCounted
## Builds one chunk's render mesh + collision faces from VoxelWorld data.
## Face culling against opaque neighbors; directional shading baked into vertex
## colors (material is unshaded, cull disabled — winding order irrelevant).

const FACES := [
	{"n": Vector3i(0, 1, 0), "shade": 1.0,
		"v": [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]},
	{"n": Vector3i(0, -1, 0), "shade": 0.45,
		"v": [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0)]},
	{"n": Vector3i(1, 0, 0), "shade": 0.72,
		"v": [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)]},
	{"n": Vector3i(-1, 0, 0), "shade": 0.72,
		"v": [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(0, 0, 1)]},
	{"n": Vector3i(0, 0, 1), "shade": 0.6,
		"v": [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 0, 1)]},
	{"n": Vector3i(0, 0, -1), "shade": 0.6,
		"v": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]},
]


## Returns {"mesh": ArrayMesh or null, "faces": PackedVector3Array (collision triangles)}
## Two surfaces: opaque, then translucent (fluids, gases, webs — Blocks.ALPHA).
static func build(vw, origin: Vector3i, size: int) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var t_verts := PackedVector3Array()
	var t_normals := PackedVector3Array()
	var t_colors := PackedColorArray()
	var t_uvs := PackedVector2Array()
	var t_indices := PackedInt32Array()
	var col_faces := PackedVector3Array()

	for x in range(size):
		for y in range(size):
			for z in range(size):
				var lp := Vector3i(x, y, z)
				var wp: Vector3i = origin + lp
				var id: int = vw.get_block_v(wp)
				if id == Blocks.AIR:
					continue
				var def: Dictionary = Blocks.get_def(id)
				for f in FACES:
					var np: Vector3i = wp + f.n
					var nid: int = vw.get_block_v(np)
					if nid == id:
						continue
					if Blocks.get_def(nid).opaque:
						continue
					var shade: float = f.shade
					# Minecraft-style block light: faces are lit by the cell
					# they face into; glow blocks are always full-bright.
					if def.glow:
						shade = maxf(shade, 0.95)
					else:
						var lv: float = float(vw.light_at(np.x, np.y, np.z)) / 15.0
						shade *= 0.16 + 0.84 * lv
					# Pixel atlas carries the block's color; the vertex color is
					# pure light/shade multiplied on top (Minecraft-style).
					var col := Color(shade, shade, shade, 1.0)
					var rect := Blocks.tile_uv(id)
					var fuv := [Vector2(rect.position.x, rect.end.y), rect.position,
						Vector2(rect.end.x, rect.position.y), rect.end]
					var alpha: float = Blocks.ALPHA.get(id, 1.0)
					if alpha < 1.0:
						col.a = alpha
						var tb := t_verts.size()
						for vi in range(4):
							t_verts.append(Vector3(lp) + f.v[vi])
							t_normals.append(Vector3(f.n))
							t_colors.append(col)
							t_uvs.append(fuv[vi])
						t_indices.append_array(PackedInt32Array([
							tb, tb + 1, tb + 2, tb, tb + 2, tb + 3]))
					else:
						var base := verts.size()
						for vi in range(4):
							verts.append(Vector3(lp) + f.v[vi])
							normals.append(Vector3(f.n))
							colors.append(col)
							uvs.append(fuv[vi])
						indices.append_array(PackedInt32Array([
							base, base + 1, base + 2, base, base + 2, base + 3]))
					if def.solid:
						var fv: Array = f.v
						col_faces.append(Vector3(lp) + fv[0])
						col_faces.append(Vector3(lp) + fv[1])
						col_faces.append(Vector3(lp) + fv[2])
						col_faces.append(Vector3(lp) + fv[0])
						col_faces.append(Vector3(lp) + fv[2])
						col_faces.append(Vector3(lp) + fv[3])

	# THREAD SAFETY: build() runs on worker threads, so it only assembles raw
	# arrays. make_mesh() turns them into GPU resources on the MAIN thread —
	# creating meshes/materials off-thread crashes the real Vulkan renderer
	# (the headless test renderer never noticed).
	var out := {"arrays": null, "t_arrays": null, "faces": col_faces}
	if verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = indices
		out.arrays = arrays
	if t_verts.size() > 0:
		var t_arrays := []
		t_arrays.resize(Mesh.ARRAY_MAX)
		t_arrays[Mesh.ARRAY_VERTEX] = t_verts
		t_arrays[Mesh.ARRAY_NORMAL] = t_normals
		t_arrays[Mesh.ARRAY_COLOR] = t_colors
		t_arrays[Mesh.ARRAY_TEX_UV] = t_uvs
		t_arrays[Mesh.ARRAY_INDEX] = t_indices
		out.t_arrays = t_arrays
	return out


## MAIN THREAD ONLY: raw arrays → ArrayMesh with materials.
static func make_mesh(built: Dictionary) -> ArrayMesh:
	if built.arrays == null and built.t_arrays == null:
		return null
	var mesh := ArrayMesh.new()
	if built.arrays != null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built.arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Blocks.material())
	if built.t_arrays != null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built.t_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Blocks.material_translucent())
	return mesh
