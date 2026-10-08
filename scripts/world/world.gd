class_name World
extends Node2D
## 世界：地面、装饰、建筑、顾客，以及格子判定。
## 坐标约定：一格 = 32×32 像素，位置 = 格子左上角。

signal roof_mode_changed(show_roof: bool)
signal building_placed(building)

const CELL := 32
const TILESET_PATH := "res://art/generated/ground_tileset.tres"

# 地面类型：荒地（不可通行）、草坪（可通行）、地砖（可通行）
const GROUND_WILD := "grass"
const GROUND_LAWN := "lawn"
const GROUND_PATH := "path"
const WALL_TILE_PATH := "res://art/generated/wall_tile.png"
const ENTRANCE_X0 := 62      # 度假村入口（底边缺口）对应的列
const ENTRANCE_X1 := 63
const STREET_ROW := 40       # 村里的横向主街
const STREET_X0 := 14
const STREET_X1 := 102

@export var grid_size := Vector2i(128, 80)          # 面积是原来的 4 倍
@export var build_area := Rect2i(3, 3, 122, 66)     # 围墙内：x 3~124、y 3~68
@export var road_row := 72

var ground: TileMapLayer
var decor: Node2D
var buildings_root: Node2D
var customers_root: Node2D
var walls_root: Node2D

var buildings: Array = []
var occupancy: Dictionary = {}
var show_roofs := true
var ground_types: Dictionary = {}      # cell -> GROUND_LAWN / GROUND_PATH（不记录就是荒地）
var wall_cells: Dictionary = {}        # 度假村围墙占的格子
var _astar: AStarGrid2D
var _astar_dirty := true
var _reachable_cache: Dictionary = {}   # Building -> bool，避免每次生成客人都重算路径
var _path_cells_cache: Array = []       # 所有可通行的地砖格子，用于闲逛选点
var litter_cells: Dictionary = {}       # 垃圾：cell -> Sprite2D
var litter_root: Node2D
var staff_root: Node2D                   # 保洁工人等在场地上走动的员工


func _ready() -> void:
	add_to_group("world")
	_create_layers()
	_init_ground_types()
	_build_ground()
	_build_walls()
	_scatter_decorations()
	_spawn_starter_buildings()


func _create_layers() -> void:
	ground = TileMapLayer.new()
	ground.name = "Ground"
	ground.z_index = -100
	if ResourceLoader.exists(TILESET_PATH):
		ground.tile_set = load(TILESET_PATH)
	add_child(ground)

	decor = Node2D.new()
	decor.name = "Decor"
	decor.z_index = -50
	add_child(decor)

	buildings_root = Node2D.new()
	buildings_root.name = "Buildings"
	add_child(buildings_root)

	customers_root = Node2D.new()
	customers_root.name = "Customers"
	customers_root.y_sort_enabled = false
	add_child(customers_root)

	litter_root = Node2D.new()
	litter_root.name = "Litter"
	add_child(litter_root)

	staff_root = Node2D.new()
	staff_root.name = "Staff"
	staff_root.y_sort_enabled = true      # 保洁工人要和建筑按 y 正确遮挡
	add_child(staff_root)

	walls_root = Node2D.new()
	walls_root.name = "Walls"
	add_child(walls_root)


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
	s.z_index = int(s.position.y)
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
	var cfg := DataRegistry.ground_config()
	var kind := str(ground_types.get(cell, GROUND_WILD))
	var atlas: Array
	if kind == GROUND_PATH:
		atlas = cfg.get("sand", [3, 0])
	elif kind == GROUND_LAWN:
		atlas = cfg.get("grass_dark", [3, 6])
	else:
		# 默认草坪：不可行走，颜色比可行走草坪浅
		atlas = cfg.get("grass", [3, 3])
	ground.set_cell(cell, 0, Vector2i(int(atlas[0]), int(atlas[1])))


func set_ground(cell: Vector2i, kind: String) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return
	if kind == GROUND_WILD:
		ground_types.erase(cell)
	else:
		ground_types[cell] = kind
	_paint_ground_tile(cell)
	_astar_dirty = true


func ground_type(cell: Vector2i) -> String:
	return str(ground_types.get(cell, GROUND_WILD))


func is_walkable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return false
	if ground_type(cell) == GROUND_WILD:
		return false
	if occupancy.has(cell):
		return false
	return true


func ground_kind_name(cell: Vector2i) -> String:
	match ground_type(cell):
		GROUND_PATH:
			return "地砖"
		GROUND_LAWN:
			return "可行走草坪"
		_:
			return "普通草坪（不可行走）"


# ---------- 寻路 ----------

func _ensure_astar() -> void:
	if _astar == null:
		_astar = AStarGrid2D.new()
		_astar.region = Rect2i(0, 0, grid_size.x, grid_size.y)
		_astar.cell_size = Vector2(CELL, CELL)
		_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
		_astar.update()
		_astar_dirty = true
	if not _astar_dirty:
		return
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var c := Vector2i(x, y)
			_astar.set_point_solid(c, not is_walkable(c))
	_astar_dirty = false
	_reachable_cache.clear()
	_path_cells_cache.clear()


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
	if b == null or not is_instance_valid(b):
		return false
	if _reachable_cache.has(b):
		return bool(_reachable_cache[b])
	var door: Vector2i = b.door_cell()
	var ok := is_walkable(door) and not find_path_cells(entrance_cell(door), door).is_empty()
	_reachable_cache[b] = ok
	return ok


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
		if force_tree and not str(d.get("id", "")).begins_with("tree"):
			continue
		var w := int(d.get("weight", 1))
		for _i in range(w):
			pool.append(d)
	if pool.is_empty():
		return
	var def: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	spawn_decoration(def, cell)


func spawn_decoration(def: Dictionary, cell: Vector2i) -> Sprite2D:
	var rect_arr: Array = def.get("rect", [0, 0, 16, 16])
	var s := Sprite2D.new()
	s.texture = load(def.get("atlas", ""))
	s.region_enabled = true
	s.region_rect = Rect2(rect_arr[0], rect_arr[1], rect_arr[2], rect_arr[3])
	s.centered = false
	s.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	var pos := Vector2(cell.x * CELL, cell.y * CELL)
	s.position = pos + Vector2(0, CELL) - Vector2(0, rect_arr[3] * DataRegistry.SPRITE_SCALE)
	s.z_index = int(s.position.y)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	decor.add_child(s)
	return s


func _spawn_starter_buildings() -> void:
	# 初始模式：8 栋常用建筑，门口小路都已经接上主街
	if SaveManager.new_game_mode == SaveManager.MODE_FULL_TEST:
		_spawn_all_buildings()
		place_building("reception", Vector2i(64, 62))
		return
	place_building("reception", Vector2i(64, 62))
	place_building("lodge_ordinary", Vector2i(18, 34))
	place_building("lodge_nature", Vector2i(30, 34))
	place_building("lodge_modern", Vector2i(6, 34))
	place_building("food_diner", Vector2i(43, 34))
	place_building("shop_small", Vector2i(55, 34))
	place_building("food_bar", Vector2i(70, 34))
	place_building("clinic_small", Vector2i(82, 34))
	place_building("showroom", Vector2i(94, 30))


func _spawn_all_buildings() -> void:
	# 完全测试模式：把建造菜单里能建的所有建筑都摆上去，并自动接好道路。
	# 用「货架式」排布：从下往上一条条横带，建筑在横带里从左往右排（中间留 2 格缝），
	# 每栋门口那一列铺一条竖路通到横带，横带之间再由右边一条竖干道串到村里的主街。
	var ids := _full_test_building_ids()
	var shelf_ys := [59, 52, 45, 38, 31, 24, 17, 10]   # 每条横带的基线（y 越大越靠下）
	var x0: int = build_area.position.x + 1             # 最外圈是围墙，从里面一格开始
	var x1: int = build_area.end.x - 1
	var shelf_index := 0
	var cursor := x0
	var max_x := x0
	var placed: Array = []
	var skipped: Array = []

	for id in ids:
		var data := DataRegistry.get_building(id)
		var f: Array = data.get("footprint", [3, 3])
		var w := int(f[0])
		var h := int(f[1])
		# 找到一条放得下这栋建筑（高度够 + 右边还有宽度）的横带
		while shelf_index < shelf_ys.size():
			var base: int = shelf_ys[shelf_index]
			var too_tall: bool = (base - h + 1) < build_area.position.y + 1
			var too_narrow: bool = (cursor + w) > x1
			if too_tall or too_narrow:
				shelf_index += 1
				cursor = x0        # 换到上一条横带，从最左边重新排
				continue
			break
		if shelf_index >= shelf_ys.size():
			skipped.append(id)
			continue
		var base: int = shelf_ys[shelf_index]
		var cell := Vector2i(cursor, base - h + 1)
		# 万一这一格真被占了（围墙拐角之类），往右挪，挪不下就换横带
		var guard := 0
		while can_place(cell, Vector2i(w, h)) == false and guard < 40:
			cursor += 1
			guard += 1
			if cursor + w > x1:
				shelf_index += 1
				cursor = x0
				if shelf_index >= shelf_ys.size():
					break
				base = shelf_ys[shelf_index]
			cell = Vector2i(cursor, base - h + 1)
		if shelf_index >= shelf_ys.size():
			skipped.append(id)
			continue
		if place_building(id, cell) == null:
			skipped.append(id)
			cursor += w + 2
			continue
		var b: Building = buildings[buildings.size() - 1]
		# 门口那一列铺一条竖路到横带，再让横带本身成为一条通路
		_pave_column(b.door_cell(), base + 1)
		_pave_row(base + 1, cursor, cursor + w - 1)
		placed.append(b)
		max_x = maxi(max_x, cursor + w - 1)
		cursor += w + 2

	# 横带之间用一条竖干道串起来，再接到村里的主街上
	var trunk_x: int = mini(max_x + 3, x1)
	_pave_column(Vector2i(trunk_x, build_area.position.y + 1), road_row)
	for base in shelf_ys:
		_pave_row(base + 1, x0, trunk_x)
	for b in placed:
		if b.needs_staff():
			b.fill_staff()
	print("[World] 完全测试模式：放置建筑 %d 栋（干道第 %d 列）%s" % [
		placed.size(), trunk_x,
		"" if skipped.is_empty() else "，排不下：%s" % ", ".join(skipped)])


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


func _mark_occupied(cell: Vector2i, footprint: Vector2i, owner: Node) -> void:
	for y in range(cell.y, cell.y + footprint.y):
		for x in range(cell.x, cell.x + footprint.x):
			occupancy[Vector2i(x, y)] = owner


func remove_building(b: Node2D) -> void:
	_astar_dirty = true
	var footprint: Vector2i = b.footprint
	for y in range(b.cell.y, b.cell.y + footprint.y):
		for x in range(b.cell.x, b.cell.x + footprint.x):
			occupancy.erase(Vector2i(x, y))
	buildings.erase(b)
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
	var owner: Variant = occupancy.get(cell, null)
	return owner as Building


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


func rest_all_staff() -> void:
	for b in buildings:
		b.rest_staff()


func rest_night() -> Dictionary:
	# 「休息一晚」跳过夜晚时调用：把场地上的顾客位置统一重置一遍。
	# 有房间的住客直接安置进房间睡觉（醒来时间已在 06:30~07:30 之间随机定好），
	# 没房间的（当日往返）在夜间收益结算完之后直接离开度假村。
	var slept := 0
	var left := 0
	for c in customers_root.get_children():
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
	var pool: Array = []
	for b in buildings:
		# 度假屋只用来入住、招待厅只用来办手续，都不算消费场所
		if b.is_lodging() or b.is_reception():
			continue
		if b == exclude:
			continue    # 刚消费过的店先不去，避免来回横跳
		if not b.has_room():
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
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


func walkable_path_cells() -> Array:
	# 缓存所有可通行的地砖格，避免每次闲逛都随机试几百次
	if _path_cells_cache.is_empty():
		for cell in ground_types.keys():
			if ground_types[cell] == GROUND_PATH and not occupancy.has(cell):
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
	s.z_index = int(s.position.y) - 1
	litter_root.add_child(s)
	litter_cells[cell] = s


func litter_near(position: Vector2, radius: float) -> int:
	var count := 0
	for cell in litter_cells.keys():
		if position.distance_to(cell_center(cell)) <= radius:
			count += 1
	return count


func clean_litter_around(position: Vector2, radius: float, max_count: int) -> int:
	var removed := 0
	for cell in litter_cells.keys():
		if removed >= max_count:
			break
		if position.distance_to(cell_center(cell)) > radius:
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


func lodge_with_free_room(party_size: int = 1) -> Building:
	var best: Building = null
	for b in buildings:
		if not b.has_free_room(party_size):
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

func set_roof_mode(show_roof: bool) -> void:
	show_roofs = show_roof
	roof_mode_changed.emit(show_roof)
	for b in buildings:
		b.apply_roof_mode(show_roof)


func toggle_roof_mode() -> void:
	set_roof_mode(not show_roofs)


# ---------- 存档 ----------

func save_data() -> Dictionary:
	var list: Array = []
	for b in buildings:
		list.append(b.save_data())
	var ground_save: Array = []
	for c in ground_types.keys():
		ground_save.append({"cell": [c.x, c.y], "kind": str(ground_types[c])})
	return {"buildings": list, "show_roofs": show_roofs, "ground": ground_save}


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
	set_roof_mode(bool(d.get("show_roofs", true)))
