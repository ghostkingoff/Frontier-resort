extends Node2D
## 场地上的「会走路的角色」基类：格子寻路、沿路径行走、走路取帧、卡住检测。
## 顾客（Customer）和保洁工人（Janitor）都继承它，避免两边各写一套走位代码。
##
## 子类需要：
##   - 在 setup() 里给 world 赋值（world 为空时所有走位函数都会安全退出）
##   - 调 _build_sprite_base(贴图路径) 建精灵
##   - 覆盖 _walk_speed() 与 _anim_fps()（默认按顾客的 74 像素/秒、8 帧/秒）
##   - 卡住时想自定义处理就覆盖 _on_stuck()

const CELL := 32
# 这套素材的走路图是「列 = 方向，行 = 走路帧」
const DIR_DOWN := 0
const DIR_UP := 1
const DIR_LEFT := 2
const DIR_RIGHT := 3
# 视角风格：false = 按移动方向取帧（四方向，素材自带）；
#           true  = 开罗式正面视角（永远正面朝镜头，只播走路帧 + 小跳步）
const FRONT_FACING_ONLY := false

const DEFAULT_SPEED := 74.0
const DEFAULT_ANIM_FPS := 8.0
const WAYPOINT_REACHED := 3.0     # 离路径点这么近就算走到了
const STUCK_SECONDS := 5.0        # 位置多久没变算卡住

var world: Node2D = null
var sprite: Sprite2D
var speed := DEFAULT_SPEED

var _path: Array = []
var _path_index := 0
var _walk_clock := 0.0
var _stuck_time := 0.0
var _last_pos := Vector2.ZERO


func _build_sprite_base(atlas: String) -> void:
	sprite = Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = load(atlas)
	sprite.hframes = 4
	sprite.vframes = 4
	sprite.frame = DIR_DOWN
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	add_child(sprite)


# ---------- 可覆盖的钩子 ----------

func _walk_speed() -> float:
	# 走动速度（像素/游戏秒）。顾客会被共享单车改速，所以走这个函数取
	return speed


func _anim_fps() -> float:
	return DEFAULT_ANIM_FPS


func _on_stuck() -> void:
	# 默认处理：把位置纠正到最近的可通行格，并清掉当前路径
	if world == null:
		return
	var fixed: Vector2i = world.nearest_walkable(world.world_to_cell(global_position), 12)
	if fixed.x != -9999:
		global_position = world.cell_center(fixed)
	clear_path()


# ---------- 寻路与行走 ----------

func clear_path() -> void:
	_path = []
	_path_index = 0


func has_path() -> bool:
	return not _path.is_empty() and _path_index < _path.size()


func _start_path_to(target_cell: Vector2i) -> bool:
	if world == null:
		return false
	var from_cell: Vector2i = world.world_to_cell(global_position)
	if world.is_walkable(from_cell):
		return _commit_path(from_cell, target_cell)
	# 站在建筑内部/门里（不可通行格）：逐个候选口试，**只在真正算出路时才移动**，
	# 否则会把角色挪到一个同样走不出去的地方（实测会让客人站在不可通行格上）
	for candidate in _start_cell_candidates(from_cell):
		if not world.is_walkable(candidate):
			continue
		var path: Array = world.find_path_cells(candidate, target_cell)
		if path.is_empty():
			continue
		_on_start_cell_moved(candidate)
		global_position = world.cell_center(candidate)
		_path = path
		_path_index = 0
		reset_stuck_timer()
		return true
	clear_path()
	return false


func _commit_path(from_cell: Vector2i, target_cell: Vector2i) -> bool:
	var path: Array = world.find_path_cells(from_cell, target_cell)
	if path.is_empty():
		clear_path()
		return false
	_path = path
	_path_index = 0
	reset_stuck_timer()
	return true


func _start_cell_candidates(from_cell: Vector2i) -> Array:
	# 想从建筑里走出来时优先试哪些格子。基类只给「最近的可通行格」，
	# 顾客会覆盖成「这栋楼的所有出入口（门口优先）」。
	return [world.nearest_walkable(from_cell, 12)]


func _on_start_cell_moved(_to_cell: Vector2i) -> void:
	# 从建筑里挪出来之后的收尾（顾客会在这里清掉 _inside_building 并把节点挂回场地层）
	pass


func _follow_path(delta: float) -> bool:
	# 返回 true = 路径走完了（或没有路径需要走）。调用方据此进入「到达」判定。
	if _path.is_empty():
		return true
	while _path_index < _path.size():
		var waypoint: Vector2 = world.cell_center(_path[_path_index])
		if global_position.distance_to(waypoint) < WAYPOINT_REACHED:
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
	var step := minf(_walk_speed() * delta, dist)
	global_position = from + dir * step
	_update_animation(dir, delta)


func _update_animation(dir: Vector2, delta: float) -> void:
	if sprite == null:
		return
	_walk_clock += delta
	var column := DIR_DOWN
	if not FRONT_FACING_ONLY:
		if absf(dir.x) > absf(dir.y):
			column = DIR_LEFT if dir.x < 0.0 else DIR_RIGHT
		else:
			column = DIR_DOWN if dir.y > 0.0 else DIR_UP
	var step := int(_walk_clock * _anim_fps()) % 4
	sprite.frame = step * sprite.hframes + column
	# 正面视角下用小跳步表现走动，避免看起来像在滑行
	sprite.position.y = -2.0 if (FRONT_FACING_ONLY and step % 2 == 0) else 0.0


# ---------- 卡住检测 ----------

func reset_stuck_timer() -> void:
	_stuck_time = 0.0
	_last_pos = global_position


func _check_stuck(delta: float) -> void:
	if _is_standing_still():
		# 站着不动是正常状态，不算卡住，否则会被反复传送
		reset_stuck_timer()
		return
	if global_position.distance_to(_last_pos) > 1.0:
		_last_pos = global_position
		_stuck_time = 0.0
		return
	_stuck_time += delta
	if _stuck_time < STUCK_SECONDS:
		return
	_stuck_time = 0.0
	_on_stuck()


func _is_standing_still() -> bool:
	# 子类覆盖：返回 true 表示「现在本来就不该动」
	return false
