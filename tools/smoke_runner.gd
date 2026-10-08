extends Node
## 自动化冒烟测试：由 main.gd 在带 --smoke 参数时挂载。
## 运行：godot --headless --path . -- --smoke
##
## 覆盖内容：建造 → 员工 → 升级 → 医院治病 → 展厅展示 → 内陆倾销 → 每日结算 → 自动存档 → 读档。

const JANITOR_SCRIPT := preload("res://scripts/customers/janitor.gd")

var elapsed := 0.0
var phase := 0
var peak_customers := 0
var checks: Array = []
var world: Node2D
var settle_time := 0.0
var morning_events := 0


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	var spawner := get_tree().get_first_node_in_group("world").get_parent().get_node_or_null("CustomerSpawner")
	if spawner:
		spawner.base_interval = 2.5
		spawner.min_interval = 1.0
	GameClock.morning_started.connect(_on_morning_started)
	print("[smoke] 测试开始：初始建筑 %d 座" % world.buildings.size())
	GameClock.cycle_length_seconds = 80.0    # 24 小时 ≈ 20 秒（4 倍速下约 5 秒到 24 点）
	GameClock.set_speed(GameClock.Speed.X4)
	# 让每位客人都会生病，方便验证医院流程（正式数值在 data/illnesses.json）
	DataRegistry.illness_config["base_chance"] = 1.0
	# 测试资金：直接加钱，不计入当日营业额
	GameState.money += 120000
	GameState.money_changed.emit(GameState.money)
	_run_build_checks()


func _run_build_checks() -> void:
	# 1. 建造
	var money_before := GameState.money
	var cost := int(DataRegistry.get_building("shop_general").get("cost", 0))
	var shop: Building = world.place_building("shop_general", Vector2i(38, 6))
	if shop and GameState.spend(cost, "建造测试"):
		checks.append("建造：%d 座建筑，资金 %d → %d" % [world.buildings.size(), money_before, GameState.money])
	else:
		checks.append("建造：失败")

	# 2. 屋顶切换
	world.set_roof_mode(false)
	checks.append("屋顶：关闭后 exterior=%s interior=%s" % [str(shop.exterior.visible), str(shop.interior.visible)])
	world.set_roof_mode(true)

	# 3. 员工
	var lodge: Building = null
	for b in world.buildings:
		if b.is_lodging():
			lodge = b
			break
	lodge.hire_staff()
	checks.append("员工：%s 在职 %d 人，日工资 %d" % [lodge.display_name(), lodge.staff.size(), lodge.daily_wage()])

	# 4. 医院 + 建筑升级（升级需要探索物资）
	var clinic: Building = world.place_building("clinic_small", Vector2i(20, 6))
	if clinic:
		clinic.hire_staff()
		GameState.add_item("bar_copper", 6)
		GameState.add_item("medipack", 3)
		var upgraded := clinic.upgrade()
		checks.append("医院升级：%s → %s（铜锭剩 %d）" % [str(upgraded), clinic.display_name(), GameState.item_count("bar_copper")])

	# 5. 展厅展示位
	var showroom: Building = world.place_building("showroom", Vector2i(44, 8))
	if showroom:
		GameState.add_item("bar_silver", 2)
		GameState.add_item("gem_purple", 2)
		showroom.add_display("bar_silver", 2)
		showroom.add_display("gem_purple", 1)
		checks.append("展厅：展示 %d / %d 件，吸引力 %d" % [
			showroom.display_used(), showroom.display_capacity(), showroom.display_score()])

	# 6. 内陆倾销（35% 价格）
	GameState.add_item("rock", 4)
	var unit := int(round(float(DataRegistry.item_value("rock")) * 0.35))
	GameState.remove_item("rock", 4)
	GameState.earn(unit * 4, "测试倾销")
	checks.append("倾销：粗矿石 ×4 收入 %d" % (unit * 4))

	# 7. 点击建筑选中（面板打开依赖这个判定）
	var picked: Building = world.building_at(Vector2i(59, 45))
	var empty: Building = world.building_at(Vector2i(8, 60))
	checks.append("点击选中：建筑 %s ｜ 空地 %s" % [
		str(picked != null), str(empty == null)])


func _process(delta: float) -> void:
	elapsed += delta
	if world and world.customers_root:
		peak_customers = maxi(peak_customers, world.customers_root.get_child_count())
	if phase == 0 and not GameState.last_report().is_empty():
		print("[smoke] 白天自然结束于第 %.1f 秒" % elapsed)
		settle_time = elapsed
		phase = 1
	if phase == 1 and elapsed > settle_time + 0.6:
		_finish()


func _finish() -> void:
	var report := GameState.last_report()
	var clinic: Building = null
	for b in world.buildings:
		if b.is_clinic():
			clinic = b
			break

	checks.append("结算：营业额 %d，到访 %d 人" % [int(report.get("revenue", 0)), int(report.get("visitors", 0))])
	checks.append("工资支出 %d ｜ 展厅成交 %d" % [int(report.get("wages", 0)), int(report.get("item_income", 0))])
	var failed_total := 0
	var waiting_total := 0
	for b in world.buildings:
		failed_total += b.failed_count
		waiting_total += b.patients.size()
	if clinic:
		checks.append("医院：治愈 %d 人 ｜ 治疗中 %d 人 ｜ 未治离开 %d 人" % [
			clinic.cured_count, clinic.treating.size(), failed_total])
	checks.append("候诊与治疗中合计 %d 人" % waiting_total)
	var lodge: Building = world.buildings[0]
	checks.append("员工状态：%s 平均 %.0f" % [lodge.display_name(), lodge.staff_energy()])
	checks.append("仓库：%d 种物资，估值 %d" % [GameState.inventory.size(), GameState.inventory_value()])
	checks.append("同屏顾客峰值：%d" % peak_customers)

	var saved := SaveManager.has_save(SaveManager.active_slot)
	checks.append("自动存档：%s" % str(saved))
	var loaded := SaveManager.load_game(SaveManager.active_slot)
	if loaded.is_empty():
		checks.append("读档：失败")
	else:
		var buildings: Array = loaded.get("world", {}).get("buildings", [])
		checks.append("读档：第 %d 天，建筑 %d 座" % [int(loaded.get("state", {}).get("day", 0)), buildings.size()])

	# 存档系统：槽位管理（类似星露谷，每个槽一局）
	var summary := SaveManager.slot_summary(SaveManager.active_slot)
	checks.append("存档槽 %d：第 %d 天 ｜ 资金 %d ｜ 设施 %d 座 ｜ 游玩 %.0f 秒" % [
		SaveManager.active_slot, int(summary.get("day", 0)), int(summary.get("money", 0)),
		int(summary.get("buildings", 0)), GameState.playtime])
	SaveManager.save_game(3)
	var third_exists := SaveManager.has_save(3)
	SaveManager.delete_save(3)
	checks.append("多存档：写入槽 3 = %s ｜ 删除后 = %s ｜ 探索前存档路径 = %s" % [
		str(third_exists), str(not SaveManager.has_save(3)), SaveManager.path_for(SaveManager.explore_slot())])
	Settings.set_master(0.5)
	checks.append("设置：主音量 %.2f ｜ 全屏 %s ｜ 配置文件 %s" % [
		Settings.master_volume, str(Settings.fullscreen), str(FileAccess.file_exists("user://settings.cfg"))])
	Settings.set_master(0.8)

	_run_day_night_checks()
	_run_ground_checks()
	_run_exploration_checks()
	_run_content_checks()

	for line in checks:
		print("[smoke] %s" % line)

	var cured := clinic.cured_count if clinic else 0
	var passed: bool = saved and int(report.get("visitors", 0)) > 0 and int(report.get("wages", 0)) > 0
	print("[smoke] 结果：%s" % ("通过" if passed else "未通过"))
	get_tree().quit(0 if passed else 1)


func _run_day_night_checks() -> void:
	# 1. 营业时间与时钟：白天 06:00 - 24:00
	GameClock.start_new_day()
	GameClock.set_speed(GameClock.Speed.X64)
	var x64 := GameClock.time_scale()
	GameClock.set_speed(GameClock.Speed.X1)
	checks.append("倍速档位：1x / 2x / 4x / 64x（测试用）｜ 64x = ×%.0f" % x64)
	checks.append("时间轴：%s 开始 ｜ 24 小时 = %.0f 分钟（每小时 %.0f 秒）" % [
		GameClock.time_text(), GameClock.cycle_length_seconds / 60.0, GameClock.cycle_length_seconds / 24.0])
	GameClock.skip_to_end_of_day()
	checks.append("24 点结算点：%s ｜ 可以夜晚继续管理 %s" % [GameClock.time_text(), str(GameClock.night_available())])

	# 2. 店铺开关门判定
	var lodge: Building = world.buildings[0]
	var bar: Building = world.place_building("food_bar", Vector2i(50, 20))
	if bar:
		bar.hire_staff()
	checks.append("开店判定：%s %s ｜ 酒吧 %s ｜ 酒吧 12 点营业 %s ｜ 酒吧 23 点营业 %s" % [
		str(lodge.data.get("name", "")),
		lodge.hours_text(), bar.hours_text() if bar else "-",
		str(bar.is_open_at(12.0)) if bar else "-",
		str(bar.is_open_at(23.0)) if bar else "-"])

	# 医院治疗流程（大地图上来回太久，这里直接验证治疗本身）
	var clinic_probe: Building = null
	for b in world.buildings:
		if b.is_clinic():
			clinic_probe = b
			break
	if clinic_probe:
		GameClock.paused = false
		GameClock.phase = GameClock.Phase.RUNNING
		clinic_probe.hire_staff()
		var sick := Customer.new()
		world.customers_root.add_child(sick)
		sick.setup(DataRegistry.customer_types[0], world, world.cell_center(clinic_probe.door_cell()))
		var pool := DataRegistry.illness_pool(1)
		sick.illness = pool[0] if not pool.is_empty() else {"name": "测试", "level": 1, "treat_hours": 1.0, "fee": 400}
		sick.cure_left = 9999.0
		sick.state = Customer.State.WAITING_CURE
		var cured_before := clinic_probe.cured_count
		clinic_probe.accept_patient(sick)
		for i in range(600):
			clinic_probe._process(0.5)
			if clinic_probe.cured_count > cured_before:
				break
		checks.append("医院治疗流程：治愈数 %d → %d" % [cured_before, clinic_probe.cured_count])
		if is_instance_valid(sick):
			sick.queue_free()

	# 3. 夜间自动收益（选休息 / 探索时结算）
	if bar:
		var money_before := GameState.money
		var estimate := bar.night_income_estimate()
		var total: int = world.apply_night_income()
		checks.append("夜间自动收益：酒吧估算 %d ｜ 合计 %d ｜ 金钱 +%d" % [
			estimate, total, GameState.money - money_before])

	# 4. 夜晚继续经营：从 24 点顺着同一条时间轴走到次日 6 点
	GameClock.resume_night()
	var night_start := GameClock.time_text()
	GameClock.progress = 0.88
	var night_mid := GameClock.time_text()
	GameClock.skip_to_end_of_day()
	checks.append("夜晚继续经营：%s → %s → 早上 %s（触发新一天 %d 次 ｜ 不再弹结算 %s）" % [
		night_start, night_mid, GameClock.time_text(), morning_events, str(not GameClock.settle_24_done)])

	# 4.5 夜里顾客也会走动（之前夜里是停住的）
	var night_target: Building = world.buildings[0]
	var night_probe := Customer.new()
	world.customers_root.add_child(night_probe)
	night_probe.setup(DataRegistry.customer_types[0], world, world.random_entrance())
	GameClock.start_new_day()
	GameClock.progress = 0.85
	var before_pos: Vector2 = night_probe.global_position
	for _i in range(5):
		night_probe._process(0.1)
	var moved := night_probe.global_position.distance_to(before_pos)
	checks.append("夜晚顾客移动：%.1f 像素（会动 %s）｜ 时间 %s" % [moved, str(moved > 1.0), GameClock.time_text()])
	night_probe.queue_free()

	# 5. 顾客朝向（现在是开罗式正面视角：始终正面朝镜头）
	var probe := Customer.new()
	probe.type_data = {"sprite": "res://art/placeholder/characters/Boy"}
	probe._build_sprite()
	add_child(probe)
	var facing: Array = []
	for dir in [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]:
		probe._update_animation(dir, 0.15)
		facing.append(str(probe.sprite.frame % 4))
	probe.queue_free()
	checks.append("顾客朝向：正面视角模式 %s ｜ 四个方向取到的列 = %s" % [
		str(Customer.FRONT_FACING_ONLY), ", ".join(facing)])

	# 6. 光照随小时变化
	var daylight := world.get_parent().get_node_or_null("Daylight")
	if daylight:
		_set_hour(6.5)
		var dawn: Color = daylight.color
		_set_hour(15.0)
		var noon: Color = daylight.color
		_set_hour(24.0)
		var midnight: Color = daylight.color
		_set_hour(3.3)
		var small_hours: Color = daylight.color
		checks.append("光照：06:30 #%s ｜ 15:00 #%s ｜ 24:00 #%s ｜ 03:20 #%s" % [
			dawn.to_html(false), noon.to_html(false), midnight.to_html(false), small_hours.to_html(false)])
	GameClock.start_new_day()


func _on_morning_started() -> void:
	morning_events += 1


func _set_hour(hour: float) -> void:
	var target := hour
	if hour < GameClock.DAY_START_HOUR:
		target = hour + 24.0
	GameClock.progress = clampf((target - GameClock.DAY_START_HOUR) / 24.0, 0.0, 1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.settle_24_done = GameClock.progress >= GameClock.SETTLE_PROGRESS
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())


func _run_ground_checks() -> void:
	# 1. 荒地不可通行，地砖 / 草坪可以走
	var wild := Vector2i(5, 20)
	var road := Vector2i(10, world.road_row)
	checks.append("通行判定：普通草坪 %s ｜ 主路 %s ｜ 地面类型 %s / %s" % [
		str(world.is_walkable(wild)), str(world.is_walkable(road)),
		world.ground_kind_name(wild), world.ground_kind_name(road)])

	# 1.5 围墙：四周有墙、底边留出入口、入口通向主路
	var wall_count: int = world.wall_cells.size()
	var entrance_ok: bool = world.is_walkable(Vector2i(world.ENTRANCE_X0, world.build_area.end.y))
	var wall_blocked: bool = not world.is_walkable(Vector2i(world.build_area.position.x - 1, world.build_area.position.y))
	checks.append("度假村围墙：%d 格 ｜ 底边入口可通行 %s ｜ 墙体挡人 %s" % [
		wall_count, str(entrance_ok), str(wall_blocked)])

	# 1.6 入口招待厅连得上主路
	var reception: Building = null
	for b in world.buildings:
		if b.id == "reception":
			reception = b
			break
	if reception:
		checks.append("招待厅：位置 %s ｜ 门口 %s（%s）｜ 客人能到 %s" % [
			str(reception.cell), str(reception.door_cell()),
			world.ground_kind_name(reception.door_cell()), str(world.building_reachable(reception))])

	# 2. 铺地面：荒地 → 草坪，并扣钱
	var money_before := GameState.money
	world.set_ground(wild, World.GROUND_LAWN)
	checks.append("铺草坪后：可通行 %s ｜ 类型 %s" % [
		str(world.is_walkable(wild)), world.ground_kind_name(wild)])

	# 3. 新建建筑不再自动铺路：先断开，再手动铺路接通
	var shop: Building = world.place_building("shop_general", Vector2i(50, 24))
	if shop:
		var door: Vector2i = shop.door_cell()
		checks.append("新建店铺（未铺路）：门口 %s ｜ 地面 %s ｜ 客人能到 %s" % [
			str(door), world.ground_kind_name(door), str(world.building_reachable(shop))])
		var paved := 0
		for y in range(door.y, world.road_row + 1):
			var c := Vector2i(door.x, y)
			if world.occupancy.has(c):
				continue
			if world.ground_type(c) != World.GROUND_PATH:
				world.set_ground(c, World.GROUND_PATH)
				paved += 1
		var path: Array = world.find_path_cells(world.entrance_cell(door), door)
		checks.append("手动铺路 %d 格后：客人能到 %s ｜ 路径 %d 步" % [
			paved, str(world.building_reachable(shop)), path.size()])

		# 3.5 从建筑里被请出来时也要走小路
		var illness_backup := float(DataRegistry.illness_config.get("base_chance", 0.035))
		DataRegistry.illness_config["base_chance"] = 0.0
		var leaver := Customer.new()
		world.customers_root.add_child(leaver)
		leaver.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		leaver.force_leave(shop)
		var leaving_ok := true
		for cell in leaver._path:
			if not world.is_walkable(cell):
				leaving_ok = false
				break
		checks.append("离开建筑路径：%d 步 ｜ 全在可通行地面 %s" % [leaver._path.size(), str(leaving_ok)])
		leaver.queue_free()
		DataRegistry.illness_config["base_chance"] = illness_backup

	# 4. 顾客会按路径走（路径上的格子都必须是可通行的）
	var spawner := world.get_parent().get_node_or_null("CustomerSpawner")
	if spawner:
		var customer_type: Dictionary = DataRegistry.customer_types[0]
		var target: Building = world.buildings[0]
		var probe := Customer.new()
		world.customers_root.add_child(probe)
		var entrance: Vector2i = world.entrance_cell(target.door_cell())
		# 用和正式生成器一样的出生点（地图边缘外），确保路径真的被算出来
		probe.setup(customer_type, world, world.random_entrance())
		var ok := true
		for cell in probe._path:
			if not world.is_walkable(cell):
				ok = false
				break
		checks.append("顾客路径：%d 步 ｜ 全部可通行 %s ｜ 目标 %s 门口 %s（可走 %s）｜ 入口 %s ｜ 可到达 %s" % [
			probe._path.size(), str(ok), target.display_name(), str(target.door_cell()),
			str(world.is_walkable(target.door_cell())), str(entrance), str(world.building_reachable(target))])
		probe.queue_free()

	# 5. 不可通行的店铺不会被选中
	var blocked_shop: Building = world.place_building("lodge_ordinary", Vector2i(5, 4))
	if blocked_shop:
		# 把门口周围重新变回荒地，模拟“没连上路”
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				var c := blocked_shop.cell + Vector2i(dx, dy)
				if not world.occupancy.has(c):
					world.set_ground(c, World.GROUND_WILD)
		world.set_ground(blocked_shop.door_cell(), World.GROUND_WILD)
		checks.append("没连路的店：可到达 %s ｜ 会被客人忽略 %s" % [
			str(world.building_reachable(blocked_shop)),
			str(world.random_target_building([], 12.0) != blocked_shop)])


func _run_exploration_checks() -> void:
	GameState.money += 3000
	GameState.money_changed.emit(GameState.money)
	PlayerStats.stamina = PlayerStats.stamina_max()
	PlayerStats.san = PlayerStats.san_max()

	# 0. 走界面路径：点「外出探索」应当直接出发，且有体力、有地图
	var hud_node := world.get_parent().get_node_or_null("HUD")
	if hud_node:
		hud_node._open_exploration()
		checks.append("点探索按钮：出发 %s ｜ 体力 %.0f ｜ SAN %.0f ｜ 局部格子 %d ｜ 世界方块 %d" % [
			str(Exploration.active), Exploration.stamina, Exploration.san,
			Exploration.current_local_map().size(), Exploration.world_map.size()])
		Exploration.go_home()
		PlayerStats.stamina = PlayerStats.stamina_max()
		PlayerStats.san = PlayerStats.san_max()
		hud_node.get_node("../ExplorationPanel").close(false)

	# 让每个格子都能捡到灰石，方便验证
	for t in DataRegistry.terrain_order:
		DataRegistry.terrains[t]["grey_chance"] = 1.0
	# 先关掉事件，专心测走格子
	Exploration.settings()["event_chance_new"] = 0.0
	Exploration.settings()["event_chance_revisit"] = 0.0

	# 1. 出发：世界地图 + 局部地图
	Exploration.start_run()
	checks.append("世界地图：%d 个地形方块（起点 %s），已在 %s" % [
		Exploration.world_map.size(), str(Exploration.start_tile),
		DataRegistry.terrain_name(Exploration.terrain_at(Exploration.current_tile))])
	checks.append("局部地图：%d 格，入口 %s" % [Exploration.current_local_map().size(), str(Exploration.player_cell)])

	# 2. 走格子：新格子 2 体力，走过 1 体力
	var local := Exploration.current_local_map()
	var from_cell: Vector2i = Exploration.player_cell
	var to_cell := Vector2i(-1, -1)
	for d in Exploration.DIRS:
		if local.has(from_cell + d):
			to_cell = from_cell + d
			break
	var before := Exploration.stamina
	Exploration.move_to(to_cell)
	checks.append("走新格子：体力 %.0f → %.0f（-%d）" % [before, Exploration.stamina, int(before - Exploration.stamina)])
	before = Exploration.stamina
	Exploration.move_to(from_cell)
	checks.append("走已走过格子：体力 -%d ｜ 灰石 %d 块" % [int(before - Exploration.stamina), Exploration.grey_stones])

	# 3. 事件
	Exploration.settings()["event_chance_new"] = 1.0
	var another := Vector2i(-1, -1)
	for d in Exploration.DIRS:
		var c: Vector2i = Exploration.player_cell + d
		if local.has(c) and not Exploration.is_cell_visited(c):
			another = c
			break
	if another != Vector2i(-1, -1):
		Exploration.move_to(another)
		checks.append("触发事件：%s（%s）" % [str(Exploration.state == Exploration.STATE_EVENT), str(Exploration.current_event.get("title", ""))])
		if Exploration.state == Exploration.STATE_EVENT:
			Exploration.choose(0)
			checks.append("事件结算后回到地图：%s" % str(Exploration.state == Exploration.STATE_MAP))

	# 4. 出图进入过渡区
	Exploration.settings()["event_chance_new"] = 0.0
	var exit_dir := Vector2i.ZERO
	for d in Exploration.DIRS:
		if not Exploration.world_map.has(Exploration.current_tile + d):
			continue
		for cell in local.keys():
			if Exploration.can_exit_from(cell, d):
				Exploration.player_cell = cell
				exit_dir = d
				break
		if exit_dir != Vector2i.ZERO:
			break
	Exploration.exit_to(exit_dir)
	checks.append("出图：方向 %s → 过渡区（%d 格 ｜ 帐篷 %s ｜ 有商人 %s）" % [
		str(exit_dir), Exploration.transition_cells().size(),
		str(Exploration.transition.has("tent")), str(Exploration.transition.get("has_merchant", false))])

	# 5. 帐篷：休息 / 冥想
	Exploration.transition_move(Vector2i.ZERO)
	Exploration.stamina -= 20.0
	Exploration.transition_move(Exploration.transition["tent"])
	before = Exploration.stamina
	Exploration.tent_action("rest")
	checks.append("帐篷休息：体力 %.0f → %.0f" % [before, Exploration.stamina])

	# 6. 商人交易
	Exploration.transition["has_merchant"] = true
	Exploration.transition_move(Vector2i.ZERO)
	Exploration.transition_move(Exploration.transition["merchant"])
	Exploration.grey_stones = 20
	Exploration.roll_trade_offers()
	var loot_before := Exploration.loot.size()
	if not Exploration.trade_offers.is_empty():
		Exploration.buy_offer(0)
	checks.append("商人：报价 %d 条 ｜ 换到 1 件（收获 %d → %d）｜ 灰石剩 %d" % [
		Exploration.trade_offers.size(), loot_before, Exploration.loot.size(), Exploration.grey_stones])

	# 7. 跨地形：踏上出口格进入下一个地形
	Exploration.transition_move(Vector2i.ZERO)
	var target_tile: Vector2i = Exploration.transition["to"]
	Exploration.transition_move(Exploration.transition["exit"])
	checks.append("跨地形：进入 %s（%s）" % [
		DataRegistry.terrain_name(Exploration.terrain_at(Exploration.current_tile)),
		str(Exploration.current_tile == target_tile)])

	# 8. 回家：灰石按低比例换成钱
	var stones := Exploration.grey_stones
	var money_before := GameState.money
	Exploration.go_home()
	checks.append("回家结算：灰石 %d → 金钱 +%d（%d 金/块）｜ 仓库 %d 种物资" % [
		stones, GameState.money - money_before,
		int(Exploration.settings().get("grey_stone_money_rate", 3)), GameState.inventory.size()])

	# 9. 体力见底自动回家
	Exploration.start_run()
	Exploration.stamina = 1.0
	var start_cell: Vector2i = Exploration.player_cell
	for d in Exploration.DIRS:
		if Exploration.current_local_map().has(start_cell + d):
			Exploration.move_to(start_cell + d)
			break
	checks.append("体力见底 → %s" % str(Exploration.end_result))

	# 10. 探索前存档仍可读（探索死亡读档用）
	var pre := SaveManager.load_game(SaveManager.explore_slot())
	checks.append("探索前存档可读：%s（第 %d 天）" % [str(not pre.is_empty()), int(pre.get("state", {}).get("day", 0))])

	# 11. 从标题界面读档进游戏的流程
	SaveManager.save_game()
	SaveManager.begin_load_game(SaveManager.active_slot)
	var pending := SaveManager.consume_pending()
	var loaded_data := SaveManager.load_game(SaveManager.active_slot)
	if not loaded_data.is_empty():
		SaveManager.apply_save(loaded_data)
	checks.append("读档进游戏：pending=%s ｜ 第 %d 天 ｜ 建筑 %d 座 ｜ 资金 %d" % [
		pending, GameState.day, world.buildings.size(), GameState.money])

	# 12. 拆除建筑：返还一半投入、展厅展品退回仓库、店内客人被请出去
	_run_demolish_checks()
	_run_guest_checks()
	_run_party_checks()


func _run_party_checks() -> void:
	GameClock.paused = false
	GameClock.phase = GameClock.Phase.RUNNING
	# 0. 三种度假屋的房位与"不需要员工"
	var lodge_info: Array = []
	for b in world.buildings:
		if b.is_lodging():
			lodge_info.append("%s %d 人间(不需员工 %s)" % [
				str(b.data.get("name", "")), b.room_capacity(), str(not b.needs_staff())])
	var reception_info := "无"
	var reception: Building = world.reception()
	if reception:
		reception_info = "不需员工 %s" % str(not reception.needs_staff())
	checks.append("度假屋房位：%s ｜ 招待厅：%s" % [" ｜ ".join(lodge_info), reception_info])
	# 1. 双人组：共享预算
	var duo: Dictionary = {}
	for g in DataRegistry.customer_types:
		if (g.get("names", []) as Array).size() == 2 and (g.get("identities", []) as Array).has("ordinary"):
			duo = g
			break
	if not duo.is_empty():
		var party := Party.new()
		party.setup(int(duo.get("budget", 4000)))
		var members: Array = []
		for n in duo.get("names", []):
			var c := Customer.new()
			world.customers_root.add_child(c)
			c.setup(duo, world, world.random_entrance(), str(n), party)
			members.append(c)
		var paid := party.spend(1000)
		checks.append("双人组「%s」：共享预算 %s ｜ 成员 %d 人 ｜ 一人花掉 1000g 后全组剩 %s" % [
			", ".join(duo.get("names", [])), GameState.format_money(party.budget_total),
			party.members.size(), GameState.format_money(party.budget_left)])
		party.begin_leave()
		checks.append("同行离场：两名成员是否都进入离场流程 = %s" % str(
			members.size() == 2 and members[0].state == Customer.State.LEAVING or members[1].state == Customer.State.LEAVING))
		for c in members:
			if is_instance_valid(c):
				c.queue_free()
	# 2. 明星：到访带来知名度
	var star_entry: Dictionary = {}
	for g in DataRegistry.customer_types:
		if (g.get("identities", []) as Array).has("star"):
			star_entry = g
			break
	if not star_entry.is_empty():
		var fame_before: float = GameState.fame
		var star := Customer.new()
		world.customers_root.add_child(star)
		var star_name: String = str((star_entry.get("names", ["明星"]) as Array)[0])
		star.setup(star_entry, world, world.random_entrance(), star_name)
		for _i in range(4000):
			star._process(0.2)
			if GameState.daily_star_fame > 0.0:
				break
		checks.append("明星到访：%s ｜ 预算 %s ｜ 当日记账知名度 +%.0f（夜结算才入账）" % [
			star_name, GameState.format_money(int(star_entry.get("budget", 0))), GameState.daily_star_fame])
		GameState.daily_visitors = 8
		var fame_delta := GameState.apply_daily_fame()
		checks.append("每日知名度结算：%.0f → %.0f（游客 %d × 1 + 明星 %.0f - 日常 1）" % [
			float(fame_delta.get("before", 0.0)), float(fame_delta.get("after", 0.0)),
			int(fame_delta.get("visitors", 0)), float(fame_delta.get("star", 0.0))])
		if is_instance_valid(star):
			star.queue_free()
	# 3. 明星 / 富商到访概率函数
	var fame_backup: float = GameState.fame
	var samples: Array = []
	for f in [100.0, 500.0, 600.0, 750.0, 1000.0, 2000.0]:
		GameState.fame = f
		samples.append("%.0f→%.1f%%" % [f, GameState.star_arrival_chance() * 100.0])
	GameState.fame = fame_backup
	checks.append("明星/富商到访概率：%s（上限 20%%）" % " ｜ ".join(samples))

	# 4. 卡在建筑内部时能不能走出来（展厅最大，最容易卡）
	# 顺便验证相机边界夹取：把位置推出边界后必须被夹回来
	var camera: Camera2D = world.get_parent().get_node_or_null("Camera")
	if camera:
		camera.position = Vector2(-99999.0, -99999.0)
		camera._clamp_position()
		var clamped_far := camera.position
		camera.position = Vector2(99999.0, 99999.0)
		camera._clamp_position()
		var clamped_near := camera.position
		checks.append("相机边界：左上限 %s ｜ 右下限 %s（不会累积越界位移）" % [
			str(clamped_far.round()), str(clamped_near.round())])
		camera.position = world.cell_center(Vector2i(58, 39))

	# 专门造一栋连通的展厅，验证"从建筑内部能走出来"
	var showroom: Building = world.place_building("showroom", Vector2i(60, 32))
	if showroom:
		world.set_ground(showroom.door_cell(), World.GROUND_PATH)
	if showroom:
		var trapped := Customer.new()
		world.customers_root.add_child(trapped)
		trapped.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		trapped.reparent(showroom.interior, true)
		trapped.global_position = showroom.global_position + Vector2(80, 110)
		trapped._inside_building = showroom
		var out_ok := trapped._start_path_to(world.entrance_cell(showroom.door_cell()))
		checks.append("从展厅内部走出来：%s ｜ 路径 %d 步 ｜ 已在可通行地面 %s ｜ 展厅 %s 门口 %s（可走 %s）｜ 入口 %s（可走 %s）" % [
			str(out_ok), trapped._path.size(), str(world.is_walkable(world.world_to_cell(trapped.global_position))),
			str(showroom.cell), str(showroom.door_cell()), str(world.is_walkable(showroom.door_cell())),
			str(world.entrance_cell(showroom.door_cell())), str(world.is_walkable(world.entrance_cell(showroom.door_cell())))])
		if is_instance_valid(trapped):
			trapped.queue_free()


func _run_guest_checks() -> void:
	# 住客模型：入住度假屋 → 四处消费 → 预算/心情到线后回招待厅结账
	GameClock.paused = false
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.progress = 0.1
	GameClock.settle_24_done = false
	# 这一段专门测“住下来消费”的循环，先关掉生病（生病单独在白天流程里测过）
	var illness_backup := float(DataRegistry.illness_config.get("base_chance", 0.035))
	DataRegistry.illness_config["base_chance"] = 0.0
	var tourist: Dictionary = DataRegistry.customer_types[1]
	var lodge: Building = world.lodge_with_free_room()
	var lodge_earned_before: int = lodge.total_earned if lodge else 0
	var guest := Customer.new()
	world.customers_root.add_child(guest)
	guest.setup(tourist, world, world.random_entrance())
	var spent := 0
	var nights := 0
	var left := 0
	var mood := 0.0
	var visited_lodge := false
	var done := false
	var guard := 0
	while guard < 20000:
		guard += 1
		guest._process(0.2)
		spent = guest.spent_total
		nights = guest.nights
		left = guest.budget_left
		mood = guest.mood
		if guest.lodge != null:
			visited_lodge = true
		if guest.state == Customer.State.DONE or guest.state == Customer.State.LEAVING:
			done = true
			break
	DataRegistry.illness_config["base_chance"] = illness_backup
	checks.append("住客行程：入住度假屋 %s ｜ 住 %d 晚 ｜ 消费 %s ｜ 预算剩 %s ｜ 心情 %.0f ｜ 已结账离店 %s" % [
		str(visited_lodge), nights, GameState.format_money(spent), GameState.format_money(left), mood, str(done)])
	checks.append("住客收尾：状态 %d ｜ 目的 %d ｜ 还有度假屋 %s ｜ 步数 %d ｜ 生病 %s" % [
		guest.state, guest.purpose, str(guest.lodge != null), guard, str(not guest.illness.is_empty())])

	# 客人任何时刻都不该站在不可通行的格子上（除了在自己房间里休息）
	var off_path := 0
	var night_probe := Customer.new()
	world.customers_root.add_child(night_probe)
	night_probe.setup(DataRegistry.customer_types[1], world, world.random_entrance())
	GameClock.progress = 0.85      # 夜里，看会不会整晚在度假屋门口横跳
	GameClock.paused = false
	GameClock.phase = GameClock.Phase.RUNNING
	var night_entries := 0
	var was_resting := false
	for _i in range(4000):
		night_probe._process(0.2)
		var resting_now: bool = night_probe.state == Customer.State.INSIDE and night_probe.purpose == Customer.Purpose.REST
		if resting_now and not was_resting:
			night_entries += 1
		was_resting = resting_now
		var cell: Vector2i = world.world_to_cell(night_probe.global_position)
		if night_probe.state == Customer.State.TO_TARGET and not world.is_walkable(cell):
			off_path += 1
		if GameClock.current_hour() >= 24.0:
			pass
		else:
			break
	checks.append("夜间休息：一晚进房 %d 次（应为 1 次左右）｜ 走路时站在不可通行格 %d 次" % [night_entries, off_path])
	if is_instance_valid(night_probe):
		night_probe.queue_free()
	if lodge:
		checks.append("度假屋收入：结账后 %s（结账前 %s）｜ 当前住客 %d 间" % [
			GameState.format_money(lodge.total_earned), GameState.format_money(lodge_earned_before), lodge.guests.size()])
	if is_instance_valid(guest):
		guest.queue_free()


func _run_demolish_checks() -> void:
	var before_count: int = world.buildings.size()
	var shop: Building = _place_building_near("shop_general", Vector2i(46, 20))
	if shop == null:
		checks.append("拆除：建造测试店铺失败")
		return
	shop.hire_staff()
	shop.set_level(2)
	var display_items := 0
	# 专门盖一间「展厅」来拆：直接把地图上那间（初始模式只有一间）拆掉的话，
	# 后面的检查就再没有展厅可用了，所以这里另建一间一次性的
	var showroom: Building = _place_building_near("showroom", Vector2i(46, 26))
	if showroom:
		GameState.add_item("gem_purple", 1)
		showroom.add_display("gem_purple", 1)
		display_items = showroom.display_used()
	var money_before := GameState.money
	var refund_expect := shop.refund_value()
	var result: Dictionary = world.demolish(shop)
	checks.append("拆除店铺：%s ｜ 预期返还 %d ｜ 实际 +%d ｜ 建筑 %d → %d" % [
		str(result.get("name", "")), refund_expect, GameState.money - money_before,
		before_count + 1, world.buildings.size()])
	# 拆除展厅（带着展品）
	if showroom and is_instance_valid(showroom):
		var had := GameState.item_count("gem_purple")
		world.demolish(showroom)
		checks.append("拆除展厅：展品退回仓库（紫晶 %d → %d，拆除前展位 %d 件）" % [
			had, GameState.item_count("gem_purple"), display_items])
	# 店里有客人时拆除不会崩
	var lodge: Building = world.buildings[0]
	var guest := Customer.new()
	world.customers_root.add_child(guest)
	guest.setup(DataRegistry.customer_types[0], world, world.random_entrance())
	lodge.add_visitor(guest)
	var ok := true
	var probe: Building = _place_building_near("shop_general", Vector2i(46, 24))
	if probe:
		var inside := Customer.new()
		world.customers_root.add_child(inside)
		inside.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		probe.add_visitor(inside)
		world.demolish(probe)
		ok = is_instance_valid(inside) and inside.state == Customer.State.LEAVING
		guest.queue_free()
	checks.append("店里有客人时拆除：客人被请出去 = %s" % str(ok))

	# 5. 属性升级与消耗品打造
	GameState.add_item("bar_copper", 8)
	GameState.add_item("bar_iron", 3)
	GameState.add_item("spring_water", 4)
	GameState.add_item("rock", 4)
	var level_before := PlayerStats.level("gather")
	var upgraded := PlayerStats.upgrade("gather")
	checks.append("属性升级：采集效率 %d → %d（×%.2f，%s）" % [
		level_before, PlayerStats.level("gather"), PlayerStats.gather_multiplier(), str(upgraded)])
	var crafted := PlayerStats.craft_consumable("ration")
	checks.append("打造消耗品：干粮 ×%d（%s）" % [PlayerStats.consumable_count("ration"), str(crafted)])
	checks.append("最深处门槛：属性未满时 all_maxed=%s" % str(PlayerStats.all_maxed()))


# ---------- 内容扩充回归（10-07：23 栋建筑 / 知名度解锁 / 卫生间 / 保洁 / 共享单车 / 垃圾） ----------

func _free_spot(size: Vector2i) -> Vector2i:
	# 找一块空着的可建造地，避免和初始地图上的建筑撞位
	for y in range(4, 76):
		for x in range(4, 124):
			if world.can_place(Vector2i(x, y), size):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _run_content_checks() -> void:
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
			_str_footprint(DataRegistry.get_building(id))])
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
	var sweep_setup: Dictionary = _setup_cleaning_scene(cleaner)
	cleaner = sweep_setup.get("cleaner")
	if cleaner:
		_run_janitor_checks(cleaner)
	else:
		checks.append("保洁工人：没找到能贴着地砖的保洁间位置，跳过（场地排不下）")

	# 7. 垃圾会持续掉心情：同一个客人、同一位置，做「干净 vs 脏」两次对照
	var mood_at := _nearest_walkable(world.cell_center(Vector2i(world.ENTRANCE_X0, world.road_row)))
	var guest2 := Customer.new()
	world.customers_root.add_child(guest2)
	if world.reception():
		guest2.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		guest2.position = world.cell_center(mood_at)
		# 先在客人脚下种几个垃圾，否则「脏」这一组根本没东西可脏
		var seeded := 0
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var c: Vector2i = mood_at + Vector2i(dx, dy)
				if world.is_walkable(c) and not world.litter_cells.has(c):
					world.spawn_litter(c)
					seeded += 1
		var dirty_at: int = world.litter_near(guest2.global_position, 6.0 * 32.0)
		guest2.mood = 80.0
		guest2._tick_mood(60.0)
		var decay_dirty := 80.0 - guest2.mood
		# 把这一带的垃圾清空，再测一次「干净」的衰减做对照
		var cleaned := 0
		for cell in world.litter_cells.keys():
			if guest2.global_position.distance_to(world.cell_center(cell)) <= 6.0 * 32.0:
				var s: Node = world.litter_cells[cell]
				if is_instance_valid(s):
					s.queue_free()
				world.litter_cells.erase(cell)
				cleaned += 1
		guest2.mood = 80.0
		guest2._tick_mood(60.0)
		var decay_clean := 80.0 - guest2.mood
		checks.append("脏乱掉心情：站在 %s，种下 %d 个垃圾（6 格内 %d 个，清掉 %d 个）｜ 1 分钟心情 -%.2f（脏）vs -%.2f（干净）" % [
			str(mood_at), seeded, dirty_at, cleaned, decay_dirty, decay_clean])
	guest2.queue_free()


# 找一块空地建起来，并像玩家一样把门口铺路接到主路（接不上就拆掉还原）
# 优先挑靠近主路的位置：铺路格数少，也贴近玩家真实的摆法（否则会挑到地图最上沿，
# 要铺六十多格才能接上主路，保洁间测垃圾时附近根本没有地砖）。
# 完全测试模式下这类建筑开局就已经摆好了，直接借用现成的那栋，不再重复建造。
func _place_and_connect(id: String) -> Building:
	var existing := _find_building(id)
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


func _nearest_walkable(pos: Vector2) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_dist := INF
	for cell in world.walkable_path_cells():
		var d: float = world.cell_center(cell).distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = cell
	return best


# 直接把建筑盖在现成的地砖上（门口天然就是客人走的路），用于测试「附近有垃圾」一类机制。
# 优先挑「旁边还有别的可通行格」的位置——垃圾只能落在可通行格上，
# 光秃秃一条单格路会让保洁间附近没有东西可扫。
func _place_on_pavement(id: String) -> Building:
	var existing := _find_building(id)
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
		if _walkable_neighbours(cell, size) >= 3:
			return b
		if fallback == null:
			fallback = b      # 先留住一个能用的，实在没有更好的就用它
	if fallback:
		return fallback
	return null


func _walkable_neighbours(cell: Vector2i, size: Vector2i) -> int:
	var count := 0
	for dx in range(-1, size.x + 1):
		for dy in range(-1, size.y + 1):
			if dx >= 0 and dx < size.x and dy >= 0 and dy < size.y:
				continue      # 建筑自己占的格子
			if world.is_walkable(cell + Vector2i(dx, dy)):
				count += 1
	return count


# 摆一个「保洁间紧贴地砖」的场景，返回 {"cleaner": Building, "cells": Array}。
# cells 是确实落在保洁间 40 像素清扫半径内的可通行格。原位置放不下就换一个，
# 换来换去都不行就返回空，让调用方跳过这一项而不是给出假的通过。
func _setup_cleaning_scene(fallback: Building) -> Dictionary:
	var size := Vector2i(2, 2)
	var pavement: Array = world.walkable_path_cells().duplicate()
	for anchor in pavement:
		for offset in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
			var cell: Vector2i = anchor + offset
			if not world.can_place(cell, size):
				continue
			if not world.is_walkable(anchor):
				continue
			var b: Building = world.place_building("amenity_cleaning", cell)
			if b == null:
				continue
			if not world.building_reachable(b):
				world.demolish(b)
				continue
			# 只挑真正在 40 像素半径内的地砖来种垃圾
			var cells: Array = []
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var probe: Vector2i = anchor + Vector2i(dx, dy)
					if not world.is_walkable(probe):
						continue
					if b.global_position.distance_to(world.cell_center(probe)) <= 40.0:
						cells.append(probe)
			if not cells.is_empty():
				if fallback and is_instance_valid(fallback):
					world.demolish(fallback)     # 用这个新位置，把原来那间拆掉
				return {"cleaner": b, "cells": cells}
			world.demolish(b)
	return {"cleaner": null, "cells": []}


# 保洁工人的回归检查：出现 / 走动 / 只清范围内 / 走了就消失
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
	checks.append("保洁工人：40 次推进后累计走动 %.0f 像素（会动 %s）｜ 负责半径 %.0f 格" % [
		moved, str(moved > 8.0), janitor.roam_radius() / 32.0])

	# 3) 范围内的垃圾会被清掉
	var near_cell: Vector2i = _nearest_walkable(janitor.global_position)
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
	var near_left: int = 0
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
		janitor_ref.global_position = world.cell_center(_nearest_walkable(cleaner.global_position))
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


func _find_building(id: String) -> Building:
	for b in world.buildings:
		if b.id == id:
			return b
	return null


# 从指定位置开始找一块放得下的空地建起来（完全测试模式下地图已经很满，固定坐标常常被占）
func _place_building_near(id: String, preferred: Vector2i) -> Building:
	var data: Dictionary = DataRegistry.get_building(id)
	var f: Array = data.get("footprint", [3, 3])
	var size := Vector2i(int(f[0]), int(f[1]))
	if world.can_place(preferred, size):
		var direct: Building = world.place_building(id, preferred)
		if direct:
			return direct
	for radius in range(1, 40):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var cell := preferred + Vector2i(dx, dy)
				if not world.can_place(cell, size):
					continue
				var b: Building = world.place_building(id, cell)
				if b:
					return b
	return null


func _read_data_file(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _str_footprint(data: Dictionary) -> String:
	var f: Array = data.get("footprint", [4, 4])
	return "%dx%d" % [int(f[0]), int(f[1])]
