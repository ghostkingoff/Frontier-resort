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
		spawner.test_interval = 2.5      # 测试档：无视客流量，按这个间隔快速来人
	GameClock.morning_started.connect(_on_morning_started)
	print("[smoke] 测试开始：初始建筑 %d 座" % world.buildings.size())
	GameClock.cycle_length_seconds = 80.0    # 24 小时 ≈ 20 秒（4 倍速下约 5 秒到 24 点）
	GameClock.set_speed(GameClock.Speed.X4)
	# 让每位客人都会生病，方便验证医院流程（正式数值在 data/illnesses.json）
	DataRegistry.illness_config["base_chance"] = 1.0
	_audit_full_test_layout()
	# 测试资金：直接加钱，不计入当日营业额
	GameState.money += 120000
	GameState.money_changed.emit(GameState.money)
	_run_ui_exclusivity_checks()
	_run_idle_animation_checks()
	_run_build_checks()


func _audit_full_test_layout() -> void:
	# 完全测试模式的开局布局检查（放在测试自己开始盖楼之前，量到的才是布局本身）：
	# 资金 / 口碑拉满；建筑不压任何路面；每栋都能从入口走到
	if SaveManager.new_game_mode != SaveManager.MODE_FULL_TEST:
		return
	var on_road: Array = []
	var unreachable: Array = []
	for b in world.buildings:
		var covers := false
		for y in range(b.cell.y, b.cell.y + b.footprint.y):
			for x in range(b.cell.x, b.cell.x + b.footprint.x):
				if world.ground_type(Vector2i(x, y)) == World.GROUND_PATH:
					covers = true
					break
			if covers:
				break
		if covers:
			on_road.append("%s@%s" % [str(b.id), str(b.cell)])
		if not world.building_reachable(b):
			unreachable.append("%s@%s" % [str(b.id), str(b.cell)])
	var money_ok: bool = GameState.money == GameState.FULL_TEST_MONEY
	var rep_ok: bool = is_equal_approx(GameState.reputation, GameState.FULL_TEST_REPUTATION)
	checks.append("完全测试模式布局：资金 %s（应 %s，%s）｜ 口碑 %.0f（应 %.0f，%s）｜ 建筑 %d 栋 ｜ 压住路面 %d 栋%s ｜ 接不上主路 %d 栋%s" % [
		GameState.format_money(GameState.money), GameState.format_money(GameState.FULL_TEST_MONEY), str(money_ok),
		GameState.reputation, GameState.FULL_TEST_REPUTATION, str(rep_ok),
		world.buildings.size(), on_road.size(),
		"" if on_road.is_empty() else "（%s）" % ", ".join(on_road),
		unreachable.size(),
		"" if unreachable.is_empty() else "（%s）" % ", ".join(unreachable)])


func _run_idle_animation_checks() -> void:
	var probe := Customer.new()
	world.customers_root.add_child(probe)
	probe.setup(DataRegistry.customer_types[0], world, world.random_entrance())
	probe._update_animation(Vector2.LEFT, 0.1)
	probe._tick_idle_animation(0.0)
	probe._tick_idle_animation(0.0)
	var customer_idle_ok: bool = probe.idle_texture != null \
		and probe.sprite.texture == probe.idle_texture \
		and probe.sprite.frame == 2 \
		and probe.sprite.vframes == 1
	probe.queue_free()

	var avatar: Node2D = get_tree().get_first_node_in_group("player_avatar")
	var player_idle_ok := false
	var player_blink_ok := false
	var player_down_frames_ok := false
	if avatar:
		var walk_image: Image = avatar.walk_texture.get_image()
		var frame_w := int(walk_image.get_width() / 4)
		var frame_h := int(walk_image.get_height() / 4)
		player_down_frames_ok = true
		for step in range(4):
			var down_frame := walk_image.get_region(
				Rect2i(0, step * frame_h, frame_w, frame_h))
			if down_frame.get_used_rect().size.x <= 0:
				player_down_frames_ok = false
				break
		avatar._facing = 3
		avatar._moving_this_frame = false
		avatar._idle_blink_clock = 0.0
		avatar._idle_blink_left = 0.0
		avatar._tick_idle_animation(7.9)
		player_idle_ok = avatar.sprite.texture == avatar.idle_texture \
			and avatar.sprite.frame == 3
		avatar._tick_idle_animation(0.1)
		player_blink_ok = avatar.sprite.frame == avatar.sprite.hframes * 1 + 3
		avatar._tick_idle_animation(0.5)
		avatar._tick_idle_animation(0.0)
		player_blink_ok = player_blink_ok and avatar.sprite.frame == 3
		avatar._show_idle_frame(false)
	checks.append("静止帧：顾客按朝向取 idle %s ｜玩家下行 4 帧完整 %s ｜8 秒眨眼一次并持续 0.5 秒 %s / %s" % [
		str(customer_idle_ok), str(player_down_frames_ok), str(player_idle_ok), str(player_blink_ok)])


func _run_ui_exclusivity_checks() -> void:
	var hud = get_node_or_null("../HUD")
	var bs = get_node_or_null("../BuildSystem")
	var console = get_node_or_null("../ConsolePanel")
	if hud == null or bs == null:
		checks.append("UI 互斥：找不到 HUD / BuildSystem，跳过")
		return
	hud._prepare_exclusive_ui("", true)

	hud._toggle_build_panel()
	bs.select("food_diner")
	var build_started: bool = hud.build_panel.visible and str(bs.selected_id) == "food_diner"
	hud._toggle_visitor_panel()
	var visitor_switch_ok: bool = hud.visitor_panel.is_open() and not hud.build_panel.visible \
		and str(bs.selected_id) == "" and not bs.is_painting() and not bs.is_demolishing()
	var visitor_highlight_ok: bool = hud.visitors_button.button_pressed \
		and not hud.build_button.button_pressed

	hud._toggle_inventory()
	var inventory_ok: bool = hud.inventory_panel.is_open() and not hud.visitor_panel.is_open() \
		and not hud.stats_panel.is_open()
	var inventory_highlight_ok: bool = hud.inventory_button.button_pressed \
		and not hud.visitors_button.button_pressed
	hud._toggle_stats()
	var stats_ok: bool = hud.stats_panel.is_open() and not hud.inventory_panel.is_open()
	var stats_highlight_ok: bool = hud.stats_button.button_pressed \
		and not hud.inventory_button.button_pressed and hud.stats_panel.panel.offset_top >= 140.0
	hud._toggle_build_panel()
	var build_ok: bool = hud.build_panel.visible and not hud.stats_panel.is_open()
	var build_highlight_ok: bool = hud.build_button.button_pressed \
		and not hud.stats_button.button_pressed
	hud._toggle_build_panel()
	var build_close_ok: bool = not hud.build_panel.visible and str(bs.selected_id) == ""

	var build_target: Building = world.buildings[0]
	hud._toggle_build_panel()
	bs.select("food_diner")
	hud._on_build_mode_building_clicked(build_target)
	var placement_panel_ok: bool = hud.building_panel.is_open() and hud.build_panel.visible \
		and str(bs.selected_id) == "food_diner"
	hud.building_panel.close()
	bs.select_ground(World.GROUND_PATH)
	hud._on_build_mode_building_clicked(build_target)
	var painting_isolated_ok: bool = not hud.building_panel.is_open() \
		and bs.is_painting() and hud.build_panel.visible
	bs.cancel()
	hud._toggle_build_panel()

	hud.enter_demolish_mode()
	hud._on_demolish_prompt_requested(build_target)
	var demolish_prompt_ok: bool = hud.building_panel.is_open() \
		and hud.building_panel.demolition_prompt and not bs.is_demolishing() and not hud.build_panel.visible
	hud.building_panel.close()

	hud._toggle_inventory()
	hud._prepare_exclusive_ui("building", true)
	hud.building_panel.open(world.buildings[0])
	var building_ok: bool = hud.building_panel.is_open() and not hud.inventory_panel.is_open()
	hud.building_panel.close()

	hud._toggle_visitor_panel()
	hud._toggle_pause_menu()
	var pause_ok: bool = hud.pause_menu.visible and not hud.visitor_panel.is_open()
	var pause_highlight_ok: bool = hud.pause_menu_button.button_pressed \
		and not hud.visitors_button.button_pressed
	hud._toggle_pause_menu()

	var console_ok := true
	if console:
		hud._toggle_inventory()
		console.open_console()
		console_ok = console.is_open() and not hud.inventory_panel.is_open() and not hud.pause_menu.visible
		console.close_console()
	hud._prepare_exclusive_ui("", true)
	checks.append("UI 互斥：建造 %s → 游客 %s／高亮 %s ｜游客→仓库 %s／高亮 %s ｜仓库→属性 %s／高亮与下移 %s ｜属性→建造 %s／高亮 %s ｜建造关闭 %s ｜放置时建筑面板保留建造 %s ｜铺地不弹建筑面板 %s ｜拆除提示 %s ｜建筑详情 %s ｜暂停 %s／高亮 %s ｜指令台 %s" % [
		str(build_started), str(visitor_switch_ok), str(visitor_highlight_ok),
		str(inventory_ok), str(inventory_highlight_ok), str(stats_ok), str(stats_highlight_ok),
		str(build_ok), str(build_highlight_ok), str(build_close_ok), str(placement_panel_ok),
		str(painting_isolated_ok), str(demolish_prompt_ok), str(building_ok),
		str(pause_ok), str(pause_highlight_ok), str(console_ok)])


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
			_: bs.select("shop_small")
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
	var cost := int(DataRegistry.get_building("shop_small").get("cost", 0))
	var shop: Building = world.place_building("shop_small", Vector2i(38, 6))
	if shop and GameState.spend(cost, "建造测试"):
		checks.append("建造：%d 座建筑，资金 %d → %d" % [world.buildings.size(), money_before, GameState.money])
	else:
		checks.append("建造：失败")

	# 2. 三层显示循环：屋顶 → 屋内 → 地面
	var actor_probe := Node2D.new()
	actor_probe.add_to_group("actors")
	world.customers_root.add_child(actor_probe)
	world.set_view_mode(World.ViewMode.INTERIOR)
	var interior_ok: bool = (not shop.roof_visible()) and shop.interior_visible()
	var interior_ground_hidden: bool = shop.ground_face != null and not shop.ground_face.visible
	var interior_group_ok: bool = world.interior_sort.visible and not world.ground_sort.visible \
		and world.active_actor_sort == world.interior_sort \
		and actor_probe.get_parent() == world.interior_sort
	world.set_view_mode(World.ViewMode.GROUND)
	var ground_ok: bool = (not shop.roof_visible()) and (not shop.interior_visible()) \
		and shop.ground_face != null and shop.ground_face.visible
	var ground_group_ok: bool = not world.interior_sort.visible and world.ground_sort.visible \
		and world.active_actor_sort == world.ground_sort \
		and actor_probe.get_parent() == world.ground_sort
	world.set_view_mode(World.ViewMode.ROOF)
	var roof_ok: bool = shop.roof_visible() and (not shop.interior_visible())
	var roof_ground_hidden: bool = shop.ground_face != null and not shop.ground_face.visible
	var roof_group_ok: bool = not world.interior_sort.visible and not world.ground_sort.visible \
		and world.active_actor_sort == world.outdoor_sort \
		and actor_probe.get_parent() == world.outdoor_sort
	var global_layers_ok: bool = shop.roof_root.get_parent() == world.outdoor_sort \
		and shop.roof_light_root.get_parent() == world.outdoor_sort \
		and shop.interior.get_parent() == world.interior_sort \
		and shop.ground_face.get_parent() == world.ground_sort \
		and world.interior_sort.z_index > world.outdoor_sort.z_index \
		and world.ground_sort.z_index > world.interior_sort.z_index
	checks.append("三层显示：屋顶 %s（占地层隐藏 %s）｜屋内 %s（占地层隐藏 %s）｜地面透视 %s（占地层显示）" % [
		str(roof_ok), str(roof_ground_hidden), str(interior_ok),
		str(interior_ground_hidden), str(ground_ok)])
	checks.append("全局显示层：结构 %s｜屋顶模式 %s｜屋内组合 %s｜地面组合 %s" % [
		str(global_layers_ok), str(roof_group_ok), str(interior_group_ok),
		str(ground_group_ok)])
	actor_probe.free()
	var layered_ok: bool = shop.ground_face != null and shop.ground_face.texture != null \
		and shop.interior_texture != null and shop.interior_texture.texture != null \
		and shop.exterior != null and shop.exterior.texture != null \
		and shop.layer_origin == Vector2i(0, 107)
	var walk_mask_ok: bool = shop.interior_walk_cells.size() == 12 \
		and shop.interior_roam_grid_cells.size() > 0 and shop.can_roam_interior()
	var walk_entry: Vector2 = shop.interior_entry_point(world.cell_center(shop.door_cell()))
	var roam_route: Array[Vector2] = shop.interior_roam_route(walk_entry)
	var route_clear := roam_route.size() > 1
	for point in roam_route:
		if not shop.interior_roam_can_stand(point):
			route_clear = false
			break
	var left_top := Vector2i(-9999, -9999)
	var right_top := Vector2i(-9999, -9999)
	for grid_cell in shop.interior_roam_grid_cells:
		var local_point: Vector2 = shop.interior_roam_grid_point(grid_cell) - shop.global_position
		if local_point.y >= 88.0:
			continue
		if local_point.x < 80.0:
			left_top = grid_cell
		elif local_point.x > 104.0:
			right_top = grid_cell
	var u_path_ok := false
	if left_top.x >= 0 and right_top.x >= 0:
		var u_path: Array[Vector2i] = shop._interior_roam_grid_path(left_top, right_top)
		var reaches_bridge := false
		u_path_ok = u_path.size() > 2
		for grid_cell in u_path:
			var point: Vector2 = shop.interior_roam_grid_point(grid_cell)
			if not shop.interior_roam_can_stand(point):
				u_path_ok = false
				break
			if point.y - shop.global_position.y >= 88.0:
				reaches_bridge = true
		u_path_ok = u_path_ok and reaches_bridge
	checks.append("小超市店内导航：粗格 %d（%s）｜细网格 %d 点 ｜漫游路线 %d 点且全在遮罩内 %s ｜绕开中间货架缺口 %s" % [
		shop.interior_walk_cells.size(), str(walk_mask_ok), shop.interior_roam_grid_cells.size(),
		roam_route.size(), str(route_clear), str(u_path_ok)])
	var roam_probe := Customer.new()
	world.customers_root.add_child(roam_probe)
	roam_probe.setup(DataRegistry.customer_types[0], world, world.random_entrance())
	roam_probe.target = shop
	roam_probe.purpose = Customer.Purpose.CONSUME
	roam_probe._enter_shop_now(shop)
	roam_probe._interior_roam_pause = 0.0
	var roam_start: Vector2 = roam_probe.global_position
	var strict_roam_ok := true
	for _i in range(160):
		roam_probe._tick_interior_roam(0.05)
		if not shop.interior_roam_can_stand(roam_probe.global_position):
			strict_roam_ok = false
			break
	var roam_moved: bool = roam_probe.global_position.distance_to(roam_start) > 1.0
	var indoor_light_mask_ok: bool = (roam_probe.light_mask & Building.LIGHT_LAYER_INTERIOR) != 0
	roam_probe.leave_now()
	var outdoor_light_mask_ok: bool = roam_probe.light_mask == 1
	checks.append("小超市游客实测：160 次细步移动全在遮罩内 %s ｜确实发生移动 %s ｜屋内/屋外光照遮罩 %s / %s" % [
		str(strict_roam_ok), str(roam_moved), str(indoor_light_mask_ok), str(outdoor_light_mask_ok)])

	var legacy_lighting_removed: bool = shop.local_lighting == null \
		and shop.night_light == null
	checks.append("旧建筑光照：通用 PointLight2D、窗晕和扇形遮罩已移除 %s" % [
		str(legacy_lighting_removed)])

	var player = world.player_avatar
	var player_lighting_ok: bool = player != null and player.high_quality \
		and player.sprite.material is ShaderMaterial \
		and player.surface_material.get_shader_parameter("normal_texture") != null \
		and bool(player.surface_material.get_shader_parameter(
			"apply_character_facing_gate")) \
		and bool(player.surface_material.get_shader_parameter(
			"ignore_self_projected_shadow")) \
		and bool(player.surface_material.get_shader_parameter(
			"use_nearest_surface")) \
		and is_equal_approx(
			float(player.surface_material.get_shader_parameter(
				"character_shadow_transition_px")),
			48.0) \
		and _player_per_frame_normals_ok(player) \
		and player.get_node_or_null("PlayerLightOccluder") == null \
		and player.walk_normal_texture.get_size() == Vector2(192, 192) \
		and player.idle_normal_texture.get_size() == Vector2(192, 96)
	var spring_lighting = get_node_or_null("../SpringWorldLighting")
	var foot_origin_ok := false
	if spring_lighting != null and player != null and player.sprite != null:
		var expected_foot: Vector2 = player.sprite.to_global(
			Vector2(0.0, player.sprite.get_rect().end.y))
		var shadow_origin: Vector2 = spring_lighting._player_foot_position()
		foot_origin_ok = shadow_origin.is_equal_approx(expected_foot)
	var sun_lighting_ok: bool = spring_lighting != null \
		and spring_lighting.rig != null \
		and spring_lighting.rig.sun_pass.get("directional") != null \
		and (spring_lighting.rig.sun_pass["directional"] as DirectionalLight3D).shadow_enabled \
		and (spring_lighting.rig.sun_pass["directional"] as DirectionalLight3D).shadow_blur >= 3.0 \
		and (spring_lighting.rig.sun_pass["directional"] as DirectionalLight3D).directional_shadow_max_distance >= 12000.0 \
		and spring_lighting.rig.get_sun_texture() != null
	var player_3d_proxy_ok: bool = spring_lighting != null \
		and spring_lighting.rig != null \
		and spring_lighting.rig.player_proxy_resource_path.ends_with(
			"shadow_proxy.glb") \
		and spring_lighting.rig.player_proxies.size() >= 5 \
		and spring_lighting.rig.player_contact_proxy != null \
		and spring_lighting.rig.get_player_sun_texture() != null
	checks.append("玩家新光照：逐帧法线与整体背光门控 %s｜旧2D遮挡已移除 %s｜3D柔化太阳阴影 %s｜阴影脚底原点 %s｜角色 3D 代理 %s" % [
		str(player_lighting_ok),
		str(player.get_node_or_null("PlayerLightOccluder") == null),
		str(sun_lighting_ok), str(foot_origin_ok),
		str(player_3d_proxy_ok)])
	var lighting_debug_ok: bool = spring_lighting != null \
		and spring_lighting.has_method("set_debug_mode")
	checks.append("实时光照调试：F1 调试通道接口 %s" % str(lighting_debug_ok))

	# 3. 员工：挑一栋有员工编制的建筑招人（度假屋/招待厅本来就不雇人）
	var staffed: Building = null
	for b in world.buildings:
		if b.staff_slots() > 0:
			staffed = b
			break
	if staffed:
		staffed.hire_staff()
		checks.append("员工：%s 在职 %d 人，日工资 %d" % [
			staffed.display_name(), staffed.staff.size(), staffed.daily_wage()])
	else:
		checks.append("员工：没有需要员工的建筑（跳过）")

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
	# 坐标不再写死：取第一栋真实建筑的落位格；空地则在别处找一格。
	var sample: Building = null
	for b in world.buildings:
		if is_instance_valid(b):
			sample = b
			break
	var picked: Building = null
	var empty_cell := Vector2i(2, 2)
	if sample:
		picked = world.building_at(sample.cell)
		while world.building_at(empty_cell) != null and empty_cell.x < world.grid_size.x - 2:
			empty_cell.x += 5
	var empty: Building = world.building_at(empty_cell)
	checks.append("点击选中：建筑 %s（%s）｜ 空地 %s（%s）" % [
		str(picked != null), sample.display_name() if sample else "无样本",
		str(empty == null), str(empty_cell)])


func _process(delta: float) -> void:
	elapsed += delta
	if world and world.customers_root:
		peak_customers = maxi(peak_customers, world.outdoor_customer_count())
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
	var staffed_probe: Building = null
	for b in world.buildings:
		if not b.staff.is_empty():
			staffed_probe = b
			break
	if staffed_probe == null:
		for b in world.buildings:
			if b.staff_slots() > 0:
				staffed_probe = b
				break
	if staffed_probe:
		checks.append("员工状态：%s 在职 %d 人 ｜ 平均体力 %.0f" % [
			staffed_probe.display_name(), staffed_probe.staff.size(), staffed_probe.staff_energy()])
	else:
		checks.append("员工状态：本轮没有员工编制的建筑（跳过）")
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


func _player_per_frame_normals_ok(player) -> bool:
	if player == null or player.walk_normal_texture == null \
			or player.idle_normal_texture == null:
		return false
	var walk_image: Image = player.walk_normal_texture.get_image()
	for direction in range(4):
		var reference: PackedByteArray = walk_image.get_region(Rect2i(
			direction * 48,
			0,
			48,
			48)).get_data()
		var has_variation := false
		for row in range(1, 4):
			if walk_image.get_region(Rect2i(
					direction * 48,
					row * 48,
					48,
					48)).get_data() != reference:
				has_variation = true
		if not has_variation:
			return false
	var idle_image: Image = player.idle_normal_texture.get_image()
	for direction in range(4):
		var top: PackedByteArray = idle_image.get_region(Rect2i(
				direction * 48,
				0,
				48,
				48)).get_data()
		var blink: PackedByteArray = idle_image.get_region(Rect2i(
					direction * 48,
					48,
					48,
				48)).get_data()
		if top == blink:
			return false
	return true


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
		# 治疗中的病人被强行带离/释放：诊所不能留悬空引用
		# （旧 bug：诊所 _process 继续访问已释放的病人 → “previously freed”）
		var sick2 := Customer.new()
		world.customers_root.add_child(sick2)
		sick2.setup(DataRegistry.customer_types[0], world, world.cell_center(clinic_probe.door_cell()))
		var pool2 := DataRegistry.illness_pool(1)
		sick2.illness = pool2[0] if not pool2.is_empty() else {"name": "测试", "level": 1, "treat_hours": 1.0, "fee": 400}
		clinic_probe.accept_patient(sick2)
		sick2._inside_building = clinic_probe
		sick2._force_exit()             # 应把病人从诊所的治疗列表里摘掉
		sick2.free()                    # 模拟该客人随后被直接释放
		var dangling := 0
		for p in clinic_probe.treating:
			if p == null or not is_instance_valid(p):
				dangling += 1
		clinic_probe._process(0.1)      # 旧代码在这里会访问已释放对象
		checks.append("诊所悬空引用：强行带离并释放后 治疗列表 %d 人（原来悬空 %d，应 0）" % [
			clinic_probe.treating.size(), dangling])

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

	# 6. 光照随小时变化（v2：由同一份春季状态曲线驱动）
	var spring_lighting := world.get_parent().get_node_or_null("SpringWorldLighting")
	if spring_lighting:
		var dawn: Dictionary = spring_lighting._sample_light_state(6.5)
		var noon: Dictionary = spring_lighting._sample_light_state(15.0)
		var midnight: Dictionary = spring_lighting._sample_light_state(0.0)
		var small_hours: Dictionary = spring_lighting._sample_light_state(3.3)
		checks.append("光照：06:30 太阳 %.2f/天空 #%s ｜ 15:00 太阳 %.2f/天空 #%s ｜ 00:00 太阳 %.2f/天空 #%s ｜ 03:20 太阳 %.2f/天空 #%s" % [
			float(dawn["sun_energy"]), (dawn["sky_color"] as Color).to_html(false),
			float(noon["sun_energy"]), (noon["sky_color"] as Color).to_html(false),
			float(midnight["sun_energy"]), (midnight["sky_color"] as Color).to_html(false),
			float(small_hours["sun_energy"]), (small_hours["sky_color"] as Color).to_html(false)])

	# 7. 路灯：1×1 / 1000g / 0 知名度；灯光窗口写在数据里（20:00 亮、04:00 熄）
	var lamp_data := DataRegistry.get_building("street_lamp")
	var lamp: Building = null
	for y in range(20, 40):
		for x in range(30, 60):
			var probe_cell := Vector2i(x, y)
			if world.can_place(probe_cell, Vector2i(1, 1)) and not world.is_walkable(probe_cell):
				lamp = world.place_building("street_lamp", probe_cell)
				if lamp:
					break
		if lamp:
			break
	if lamp:
		var lamp_surface_ok: bool = lamp.wall_texture != null \
			and lamp.roof_texture != null \
			and lamp.wall_texture.material is ShaderMaterial \
			and lamp.roof_texture.material is ShaderMaterial \
			and (lamp.wall_texture.material as ShaderMaterial).get_shader_parameter(
				"normal_texture") != null \
			and (lamp.roof_texture.material as ShaderMaterial).get_shader_parameter(
				"normal_texture") != null
		var lamp_schedule_ok: bool = is_equal_approx(lamp.light_on_hour, 18.0) \
			and is_equal_approx(lamp.light_off_hour, 8.0) \
			and is_equal_approx(lamp.open_hour(), 18.0) \
			and is_equal_approx(lamp.close_hour(), 8.0)
		var lamp_energies: Array[String] = []
		for probe_hour in [17.0, 18.2, 23.0, 7.5, 8.2]:
			lamp_energies.append("%.2f" % lamp.lamp_energy_at(probe_hour))
		var real_lamp_shadow_ok := false
		var lamp_glow_ok := false
		var lamp_ground_shape_ok := false
		if spring_lighting != null:
			_set_hour(23.0)
			var fp: Array = lamp_data.get("footprint", [1, 1])
			var lamp_center: Vector2 = lamp.global_position + Vector2(
				float(fp[0]) * World.CELL * 0.5,
				float(fp[1]) * World.CELL * 0.5)
			var saved_camera_position: Vector2 = spring_lighting.camera.global_position
			spring_lighting.camera.global_position = lamp_center
			spring_lighting._process(0.0)
			var active_lamp: Dictionary = spring_lighting._update_lamp_state(23.0)
			var spot := spring_lighting.rig.lamp_pass.get("lamp") as SpotLight3D
			real_lamp_shadow_ok = bool(active_lamp["active"]) \
				and spot != null and spot.shadow_enabled \
				and spot.light_energy > 0.0
			var active_lights: Array = active_lamp.get("lights", [])
			var ground_aspects := PackedFloat32Array()
			if not spring_lighting.ground_materials.is_empty():
				ground_aspects = PackedFloat32Array(
					spring_lighting.ground_materials[0].get_shader_parameter(
						"local_light_ground_ellipse_aspects"))
			for light_index in range(active_lights.size()):
				var light_spec: Dictionary = active_lights[light_index]
				if not bool(light_spec.get("window_light", false)) \
						and is_equal_approx(
							float(light_spec.get(
								"ground_ellipse_aspect",
								1.0)),
							sqrt(2.0)) \
						and light_index < ground_aspects.size() \
						and is_equal_approx(
							ground_aspects[light_index],
							sqrt(2.0)):
					lamp_ground_shape_ok = true
					break
			var glow := spring_lighting.lamp_glows.get(lamp) as Sprite2D
			var glow_material := glow.material as ShaderMaterial if glow != null else null
			lamp_glow_ok = glow != null and glow.visible \
				and glow.get_parent() == lamp.roof_root \
				and lamp.roof_texture != null \
				and glow.get_index() < lamp.roof_texture.get_index() \
				and glow_material != null \
				and is_equal_approx(
					float(glow_material.get_shader_parameter("opacity")),
					0.12) \
				and is_equal_approx(
					float(glow_material.get_shader_parameter("brightness")),
					0.18)
			spring_lighting.camera.global_position = saved_camera_position
		checks.append("路灯 v2：正式分层材质 %s｜18:00-次日08:00 %s｜能量 %s｜真实 Spot 阴影 %s｜灯头光 12%% 透明度/18%% 亮度且由灯头覆盖 %s｜45°椭圆地块光 %s｜旧 PointLight2D 已关闭 %s" % [
			str(lamp_surface_ok), str(lamp_schedule_ok), " / ".join(lamp_energies),
			str(real_lamp_shadow_ok), str(lamp_glow_ok),
			str(lamp_ground_shape_ok),
			str(lamp.night_light == null)])
	if false:
		var lamp_energy: Array = []
		for probe_hour in [17.0, 18.2, 23.0, 7.5, 8.2]:
			lamp.update_lights(probe_hour)
			lamp_energy.append("%.2f" % lamp.night_light.energy)
		var fp: Array = lamp_data.get("footprint", [0, 0])
		checks.append("路灯：%d×%d ｜ %d g ｜ 解锁 %d ｜ 灯光 17 点 %s ｜ 18:12 %s ｜ 23 点 %s ｜ 07:30 %s ｜ 08:12 %s（应为 0 / 亮 / 亮 / 亮 / 0）" % [
			int(fp[0]), int(fp[1]), int(lamp_data.get("cost", 0)), int(lamp_data.get("unlock_fame", 0)),
			lamp_energy[0], lamp_energy[1], lamp_energy[2], lamp_energy[3], lamp_energy[4]])
		var next_lighting := world.get_parent().get_node_or_null("NextLightingSystem")
		var lamp_spot: SpotLight3D = null
		if next_lighting and next_lighting.sun_shadow_3d:
			next_lighting.sun_shadow_3d.update_lamp_lights(21.0)
			lamp_spot = next_lighting.sun_shadow_3d.get_lamp_light(lamp)
		if next_lighting:
			next_lighting.apply_street_lamp_config()
			lamp.update_lights(21.0)
		var lamp_asset_ok: bool = lamp.wall_texture != null \
			and lamp.roof_texture != null \
			and lamp.layer_origin == Vector2i(16, 32) \
			and lamp_data.get("sprite_layers", {}).has("shadow_proxy") \
			and lamp.wall_texture.material is ShaderMaterial \
			and lamp.roof_texture.material is ShaderMaterial \
			and (lamp.wall_texture.material as ShaderMaterial).get_shader_parameter(
				"normal_texture") != null \
			and (lamp.roof_texture.material as ShaderMaterial).get_shader_parameter(
				"normal_texture") != null
		var lamp_schedule_ok: bool = is_equal_approx(lamp.light_on_hour, 18.0) \
			and is_equal_approx(lamp.light_off_hour, 8.0) \
			and is_equal_approx(lamp.open_hour(), 18.0) \
			and is_equal_approx(lamp.close_hour(), 8.0)
		var footprint: Array = lamp.data.get("footprint", [1, 1])
		var base_center: Vector2 = lamp.global_position + Vector2(
			float(footprint[0]) * Building.CELL * 0.5,
			float(footprint[1]) * Building.CELL * 0.5)
		var lamp_point_ok: bool = lamp.night_light.texture != null \
			and lamp.night_light.texture.get_size() == Vector2(256.0, 256.0) \
			and not lamp.night_light.shadow_enabled \
			and lamp.night_light.range_item_cull_mask == Building.LIGHT_LAYER_GROUND_LAMP \
			and (world.ground.light_mask & Building.LIGHT_LAYER_GROUND_LAMP) != 0 \
			and lamp.night_light.global_position.is_equal_approx(base_center) \
			and lamp.night_light.scale.is_equal_approx(Vector2(1.45, 0.85)) \
			and lamp.night_light.energy > 0.0
		var player = world.player_avatar
		var player_normal_light_ok := false
		if next_lighting != null and player != null \
				and player.surface_material != null:
			var saved_position: Vector2 = player.global_position
			player.global_position = lamp.night_light.global_position
			next_lighting._update_player_local_light(21.0)
			player_normal_light_ok = float(player.surface_material.get_shader_parameter(
				"local_light_energy")) > 0.0
			player.global_position = saved_position
			next_lighting._update_player_local_light(GameClock.hour_of_day())
		var lamp_shadow_ok: bool = lamp_spot != null and lamp_spot.shadow_enabled \
			and is_zero_approx(lamp_spot.light_energy) \
			and not lamp_spot.visible \
			and lamp_spot.light_projector != null
		var ground_shadow_ok := false
		if next_lighting != null and player != null and player.sprite != null:
			var lamp_runtime: StreetLampLight = lamp.local_lighting
			var foot_offset: Vector2 = next_lighting.sun_shadow_3d.player_foot_world_position(
				player) - player.global_position
			player.detach_to(base_center - foot_offset)
			lamp.update_lights(21.0)
			var contact_scale: Vector2 = lamp_runtime.actor_shadow.scale
			var contact_visible: bool = lamp_runtime.actor_shadow.visible \
				and is_zero_approx(lamp_runtime.actor_shadow.rotation)
			player.detach_to(base_center \
				+ Vector2(lamp_runtime.pool_radius_px.x * 0.55, 0.0) - foot_offset)
			lamp.update_lights(21.0)
			var offset_shadow: Sprite2D = lamp_runtime.actor_shadow
			var outward_ok: bool = offset_shadow.visible \
				and offset_shadow.global_position.x > base_center.x \
				and is_equal_approx(offset_shadow.rotation, -PI * 0.5)
			var farther_longer_ok: bool = offset_shadow.scale.y > contact_scale.y
			var proxy_width: float = next_lighting.sun_shadow_3d.player_shadow.get_aabb().size.x
			var width_ok: bool = is_equal_approx(
				contact_scale.x * offset_shadow.texture.get_width(), proxy_width)
			player.reset_to_reception()
			lamp.update_lights(GameClock.hour_of_day())
			ground_shadow_ok = lamp_runtime.shadow_root != null \
				and lamp_runtime.shadow_root.get_parent() == world.map_layer_root \
				and contact_visible and outward_ok and farther_longer_ok and width_ok
		var brightness_falloff_ok: bool = next_lighting != null \
			and is_equal_approx(
				float(next_lighting.street_lamp_config.get("brightness", -1.0)),
				5.0) \
			and is_equal_approx(
				float(next_lighting.street_lamp_config.get("falloff_power", -1.0)),
				0.8)
		checks.append("路灯新光照：分层素材/代理 %s｜底座椭圆点光 %s｜亮度/衰减接口 %s｜18:00-次日08:00 %s｜玩家不受覆盖 %s｜玩家法线受光 %s｜地面动态影 %s｜旧3D光影关闭 %s" % [
			str(lamp_asset_ok), str(lamp_point_ok), str(brightness_falloff_ok),
			str(lamp_schedule_ok), str(lamp_point_ok),
			str(player_normal_light_ok), str(ground_shadow_ok), str(lamp_shadow_ok)])

		# 旋转只改变灯具外观，底座椭圆光池和 3D 灯光方向保持不变。
		var dirs: Array = []
		var light_direction_fixed := true
		var point_light_fixed := true
		var initial_light_transform := Transform3D.IDENTITY
		var initial_point_transform: Transform3D = lamp.night_light.global_transform
		if next_lighting and next_lighting.sun_shadow_3d:
			next_lighting.sun_shadow_3d.update_lamp_lights(21.0)
			lamp_spot = next_lighting.sun_shadow_3d.get_lamp_light(lamp)
			if lamp_spot != null:
				initial_light_transform = lamp_spot.global_transform
			else:
				light_direction_fixed = false
		else:
			light_direction_fixed = false
		for _i in range(4):
			lamp.rotate_clockwise()
			dirs.append(str(Vector2(lamp.rotation_dir()).normalized()))
			if not lamp.night_light.global_transform.is_equal_approx(
					initial_point_transform):
				point_light_fixed = false
			if next_lighting and next_lighting.sun_shadow_3d:
				next_lighting.sun_shadow_3d.update_lamp_lights(21.0)
				lamp_spot = next_lighting.sun_shadow_3d.get_lamp_light(lamp)
				if lamp_spot == null \
						or not lamp_spot.global_transform.is_equal_approx(
							initial_light_transform):
					light_direction_fixed = false
		checks.append("路灯旋转：3D方向固定 %s｜椭圆光池固定 %s｜贴图保持竖直 %s｜四向 %s" % [
			str(light_direction_fixed), str(point_light_fixed),
			str(is_zero_approx(lamp.exterior.rotation)),
			" → ".join(dirs)])
		# 朝向要能进存档（停在「左」，避免和默认朝向 0 撞巧）
		lamp.rotate_clockwise()
		var snapshot: Dictionary = lamp.save_data()
		var saved_rot := int(snapshot.get("rot", -1))
		lamp.rot_step = 0
		lamp.apply_save(snapshot)
		checks.append("路灯朝向存档：写入 %d ｜ 读档恢复 %d ｜ 朝向文本 %s" % [
			saved_rot, lamp.rot_step, lamp.rotation_text()])
		# 拆除 / 清场时灯光要一起回收（灯挂在 World 根下，不在建筑子节点里）
		var probe_lamp := Building.new()
		world.buildings_root.add_child(probe_lamp)
		probe_lamp.setup(DataRegistry.get_building("street_lamp"), Vector2i(2, 2), world)
		var probe_light: PointLight2D = probe_lamp.night_light
		probe_lamp.free()
		checks.append("灯光回收：建筑释放后灯已回收 %s" % str(
			not is_instance_valid(probe_light) or probe_light.is_queued_for_deletion()))
		if next_lighting and next_lighting.sun_shadow_3d and is_instance_valid(lamp):
			var had_spot: bool = next_lighting.sun_shadow_3d.lamp_lights.has(lamp)
			world.remove_building(lamp)
			var spot_removed: bool = not next_lighting.sun_shadow_3d.lamp_lights.has(lamp)
			checks.append("路灯移除：3D 聚光灯同步清理 %s（移除前存在 %s）" % [
				str(spot_removed), str(had_spot)])
	else:
		checks.append("路灯：v2 接管完成，旧版灯光检查已停用")

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
	var dense_grass := Vector2i(5, 20)
	var stone_tile := Vector2i(6, 20)
	world.set_ground(dense_grass, World.GROUND_DENSE_GRASS)
	world.set_ground(stone_tile, World.GROUND_STONE_TILE)
	var dense_source: int = world.ground_misc.get_cell_source_id(dense_grass)
	var stone_source: int = world.ground_path.get_cell_source_id(stone_tile)
	checks.append("新增地面：茂密草地（可行走 %s｜源 %d）｜石砖地（可行走 %s｜源 %d）" % [
		str(world.is_walkable(dense_grass)), dense_source,
		str(world.is_walkable(stone_tile)), stone_source])
	var lamp_probe: Building = _place_building_near("street_lamp", Vector2i(8, 20))
	if lamp_probe:
		var lamp_cell: Vector2i = lamp_probe.cell
		var lamp_ground: String = world.ground_type(lamp_cell)
		var lamp_build = get_node_or_null("../BuildSystem")
		if lamp_build:
			lamp_build.select_demolish()
			lamp_build._handle_demolish_click(lamp_cell)
			lamp_build.cancel()
		var lamp_ok: bool = world.building_at(lamp_cell) == null \
			and world.ground_type(lamp_cell) == lamp_ground
		checks.append("拆除模式：路灯直接拆除并恢复原地砖 %s" % str(lamp_ok))
	var wasteland_cell: Vector2i = world.random_walkable_cell()
	if wasteland_cell.x >= 0:
		var original_kind: String = world.ground_type(wasteland_cell)
		world.set_ground(wasteland_cell, World.GROUND_PATH)
		var build_probe = get_node_or_null("../BuildSystem")
		if build_probe:
			build_probe.select_demolish()
			build_probe._handle_demolish_click(wasteland_cell)
			build_probe.cancel()
		var wasteland_ok: bool = world.ground_type(wasteland_cell) == World.GROUND_WASTELAND \
			and not world.is_walkable(wasteland_cell) \
			and not world.can_place(wasteland_cell, Vector2i(1, 1)) \
			and world.ground_misc.get_cell_source_id(wasteland_cell) == 4
		checks.append("荒地：拆除地砖自动生成 %s（源 %d）" % [
			str(wasteland_ok), world.ground_misc.get_cell_source_id(wasteland_cell)])
		world.set_ground(wasteland_cell, original_kind)
	var grass_cell := Vector2i(-1, -1)
	for y in range(world.build_area.position.y, world.build_area.end.y):
		for x in range(world.build_area.position.x, world.build_area.end.x):
			var c := Vector2i(x, y)
			if not world.occupancy.has(c) and not world.is_wall(c) \
					and world.ground_type(c) == World.GROUND_WILD:
				grass_cell = c
				break
		if grass_cell.x >= 0:
			break
	if grass_cell.x >= 0:
		var grass_build = get_node_or_null("../BuildSystem")
		if grass_build:
			grass_build.select_demolish()
			grass_build._handle_demolish_click(grass_cell)
			grass_build.cancel()
		checks.append("草地可拆除并变为荒地 %s" % str(
			world.ground_type(grass_cell) == World.GROUND_WASTELAND))
		world.set_ground(grass_cell, World.GROUND_WILD)
	var drag_cells: Array[Vector2i] = []
	for y in range(world.build_area.position.y, world.build_area.end.y):
		for x in range(world.build_area.position.x, world.build_area.end.x - 1):
			var c := Vector2i(x, y)
			var neighbor := c + Vector2i.RIGHT
			if not world.occupancy.has(c) and not world.occupancy.has(neighbor) \
					and not world.is_wall(c) and not world.is_wall(neighbor):
				drag_cells = [c, neighbor]
				break
		if not drag_cells.is_empty():
			break
	if drag_cells.size() == 2:
		var drag_backup: Array[String] = []
		var drag_build = get_node_or_null("../BuildSystem")
		for c in drag_cells:
			drag_backup.append(world.ground_type(c))
			world.set_ground(c, World.GROUND_PATH)
		if drag_build:
			drag_build.select_demolish()
			for c in drag_cells:
				drag_build._demolish_drag_at(c)
			drag_build.cancel()
		var drag_ok := true
		for c in drag_cells:
			if world.ground_type(c) != World.GROUND_WASTELAND:
				drag_ok = false
				break
		checks.append("拆除地砖拖拽连续生效 %s" % str(drag_ok))
		for i in range(drag_cells.size()):
			world.set_ground(drag_cells[i], drag_backup[i])

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
	var shop: Building = world.place_building("shop_small", Vector2i(50, 24))
	if shop:
		var under_building: Vector2i = shop.cell
		var nonwalk_under_ok: bool = world.can_paint_ground(
			under_building, World.GROUND_DENSE_GRASS)
		var walk_under_blocked: bool = not world.can_paint_ground(
			under_building, World.GROUND_STONE_TILE)
		world.set_ground(under_building, World.GROUND_DENSE_GRASS)
		var painted_under: bool = world.ground_type(under_building) == World.GROUND_DENSE_GRASS
		world.set_ground(under_building, World.GROUND_WILD)
		checks.append("建筑下地面：不可行走块可替换 %s（实际写入 %s）｜可行走块被阻止 %s" % [
			str(nonwalk_under_ok), str(painted_under), str(walk_under_blocked)])
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
	# 夜间休息：午夜后回房睡觉，应该在房里一觉到天亮，而不是在门口反复进出。
	# （旧 bug：跨过 24 点时已经定好醒来时间，进房时计时器没被重置成「睡到天亮」，
	#   于是进房即结束、再进再结束，看起来就是住客在度假屋里乱闪。）
	var off_path := 0
	var night_type: Dictionary = {}
	for t in DataRegistry.customer_types:
		if int(t.get("max_nights", 0)) > 0:
			night_type = t
			break
	var night_probe := Customer.new()
	world.customers_root.add_child(night_probe)
	night_probe.setup(night_type, world, world.random_entrance())
	var probe_room: Building = world.lodge_with_free_room()
	if probe_room:
		night_probe.lodge = probe_room
		probe_room.add_guest(night_probe)
	GameClock.paused = false
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.progress = 0.7       # 先停在夜里之前
	night_probe._process(0.2)
	GameClock.progress = 0.85      # 跨过 24 点：系统给今晚定下醒来时间
	night_probe._process(0.2)
	night_probe.action_left = 0.0  # 模拟「午夜后又逛了一处、计时器已经用完」再回房
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
	checks.append("夜间休息：房位 %s ｜ 一晚进房 %d 次（应为 1 次左右）｜ 走路时站在不可通行格 %d 次" % [
		str(probe_room != null), night_entries, off_path])
	if is_instance_valid(night_probe):
		night_probe.queue_free()
	if lodge:
		checks.append("度假屋收入：结账后 %s（结账前 %s）｜ 当前住客 %d 间" % [
			GameState.format_money(lodge.total_earned), GameState.format_money(lodge_earned_before), lodge.guests.size()])
	if is_instance_valid(guest):
		guest.queue_free()


func _run_demolish_checks() -> void:
	var before_count: int = world.buildings.size()
	var shop: Building = _place_building_near("shop_small", Vector2i(46, 20))
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
	var shop_cells: Array[Vector2i] = []
	var ground_under_shop: Array[String] = []
	for y in range(shop.cell.y, shop.cell.y + shop.footprint.y):
		for x in range(shop.cell.x, shop.cell.x + shop.footprint.x):
			var c := Vector2i(x, y)
			shop_cells.append(c)
			ground_under_shop.append(world.ground_type(c))
	var result: Dictionary = world.demolish(shop)
	var ground_restore_ok := true
	for i in range(shop_cells.size()):
		if world.ground_type(shop_cells[i]) != ground_under_shop[i]:
			ground_restore_ok = false
			break
	checks.append("拆除店铺：%s ｜ 预期返还 %d ｜ 实际 +%d ｜ 建筑 %d → %d" % [
		str(result.get("name", "")), refund_expect, GameState.money - money_before,
		before_count + 1, world.buildings.size()])
	checks.append("建筑拆除后恢复原本地面 %s" % str(ground_restore_ok))
	var next_lodge: Building = _find_building("lodge_ordinary")
	var next_system := world.get_parent().get_node_or_null("SpringWorldLighting")
	var next_asset_ok: bool = next_lodge != null \
		and next_lodge.wall_texture != null and next_lodge.wall_texture.texture != null \
		and next_lodge.roof_texture != null and next_lodge.roof_texture.texture != null \
		and next_lodge.ground_terrain != null \
		and next_lodge.ground_terrain.texture != null \
		and next_lodge.interior_texture != null \
		and next_lodge.wall_texture.material is ShaderMaterial \
		and next_lodge.roof_texture.material is ShaderMaterial \
		and next_lodge.ground_terrain.material is ShaderMaterial \
		and next_lodge.interior_texture.material is ShaderMaterial \
		and (next_lodge.wall_texture.material as ShaderMaterial).get_shader_parameter(
			"normal_texture") != null \
		and (next_lodge.roof_texture.material as ShaderMaterial).get_shader_parameter(
			"normal_texture") != null
	var next_portals_ok: bool = (
		next_lodge.interior_walk_cells.size() > 0
		and not next_lodge.interior_interaction_cells.is_empty()
		and ResourceLoader.exists(
			"res://data/lighting_portals/lodge_ordinary.json")
		and ResourceLoader.exists(
			"res://art/characters/buildings/lodge_ordinary/shadow_proxy.glb")) \
		if next_lodge != null else false
	checks.append("新光影资产：ground/wall/roof/interior 分层与材质 %s｜portal/代理数据 %s｜系统节点 %s" % [
		str(next_asset_ok), str(next_portals_ok), str(next_system != null)])
	var schedule_ok := false
	var leak_shape_ok := false
	var leak_edge_ok := false
	var wall_shadow_ok := false
	var lodge_proxy_ok := false
	var exposure_schedule_ok := false
	var ambient_schedule_ok := false
	if next_system != null:
		var sun_night: Dictionary = next_system._sample_light_state(2.0)
		var sun_noon: Dictionary = next_system._sample_light_state(12.0)
		var sun_evening: Dictionary = next_system._sample_light_state(18.5)
		schedule_ok = is_zero_approx(float(sun_night["sun_energy"])) \
			and float(sun_noon["sun_energy"]) > 0.75 \
			and float(sun_evening["sun_energy"]) > 0.0 \
			and float(sun_evening["sun_energy"]) < float(sun_noon["sun_energy"])
		exposure_schedule_ok = is_equal_approx(
				float(next_system.config.get("exposure_day", -1.0)),
				0.78) \
			and is_equal_approx(
				float(next_system.config.get("exposure_night", -1.0)),
				0.20) \
			and float(next_system.config.get("exposure_night", 1.0)) \
				< float(next_system.config.get("exposure_day", 0.0))
		var night_sky: Color = sun_night["sky_color"]
		var noon_sky: Color = sun_noon["sky_color"]
		ambient_schedule_ok = not night_sky.is_equal_approx(noon_sky) \
			and night_sky.get_luminance() < noon_sky.get_luminance()
		if next_lodge != null:
			var wall_material := next_lodge.wall_texture.material as ShaderMaterial
			var roof_material := next_lodge.roof_texture.material as ShaderMaterial
			wall_shadow_ok = wall_material != null and roof_material != null \
				and bool(wall_material.get_shader_parameter(
					"receive_projected_shadow")) \
				and not bool(roof_material.get_shader_parameter(
					"receive_projected_shadow")) \
				and is_equal_approx(
					float(wall_material.get_shader_parameter(
						"surface_foot_uv_y")),
					217.0 / 256.0) \
				and is_equal_approx(
					float(wall_material.get_shader_parameter(
						"canvas_height_px")),
					256.0) \
				and wall_material.get_shader_parameter(
					"sun_shadow_texture") != null
		var proxy_root := next_system.rig.sun_pass.get("proxy_root") as Node3D
		lodge_proxy_ok = proxy_root != null and proxy_root.get_child_count() > 0
	var window_emission_ok := false
	var window_spill_ok := false
	var window_projection_ok := false
	if next_system != null and next_lodge != null:
		var saved_hour := GameClock.hour_of_day()
		var portal_entry: Dictionary = next_system.portal_entries.get(
			next_lodge, {})
		var emission_sprites: Array = portal_entry.get(
			"emission_sprites", [])
		var emission_materials: Array = portal_entry.get(
			"emission_materials", [])
		_set_hour(22.0)
		next_system._process(0.0)
		window_emission_ok = emission_sprites.size() >= 2 \
			and (emission_sprites[0] as Sprite2D).visible \
			and float((emission_materials[0] as ShaderMaterial)
				.get_shader_parameter("emission_energy")) > 0.0
		var window_state: Dictionary = next_system._update_lamp_state(22.0)
		var shadow_count := int(window_state.get("shadow_count", 0))
		var window_light_count := 0
		var windows_are_unshadowed := true
		for light_index in range(window_state.get("lights", []).size()):
			var light_spec: Dictionary = window_state["lights"][light_index]
			if bool(light_spec.get("window_light", false)):
				window_light_count += 1
				windows_are_unshadowed = windows_are_unshadowed \
					and light_index >= shadow_count \
					and is_equal_approx(float(light_spec["range"]), 17.5) \
					and is_equal_approx(
						float(light_spec["attenuation_range"]),
						30.625) \
					and is_equal_approx(
						float(light_spec["attenuation_power"]),
						4.0) \
					and is_equal_approx(
						float(light_spec["attenuation_curve"]),
						2.0) \
					and is_equal_approx(
						float(light_spec["ground_ellipse_aspect"]),
						1.0) \
					and float(light_spec["energy"]) > 0.0
		window_spill_ok = windows_are_unshadowed and window_light_count >= 2
		_set_hour(12.0)
		next_system._process(0.0)
		var overlay := portal_entry.get("interior_overlay") as Sprite2D
		var overlay_material := portal_entry.get("interior_material") as ShaderMaterial
		window_projection_ok = overlay != null and overlay_material != null \
			and overlay.visible \
			and float(overlay_material.get_shader_parameter(
				"portal_energy")) > 0.0
		_set_hour(saved_hour)
		next_system._process(0.0)
	if false:
		var sun_7: Dictionary = next_system._sun_state(7.0)
		var sun_10: Dictionary = next_system._sun_state(10.0)
		var sun_13: Dictionary = next_system._sun_state(13.0)
		var sun_16: Dictionary = next_system._sun_state(16.0)
		var sun_19: Dictionary = next_system._sun_state(19.0)
		var shadow_8: float = next_system._shadow_fade(8.0)
		var shadow_10: float = next_system._shadow_fade(10.0)
		var shadow_16: float = next_system._shadow_fade(16.0)
		var shadow_18: float = next_system._shadow_fade(18.0)
		var shadow_19: float = next_system._shadow_fade(19.0)
		schedule_ok = is_zero_approx(float(sun_7["energy"])) \
			and is_equal_approx(float(sun_10["energy"]), float(sun_13["energy"])) \
			and is_equal_approx(float(sun_10["energy"]), float(sun_16["energy"])) \
			and is_zero_approx(float(sun_19["energy"])) \
			and is_zero_approx(shadow_8) \
			and is_equal_approx(shadow_10, 1.0) \
			and is_equal_approx(shadow_16, 1.0) \
			and is_zero_approx(shadow_18) \
			and is_zero_approx(shadow_19) \
			and is_equal_approx(Building.LIGHT_ON_EARLIEST, 18.0) \
			and is_equal_approx(Building.LIGHT_ON_LATEST, 18.75) \
			and is_equal_approx(float(next_system.leak_config.get("on_start_hour", -1.0)), 18.0) \
			and is_equal_approx(float(next_system.leak_config.get("on_end_hour", -1.0)), 18.75) \
			and is_equal_approx(float(next_system.leak_config.get("off_start_hour", -1.0)), 24.0) \
			and is_equal_approx(float(next_system.leak_config.get("off_end_hour", -1.0)), 24.5)
		if next_lodge != null:
			var next_entry: Dictionary = next_system.building_entries.get(next_lodge, {})
			var wall_material: ShaderMaterial = next_entry.get("wall_material")
			var roof_material: ShaderMaterial = next_entry.get("roof_material")
			if wall_material and roof_material:
				wall_shadow_ok = is_equal_approx(
						float(wall_material.get_shader_parameter("receive_projected_shadow")),
						1.0) \
					and is_equal_approx(
						float(roof_material.get_shader_parameter("receive_projected_shadow")),
						0.0) \
					and is_equal_approx(
						float(wall_material.get_shader_parameter("wall_foot_y_px")),
						217.0) \
					and is_equal_approx(
						float(wall_material.get_shader_parameter("canvas_height_px")),
						256.0) \
					and is_equal_approx(
						float(wall_material.get_shader_parameter("projected_shadow_strength")),
						0.79) \
					and is_equal_approx(
						float(wall_material.get_shader_parameter(
							"wall_shadow_fade_start_ratio")),
						1.5) \
					and is_equal_approx(
						float(wall_material.get_shader_parameter(
							"wall_shadow_fade_end_ratio")),
						2.5) \
					and wall_material.get_shader_parameter(
						"projected_shadow_texture") != null
			var leak_sprites: Array = next_entry.get("leak_sprites", [])
			if not leak_sprites.is_empty():
				var leak_sprite: Sprite2D = leak_sprites[0]["sprite"]
				var rendered_size := Vector2(
					leak_sprite.texture.get_width() * leak_sprite.scale.x,
					leak_sprite.texture.get_height() * leak_sprite.scale.y)
				leak_shape_ok = rendered_size.is_equal_approx(Vector2(19.0, 19.0))
				leak_edge_ok = is_equal_approx(
					float(leak_sprite.material.get_shader_parameter("edge_strength")),
					1.4)
	if false and next_system != null and next_lodge != null:
		var proxy: Node3D = next_system.sun_shadow_3d.building_proxies.get(next_lodge)
		var footprint_array: Array = next_lodge.data.get("footprint", [0, 0])
		var center: Vector2 = next_lodge.global_position + Vector2(
			float(footprint_array[0]) * World.CELL * 0.5,
			float(footprint_array[1]) * World.CELL * 0.5)
		var proxy_doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			"res://art/characters/buildings/lodge_ordinary/shadow_proxy.json"))
		var proxy_size: Array = proxy_doc.get("size_px", []) \
			if proxy_doc is Dictionary else []
		lodge_proxy_ok = proxy != null \
			and proxy.position.is_equal_approx(Vector3(center.x, 0.0, center.y)) \
			and proxy.scale.is_equal_approx(Vector3.ONE) \
			and proxy_size.size() == 3 \
			and absf(float(proxy_size[0]) - 143.44) <= 5.0 \
			and absf(float(proxy_size[1]) - 96.38) <= 5.0
	var daylight_ambient = null
	if false:
		exposure_schedule_ok = is_equal_approx(
				float(next_system.config.get("scene_exposure_day", -1.0)),
				1.0) \
			and is_equal_approx(
				float(next_system.config.get("scene_exposure_night", -1.0)),
				0.60)
	if daylight_ambient != null:
		var frames: Array = DataRegistry.lighting_keyframes
		var night_a: Color = daylight_ambient._sample(frames, 6.9)
		var night_b: Color = daylight_ambient._sample(frames, 19.0)
		var day_a: Color = daylight_ambient._sample(frames, 10.0)
		var day_b: Color = daylight_ambient._sample(frames, 13.0)
		var day_c: Color = daylight_ambient._sample(frames, 16.0)
		var night_expected := Color.from_string("#4b5a83", Color.WHITE)
		var day_expected := Color.from_string("#707291", Color.WHITE)
		ambient_schedule_ok = night_a.is_equal_approx(night_b) \
			and day_a.is_equal_approx(day_b) \
			and day_b.is_equal_approx(day_c) \
			and night_a.is_equal_approx(night_expected) \
			and day_a.is_equal_approx(day_expected)
	checks.append("v2 光影：昼夜太阳曲线 %s｜天空环境曲线 %s｜曝光 %s｜墙面投影标记 %s｜建筑阴影代理 %s｜夜间窗户自发光 %s｜窗户矩形外溢 %s｜白天室内窗光 %s" % [
		str(schedule_ok), str(ambient_schedule_ok),
		str(exposure_schedule_ok), str(wall_shadow_ok),
		str(lodge_proxy_ok),
		str(window_emission_ok), str(window_spill_ok),
		str(window_projection_ok)])
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
	var probe: Building = _place_building_near("shop_small", Vector2i(46, 24))
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
