class_name EffectExec
extends RefCounted
## Server-side executor: turns spell/potion metas into voxel ops, buffs,
## direct damage, and loot. All world changes go through Game._apply_edit so
## they hit the replicated edit log.


# ---------------------------------------------------------------- spells

static func cast(g, pid: int, meta: Dictionary, target: Vector3) -> void:
	var power := int(meta.get("power", 1))
	var p := [int(floor(target.x)), int(floor(target.y)), int(floor(target.z))]
	match String(meta.effect):
		"explode":
			var r := 1.5 + power * 0.8
			g._apply_edit({"t": "sphere", "p": p, "r": r, "b": Blocks.AIR})
			_damage_enemies_near(g, target, r + 1.0, power * 12)
			g.rpc("cl_notify", "%s detonates %s!" % [g.players[pid].name, meta.name])
			if meta.get("loot_rain", false):
				var rng := RandomNumberGenerator.new()
				rng.randomize()
				for i in range(2 + power):
					g.server_spawn_pickup(target + Vector3(rng.randf_range(-2, 2), 1.5, rng.randf_range(-2, 2)),
						{"id": "gold_dust", "count": 1, "meta": {}})
		"transmute_gold":
			g._apply_edit({"t": "sphere_replace", "p": p, "r": 1.0 + power * 0.7,
				"from": [Blocks.STONE, Blocks.DIRT, Blocks.BRICK], "b": Blocks.GOLD_ORE})
			g.send_to(pid, "cl_notify", ["Stone blushes gold."])
		"ice_path":
			var node = g.world.get_player(pid)
			if node == null:
				return
			var dir: Vector3 = (target - node.global_position)
			dir.y = 0
			dir = dir.normalized() if dir.length() > 0.1 else Vector3.FORWARD
			var d := [int(round(dir.x)), 0, int(round(dir.z))]
			if d[0] == 0 and d[2] == 0:
				d[0] = 1
			var start: Vector3 = node.global_position + Vector3(d[0], -1.2, d[2])
			g._apply_edit({"t": "line", "p": [int(floor(start.x)), int(floor(start.y)), int(floor(start.z))],
				"d": d, "len": 4 + power * 2, "b": Blocks.ICE})
			# Frost also quenches lava (all flow levels) it crosses.
			g._apply_edit({"t": "sphere_replace", "p": p, "r": 2.0 + power,
				"from": [Blocks.LAVA, Blocks.LAVA_F2, Blocks.LAVA_F1], "b": Blocks.OBSIDIAN})
		"vines":
			g._apply_edit({"t": "column", "p": p, "h": 3 + power * 2, "b": Blocks.VINE})
		"lava_burst":
			g._apply_edit({"t": "sphere", "p": p, "r": 1.0 + power * 0.4, "b": Blocks.LAVA})
			_damage_enemies_near(g, target, 2.5 + power, power * 8)
		"teleport":
			# Clear headroom, then blink.
			g._apply_edit({"t": "set", "p": [p[0], p[1] + 1, p[2]], "b": Blocks.AIR})
			g._apply_edit({"t": "set", "p": [p[0], p[1] + 2, p[2]], "b": Blocks.AIR})
			g.rpc("cl_teleport", pid, target + Vector3(0.5, 1.6, 0.5))
			g.send_to(pid, "cl_notify", ["Reality shuffles you elsewhere."])
		"luck_buff":
			var amt: int = 8 + power * 6
			var until := Time.get_ticks_msec() + 45000
			if meta.get("aoe", false):
				# Bard song: everyone within earshot shares the fortune.
				var caster = g.world.get_player(pid)
				for opid in g.players:
					var op = g.world.get_player(opid)
					if op != null and caster != null and op.global_position.distance_to(caster.global_position) < 10.0:
						g.players[opid].buffs.append({"k": "luck", "amt": amt, "until": until})
						g._sync_player(opid)
				g.rpc("cl_notify", "%s plays Fortune's Tune — the party glimmers (+%d luck)." % [g.players[pid].name, amt])
			else:
				g.players[pid].buffs.append({"k": "luck", "amt": amt, "until": until})
				g.send_to(pid, "cl_notify", ["Fortune leans in (+%d luck, 45s)." % amt])
			if meta.get("gills", false):
				g.players[pid].buffs.append({"k": "gills", "amt": 1, "until": Time.get_ticks_msec() + 90000})
				g.send_to(pid, "cl_notify", ["The tide accepts you — breathe freely underwater (90s)."])
		"mend":
			var rec2: Dictionary = g.players[pid]
			var heal: int = 10 * (power + 1)
			rec2.hp = mini(int(rec2.hp) + heal, int(rec2.max_hp))
			g.send_to(pid, "cl_notify", ["Golden light seals your wounds (+%d HP)." % heal])
		"smoke_cloud":
			# Element flavors the cloud: void = sleep gas, ember = poison fumes.
			var gas := Blocks.SMOKE_3
			match String(meta.get("element", "")):
				"void":
					gas = Blocks.GAS_SLEEP_2
				"ember":
					gas = Blocks.GAS_POISON_2
			g.spawn_gas_cloud(target, 1.5 + power * 0.5, gas)
			g.send_to(pid, "cl_notify", ["The %s blooms and billows." % meta.name])
		"glyph_trap":
			g._apply_edit({"t": "set", "p": p, "b": Blocks.RUNE_TRAP})
			g.send_to(pid, "cl_notify", ["A blast glyph settles into the stone — anything that treads on it regrets it."])
	# Cursed spells bite back sometimes.
	if bool(meta.get("cursed", false)) and randf() < 0.25:
		g.hurt_player(pid, 8, "a Fiend's Pact")
		g.send_to(pid, "cl_notify", ["The pact collects its due. (-8 HP)"])


static func _damage_enemies_near(g, at: Vector3, radius: float, dmg: int) -> void:
	for eid in g.enemies:
		var e: Dictionary = g.enemies[eid]
		if e.alive and not e.in_combat and Vector3(e.pos).distance_to(at) <= radius:
			e.hp -= dmg
			if e.hp <= 0:
				g.enemy_defeated(eid, 1)
			else:
				g.rpc("cl_notify", "%s reels from the blast!" % e.get("name", "Something"))


# ---------------------------------------------------------------- potions

static func drink(g, pid: int, meta: Dictionary) -> void:
	var rec: Dictionary = g.players[pid]
	var now := Time.get_ticks_msec()
	for e in meta.get("effects", []):
		var pot := int(e.potency)
		match String(e.prop):
			"heal":
				rec.hp = mini(int(rec.hp) + pot * 8, int(rec.max_hp))
				g.send_to(pid, "cl_notify", ["Warmth spreads (+%d HP)." % (pot * 8)])
			"luck":
				rec.buffs.append({"k": "luck", "amt": pot * 5, "until": now + 60000})
				g.send_to(pid, "cl_notify", ["Odds tilt your way (+%d luck, 60s)." % (pot * 5)])
			"stone":
				rec.buffs.append({"k": "stone", "amt": 1, "until": now + 10000})
				g.send_to(pid, "cl_notify", ["Your skin turns to living stone (10s)."])
			"swift":
				rec.buffs.append({"k": "swift", "amt": pot, "until": now + 30000})
				g.send_to(pid, "cl_notify", ["Quicksilver in your veins (30s)."])
			"toxic":
				rec.buffs.append({"k": "luck", "amt": pot * 8, "until": now + 45000})
				g.hurt_player(pid, 5, "a risk tonic")
				g.send_to(pid, "cl_notify", ["It burns beautifully (+%d luck, -5 HP)." % (pot * 8)])
			"volatile":
				g.hurt_player(pid, pot * 3, "drinking a solvent")
				g.send_to(pid, "cl_notify", ["You DRANK the solvent?!"])
			"gills":
				rec.buffs.append({"k": "gills", "amt": 1, "until": now + 120000})
				g.send_to(pid, "cl_notify", ["Gills flutter at your neck — breathe underwater (120s)."])


static func throw_potion(g, pid: int, meta: Dictionary, target: Vector3) -> void:
	var p := [int(floor(target.x)), int(floor(target.y)), int(floor(target.z))]
	for e in meta.get("effects", []):
		var pot := int(e.potency)
		match String(e.prop):
			"volatile":
				var r := 1.0 + pot * 0.5
				g._apply_edit({"t": "sphere", "p": p, "r": r, "b": Blocks.AIR})
				# Potent solvents leave live acid that keeps flowing and eating.
				if pot >= 3:
					g._apply_edit({"t": "set", "p": p, "b": Blocks.ACID})
				_damage_enemies_near(g, target, r + 1.0, pot * 8)
				g.rpc("cl_notify", "Glass shatters — the walls dissolve!")
			"smoke":
				g.spawn_gas_cloud(target, 1.5 + pot * 0.4, Blocks.SMOKE_3, true)
				g.rpc("cl_notify", "A smoke bomb blooms — eyes lose you in the haze.")
			"toxic":
				g.spawn_gas_cloud(target, 1.0 + pot * 0.4, Blocks.GAS_POISON_2)
				_damage_enemies_near(g, target, 2.0 + pot * 0.4, pot * 4)
				g.rpc("cl_notify", "Green vapor hisses out of the shattered flask.")
			_:
				# Benign effects still work on yourself if thrown at your feet.
				var node = g.world.get_player(pid)
				if node != null and node.global_position.distance_to(target) < 3.0:
					drink(g, pid, {"effects": [e]})
