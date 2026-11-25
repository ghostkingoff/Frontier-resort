extends Node
## Captures the root window after entering the game through title.tscn.

const OUT_DIR := "res://.tmp/runtime_main"
const WAIT_FRAMES := 16
const BUILD_MARKER := "LIGHTING BUILD 2026-11-13-RGB-FOG-SUN-V3"
const CONFIG_PATH := "res://data/lighting_v2/spring_clear.json"
const ATMOSPHERE_SHADER_PATH := "res://shaders/lighting_v2/spring_atmosphere.gdshader"
const SEASON_LIGHT_PROFILE_SCRIPT := preload(
	"res://scripts/lighting_v2/season_light_profile.gd")

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
var hold_rain := false
var hold_cloud := ""
var hold_animate := false
var hold_speed := GameClock.Speed.X1
var hold_game_day := -1
var focus_kind := ""
var player_normal_mode := "normal"
var lighting_debug_mode := -1
var player_animation_frame := -1
var player_facing_override := -1
var place_debug_lamp := false
var hide_building_labels := false
var player_shared_atlas_uv := true
var player_cell_override := Vector2i(-1, -1)
var use_sun_screen_override := false
var sun_screen_override := Vector3.ZERO
var capture_marker: Label
var schedule := [
	{"name": "title_flow_sunrise.png", "hour": 7.5, "fog": false},
	{"name": "title_flow_noon.png", "hour": 13.0, "fog": false},
	{"name": "title_flow_rain_noon.png", "hour": 13.0, "fog": false, "rain": true},
	{"name": "title_flow_sunset.png", "hour": 19.0, "fog": false},
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
	var profile = SEASON_LIGHT_PROFILE_SCRIPT.new().current_profile()
	if not profile.is_empty():
		schedule[0]["hour"] = float(profile["sunrise_hour"])
		schedule[1]["hour"] = float(profile["solar_noon_hour"])
		schedule[2]["hour"] = float(profile["sunset_hour"])
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
	if use_sun_screen_override:
		print("[runtime-main] 太阳方向覆盖：%s" % sun_screen_override)
	if hold_mode:
		if hold_animate:
			GameClock.cycle_length_seconds = 1000000000.0
			GameClock.paused = false
		schedule = [{
			"name": "os_hold_%s.png" % _hour_file_token(hold_hour),
			"hour": hold_hour,
			"fog": hold_fog,
			"rain": hold_rain,
			"panel": "--dev-events-panel" in OS.get_cmdline_user_args(),
		}]
		_create_capture_marker()
		print("[runtime-main] Windows 系统截图停留模式：%s" %
			_hour_display(hold_hour))
		print("[runtime-main] 云事件：%s" % (
			hold_cloud if hold_cloud != "" else "关闭"))


func _process(_delta: float) -> void:
	frame += 1
	if frame == 45:
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
	if hide_building_labels and world != null:
		for building in world.get("buildings"):
			if building != null and is_instance_valid(building) \
					and building.label != null:
				building.label.visible = false
		var player_node: Node = world.get("player_avatar")
		if player_node != null and is_instance_valid(player_node) \
				and player_node.label != null:
			player_node.label.visible = false
	camera = get_viewport().get_camera_2d()
	spring = get_parent().get_node_or_null("SpringWorldLighting")
	var spring_lighting := spring as SpringWorldLighting
	if spring_lighting != null:
		spring_lighting.reset_player_surface_map_disables()
		spring_lighting.set_player_shared_atlas_uv(player_shared_atlas_uv)
		match player_normal_mode:
			"off":
				spring_lighting.set_player_surface_map_disabled("normal", true)
			"smooth":
				spring_lighting.set_player_smooth_normal_enabled(true)
			_:
				pass
		if lighting_debug_mode >= 0:
			spring_lighting.set_debug_mode(lighting_debug_mode)
		if use_sun_screen_override:
			spring_lighting.set_sun_screen_override(
				sun_screen_override)
	camera.set_process(false)
	camera.zoom = Vector2(2.35, 2.35)
	if focus_kind in [
			"player",
			"player_below_lamp",
			"player_equal_lamp",
			"player_half_shadow"]:
		var player: Node2D = world.player_avatar as Node2D
		var lamp_for_player: Building = null
		for building in world.buildings:
			if building.id == "street_lamp":
				lamp_for_player = building
				break
		if lamp_for_player == null and place_debug_lamp and player != null:
			lamp_for_player = _place_lamp_near(player.global_position)
		if player != null:
			if bool(player.get("inside_reception")):
				player.leave_reception()
			var target_offset := Vector2(48.0, 48.0)
			if focus_kind == "player_below_lamp":
				target_offset = Vector2(-48.0, -32.0)
			elif focus_kind == "player_equal_lamp":
				target_offset = Vector2(48.0, 0.0)
			elif focus_kind == "player_half_shadow":
				target_offset = Vector2(48.0, 24.0)
			var target := player.global_position
			if player_cell_override.x >= 0 \
					and player_cell_override.y >= 0:
				target = world.cell_center(player_cell_override)
				player.detach_to(target)
			elif lamp_for_player != null:
				target = lamp_for_player.global_position + target_offset
				player.detach_to(target)
			player.set(
				"_facing",
				player_facing_override if player_facing_override >= 0 else 2)
			player.set_process(false)
			camera.zoom = Vector2(2.35, 2.35)
			camera.position = target + Vector2(0.0, -18.0)
		return
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
	if focus_kind in ["shop_small", "wall_shadow"]:
		var shop: Building = null
		for building in world.buildings:
			if building.id == "shop_small":
				shop = building
				break
		if shop != null:
			if focus_kind == "wall_shadow":
				var player := world.get("player_avatar") as Node2D
				if player != null:
					if bool(player.get("inside_reception")):
						player.leave_reception()
					var test_cell := Vector2i(
						shop.cell.x + maxi(
							1,
							floori(shop.footprint.x * 0.75)),
						shop.cell.y + shop.footprint.y)
					if player_cell_override.x >= 0 \
							and player_cell_override.y >= 0:
						test_cell = player_cell_override
					player.detach_to(world.cell_center(test_cell))
					player.set_process(false)
			camera.zoom = Vector2(2.6, 2.6)
			camera.position = shop.global_position + Vector2(
				shop.footprint.x * 16.0,
				shop.footprint.y * 24.0)
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
	WorldWeather.clear_weather_event("fog")
	WorldWeather.clear_weather_event("rain")
	WorldWeather.clear_weather_event("cloud")
	if bool(entry["fog"]):
		_trigger_capture_weather_event("fog", "large", 24.0)
	if bool(entry.get("rain", false)):
		_trigger_capture_weather_event("rain", "large", 24.0)
	if hold_cloud in ["small", "medium", "large"]:
		_trigger_capture_weather_event("cloud", hold_cloud, 24.0)
	var hour := float(entry["hour"])
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf(
		(target - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.paused = not hold_animate
	GameClock.set_speed(hold_speed)
	if hold_game_day > 0:
		GameState.day = hold_game_day
		GameState.day_changed.emit(GameState.day)
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())
	var player := world.get("player_avatar") as Node2D
	if player != null:
		if player_animation_frame >= 0:
			player.set("_walk_clock", float(player_animation_frame) / 8.0)
			var facing := int(player.get("_facing"))
			var direction := Vector2.DOWN
			match facing:
				1:
					direction = Vector2.UP
				2:
					direction = Vector2.LEFT
				3:
					direction = Vector2.RIGHT
			player.call("_animate", direction, 0.0)
		else:
			player.call("_show_idle_frame", false)
	var panel := get_parent().get_node_or_null(
		"LightingV2DebugPanel") as LightingV2DebugPanel
	if panel != null:
		panel.set_panel_visible(bool(entry.get("panel", false)))
	wait_left = 90 if hold_mode and hold_rain else WAIT_FRAMES


func _trigger_capture_weather_event(
		type_id: String,
		size_id: String,
		duration_hours: float) -> void:
	var event := WorldWeather.trigger_weather_event(
		type_id,
		size_id,
		duration_hours)
	if event.is_empty():
		return
	WorldWeather.set_weather_event_remaining_hours(
		type_id,
		maxf(duration_hours - 2.0, 0.25))


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
		_capture_shadow_map()


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
		elif arg.begins_with("--hold-rain="):
			hold_rain = arg.trim_prefix("--hold-rain=") == "1"
		elif arg.begins_with("--hold-cloud="):
			var cloud_size := arg.trim_prefix("--hold-cloud=")
			if cloud_size in ["small", "medium", "large"]:
				hold_cloud = cloud_size
		elif arg == "--rain":
			hold_rain = true
		elif arg == "--hold-animate":
			hold_animate = true
		elif arg.begins_with("--hold-speed="):
			hold_speed = clampi(
				int(arg.trim_prefix("--hold-speed=")),
				GameClock.Speed.X1,
				GameClock.Speed.X64)
		elif arg.begins_with("--game-day="):
			hold_game_day = maxi(
				int(arg.trim_prefix("--game-day=")),
				1)
		elif arg.begins_with("--focus="):
			focus_kind = arg.trim_prefix("--focus=")
		elif arg.begins_with("--player-normal="):
			player_normal_mode = arg.trim_prefix("--player-normal=")
		elif arg.begins_with("--lighting-debug="):
			lighting_debug_mode = int(arg.trim_prefix("--lighting-debug="))
		elif arg.begins_with("--player-frame="):
			player_animation_frame = clampi(
				int(arg.trim_prefix("--player-frame=")),
				0,
				3)
		elif arg.begins_with("--player-facing="):
			player_facing_override = clampi(
				int(arg.trim_prefix("--player-facing=")),
				0,
				3)
		elif arg == "--debug-place-lamp":
			place_debug_lamp = true
		elif arg == "--hide-labels":
			hide_building_labels = true
		elif arg.begins_with("--sun-screen="):
			var sun_parts := arg.trim_prefix("--sun-screen=").split(",")
			if sun_parts.size() == 3:
				sun_screen_override = Vector3(
					float(sun_parts[0]),
					float(sun_parts[1]),
					float(sun_parts[2])).normalized()
				use_sun_screen_override = \
					sun_screen_override.length_squared() > 0.000001
		elif arg.begins_with("--player-shared-atlas-uv="):
			player_shared_atlas_uv = \
				arg.trim_prefix("--player-shared-atlas-uv=") != "0"
		elif arg.begins_with("--player-cell="):
			var parts := arg.trim_prefix("--player-cell=").split(",")
			if parts.size() == 2:
				player_cell_override = Vector2i(
					int(parts[0]),
					int(parts[1]))


func _place_lamp_near(position: Vector2) -> Building:
	var preferred: Vector2i = world.world_to_cell(position) + Vector2i(1, 0)
	var footprint := Vector2i(1, 1)
	for radius in range(0, 8):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var cell: Vector2i = preferred + Vector2i(dx, dy)
				if world.can_place(cell, footprint):
					return world.place_building("street_lamp", cell) as Building
	return null


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
	if hold_cloud != "":
		capture_marker.text += "  CLOUD %s" % hold_cloud.to_upper()
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
		"cloud": hold_cloud,
		"viewport_capture": viewport_path,
		"config_md5": FileAccess.get_md5(CONFIG_PATH),
		"atmosphere_shader_md5": FileAccess.get_md5(ATMOSPHERE_SHADER_PATH),
		"sun_screen_override": (
			[sun_screen_override.x, sun_screen_override.y, sun_screen_override.z]
			if use_sun_screen_override else null),
	}
	var file := FileAccess.open(ready_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
	print("[runtime-main] OS_HOLD_READY %s" % ready_path)


func _capture_shadow_map() -> void:
	var spring_lighting := spring as SpringWorldLighting
	if spring_lighting == null or spring_lighting.rig == null:
		return
	var wall_material: ShaderMaterial = null
	for building in world.buildings:
		if building.id == "shop_small":
			var materials: Array = spring_lighting.building_materials.get(
				building,
				[])
			if not materials.is_empty():
				wall_material = materials[0] as ShaderMaterial
				print("[runtime-main] 墙面太阳投影 enabled=%s building_mask=%s" % [
					str(wall_material.get_shader_parameter(
						"apply_wall_shadow_projection")),
					str(wall_material.get_shader_parameter(
						"building_sun_shadow_texture") != null),
				])
			break
	var player_node := world.get("player_avatar") as Node2D
	if player_node != null and camera != null:
		var canvas_screen := get_viewport().get_canvas_transform() \
			* player_node.global_position
		var shadow_camera := spring_lighting.rig.sun_pass.get(
			"camera") as Camera3D
		print("[runtime-main] 相机对齐 player_world=%s camera_pos=%s screen_center=%s canvas_screen=%s viewport=%s sun_camera=%s sun_size=%.2f" % [
			str(player_node.global_position),
			str(camera.global_position),
			str(camera.get_screen_center_position()),
			str(canvas_screen),
			str(get_viewport().get_visible_rect().size),
			str(shadow_camera.position if shadow_camera != null else Vector3.ZERO),
			shadow_camera.size if shadow_camera != null else 0.0,
		])
	var shadow_texture := spring_lighting.rig.get_sun_texture()
	if shadow_texture != null:
		var image := shadow_texture.get_image()
		if image != null and not image.is_empty():
			var shadow_path := "%s/sun_shadow_map.png" % output_dir
			image.save_png(shadow_path)
			print("[runtime-main] 太阳阴影图 -> %s" % shadow_path)
	var building_shadow_texture := spring_lighting.rig.get_building_sun_texture()
	if building_shadow_texture != null:
		var building_image := building_shadow_texture.get_image()
		if building_image != null and not building_image.is_empty():
			var building_shadow_path := "%s/building_sun_shadow_map.png" % output_dir
			building_image.save_png(building_shadow_path)
			print("[runtime-main] 建筑太阳阴影图 -> %s" % building_shadow_path)
	var player_shadow_texture := spring_lighting.rig.get_player_sun_texture()
	if player_shadow_texture != null:
		var player_shadow_image := player_shadow_texture.get_image()
		if player_shadow_image != null and not player_shadow_image.is_empty():
			var player_shadow_path := "%s/player_sun_shadow_map.png" % output_dir
			player_shadow_image.save_png(player_shadow_path)
			print("[runtime-main] 角色太阳阴影图 -> %s" % player_shadow_path)
	if hold_rain and spring_lighting.rain_reflection_viewport != null:
		var reflection_image: Image = \
			spring_lighting.rain_reflection_viewport.get_texture().get_image()
		if reflection_image != null and not reflection_image.is_empty():
			var reflection_path := "%s/rain_reflection_texture.png" % output_dir
			reflection_image.save_png(reflection_path)
			print("[runtime-main] 雨天倒影图 -> %s" % reflection_path)
	if hold_rain and spring_lighting.rain_ripple_viewport != null:
		var ripple_image: Image = \
			spring_lighting.rain_ripple_viewport.get_texture().get_image()
		if ripple_image != null and not ripple_image.is_empty():
			var ripple_path := "%s/rain_ripple_texture.png" % output_dir
			ripple_image.save_png(ripple_path)
			print("[runtime-main] 雨天水波图 -> %s" % ripple_path)


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
