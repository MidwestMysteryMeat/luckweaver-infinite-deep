class_name Encounter
extends RefCounted
## Turn-based fantasy combat, D&D style, server-side only. The client renders
## the state dict and returns action ids; every roll happens here.
##
## Dice rules:
##  - Initiative: d20 + luck/10 each; loser gets swung on first.
##  - Attack: d20 + atk bonus vs AC. Nat 20 = crit (double dice, + Soul Strike).
##    Nat 1 = fumble (free counter jab). Luck procs advantage (roll twice, keep
##    high) and widens the crit range (19+ at 40 luck, 18+ at 70).
##  - Loaded Dice passive: one automatic reroll of a missed attack per battle.
##  - Defend: +4 AC until your next turn.
##  - Enemy specials (multiattack, poison, luck drain, gold steal, self-heal,
##    curse) roll on their own chance each enemy turn.
##  - Boss: phases at 2/3 and 1/3 HP — hits harder, specials more often.

var g  # Game autoload (server)
var pid: int
var eid: int
var phase := "player"    # player | done
var lines: Array = []
var rolls: Array = []    # recent dice results for the UI, newest last
var rng := RandomNumberGenerator.new()
var over := false

# battle state
var sneak := false           # set by Game: smoke-shrouded or long-range opener
var opened_ranged := false   # fight opened with a bow shot
var ac_shred := 0            # Black Pudding corrodes your armor
var defend_ac := 0
var luck_bonus := 0          # from Fortune spells this battle
var player_adv := false      # next attack has advantage (hex)
var player_disadv := false   # cursed: next attack disadvantage
var enemy_stunned := false   # chill: enemy skips next turn
var enemy_atk_down := 0
var poison_turns := 0
var reroll_used := false
var boss_phase := 1


func _init(game_ref, player_id: int, enemy_id: int) -> void:
	g = game_ref
	pid = player_id
	eid = enemy_id
	rng.randomize()


func rec() -> Dictionary:
	return g.players[pid]


func e() -> Dictionary:
	return g.enemies[eid]


func luck() -> int:
	return clampi(g.eff_luck(rec()) + luck_bonus, 0, 90)


func _say(t: String) -> void:
	lines.append(t)
	if lines.size() > 10:
		lines.pop_front()


func _roll_note(who: String, dice: Array, bonus: int, vs: int, txt: String) -> void:
	rolls.append({"who": who, "dice": dice, "bonus": bonus,
		"total": dice.max() + bonus, "vs": vs, "txt": txt})
	if rolls.size() > 2:
		rolls.pop_front()


# ---------------------------------------------------------------- stats

func _d(n: int, die: int, bonus: int) -> int:
	var total := bonus
	for i in range(n):
		total += rng.randi_range(1, die)
	return total


## Best average-damage weapon anywhere in the satchel (def + entry meta for
## smith quality / enchants); {} = unarmed.
func _best_weapon() -> Dictionary:
	var best := {}
	var best_avg := -1.0
	for entry in rec().inv:
		if entry == null or Db.item_def(entry.id).kind != "weapon":
			continue
		var def: Dictionary = Db.item_def(entry.id)
		var meta: Dictionary = entry.get("meta", {})
		var avg: float = def.dmg[0] * (def.dmg[1] + 1) * 0.5 + def.dmg[2] \
			+ int(meta.get("quality", 0)) + int(meta.get("epow", 0)) * 2
		if avg > best_avg:
			best_avg = avg
			best = {"def": def, "meta": meta}
	return best


func _atk_bonus() -> int:
	var c: Dictionary = Db.CLASSES[rec().class_id]
	var w := _best_weapon()
	var watk: int = int(w.def.get("atk", 0)) if not w.is_empty() else 0
	var b: int = int(c.atk) + int(rec().level) / 2 + watk \
		+ int(rec().get("atk_perm", 0)) + Db.prof_eff(rec(), "combat") / 8
	if rec().get("injuries", {}).has("arms"):
		b -= 2
	for buff in rec().buffs:
		if buff.k == "atk":
			b += int(buff.amt)
	return b


func _dmg_dice() -> Array:
	var w := _best_weapon()
	if w.is_empty():
		return Db.CLASSES[rec().class_id].dmg
	var d: Array = w.def.dmg.duplicate()
	d[2] = int(d[2]) + int(w.meta.get("quality", 0))
	return d


func _player_ac() -> int:
	var armor: Dictionary = g.armor_of(rec())
	var ac: int = 10 + int(Db.CLASSES[rec().class_id].def) + defend_ac \
		+ int(rec().get("ac_perm", 0)) + int(armor.ac) - ac_shred \
		+ int(armor.ench.get("ember", 0))  # Bulwark enchant
	if rec().get("injuries", {}).has("body"):
		ac -= 1
	for b in rec().buffs:
		if b.k == "stone":
			ac += 6
		elif b.k == "ac":
			ac += int(b.amt)
	return ac


func _crit_floor() -> int:
	if luck() >= 70:
		return 18
	if luck() >= 40:
		return 19
	return 20


func _insight() -> bool:
	return rec().passives.has("insight") or rec().mutations.has("third_eye")


# ---------------------------------------------------------------- flow

var npc := false             # neutral parley mode (talk / trade / rob)
var npc_offer := {}          # current trade offer {"id", "price"}

const NPC_LINES := [
	"\"Watch the slimes past the third torch. They hum before they lunge.\"",
	"\"I buried a friend on floor five. The dark took him.\"",
	"\"Fortune favors the armed. And the fed. Mostly the fed.\"",
	"\"The Vault Tyrant cheats. Obviously. So should you.\"",
	"\"Locked doors mean somebody's savings. Just saying.\"",
	"\"Kelp. Chew it before you dive. Trust me.\"",
	"\"An anvil and enough hide will outlive any blade you buy.\"",
]


func start() -> void:
	if String(e().get("disp", "hostile")) == "neutral":
		npc = true
		phase = "npc"
		_say("%s eyes you warily. \"Easy now, Luckweaver.\"" % e().name)
		_push()
		return
	_begin_combat()


func _begin_combat() -> void:
	npc = false
	_say("%s blocks your path!" % e().name)
	# Sneak attack: a free opening strike with advantage and doubled dice,
	# before initiative is even rolled.
	if sneak:
		phase = "player"
		var dd := _bow_dice() if opened_ranged else _dmg_dice()
		var dmg := _d(int(dd[0]) * 2, int(dd[1]), int(dd[2]))
		_say("SNEAK ATTACK! Your %s finds them utterly unaware — %d damage!" %
			["arrow" if opened_ranged else "blade", dmg])
		_damage_enemy(dmg)
		if over:
			return
	elif opened_ranged:
		var dd2 := _bow_dice()
		var dmg2 := _d(int(dd2[0]), int(dd2[1]), int(dd2[2]))
		_say("Your arrow strikes first for %d!" % dmg2)
		phase = "player"
		_damage_enemy(dmg2)
		if over:
			return
	var pi := rng.randi_range(1, 20)
	var ei := rng.randi_range(1, 20)
	var p_init: int = pi + luck() / 10
	_say("Initiative — you: %d+%d=%d, foe: %d." % [pi, luck() / 10, p_init, ei])
	if ei > p_init:
		_say("%s moves first!" % e().name)
		phase = "player"
		_enemy_turn()
		if over:
			return
	else:
		_say("You seize the tempo. Your move.")
		phase = "player"
	_push()


func handle(action: String) -> void:
	if over:
		return
	if phase == "npc":
		_handle_npc(action)
		return
	if phase != "player":
		return
	if action.begins_with("spell:"):
		_cast(int(action.substr(6)))
		return
	if action.begins_with("potion:"):
		_quaff(int(action.substr(7)))
		return
	match action:
		"attack":
			_attack()
		"shoot":
			_shoot()
		"defend":
			defend_ac = 4
			_say("You raise your guard (+4 AC).")
			_end_player_turn()
		"flee":
			_flee()
		_:
			_push()


func _end_player_turn() -> void:
	if over:
		return
	_enemy_turn()
	if over:
		return
	phase = "player"
	_push()


# ---------------------------------------------------------------- npc parley

func _handle_npc(action: String) -> void:
	match action:
		"talk":
			_say(NPC_LINES[rng.randi_range(0, NPC_LINES.size() - 1)])
		"trade":
			var pool: Array = Db.ENEMIES[e().type].get("trades", ["luckroot"])
			var id: String = pool[rng.randi_range(0, pool.size() - 1)]
			var price := int(Db.item_def(id).value * 1.2) + rng.randi_range(0, 5)
			npc_offer = {"id": id, "price": price}
			_say("\"For you? My %s. %d gold.\"" % [Db.item_def(id).name, price])
		"buy":
			if npc_offer.is_empty():
				_say("\"Ask what I'm selling first.\"")
			elif int(rec().gold) < int(npc_offer.price):
				_say("\"Come back with real coin.\"")
			else:
				rec().gold = int(rec().gold) - int(npc_offer.price)
				g.give_item(pid, npc_offer.id, 1, {})
				_say("\"Pleasure doing business.\" (+1 %s)" % Db.item_def(npc_offer.id).name)
				npc_offer = {}
		"quest":
			# One active quest per player: kill N of a local menace, or gather
			# ingredients. Talk to any villager again to turn it in.
			var q: Dictionary = g.quests.get(pid, {})
			if q.is_empty():
				var kill_types: Array = []
				for t in Db.ENEMIES:
					var d2: Dictionary = Db.ENEMIES[t]
					if String(d2.get("disposition", "hostile")) == "hostile" and not d2.boss \
							and g.floor_num >= int(d2.min_floor) and int(d2.min_floor) < 99:
						kill_types.append(t)
				if rng.randf() < 0.6 and not kill_types.is_empty():
					var kt: String = kill_types[rng.randi_range(0, kill_types.size() - 1)]
					q = {"type": "kill", "target": kt, "n": rng.randi_range(2, 4), "done": 0,
						"reward": 60 + g.floor_num * 25}
					_say("\"%ss have been circling us. Cull %d and I'll pay %d gold.\"" %
						[Db.ENEMIES[kt].name, int(q.n), int(q.reward)])
				else:
					var wants := ["wheat", "hog_meat", "kelp", "luckroot", "bone"]
					q = {"type": "gather", "target": wants[rng.randi_range(0, wants.size() - 1)],
						"n": rng.randi_range(3, 5), "done": 0, "reward": 50 + g.floor_num * 20}
					_say("\"Bring me %d %s and %d gold is yours.\"" %
						[int(q.n), Db.item_def(q.target).name, int(q.reward)])
				g.quests[pid] = q
			elif q.type == "kill" and int(q.done) >= int(q.n):
				g.reward_gold(pid, int(q.reward))
				g.grant_xp(pid, int(q.reward) / 2)
				_say("\"You actually did it. The hamlet sleeps easier.\" (+%d gold)" % int(q.reward))
				g.quests.erase(pid)
			elif q.type == "gather" and g._count_of(rec(), String(q.target)) >= int(q.n):
				g._consume_id(rec(), String(q.target), int(q.n))
				g.reward_gold(pid, int(q.reward))
				g.grant_xp(pid, int(q.reward) / 2)
				_say("\"Fresh %s! Bless you.\" (+%d gold)" % [Db.item_def(q.target).name, int(q.reward)])
				g.quests.erase(pid)
			else:
				var need: String = Db.ENEMIES[q.target].name if q.type == "kill" else Db.item_def(q.target).name
				_say("\"Still waiting: %d/%d %s.\"" % [int(q.done) if q.type == "kill"
					else g._count_of(rec(), String(q.target)), int(q.n), need])
		"rob":
			# d20 + luck/10 vs d20 + their guard/2. Fail = they draw steel.
			var pd := rng.randi_range(1, 20)
			var ed := rng.randi_range(1, 20)
			var pt: int = pd + luck() / 10
			var et: int = ed + int(e().get("guard", 10)) / 2
			_roll_note("you", [pd], luck() / 10, et, "ROBBED!" if pt > et else "CAUGHT")
			if pt > et:
				var take := rng.randi_range(15, 35 + g.floor_num * 8)
				g.reward_gold(pid, take)
				_say("You roll %d vs %d — you lift %d gold and melt into the dark." % [pt, et, take])
				e().in_combat = false
				e().cooldown = 20.0
				_finish()
				return
			_say("You roll %d vs %d — caught red-handed! %s draws steel!" % [pt, et, e().name])
			e().disp = "hostile"
			_begin_combat()
			return
		"leave":
			_say("\"Safe roads, Luckweaver.\"")
			e().in_combat = false
			e().cooldown = 4.0
			_finish()
			return
	_push()


# ---------------------------------------------------------------- player attack

func _attack() -> void:
	defend_ac = 0
	var adv := player_adv
	player_adv = false
	if not adv and not player_disadv and rng.randf() * 100.0 < luck() * 0.4:
		adv = true
		_say("Fortune tilts the blade — advantage!")
	var dice := [rng.randi_range(1, 20)]
	if adv or player_disadv:
		dice.append(rng.randi_range(1, 20))
	var d20: int = dice.max() if not player_disadv else dice.min()
	if player_disadv:
		_say("The curse drags your arm (disadvantage).")
		player_disadv = false
	var bonus := _atk_bonus()
	var total := d20 + bonus

	if d20 == 1:
		_roll_note("you", dice, bonus, int(e().ac), "FUMBLE")
		_say("Natural 1! You stumble — %s jabs you as you recover." % e().name)
		_enemy_hit_player(true)
		_end_player_turn()
		return

	var crit := d20 >= _crit_floor()
	var hit := crit or total >= int(e().ac)
	if not hit and rec().passives.has("reroll") and not reroll_used:
		reroll_used = true
		_say("Loaded Dice! The miss tumbles back into your palm — reroll.")
		d20 = rng.randi_range(1, 20)
		dice = [d20]
		total = d20 + bonus
		crit = d20 >= _crit_floor()
		hit = crit or total >= int(e().ac)

	if not hit:
		_roll_note("you", dice, bonus, int(e().ac), "MISS")
		_say("You roll %d+%d=%d vs AC %d — miss." % [d20, bonus, total, int(e().ac)])
		_end_player_turn()
		return

	var dd := _dmg_dice()
	var n := int(dd[0]) * (2 if crit else 1)
	var dmg := _d(n, int(dd[1]), int(dd[2]))
	if crit:
		var soul := 1.0 + float(rec().passives.get("soul_strike", 0.0))
		dmg = int(dmg * soul)
		_roll_note("you", dice, bonus, int(e().ac), "CRIT!")
		_say("NATURAL %d — CRITICAL! %dd%d+%d smashes for %d!" % [d20, n, int(dd[1]), int(dd[2]), dmg])
	else:
		_roll_note("you", dice, bonus, int(e().ac), "HIT")
		_say("You roll %d+%d=%d vs AC %d — hit for %d." % [d20, bonus, total, int(e().ac), dmg])
	dmg += _weapon_enchant_on_hit()
	var w2 := _best_weapon()
	if not w2.is_empty() and String(w2.meta.get("ench", "")) == "ember":
		_apply_status("burn", 1)  # Flamebrand ignites
	_damage_enemy(dmg)
	if not over:
		_end_player_turn()


## Flamebrand burns, Souleater drinks, Frostbite freezes, Thornheart mends.
func _weapon_enchant_on_hit() -> int:
	var w := _best_weapon()
	if w.is_empty() or not w.meta.has("ench"):
		return 0
	var pow_ := int(w.meta.get("epow", 1))
	var extra := 0
	match String(w.meta.ench):
		"ember":
			extra = _d(pow_, 4, 0)
			_say("Flamebrand sears for %d more." % extra)
		"void":
			extra = _d(1, 4, 0)
			var drink := 2 * pow_
			rec().hp = mini(int(rec().hp) + drink, int(rec().max_hp))
			_say("Souleater bites for %d and feeds you %d HP." % [extra, drink])
		"frost":
			if rng.randf() < 0.12 * pow_:
				enemy_stunned = true
				_say("Frostbite locks the foe in rime — it loses its next turn!")
		"verdant":
			rec().hp = mini(int(rec().hp) + pow_, int(rec().max_hp))
			_say("Thornheart returns %d HP." % pow_)
		"gilded":
			pass  # Goldtouched pays out at the kill (see _victory)
	return extra


## Damage with a type tag against the foe's resistances and weaknesses.
func _damage_enemy(dmg: int, tag := "physical") -> void:
	var def: Dictionary = Db.ENEMIES[e().type]
	if tag in def.get("resist", []):
		dmg = maxi(1, dmg / 2)
		_say("(%s resists %s — halved to %d)" % [e().name, tag, dmg])
	elif tag in def.get("weak", []):
		dmg = int(dmg * 1.5)
		_say("(%s is WEAK to %s — %d!)" % [e().name, tag, dmg])
	e().hp = int(e().hp) - dmg
	if int(e().hp) <= 0:
		_victory()
		return
	# Ochre Jellies split when cut below half — a smaller one slithers off.
	if String(e().special) == "split" and not bool(e().get("split_done", false)) \
			and int(e().hp) < int(e().max) / 2:
		e()["split_done"] = true
		_say("%s SPLITS — a smaller jelly slithers away into the dark!" % e().name)
		g.spawn_split(eid)
	_check_boss_phase()


## Best bow's damage dice (quality included); [] if no bow.
func _bow_dice() -> Array:
	var best: Array = []
	var best_avg := -1.0
	for entry in rec().inv:
		if entry == null:
			continue
		var def: Dictionary = Db.item_def(entry.id)
		if def.kind != "weapon" or not def.get("ranged", false):
			continue
		var avg: float = def.dmg[0] * (def.dmg[1] + 1) * 0.5 + def.dmg[2]
		if avg > best_avg:
			best_avg = avg
			best = [int(def.dmg[0]), int(def.dmg[1]),
				int(def.dmg[2]) + int(entry.get("meta", {}).get("quality", 0))]
	return best if best_avg >= 0 else [1, 8, 0]


func _shoot() -> void:
	var r := rec()
	var have_arrow := false
	for i in range(r.inv.size()):
		if r.inv[i] != null and r.inv[i].id == "arrow":
			have_arrow = true
			r.inv[i].count = int(r.inv[i].count) - 1
			if int(r.inv[i].count) <= 0:
				r.inv[i] = null
			break
	if not have_arrow:
		_say("Your quiver is empty.")
		_push()
		return
	g._sync_player(pid)
	defend_ac = 0
	var d20 := rng.randi_range(1, 20)
	var bonus := _atk_bonus()
	var crit := d20 >= _crit_floor()
	if d20 != 1 and (crit or d20 + bonus >= int(e().ac)):
		var dd := _bow_dice()
		var dmg := _d(int(dd[0]) * (2 if crit else 1), int(dd[1]), int(dd[2]))
		_roll_note("you", [d20], bonus, int(e().ac), "CRIT!" if crit else "HIT")
		_say("Arrow: %d+%d vs AC %d — %s for %d!" % [d20, bonus, int(e().ac),
			"CRITICAL" if crit else "hit", dmg])
		_damage_enemy(dmg)
	else:
		_roll_note("you", [d20], bonus, int(e().ac), "MISS")
		_say("Arrow: %d+%d vs AC %d — it clatters off the stone." % [d20, bonus, int(e().ac)])
	if not over:
		_end_player_turn()


# ---------------------------------------------------------------- enemy turn

func _enemy_turn() -> void:
	# Status effects tick at the top of the foe's turn.
	var st: Dictionary = e().get("status", {})
	if int(st.get("burn", 0)) > 0:
		st.burn = int(st.burn) - 1
		_say("%s burns for 4." % e().name)
		_damage_enemy(4, "fire")
		if over:
			return
	if int(st.get("poison", 0)) > 0:
		st.poison = int(st.poison) - 1
		_say("Venom eats at %s for 3." % e().name)
		_damage_enemy(3, "poison")
		if over:
			return
	if int(st.get("sleep", 0)) > 0:
		st.sleep = int(st.sleep) - 1
		_say("%s is fast asleep — it loses its turn." % e().name)
		_tick_poison()
		return
	if enemy_stunned:
		enemy_stunned = false
		_say("%s is frozen solid and loses its turn!" % e().name)
		_tick_poison()
		return
	var spec := String(e().special)
	if spec != "" and rng.randf() < float(e().spec_chance) + (0.15 if boss_phase >= 3 else 0.0):
		_enemy_special(spec)
	else:
		_enemy_hit_player(false)
	_tick_poison()


func _enemy_hit_player(half: bool) -> void:
	var d20 := rng.randi_range(1, 20)
	var atk: int = int(e().atk) - enemy_atk_down \
		- int(g.armor_of(rec()).ench.get("void", 0))  # Dread armor enchant
	var total := d20 + atk
	var ac := _player_ac()
	if d20 == 1:
		_roll_note("foe", [d20], atk, ac, "FUMBLE")
		var counter := maxi(1, _d(1, int(_dmg_dice()[1]), 0) / 2)
		_say("%s rolls a natural 1 and overextends — you counter for %d!" % [e().name, counter])
		_damage_enemy(counter)
		return
	if d20 < 20 and total < ac:
		_roll_note("foe", [d20], atk, ac, "MISS")
		_say("%s rolls %d+%d=%d vs your AC %d — you deflect it." % [e().name, d20, atk, total, ac])
		return
	var dd: Array = e().dmg
	var crit := d20 == 20
	var dmg := _d(int(dd[0]) * (2 if crit else 1), int(dd[1]), int(dd[2]))
	if half:
		dmg = maxi(1, dmg / 2)
	if crit:
		_roll_note("foe", [d20], atk, ac, "CRIT!")
		_say("%s rolls a NATURAL 20 — critical for %d!" % [e().name, dmg])
	else:
		_roll_note("foe", [d20], atk, ac, "HIT")
		_say("%s rolls %d+%d=%d — hits you for %d." % [e().name, d20, atk, total, dmg])
	g.hurt_player(pid, dmg, e().name)
	# hurt_player aborts us if they died.


func _enemy_special(spec: String) -> void:
	match spec:
		"multiattack":
			_say("%s unleashes a flurry!" % e().name)
			_enemy_hit_player(false)
			if not over:
				_enemy_hit_player(false)
		"poison":
			_say("%s spits searing venom!" % e().name)
			_enemy_hit_player(false)
			if not over:
				poison_turns = 3
				_say("Poison seeps into your veins (3 turns).")
		"luck_drain":
			var drain := rng.randi_range(5, 12)
			rec().buffs.append({"k": "luck", "amt": -drain, "until": Time.get_ticks_msec() + 60000})
			_say("%s siphons your fortune (-%d luck, 60s)." % [e().name, drain])
			g._sync_player(pid)
		"gold_steal":
			var take: int = mini(int(rec().gold), rng.randi_range(8, 20 + g.floor_num * 4))
			rec().gold = int(rec().gold) - take
			e()["stolen"] = int(e().get("stolen", 0)) + take
			_say("%s snatches %d gold from your purse!" % [e().name, take])
			g._sync_player(pid)
		"heal_self":
			var heal := int(int(e().max) * 0.15)
			e().hp = mini(int(e().hp) + heal, int(e().max))
			_say("%s knits its wounds (+%d HP)." % [e().name, heal])
		"curse":
			player_disadv = true
			_say("%s marks you with a black sigil — your next strike is cursed." % e().name)
		"engulf":
			_say("%s SURGES forward and engulfs you in caustic jelly!" % e().name)
			_enemy_hit_player(false)
			if not over:
				poison_turns = maxi(poison_turns, 2)
				_say("Acid soaks through everything (2 turns).")
		"acid_spit":
			_say("%s spits a rope of black acid!" % e().name)
			_enemy_hit_player(false)
			if not over and ac_shred < 4:
				ac_shred += 1
				_say("Your armor sizzles and pits (-1 AC this battle).")
		"split":
			_enemy_hit_player(false)  # jellies just hit; splitting happens when wounded


func _tick_poison() -> void:
	if poison_turns > 0 and not over:
		poison_turns -= 1
		var dmg := rng.randi_range(2, 5)
		_say("Poison burns for %d." % dmg)
		g.hurt_player(pid, dmg, "poison")


func _check_boss_phase() -> void:
	if not bool(e().get("boss", false)):
		return
	var frac := float(e().hp) / float(e().max)
	var want := 1
	if frac <= 0.33:
		want = 3
	elif frac <= 0.66:
		want = 2
	if want > boss_phase:
		boss_phase = want
		e().atk = int(e().atk) + 1
		_say("— PHASE %d — %s roars, and the vault trembles! (+1 atk, wilder tricks)" % [boss_phase, e().name])


# ---------------------------------------------------------------- spells & potions

func _combat_spell_actions() -> Array:
	var out: Array = []
	var inv: Array = rec().inv
	for i in range(inv.size()):
		var it = inv[i]
		if it != null and it.id == "spell" and int(it.meta.get("charges", 0)) > 0 \
				and it.meta.get("combat", "") != "":
			out.append({"id": "spell:%d" % i, "label": "✦ %s" % it.meta.name})
	return out.slice(0, 3)


func _potion_actions() -> Array:
	var out: Array = []
	var inv: Array = rec().inv
	for i in range(inv.size()):
		var it = inv[i]
		if it == null or it.id != "potion":
			continue
		var drinkable := false
		for fx in it.meta.get("effects", []):
			if String(fx.prop) in ["heal", "luck", "stone", "swift"]:
				drinkable = true
		if drinkable:
			out.append({"id": "potion:%d" % i, "label": "🜃 %s" % it.meta.name})
	return out.slice(0, 2)


func _cast(slot: int) -> void:
	var r := rec()
	if slot < 0 or slot >= r.inv.size() or r.inv[slot] == null:
		_push()
		return
	var it: Dictionary = r.inv[slot]
	if it.id != "spell" or int(it.meta.get("charges", 0)) <= 0:
		_push()
		return
	it.meta.charges = int(it.meta.charges) - 1
	var power := int(it.meta.get("power", 1))
	match String(it.meta.get("combat", "")):
		"smite":
			var dmg := _d(power + 1, 6, power)
			_say("%s sears %s for %d — no roll needed, fire finds its mark." % [it.meta.name, e().name, dmg])
			_apply_status("burn", 2)
			_damage_enemy(dmg, "fire")
		"chill":
			enemy_stunned = true
			_apply_status("sleep", 0)  # flavor: frozen, not slept
			_say("%s encases %s in rime — it will lose its next turn." % [it.meta.name, e().name])
		"mend":
			var heal := 8 * (power + 1)
			r.hp = mini(int(r.hp) + heal, int(r.max_hp))
			_say("%s knits your wounds (+%d HP)." % [it.meta.name, heal])
		"hex":
			enemy_atk_down += 2
			player_adv = true
			_say("%s — the foe's fate is marked: -2 to its attacks, advantage on your next." % it.meta.name)
		"fortune":
			luck_bonus += 20
			_say("%s — fortune floods the field (+20 luck this battle)." % it.meta.name)
	if int(it.meta.charges) <= 0:
		r.inv[slot] = null
		_say("The spell crumbles to glitter.")
	g._sync_player(pid)
	if not over:
		_end_player_turn()


func _quaff(slot: int) -> void:
	var r := rec()
	if slot < 0 or slot >= r.inv.size() or r.inv[slot] == null or r.inv[slot].id != "potion":
		_push()
		return
	var meta: Dictionary = r.inv[slot].meta
	_say("You down the %s." % meta.name)
	var it: Dictionary = r.inv[slot]
	it.count = int(it.count) - 1
	if int(it.count) <= 0:
		r.inv[slot] = null
	EffectExec.drink(g, pid, meta)
	g._sync_player(pid)
	if not over:
		_end_player_turn()


# ---------------------------------------------------------------- flee / end

func _flee() -> void:
	var pd := rng.randi_range(1, 20)
	var ed := rng.randi_range(1, 20)
	var pt: int = pd + luck() / 10
	var et: int = ed + g.floor_num / 2
	if pt >= et:
		_roll_note("you", [pd], luck() / 10, et, "ESCAPED")
		_say("You roll %d vs %d — you slip into the shadows." % [pt, et])
		e().in_combat = false
		e().cooldown = 8.0
		_finish()
	else:
		_roll_note("you", [pd], luck() / 10, et, "CAUGHT")
		_say("You roll %d vs %d — %s catches your cloak!" % [pt, et, e().name])
		_enemy_hit_player(false)
		if not over:
			phase = "player"
			_push()


func _victory() -> void:
	_say("%s is struck down!" % e().name)
	phase = "done"
	over = true
	# Gold: 2d6 + floor scaling, elite multiplier, stolen gold recovered.
	var reward := _d(2, 6, g.floor_num * 4)
	reward = int(reward * float(e().get("gold_mult", 1.0)))
	reward += int(e().get("stolen", 0))
	# Enchant payoffs.
	var w := _best_weapon()
	if not w.is_empty() and String(w.meta.get("ench", "")) == "gilded":
		reward += 10 * int(w.meta.get("epow", 1))
		_say("Goldtouched glimmers — the corpse pays extra.")
	var mend := int(g.armor_of(rec()).ench.get("verdant", 0))
	if mend > 0:
		rec().hp = mini(int(rec().hp) + mend * 3, int(rec().max_hp))
		_say("Mending armor knits you for %d." % (mend * 3))
	g.reward_gold(pid, reward)
	_say("You loot %d gold from the corpse." % reward)
	_push()
	g.enemy_defeated(eid, pid)
	g.encounter_over(pid)


## Applies a status to the foe unless its nature resists it.
func _apply_status(kind: String, turns: int) -> void:
	if turns <= 0:
		return
	var def: Dictionary = Db.ENEMIES[e().type]
	var block: bool = (kind == "burn" and "fire" in def.get("resist", [])) \
		or (kind == "poison" and "poison" in def.get("resist", []))
	if block:
		_say("%s shrugs off the %s." % [e().name, kind])
		return
	if not e().has("status"):
		e()["status"] = {}
	e().status[kind] = maxi(int(e().status.get(kind, 0)), turns)


## Called by Game when the player dies or disconnects mid-encounter.
func abort() -> void:
	if over:
		return
	over = true
	phase = "done"
	e().in_combat = false
	e().cooldown = 8.0
	_push()
	g.encounter_over(pid)


func _finish() -> void:
	over = true
	phase = "done"
	_push()
	g.encounter_over(pid)


# ---------------------------------------------------------------- state → client

func _actions() -> Array:
	var out: Array = []
	if phase == "npc":
		out.append({"id": "talk", "label": "💬 Talk"})
		out.append({"id": "trade", "label": "🪙 Trade"})
		if not npc_offer.is_empty():
			out.append({"id": "buy", "label": "Buy (%d g)" % int(npc_offer.price)})
		out.append({"id": "quest", "label": "📜 Quest"})
		out.append({"id": "rob", "label": "🗡 Rob (d20)"})
		out.append({"id": "leave", "label": "Leave"})
		return out
	if phase != "player":
		return out
	out.append({"id": "attack", "label": "⚔ Attack (+%d, %s)" % [_atk_bonus(), _dice_txt()]})
	var arrows := 0
	var has_bow := false
	for it in rec().inv:
		if it == null:
			continue
		if it.id == "arrow":
			arrows += int(it.count)
		elif Db.item_def(it.id).get("ranged", false):
			has_bow = true
	if has_bow and arrows > 0:
		out.append({"id": "shoot", "label": "🏹 Shoot (%d arrows)" % arrows})
	out.append({"id": "defend", "label": "🛡 Defend (+4 AC)"})
	out.append_array(_combat_spell_actions())
	out.append_array(_potion_actions())
	out.append({"id": "flee", "label": "🏃 Flee"})
	return out


func _dice_txt() -> String:
	var dd := _dmg_dice()
	var s := "%dd%d" % [int(dd[0]), int(dd[1])]
	if int(dd[2]) > 0:
		s += "+%d" % int(dd[2])
	return s


func _intent() -> String:
	if not _insight():
		return ""
	var spec := String(e().special)
	if spec == "":
		return "It has no tricks — pure violence."
	return "It is winding up: %s (%d%% each turn)." % [spec.replace("_", " "), int(float(e().spec_chance) * 100)]


func state() -> Dictionary:
	return {
		"phase": phase,
		"enemy_name": e().name, "enemy_hp": maxi(0, int(e().hp)), "enemy_max": int(e().max),
		"boss": bool(e().get("boss", false)), "boss_phase": boss_phase,
		"elite": String(e().get("elite", "")),
		"enemy_ac": int(e().ac) if _insight() else -1,
		"intent": _intent(),
		"hp": int(rec().hp), "max_hp": int(rec().max_hp), "gold": int(rec().gold),
		"luck": luck(), "ac": _player_ac(),
		"poison": poison_turns,
		"lines": lines.duplicate(),
		"rolls": rolls.duplicate(true),
		"actions": _actions(),
	}


func _push() -> void:
	g.push_enc_state(pid, state())
