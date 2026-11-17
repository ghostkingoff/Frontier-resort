class_name World
extends Node2D
## 世界：地面、装饰、建筑、顾客，以及格子判定。
## 坐标约定：一格 = 32×32 像素，位置 = 格子左上角。

signal roof_mode_changed(show_roof: bool)
signal building_placed(building)
signal building_removed(building)

const CELL := 32
const TILESET_PATH := "res://art/generated/spring_ground_tileset.tres"
const PLAYER_CHARACTER := preload("res://scripts/actors/player_character.gd")
const PINE_DIR := "res://art/characters/trees/pine/"

# 地面类型：草地 / 荒地（不可通行）、修剪草坪 / 地砖 / 石砖地（可通行）
const GROUND_WILD := "grass"
const GROUND_LAWN := "lawn"
const GROUND_PATH := "path"
const GROUND_DENSE_GRASS := "dense_grass"
const GROUND_STONE_TILE := "stone_tile"
const GROUND_WASTELAND := "wasteland"
const WALL_TILE_PATH := "res://art/generated/wall_tile.png"
const ENTRANCE_X0 := 62      # 度假村入口（底边缺口）对应的列
const ENTRANCE_X1 := 63
const STREET_ROW := 40       # 村里的横向主街
const STREET_X0 := 14
const STREET_X1 := 102

enum ViewMode { ROOF, INTERIOR, GROUND }   # 当前显示层：屋顶 / 屋内 / 地面

@export var grid_size := Vector2i(128, 80)          # 面积是原来的 4 倍
@export var build_area := Rect2i(3, 3, 122, 66)     # 围墙内：x 3~124、y 3~68
@export var road_row := 72

var ground: TileMapLayer
var ground_lawn: TileMapLayer
var ground_path: TileMapLayer
var ground_misc: TileMapLayer
var decor: Node2D
var buildings_root: Node2D
var customers_root: Node2D
var walls_root: Node2D
var map_layer_root: Node2D
var outdoor_sort: Node2D
var interior_sort: Node2D
var ground_sort: Node2D
var active_actor_sort: Node2D

var buildings: Array = []
var occupancy: Dictionary = {}
var view_mode: int = ViewMode.ROOF
var show_roofs := true                  # 兼容旧工具：等价于 view_mode == ROOF
var ground_types: Dictionary = {}      # cell -> 地面类型（不记录就是地图默认的普通草地）
var wall_cells: Dictionary = {}        # 度假村围墙占的格子
var _astar: AStarGrid2D
var _astar_dirty := true
var _astar_dirty_cells: Dictionary = {}  # 只登记「改动过的格子」，寻路时增量更新（见 _ensure_astar）
var _reachable_cache: Dictionary = {}   # Building -> bool，避免每次生成客人都重算路径
var _path_cells_cache: Array = []       # 所有可通行的地砖格子，用于闲逛选点
var litter_cells: Dictionary = {}       # 垃圾：cell -> Sprite2D
var litter_root: Node2D
var staff_root: Node2D                   # 保洁工人等在场地上走动的员工
var player_avatar: Node2D = null         # 玩家角色（常驻招待厅；自我操纵模式里由玩家控制）


func _ready() -> void:
	add_to_group("world")
	_create_layers()
	_init_ground_types()
	_build_ground()
	_build_walls()
	_scatter_decorations()
	_spawn_starter_buildings()
	_spawn_player_avatar()
	set_process(true)      # 每帧推进店铺灯光


func _spawn_player_avatar() -> void:
	# 玩家角色：常驻在招待厅里的 NPC；进入自我操纵模式后由玩家控制
	var avatar: Node2D = PLAYER_CHARACTER.new()
	avatar.name = "PlayerAvatar"
	add_child(avatar)
	avatar.setup(self)
	player_avatar = avatar


func outdoor_customer_count() -> int:
	var count := 0
	for customer in get_tree().get_nodes_in_group("customers"):
		if customer != null and is_instance_valid(customer) \
				and not customer.is_queued_for_deletion():
			count += 1
	return count


func _process(_delta: float) -> void:
	pass

func _create_layers() -> void:
	# 三层显示：
	#   地面层 = ground（地砖，z=-100）+ decor（装饰，z=-50），永远在最底下
	#   屋内层 = 每栋建筑内部的 InteriorLayer（地板 + 墙框 + 进店客人）
	#   屋顶层 = 每栋建筑内部的 RoofLayer（外墙 / 侧面 / 正面 / 屋顶，盖在屋内层上）
	# 建筑本身仍按 y 排序（z_index = position.y），前后遮挡与人物穿插都保持正确。
	map_layer_root = Node2D.new()
	map_layer_root.name = "MapLayer"
	map_layer_root.z_index = -1000
	add_child(map_layer_root)

	var shared_tileset: TileSet = null
	if ResourceLoader.exists(TILESET_PATH):
		shared_tileset = load(TILESET_PATH)
	ground = _make_ground_layer("GroundGrass", shared_tileset)
	ground_lawn = _make_ground_layer("GroundLawn", shared_tileset)
	ground_path = _make_ground_layer("GroundPath", shared_tileset)
	ground_misc = _make_ground_layer("GroundMisc", shared_tileset)

	outdoor_sort = Node2D.new()
	outdoor_sort.name = "OutdoorYSort"
	outdoor_sort.y_sort_enabled = true
	outdoor_sort.z_index = 0
	add_child(outdoor_sort)

	interior_sort = Node2D.new()
	interior_sort.name = "InteriorLayerGroup"
	interior_sort.y_sort_enabled = true
	interior_sort.z_index = 1000
	interior_sort.visible = false
	add_child(interior_sort)

	ground_sort = Node2D.new()
	ground_sort.name = "GroundLayerGroup"
	ground_sort.y_sort_enabled = true
	ground_sort.z_index = 2000
	ground_sort.visible = false
	add_child(ground_sort)

	# 室外地图对象共享同一套 Y 排序；分类变量保留为兼容别名。
	decor = outdoor_sort
	customers_root = outdoor_sort
	litter_root = outdoor_sort
	staff_root = outdoor_sort
	walls_root = outdoor_sort
	active_actor_sort = outdoor_sort

	buildings_root = Node2D.new()
	buildings_root.name = "Buildings"
	add_child(buildings_root)


func _make_ground_layer(layer_name: String, shared_tileset: TileSet) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.z_index = 0
	layer.tile_set = shared_tileset
	map_layer_root.add_child(layer)
	return layer


func _build_walls() -> void:
	# 围着建造区一圈围墙，底边中间留出入口
	wall_cells.clear()
	var left := build_area.position.x - 1
	var right := build_area.end.x
	var top := build_area.position.y - 1
	var bottom := build_area.end.y
	var gap_from := ENTRANCE_X0
	var gap_to := ENTRANCE_X1
	for x in range(left, right + 1):
		if not (x >= gap_from and x <= gap_to):
			wall_cells[Vector2i(x, bottom)] = true
		wall_cells[Vector2i(x, top)] = true
	for y in range(top, bottom + 1):
		wall_cells[Vector2i(left, y)] = true
		wall_cells[Vector2i(right, y)] = true
	for cell in wall_cells.keys():
		_spawn_wall(cell)


func _spawn_wall(cell: Vector2i) -> void:
	if not ResourceLoader.exists(WALL_TILE_PATH):
		return
	var s := Sprite2D.new()
	s.texture = load(WALL_TILE_PATH)
	s.centered = false
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.position = cell_to_world(cell)
	s.z_index = 0
	walls_root.add_child(s)


func is_wall(cell: Vector2i) -> bool:
	return wall_cells.has(cell)


func _build_ground() -> void:
	if ground.tile_set == null:
		push_warning("[World] 缺少地面 TileSet，先运行 tools/build_tileset.gd 生成。")
		return
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			_paint_ground_tile(Vector2i(x, y))


func _init_ground_types() -> void:
	ground_types.clear()
	# 主路（横穿地图）
	for x in range(grid_size.x):
		for y in range(road_row, road_row + 2):
			ground_types[Vector2i(x, y)] = GROUND_PATH
	# 从主路通进村里的中央大道
	for y in range(STREET_ROW + 1, road_row):
		for x in range(ENTRANCE_X0, ENTRANCE_X1 + 1):
			ground_types[Vector2i(x, y)] = GROUND_PATH
	# 横向主街
	for x in range(STREET_X0, STREET_X1 + 1):
		for y in range(STREET_ROW, STREET_ROW + 2):
			ground_types[Vector2i(x, y)] = GROUND_PATH
	# 每栋起始建筑门口到主街的小路
	for door_x in [8, 20, 32, 44, 56, 72, 84, 96]:
		for y in range(34, STREET_ROW + 2):
			ground_types[Vector2i(door_x, y)] = GROUND_PATH
	# 招待厅（入口旁）门口接到中央大道
	for x in range(ENTRANCE_X0, 67):
		ground_types[Vector2i(x, 66)] = GROUND_PATH


func _paint_ground_tile(cell: Vector2i) -> void:
	if ground.tile_set == null:
		return
	var kind := str(ground_types.get(cell, GROUND_WILD))
	var tile_cfg := DataRegistry.ground_tile_config(kind)
	var coords: Array = tile_cfg.get("coords", [3, 3])
	for layer in [ground, ground_lawn, ground_path, ground_misc]:
		(layer as TileMapLayer).erase_cell(cell)
	var target := ground
	if kind == GROUND_PATH or kind == GROUND_STONE_TILE:
		target = ground_path
	elif kind == GROUND_LAWN:
		target = ground_lawn
	elif kind == GROUND_DENSE_GRASS or kind == GROUND_WASTELAND:
		target = ground_misc
	target.set_cell(cell, int(tile_cfg.get("source", 0)),
		Vector2i(int(coords[0]), int(coords[1])))


func set_ground(cell: Vector2i, kind: String) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return
	if occupancy.has(cell) and ground_kind_is_walkable(kind):
		return
	if kind == GROUND_WILD:
		ground_types.erase(cell)
	else:
		ground_types[cell] = kind
	_paint_ground_tile(cell)
	_path_cells_cache.clear()
	_mark_astar_cell(cell)


func ground_type(cell: Vector2i) -> String:
	return str(ground_types.get(cell, GROUND_WILD))


func ground_kind_is_walkable(kind: String) -> bool:
	return kind != GROUND_WILD and kind != GROUND_DENSE_GRASS and kind != GROUND_WASTELAND


func can_paint_ground(cell: Vector2i, kind: String) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return false
	if is_wall(cell) or ground_type(cell) == kind:
		return false
	if occupancy.has(cell) and ground_kind_is_walkable(kind):
		return false
	return true


func is_walkable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return false
	var kind := ground_type(cell)
	if not ground_kind_is_walkable(kind):
		return false
	if occupancy.has(cell):
		return false
	return true


func ground_kind_name(cell: Vector2i) -> String:
	match ground_type(cell):
		GROUND_PATH:
			return "地砖"
		GROUND_LAWN:
			return "修剪草坪"
		GROUND_DENSE_GRASS:
			return "茂密草地（不可行走）"
		GROUND_STONE_TILE:
			return "石砖地"
		GROUND_WASTELAND:
			return "荒地（不可建造 / 不可行走）"
		_:
			return "草地"


# ---------- 寻路 ----------

func _ensure_astar() -> void:
	if _astar == null:
		_astar = AStarGrid2D.new()
		_astar.region = Rect2i(0, 0, grid_size.x, grid_size.y)
		_astar.cell_size = Vector2(CELL, CELL)
		_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
		_astar.update()
		# 新建的 AStarGrid2D 里所有点都是「可通行」的，必须立刻按地图填一遍。
		# 不能只置 _astar_dirty 就走增量分支：那时候脏格表是空的，会直接返回，
		# 网格就一直是全空 = 客人能穿过建筑（实测 10240 格里 9488 格状态是错的）。
		for y in range(grid_size.y):
			for x in range(grid_size.x):
				var c := Vector2i(x, y)
				_astar.set_point_solid(c, not is_walkable(c))
		_astar_dirty = false
		_astar_dirty_cells.clear()
		return
	# 增量优先：改了哪几格就只更新哪几格。
	# 全量重建要遍历 10240 格，实测 5.48 毫秒；铺一格地只影响 1 格，
	# 增量更新后连续铺路从 5.45 毫秒/格降到接近零。
	if not _astar_dirty_cells.is_empty():
		for c in _astar_dirty_cells.keys():
			var cc: Vector2i = c
			if _astar.region.has_point(cc):
				_astar.set_point_solid(cc, not is_walkable(cc))
		_astar_dirty_cells.clear()
		_astar_dirty = false
		_reachable_cache.clear()
		_path_cells_cache.clear()
		return
	if not _astar_dirty:
		return
	# 兜底：整表重建（读档、或调用方直接置脏时）
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var c2 := Vector2i(x, y)
			_astar.set_point_solid(c2, not is_walkable(c2))
	_astar_dirty = false
	_reachable_cache.clear()
	_path_cells_cache.clear()


func _mark_astar_cell(cell: Vector2i) -> void:
	_astar_dirty_cells[cell] = true
	_astar_dirty = true


func _mark_astar_cells(cells: Array) -> void:
	for c in cells:
		var cc: Vector2i = c
		_astar_dirty_cells[cc] = true
	_astar_dirty = true


func find_path_cells(from: Vector2i, to: Vector2i) -> Array:
	_ensure_astar()
	if not _astar.region.has_point(from) or not _astar.region.has_point(to):
		return []
	if _astar.is_point_solid(from) or _astar.is_point_solid(to):
		return []
	var ids := _astar.get_id_path(from, to)
	return ids


func nearest_walkable(cell: Vector2i, radius: int = 3) -> Vector2i:
	# 找附近最近的可通行格（客人站在门里 / 建筑格子上时用）
	if is_walkable(cell):
		return cell
	for r in range(1, radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c := cell + Vector2i(dx, dy)
				if is_walkable(c):
					return c
	return Vector2i(-9999, -9999)


func entrance_cell(for_cell: Vector2i) -> Vector2i:
	# 客人从主路两端进场，取离目标更近的一侧
	if for_cell.x <= grid_size.x / 2:
		return Vector2i(0, road_row)
	return Vector2i(grid_size.x - 1, road_row)


func building_reachable(b: Building) -> bool:
	# 只要外圈任意一格能走通，就算这栋楼可达（门口优先，但不强求）
	if b == null or not is_instance_valid(b):
		return false
	if _reachable_cache.has(b):
		return bool(_reachable_cache[b])
	var ok: bool = best_entry_cell(b, b.global_position).x != -9999
	_reachable_cache[b] = ok
	return ok


func best_entry_cell(b: Building, from: Vector2) -> Vector2i:
	# 选一个「能走到的」出入口：优先贴图上的门口，不通再从外圈里挑离 from 最近的。
	# 返回 (-9999, -9999) 表示这栋楼现在一个口都进不去。
	if b == null or not is_instance_valid(b):
		return Vector2i(-9999, -9999)
	var door: Vector2i = b.door_cell()
	if is_walkable(door) and not find_path_cells(entrance_cell(door), door).is_empty():
		return door
	# 门口不通：外圈里按离 from 的距离依次试
	var candidates: Array = []
	for c in b.perimeter_cells():
		if not is_walkable(c):
			continue
		candidates.append(c)
	candidates.sort_custom(func(a: Vector2i, c: Vector2i) -> bool:
		return cell_center(a).distance_to(from) < cell_center(c).distance_to(from))
	for c in candidates:
		if not find_path_cells(entrance_cell(c), c).is_empty():
			return c
	return Vector2i(-9999, -9999)


func nearest_entry_cell(b: Building, from: Vector2i, radius: int = 12) -> Vector2i:
	# 从建筑里出来时用：找离 from 最近的一个可通行出入口（同样优先门口）
	if b == null or not is_instance_valid(b):
		return Vector2i(-9999, -9999)
	var door: Vector2i = b.door_cell()
	if is_walkable(door):
		return door
	var best := Vector2i(-9999, -9999)
	var best_dist := INF
	for c in b.perimeter_cells():
		if not is_walkable(c):
			continue
		var d: float = cell_center(c).distance_to(cell_center(from))
		if d < best_dist:
			best_dist = d
			best = c
	if best.x != -9999:
		return best
	# 外圈全不可通行（很少见）：退回「最近的可通行格」，同样要检查哨兵值
	var fallback: Vector2i = nearest_walkable(from, radius)
	return fallback if fallback.x != -9999 else Vector2i(-9999, -9999)


func _scatter_decorations() -> void:
	var defs := DataRegistry.decorations()
	if defs.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260928
	# 地图边缘的树线
	for x in range(0, grid_size.x, 2):
		_try_decor(rng, defs, Vector2i(x, 0), true)
		_try_decor(rng, defs, Vector2i(x, grid_size.y - 1), true)
	for y in range(2, grid_size.y - 2, 2):
		_try_decor(rng, defs, Vector2i(0, y), true)
		_try_decor(rng, defs, Vector2i(grid_size.x - 1, y), true)
	# 建造区外的零散装饰（地图放大到 4 倍，数量同步增加）
	for i in range(110):
		var cell := Vector2i(rng.randi_range(4, grid_size.x - 5), rng.randi_range(3, grid_size.y - 4))
		if build_area.has_point(cell):
			continue
		_try_decor(rng, defs, cell, false)


func _try_decor(rng: RandomNumberGenerator, defs: Array, cell: Vector2i, force_tree: bool) -> void:
	var pool: Array = []
	for d in defs:
		if str(d.get("id", "")) == "pond":
			continue
		if force_tree and not str(d.get("id", "")).begins_with("tree"):
			continue
		var w := int(d.get("weight", 1))
		for _i in range(w):
			pool.append(d)
	if pool.is_empty():
		return
	var def: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	spawn_decoration(def, cell)


func spawn_decoration(def: Dictionary, cell: Vector2i) -> Node2D:
	if str(def.get("id", "")).begins_with("tree"):
		return _spawn_pine_decoration(cell)
	var rect_arr: Array = def.get("rect", [0, 0, 16, 16])
	var s := Sprite2D.new()
	s.texture = load(def.get("atlas", ""))
	s.region_enabled = true
	s.region_rect = Rect2(rect_arr[0], rect_arr[1], rect_arr[2], rect_arr[3])
	s.centered = false
	s.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	var pos := Vector2(cell.x * CELL, cell.y * CELL)
	s.position = pos + Vector2(0, CELL) - Vector2(0, rect_arr[3] * DataRegistry.SPRITE_SCALE)
	s.z_index = 0
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	decor.add_child(s)
	return s


func _spawn_pine_decoration(cell: Vector2i) -> Node2D:
	var root := Node2D.new()
	root.name = "PineDecoration"
	root.position = cell_center(cell) + Vector2(0.0, CELL * 0.5)
	root.add_to_group("lighting_pines")
	decor.add_child(root)

	var sprite := Sprite2D.new()
	sprite.name = "PineSurface"
	sprite.texture = load(PINE_DIR + "color.png")
	sprite.centered = false
	sprite.position = Vector2(-32.0, -128.0)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.add_to_group("lighting_surface_sprites")
	root.add_child(sprite)
	return root


func _spawn_starter_buildings() -> void:
	# 初始模式：8 栋常用建筑，门口小路都已经接上主街
	if SaveManager.new_game_mode == SaveManager.MODE_FULL_TEST:
		_spawn_all_buildings()
		place_building("reception", Vector2i(64, 62))
		return
	place_building("reception", Vector2i(64, 62))
	# 每一栋都按「实际门口那一格」重新铺一条小路接到主街：
	# 之前 _init_ground_types() 里写死的 door_x 是按老布局算的，宽度一变就会错位一格
	# （实测「现代风度假屋」的门被压在建筑底下 → 整栋楼永远走不到，客人也住不进去）
	_place_starter("lodge_ordinary", Vector2i(18, 34))
	_place_starter("lodge_nature", Vector2i(30, 34))
	_place_starter("lodge_modern", Vector2i(6, 34))
	_place_starter("food_diner", Vector2i(43, 34))
	_place_starter("shop_small", Vector2i(55, 34))
	_place_starter("food_bar", Vector2i(70, 34))
	_place_starter("clinic_small", Vector2i(82, 34))
	_place_starter("showroom", Vector2i(94, 30))


func _place_starter(id: String, cell: Vector2i) -> Building:
	var b: Building = place_building(id, cell)
	if b != null:
		var door := b.door_cell()
		_pave_column(door, STREET_ROW + 1)               # 门口那一列铺到主街高度
		# 主街本身只从 STREET_X0 铺到 STREET_X1：靠边的建筑（如最左边的现代风度假屋）
		# 光铺竖列接不上主街，还要补一条横路把它连过去，否则整栋楼走不到
		if door.x < STREET_X0:
			_pave_row(STREET_ROW + 1, door.x, STREET_X0)
		elif door.x > STREET_X1:
			_pave_row(STREET_ROW + 1, STREET_X1, door.x)
	return b


func _spawn_all_buildings() -> void:
	# 完全测试模式：把建造菜单里能建的所有建筑都摆上去，并自动接好道路。
	# 排布原则（10-12 调整）：
	#   · 建筑**不压任何已有路面**（横向主街 / 中央大道 / 主路 / 小路都不碰），
	#     所以中间主干道永远是通的、干干净净
	#   · 建筑全部摆在主街上方的空地里，按「货架」分横带：矮的排下带、高的排上带
	#   · 左右各先铺一条竖路，每条横带再铺一条横路把两条竖路连通——
	#     最下面那条横带紧贴主街，正面就是店铺街；上两条横带左右都有出入口，不用绕远路
	var ids := _full_test_building_ids()
	var shelf_ys := [38, 27, 16]        # 横带基线（都在主街 40 上方；间距 11 格，最高的 7 格楼也放得下）
	var x0: int = build_area.position.x + 1             # 最外圈是围墙，从里面一格开始
	var x1: int = build_area.end.x - 1
	var conn_left: int = x0                             # 左侧竖路（贴围墙）
	var conn_right: int = x1 - 2                        # 右侧竖路
	# 两条竖路先铺好：保证横带两头都通，也让建筑自动避开它们（_shelf_spot_ok 不许压路面）
	_pave_column(Vector2i(conn_left, build_area.position.y + 1), STREET_ROW + 1)
	_pave_column(Vector2i(conn_right, build_area.position.y + 1), STREET_ROW + 1)
	var shelf_index := 0
	var cursor := conn_left + 2
	var placed: Array = []
	var skipped: Array = []

	for id in ids:
		var data := DataRegistry.get_building(id)
		var f: Array = data.get("footprint", [3, 3])
		var w := int(f[0])
		var h := int(f[1])
		# 找到一条放得下这栋建筑的横带：往右挪到能放为止，挪到头就换上一条横带
		var spot := Vector2i(-9999, -9999)
		var base_used := 0
		while shelf_index < shelf_ys.size():
			var base: int = shelf_ys[shelf_index]
			var cell := Vector2i(cursor, base - h + 1)
			if cursor + w <= conn_right and cell.y >= build_area.position.y + 1 \
					and _shelf_spot_ok(cell, Vector2i(w, h)):
				spot = cell
				base_used = base
				break
			cursor += 1
			if cursor + w > conn_right:
				shelf_index += 1
				cursor = conn_left + 2        # 换到上一条横带，从最左边重新排
		if spot.x == -9999:
			skipped.append(id)
			continue
		if place_building(id, spot) == null:
			skipped.append(id)
			cursor += w + 2
			continue
		var b: Building = buildings[buildings.size() - 1]
		# 门口就在横带路上（建筑底边下一格）：把这一格和整段横带路铺好
		_pave_cell(b.door_cell())
		_pave_row(base_used + 1, cursor, cursor + w - 1)
		placed.append(b)
		cursor += w + 2

	# 每条横带铺满一条横路：左接左竖路、右接右竖路，中间穿过所有门口
	for base in shelf_ys:
		_pave_row(base + 1, conn_left, conn_right)
	for b in placed:
		if b.needs_staff():
			b.fill_staff()
	print("[World] 完全测试模式：放置建筑 %d 栋（竖路第 %d / %d 列）%s" % [
		placed.size(), conn_left, conn_right,
		"" if skipped.is_empty() else "，排不下：%s" % ", ".join(skipped)])


func _shelf_spot_ok(cell: Vector2i, footprint: Vector2i) -> bool:
	# 货架摆放的额外限制：不能压到任何已有路面（主干道 / 横带路 / 起始小路），保证路网通畅
	if not can_place(cell, footprint):
		return false
	for y in range(cell.y, cell.y + footprint.y):
		for x in range(cell.x, cell.x + footprint.x):
			if ground_type(Vector2i(x, y)) == GROUND_PATH:
				return false
	return true


func _full_test_building_ids() -> Array:
	# 建造菜单里能看到的全部建筑；招待厅由初始化流程单独摆放，这里跳过
	var ids: Array = []
	for id in DataRegistry.building_order:
		if id == "reception":
			continue
		if bool(DataRegistry.get_building(id).get("hidden", false)):
			continue
		ids.append(id)
	# 矮的排前面，货架更紧凑
	ids.sort_custom(func(a, b):
		var fa: Array = DataRegistry.get_building(a).get("footprint", [3, 3])
		var fb: Array = DataRegistry.get_building(b).get("footprint", [3, 3])
		if int(fa[1]) != int(fb[1]):
			return int(fa[1]) > int(fb[1])
		return int(fa[0]) > int(fb[0]))
	return ids


func _pave_column(from_cell: Vector2i, to_y: int) -> void:
	var y0: int = mini(from_cell.y, to_y)
	var y1: int = maxi(from_cell.y, to_y)
	for y in range(y0, y1 + 1):
		_pave_cell(Vector2i(from_cell.x, y))


func _pave_row(y: int, from_x: int, to_x: int) -> void:
	for x in range(mini(from_x, to_x), maxi(from_x, to_x) + 1):
		_pave_cell(Vector2i(x, y))


func _pave_cell(cell: Vector2i) -> void:
	if occupancy.has(cell) or is_wall(cell):
		return
	if not build_area.has_point(cell):
		return
	if ground_type(cell) != GROUND_PATH:
		set_ground(cell, GROUND_PATH)


# ---------- 坐标换算 ----------

func world_size() -> Vector2:
	return Vector2(grid_size.x * CELL, grid_size.y * CELL)


func world_rect() -> Rect2:
	return Rect2(Vector2.ZERO, world_size())


func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL, cell.y * CELL)


func cell_center(cell: Vector2i) -> Vector2:
	return cell_to_world(cell) + Vector2(CELL, CELL) * 0.5


func world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CELL), floori(pos.y / CELL))


# ---------- 建造 ----------

func is_area_free(cell: Vector2i, footprint: Vector2i) -> bool:
	for y in range(cell.y, cell.y + footprint.y):
		for x in range(cell.x, cell.x + footprint.x):
			if occupancy.has(Vector2i(x, y)):
				return false
	return true


func can_place(cell: Vector2i, footprint: Vector2i) -> bool:
	if cell.x < build_area.position.x or cell.y < build_area.position.y:
		return false
	if cell.x + footprint.x > build_area.end.x or cell.y + footprint.y > build_area.end.y:
		return false
	for y in range(cell.y, cell.y + footprint.y):
		for x in range(cell.x, cell.x + footprint.x):
			if ground_type(Vector2i(x, y)) == GROUND_WASTELAND:
				return false
	return is_area_free(cell, footprint)


func place_building(id: String, cell: Vector2i, level: int = 1) -> Node2D:
	var data := DataRegistry.get_building(id)
	if data.is_empty():
		push_error("[World] 未知建筑：%s" % id)
		return null
	var footprint := _footprint_of(data)
	if not can_place(cell, footprint):
		push_warning("[World] 位置不可建造：%s @ %s" % [id, cell])
		return null
	var b := Building.new()
	buildings_root.add_child(b)
	b.setup(data, cell, self)
	b.set_level(level)
	buildings.append(b)
	_mark_occupied(cell, footprint, b)
	_astar_dirty = true
	# 检查有没有店铺因此连不上主路（新盖的可能没铺路，也可能压断了别人已有的路）
	var blocked: Array = []
	for other in buildings:
		if not building_reachable(other):
			blocked.append(str(other.data.get("name", "")))
	if not blocked.is_empty():
		GameState.notice.emit("这些店连不上主路，客人过不去：%s（用「建造 → 地面」把路铺到门口）" % ", ".join(blocked))
	building_placed.emit(b)
	return b


func _footprint_of(data: Dictionary) -> Vector2i:
	var f: Array = data.get("footprint", [4, 4])
	return Vector2i(int(f[0]), int(f[1]))


func _mark_occupied(cell: Vector2i, footprint: Vector2i, building_owner: Node) -> void:
	for y in range(cell.y, cell.y + footprint.y):
		for x in range(cell.x, cell.x + footprint.x):
			var c := Vector2i(x, y)
			occupancy[c] = building_owner
			_mark_astar_cell(c)      # 占格后这些格子不可通行


func remove_building(b: Node2D) -> void:
	# 玩家角色如果在被拆的这栋楼里，先把它挪到门口（否则会跟着楼一起被释放）
	var as_building := b as Building
	if as_building != null and player_avatar != null and is_instance_valid(player_avatar) \
			and player_avatar.get_parent() == as_building.interior:
		player_avatar.detach_to(cell_center(as_building.door_cell()))
	var footprint: Vector2i = b.footprint
	var freed: Array = []
	for y in range(b.cell.y, b.cell.y + footprint.y):
		for x in range(b.cell.x, b.cell.x + footprint.x):
			var c := Vector2i(x, y)
			occupancy.erase(c)
			freed.append(c)          # 拆掉后这些格子恢复成「看地面类型」
	_mark_astar_cells(freed)
	buildings.erase(b)
	building_removed.emit(b)
	b.queue_free()


func demolish(b: Building) -> Dictionary:
	# 拆除：展厅里的展品退回仓库，客人请出去，返还一半投入
	if b == null or not is_instance_valid(b):
		return {}
	var building_name := str(b.data.get("name", ""))
	var refund := b.refund_value()
	for entry in b.displayed.duplicate():
		var item_id := str(entry.get("item_id", ""))
		var count := int(entry.get("count", 0))
		if item_id != "" and count > 0:
			GameState.add_item(item_id, count)
	b.displayed.clear()
	b.evacuate()
	remove_building(b)
	if refund > 0:
		GameState.earn(refund, "拆除返还")
	return {"name": building_name, "refund": refund}


func building_at(cell: Vector2i) -> Building:
	var occupant: Variant = occupancy.get(cell, null)
	return occupant as Building


# ---------- 每日结算辅助 ----------

func daily_wages_total() -> int:
	var total := 0
	for b in buildings:
		total += b.daily_wage()
	return total


func pay_daily_wages() -> int:
	var total := daily_wages_total()
	if total > 0:
		GameState.pay_wages(total)
	return total


func showroom_score() -> int:
	var total := 0
	for b in buildings:
		if b.is_showroom():
			total += b.display_score()
	return total


func showroom_display_value() -> int:
	# 展厅里所有展品的总价值（富商的到访概率受它影响）
	var total := 0
	for b in buildings:
		if not b.is_showroom():
			continue
		for entry in b.displayed:
			total += DataRegistry.item_value(str(entry.get("item_id", ""))) * int(entry.get("count", 1))
	return total


func settle_showroom_sales() -> int:
	var income := 0
	for b in buildings:
		income += b.settle_display_sales()
	return income


func night_income_total() -> int:
	var total := 0
	for b in buildings:
		total += b.night_income_estimate()
	return total


func apply_night_income() -> int:
	var total := night_income_total()
	if total > 0:
		GameState.earn(total, "夜间营业")
		GameState.add_reputation(0.3)
	return total


func rest_night() -> Dictionary:
	# 「休息一晚」跳过夜晚时调用：把场地上的顾客位置统一重置一遍。
	# 有房间的住客直接安置进房间睡觉（醒来时间已在 06:30~07:30 之间随机定好），
	# 没房间的（当日往返）在夜间收益结算完之后直接离开度假村。
	var slept := 0
	var left := 0
	for c in get_tree().get_nodes_in_group("customers"):
		if c is Customer:
			if c.goto_room_for_night():
				slept += 1
			else:
				c.leave_now()
				left += 1
	return {"slept": slept, "left": left}


func night_yield() -> Array:
	# 探索系统（Phase 3）开放前的临时夜间产出，保证展厅与倾销可以先玩起来
	if not GameState.placeholder_night_yield:
		return []
	var pool: Array = DataRegistry.items_by_rarity("common") + DataRegistry.items_by_rarity("uncommon")
	if pool.is_empty():
		return []
	var gained: Array = []
	var runs := randi_range(1, 3)
	for _i in range(runs):
		var item_id: String = pool[randi() % pool.size()]
		var count := randi_range(1, 2)
		GameState.add_item(item_id, count)
		gained.append({"id": item_id, "count": count})
	return gained


func find_clinic(illness_level: int, from: Vector2) -> Building:
	var best: Building = null
	var best_dist := INF
	for b in buildings:
		if not b.is_clinic():
			continue
		if b.treat_level() < illness_level:
			continue
		if b.patients.size() >= 4:
			continue
		var d := from.distance_to(b.door_point())
		if d < best_dist:
			best_dist = d
			best = b
	return best


func clear_buildings() -> void:
	for b in buildings.duplicate():
		remove_building(b)
	occupancy.clear()


# ---------- 顾客相关 ----------

func random_target_building(prefers: Array, hour: float = -1.0, exclude: Building = null) -> Node2D:
	if buildings.is_empty():
		return null
	if hour < 0.0:
		hour = GameClock.hour_of_day()
	# 先找「还有使用位」的店；一家都没有，再退而求其次找「还有预定位（排队位）」的店
	var pool := _target_pool(prefers, hour, exclude, true)
	if pool.is_empty():
		pool = _target_pool(prefers, hour, exclude, false)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


func _target_pool(prefers: Array, hour: float, exclude: Building, use_slot_only: bool) -> Array:
	var pool: Array = []
	for b in buildings:
		# 度假屋只用来入住、招待厅只用来办手续，都不算消费场所
		if b.is_lodging() or b.is_reception():
			continue
		if b == exclude:
			continue    # 刚消费过的店先不去，避免来回横跳
		if use_slot_only:
			if not b.has_use_slot():
				continue
		elif not b.has_queue_slot():
			continue
		if not b.is_open_at(hour):
			continue    # 还没到营业时间的店不接客
		if not building_reachable(b):
			continue    # 客人走不到门口
		var weight := 1
		if prefers.has(b.data.get("category", "")):
			weight = 6
		for _i in range(weight):
			pool.append(b)
	return pool


func walkable_path_cells() -> Array:
	# 缓存所有可通行的地砖格，避免每次闲逛都随机试几百次
	if _path_cells_cache.is_empty():
		for cell in ground_types.keys():
			if not occupancy.has(cell) and is_walkable(cell):
				_path_cells_cache.append(cell)
	return _path_cells_cache


# ---------- 垃圾与保洁 ----------

func spawn_litter(cell: Vector2i) -> void:
	# 游客走过的地方小概率留下垃圾
	if litter_cells.has(cell) or not is_walkable(cell):
		return
	if litter_cells.size() >= 400:
		return
	var s := Sprite2D.new()
	s.texture = load("res://art/placeholder/items/branch.png")
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.scale = Vector2(1.4, 1.4)
	s.modulate = Color(0.75, 0.72, 0.62)
	s.position = cell_center(cell) + Vector2(randf_range(-8, 8), randf_range(-6, 6))
	s.z_index = 0
	litter_root.add_child(s)
	litter_cells[cell] = s


func litter_near(at: Vector2, radius: float) -> int:
	var count := 0
	for cell in litter_cells.keys():
		if at.distance_to(cell_center(cell)) <= radius:
			count += 1
	return count


func clean_litter_around(at: Vector2, radius: float, max_count: int) -> int:
	var removed := 0
	for cell in litter_cells.keys():
		if removed >= max_count:
			break
		if at.distance_to(cell_center(cell)) > radius:
			continue
		_erase_litter(cell)
		removed += 1
	return removed


func remove_litter_at(cell: Vector2i) -> int:
	# 清掉指定格子上的垃圾，成功返回 1（保洁工人走到垃圾旁边时用）
	if not litter_cells.has(cell):
		return 0
	_erase_litter(cell)
	return 1


func _erase_litter(cell: Vector2i) -> void:
	var s: Node = litter_cells.get(cell)
	if s != null and is_instance_valid(s):
		s.queue_free()
	litter_cells.erase(cell)


func wander_cell_near(from: Vector2, min_distance: float = 140.0) -> Vector2i:
	# 在附近挑一个能走的格子（太近就换），让客人不会横穿整张地图去发呆
	var cells := walkable_path_cells()
	if cells.is_empty():
		return Vector2i(-9999, -9999)
	var best := Vector2i(-9999, -9999)
	var best_dist := INF
	for _i in range(24):
		var cell: Vector2i = cells[randi() % cells.size()]
		var d := from.distance_to(cell_center(cell))
		if d < min_distance:
			continue
		if d < best_dist:
			best_dist = d
			best = cell
	if best.x == -9999:
		best = cells[randi() % cells.size()]
	return best


func random_walkable_cell() -> Vector2i:
	var cells := walkable_path_cells()
	if cells.is_empty():
		return Vector2i(-9999, -9999)
	return cells[randi() % cells.size()]


func reception() -> Building:
	for b in buildings:
		if b.is_reception():
			return b
	return null


func lodge_with_free_room(party_size: int = 1, party_ref: Party = null) -> Building:
	var best: Building = null
	for b in buildings:
		if not b.has_free_room(party_size, party_ref):
			continue
		if not building_reachable(b):
			continue
		if best == null or b.guests.size() < best.guests.size():
			best = b
	return best


func random_entrance() -> Vector2:
	var side := randi() % 2
	var y := (road_row + 1) * CELL
	if side == 0:
		return Vector2(-CELL, y)
	return Vector2(grid_size.x * CELL + CELL, y)


# ---------- 屋顶模式 ----------

func set_view_mode(mode: int) -> void:
	# 三种显示层循环：屋顶（看外观）→ 屋内（看地板 / 店内顾客）→ 地面（只看地砖和路面）
	# 屋顶层、地面层都不显示屋内游客：只有 INTERIOR 会打开 InteriorLayer。
	view_mode = clampi(mode, ViewMode.ROOF, ViewMode.GROUND)
	show_roofs = view_mode == ViewMode.ROOF
	roof_mode_changed.emit(show_roofs)          # 兼容旧信号
	map_layer_root.visible = true
	outdoor_sort.visible = true
	interior_sort.visible = view_mode == ViewMode.INTERIOR
	ground_sort.visible = view_mode == ViewMode.GROUND
	var next_actor_sort := outdoor_sort
	if view_mode == ViewMode.INTERIOR:
		next_actor_sort = interior_sort
	elif view_mode == ViewMode.GROUND:
		next_actor_sort = ground_sort
	active_actor_sort = next_actor_sort
	for actor in get_tree().get_nodes_in_group("actors"):
		if actor == null or not is_instance_valid(actor):
			continue
		var actor_parent := actor.get_parent()
		if actor_parent in [outdoor_sort, interior_sort, ground_sort]:
			actor.reparent(next_actor_sort, true)
	customers_root = next_actor_sort
	staff_root = next_actor_sort
	for b in buildings:
		b.apply_view_mode(view_mode)


func cycle_view_mode() -> int:
	set_view_mode((view_mode + 1) % 3)
	return view_mode


func view_mode_name() -> String:
	match view_mode:
		ViewMode.ROOF:
			return "屋顶"
		ViewMode.INTERIOR:
			return "屋内"
		ViewMode.GROUND:
			return "地面"
	return "屋顶"


func set_roof_mode(show_roof: bool) -> void:
	# 兼容旧调用：true = 屋顶，false = 屋内（地面是新模式，请用 set_view_mode / cycle_view_mode）
	set_view_mode(ViewMode.ROOF if show_roof else ViewMode.INTERIOR)


func toggle_roof_mode() -> void:
	cycle_view_mode()      # 兼容旧入口（R 键 / 顶栏按钮）：现在是三态循环


# ---------- 存档 ----------

func save_data() -> Dictionary:
	var list: Array = []
	for b in buildings:
		list.append(b.save_data())
	var ground_save: Array = []
	for c in ground_types.keys():
		ground_save.append({"cell": [c.x, c.y], "kind": str(ground_types[c])})
	return {"buildings": list, "view_mode": view_mode, "show_roofs": show_roofs, "ground": ground_save}


func load_data(d: Dictionary) -> void:
	clear_buildings()
	_init_ground_types()
	var ground_save: Array = d.get("ground", [])
	if not ground_save.is_empty():
		ground_types.clear()
		for entry in ground_save:
			var c: Array = entry.get("cell", [0, 0])
			ground_types[Vector2i(int(c[0]), int(c[1]))] = str(entry.get("kind", GROUND_WILD))
		for y in range(grid_size.y):
			for x in range(grid_size.x):
				_paint_ground_tile(Vector2i(x, y))
	_astar_dirty = true
	for entry in d.get("buildings", []):
		var cell_arr: Array = entry.get("cell", [0, 0])
		var built := place_building(entry.get("id", ""), Vector2i(int(cell_arr[0]), int(cell_arr[1])), int(entry.get("level", 1)))
		if built:
			built.apply_save(entry)
	if d.has("view_mode"):
		set_view_mode(int(d.get("view_mode", ViewMode.ROOF)))
	else:
		set_roof_mode(bool(d.get("show_roofs", true)))      # 旧存档兼容
	if player_avatar != null and is_instance_valid(player_avatar):
		player_avatar.reset_to_reception()   # 读档后角色回招待厅，新的一天从厅里开始
