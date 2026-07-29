extends Node
## Regression for fluid lighting repairs spanning unrelated lava cells.
## Two changed sources thousands of blocks apart must trigger local repairs,
## not one world-sized bounding-box scan.


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

	# A large streamed queue must be split across deterministic beats instead
	# of monopolizing one frame. Out-of-range cells read as air and are erased.
	var budget_world := VoxelWorld.new()
	add_child(budget_world)
	for x in range(VoxelWorld.FLUID_STEP_BUDGET + 1):
		budget_world.fluid_cells[Vector3i(x, VoxelWorld.H, 0)] = true
	budget_world.fluid_step()
	if budget_world.fluid_cells.size() != 1:
		passed = false
		printerr("FLUID LIGHT FAIL: fluid step exceeded its work budget")

	if passed:
		print("FLUID LIGHT PASS (%dms)" % elapsed)
		get_tree().quit(0)
	else:
		get_tree().quit(1)
