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
			_damage_enemies_near(g, target, r + 1.0, power * 12,
				"fire" if meta.get("element", "") == "ember" else "physical",
				"burn" if meta.get("element", "") == "ember" else "", 2, pid)
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
			_damage_enemies_near(g, target, 2.5 + power, power * 8, "fire", "burn", 3, pid)
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
			rec2.injuries = {}  # true healing magic cures every wound
			g.send_to(pid, "cl_notify", ["Golden light seals your wounds (+%d HP, injuries cured)." % heal])
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
		"tunnel":
			# Melt a corridor straight through the wall you're facing.
			var tn = g.world.get_player(pid)
			if tn == null:
				return
			var tdir: Vector3 = (target - tn.global_position)
			tdir.y = 0
			tdir = tdir.normalized() if tdir.length() > 0.1 else Vector3.FORWARD
			var td := [int(round(tdir.x)), 0, int(round(tdir.z))]
			if td[0] == 0 and td[2] == 0:
				td[0] = 1
			var tstart: Vector3 = tn.global_position + Vector3(td[0], 0, td[2])
			for dy in range(0, 2):
				g._apply_edit({"t": "line", "p": [int(floor(tstart.x)), int(floor(tstart.y)) + dy, int(floor(tstart.z))],
					"d": td, "len": 3 + power * 2, "b": Blocks.AIR})
			g.send_to(pid, "cl_notify", ["The stone sighs and melts open before you."])
		"elem_wall":
			# A defensive wall rises at the target, perpendicular to your aim:
			# fire wall, ice wall, vine wall, obsidian wall, or golden wall.
			var wn = g.world.get_player(pid)
			if wn == null:
				return
			var wdir: Vector3 = (target - wn.global_position)
			var perp := [0, 0, 1] if absf(wdir.x) >= absf(wdir.z) else [1, 0, 0]
			var wall_block: int = {"ember": Blocks.LAVA, "frost": Blocks.ICE,
				"verdant": Blocks.VINE, "void": Blocks.OBSIDIAN,
				"gilded": Blocks.GOLD_BLOCK}.get(String(meta.get("element", "frost")), Blocks.ICE)
			var half := 1 + power / 2
			for i in range(-half, half + 1):
				g._apply_edit({"t": "column", "p": [p[0] + perp[0] * i, p[1], p[2] + perp[2] * i],
					"h": 2, "b": wall_block})
			if wall_block == Blocks.LAVA:
				_damage_enemies_near(g, target, 2.0 + half, power * 6, "fire", "burn", 2, pid)
			g.send_to(pid, "cl_notify", ["A wall of %s roars up from the ground!" % Blocks.get_def(wall_block).name.to_lower()])
		"invisibility":
			g.players[pid].buffs.append({"k": "invis", "amt": 1,
				"until": Time.get_ticks_msec() + (20000 + power * 10000)})
			g._sync_player(pid)
			g.send_to(pid, "cl_notify", ["You fade from sight — stalkers lose your scent."])
		"phase":
			# Ghoststep: pass through the wall ahead into the first air pocket.
			var gn = g.world.get_player(pid)
			if gn == null:
				return
			var gdir: Vector3 = (target - gn.global_position)
			gdir.y = 0
			gdir = gdir.normalized() if gdir.length() > 0.1 else Vector3.FORWARD
			var base_c := Vector3i((gn.global_position + Vector3(0, 0.5, 0)).floor())
			for step in range(2, 6 + power):
				var c := base_c + Vector3i(round(gdir.x * step), 0, round(gdir.z * step))
				if not Blocks.is_solid(g.voxel.get_block_v(c)) \
						and not Blocks.is_solid(g.voxel.get_block_v(c + Vector3i(0, 1, 0))):
					g.rpc("cl_teleport", pid, Vector3(c) + Vector3(0.5, 0.2, 0.5))
					g.send_to(pid, "cl_notify", ["You step INTO the stone — and out the far side."])
					return
			g.send_to(pid, "cl_notify", ["The stone is too thick to ghost through here."])
		"resurrect":
			# Restore a recently-fallen ally: pull them to you, mend them,
			# refund what the reaper took.
			var best_pid := -1
			var now := Time.get_ticks_msec()
			for opid in g.players:
				var d: Dictionary = g.last_deaths.get(opid, {})
				if opid != pid and not d.is_empty() and now - int(d.t) < 120000:
					best_pid = opid
			if best_pid < 0:
				g.send_to(pid, "cl_notify", ["No fallen soul lingers near enough to call back."])
				return
			var fallen: Dictionary = g.players[best_pid]
			fallen.hp = int(fallen.max_hp)
			fallen.gold = int(fallen.gold) + int(g.last_deaths[best_pid].gold)
			g.last_deaths.erase(best_pid)
			var caster = g.world.get_player(pid)
			if caster != null:
				g.rpc("cl_teleport", best_pid, caster.global_position + Vector3(1, 0.5, 0))
			g._sync_player(best_pid)
			g.rpc("cl_notify", "%s calls %s back from the dark — whole, and repaid." %
				[g.players[pid].name, fallen.name])
	# Real-time combat tricks: casting at (or near) a foe applies the spell's
	# battle effect directly — smite burns, chill freezes, hex saps.
	var combat := String(meta.get("combat", ""))
	if combat != "":
		for eid in g.enemies:
			var ce: Dictionary = g.enemies[eid]
			if not ce.alive or Vector3(ce.pos).distance_to(target) > 3.0:
				continue
			match combat:
				"smite":
					var sdmg := 0
					for i in range(power + 1):
						sdmg += randi_range(1, 6)
					ce.hp = int(ce.hp) - sdmg
					g._enemy_status(ce, "burn", 2)
					g.rpc("cl_hit_fx", eid, sdmg, "")
					if int(ce.hp) <= 0:
						g.enemy_defeated(eid, pid)
				"chill":
					g._enemy_status(ce, "sleep", 2)
					g.rpc("cl_notify", "%s is frozen in place!" % ce.name)
				"hex":
					ce.atk = maxi(int(ce.atk) - 2, 0)
					g.rpc("cl_notify", "%s is hexed — its blows weaken." % ce.name)
			break
		if combat == "mend":
			var mrec: Dictionary = g.players[pid]
			mrec.hp = mini(int(mrec.hp) + 8 * (power + 1), int(mrec.max_hp))
		elif combat == "fortune":
			g.players[pid].buffs.append({"k": "luck", "amt": 20,
				"until": Time.get_ticks_msec() + 30000})
		g._sync_player(pid)
	# Cursed spells bite back sometimes.
	if bool(meta.get("cursed", false)) and randf() < 0.25:
		g.hurt_player(pid, 8, "a Fiend's Pact")
		g.send_to(pid, "cl_notify", ["The pact collects its due. (-8 HP)"])


## Area damage honoring resist/weak, optional status infliction, and the
## friendly-fire lobby setting (allies caught in the blast take half).
static func _damage_enemies_near(g, at: Vector3, radius: float, dmg: int,
		tag := "physical", status := "", turns := 0, caster := -1) -> void:
	# Your own blast doesn't care whose fingers lit it: the caster always
	# takes half if caught in the radius (allies only with friendly fire on).
	if caster >= 0:
		var cn = g.world.get_player(caster)
		if cn != null and cn.global_position.distance_to(at) <= radius:
			g.hurt_player(caster, maxi(1, dmg / 2), "your own blast")
	for eid in g.enemies:
		var e: Dictionary = g.enemies[eid]
		if not e.alive or e.in_combat or Vector3(e.pos).distance_to(at) > radius:
			continue
		var def: Dictionary = Db.ENEMIES[e.type]
		var final := dmg
		if tag in def.get("resist", []):
			final = maxi(1, dmg / 2)
		elif tag in def.get("weak", []):
			final = int(dmg * 1.5)
		if status != "" and not ((status == "burn" and "fire" in def.get("resist", []))
				or (status == "poison" and "poison" in def.get("resist", []))):
			if not e.has("status"):
				e["status"] = {}
			e.status[status] = maxi(int(e.status.get(status, 0)), turns)
		e.hp -= final
		if e.hp <= 0:
			# Credit whoever cast it. This was hardcoded to peer 1, so in
			# multiplayer the HOST collected the XP, proficiency, kill-quest
			# progress, gold and loot for every client's blast kill.
			g.enemy_defeated(eid, caster if caster >= 0 else 1)
		else:
			g.rpc("cl_notify", "%s reels from the blast!" % e.get("name", "Something"))
	if g.friendly_fire:
		for opid in g.players:
			var pn = g.world.get_player(opid)
			if pn != null and pn.global_position.distance_to(at) <= radius:
				g.hurt_player(opid, maxi(1, dmg / 2), "friendly fire")


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
				# Healing knits one wound.
				var inj: Dictionary = rec.get("injuries", {})
				if not inj.is_empty():
					var slot: String = inj.keys()[0]
					inj.erase(slot)
					g.send_to(pid, "cl_notify", ["Your %s mends." % slot])
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
				_damage_enemies_near(g, target, r + 1.0, pot * 8, "poison", "poison", 2, pid)
				g.rpc("cl_notify", "Glass shatters — the walls dissolve!")
			"smoke":
				g.spawn_gas_cloud(target, 1.5 + pot * 0.4, Blocks.SMOKE_3, true)
				g.rpc("cl_notify", "A smoke bomb blooms — eyes lose you in the haze.")
			"toxic":
				g.spawn_gas_cloud(target, 1.0 + pot * 0.4, Blocks.GAS_POISON_2)
				_damage_enemies_near(g, target, 2.0 + pot * 0.4, pot * 4, "physical", "", 0, pid)
				g.rpc("cl_notify", "Green vapor hisses out of the shattered flask.")
			_:
				# Benign effects still work on yourself if thrown at your feet.
				var node = g.world.get_player(pid)
				if node != null and node.global_position.distance_to(target) < 3.0:
					drink(g, pid, {"effects": [e]})
