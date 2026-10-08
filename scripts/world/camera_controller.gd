extends Camera2D
## 相机：鼠标拖拽 / 滚轮缩放 / 触摸拖动 / 双指缩放 / WASD 平移。

@export var min_zoom := 1.0
@export var max_zoom := 4.0
@export var zoom_step := 1.15
@export var keyboard_pan_speed := 720.0
@export var middle_drag_max_speed := 1700.0   # 中键按住时，鼠标拉到最边缘的移动速度
@export var middle_drag_deadzone := 0.08      # 屏幕中心 8% 范围内不动

var world: Node2D
var _pan_held := false                        # 是否按住鼠标中键
var _touches: Dictionary = {}
var _pinch_distance := 0.0
var _zoom_target := 2.0                       # 平滑缩放的目标值


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	zoom = Vector2(2.0, 2.0)
	_zoom_target = 2.0
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
	# 按住中键：视角朝鼠标方向移动，越靠屏幕边缘越快（类似浏览网页的操作）
	if _pan_held:
		var view := get_viewport_rect().size
		var center := view * 0.5
		var ratio := (get_viewport().get_mouse_position() - center) / center
		var strength := Vector2(_deadzone_curve(ratio.x), _deadzone_curve(ratio.y))
		position += strength * middle_drag_max_speed * delta / zoom.x
	# 缩放平滑过渡：指数插值，帧率无关
	if absf(zoom.x - _zoom_target) > 0.001:
		var t := 1.0 - exp(-9.0 * delta)
		var z := lerpf(zoom.x, _zoom_target, t)
		zoom = Vector2(z, z)
	_clamp_position()


func _deadzone_curve(value: float) -> float:
	# 死区内为 0，越靠边加速越快（平方曲线）
	var v := clampf(value, -1.0, 1.0)
	if absf(v) <= middle_drag_deadzone:
		return 0.0
	var t := (absf(v) - middle_drag_deadzone) / (1.0 - middle_drag_deadzone)
	return signf(v) * t * t


func _clamp_position() -> void:
	# 关键：把相机位置本身夹在边界内。
	# 否则一直往边界外拖时位置会持续累积，反方向拖要先“还债”才会动。
	var half := get_viewport_rect().size * 0.5 / zoom
	var min_x := float(limit_left) + half.x
	var max_x := float(limit_right) - half.x
	var min_y := float(limit_top) + half.y
	var max_y := float(limit_bottom) - half.y
	position.x = (min_x + max_x) * 0.5 if min_x > max_x else clampf(position.x, min_x, max_x)
	position.y = (min_y + max_y) * 0.5 if min_y > max_y else clampf(position.y, min_y, max_y)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
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
		MOUSE_BUTTON_MIDDLE:
			_pan_held = event.pressed


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
	# 只改目标值，实际 zoom 在 _process 里平滑靠拢
	_zoom_target = clampf(_zoom_target * factor, min_zoom, max_zoom)
