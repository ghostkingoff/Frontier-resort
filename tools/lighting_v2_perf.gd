extends Node
## 1080p stress probe for the integrated v2 lighting pipeline.
## Run:
##   godot --path . res://tools/lighting_v2_perf.tscn -- --lighting-v2-perf

const WARMUP_FRAMES := 45
const SAMPLE_FRAMES := 240

var render_viewport: SubViewport
var main: Node
var camera: Camera2D
var world: Node2D
var samples: Array[float] = []
var frame := 0
var started := false
var start_usec := 0
var fog_mode := false
var morning_mode := false
var rain_mode := false


func _ready() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	SaveManager.read_only = true
	for arg in OS.get_cmdline_user_args():
		if arg == "--full-map":
			SaveManager.new_game_mode = SaveManager.MODE_FULL_TEST
		elif arg == "--fog":
			fog_mode = true
		elif arg == "--morning":
			morning_mode = true
		elif arg == "--rain":
			rain_mode = true
	render_viewport = SubViewport.new()
	render_viewport.name = "PerfViewport"
	render_viewport.size = Vector2i(1920, 1080)
	render_viewport.use_hdr_2d = true
	render_viewport.transparent_bg = false
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(render_viewport)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	render_viewport.add_child(main)
	world = main.get_node("World")
	camera = main.get_node("Camera")
	camera.set_process(false)
	camera.zoom = Vector2(0.82, 0.82)
	WorldWeather.set_today_rain_force(1 if rain_mode else -1)
	if fog_mode:
		WorldWeather.set_fog_force(1)
		_set_hour(7.0)
	elif morning_mode:
		WorldWeather.set_fog_force(-1)
		_set_hour(7.0)
	else:
		WorldWeather.set_fog_force(-1)
		_set_hour(22.0)
	var lodge: Building = _find_building("lodge_ordinary")
	if lodge != null:
		camera.position = world.cell_center(Vector2i(20, 20))
		for job in [
			[Vector2i(5, 8), Vector2i(0, 0)],
			[Vector2i(10, 12), Vector2i(0, 0)],
			[Vector2i(16, 7), Vector2i(0, 0)],
			[Vector2i(23, 8), Vector2i(1, 0)],
			[Vector2i(28, 12), Vector2i(1, 0)],
			[Vector2i(34, 8), Vector2i(1, 0)],
			[Vector2i(8, 35), Vector2i(0, 1)],
			[Vector2i(13, 38), Vector2i(0, 1)],
			[Vector2i(17, 34), Vector2i(0, 1)],
			[Vector2i(24, 34), Vector2i(1, 1)],
			[Vector2i(29, 38), Vector2i(1, 1)],
			[Vector2i(34, 34), Vector2i(1, 1)],
		]:
			_place_lamp(job[0], job[1])
	_spawn_stress_customers()


func _spawn_stress_customers() -> void:
	var types: Array = DataRegistry.customer_types
	for index in range(mini(16, types.size())):
		var customer := Customer.new()
		world.customers_root.add_child(customer)
		customer.setup(
			types[index],
			world,
			world.random_entrance())


func _process(delta: float) -> void:
	frame += 1
	if frame < WARMUP_FRAMES:
		return
	if not started:
		started = true
		start_usec = Time.get_ticks_usec()
		camera.position = world.cell_center(Vector2i(20, 20))
		return
	var t := float(frame - WARMUP_FRAMES) / float(SAMPLE_FRAMES)
	camera.position = world.cell_center(Vector2i(20, 20)) + Vector2(
		sin(t * TAU * 2.0) * 160.0,
		cos(t * TAU * 1.5) * 120.0)
	samples.append(delta)
	if samples.size() >= SAMPLE_FRAMES:
		_finish()


func _find_building(id: String) -> Building:
	for building in world.buildings:
		if building.id == id:
			return building
	return null


func _place_lamp(preferred: Vector2i, required_zone: Vector2i) -> void:
	for radius in range(0, 21):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var cell := preferred + Vector2i(dx, dy)
				var zone := Vector2i(
					floori(float(cell.x) / 20.0),
					floori(float(cell.y) / 20.0))
				if zone != required_zone:
					continue
				if not world.can_place(cell, Vector2i(1, 1)):
					continue
				if world.ground_type(cell) == World.GROUND_PATH:
					continue
				if world.place_building("street_lamp", cell) != null:
					return


func _set_hour(hour: float) -> void:
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf(
		(target - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())


func _finish() -> void:
	var elapsed := float(Time.get_ticks_usec() - start_usec) / 1_000_000.0
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += value
	var average := total / maxf(float(sorted.size()), 1.0)
	var p95: float = sorted[mini(
		int(float(sorted.size()) * 0.95),
		sorted.size() - 1)]
	var p99: float = sorted[mini(
		int(float(sorted.size()) * 0.99),
		sorted.size() - 1)]
	var fps := float(sorted.size()) / maxf(elapsed, 0.001)
	print("[lighting-v2-perf] %s ｜ 1920x1080 ｜ 帧 %d ｜ 平均 %.2f ms ｜ P95 %.2f ms ｜ P99 %.2f ms ｜ 平均 %.1f FPS" % [
		"%s%s" % [
			"全天降雨" if rain_mode else ("晴朗清晨" if morning_mode else "无雾"),
			" + 噪声深度雾" if fog_mode else "",
		],
		sorted.size(),
		average * 1000.0,
		p95 * 1000.0,
		p99 * 1000.0,
		fps,
	])
	var lamp_state: Dictionary = main.get_node(
		"SpringWorldLighting")._update_lamp_state(GameClock.hour_of_day())
	print("[lighting-v2-perf] 动态角色代理 %d ｜ 建筑 %d ｜ 照明灯 %d ｜ 阴影灯 %d ｜ 页 %d" % [
		world.get_tree().get_nodes_in_group("customers").size()
			+ (1 if world.player_avatar != null else 0),
		world.buildings.size(),
		(lamp_state.get("lights", []) as Array).size(),
		int(lamp_state.get("shadow_count", 0)),
		main.get_node("SpringWorldLighting").rig.active_lamp_page_count,
	])
	get_tree().quit()
