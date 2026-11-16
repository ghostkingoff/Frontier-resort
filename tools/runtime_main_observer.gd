extends Node
## Captures the root window after entering the game through title.tscn.

const OUT_DIR := "res://.tmp/runtime_main"
const WAIT_FRAMES := 16
const BUILD_MARKER := "LIGHTING BUILD 2026-11-13-RGB-FOG-SUN-V3"
const CONFIG_PATH := "res://data/lighting_v2/spring_clear.json"
const ATMOSPHERE_SHADER_PATH := "res://shaders/lighting_v2/spring_atmosphere.gdshader"
const SUNRISE_HOUR := 6.0 + 25.0 / 60.0
const SUNSET_HOUR := 19.0 + 25.0 / 60.0

var world: Node2D
var camera: Camera2D
var spring: Node
var output_dir := ""
var frame := 0
var schedule_index := 0
var wait_left := 0
var hold_mode := false
var hold_hour := 12.0
var hold_fog := false
var focus_kind := ""
var capture_marker: Label
var schedule := [
	{"name": "title_flow_0625_sunrise.png", "hour": SUNRISE_HOUR, "fog": false},
	{"name": "title_flow_1200_noon.png", "hour": 12.0, "fog": false},
	{"name": "title_flow_1925_sunset.png", "hour": SUNSET_HOUR, "fog": false},
	{"name": "title_flow_0100_night.png", "hour": 1.0, "fog": false},
	{"name": "title_flow_0820_fog.png", "hour": 8.0 + 20.0 / 60.0, "fog": true},
	{
		"name": "title_flow_f10.png",
		"hour": 7.0,
		"fog": true,
		"panel": true,
	},
]


func _ready() -> void:
	_parse_capture_args()
	output_dir = "%s/run_%d_%d" % [
		OUT_DIR,
		int(Time.get_unix_time_from_system() * 1000.0),
		OS.get_process_id(),
	]
	DirAccess.make_dir_recursive_absolute(output_dir)
	SaveManager.read_only = true
	print("[runtime-main] 输出目录：%s" % output_dir)
	print("[runtime-main] %s" % BUILD_MARKER)
	print("[runtime-main] PID：%d" % OS.get_process_id())
	print("[runtime-main] spring_clear.json MD5：%s" % FileAccess.get_md5(CONFIG_PATH))
	print("[runtime-main] spring_atmosphere.gdshader MD5：%s" %
		FileAccess.get_md5(ATMOSPHERE_SHADER_PATH))
	if hold_mode:
		schedule = [{
			"name": "os_hold_%s.png" % _hour_file_token(hold_hour),
			"hour": hold_hour,
			"fog": hold_fog,
			"panel": "--dev-events-panel" in OS.get_cmdline_user_args(),
		}]
		_create_capture_marker()
		print("[runtime-main] Windows 系统截图停留模式：%s" %
			_hour_display(hold_hour))


func _process(_delta: float) -> void:
	frame += 1
	if frame == 8:
		_prepare()
		_apply_schedule()
		return
	if wait_left > 0:
		wait_left -= 1
		if wait_left == 0:
			_capture(str(schedule[schedule_index]["name"]))
			schedule_index += 1
			if schedule_index >= schedule.size():
				if hold_mode:
					print("[runtime-main] 已停在目标时刻，等待 Windows 窗口截图")
				else:
					print("[runtime-main] 结果：通过")
					get_tree().quit()
			else:
				_apply_schedule()


func _prepare() -> void:
	world = get_tree().get_first_node_in_group("world")
	camera = get_viewport().get_camera_2d()
	spring = get_parent().get_node_or_null("SpringWorldLighting")
	camera.set_process(false)
	camera.zoom = Vector2(2.35, 2.35)
	if focus_kind == "street_lamp":
		var lamp: Building = null
		for building in world.buildings:
			if building.id == "street_lamp":
				lamp = building
				break
		camera.zoom = Vector2(2.6, 2.6)
		camera.position = lamp.global_position + Vector2(16.0, 12.0) \
			if lamp != null else world.cell_center(Vector2i(58, 39))
		return
	var lodge: Building = null
	for building in world.buildings:
		if building.id == "lodge_ordinary":
			lodge = building
			break
	camera.position = lodge.global_position + Vector2(96.0, 58.0) \
		if lodge != null else world.cell_center(Vector2i(58, 39))


func _apply_schedule() -> void:
	var entry: Dictionary = schedule[schedule_index]
	WorldWeather.set_fog_force(1 if bool(entry["fog"]) else -1)
	var hour := float(entry["hour"])
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf(
		(target - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.paused = true
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())
	var panel := get_parent().get_node_or_null(
		"LightingV2DebugPanel") as LightingV2DebugPanel
	if panel != null:
		panel.set_panel_visible(bool(entry.get("panel", false)))
	wait_left = WAIT_FRAMES


func _capture(file_name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s" % [output_dir, file_name]
	var error := image.save_png(path)
	print("[runtime-main] %s %dx%d -> %s" % [
		file_name,
		image.get_width(),
		image.get_height(),
		error_string(error),
	])
	if hold_mode:
		_write_hold_ready(path)


func _parse_capture_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hold-hour="):
			hold_mode = true
			hold_hour = clampf(
				float(arg.trim_prefix("--hold-hour=")),
				0.0,
				23.999)
		elif arg.begins_with("--hold-fog="):
			hold_fog = arg.trim_prefix("--hold-fog=") == "1"
		elif arg.begins_with("--focus="):
			focus_kind = arg.trim_prefix("--focus=")


func _create_capture_marker() -> void:
	var layer := CanvasLayer.new()
	layer.name = "RuntimeCaptureMarker"
	layer.layer = 200
	add_child(layer)
	capture_marker = Label.new()
	capture_marker.position = Vector2(18.0, 16.0)
	capture_marker.text = "%s\nWINDOW CAPTURE  %s  PID %d" % [
		BUILD_MARKER,
		_hour_display(hold_hour),
		OS.get_process_id(),
	]
	capture_marker.add_theme_font_size_override("font_size", 18)
	capture_marker.add_theme_color_override("font_color", Color(1.0, 0.94, 0.74))
	capture_marker.add_theme_color_override(
		"font_outline_color",
		Color(0.02, 0.02, 0.04, 0.96))
	capture_marker.add_theme_constant_override("outline_size", 5)
	layer.add_child(capture_marker)


func _write_hold_ready(viewport_path: String) -> void:
	var ready_path := "%s/os_hold_ready.json" % output_dir
	var data := {
		"build_marker": BUILD_MARKER,
		"pid": OS.get_process_id(),
		"hour": hold_hour,
		"fog": hold_fog,
		"viewport_capture": viewport_path,
		"config_md5": FileAccess.get_md5(CONFIG_PATH),
		"atmosphere_shader_md5": FileAccess.get_md5(ATMOSPHERE_SHADER_PATH),
	}
	var file := FileAccess.open(ready_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
	print("[runtime-main] OS_HOLD_READY %s" % ready_path)


func _hour_file_token(hour: float) -> String:
	var hour_int := int(floor(hour))
	var minute_int := int(round((hour - float(hour_int)) * 60.0))
	if minute_int >= 60:
		hour_int += 1
		minute_int -= 60
	return "%02d%02d" % [hour_int % 24, minute_int]


func _hour_display(hour: float) -> String:
	var token := _hour_file_token(hour)
	return "%s:%s" % [token.substr(0, 2), token.substr(2, 2)]
