extends Node2D
## 保洁工人：由「保洁间」雇佣的员工，会在度假村里走动清扫垃圾。
## 只负责保洁间周围半径 ROAM_RADIUS_CELLS 格以内的地砖区域，
## 超出范围的垃圾不会去清（脚下的垃圾顺手扫掉）。
## 注：这里不用 class_name，改用显式 preload 引用，避免依赖引擎的全局类缓存。

enum State { IDLE, MOVING }

const CELL := 32
const DIR_DOWN := 0
const DIR_UP := 1
const DIR_LEFT := 2
const DIR_RIGHT := 3
const FRONT_FACING_ONLY := false     # 与顾客保持一致：false = 按移动方向取帧

const ROAM_RADIUS_CELLS := 40        # 负责范围：以保洁间为中心 40 格
const CLEAN_RADIUS_CELLS := 1        # 走到垃圾旁边多近才算清掉
const SPEED := 62.0                  # 比顾客慢一点，看着像在慢慢扫地
const SEARCH_INTERVAL := 0.5         # 每 0.5 现实秒找一次垃圾
const PICK_DISTANCE := 1.6           # 走到这个距离（格）内就动手清

var home: Node2D = null              # 所属保洁间
var world: Node2D = null
var sprite: Sprite2D

var state: int = State.IDLE
var _target_cell := Vector2i(-9999, -9999)
var _path: Array = []
var _path_index := 0
var _idle_left := 0.0
var _search_timer := 0.0
var _stuck_time := 0.0
var _last_pos := Vector2.ZERO
var _walk_clock := 0.0
var cleaned_total := 0               # 累计清掉的垃圾数


func setup(building: Node2D, world_ref: Node2D) -> void:
	home = building
	world = world_ref
	_build_sprite()
	global_position = world.cell_center(building.door_cell())
	_last_pos = global_position
	_idle_left = randf_range(0.0, 1.5)


func _build_sprite() -> void:
	var walk := "res://art/placeholder/characters/OldMan/walk.png"
	var idle := "res://art/placeholder/characters/OldMan/idle.png"
	if not ResourceLoader.exists(walk):
		walk = idle
	sprite = Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = load(walk)
	sprite.hframes = 4
	sprite.vframes = 4
	sprite.frame = DIR_DOWN
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	# 用一点冷色把保洁工人和游客区分开（占位素材阶段的手段）
	sprite.modulate = Color(0.72, 0.86, 1.0)
	add_child(sprite)


func roam_radius() -> float:
	# 像素单位：负责范围的半径
	return float(ROAM_RADIUS_CELLS) * float(CELL)


func roam_radius_cells() -> int:
	return ROAM_RADIUS_CELLS


func _process(delta: float) -> void:
	if world == null or home == null or not is_instance_valid(home):
		queue_free()
		return
	if GameClock.paused or GameClock.phase == GameClock.Phase.SETTLEMENT:
		return
	var scaled := delta * GameClock.time_scale()
	_check_stuck(delta)
	# 脚下的垃圾顺手扫掉
	world.clean_litter_around(global_position, float(CELL) * 0.6, 1)
	_search_timer -= scaled
	if _search_timer <= 0.0:
		_search_timer = SEARCH_INTERVAL
		_look_for_litter()
	match state:
		State.IDLE:
			_idle_left -= scaled
			if _idle_left <= 0.0:
				_start_roam()
		State.MOVING:
			if _follow_path(scaled):
				state = State.IDLE
				_idle_left = randf_range(0.6, 2.0)


# ---------- 找垃圾 ----------

func _look_for_litter() -> void:
	var target := _nearest_litter_cell()
	if target.x == -9999:
		return
	if _target_cell == target and state == State.MOVING:
		return                       # 已经在去的路上
	if global_position.distance_to(world.cell_center(target)) <= float(CELL) * PICK_DISTANCE:
		if world.remove_litter_at(target) > 0:
			cleaned_total += 1
		_target_cell = Vector2i(-9999, -9999)
		return
	_target_cell = target
	if not _start_path_to(target):
		_target_cell = Vector2i(-9999, -9999)


func _nearest_litter_cell() -> Vector2i:
	# 只认负责范围内的垃圾：超出 40 格的不去
	var radius := roam_radius()
	var best := Vector2i(-9999, -9999)
	var best_dist := INF
	for cell in world.litter_cells.keys():
		var d: float = world.cell_center(cell).distance_to(home.global_position)
		if d > radius:
			continue
		var own: float = global_position.distance_to(world.cell_center(cell))
		if own < best_dist:
			best_dist = own
			best = cell
	return best


func has_litter_at(cell: Vector2i) -> bool:
	return world != null and world.litter_cells.has(cell)


func current_target() -> Vector2i:
	# 当前正在去清的垃圾格（没有就是 (-9999, -9999)）
	return _target_cell


# ---------- 走动 ----------

func _start_roam() -> void:
	var cell := _pick_roam_cell()
	if cell.x == -9999:
		_idle_left = randf_range(1.0, 2.5)
		return
	_target_cell = Vector2i(-9999, -9999)
	if _start_path_to(cell):
		state = State.MOVING
	else:
		_idle_left = randf_range(1.0, 2.5)


func _pick_roam_cell() -> Vector2i:
	# 在负责范围内的地砖上随机挑一个能走到的点
	var radius := roam_radius()
	var origin: Vector2 = home.global_position
	for _attempt in range(24):
		# 每次重新取一遍：这份缓存会因为铺地/盖楼/拆楼被清空，
		# 拿旧引用去取 size() 会变成 0，就出现「Modulo by zero」
		var cells: Array = world.walkable_path_cells()
		if cells.is_empty():
			return Vector2i(-9999, -9999)
		var candidate: Vector2i = cells[randi() % cells.size()]
		var d: float = world.cell_center(candidate).distance_to(origin)
		if d > radius:
			continue
		if global_position.distance_to(world.cell_center(candidate)) < float(CELL) * 2.0:
			continue                 # 太近了，换个地方
		if not world.find_path_cells(world.world_to_cell(global_position), candidate).is_empty():
			return candidate
	return Vector2i(-9999, -9999)


func _start_path_to(target_cell: Vector2i) -> bool:
	var from_cell: Vector2i = world.world_to_cell(global_position)
	if not world.is_walkable(from_cell):
		var fixed: Vector2i = world.nearest_walkable(from_cell, 12)
		if fixed.x == -9999:
			return false
		from_cell = fixed
		global_position = world.cell_center(fixed)
	var path: Array = world.find_path_cells(from_cell, target_cell)
	if path.is_empty():
		_path = []
		_path_index = 0
		return false
	_path = path
	_path_index = 0
	_stuck_time = 0.0
	_last_pos = global_position
	return true


func _follow_path(delta: float) -> bool:
	if _path.is_empty():
		return true
	while _path_index < _path.size():
		var waypoint: Vector2 = world.cell_center(_path[_path_index])
		if global_position.distance_to(waypoint) < 3.0:
			_path_index += 1
			continue
		_step_towards(waypoint, delta)
		return false
	return true


func _step_towards(point: Vector2, delta: float) -> void:
	var from := global_position
	var dist := from.distance_to(point)
	if dist < 1.0:
		return
	var dir := (point - from) / dist
	# 高倍速下一帧能走很远，必须夹住步长，否则会冲过路径拐点
	var step := minf(SPEED * delta, dist)
	global_position = from + dir * step
	_update_animation(dir, delta)


func _update_animation(dir: Vector2, delta: float) -> void:
	_walk_clock += delta
	var column := DIR_DOWN
	if not FRONT_FACING_ONLY:
		if absf(dir.x) > absf(dir.y):
			column = DIR_LEFT if dir.x < 0.0 else DIR_RIGHT
		else:
			column = DIR_DOWN if dir.y > 0.0 else DIR_UP
	var step := int(_walk_clock * 7.0) % 4
	sprite.frame = step * sprite.hframes + column
	sprite.position.y = -2.0 if (FRONT_FACING_ONLY and step % 2 == 0) else 0.0


func _check_stuck(delta: float) -> void:
	# 只在「正在走路」时才算卡住：站在那儿发呆是正常的
	if state != State.MOVING:
		_stuck_time = 0.0
		_last_pos = global_position
		return
	if global_position.distance_to(_last_pos) > 1.0:
		_last_pos = global_position
		_stuck_time = 0.0
		return
	_stuck_time += delta
	if _stuck_time < 5.0:
		return
	_stuck_time = 0.0
	# 走不动了：纠正位置后重新找活干
	var fixed: Vector2i = world.nearest_walkable(world.world_to_cell(global_position), 12)
	if fixed.x != -9999:
		global_position = world.cell_center(fixed)
	_target_cell = Vector2i(-9999, -9999)
	_path = []
	_path_index = 0
	state = State.IDLE
	_idle_left = 0.3
