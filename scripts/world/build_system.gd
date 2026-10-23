extends Node2D
## 建造模式：选择建筑 → 半透明预览 → 点击放置。

signal selection_changed(id: String)
signal building_clicked(building)
signal demolish_prompt_requested(building)

var world: Node2D
var selected_id := ""
var paint_kind := ""
var demolish_mode := false
var valid := false

var _ghost: Sprite2D
var _marker: ColorRect
var _marker_label: Label
var _footprint := Vector2i(4, 4)
var _cell := Vector2i.ZERO
var _demolish_drag_cell := Vector2i(-9999, -9999)


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	set_process(false)
	z_index = 4000


func select(id: String) -> void:
	cancel()
	var data := DataRegistry.get_building(id)
	if data.is_empty():
		return
	selected_id = id
	var f: Array = data.get("footprint", [4, 4])
	_footprint = Vector2i(int(f[0]), int(f[1]))
	_build_ghost(data)
	set_process(true)
	selection_changed.emit(id)


func select_ground(kind: String) -> void:
	cancel()
	paint_kind = kind
	_build_ground_ghost(kind)
	set_process(true)
	selection_changed.emit("ground:" + kind)


func select_demolish() -> void:
	cancel()
	demolish_mode = true
	_ensure_marker()
	set_process(true)
	selection_changed.emit("demolish")


func is_demolishing() -> bool:
	return demolish_mode


func is_painting() -> bool:
	return paint_kind != ""


func cancel() -> void:
	selected_id = ""
	paint_kind = ""
	demolish_mode = false
	_demolish_drag_cell = Vector2i(-9999, -9999)
	if _ghost:
		_ghost.queue_free()
		_ghost = null
	if _marker:
		_marker.visible = false
	if _marker_label:
		_marker_label.visible = false
	set_process(false)
	selection_changed.emit("")


func _ensure_marker() -> void:
	if _marker == null:
		_marker = ColorRect.new()
		_marker.color = Color(1.0, 0.3, 0.3, 0.3)
		_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_marker.visible = false
		add_child(_marker)
	if _marker_label == null:
		_marker_label = UIKit.label("", 22, Color(1.0, 0.9, 0.9))
		_marker_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_marker_label.visible = false
		add_child(_marker_label)


func _build_ghost(data: Dictionary) -> void:
	var cfg: Dictionary = data.get("sprite", {})
	var layered_cfg: Dictionary = data.get("sprite_layers", {})
	if not layered_cfg.is_empty():
		var origin_arr: Array = layered_cfg.get("origin", [0, 0])
		var ghost_path := str(layered_cfg.get("roof", layered_cfg.get("ground", "")))
		_ghost = Sprite2D.new()
		if ghost_path != "" and ResourceLoader.exists(ghost_path):
			_ghost.texture = load(ghost_path)
		_ghost.centered = false
		_ghost.offset = -Vector2(int(origin_arr[0]), int(origin_arr[1]))
		_ghost.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_ghost.modulate = Color(1, 1, 1, 0.65)
		add_child(_ghost)
		return
	var rect_arr: Array = cfg.get("rect", [0, 0, 64, 64])
	var rect := Rect2(rect_arr[0], rect_arr[1], rect_arr[2], rect_arr[3])
	_ghost = Sprite2D.new()
	_ghost.texture = load(str(cfg.get("atlas", "")))
	_ghost.region_enabled = true
	_ghost.region_rect = rect
	_ghost.centered = false
	_ghost.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ghost.modulate = Color(1, 1, 1, 0.65)
	_ghost.scale = Vector2(
		float(_footprint.x * 32) / maxf(rect.size.x, 1.0),
		float(_footprint.y * 32) / maxf(rect.size.y, 1.0))
	add_child(_ghost)


func _build_ground_ghost(kind: String) -> void:
	var tile_cfg := DataRegistry.ground_tile_config(kind)
	var coords: Array = tile_cfg.get("coords", [3, 3])
	_ghost = Sprite2D.new()
	_ghost.texture = load(str(tile_cfg.get(
		"atlas", "res://art/generated/field_2x.png")))
	_ghost.region_enabled = true
	_ghost.region_rect = Rect2(int(coords[0]) * 32, int(coords[1]) * 32, 32, 32)
	_ghost.centered = false
	_ghost.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ghost.modulate = Color(1, 1, 1, 0.6)
	add_child(_ghost)


func ground_cost(kind: String) -> int:
	var costs: Dictionary = DataRegistry.ground_config().get("cost", {})
	return int(costs.get(kind, 0))


func _process(_delta: float) -> void:
	if world == null:
		return
	var mouse := world.get_global_mouse_position()
	var hover: Vector2i = world.world_to_cell(mouse)
	if demolish_mode:
		_cell = hover
		_update_demolish_marker()
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_demolish_drag_cell = Vector2i(-9999, -9999)
		elif _demolish_drag_cell != _cell:
			_demolish_drag_at(_cell)
		return
	if _ghost == null:
		return
	if is_painting():
		_cell = hover
		_ghost.position = world.cell_to_world(_cell)
		valid = world.can_paint_ground(_cell, paint_kind) \
			and GameState.can_afford(ground_cost(paint_kind))
		_ghost.modulate = Color(0.6, 1.0, 0.6, 0.55) if valid else Color(1.0, 0.5, 0.5, 0.5)
		if valid and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_paint_cell(_cell)
		return
	_cell = hover - _footprint / 2
	_ghost.position = world.cell_to_world(_cell)
	valid = world.can_place(_cell, _footprint) and GameState.can_afford(_cost())
	_ghost.modulate = Color(0.55, 1.0, 0.55, 0.7) if valid else Color(1.0, 0.45, 0.45, 0.7)


func _cost() -> int:
	return int(DataRegistry.get_building(selected_id).get("cost", 0))


func _unhandled_input(event: InputEvent) -> void:
	# 右键：退出建造 / 铺地 / 拆除模式（和 ESC 等价，方便纯鼠标操作）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if demolish_mode or is_painting() or selected_id != "":
			cancel()
			get_viewport().set_input_as_handled()
		return
	if demolish_mode:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_handle_demolish_click(world.world_to_cell(world.get_global_mouse_position()))
			get_viewport().set_input_as_handled()
			return
		if event is InputEventScreenTouch and event.pressed:
			var canvas := get_viewport().get_canvas_transform()
			_cell = world.world_to_cell(canvas.affine_inverse() * event.position)
			_handle_demolish_click(_cell)
			get_viewport().set_input_as_handled()
			return
		return
	if is_painting():
		var paint_click := false
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			paint_click = true
		elif event is InputEventScreenTouch and event.pressed:
			var canvas := get_viewport().get_canvas_transform()
			var world_pos: Vector2 = canvas.affine_inverse() * event.position
			_cell = world.world_to_cell(world_pos)
			paint_click = true
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()
			return
		if paint_click:
			_paint_cell(_cell)
			get_viewport().set_input_as_handled()
		return
	if selected_id == "":
		return
	var pressed := false
	var clicked_cell := Vector2i(-9999, -9999)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		pressed = true
		clicked_cell = world.world_to_cell(world.get_global_mouse_position())
	elif event is InputEventScreenTouch and event.pressed:
		# 触摸时以触摸点为准
		var canvas := get_viewport().get_canvas_transform()
		var world_pos: Vector2 = canvas.affine_inverse() * event.position
		clicked_cell = world.world_to_cell(world_pos)
		_cell = world.world_to_cell(world_pos) - _footprint / 2
		valid = world.can_place(_cell, _footprint) and GameState.can_afford(_cost())
		pressed = true
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel()
		get_viewport().set_input_as_handled()
		return
	if pressed:
		var existing: Building = world.building_at(clicked_cell)
		if existing:
			building_clicked.emit(existing)
			get_viewport().set_input_as_handled()
			return
		_try_place()
		get_viewport().set_input_as_handled()


func _try_place() -> void:
	if not valid:
		if world.can_place(_cell, _footprint):
			GameState.notice.emit("资金不足，无法建造 %s" % str(DataRegistry.get_building(selected_id).get("name", "")))
		return
	var cost := _cost()
	var build_data := DataRegistry.get_building(selected_id)
	if GameState.fame < float(build_data.get("unlock_fame", 0)):
		GameState.notice.emit("知名度不足，暂时无法建造 %s" % str(build_data.get("name", "")))
		return
	if not GameState.can_afford(cost):
		GameState.notice.emit("资金不足")
		return
	if not GameState.spend(cost, "建造"):
		return
	var building: Node2D = world.place_building(selected_id, _cell)
	if building:
		GameState.notice.emit("已建造 %s（-%s）" % [str(building.data.get("name", "")), GameState.format_money(cost)])


func _paint_cell(cell: Vector2i) -> void:
	if paint_kind == "":
		return
	if world.is_wall(cell):
		GameState.notice.emit("这里是度假村的围墙，不能铺地面")
		return
	if not world.can_paint_ground(cell, paint_kind):
		return
	var cost := ground_cost(paint_kind)
	if cost > 0 and not GameState.spend(cost, "铺设地面"):
		return
	world.set_ground(cell, paint_kind)


func _update_demolish_marker() -> void:
	var b: Building = world.building_at(_cell)
	if _marker == null or _marker_label == null:
		return
	if b == null:
		if not _can_remove_ground(_cell):
			_marker.visible = false
			_marker_label.visible = false
			return
		_marker.visible = true
		_marker.position = world.cell_to_world(_cell)
		_marker.size = Vector2(World.CELL, World.CELL)
		_marker.color = Color(1.0, 0.25, 0.25, 0.28)
		_marker_label.visible = true
		_marker_label.text = "拆除地砖 → 荒地"
		_marker_label.position = world.cell_to_world(_cell) + Vector2(0, -36)
		return
	var rect_pos: Vector2 = world.cell_to_world(b.cell)
	_marker.visible = true
	_marker.position = rect_pos
	_marker.size = Vector2(b.footprint) * float(World.CELL)
	var direct := b.can_demolish_directly()
	_marker.color = Color(1.0, 0.25, 0.25, 0.34 if direct else 0.22)
	_marker_label.visible = true
	_marker_label.text = "%s ｜ 返还 %s%s" % [
		b.display_name(), GameState.format_money(b.refund_value()),
		"（点击直接拆除）" if direct else "（点击打开面板确认）"]
	_marker_label.position = rect_pos + Vector2(0, -36)


func _can_remove_ground(cell: Vector2i) -> bool:
	if world.is_wall(cell):
		return false
	var kind: String = world.ground_type(cell)
	return kind != World.GROUND_WASTELAND


func _demolish_drag_at(cell: Vector2i) -> void:
	_demolish_drag_cell = cell
	if world.building_at(cell) != null or not _can_remove_ground(cell):
		return
	world.set_ground(cell, World.GROUND_WASTELAND)


func _handle_demolish_click(cell: Vector2i = Vector2i(-9999, -9999)) -> void:
	_cell = cell if cell.x != -9999 else world.world_to_cell(world.get_global_mouse_position())
	var b: Building = world.building_at(_cell)
	if b == null:
		if not _can_remove_ground(_cell):
			return
		_demolish_drag_at(_cell)
		GameState.notice.emit("已拆除地砖，恢复为荒地")
		_update_demolish_marker()
		return
	if not b.can_demolish_directly():
		demolish_prompt_requested.emit(b)
		return
	var result: Dictionary = world.demolish(b)
	if _marker:
		_marker.visible = false
	if _marker_label:
		_marker_label.visible = false
	GameState.notice.emit("已拆除 %s，返还 %s" % [
		str(result.get("name", "")), GameState.format_money(int(result.get("refund", 0)))])
