class_name UIKit
extends RefCounted
## 界面通用外观：像素字体、面板样式、标签、按钮、物品图标。

const FONT_PATH := "res://art/fonts/ark-pixel-12px-zh_hans.ttf"

static var _theme: Theme = null


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	var font: FontFile = load(FONT_PATH)
	if font:
		font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		font.hinting = TextServer.HINTING_NONE
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		t.default_font = font
	t.default_font_size = 24
	_theme = t
	return t


static func panel_style(bg: Color = Color(0.10, 0.09, 0.13, 0.94), border: Color = Color(0.40, 0.36, 0.50)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


static func label(text: String, size: int = 24, color: Color = Color(0.92, 0.92, 0.96)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 5)
	return l


static func paragraph(text: String, size: int = 22, color: Color = Color(0.90, 0.92, 0.97), width: float = 420.0) -> Label:
	var l := label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(width, 0)
	return l


static func button(text: String, min_size: Vector2 = Vector2(104, 52)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_stylebox_override("normal", panel_style(Color(0.16, 0.14, 0.20, 0.92), Color(0.42, 0.38, 0.52)))
	b.add_theme_stylebox_override("hover", panel_style(Color(0.24, 0.21, 0.30, 0.95), Color(0.72, 0.62, 0.35)))
	b.add_theme_stylebox_override("pressed", panel_style(Color(0.30, 0.26, 0.16, 0.98), Color(0.95, 0.80, 0.40)))
	b.add_theme_stylebox_override("focus", panel_style(Color(0.22, 0.20, 0.28, 0.95), Color(0.72, 0.62, 0.35)))
	b.add_theme_stylebox_override("disabled", panel_style(Color(0.13, 0.12, 0.15, 0.85), Color(0.28, 0.26, 0.32)))
	return b


static func icon(path: String, box: Vector2 = Vector2(40, 40)) -> TextureRect:
	var icon_rect := TextureRect.new()
	if path != "" and ResourceLoader.exists(path):
		icon_rect.texture = load(path)
	icon_rect.custom_minimum_size = box
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return icon_rect


static func spacer(height: float = 6.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


static func root_control() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme()
	return root
