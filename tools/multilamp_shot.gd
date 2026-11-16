extends Node
## Verifies four regions, twelve shadow slots and four RGB pages.

const OUT_DIR := "res://.tmp/lighting_v2"

var render_viewport: SubViewport
var main: Node
var world: Node2D
var spring: Node
var camera: Camera2D
var lamps: Array[Building] = []
var frame := 0
var stage := 0
var wait_frames := 0


func _ready() -> void:
	SaveManager.read_only = true
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	render_viewport = SubViewport.new()
	render_viewport.size = Vector2i(1920, 1080)
	render_viewport.use_hdr_2d = true
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(render_viewport)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	render_viewport.add_child(main)


func _process(_delta: float) -> void:
	frame += 1
	if frame < 8:
		return
	if stage == 0:
		_prepare_scene()
		stage = 1
		wait_frames = 32
		return
	if wait_frames > 0:
		wait_frames -= 1
		return
	match stage:
		1:
			_capture("multi_lamp.png")
			spring.call("set_debug_mode", 6)
			stage = 2
			wait_frames = 20
		2:
			_capture("multi_lamp_union_debug.png")
			spring.call("set_debug_mode", 7)
			stage = 3
			wait_frames = 20
		3:
			_capture("multi_lamp_channels_page0.png")
			spring.call("set_debug_mode", 8)
			stage = 4
			wait_frames = 20
		4:
			_capture("multi_lamp_channels_page1.png")
			spring.call("set_debug_mode", 9)
			stage = 5
			wait_frames = 20
		5:
			_capture("multi_lamp_channels_page2.png")
			spring.call("set_debug_mode", 10)
			stage = 6
			wait_frames = 20
		6:
			_capture("multi_lamp_channels_page3.png")
			_finish()


func _prepare_scene() -> void:
	for node in main.find_children("*", "CanvasLayer", true, false):
		if node is CanvasLayer and (node as CanvasLayer).layer >= 10:
			(node as CanvasLayer).visible = false
	world = main.get_node("World")
	spring = main.get_node("SpringWorldLighting")
	camera = main.get_node("Camera")
	camera.set_process(false)
	camera.zoom = Vector2(0.82, 0.82)

	var lodge: Building = null
	for building in world.buildings:
		if building.id == "lodge_ordinary":
			lodge = building
			break
	if lodge == null:
		return
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
	_set_hour(22.0)
	var player: Node2D = world.player_avatar
	if player != null:
		player.detach_to(world.cell_center(Vector2i(20, 20)))
		player._facing = 2
		player._show_idle_frame(false)


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
				var lamp: Building = world.place_building("street_lamp", cell)
				if lamp != null:
					lamps.append(lamp)
					return


func _set_hour(hour: float) -> void:
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf(
		(target - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())


func _capture(file_name: String) -> void:
	var image := render_viewport.get_texture().get_image()
	var err := image.save_png("%s/%s" % [OUT_DIR, file_name])
	print("[multilamp] %s -> %s" % [file_name, error_string(err)])


func _finish() -> void:
	var state: Dictionary = spring._update_lamp_state(22.0)
	var active: Array = state.get("lights", [])
	var shadow_count := int(state.get("shadow_count", 0))
	var region_shadow_counts: Dictionary = {}
	for index in range(shadow_count):
		var zone: Vector2i = active[index]["zone"]
		region_shadow_counts[zone] = int(
			region_shadow_counts.get(zone, 0)) + 1
	var max_shadows_per_region := 0
	for count in region_shadow_counts.values():
		max_shadows_per_region = maxi(max_shadows_per_region, int(count))
	var visible_spots := 0
	for page in spring.rig.lamp_passes:
		for spot in page.get("lamps", []):
			if spot != null and (spot as SpotLight3D).visible:
				visible_spots += 1
	var ground_material := spring.ground_materials[0] as ShaderMaterial
	var illuminated := int(ground_material.get_shader_parameter(
		"local_light_count"))
	var shadowed := int(ground_material.get_shader_parameter(
		"shadowed_light_count"))
	var ok: bool = lamps.size() == 12 and active.size() == 12 \
		and illuminated == 12 and shadowed == 12 and max_shadows_per_region <= 3 \
		and visible_spots == 12 \
		and spring.rig.lamp_passes.size() == 4 \
		and spring.rig.active_lamp_page_count == 4
	print("[multilamp] 放置 %d ｜照明 %d ｜阴影 %d ｜单区最多阴影 %d ｜页 %d ｜可见通道 %d ｜结果：%s" % [
		lamps.size(),
		active.size(),
		shadowed,
		max_shadows_per_region,
		spring.rig.active_lamp_page_count,
		visible_spots,
		"通过" if ok else "失败",
	])
	get_tree().quit(0 if ok else 1)
