extends "res://scripts/actors/actor.gd"
## 保洁工人：由「保洁间」雇佣的员工，会在度假村里走动清扫垃圾。
## 只负责保洁间周围半径 ROAM_RADIUS_CELLS 格以内的地砖区域，
## 超出范围的垃圾不会去清（脚下的垃圾顺手扫掉）。
## 走位（寻路 / 行走 / 取帧 / 卡住检测）继承自 actor.gd，和顾客共用一套。
## 注：这里不用 class_name，改用显式 preload 引用，避免依赖引擎的全局类缓存。

enum State { IDLE, MOVING }

const ROAM_RADIUS_CELLS := 40        # 负责范围：以保洁间为中心 40 格
const JANITOR_SPEED := 62.0          # 比顾客慢一点，看着像在慢慢扫地
const ANIM_FPS := 7.0                # 比顾客略慢，显得在慢慢走
const SEARCH_INTERVAL := 0.5         # 每 0.5 现实秒找一次垃圾
const PICK_DISTANCE := 1.6           # 走到这个距离（格）内就动手清

var home: Node2D = null              # 所属保洁间
var shift := "day"                   # 班次："day" 白班 08:00-20:00 ｜ "night" 夜班 20:00-08:00

var state: int = State.IDLE
var _target_cell := Vector2i(-9999, -9999)
var _idle_left := 0.0
var _search_timer := 0.0
var cleaned_total := 0               # 累计清掉的垃圾数


func setup(building: Node2D, world_ref: Node2D) -> void:
	home = building
	world = world_ref
	speed = JANITOR_SPEED
	_build_sprite_base("res://art/placeholder/characters/OldMan/walk.png")
	# 用一点冷色把保洁工人和游客区分开（占位素材阶段的手段）
	sprite.modulate = Color(0.72, 0.86, 1.0)
	global_position = world.cell_center(world.nearest_entry_cell(building, building.door_cell()))
	reset_stuck_timer()
	_idle_left = randf_range(0.0, 1.5)


func _anim_fps() -> float:
	return ANIM_FPS


func _is_standing_still() -> bool:
	return state != State.MOVING


func _on_stuck() -> void:
	# 走不动了：纠正位置后重新找活干
	super._on_stuck()
	_target_cell = Vector2i(-9999, -9999)
	state = State.IDLE
	_idle_left = 0.3


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
			if not has_path():
				# 路径被清掉了（铺地/盖楼使缓存失效等）：回 IDLE 重新找活干，
				# 不能停在这儿不动，否则工人会一直杵着
				state = State.IDLE
				_idle_left = 0.2
			elif _follow_path(scaled):
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
