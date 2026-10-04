extends Camera2D
## 相机：鼠标拖拽 / 滚轮缩放 / 触摸拖动 / 双指缩放 / WASD 平移。

@export var min_zoom := 1.0
@export var max_zoom := 4.0
@export var zoom_step := 1.15
@export var keyboard_pan_speed := 720.0

var world: Node2D
var _dragging := false
var _touches: Dictionary = {}
var _pinch_distance := 0.0


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	zoom = Vector2(2.0, 2.0)
	if world:
		var rect: Rect2 = world.world_rect()
		limit_left = int(rect.position.x) - 200
		limit_top = int(rect.position.y) - 200
		limit_right = int(rect.end.x) + 200
		limit_bottom = int(rect.end.y) + 200
		position = world.cell_center(Vector2i(world.build_area.get_center()))


func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		position += dir.normalized() * keyboard_pan_speed * delta / zoom.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		if _dragging:
			position -= event.relative / zoom
	elif event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_by(zoom_step)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_by(1.0 / zoom_step)
		MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		if _touches.size() == 2:
			_pinch_distance = _two_touch_distance()
	else:
		_touches.erase(event.index)


func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if _touches.size() >= 2:
		var d := _two_touch_distance()
		if _pinch_distance > 0.0 and d > 0.0:
			_zoom_by(d / _pinch_distance)
		_pinch_distance = d
	elif _touches.size() == 1:
		position -= event.relative / zoom


func _two_touch_distance() -> float:
	var keys := _touches.keys()
	if keys.size() < 2:
		return 0.0
	return (_touches[keys[0]] as Vector2).distance_to(_touches[keys[1]] as Vector2)


func _zoom_by(factor: float) -> void:
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(z, z)
