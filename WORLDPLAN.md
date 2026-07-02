# Infinite World Migration Plan (branch: infinite-world)

Goal: **Minecraft × D&D infinite dungeon.** Seamless, unbounded X/Z, deep Y,
no portal-gated floors. Everything else (mobs, crafting, combat, towns,
economy) carries over unchanged.

## Architecture

1. **Storage**: `VoxelWorld.data` (fixed array) → `columns: {Vector2i: PackedByteArray}`,
   one 16×128×16 column per key. `get_block/set_block` route through columns;
   missing column ⇒ generate on demand (deterministic from `hash(seed, cx, cz)`).
2. **Generation** (per column, no global structures): layered noise caves +
   room-blob features seeded per column; surface at y≈96 holds the town region
   (spawn columns get the Gilded Refuge prefab); **depth bands replace floors**
   — biome/difficulty/music keyed to y (delve → caverns → lakes → crypt →
   molten as you dig), boss lairs as rare deep features. Cross-column features
   (corridors) use neighbor-deterministic stitching (hash both columns).
3. **Streaming**: each peer keeps columns within radius R (~6) of any player;
   server ticks entities only in loaded columns; unload beyond R+2 (edits
   preserved via the log). Light + mesh per column, built on load (worker
   arrays, main-thread meshes — already done).
4. **Replication/saves — unchanged in spirit**: ops carry absolute coords and
   replay over deterministic gen. Op log grows unbounded → shard the log by
   column key (`edits: {Vector2i: []}`); late joiners fetch only the columns
   they load. Saves = seed + sharded logs + entity/waystone/chest registries.
5. **Fluids/light/traps/crops/camps**: already absolute-coordinate systems;
   active sets survive; light BFS becomes per-column with 1-column border.
6. **Progression mapping**: `floor_num` → `depth_band(y)` everywhere it scales
   difficulty/loot/music. Portals removed from gen; waystones become the
   fast-travel network. `descend` = dig.
7. **Map**: the new player-centered window already pans; add zoom levels.

## Order of work
storage+gen → streaming/tick gating → sharded logs + late join → depth bands
replace floor_num → town prefab at surface → tests (extend smoke: dig 200
blocks out, verify determinism across two peers) → perf pass.
