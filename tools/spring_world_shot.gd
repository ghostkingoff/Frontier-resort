extends Node
## Visual regression captures for the integrated main-world renderer.
## Run:
##   godot --path . res://tools/spring_world_shot.tscn -- --spring-world-shot

const OUT_DIR := "res://.tmp/lighting_v2/main"
const SUNRISE_HOUR := 6.0 + 25.0 / 60.0
const SUNSET_HOUR := 19.0 + 25.0 / 60.0

var render_viewport: SubViewport
var main: Node
var spring: Node
var lodge: Building
var camera: Camera2D
var frame := 0
var schedule_index := 0
var wait_after_change := 0
var schedule := [
	{"hour": SUNRISE_HOUR, "name": "main_sunrise_0625.png", "debug": 0},
	{"hour": 7.0, "name": "main_0700.png", "debug": 0},
	{"hour": 10.0, "name": "main_1000.png", "debug": 0},
	{"hour": 12.0, "name": "main_1200.png", "debug": 0},
	{"hour": 15.0, "name": "main_1500.png", "debug": 0},
	{"hour": 17.5, "name": "main_1730.png", "debug": 0},
	{"hour": 18.5, "name": "main_1830.png", "debug": 0},
	{"hour": SUNSET_HOUR, "name": "main_sunset_1925.png", "debug": 0},
	{"hour": 21.5, "name": "main_2130.png", "debug": 0},
	{"hour": 1.0, "name": "main_night_0100.png", "debug": 0},
	{"hour": 12.0, "name": "main_snow_1200.png", "debug": 0, "snow_event": true, "snow_remaining": 1.5},
	{"hour": 1.0, "name": "main_snow_night_0100.png", "debug": 0, "snow_event": true, "snow_remaining": 1.5},
	{"hour": 6.15, "name": "main_fog_0615_fade_in.png", "debug": 0, "fog_event": true, "fog_remaining": 3.625},
	{"hour": 6.5, "name": "main_fog_0630_full.png", "debug": 0, "fog_event": true, "fog_remaining": 1.5},
	{"hour": 8.5, "name": "main_fog_0830_fade_start.png", "debug": 0, "fog_event": true, "fog_remaining": 1.5},
	{"hour": 8.75, "name": "main_fog_0845_fade_out.png", "debug": 0, "fog_event": true, "fog_remaining": 0.375},
	{"hour": 9.0, "name": "main_fog_0900_end.png", "debug": 0, "fog_event": false},
	{"hour": 7.0, "name": "main_wall_0700_backlit.png", "debug": 0},
	{"hour": 11.5, "name": "main_wall_1130_dark.png", "debug": 0},
	{"hour": 12.5, "name": "main_wall_1230_transition.png", "debug": 0},
	{"hour": 13.5, "name": "main_wall_1330_transition.png", "debug": 0},
	{"hour": 14.0, "name": "main_wall_1400_lit.png", "debug": 0},
	{"hour": 18.5, "name": "main_wall_1830_lit.png", "debug": 0},
	{"hour": 7.0, "name": "main_0700_shadow_debug.png", "debug": 5},
	{"hour": 7.5, "name": "main_pine_0730.png", "debug": 0, "focus": "pine"},
	{"hour": 17.5, "name": "main_pine_1730.png", "debug": 0, "focus": "pine"},
	{"hour": 12.0, "name": "main_region_grid.png", "debug": 11},
	{"hour": 7.0, "name": "main_f10_dev_panel.png", "debug": 0, "fog_event": true, "fog_remaining": 1.5, "panel": true},
]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	render_viewport = SubViewport.new()
	render_viewport.name = "FullHDRenderViewport"
	render_viewport.size = Vector2i(1920, 1080)
	render_viewport.use_hdr_2d = true
	render_viewport.transparent_bg = false
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(render_viewport)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	render_viewport.add_child(main)


func _process(_delta: float) -> void:
	if schedule_index >= schedule.size():
		return
	frame += 1
	if schedule_index == 0 and frame == 8:
		_prepare_camera()
		_set_next_shot()
		return
	if wait_after_change > 0:
		wait_after_change -= 1
		if wait_after_change == 0:
			var entry: Dictionary = schedule[schedule_index]
			_capture(str(entry["name"]))
			schedule_index += 1
			if schedule_index >= schedule.size():
				_finish()
			else:
				_set_next_shot()


func _prepare_camera() -> void:
	for node in main.find_children("*", "CanvasLayer", true, false):
		if node is CanvasLayer and (node as CanvasLayer).layer >= 10:
			(node as CanvasLayer).visible = false
	var world: Node2D = main.get_node("World")
	camera = main.get_node("Camera")
	camera.set_process(false)
	camera.zoom = Vector2(2.35, 2.35)
	for building in world.buildings:
		if building.id == "lodge_ordinary":
			lodge = building
			break
	if lodge != null:
		camera.position = lodge.global_position + Vector2(96.0, 58.0)
	else:
		camera.position = world.cell_center(Vector2i(58, 39))
	spring = main.get_node("SpringWorldLighting")


func _set_next_shot() -> void:
	var entry: Dictionary = schedule[schedule_index]
	_set_hour(float(entry["hour"]))
	if spring != null:
		spring.call("set_debug_mode", int(entry.get("debug", 0)))
	WorldWeather.clear_weather_event("fog")
	if bool(entry.get("fog_event", false)):
		WorldWeather.trigger_weather_event("fog", "large", 4.0)
		WorldWeather.set_weather_event_remaining_hours(
			"fog",
			float(entry.get("fog_remaining", 1.5)))
	WorldWeather.clear_weather_event("snow")
	if bool(entry.get("snow_event", false)):
		WorldWeather.trigger_weather_event("snow", "large", 4.0)
		WorldWeather.set_weather_event_remaining_hours(
			"snow",
			float(entry.get("snow_remaining", 1.5)))
		spring._snow_visual_strength = 1.0
		spring._snow_cover_amount = 1.0
	var dev_panel := main.get_node_or_null(
		"LightingV2DebugPanel") as LightingV2DebugPanel
	if dev_panel != null:
		dev_panel.set_panel_visible(bool(entry.get("panel", false)))
	if str(entry.get("focus", "lodge")) == "pine":
		var pines := get_tree().get_nodes_in_group("lighting_pines")
		if not pines.is_empty():
			camera.position = (pines[0] as Node2D).global_position + Vector2(0.0, -48.0)
	elif lodge != null:
		camera.position = lodge.global_position + Vector2(96.0, 58.0)
	wait_after_change = 24


func _set_hour(hour: float) -> void:
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf(
		(target - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.paused = true
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())


func _capture(file_name: String) -> void:
	var image := render_viewport.get_texture().get_image()
	var path := "%s/%s" % [OUT_DIR, file_name]
	var err := image.save_png(path)
	print("[spring-world-shot] %s -> %s" % [file_name, error_string(err)])
	if spring != null:
		var grid := spring.get_node_or_null("RegionDebugGrid") as Node2D
		print("[spring-world-shot] debug=%d grid_visible=%s" % [
			int(spring.debug_mode),
			str(grid.visible) if grid != null else "null",
		])


func _finish() -> void:
	print("[spring-world-shot] 结果：通过")
	get_tree().quit()
