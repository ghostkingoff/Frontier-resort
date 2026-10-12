extends Node2D
## 玩家角色（常驻 NPC）：平时待在招待厅里。
## 进入「自我操纵模式」后可用 WASD / 方向键走动；按 F 与建筑交互（当前：进出招待厅）。
## 退出模式后停在原地；24 点结算时如果不是操纵模式，会由 HUD 放回招待厅里。

signal use_reception_requested     # 在厅外按 F：请求「回到招待厅并退出自我操纵模式」（由 HUD 弹确认框）

const SPEED := 96.0                # 走动速度（像素/游戏秒，比顾客稍快一点）
const LABEL_TEXT := "玩家"
const INTERACT_RANGE := 96.0       # 在厅外离门口多近才能按 F（像素）
const CONTROLLED_Z := 3900         # 操纵模式下的层级：盖过屋顶，保证角色始终可见
# 碰撞框：只盖下半身（脚部）。俯视角下往上走时上半身允许越出格子；
# 往下走时脚不会伸进不可行走的地砖——框的下边界贴到交界线就停。
# （四边各内缩 0.5 像素：避免站在「边界线正上方」时被浮点误差判成下一格）
const BODY_RECT := Rect2(-9.5, 1.5, 19.0, 14.0)
const MAX_STEP := 8.0              # 单次推进的像素上限（高倍速下不会一帧跨过整格）

var world: Node2D = null
var sprite: Sprite2D
var label: Label
var controlled := false            # 是否处于自我操纵模式
var inside_reception := false      # 当前是否在招待厅里
var _inside_rect := Rect2()        # 在厅内时的活动范围（全局坐标）
var _walk_clock := 0.0
var _facing := 0                   # 朝向：0 下 1 上 2 左 3 右（和走路图的列一致）


func setup(world_ref: Node2D) -> void:
	world = world_ref
	add_to_group("player_avatar")
	_build_sprite()
	_build_label()
	reset_to_reception()


func _build_sprite() -> void:
	sprite = Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = load("res://art/placeholder/characters/Boy/walk.png")
	sprite.hframes = 4
	sprite.vframes = 4
	sprite.frame = 0
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	sprite.modulate = Color(1.0, 0.93, 0.68)     # 暖色一点，和普通游客区分
	add_child(sprite)


func _build_label() -> void:
	label = Label.new()
	label.text = LABEL_TEXT
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.72, 0.95))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-36, -54)
	label.size = Vector2(72, 22)
	add_child(label)


func set_controlled(on: bool) -> void:
	controlled = on
	_walk_clock = 0.0
	_set_frame(0, _facing)
	_apply_z()


func _process(delta: float) -> void:
	if world == null:
		return
	_apply_z()
	if not controlled:
		return
	if GameClock.paused or GameClock.phase == GameClock.Phase.SETTLEMENT:
		return
	if GameState.text_input_active:
		return      # 指令台打字中：WASD 是输入文字，不是走路
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir == Vector2.ZERO:
		return
	move_step(dir.normalized(), delta)


func move_step(dir: Vector2, delta: float) -> void:
	# 走一小步（单独抽出来方便冒烟测试）。碰撞按「身体框」判定：
	# 走不通的轴不动（可以沿墙滑）；每一步最多 8 像素，避免高倍速下一帧跨格。
	if dir == Vector2.ZERO:
		return
	var remaining := SPEED * delta * GameClock.time_scale()
	if inside_reception:
		var target := global_position + dir * remaining
		target = Vector2(
			clampf(target.x, _inside_rect.position.x, _inside_rect.end.x),
			clampf(target.y, _inside_rect.position.y, _inside_rect.end.y))
		global_position = target
		_animate(dir, delta)
		return
	var guard := 0
	while remaining > 0.001 and guard < 24:
		guard += 1
		var chunk := minf(remaining, MAX_STEP)
		remaining -= chunk
		var from := global_position
		var target := from + dir * chunk
		var moved := from
		if _can_stand(Vector2(target.x, from.y)):
			moved.x = target.x
		if _can_stand(Vector2(moved.x, target.y)):
			moved.y = target.y
		if moved.is_equal_approx(from):
			break                      # 两个轴都走不通：停下
		global_position = moved
	_animate(dir, delta)


func _can_stand(at: Vector2) -> bool:
	# 只判定「下半身框」（俯视角）：四个角都要落在可行走的格子上。
	# 往上走时上半身允许越出格子；往下走时脚不会伸进不可行走的地砖。
	if world == null:
		return false
	var tl := at + BODY_RECT.position
	var br := at + BODY_RECT.end
	return _cell_walkable(tl) \
		and _cell_walkable(Vector2(br.x, tl.y)) \
		and _cell_walkable(Vector2(tl.x, br.y)) \
		and _cell_walkable(br)


func _cell_walkable(at: Vector2) -> bool:
	var cell: Vector2i = world.world_to_cell(at)
	return world.is_walkable(cell) and not world.wall_cells.has(cell)


func _animate(dir: Vector2, delta: float) -> void:
	_walk_clock += delta * GameClock.time_scale()
	if absf(dir.x) > absf(dir.y):
		_facing = 2 if dir.x < 0.0 else 3
	else:
		_facing = 0 if dir.y > 0.0 else 1
	_set_frame(int(_walk_clock * 8.0) % 4, _facing)


func _set_frame(step: int, column: int) -> void:
	if sprite:
		sprite.frame = step * sprite.hframes + column


func _apply_z() -> void:
	if controlled:
		z_index = CONTROLLED_Z
	elif inside_reception:
		z_index = 0                      # 跟着室内层排：开屋顶时会被屋顶盖住
	else:
		z_index = int(global_position.y)


# ---------- 与招待厅交互 ----------

func try_interact() -> String:
	# 返回 "leave"（从厅里出来）/ "use_reception"（在门口请求回厅并退模式）/ ""（附近没有可交互的东西）
	if inside_reception:
		leave_reception()
		return "leave"
	if _near_reception():
		use_reception_requested.emit()
		return "use_reception"
	return ""


func interaction_hint() -> String:
	if not controlled:
		return ""
	if inside_reception:
		return "按 F 离开招待厅"
	if _near_reception():
		return "按 F 使用招待厅（回厅内并退出自我操纵模式）"
	return "WASD / 方向键 移动 ｜ 走到招待厅门口按 F 可回去"


func _near_reception() -> bool:
	if world == null:
		return false
	var reception: Building = world.reception()
	if reception == null:
		return false
	return global_position.distance_to(world.cell_center(reception.door_cell())) <= INTERACT_RANGE


func enter_reception() -> void:
	if world == null:
		return
	var reception: Building = world.reception()
	if reception == null:
		return
	inside_reception = true
	_inside_rect = Rect2(reception.global_position, Vector2(reception.footprint) * 32.0).grow(-10.0)
	reparent(reception.interior, true)
	global_position = reception.interior_point()
	_apply_z()


func leave_reception() -> void:
	if world == null:
		return
	var reception: Building = world.reception()
	if reception == null:
		return
	inside_reception = false
	reparent(world, true)
	global_position = world.cell_center(reception.door_cell())
	_apply_z()


func detach_to(at: Vector2) -> void:
	# 招待厅被拆/清场时调用：从楼里挪出来，别跟着一起被释放
	inside_reception = false
	if world != null:
		reparent(world, true)
	global_position = at
	_apply_z()


func reset_to_reception() -> void:
	enter_reception()
