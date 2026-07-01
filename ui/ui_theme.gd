class_name UITheme
extends RefCounted
## Casino-gothic UI helpers — every Control in the game is built through these
## so the whole interface stays on-palette without a .theme resource.

const BG := Color(0.07, 0.05, 0.11, 0.92)
const PANEL := Color(0.11, 0.08, 0.16, 0.96)
const GOLD := Color(0.95, 0.78, 0.25)
const NEON := Color(0.45, 0.9, 0.8)
const RED := Color(0.9, 0.25, 0.35)
const TEXT := Color(0.92, 0.9, 0.95)
const DIM := Color(0.6, 0.57, 0.68)


static func panel_style(border := GOLD) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(14)
	return sb


static func panel(border := GOLD) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(border))
	return p


static func label(text: String, size := 16, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func title(text: String, size := 34) -> Label:
	var l := label(text, size, GOLD)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


static func button(text: String, size := 18) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", GOLD)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.12, 0.24)
	sb.border_color = DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	b.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate()
	sbh.border_color = GOLD
	sbh.bg_color = Color(0.22, 0.16, 0.32)
	b.add_theme_stylebox_override("hover", sbh)
	var sbp := sb.duplicate()
	sbp.bg_color = Color(0.3, 0.22, 0.4)
	b.add_theme_stylebox_override("pressed", sbp)
	return b


static func line_edit(placeholder := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.add_theme_color_override("font_color", TEXT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.04, 0.09)
	sb.border_color = DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	e.add_theme_stylebox_override("normal", sb)
	return e


static func hbar(value: float, maxv: float, fg: Color, w := 200.0, h := 16.0) -> ProgressBar:
	var pb := ProgressBar.new()
	pb.max_value = maxv
	pb.value = value
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(w, h)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.04, 0.08)
	bg.set_corner_radius_all(4)
	pb.add_theme_stylebox_override("background", bg)
	var f := StyleBoxFlat.new()
	f.bg_color = fg
	f.set_corner_radius_all(4)
	pb.add_theme_stylebox_override("fill", f)
	return pb


static func center_wrap(inner: Control) -> CenterContainer:
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.add_child(inner)
	return c
