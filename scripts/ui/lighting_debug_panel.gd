extends CanvasLayer
class_name LightingDebugPanel

const SNAPSHOT_PATH := "res://.tmp/lighting_debug_snapshot.json"

var next_lighting: Node
var daylight: CanvasModulate
var panel: PanelContainer
var content: VBoxContainer
var status_label: Label
var slider_controls: Dictionary = {}
var color_buttons: Dictionary = {}
var defaults: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	if not OS.is_debug_build():
		queue_free()
		return
	next_lighting = get_node_or_null("../NextLightingSystem")
	daylight = get_node_or_null("../Daylight") as CanvasModulate
	if next_lighting == null or daylight == null:
		queue_free()
		return
	_capture_defaults()
	_build_panel()
	visible = false
	var arguments := OS.get_cmdline_user_args()
	if "--lighting-debug-ui" in arguments:
		visible = true
	if "--lighting-debug-snapshot" in arguments:
		_print_snapshot.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo \
				and key_event.keycode == KEY_F10:
			visible = not visible
			get_viewport().set_input_as_handled()


func _capture_defaults() -> void:
	var config: Dictionary = next_lighting.config
	var sun: Dictionary = config.get("sun", {})
	var surface: Dictionary = config.get("surface", {})
	var player_surface: Dictionary = config.get("player_surface", {})
	var street_lamp: Dictionary = config.get("street_lamp", {})
	var legacy_sun: Dictionary = daylight.sun_config
	defaults = {
		"exposure_day": float(config.get("scene_exposure_day", 0.60)),
		"exposure_night": float(config.get("scene_exposure_night", 0.60)),
		"lamp_brightness": float(street_lamp.get("brightness", 5.0)),
		"lamp_falloff": float(street_lamp.get("falloff_power", 0.8)),
		"sun_max": float(sun.get("maximum_energy", 0.02)),
		"legacy_max": float(legacy_sun.get("legacy_maximum_energy", 0.31)),
		"normal": float(surface.get("normal_strength", 0.85)),
		"specular": float(surface.get("specular_strength", 0.055)),
		"occlusion": float(surface.get("occlusion_direct_strength", 0.34)),
		"wall_shadow": float(surface.get("wall_shadow_strength", 0.79)),
		"player_normal": float(player_surface.get("normal_strength", 0.88)),
		"player_specular": float(player_surface.get("specular_strength", 0.34)),
		"ambient_day": _ambient_day_color(),
		"ambient_night": _ambient_night_color(),
		"sun_noon": Color.from_string(
			str(sun.get("noon_color", "#f3e0c2")), Color.WHITE),
		"legacy_day": Color.from_string(
			str(legacy_sun.get("legacy_day_color", "#f3e0c2")), Color.WHITE),
	}


func _build_panel() -> void:
	panel = PanelContainer.new()
	panel.name = "LightingDebugPanel"
	panel.position = Vector2(18.0, 112.0)
	panel.custom_minimum_size = Vector2(440.0, 570.0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420.0, 560.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	content = VBoxContainer.new()
	content.custom_minimum_size = Vector2(400.0, 0.0)
	content.add_theme_constant_override("separation", 7)
	scroll.add_child(content)

	var title := Label.new()
	title.text = "实时光照调参（临时）"
	title.add_theme_font_size_override("font_size", 24)
	content.add_child(title)
	var hint := Label.new()
	hint.text = "F10 显示/隐藏。只在调试版生效，重启恢复默认；颜色和夜间值可向下滚动。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 16)
	content.add_child(hint)
	content.add_child(HSeparator.new())

	for definition in _slider_definitions():
		_add_slider(definition)

	content.add_child(HSeparator.new())
	var color_title := Label.new()
	color_title.text = "颜色（点击色块打开色轮）"
	color_title.add_theme_font_size_override("font_size", 19)
	content.add_child(color_title)
	_add_color_control("ambient_day", "白天环境色", defaults["ambient_day"])
	_add_color_control("ambient_night", "夜间环境色", defaults["ambient_night"])
	_add_color_control("sun_noon", "太阳正午色", defaults["sun_noon"])
	_add_color_control("legacy_day", "传统方向光白天色", defaults["legacy_day"])

	content.add_child(HSeparator.new())
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	content.add_child(actions)
	var print_button := Button.new()
	print_button.text = "打印并复制当前数据"
	print_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	print_button.pressed.connect(_print_snapshot)
	actions.add_child(print_button)
	var reset_button := Button.new()
	reset_button.text = "恢复默认"
	reset_button.pressed.connect(_reset_defaults)
	actions.add_child(reset_button)

	status_label = Label.new()
	status_label.text = "拖动参数会立即更新画面。"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 16)
	content.add_child(status_label)


func _slider_definitions() -> Array:
	return [
		{"key": "exposure_day", "label": "白天曝光", "min": 0.10, "max": 1.20, "step": 0.01, "digits": 2},
		{"key": "exposure_night", "label": "夜间曝光", "min": 0.10, "max": 1.20, "step": 0.01, "digits": 2},
		{"key": "lamp_brightness", "label": "路灯光池亮度", "min": 0.00, "max": 12.00, "step": 0.05, "digits": 2},
		{"key": "lamp_falloff", "label": "路灯光池衰减（越大越集中）", "min": 0.20, "max": 3.00, "step": 0.01, "digits": 2},
		{"key": "sun_max", "label": "太阳直射强度", "min": 0.00, "max": 0.60, "step": 0.005, "digits": 3},
		{"key": "legacy_max", "label": "传统方向光强度", "min": 0.00, "max": 1.00, "step": 0.01, "digits": 2},
		{"key": "normal", "label": "建筑/路灯法线", "min": 0.00, "max": 2.00, "step": 0.01, "digits": 2},
		{"key": "specular", "label": "建筑/路灯高光", "min": 0.00, "max": 0.50, "step": 0.005, "digits": 3},
		{"key": "occlusion", "label": "Occlusion 直射强度", "min": 0.00, "max": 1.00, "step": 0.01, "digits": 2},
		{"key": "wall_shadow", "label": "墙面投影强度", "min": 0.00, "max": 1.00, "step": 0.01, "digits": 2},
		{"key": "player_normal", "label": "玩家法线", "min": 0.00, "max": 2.00, "step": 0.01, "digits": 2},
		{"key": "player_specular", "label": "玩家高光", "min": 0.00, "max": 0.80, "step": 0.01, "digits": 2},
	]


func _add_slider(definition: Dictionary) -> void:
	var key := str(definition["key"])
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	content.add_child(row)
	var label_row := HBoxContainer.new()
	row.add_child(label_row)
	var label := Label.new()
	label.text = str(definition["label"])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 17)
	label_row.add_child(label)
	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(70.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label_row.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = float(definition["min"])
	slider.max_value = float(definition["max"])
	slider.step = float(definition["step"])
	slider.value = _numeric_value(key)
	row.add_child(slider)
	value_label.text = _format_value(slider.value, int(definition["digits"]))
	slider.value_changed.connect(
		_on_slider_changed.bind(key, value_label, int(definition["digits"])))
	slider_controls[key] = {
		"slider": slider,
		"value_label": value_label,
		"digits": int(definition["digits"]),
	}


func _add_color_control(key: String, label_text: String, color: Color) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	content.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 17)
	row.add_child(label)
	var button := ColorPickerButton.new()
	button.custom_minimum_size = Vector2(120.0, 32.0)
	button.color = color
	button.text = "#" + color.to_html(false)
	row.add_child(button)
	var picker := button.get_picker()
	picker.edit_alpha = false
	picker.picker_shape = ColorPicker.SHAPE_HSV_WHEEL
	picker.custom_minimum_size = Vector2(360.0, 320.0)
	button.color_changed.connect(_on_color_changed.bind(key, button))
	color_buttons[key] = button


func _numeric_value(key: String) -> float:
	var config: Dictionary = next_lighting.config
	var sun: Dictionary = config.get("sun", {})
	var surface: Dictionary = config.get("surface", {})
	var player_surface: Dictionary = config.get("player_surface", {})
	var street_lamp: Dictionary = config.get("street_lamp", {})
	match key:
		"exposure_day":
			return float(config.get("scene_exposure_day", 0.60))
		"exposure_night":
			return float(config.get("scene_exposure_night", 0.60))
		"lamp_brightness":
			return float(street_lamp.get("brightness", 5.0))
		"lamp_falloff":
			return float(street_lamp.get("falloff_power", 0.8))
		"sun_max":
			return float(sun.get("maximum_energy", 0.02))
		"legacy_max":
			return float(daylight.sun_config.get("legacy_maximum_energy", 0.31))
		"normal":
			return float(surface.get("normal_strength", 0.85))
		"specular":
			return float(surface.get("specular_strength", 0.055))
		"occlusion":
			return float(surface.get("occlusion_direct_strength", 0.34))
		"wall_shadow":
			return float(surface.get("wall_shadow_strength", 0.79))
		"player_normal":
			return float(player_surface.get("normal_strength", 0.88))
		"player_specular":
			return float(player_surface.get("specular_strength", 0.34))
	return 0.0


func _write_numeric(key: String, value: float) -> void:
	var config: Dictionary = next_lighting.config
	var sun: Dictionary = config.get("sun", {})
	var surface: Dictionary = config.get("surface", {})
	var player_surface: Dictionary = config.get("player_surface", {})
	var street_lamp: Dictionary = config.get("street_lamp", {})
	match key:
		"exposure_day":
			config["scene_exposure_day"] = value
		"exposure_night":
			config["scene_exposure_night"] = value
		"lamp_brightness":
			street_lamp["brightness"] = value
		"lamp_falloff":
			street_lamp["falloff_power"] = value
		"sun_max":
			sun["maximum_energy"] = value
		"legacy_max":
			daylight.sun_config["legacy_maximum_energy"] = value
			sun["legacy_maximum_energy"] = value
		"normal":
			surface["normal_strength"] = value
		"specular":
			surface["specular_strength"] = value
		"occlusion":
			surface["occlusion_direct_strength"] = value
		"wall_shadow":
			surface["wall_shadow_strength"] = value
		"player_normal":
			player_surface["normal_strength"] = value
		"player_specular":
			player_surface["specular_strength"] = value
	config["sun"] = sun
	config["surface"] = surface
	config["player_surface"] = player_surface
	config["street_lamp"] = street_lamp
	next_lighting.surface_config = surface
	next_lighting.player_surface_config = player_surface
	next_lighting.street_lamp_config = street_lamp


func _on_slider_changed(
		value: float, key: String, value_label: Label, digits: int) -> void:
	value_label.text = _format_value(value, digits)
	_write_numeric(key, value)
	_apply_changes()


func _on_color_changed(color: Color, key: String, button: ColorPickerButton) -> void:
	button.text = "#" + color.to_html(false)
	_write_color(key, color)
	_apply_changes()


func _write_color(key: String, color: Color) -> void:
	var config: Dictionary = next_lighting.config
	var sun: Dictionary = config.get("sun", {})
	match key:
		"ambient_day":
			for frame in DataRegistry.lighting_keyframes:
				var hour := float(frame.get("hour", -1.0))
				if is_equal_approx(hour, 10.0) or is_equal_approx(hour, 16.0):
					frame["color"] = color
		"ambient_night":
			for frame in DataRegistry.lighting_keyframes:
				var hour := float(frame.get("hour", -1.0))
				if is_equal_approx(hour, 0.0) \
						or is_equal_approx(hour, 7.0) \
						or is_equal_approx(hour, 19.0) \
						or is_equal_approx(hour, 24.0):
					frame["color"] = color
		"sun_noon":
			sun["noon_color"] = "#" + color.to_html(false)
		"legacy_day":
			daylight.sun_config["legacy_day_color"] = "#" + color.to_html(false)
			sun["legacy_day_color"] = "#" + color.to_html(false)
	config["sun"] = sun


func _apply_changes() -> void:
	daylight._apply(GameClock.progress)
	var hour := GameClock.hour_of_day()
	for building in next_lighting.world.buildings:
		if next_lighting.building_entries.has(building):
			next_lighting._update_building(
				building, next_lighting.building_entries[building], 0.0)
	next_lighting._update_player_local_light(hour)
	next_lighting._update_exposure_overlay()
	next_lighting.apply_street_lamp_config()


func _print_snapshot() -> void:
	var data := _current_snapshot()
	var text := JSON.stringify(data, "\t")
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	var file := FileAccess.open(SNAPSHOT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	DisplayServer.clipboard_set(text)
	print("[LightingDebug] 当前光照数据：")
	print(text)
	status_label.text = "已打印并复制，同时写入 .tmp/lighting_debug_snapshot.json"


func _current_snapshot() -> Dictionary:
	var config: Dictionary = next_lighting.config
	var sun: Dictionary = config.get("sun", {})
	var surface: Dictionary = config.get("surface", {})
	var player_surface: Dictionary = config.get("player_surface", {})
	var street_lamp: Dictionary = config.get("street_lamp", {})
	return {
		"ambient_day": "#" + _ambient_day_color().to_html(false),
		"ambient_night": "#" + _ambient_night_color().to_html(false),
		"scene_exposure_day": float(config.get("scene_exposure_day", 0.60)),
		"scene_exposure_night": float(config.get("scene_exposure_night", 0.60)),
		"street_lamp": street_lamp.duplicate(true),
		"sun": {
			"maximum_energy": float(sun.get("maximum_energy", 0.02)),
			"minimum_color": str(sun.get("minimum_color", "#f2b06c")),
			"noon_color": str(sun.get("noon_color", "#f3e0c2")),
			"legacy_maximum_energy": float(
				daylight.sun_config.get("legacy_maximum_energy", 0.31)),
			"legacy_dawn_color": str(
				daylight.sun_config.get("legacy_dawn_color", "#ff9e47")),
			"legacy_day_color": str(
				daylight.sun_config.get("legacy_day_color", "#f3e0c2")),
		},
		"surface": surface.duplicate(true),
		"player_surface": player_surface.duplicate(true),
	}


func _reset_defaults() -> void:
	for key in [
		"exposure_day", "exposure_night", "lamp_brightness", "lamp_falloff",
		"sun_max", "legacy_max",
		"normal", "specular",
		"occlusion", "wall_shadow", "player_normal", "player_specular"]:
		_write_numeric(str(key), float(defaults[key]))
	_write_color("ambient_day", defaults["ambient_day"])
	_write_color("ambient_night", defaults["ambient_night"])
	_write_color("sun_noon", defaults["sun_noon"])
	_write_color("legacy_day", defaults["legacy_day"])
	_sync_controls()
	_apply_changes()
	status_label.text = "已恢复本次运行开始时的默认值。"


func _sync_controls() -> void:
	for key in slider_controls.keys():
		var control: Dictionary = slider_controls[key]
		var slider: HSlider = control["slider"]
		var value_label: Label = control["value_label"]
		slider.set_value_no_signal(_numeric_value(str(key)))
		value_label.text = _format_value(
			slider.value, int(control["digits"]))
	for key in color_buttons.keys():
		var button: ColorPickerButton = color_buttons[key]
		button.set_block_signals(true)
		match str(key):
			"ambient_day":
				button.color = _ambient_day_color()
			"ambient_night":
				button.color = _ambient_night_color()
			"sun_noon":
				button.color = Color.from_string(
					str(next_lighting.config.get("sun", {}).get(
						"noon_color", "#f3e0c2")), Color.WHITE)
			"legacy_day":
				button.color = Color.from_string(
					str(daylight.sun_config.get("legacy_day_color", "#f3e0c2")),
					Color.WHITE)
		button.text = "#" + button.color.to_html(false)
		button.set_block_signals(false)


func _ambient_day_color() -> Color:
	for frame in DataRegistry.lighting_keyframes:
		if is_equal_approx(float(frame.get("hour", -1.0)), 10.0):
			return frame.get("color", Color.WHITE)
	return Color.WHITE


func _ambient_night_color() -> Color:
	for frame in DataRegistry.lighting_keyframes:
		if is_equal_approx(float(frame.get("hour", -1.0)), 19.0):
			return frame.get("color", Color.WHITE)
	return Color.WHITE


func _format_value(value: float, digits: int) -> String:
	return ("%." + str(digits) + "f") % value
