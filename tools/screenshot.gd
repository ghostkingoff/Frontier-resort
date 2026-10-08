extends Node2D
## 画面自检工具：载入主场景，渲染若干帧后把画面存到 .tmp/ 目录。
## 运行：godot --path . res://tools/screenshot.tscn -- --screenshot
## 想看完全测试模式铺满建筑的样子：-- --screenshot --mode=full_test --view=shelves

const OUT_DIR := "res://.tmp"

var main: Node
var frames := 0
var showroom_holder: Node2D
var view_mode := ""      # shelves = 把镜头对准货架区（完全测试模式用）｜ janitor = 保洁工人
var janitor_cam_target: Node2D = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--mode="):
			SaveManager.new_game_mode = arg.split("=")[1]
		elif arg.begins_with("--view="):
			view_mode = arg.split("=")[1]
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)
	await get_tree().process_frame
	var camera: Camera2D = main.get_node("Camera")
	if view_mode == "shelves":
		camera.zoom = Vector2(0.75, 0.75)
		camera.position = main.get_node("World").cell_center(Vector2i(52, 54))
	else:
		camera.zoom = Vector2(1.3, 1.3)
		camera.position = main.get_node("World").cell_center(Vector2i(58, 39))
	# 新档自带每种建筑各一栋，这里只补一个展厅引用给面板用
	var world: Node2D = main.get_node("World")
	var showroom: Node2D = null
	for b in world.buildings:
		if b.is_showroom():
			showroom = b
			break
	GameState.add_item("bar_silver", 3)
	GameState.add_item("gem_purple", 2)
	GameState.add_item("rock", 6)
	GameState.add_item("chest_small", 1)
	GameState.money += 5000
	GameState.money_changed.emit(GameState.money)
	PlayerStats.add_consumable("ration", 2)
	PlayerStats.add_consumable("talisman", 1)
	for b in world.buildings:
		b.hire_staff()
	if showroom:
		showroom.add_display("bar_silver", 2)
		showroom.add_display("chest_small", 1)
		showroom_holder = showroom
	_spawn_demo_customers()
	if view_mode == "janitor":
		await _setup_janitor_scene()


func _setup_janitor_scene() -> void:
	# 建一间保洁间、雇一位保洁工人、在旁边撒点垃圾，把镜头对准工人看清扫
	var world: Node2D = main.get_node("World")
	var size := Vector2i(2, 2)
	var cleaner: Building = null
	for cell in world.walkable_path_cells():
		if not world.can_place(cell, size):
			continue
		var b: Building = world.place_building("amenity_cleaning", cell)
		if b and world.building_reachable(b):
			cleaner = b
			break
		if b:
			world.demolish(b)
	if cleaner == null:
		return
	cleaner.hire_staff()
	# 工人出现后再在附近地砖上撒垃圾
	await get_tree().process_frame
	var janitor: Node2D = null
	for j in cleaner.janitors:
		if j != null and is_instance_valid(j):
			janitor = j
			break
	if janitor == null:
		return
	var planted := 0
	for cell in world.walkable_path_cells():
		if planted >= 6:
			break
		var d: float = world.cell_center(cell).distance_to(cleaner.global_position)
		if d > 400.0 or d < 60.0:
			continue
		world.spawn_litter(cell)
		planted += 1
	var camera: Camera2D = main.get_node("Camera")
	camera.zoom = Vector2(1.5, 1.5)
	camera.position = world.cell_center(cleaner.cell) + Vector2(0, 96)
	janitor_cam_target = janitor


func _spawn_demo_customers() -> void:
	# 放几位顾客从主路走进来，方便检查人物贴图、朝向与寻路
	var world: Node2D = main.get_node("World")
	var types: Array = DataRegistry.customer_types
	var target: Building = world.buildings[0] if not world.buildings.is_empty() else null
	if target == null:
		return
	for i in range(mini(5, types.size())):
		var c := Customer.new()
		world.customers_root.add_child(c)
		c.setup(types[i], world, world.random_entrance())
		# 直接放到镜头能看到的街上，再让他们继续走自己的路线
		var street_cell := Vector2i(38 + i * 9, 41)
		if world.is_walkable(street_cell):
			c.global_position = world.cell_center(street_cell)
			if c.target != null and is_instance_valid(c.target):
				c._start_path_to(c.target.door_cell())


func _process(_delta: float) -> void:
	frames += 1
	if janitor_cam_target != null and is_instance_valid(janitor_cam_target):
		# 镜头跟着保洁工人走，方便看清扫过程
		var camera: Camera2D = main.get_node("Camera")
		camera.position = janitor_cam_target.global_position + Vector2(0, 48)
		if frames == 150:
			_capture("shot_18_janitor.png")
		# 让工人自己走一会儿，看它到底有没有把垃圾清掉（趁探索面板还没打开）
		if frames == 320:
			var world2: Node2D = main.get_node("World")
			var j2: Node2D = null
			var c2: Building = null
			for b in world2.buildings:
				if b.service() == "cleaning":
					c2 = b
					break
			if c2 and not c2.janitors.is_empty():
				j2 = c2.janitors[0]
			print("[screenshot] 保洁工人：累计清掉 %d 个 ｜ 场上还剩 %d 个垃圾" % [
				int(j2.cleaned_total) if j2 else -1, world2.litter_cells.size()])
		if frames == 330:
			_capture("shot_19_janitor_after.png")
	if janitor_cam_target != null:
		# 保洁工人视角：只拍工人在干什么，不跑下面那套界面截图流程
		if frames >= 420:
			get_tree().quit()
		return
	if frames == 90:
		_capture("shot_01_roof_on.png")
	if frames == 120:
		main.get_node("World").set_roof_mode(false)
	if frames == 150:
		_capture("shot_02_roof_off.png")
	if frames == 180:
		main.get_node("World").set_roof_mode(true)
		if showroom_holder:
			# 打开小木屋的面板，展示「住客 / 住宿费」这些新信息
			var lodge: Node2D = null
			for b in main.get_node("World").buildings:
				if b.is_lodging():
					lodge = b
					break
			main.get_node("BuildingPanel").open(lodge if lodge else showroom_holder)
	if frames == 220:
		_capture("shot_03_building_panel.png")
	if frames == 250:
		main.get_node("BuildingPanel").close()
		main.get_node("InventoryPanel").toggle()
	if frames == 290:
		_capture("shot_04_inventory.png")
	if frames == 320:
		main.get_node("InventoryPanel").close()
		main.get_node("StatsPanel").toggle()
	if frames == 360:
		_capture("shot_05_stats.png")
	if frames == 390:
		main.get_node("StatsPanel").close()
		main.get_node("ExplorationPanel").open()
	if frames == 450:
		_capture("shot_06_explore_map.png")
	if frames == 470:
		Exploration.toggle_world()
	if frames == 500:
		_capture("shot_07_explore_world.png")
	if frames == 520:
		Exploration.toggle_world()
		Exploration._trigger_event()
	if frames == 550:
		_capture("shot_08_explore_event.png")
	if frames == 570:
		Exploration.choose(0)
		_force_transition()
	if frames == 610:
		_capture("shot_09_explore_transition.png")
	if frames == 640:
		Exploration.go_home()
		main.get_node("ExplorationPanel").close()
		_set_hour(7.0)
	if frames == 680:
		_capture("shot_09_morning.png")
	if frames == 700:
		_set_hour(12.0)
	if frames == 740:
		_capture("shot_10_noon.png")
	if frames == 760:
		_set_hour(19.0)
	if frames == 800:
		_capture("shot_11_evening.png")
	if frames == 820:
		_set_hour(23.7)
	if frames == 860:
		_capture("shot_12_late.png")
	if frames == 880:
		_set_hour(2.5)
	if frames == 920:
		_capture("shot_13_night.png")
	if frames == 950:
		GameClock.start_new_day()
		GameClock.skip_to_end_of_day()
	if frames == 990:
		_capture("shot_14_settlement.png")
	if frames == 1020:
		var hud: CanvasLayer = main.get_node("HUD")
		hud._start_next_day()
		hud._toggle_build_panel()
	if frames == 1060:
		_capture("shot_15_build_menu.png")
	if frames == 1080:
		# 拆除模式：打开建造菜单 + 选中一栋建筑做高亮预览
		var build := main.get_node("BuildSystem")
		build.select_demolish()
		build.set_process(false)
		var scene_world: Node2D = main.get_node("World")
		var target: Building = null
		for b in scene_world.buildings:
			if b.id == "reception":
				target = b
				break
		if target == null and not scene_world.buildings.is_empty():
			target = scene_world.buildings[0]
		if target:
			build._cell = target.cell + Vector2i(2, 2)
			build.pending_demolish = target      # 预览“再点一次确认”的状态
			build._update_demolish_marker()
	if frames == 1120:
		_capture("shot_16_demolish.png")
	if frames == 1140:
		# 知名度拉高后重开建造菜单：检查「（知名度 XXX 解锁）」的置灰项是否变成可建
		var build_sys := main.get_node_or_null("BuildSystem")
		if build_sys:
			build_sys.cancel()
		GameState.add_fame(1500.0)
		var hud: CanvasLayer = main.get_node("HUD")
		if not hud.build_panel.visible:
			hud._toggle_build_panel()
		else:
			hud._refresh_build_list()
	if frames == 1180:
		_capture("shot_17_build_menu_unlocked.png")
	if frames == 1200:
		get_tree().quit()


func _force_transition() -> void:
	# 直接走到一个能出图的位置，然后出图，方便截图看过渡区
	for d in Exploration.DIRS:
		if not Exploration.world_map.has(Exploration.current_tile + d):
			continue
		for cell in Exploration.current_local_map().keys():
			if Exploration.can_exit_from(cell, d):
				Exploration.player_cell = cell
				Exploration.exit_to(d)
				return


func _set_hour(hour: float) -> void:
	# 传 0-6 表示凌晨（属于第二天），6-24 表示当天
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf((target - GameClock.DAY_START_HOUR) / 24.0, 0.0, 1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.settle_24_done = GameClock.progress >= GameClock.SETTLE_PROGRESS
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())


func _capture(file_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s" % [OUT_DIR, file_name]
	var err := img.save_png(path)
	print("[screenshot] %s -> %s" % [file_name, error_string(err)])
