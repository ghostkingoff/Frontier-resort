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


func _run_build_mode_checks() -> void:
	# 建造模式的进入 / 退出：右键必须和 ESC 等价（纯鼠标操作），且三种模式都要能退出
	var bs := get_node_or_null("../BuildSystem")
	var cam := get_node_or_null("../Camera")
	if bs == null:
		checks.append("建造模式：找不到 BuildSystem，跳过")
		return
	var results: Array = []
	for mode in ["demolish", "paint", "place"]:
		match mode:
			"demolish": bs.select_demolish()
			"paint": bs.select_ground(World.GROUND_PATH)
			_: bs.select("shop_general")
		var entered: bool = bs.is_demolishing() or bs.is_painting() or str(bs.selected_id) != ""
		var right_click := InputEventMouseButton.new()
		right_click.button_index = MOUSE_BUTTON_RIGHT
		right_click.pressed = true
		bs._unhandled_input(right_click)
		var exited: bool = not (bs.is_demolishing() or bs.is_painting() or str(bs.selected_id) != "")
		results.append("%s：进入 %s → 右键退出 %s" % [mode, str(entered), str(exited)])
	checks.append("右键退出建造模式：%s" % " ｜ ".join(results))

	# 移动视口模式：按钮切换后左键按住应能平移相机，且起步不是瞬间拉满
	if cam == null or not cam.has_method("toggle_pan_mode"):
		checks.append("移动视口模式：找不到相机或接口，跳过")
		return
	var cam_ref: Camera2D = cam
	# headless 下 warp_mouse 无效（鼠标固定 0,0），只能测「恒定推力」的情形。
	# 为避免相机撞到边界把位移吃掉，测试期间把边界临时放大，测完还原。
	var lim_backup := [cam_ref.limit_left, cam_ref.limit_top, cam_ref.limit_right, cam_ref.limit_bottom]
	cam_ref.limit_left = -1000000
	cam_ref.limit_top = -1000000
	cam_ref.limit_right = 1000000
	cam_ref.limit_bottom = 1000000
	var on: bool = cam_ref.toggle_pan_mode()
	get_viewport().warp_mouse(Vector2(
		get_viewport().get_visible_rect().size.x * 0.95,
		get_viewport().get_visible_rect().size.y * 0.25))
	cam_ref.set("_drag_held", true)
	var pos_before: Vector2 = cam_ref.position
	cam_ref._process(0.05)
	var step_early: float = pos_before.distance_to(cam_ref.position)
	var pos_mid: Vector2 = cam_ref.position
	for _i in range(12):
		cam_ref._process(0.05)
	var step_late: float = pos_mid.distance_to(cam_ref.position)
	# 松手：应该继续滑一段（惯性），然后停下来。
	# 注意要累计「从松手到完全停住」的总滑行距离：只测松手后 0.05 秒的位移会被
	# 起步冲量主导，反映不出衰减参数的变化（实测那样测只差 12%，不是真正的滑行量）。
	cam_ref.set("_drag_held", false)
	var pos_release: Vector2 = cam_ref.position
	var glide_total := 0.0
	for _i in range(200):
		var before_step: Vector2 = cam_ref.position
		cam_ref._process(0.05)
		glide_total += before_step.distance_to(cam_ref.position)
		if (cam_ref.get("_glide") as Vector2) == Vector2.ZERO:
			break
	var step_glide: float = glide_total
	var rest_pos: Vector2 = cam_ref.position
	var glide_end: Vector2 = cam_ref.get("_glide")
	cam_ref._process(0.2)
	var drift: float = rest_pos.distance_to(cam_ref.position)
	var pan_enabled: bool = bool(cam_ref.get("pan_mode"))
	var off: bool = cam_ref.toggle_pan_mode()
	checks.append("移动视口模式：开启 %s ｜ 起步 0.05 秒走了 %.0f 像素（应远小于中段）｜ 稳定后 0.05 秒 %.0f 像素 ｜ 松手后总滑行 %.1f 像素（衰减率翻倍应约减半）｜ 最终停住（残余 %.1f，再推 0.2 秒漂移 %.1f）｜ 再点关闭 %s" % [
		str(pan_enabled), step_early, step_late, step_glide,
		glide_end.length(), drift, str(not off)])

	# 缩放范围：两端都应是原来的 0.7 倍（1.0→0.7、4.0→2.8）
	for _i in range(40):
		cam_ref._zoom_by(2.0)
	var zmax: float = float(cam_ref.get("_zoom_target"))
	for _i in range(40):
		cam_ref._zoom_by(0.5)
	var zmin: float = float(cam_ref.get("_zoom_target"))
	checks.append("缩放倍率：拉到最大 %.2f（期望 2.80）｜ 拉到最小 %.2f（期望 0.70）" % [zmax, zmin])
	cam_ref.set("_zoom_target", 2.0)
	cam_ref.set("zoom", Vector2(2.0, 2.0))

	# 中键：速度常量为原本的 1700 → 2550（+50%），松手后同样有惯性滑行
	checks.append("中键速度常量：%.0f（原 1700，+50%% = 2550）" % float(cam_ref.get("middle_drag_max_speed")))
	cam_ref.set("_glide", Vector2.ZERO)
	cam_ref.set("_pan_ramp", 0.0)
	cam_ref.set("_pan_held", true)
	for _i in range(20):        # 先跑到稳定速度
		cam_ref._process(0.05)
	var m_pos: Vector2 = cam_ref.position
	cam_ref._process(0.05)
	var mid_step: float = m_pos.distance_to(cam_ref.position)
	var mid_speed: float = (cam_ref.get("_glide") as Vector2).length()
	cam_ref.set("_pan_held", false)
	var mid_glide := 0.0
	for _i in range(200):
		var before_mid: Vector2 = cam_ref.position
		cam_ref._process(0.05)
		mid_glide += before_mid.distance_to(cam_ref.position)
		if (cam_ref.get("_glide") as Vector2) == Vector2.ZERO:
			break
	checks.append("中键移动：稳定速度 %.0f 像素/秒 ｜ 0.05 秒位移 %.0f 像素 ｜ 松手后总滑行 %.1f 像素 ｜ 最终残余 %.1f" % [
		mid_speed, mid_step, mid_glide, (cam_ref.get("_glide") as Vector2).length()])
	cam_ref.limit_left = int(lim_backup[0])
	cam_ref.limit_top = int(lim_backup[1])
	cam_ref.limit_right = int(lim_backup[2])
	cam_ref.limit_bottom = int(lim_backup[3])


func _run_astar_sync_check() -> void:
	# 寻路网格是「增量更新」的（改了哪几格只更新哪几格，见 World._ensure_astar）。
	# 这里逐格对比「增量结果」与「全量重建结果」——只要有人漏标记一格，
	# 网格就会过期、客人会穿墙，而普通玩法测试很难发现。
	world._ensure_astar()
	var a: Array = _snapshot_solid()
	world._astar_dirty_cells.clear()
	world._astar_dirty = true
	world._ensure_astar()
	var b: Array = _snapshot_solid()
	var diff := 0
	for i in range(a.size()):
		if a[i] != b[i]:
			diff += 1
	checks.append("寻路网格同步：%d 格中增量与全量重建不一致 %d 格（必须为 0）" % [a.size(), diff])


func _snapshot_solid() -> Array:
	var out: Array = []
	for y in range(world.grid_size.y):
		for x in range(world.grid_size.x):
			out.append(world._astar.is_point_solid(Vector2i(x, y)))
	return out


func _run_build_checks() -> void:
	_run_build_mode_checks()
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
	# 内容回归（建筑表 / 解锁 / 服务设施 / 保洁工人 / 垃圾）已拆到单独文件
	var content: Node = load("res://tools/smoke_content.gd").new()
	add_child(content)
	content.setup(self)
	content.run()

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
	_run_astar_sync_check()

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

		# 3.4 出入口不再限定门口：把门口那一格堵死，客人应该从外圈其它面进
		var ring: Array = shop.perimeter_cells()
		var door_was: Vector2i = shop.door_cell()
		# 先把左侧那一面也铺一条竖路通到主路（模拟玩家在侧面也开了条路）
		var side_x: int = door_was.x - 2
		var side_paved := 0
		for y in range(shop.cell.y, world.road_row + 1):
			var c := Vector2i(side_x, y)
			if world.occupancy.has(c):
				continue
			if world.ground_type(c) != World.GROUND_PATH:
				world.set_ground(c, World.GROUND_PATH)
				side_paved += 1
		world.set_ground(door_was, World.GROUND_WILD)          # 门口那格改成不可通行
		var alt: Vector2i = world.best_entry_cell(shop, world.cell_center(door_was))
		checks.append("出入口不再限定门口：外圈 %d 格 ｜ 另铺侧面路 %d 格 ｜ 堵掉门口 %s 后改从 %s 进（%s）" % [
			ring.size(), side_paved, str(door_was), str(alt),
			"能进" if alt.x != -9999 and alt != door_was else "没找到替代入口"])
		# 门口可通行时应优先选门口
		world.set_ground(door_was, World.GROUND_PATH)
		var preferred: Vector2i = world.best_entry_cell(shop, world.cell_center(door_was))
		checks.append("出入口优先走门口：门口可通行时选的入口就是门口 = %s" % str(preferred == door_was))

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




# ---------- 通用小工具（内容回归那边也用，见 tools/smoke_content.gd） ----------

func _nearest_walkable(pos: Vector2) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_dist := INF
	for cell in world.walkable_path_cells():
		var d: float = world.cell_center(cell).distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = cell
	return best


func _walkable_neighbours(cell: Vector2i, size: Vector2i) -> int:
	var count := 0
	for dx in range(-1, size.x + 1):
		for dy in range(-1, size.y + 1):
			if dx >= 0 and dx < size.x and dy >= 0 and dy < size.y:
				continue      # 建筑自己占的格子
			if world.is_walkable(cell + Vector2i(dx, dy)):
				count += 1
	return count


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


func _str_footprint(data: Dictionary) -> String:
	var f: Array = data.get("footprint", [4, 4])
	return "%dx%d" % [int(f[0]), int(f[1])]
