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
static func build(vw, origin: Vector3i, size: int) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
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
					var col: Color = def.color * shade
					col.a = 1.0
					var base := verts.size()
					for v in f.v:
						verts.append(Vector3(lp) + v)
						normals.append(Vector3(f.n))
						colors.append(col)
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

	var out := {"mesh": null, "faces": col_faces}
	if verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, Blocks.material())
		out.mesh = mesh
	return out
