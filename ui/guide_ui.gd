class_name GuideUI
extends Control
## The Luckweaver's Handbook (H) — the in-game manual, paged by topic.

const PAGES := [
	["Getting Started",
"""You wake in an infinite wilderness. Villages hold benches and folk;
the Deep begins wherever you start digging.
• WASD move, Space jump (hold in water to swim), Shift sprint, CTRL dodge-dash.
• LMB attacks foes / (hold) mines blocks. RMB places blocks or uses items.
• E interacts: benches, doors, chests, waystones — and creatures
  (Trade with folk, Hunt animals... or offer wheat to TAME one as a pet).
• Tab satchel · K disciplines & perks · M map · H this book · T chat · Esc pause.
• Gamepad works: left stick move, right stick look, A jump, B dodge, X interact.
There is NO portal: dig down to descend. Every 8 blocks below the surface
is a deeper, deadlier, richer BAND. Bosses stalk band 3 and below.
Night falls on the overworld — monsters walk it. Build, hide, or fight."""],
	["Spells & Mana",
"""Spells are ITEMS you learn, keep forever, and cast on MANA (blue bar).
• LEARN: find a village RUNE FORGE (E) → craft "Learn Spell" (100 g) for your
  class's signature spell — or forge others from rune + sigil + essence.
• EQUIP: the spell appears in your satchel (Tab). Drag/click it onto a
  hotbar slot like any item.
• CAST: select its slot (1-9 / mouse wheel), aim, RMB. Costs mana; mana
  regenerates (faster at campfires). Spells NEVER drop on death.
• Bigger spells cost more mana. Walls, breaches, invisibility, firestorms,
  healing, resurrection — see the Rune Forge list for what you can build."""],
	["Combat (real-time d20)",
"""Combat is REAL-TIME, but every strike is a d20 + attack bonus vs the foe's AC.
• LMB swings (watch your arm arc); bows fire aimed shots from afar.
• Natural 20 = critical (double dice). Natural 1 = fumble. Dodge with CTRL.
• LUCK bends everything: advantage procs, wider crit range, rerolls.
• Bosses TELEGRAPH big attacks (⚠ WINDUP) — move before the blow lands!
• Statuses work both ways: burn, poison, and sleep afflict foes too.
• Every creature resists some damage and fears another — silver cuts ghosts.
• Strike from smoke, invisibility, or long range for a SNEAK ATTACK (2× opener).
• Watch for AMBUSHES, cave-ins, gas leaks, and gold rushes as you explore."""],
	["Crafting Benches",
"""Allied and cozy villages hold all six benches on their plaza:
• ANVIL — smith weapons/armor/tools from stone, hides, bone, and metal
  (copper → iron → silver → adamant, deeper floors hold richer ores).
• RUNE FORGE — rune + sigil + essence = spell (walls, breaches, invisibility...).
• CAULDRON — 2-3 ingredients: shared properties become the potion. Volatile,
  smoke, and toxic brews become throwable bombs.
• SKILL FORGE — merge two skills/spells into new passives.
• ENCHANTING ALTAR — 2 essences + 30g enchants gear. A LUCK SHARD instead
  soul-BINDS an item so death can't take it.
• CAMPFIRE — cook feasts (shared buffs, rare permanent boosts); fillet fish."""],
	["Survival",
"""• Every skill levels as you use it; level-ups grant points to spend (K).
• Oxygen drains underwater — kelp potions, Tideborn armor, or surface.
• Farming: seeds on dirt, light ≥ 8 (glowstone), harvest wheat.
• Fishing: craft a rod, aim at water, RMB. Grubs (dig dirt) improve the catch.
  Keep fish alive to sell — or use them to fillet meat for cooking.
  A Mythril Rod can fish LAVA. Luckfish grant permanent luck.
• Campfires heal, act as respawn points, and anchor your camps.
• Storage Chests (craft: 6 wood) share loot with your party; town chests persist.
• DEATH drops your items where you fell — corpse-run to reclaim them.
  Spells, enchanted gear, and soul-bound items stay with you."""],
	["The World & The Deep",
"""• Overworld biomes: meadows, elderwood, dunes, frostveil, mirkfen,
  titan spires, and the sunken sea — villages and ruins dot all of them.
• Villages come allied, cozy, hostile (bandits!), or haunted — guardians,
  shops, quests, and warm beds in the friendly ones.
• Below: caves widen with depth, brick DUNGEONS hide loot and traps,
  ores run copper → iron → silver → adamant, lava pools at bedrock.
• Villagers and explorers talk, trade, and post quests. Completing them builds
  REPUTATION: shop discounts, richer contracts — and some villagers will even
  move to your Refuge. Robbing folk is a d20 gamble with consequences.
• Traps everywhere: tripwires, glyphs, darts, gas chests, pressure-plate
  CRUSHERS. Every trap is a block — spot it, mine it, disarm it.
• Waystones are teleport bookmarks; place your own network.
• Spend skill points (K) to unlock PERKS at 1 / 3 / 5 points per discipline.
• The dungeon adapts: win too comfortably and it gets meaner.
• DEATH drops your gear where you fell — soul-bind treasures at the Altar."""],
]

var main
var _page := 0
var _title: Label
var _body: Label
var _pager: Label


func _init(main_ref) -> void:
	main = main_ref
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(640, 0)
	_title = UITheme.title("", 24)
	root.add_child(_title)
	_body = UITheme.label("", 15)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD
	_body.custom_minimum_size = Vector2(620, 340)
	var pan := UITheme.panel(UITheme.NEON)
	pan.add_child(_body)
	root.add_child(pan)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var prev := UITheme.button("← Prev", 14)
	prev.pressed.connect(func(): _flip(-1))
	row.add_child(prev)
	_pager = UITheme.label("", 14, UITheme.DIM)
	row.add_child(_pager)
	var next := UITheme.button("Next →", 14)
	next.pressed.connect(func(): _flip(1))
	row.add_child(next)
	var close := UITheme.button("Close (H)", 14)
	close.pressed.connect(func(): main.close_top_ui())
	row.add_child(close)
	root.add_child(row)

	var outer := UITheme.panel()
	outer.add_child(root)
	add_child(UITheme.center_wrap(outer))
	_show()


func _flip(d: int) -> void:
	_page = clampi(_page + d, 0, PAGES.size() - 1)
	_show()


func _show() -> void:
	_title.text = "📖 " + PAGES[_page][0]
	_body.text = PAGES[_page][1]
	_pager.text = " %d / %d " % [_page + 1, PAGES.size()]
