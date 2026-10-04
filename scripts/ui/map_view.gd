class_name MapView
extends Control
## 用方块绘制地图：格子分布刻意做得不太整齐（带随机微偏移），点击格子发出信号。

signal cell_clicked(cell: Vector2i)

var cells: Dictionary = {}          # Vector2i -> { color: Color, label: String, sub: String, border: Color }
var marker_cell := Vector2i(9999, 9999)
var marker_color := Color(0.25, 0.72, 1.0)
var spacing := 6.0
var jitter := 5.0
var padding := 30.0
var show_labels := true
var hover_cell := Vector2i(9999, 9999)

var _rects: Dictionary = {}
var _cell_size := 96.0
var _font: Font


func _ready() -> void:
	_font = UIKit.theme().default_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


func set_cells(data: Dictionary) -> void:
	cells = data
	queue_redraw()


func set_marker(cell: Vector2i) -> void:
	marker_cell = cell
	queue_redraw()


func _draw() -> void:
	_layout()
	for cell in _rects.keys():
		var rect: Rect2 = _rects[cell]
		var info: Dictionary = cells[cell]
		var fill: Color = info.get("color", Color(0.5, 0.5, 0.5))
		var border: Color = info.get("border", Color(0.05, 0.05, 0.08))
		draw_rect(rect, fill, true)
		draw_rect(rect, border, false, 3.0)
		if show_labels:
			var label := str(info.get("label", ""))
			var sub := str(info.get("sub", ""))
			if label != "":
				var label_pos := rect.position + Vector2(10, 30)
				draw_string(_font, label_pos, label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 20, 24, Color(1, 1, 1, 0.95))
			if sub != "":
				var sub_pos := rect.position + Vector2(10, 56)
				draw_string(_font, sub_pos, sub, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 20, 19, Color(1, 1, 1, 0.72))
	if _rects.has(marker_cell):
		_draw_marker(_rects[marker_cell])


func _draw_marker(rect: Rect2) -> void:
	var center := rect.position + rect.size * 0.5
	var w := rect.size.x * 0.34
	var h := rect.size.y * 0.34
	var points := PackedVector2Array([
		center + Vector2(0, -h * 0.6),
		center + Vector2(-w * 0.5, h * 0.5),
		center + Vector2(w * 0.5, h * 0.5),
	])
	draw_colored_polygon(points, marker_color)
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, Color(0.05, 0.1, 0.2), 2.0)


func _layout() -> void:
	_rects.clear()
	if cells.is_empty():
		return
	var min_cell := Vector2i(9999, 9999)
	var max_cell := Vector2i(-9999, -9999)
	for cell in cells.keys():
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
	var cols := max_cell.x - min_cell.x + 1
	var rows := max_cell.y - min_cell.y + 1
	var avail := size - Vector2(padding * 2.0, padding * 2.0)
	var cw := (avail.x - spacing * float(maxi(cols - 1, 0))) / float(maxi(cols, 1))
	var ch := (avail.y - spacing * float(maxi(rows - 1, 0))) / float(maxi(rows, 1))
	_cell_size = clampf(minf(cw, ch), 48.0, 150.0)
	var total := Vector2(
		float(cols) * _cell_size + spacing * float(maxi(cols - 1, 0)),
		float(rows) * _cell_size + spacing * float(maxi(rows - 1, 0)))
	var origin := (size - total) * 0.5
	for cell in cells.keys():
		var j := _jitter_for(cell)
		var pos := origin + Vector2(
			float(cell.x - min_cell.x) * (_cell_size + spacing),
			float(cell.y - min_cell.y) * (_cell_size + spacing)) + j
		_rects[cell] = Rect2(pos, Vector2(_cell_size, _cell_size))


func _jitter_for(cell: Vector2i) -> Vector2:
	var h := float((cell.x * 73856093) ^ (cell.y * 19349663))
	var a := sin(h * 0.013) * 0.5 + 0.5
	var b := cos(h * 0.017) * 0.5 + 0.5
	return Vector2((a - 0.5) * 2.0 * jitter, (b - 0.5) * 2.0 * jitter)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var cell := cell_at(event.position)
		if cell != Vector2i(9999, 9999):
			cell_clicked.emit(cell)
			accept_event()
	elif event is InputEventMouseMotion:
		hover_cell = cell_at(event.position)


func cell_at(pos: Vector2) -> Vector2i:
	for cell in _rects.keys():
		if (_rects[cell] as Rect2).has_point(pos):
			return cell
	return Vector2i(9999, 9999)
