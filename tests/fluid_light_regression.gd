extends Node
## Regressions that keep fluid_step()'s cost proportional to actual fluid
## activity rather than to world size:
##   1. Two changed lava sources thousands of blocks apart must trigger local
##      light repairs, not one world-sized bounding-box scan.
##   2. Generating terrain must queue no fluid work at all — generated oceans
##      and lava lakes are already in equilibrium.
## Prints "FLUID LIGHT PASS" and exits 0.


func _ready() -> void:
	var world := VoxelWorld.new()
	world.world_seed = 424242
	add_child(world)

	var cells := [
		Vector3i(8, 80, 8),
		Vector3i(4104, 80, 4104),
	]
	for cell in cells:
		world.set_block(cell.x, cell.y, cell.z, Blocks.AIR, false)
		world.set_block(cell.x, cell.y - 1, cell.z, Blocks.AIR, false)
		world.set_block(cell.x, cell.y, cell.z, Blocks.LAVA, false)
	world.fluid_cells.clear()
	for cell in cells:
		world.fluid_cells[cell] = true

	# Lava advances every other deterministic fluid step.
	world.fluid_step()
	var started := Time.get_ticks_msec()
	world.fluid_step()
	var elapsed := Time.get_ticks_msec() - started

	var passed := true
	for cell in cells:
		if Blocks.fluid_kind(world.get_block(cell.x, cell.y - 1, cell.z)) != "lava":
			passed = false
			printerr("FLUID LIGHT FAIL: distant lava did not flow")
		if world.light_at(cell.x, cell.y - 1, cell.z) < 14:
			passed = false
			printerr("FLUID LIGHT FAIL: light did not follow lava across a bucket edge")
	if elapsed > 15000:
		passed = false
		printerr("FLUID LIGHT FAIL: local repairs took %dms" % elapsed)

	# Generating terrain must not queue any fluid work. WorldGen places oceans
	# and lava lakes in equilibrium, so waking them only made every fluid beat
	# scan tens of thousands of permanently stable cells — and each edge cell's
	# neighbour lookup generated further columns, which queued yet more cells.
	# Disturbances arrive through set_block(), which wakes what it touches.
	var gen_world := VoxelWorld.new()
	gen_world.world_seed = 424242
	add_child(gen_world)
	var generated_fluid := false
	for cx in range(-8, 9):
		for cz in range(-8, 9):
			var col := gen_world.ensure_column(Vector2i(cx, cz))
			if generated_fluid:
				continue
			var data: PackedByteArray = col.data
			for i in range(0, data.size(), 16):
				if Blocks.fluid_kind(data[i]) != "":
					generated_fluid = true
					break
	if not generated_fluid:
		passed = false
		printerr("FLUID LIGHT FAIL: sample generated no fluid, so the check below is vacuous")
	elif not gen_world.fluid_cells.is_empty():
		passed = false
		printerr("FLUID LIGHT FAIL: generating terrain queued %d settled fluid cells"
			% gen_world.fluid_cells.size())

	if passed:
		print("FLUID LIGHT PASS (%dms)" % elapsed)
		get_tree().quit(0)
	else:
		get_tree().quit(1)
