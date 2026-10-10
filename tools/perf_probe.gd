extends Node
## 运行性能测量：量出铺地 / 盖楼 / 寻路 / 每帧的真实耗时，用来判断瓶颈在哪，
## 避免凭感觉做优化。
##
## 运行：godot --headless --path . res://tools/perf_probe.tscn -- --iters=200
##
## 输出：
##   - A* 全量重建一次多少毫秒（这是「铺一格地就置脏、下次寻路全量重建」的成本）
##   - set_ground 单次多少毫秒（含重建）
##   - place_building 单次多少毫秒
##   - find_path_cells 单次多少毫秒（不含重建）
##   - walkable_path_cells() 冷 / 热缓存的成本
##   - 有 6 个客人时 _process 的每帧耗时
## 注意：固定随机种子，数字可复现；用测试存档目录且只读，绝不碰玩家存档。

var main: Node
var world: Node2D
var iters := 200
var _ready_done := false


func _ready() -> void:
	SaveManager.save_dir = SaveManager.TEST_SAVE_DIR
	SaveManager.read_only = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--iters="):
			iters = maxi(1, int(arg.split("=")[1]))
	seed(20261008)
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)


func _process(_delta: float) -> void:
	if _ready_done:
		return
	_ready_done = true
	world = main.get_node_or_null("World")
	if world == null:
		print("[perf] 拿不到 World，退出")
		get_tree().quit(1)
		return
	# 必须 await：_run 结尾要等两帧才能读渲染监视器（帧内读不到绘制调用数）
	await _run()
	print("[perf] 结束")
	get_tree().quit(0)


func _run() -> void:
	print("[perf] 迭代次数 = %d ｜ 地图 %dx%d = %d 格" % [
		iters, world.grid_size.x, world.grid_size.y, world.grid_size.x * world.grid_size.y])

	# 1) A* 全量重建一次的成本（每次铺地/盖楼都会置脏，之后第一次寻路触发重建）
	var t0 := Time.get_ticks_usec()
	for _i in range(iters):
		world._astar_dirty = true
		world._ensure_astar()
	var rebuild_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(iters)
	print("[perf] A* 全量重建：%.3f 毫秒/次" % rebuild_ms)

	# 2) set_ground 单次成本（自身很轻，但会置脏 → 下一次寻路要付上面的重建费）
	var cells: Array = _pick_cells(iters * 2)
	t0 = Time.get_ticks_usec()
	for i in range(iters):
		world.set_ground(cells[i], World.GROUND_PATH)
	var set_ground_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(iters)
	print("[perf] set_ground：%.3f 毫秒/次（不含置脏后那次重建）" % set_ground_ms)

	# 3) 实际手感：铺 60 格地砖、其间穿插寻路（模拟玩家按住拖动连续铺路）
	t0 = Time.get_ticks_usec()
	for i in range(60):
		world.set_ground(cells[iters + i], World.GROUND_PATH)
		world.find_path_cells(Vector2i(64, 62), cells[iters + i])   # 每次都在重建后寻路
	var drag_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / 60.0
	print("[perf] 连续铺路（每铺一格 + 一次寻路）：%.3f 毫秒/格" % drag_ms)

	# 4) find_path_cells 单次成本（A* 已是最新时）
	world._ensure_astar()
	var target: Vector2i = _nearest_path_cell(Vector2i(20, 20))
	t0 = Time.get_ticks_usec()
	var found := 0
	for _i in range(iters):
		if not world.find_path_cells(Vector2i(64, 62), target).is_empty():
			found += 1
	var path_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(iters)
	print("[perf] find_path_cells：%.3f 毫秒/次（%d/%d 次找到路）" % [path_ms, found, iters])

	# 5) walkable_path_cells：冷缓存 vs 热缓存
	world._path_cells_cache.clear()
	t0 = Time.get_ticks_usec()
	var n: int = world.walkable_path_cells().size()
	var cold_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	for _i in range(iters):
		world.walkable_path_cells()
	var warm_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(iters)
	print("[perf] walkable_path_cells：冷缓存 %.3f 毫秒/次（%d 格）｜ 热缓存 %.4f 毫秒/次" % [
		cold_ms, n, warm_ms])

	# 6) 盖楼单次成本
	var t_build := Time.get_ticks_usec()
	var built := 0
	for i in range(mini(iters, 40)):
		var c: Vector2i = cells[i * 3]
		if world.can_place(c, Vector2i(3, 2)):
			if world.place_building("food_diner", c) != null:
				built += 1
	var build_ms := float(Time.get_ticks_usec() - t_build) / 1000.0 / float(maxi(built, 1))
	print("[perf] place_building：%.3f 毫秒/次（成功 %d 栋）" % [build_ms, built])

	# 7) 正确性：增量更新后的网格必须与「全量重建」逐格一致
	#    （增量最大的风险是漏标记某格 → 寻路网格过期 → 客人穿墙）
	world._ensure_astar()
	var incremental: Array = []
	for y in range(world.grid_size.y):
		for x in range(world.grid_size.x):
			incremental.append(world._astar.is_point_solid(Vector2i(x, y)))
	world._astar_dirty_cells.clear()
	world._astar_dirty = true
	world._ensure_astar()
	var rebuilt: Array = []
	for y in range(world.grid_size.y):
		for x in range(world.grid_size.x):
			rebuilt.append(world._astar.is_point_solid(Vector2i(x, y)))
	var diff := 0
	for i in range(incremental.size()):
		if incremental[i] != rebuilt[i]:
			diff += 1
	print("[perf] 增量 vs 全量重建：%d 格中不一致 %d 格（必须为 0）" % [incremental.size(), diff])

	# 8) 渲染开销：节点数与绘制调用（逻辑再快，绘制多了也会掉帧）
	await get_tree().process_frame
	await get_tree().process_frame
	print("[perf] 渲染：节点 %d 个 ｜ 绘制调用 %d ｜ 绘制对象 %d ｜ 帧耗时 %.2f 毫秒 ｜ 物理 %.2f" % [
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	# 建筑里的子节点统计（注意：灯挂在 World 下、且 top_level=true，不在建筑子节点里）
	var light_count := _count_lights(world)
	var child_total := 0
	for b in world.buildings:
		child_total += b.get_child_count()
	if not world.buildings.is_empty():
		print("[perf] 建筑 %d 栋 ｜ 平均每栋 %.1f 个子节点 ｜ 场景内灯光 %d 盏（应≈建筑数）" % [
			world.buildings.size(), float(child_total) / float(world.buildings.size()), light_count])

	# 9) 客人 _process 的每帧成本（世界已经在动的时候）
	var guests: Array = _spawn_guests(6)
	if guests.is_empty():
		print("[perf] 没造出客人，跳过每帧测量")
		return
	# 先推进 1 秒让客人进入正常行走状态
	for _i in range(60):
		for g0 in guests:
			var g: Node2D = g0
			if is_instance_valid(g):
				g._process(0.016)
	t0 = Time.get_ticks_usec()
	var steps := 120
	for _i in range(steps):
		for g0 in guests:
			var g: Node2D = g0
			if is_instance_valid(g):
				g._process(0.016)
	var per_frame_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(steps)
	print("[perf] 6 位客人的 _process：%.3f 毫秒/帧（客人的 AI + 寻路）" % per_frame_ms)


func _count_lights(n: Node) -> int:
	var c := 0
	if n is PointLight2D:
		c += 1
	for ch in n.get_children():
		c += _count_lights(ch)
	return c


func _pick_cells(count: int) -> Array:
	# 挑一批互不相邻、当前还是荒地的格子，保证 set_ground 都真实生效
	var out: Array = []
	var x := 4
	var y := 4
	while out.size() < count and y < world.grid_size.y - 4:
		var c := Vector2i(x, y)
		if not world.occupancy.has(c) and world.ground_type(c) == World.GROUND_WILD:
			out.append(c)
		x += 1
		if x >= world.grid_size.x - 4:
			x = 4
			y += 1
	while out.size() < count:
		out.append(Vector2i(4, 4))     # 不够就重复用同一格（set_ground 幂等）
	return out


func _nearest_path_cell(from: Vector2i) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_d := INF
	var path_cells: Array = world.walkable_path_cells()
	for c in path_cells:
		var cc: Vector2i = c
		var d: float = Vector2(cc).distance_to(Vector2(from))
		if d < best_d:
			best_d = d
			best = cc
	return best


func _spawn_guests(count: int) -> Array:
	var out: Array = []
	var root: Node2D = world.customers_root
	for i in range(count):
		var g: Node2D = load("res://scripts/customers/customer.gd").new()
		root.add_child(g)
		g.setup(DataRegistry.customer_types[i % DataRegistry.customer_types.size()],
			world, world.random_entrance())
		out.append(g)
	return out
