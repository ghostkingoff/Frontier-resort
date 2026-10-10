extends Node
## 冒烟测试的「内容回归」部分：建筑表 / 知名度解锁 / 卫生间 / 共享单车 / 保洁工人 / 垃圾与心情。
## 由 smoke_runner.gd 在 _finish() 里挂载，共用它的 world 与 checks。
##
## 拆出来的原因：smoke_runner.gd 原本 1100 多行，这一块是历次内容扩充堆上去的，
## 单独成文件以后加新系统的回归检查不用在 1000 行的文件里找位置。

const JANITOR_SCRIPT := preload("res://scripts/customers/janitor.gd")

var runner: Node          # smoke_runner 实例：读它的 world / checks
var world: Node2D
var checks: Array


func setup(runner_ref: Node) -> void:
	runner = runner_ref
	world = runner_ref.world
	checks = runner_ref.checks


func run() -> void:
	# 1. 两份建筑配置不能有同名 id（有的话扩充表会静默覆盖主表，改了数据却没反应）
	var extra_ids: Dictionary = {}
	for item in _read_data_file("res://data/buildings_extra.json").get("buildings", []):
		extra_ids[str(item.get("id", ""))] = true
	var clashes: Array = []
	for item in _read_data_file("res://data/buildings.json").get("buildings", []):
		var id := str(item.get("id", ""))
		if extra_ids.has(id):
			clashes.append(id)
	checks.append("建筑配置冲突：同名 id %d 个%s" % [
		clashes.size(), "" if clashes.is_empty() else "（%s，实际生效的是扩充表）" % ", ".join(clashes)])

	# 2. 建造菜单里实际会显示多少栋（hidden 的不显示）
	var visible := 0
	var hidden := 0
	for id in DataRegistry.building_order:
		if bool(DataRegistry.get_building(id).get("hidden", false)):
			hidden += 1
		else:
			visible += 1
	checks.append("建筑表：%d 种（建造菜单显示 %d ｜ 已淘汰 hidden %d）" % [
		DataRegistry.building_order.size(), visible, hidden])

	# 3. 知名度解锁门槛：构造玩家知名度 500，核对门槛判定
	var fame_before: float = GameState.fame
	GameState.fame = 500.0
	var want := 0
	var mismatched: Array = []
	for id in DataRegistry.building_order:
		var data: Dictionary = DataRegistry.get_building(id)
		var need := int(data.get("unlock_fame", 0))
		if need <= 0 or need > 600:
			continue
		want += 1
		if (GameState.fame >= float(need)) != (need <= 500):
			mismatched.append("%s(%d)" % [str(data.get("name", id)), need])
	checks.append("知名度解锁：门槛在 (0, 600] 的建筑 %d 栋 ｜ 知名度 500 时判定不一致 %d 个%s" % [
		want, mismatched.size(), "" if mismatched.is_empty() else "（%s）" % ", ".join(mismatched)])
	GameState.fame = fame_before

	# 4. 占地格数（10-07 已从代码里的临时覆盖搬进 data/*.json）
	var lodge_cells: Array = []
	for id in ["lodge_ordinary", "lodge_nature", "lodge_modern"]:
		lodge_cells.append("%s %s" % [
			str(DataRegistry.get_building(id).get("name", id)),
			runner._str_footprint(DataRegistry.get_building(id))])
	checks.append("度假屋规格：%s" % " ｜ ".join(lodge_cells))
	var too_big: Array = []
	for id in DataRegistry.building_order:
		var f: Array = DataRegistry.get_building(id).get("footprint", [4, 4])
		if int(f[0]) <= 0 or int(f[1]) <= 0 or int(f[0]) > 8 or int(f[1]) > 8:
			too_big.append("%s%s" % [id, f])
	checks.append("占地格数：全部在 1~8 格内 = %s%s" % [
		str(too_big.is_empty()), "" if too_big.is_empty() else "（越界：%s）" % ", ".join(too_big)])

	# 5. 三个新机制：公共卫生间 / 共享单车 / 保洁间
	#    注意：客人只会去「门口连得上主路」的建筑，所以测试里必须像玩家一样把路铺到门口，
	#    否则 random_target_building() 根本不会把它们放进候选池。
	var toilet: Building = _place_and_connect("amenity_toilet")
	var bike: Building = _place_and_connect("amenity_bike")
	# 保洁间直接盖在已经有地砖的地方，这样它门口就是客人会走的路（垃圾也只落在这里）
	var cleaner: Building = _place_on_pavement("amenity_cleaning")
	checks.append("服务设施：公共卫生间 %s ｜ 共享单车 %s ｜ 保洁间 %s ｜ 三家都接上主路 %s" % [
		str(toilet != null), str(bike != null), str(cleaner != null),
		str(toilet != null and world.building_reachable(toilet)
			and bike != null and world.building_reachable(bike)
			and cleaner != null and world.building_reachable(cleaner))])
	if toilet and bike and cleaner and world.reception():
		checks.append("自助设施：卫生间/单车 员工编制 %d/%d ｜ 缺员工心情惩罚 %d/%d（应为 0）｜ 保洁间编制 %d" % [
			toilet.staff_slots(), bike.staff_slots(),
			int(toilet.staff_mood_bonus()), int(bike.staff_mood_bonus()), cleaner.staff_slots()])
		# 客人真的会挑中这三个设施（random_target_building 的池子里必须包含它们）
		var picked: Dictionary = {}
		for _i in range(240):
			var target_b: Building = world.random_target_building([], 12.0)
			if target_b:
				picked[target_b.id] = true
		checks.append("客人可选：卫生间进池 %s ｜ 共享单车进池 %s ｜ 保洁间进池 %s" % [
			str(picked.has("amenity_toilet")), str(picked.has("amenity_bike")),
			str(picked.has("amenity_cleaning"))])

		# 卫生间：不花钱，只涨心情（服务效果在客人「离开设施」时结算）
		var guest := Customer.new()
		world.customers_root.add_child(guest)
		guest.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		var money_0 := GameState.money
		var budget_0: int = guest.budget_left
		var mood_0: float = guest.mood
		guest.target = toilet
		guest.purpose = Customer.Purpose.CONSUME
		guest._enter_facility()
		guest._finish_consume()
		checks.append("公共卫生间：心情 %.1f → %.1f（+%.1f）｜ 客人预算 %d → %d ｜ 收入 %d（应为 0）" % [
			mood_0, guest.mood, guest.mood - mood_0, budget_0, guest.budget_left,
			GameState.money - money_0])

		# 共享单车：租一次，速度翻倍
		var speed_0: float = guest.speed
		guest.target = bike
		guest.purpose = Customer.Purpose.CONSUME
		guest._enter_facility()
		guest._finish_consume()
		checks.append("共享单车：速度 %.0f → %.0f（×%.1f）｜ 已租 %s" % [
			speed_0, guest.speed, guest.speed / maxf(speed_0, 1.0), str(guest.has_bike)])
		guest.queue_free()
	else:
		checks.append("服务设施：建造或接路失败，跳过机制检查")

	# 6. 保洁工人：雇了人才会出现，会在外面走动，只清负责范围（半径 40 格）内的垃圾
	if cleaner:
		cleaner = _setup_cleaning_scene(cleaner)
		if cleaner:
			_run_janitor_checks(cleaner)
		else:
			checks.append("保洁工人：没找到能贴着地砖的保洁间位置，跳过（场地排不下）")
	else:
		checks.append("保洁工人：保洁间没建起来，跳过")

	# 7. 垃圾会持续掉心情：同一个客人、同一位置，做「干净 vs 脏」两次对照
	_run_litter_mood_check()


# ---------- 保洁工人 ----------

func _run_janitor_checks(cleaner: Building) -> void:
	# 1) 雇人才有工人，人走了工人也消失
	cleaner.hire_staff()
	cleaner._sync_janitors()
	var after_hire: int = cleaner.janitors.size()
	cleaner.fire_staff()
	cleaner._sync_janitors()
	var after_fire: int = cleaner.janitors.size()
	cleaner.hire_staff()
	cleaner._sync_janitors()
	checks.append("保洁工人：雇 1 人 → 工人 %d 位 ｜ 解雇 → %d 位（应为 1 / 0）" % [after_hire, after_fire])

	# 2) 会在外面走动：给足时间看位置有没有变化
	var janitor: Node2D = null
	for j in cleaner.janitors:
		if j != null and is_instance_valid(j):
			janitor = j
			break
	if janitor == null:
		checks.append("保洁工人：没拿到工人实例，跳过走动检查")
		return
	var start_pos: Vector2 = janitor.global_position
	var moved := 0.0
	for _i in range(40):
		janitor._process(0.25)
		moved = maxf(moved, start_pos.distance_to(janitor.global_position))
	checks.append("保洁工人：40 次推进后累计走动 %.0f 像素（会动 %s）｜ 负责半径 %d 格" % [
		moved, str(moved > 8.0), janitor.roam_radius_cells()])

	# 3) 范围内的垃圾会被清掉
	var near_cell: Vector2i = runner._nearest_walkable(janitor.global_position)
	var near_planted := 0
	for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var c: Vector2i = near_cell + d
		if world.is_walkable(c) and not world.litter_cells.has(c):
			world.spawn_litter(c)
			near_planted += 1
	var janitor_ref: Node2D = janitor
	var real_total: int = janitor.cleaned_total
	for _i in range(30):
		janitor_ref._process(0.4)
		if janitor_ref.cleaned_total > real_total:
			break
	# 兜底：万一寻路没走到，直接站到垃圾上确认清扫动作本身有效
	if janitor_ref.cleaned_total == real_total and world.litter_cells.has(near_cell):
		janitor_ref.global_position = world.cell_center(near_cell)
		janitor_ref._look_for_litter()
	var near_left := 0
	for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		if world.litter_cells.has(near_cell + d):
			near_left += 1
	checks.append("保洁工人清扫：范围内种下 %d 个 ｜ 走了一轮后剩 %d 个 ｜ 工人累计清掉 %d 个" % [
		near_planted, near_left, janitor_ref.cleaned_total])

	# 4) 负责范围外的垃圾不清（放在离保洁间 40 格以外的地方）
	var far_cell := Vector2i(-9999, -9999)
	for cell in world.walkable_path_cells():
		if world.litter_cells.has(cell):
			continue
		if world.cell_center(cell).distance_to(cleaner.global_position) > float(JANITOR_SCRIPT.ROAM_RADIUS_CELLS + 5) * 32.0:
			far_cell = cell
			break
	if far_cell.x != -9999:
		world.spawn_litter(far_cell)
		janitor_ref.global_position = world.cell_center(runner._nearest_walkable(cleaner.global_position))
		var found := Vector2i(-9999, -9999)
		for _i in range(30):
			janitor_ref._look_for_litter()
			found = janitor_ref.current_target()
			if found.x != -9999:
				break
		checks.append("保洁工人范围：范围外 %d 格外放 1 个垃圾 ｜ 工人是否去清 = %s（应为 false）" % [
			int(world.cell_center(far_cell).distance_to(cleaner.global_position) / 32.0),
			str(found == far_cell)])
		world.remove_litter_at(far_cell)
	else:
		checks.append("保洁工人范围：地图上找不到 40 格以外的可通行格，跳过")


# 把保洁间挪到一片「旁边还有别的可通行格」的地砖上，让工人一出门就有垃圾可扫
func _setup_cleaning_scene(fallback: Building) -> Building:
	for cell in world.walkable_path_cells():
		if not world.can_place(cell, Vector2i(2, 2)):
			continue
		var b: Building = world.place_building("amenity_cleaning", cell)
		if b == null:
			continue
		if not world.building_reachable(b):
			world.demolish(b)
			continue
		# 门口附近至少有 2 格可通行地砖才算合格
		if runner._walkable_neighbours(cell, Vector2i(2, 2)) >= 3:
			if fallback and is_instance_valid(fallback):
				world.demolish(fallback)
			return b
		world.demolish(b)
	return fallback


func _place_and_connect(id: String) -> Building:
	# 完全测试模式下这类建筑开局就已经摆好了，直接借用现成的那栋，不再重复建造
	var existing: Building = runner._find_building(id)
	if existing:
		return existing
	var data: Dictionary = DataRegistry.get_building(id)
	var f: Array = data.get("footprint", [3, 3])
	var size := Vector2i(int(f[0]), int(f[1]))
	var spots: Array = []
	for y in range(3, 62):
		for x in range(4, 124):
			var cell := Vector2i(x, y)
			if world.can_place(cell, size):
				spots.append(cell)
	spots.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return absi(a.y - world.road_row) < absi(b.y - world.road_row))
	for cell in spots:
		if world.place_building(id, cell) == null:
			continue
		var b: Building = world.buildings[world.buildings.size() - 1]
		for py in range(b.door_cell().y, world.road_row + 1):
			var c := Vector2i(b.door_cell().x, py)
			if not world.occupancy.has(c) and world.ground_type(c) != World.GROUND_PATH:
				world.set_ground(c, World.GROUND_PATH)
		if world.building_reachable(b):
			return b
		world.demolish(b)      # 接不上就还原，继续找下一块
	return null


func _place_on_pavement(id: String) -> Building:
	# 直接把建筑盖在现成的地砖上（门口天然就是客人走的路），用于测试「附近有垃圾」一类机制
	var existing: Building = runner._find_building(id)
	if existing:
		return existing
	var data: Dictionary = DataRegistry.get_building(id)
	var f: Array = data.get("footprint", [2, 2])
	var size := Vector2i(int(f[0]), int(f[1]))
	var fallback: Building = null
	for cell in world.walkable_path_cells():
		if not world.can_place(cell, size):
			continue
		var b: Building = world.place_building(id, cell)
		if b == null or not world.building_reachable(b):
			continue
		if runner._walkable_neighbours(cell, size) >= 3:
			return b
		if fallback == null:
			fallback = b      # 先留住一个能用的，实在没有更好的就用它
	if fallback:
		return fallback
	return null


# ---------- 垃圾与心情 ----------

func _run_litter_mood_check() -> void:
	var mood_at: Vector2i = runner._nearest_walkable(world.cell_center(Vector2i(world.ENTRANCE_X0, world.road_row)))
	var guest := Customer.new()
	world.customers_root.add_child(guest)
	if world.reception():
		guest.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		guest.global_position = world.cell_center(mood_at)
		# 先在客人脚下种几个垃圾，否则「脏」这一组根本没东西可脏
		var seeded := 0
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var c: Vector2i = mood_at + Vector2i(dx, dy)
				if world.is_walkable(c) and not world.litter_cells.has(c):
					world.spawn_litter(c)
					seeded += 1
		var dirty_at: int = world.litter_near(guest.global_position, 6.0 * 32.0)
		guest.mood = 80.0
		guest._tick_mood(60.0)
		var decay_dirty := 80.0 - guest.mood
		# 把这一带的垃圾清空，再测一次「干净」的衰减做对照
		var cleaned := 0
		for cell in world.litter_cells.keys():
			if guest.global_position.distance_to(world.cell_center(cell)) <= 6.0 * 32.0:
				world.remove_litter_at(cell)
				cleaned += 1
		guest.mood = 80.0
		guest._tick_mood(60.0)
		var decay_clean := 80.0 - guest.mood
		checks.append("脏乱掉心情：站在 %s，种下 %d 个垃圾（6 格内 %d 个，清掉 %d 个）｜ 1 分钟心情 -%.2f（脏）vs -%.2f（干净）" % [
			str(mood_at), seeded, dirty_at, cleaned, decay_dirty, decay_clean])
	guest.queue_free()


func _read_data_file(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}
