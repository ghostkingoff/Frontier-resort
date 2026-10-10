extends Camera2D
## 相机：鼠标拖拽 / 滚轮缩放 / 触摸拖动 / 双指缩放 / WASD 平移。

@export var min_zoom := 0.7                    # 原 1.0，两端各 ×0.7
@export var max_zoom := 2.8                    # 原 4.0，两端各 ×0.7
@export var zoom_step := 1.15
@export var keyboard_pan_speed := 720.0
@export var middle_drag_max_speed := 2550.0    # 原 1700，提速 50%
@export var middle_drag_deadzone := 0.08       # 屏幕中心 8% 范围内不动
@export var drag_accel_rate := 9.0             # 拖动速度追赶的平滑速度（越大越跟手）
@export var glide_decay_held := 28.0           # 鼠标停下但还按着：速度衰减（越大停得越快 = 惯性越弱）
@export var glide_decay_released := 10.4       # 松手后的惯性滑行衰减
# 说明：指数衰减下「总滑行距离 ≈ 初速 / 衰减率」，即距离与衰减率成反比。
# 所以想让滑行减半，就把衰减率乘 2。当前值 = 最初 7.0 / 2.6 的 4 倍 = 滑行约为最初的 1/4。
@export var pan_ramp_rate := 5.0               # 「移动视口」按钮模式：起步 / 收尾的平滑速度
@export var glide_min_speed := 4.0             # 低于这个速度就直接停，避免无限缓慢漂移

var world: Node2D
var _pan_held := false                        # 是否按住鼠标中键
var pan_mode := false                         # 移动视口模式：进入后按住左键拖动即可平移
var _drag_held := false
var _last_mouse := Vector2.ZERO
var _touches: Dictionary = {}
var _pinch_distance := 0.0
var _zoom_target := 2.0                       # 平滑缩放的目标值
var _glide := Vector2.ZERO                    # 当前平移速度（世界像素/游戏秒），惯性就靠它
var _pan_ramp := 0.0                          # 「移动视口」按钮模式的起步/收尾进度 0~1


func set_pan_mode(on: bool) -> void:
	pan_mode = on
	_drag_held = false
	if pan_mode:
		Input.set_default_cursor_shape(Input.CURSOR_DRAG)
	else:
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func toggle_pan_mode() -> bool:
	set_pan_mode(not pan_mode)
	return pan_mode


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
	# 平移速度的目标值（世界像素/游戏秒）。惯性 = 不直接把目标值当位移，而是让 _glide 平滑追上去
	var desired := Vector2.ZERO
	var smooth := drag_accel_rate

	# 按键方向：屏幕边缘跑得越快（中键）与「移动视口」按钮模式
	var push := Vector2.ZERO
	var pushing := false
	if _pan_held:
		var view := get_viewport_rect().size
		var ratio := (get_viewport().get_mouse_position() - view * 0.5) / (view * 0.5)
		push = Vector2(_deadzone_curve(ratio.x), _deadzone_curve(ratio.y))
		pushing = true
	elif pan_mode and _drag_held:
		# 按钮模式：以鼠标离屏幕中心的方向与距离决定推力，越靠边越快（和中键同一套手感）
		var view2 := get_viewport_rect().size
		var ratio2 := (get_viewport().get_mouse_position() - view2 * 0.5) / (view2 * 0.5)
		push = Vector2(_deadzone_curve(ratio2.x), _deadzone_curve(ratio2.y))
		pushing = true

	if pushing:
		# 起步平滑：按住后 _pan_ramp 从 0 涨到 1，速度不会瞬间拉满
		_pan_ramp = minf(1.0, _pan_ramp + delta * pan_ramp_rate)
		var eased := smoothstep(0.0, 1.0, _pan_ramp)
		desired = push * middle_drag_max_speed * eased
		smooth = drag_accel_rate
	elif pan_mode and _drag_held:
		# 鼠标还在拖、但已经停在死区里：保留一部分速度，配合下面的惯性慢慢滑
		desired = _glide
		smooth = glide_decay_held
	else:
		# 松手：收尾平滑，减速到停止
		_pan_ramp = 0.0
		desired = Vector2.ZERO
		smooth = glide_decay_released

	_glide = _glide.lerp(desired, 1.0 - exp(-smooth * delta))
	if _glide.length() < glide_min_speed and desired == Vector2.ZERO:
		_glide = Vector2.ZERO
	if _glide != Vector2.ZERO:
		position += _glide * delta / zoom.x
	_last_mouse = get_viewport().get_mouse_position()
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
	if pan_mode:
		# 移动视口模式：左键按下拖动平移，滚轮照常缩放。
		# 这里要把事件吃掉，否则左键会被建造系统当成放置/拆除。
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_drag_held = event.pressed
				get_viewport().set_input_as_handled()
				return
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_by(zoom_step)
				return
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_by(1.0 / zoom_step)
				return
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
