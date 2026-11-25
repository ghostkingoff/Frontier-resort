extends CanvasLayer
class_name LightingV2DebugPanel
## F10 development console for high-level probability events and weather.

const SNAPSHOT_PATH := "res://.tmp/lighting_v2_dev_events.json"
const LIGHTING_TUNING_PATH := "res://.tmp/lighting_tuning.json"
const SEASON_LIGHT_PROFILE_SCRIPT := preload(
	"res://scripts/lighting_v2/season_light_profile.gd")
const LIGHTING_PREVIEW_PHASES := [
	{"phase": "blue_hour", "label": "黎明蓝调"},
	{"phase": "sunrise", "label": "日出"},
	{"phase": "morning", "label": "上午"},
	{"phase": "noon", "label": "正午"},
	{"phase": "afternoon", "label": "下午"},
	{"phase": "sunset", "label": "日落"},
	{"phase": "dusk", "label": "暮色蓝调"},
	{"phase": "night", "label": "深夜"},
]

var panel: PanelContainer
var blocker: ColorRect
var content: VBoxContainer
var scroll: ScrollContainer
var status_label: Label
var weather_status_label: Label
var cloud_event_status_label: Label
var day_spin: SpinBox
var cloud_duration_spin: SpinBox
var rain_duration_spin: SpinBox
var fog_duration_spin: SpinBox
var rain_event_status_label: Label
var fog_event_status_label: Label
var cloud_shadow_tuning_controls: Dictionary = {}
var cloud_shadow_tuning_output: TextEdit
var force_controls: Dictionary = {}
var chance_controls: Dictionary = {}
var multiplier_controls: Dictionary = {}
var lighting_tuning_controls: Dictionary = {}
var lighting_tuning_output: TextEdit
var player_surface_toggles: Dictionary = {}
var player_smooth_normal_toggle: CheckButton
var player_shared_atlas_uv_toggle: CheckButton
var spring_lighting: SpringWorldLighting
var season_light_preview
var lighting_preview_buttons: Array[Button] = []
var _previous_text_input_active := false
var _owns_text_lock := false
var _status_elapsed := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	spring_lighting = get_parent().get_node_or_null(
		"SpringWorldLighting") as SpringWorldLighting
	season_light_preview = SEASON_LIGHT_PROFILE_SCRIPT.new()
	_build_panel()
	visible = false
	DevEvents.changed.connect(_on_events_changed)
	WorldWeather.changed.connect(_on_weather_changed)
	_refresh_all()
	if "--dev-events-panel" in OS.get_cmdline_user_args():
		set_panel_visible(true)


func _process(delta: float) -> void:
	if not visible:
		return
	_status_elapsed += delta
	if _status_elapsed >= 0.25:
		_status_elapsed = 0.0
		_refresh_dynamic_labels()


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo \
				and key_event.keycode == KEY_F10:
			set_panel_visible(not visible)
			get_viewport().set_input_as_handled()


func set_panel_visible(value: bool) -> void:
	if value == visible:
		return
	visible = value
	if value:
		_previous_text_input_active = GameState.text_input_active
		GameState.text_input_active = true
		_owns_text_lock = not _previous_text_input_active
		_refresh_all()
	else:
		if _owns_text_lock:
			GameState.text_input_active = _previous_text_input_active
		_owns_text_lock = false


func _build_panel() -> void:
	blocker = ColorRect.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.color = Color(0.0, 0.0, 0.0, 0.0)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)

	panel = PanelContainer.new()
	panel.name = "DevEventPanel"
	panel.anchor_bottom = 1.0
	panel.offset_left = 24.0
	panel.offset_top = 24.0
	panel.offset_right = 728.0
	panel.offset_bottom = -24.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.055, 0.075, 0.09, 0.96)
	background.border_color = Color(0.36, 0.65, 0.68, 0.88)
	background.set_border_width_all(2)
	background.set_corner_radius_all(8)
	background.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	background.shadow_size = 14
	panel.add_theme_stylebox_override("panel", background)
	add_child(panel)

	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	panel.add_child(scroll)

	content = VBoxContainer.new()
	content.custom_minimum_size = Vector2(664.0, 0.0)
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	var title_row := HBoxContainer.new()
	content.add_child(title_row)
	var title := Label.new()
	title.text = "开发事件控制台"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 26)
	title_row.add_child(title)
	var close_hint := Label.new()
	close_hint.text = "F10 关闭"
	close_hint.modulate = Color(0.72, 0.82, 0.82, 0.9)
	close_hint.add_theme_font_size_override("font_size", 16)
	title_row.add_child(close_hint)

	var intro := Label.new()
	intro.text = "所有“接管”只修改本次运行，不写入存档。自动模式仍使用项目中的动态公式。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.modulate = Color(0.76, 0.82, 0.82, 1.0)
	intro.add_theme_font_size_override("font_size", 16)
	content.add_child(intro)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 16)
	content.add_child(status_label)
	content.add_child(HSeparator.new())

	_add_day_section()
	content.add_child(HSeparator.new())
	_add_weather_section()
	content.add_child(HSeparator.new())
	_add_cloud_section()
	content.add_child(HSeparator.new())
	_add_lighting_tuning_section()
	content.add_child(HSeparator.new())
	_add_chance_section()
	content.add_child(HSeparator.new())
	_add_multiplier_section()
	content.add_child(HSeparator.new())
	_add_action_buttons()


func _add_day_section() -> void:
	_add_section_title("日期跳转")
	var hint := Label.new()
	hint.text = "临时切换到任意绝对天数，用于检查四季光照和天气组合。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.78, 0.86, 0.84, 1.0)
	hint.add_theme_font_size_override("font_size", 15)
	content.add_child(hint)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	content.add_child(row)
	var previous_button := Button.new()
	previous_button.text = "前一天"
	previous_button.pressed.connect(_on_day_step.bind(-1))
	row.add_child(previous_button)
	day_spin = SpinBox.new()
	day_spin.min_value = 1.0
	day_spin.max_value = 999999.0
	day_spin.step = 1.0
	day_spin.allow_greater = false
	day_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	day_spin.value = GameState.day
	row.add_child(day_spin)
	var next_button := Button.new()
	next_button.text = "后一天"
	next_button.pressed.connect(_on_day_step.bind(1))
	row.add_child(next_button)
	var apply_button := Button.new()
	apply_button.text = "应用日期"
	apply_button.pressed.connect(_on_apply_day)
	row.add_child(apply_button)


func _add_weather_section() -> void:
	_add_section_title("天气与能见度")
	var rollback_hint := Label.new()
	rollback_hint.text = "雨、雾、云为独立事件，可在 06:00–次日 06:00 的任意时段开始；三者可同时存在，并各自淡入淡出。"
	rollback_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rollback_hint.modulate = Color(0.95, 0.78, 0.55, 1.0)
	rollback_hint.add_theme_font_size_override("font_size", 15)
	content.add_child(rollback_hint)
	weather_status_label = Label.new()
	weather_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	weather_status_label.add_theme_font_size_override("font_size", 17)
	content.add_child(weather_status_label)
	_add_force_control("today_rain", "今日自动雨事件")
	_add_force_control("yesterday_rain", "昨日降雨（独立记录）")
	_add_force_control("fog", "今日自动雾事件")
	var rain_controls := _add_weather_event_controls("rain", "雨事件", 2.0)
	rain_event_status_label = rain_controls["status_label"] as Label
	rain_duration_spin = rain_controls["duration_spin"] as SpinBox
	var fog_controls := _add_weather_event_controls("fog", "雾事件", 3.0)
	fog_event_status_label = fog_controls["status_label"] as Label
	fog_duration_spin = fog_controls["duration_spin"] as SpinBox
	var lighting_label := Label.new()
	lighting_label.text = "太阳与夜间预览（点击后停在目标时刻）"
	lighting_label.modulate = Color(0.78, 0.86, 0.84, 1.0)
	lighting_label.add_theme_font_size_override("font_size", 15)
	content.add_child(lighting_label)
	var lighting_row := HBoxContainer.new()
	lighting_row.add_theme_constant_override("separation", 5)
	content.add_child(lighting_row)
	for preview in LIGHTING_PREVIEW_PHASES:
		var button := Button.new()
		button.text = "%s\n--:--" % str(preview["label"])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(
			_on_lighting_preview_phase.bind(str(preview["phase"])))
		lighting_row.add_child(button)
		lighting_preview_buttons.append(button)


func _add_weather_event_controls(
		type_id: String,
		title_text: String,
		default_duration: float) -> Dictionary:
	var title := Label.new()
	title.text = "%s（独立）" % title_text
	title.modulate = Color(0.62, 0.88, 0.86, 1.0)
	title.add_theme_font_size_override("font_size", 18)
	content.add_child(title)
	var status_label := Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 16)
	content.add_child(status_label)
	var duration_row := HBoxContainer.new()
	duration_row.add_theme_constant_override("separation", 8)
	content.add_child(duration_row)
	var duration_label := Label.new()
	duration_label.text = "持续时间（游戏小时）"
	duration_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	duration_label.add_theme_font_size_override("font_size", 16)
	duration_row.add_child(duration_label)
	var duration_spin := SpinBox.new()
	duration_spin.min_value = 0.25
	duration_spin.max_value = 48.0
	duration_spin.step = 0.25
	duration_spin.value = default_duration
	duration_spin.custom_minimum_size = Vector2(128.0, 0.0)
	duration_row.add_child(duration_spin)
	var event_row := HBoxContainer.new()
	event_row.add_theme_constant_override("separation", 6)
	content.add_child(event_row)
	for definition in [
		["小", "small"],
		["中", "medium"],
		["大", "large"],
	]:
		var button := Button.new()
		button.text = str(definition[0])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(
			_on_trigger_weather_event.bind(
				type_id,
				str(definition[1]),
				duration_spin))
		event_row.add_child(button)
	var clear_button := Button.new()
	clear_button.text = "清除"
	clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_button.pressed.connect(
		_on_clear_weather_event.bind(type_id))
	event_row.add_child(clear_button)
	return {
		"status_label": status_label,
		"duration_spin": duration_spin,
	}


func _add_cloud_section() -> void:
	_add_section_title("云事件与云影 / 云隙光")
	var hint := Label.new()
	hint.text = (
		"小云、中云、大云共用世界坐标云影；"
		+ "大云另有跟随太阳方向的加法云隙光层。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.70, 0.84, 0.84, 1.0)
	hint.add_theme_font_size_override("font_size", 15)
	content.add_child(hint)
	cloud_event_status_label = Label.new()
	cloud_event_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cloud_event_status_label.add_theme_font_size_override("font_size", 17)
	content.add_child(cloud_event_status_label)

	var duration_row := HBoxContainer.new()
	duration_row.add_theme_constant_override("separation", 8)
	content.add_child(duration_row)
	var duration_label := Label.new()
	duration_label.text = "事件持续时间（游戏小时）"
	duration_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	duration_label.add_theme_font_size_override("font_size", 16)
	duration_row.add_child(duration_label)
	cloud_duration_spin = SpinBox.new()
	cloud_duration_spin.min_value = 0.25
	cloud_duration_spin.max_value = 48.0
	cloud_duration_spin.step = 0.25
	cloud_duration_spin.value = 6.0
	cloud_duration_spin.custom_minimum_size = Vector2(128.0, 0.0)
	duration_row.add_child(cloud_duration_spin)

	var event_row := HBoxContainer.new()
	event_row.add_theme_constant_override("separation", 6)
	content.add_child(event_row)
	for definition in [
		["小云", "small"],
		["中云", "medium"],
		["大云", "large"],
	]:
		var button := Button.new()
		button.text = str(definition[0])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(
			_on_trigger_cloud_event.bind(str(definition[1])))
		event_row.add_child(button)
	var clear_button := Button.new()
	clear_button.text = "清除云事件"
	clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_button.pressed.connect(_on_clear_cloud_event)
	event_row.add_child(clear_button)
	_add_cloud_shadow_tuning_section()


func _add_cloud_shadow_tuning_section() -> void:
	var hint := Label.new()
	hint.text = (
		"每档云影分别调整覆盖率、直射遮光和天空/反弹环境遮光；"
		+ "大云光柱总亮度可独立微调。"
		+ "修改仅作用于本次运行。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.72, 0.84, 0.82, 1.0)
	hint.add_theme_font_size_override("font_size", 15)
	content.add_child(hint)
	if spring_lighting == null:
		var missing := Label.new()
		missing.text = "未找到 SpringWorldLighting，云影调参不可用。"
		missing.modulate = Color(1.0, 0.55, 0.45, 1.0)
		missing.add_theme_font_size_override("font_size", 16)
		content.add_child(missing)
		return
	for tier in [
		["small", "小云"],
		["medium", "中云"],
		["large", "大云"],
	]:
		var tier_title := Label.new()
		tier_title.text = str(tier[1])
		tier_title.modulate = Color(0.62, 0.88, 0.86, 1.0)
		tier_title.add_theme_font_size_override("font_size", 18)
		content.add_child(tier_title)
		for definition in [
			["coverage", "覆盖率"],
			["direct_strength", "直射遮光"],
			["ambient_strength", "环境遮光"],
		]:
			_add_cloud_shadow_tuning_control(
				"%s_%s" % [str(tier[0]), str(definition[0])],
				str(definition[1]))
	var hole_title := Label.new()
	hole_title.text = "大云光斑"
	hole_title.modulate = Color(0.62, 0.88, 0.86, 1.0)
	hole_title.add_theme_font_size_override("font_size", 18)
	content.add_child(hole_title)
	_add_cloud_hole_tuning_control(
		"large_hole_size",
		"光斑大小（相对基准）",
		25.0,
		300.0)
	_add_cloud_hole_tuning_control(
		"large_hole_amount",
		"光斑数量",
		0.0,
		100.0)
	_add_cloud_hole_tuning_control(
		"god_ray_energy",
		"光柱总亮度",
		0.0,
		200.0)
	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 8)
	content.add_child(button_row)
	var print_button := Button.new()
	print_button.text = "打印并复制云影参数"
	print_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	print_button.pressed.connect(_on_print_cloud_shadow_tuning)
	button_row.add_child(print_button)
	var reset_button := Button.new()
	reset_button.text = "恢复云影默认"
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(_on_reset_cloud_shadow_tuning)
	button_row.add_child(reset_button)
	cloud_shadow_tuning_output = TextEdit.new()
	cloud_shadow_tuning_output.editable = false
	cloud_shadow_tuning_output.custom_minimum_size = Vector2(0.0, 140.0)
	cloud_shadow_tuning_output.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	cloud_shadow_tuning_output.add_theme_font_size_override("font_size", 14)
	content.add_child(cloud_shadow_tuning_output)


func _add_cloud_shadow_tuning_control(key: String, label_text: String) -> void:
	var tuning := spring_lighting.get_cloud_shadow_tuning()
	var value := float(tuning.get(key, 0.0))
	var value_label := Label.new()
	value_label.text = "%.1f%%" % (value * 100.0)
	value_label.custom_minimum_size = Vector2(82.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 15)
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	content.add_child(row)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	row.add_child(top)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 16)
	top.add_child(label)
	top.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 0.1
	slider.value = value * 100.0
	slider.value_changed.connect(
		_on_cloud_shadow_tuning_changed.bind(key, value_label))
	row.add_child(slider)
	cloud_shadow_tuning_controls[key] = {
		"slider": slider,
		"value_label": value_label,
	}


func _add_cloud_hole_tuning_control(
		key: String,
		label_text: String,
		minimum: float,
		maximum: float) -> void:
	var tuning := spring_lighting.get_cloud_shadow_tuning()
	var value := float(tuning.get(key, 0.0))
	var value_label := Label.new()
	value_label.text = "%.1f%%" % (value * 100.0)
	value_label.custom_minimum_size = Vector2(82.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 15)
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	content.add_child(row)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	row.add_child(top)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 16)
	top.add_child(label)
	top.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 1.0
	slider.value = value * 100.0
	slider.value_changed.connect(
		_on_cloud_shadow_tuning_changed.bind(key, value_label))
	row.add_child(slider)
	cloud_shadow_tuning_controls[key] = {
		"slider": slider,
		"value_label": value_label,
	}


func _on_cloud_shadow_tuning_changed(
		slider_value: float,
		key: String,
		value_label: Label) -> void:
	if spring_lighting == null:
		return
	var value := slider_value / 100.0
	spring_lighting.set_cloud_shadow_tuning(key, value)
	value_label.text = "%.1f%%" % slider_value


func _refresh_cloud_shadow_tuning_controls() -> void:
	if spring_lighting == null:
		return
	var tuning := spring_lighting.get_cloud_shadow_tuning()
	for key in cloud_shadow_tuning_controls.keys():
		var control: Dictionary = cloud_shadow_tuning_controls[key]
		var slider := control["slider"] as HSlider
		var value_label := control["value_label"] as Label
		var value := float(tuning.get(key, 0.0))
		if slider != null:
			slider.set_block_signals(true)
			slider.set_value_no_signal(value * 100.0)
			slider.set_block_signals(false)
		if value_label != null:
			value_label.text = "%.1f%%" % (value * 100.0)


func _on_print_cloud_shadow_tuning() -> void:
	if spring_lighting == null or cloud_shadow_tuning_output == null:
		return
	var text := JSON.stringify(
		spring_lighting.cloud_shadow_tuning_snapshot(),
		"\t")
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	var file := FileAccess.open(
		"res://.tmp/cloud_shadow_tuning.json",
		FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	DisplayServer.clipboard_set(text)
	cloud_shadow_tuning_output.text = text
	print("[CloudShadowTuning] %s" % text)


func _on_reset_cloud_shadow_tuning() -> void:
	if spring_lighting == null:
		return
	spring_lighting._reset_cloud_shadow_tuning()
	_refresh_cloud_shadow_tuning_controls()
	if cloud_shadow_tuning_output != null:
		cloud_shadow_tuning_output.text = "云影参数已恢复默认。"


func _add_lighting_tuning_section() -> void:
	_add_section_title("实时光照调参（仅本次运行）")
	var hint := Label.new()
	hint.text = (
		"滑杆即时作用于窗头、路灯头、窗口地块光和路灯地块光。"
		+ "窗户地块光使用线性衰减；路灯地块光使用 45° 俯视椭圆。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.72, 0.84, 0.82, 1.0)
	hint.add_theme_font_size_override("font_size", 15)
	content.add_child(hint)
	if spring_lighting == null:
		var missing := Label.new()
		missing.text = "未找到 SpringWorldLighting，光照调参不可用。"
		missing.modulate = Color(1.0, 0.55, 0.45, 1.0)
		missing.add_theme_font_size_override("font_size", 16)
		content.add_child(missing)
		return
	var player_map_label := Label.new()
	player_map_label.text = "角色材质 A/B（可任意组合关闭）"
	player_map_label.modulate = Color(0.82, 0.9, 0.88, 1.0)
	player_map_label.add_theme_font_size_override("font_size", 16)
	content.add_child(player_map_label)
	for definition in [
		{"key": "normal", "label": "关闭法线（改用中性平面）"},
		{"key": "specular", "label": "关闭 Specular（高光）"},
		{"key": "occlusion", "label": "关闭 Occlusion（环境遮蔽）"},
	]:
		var map_kind := str(definition["key"])
		var toggle := CheckButton.new()
		toggle.text = str(definition["label"])
		toggle.add_theme_font_size_override("font_size", 16)
		toggle.button_pressed = spring_lighting.is_player_surface_map_disabled(
			map_kind)
		toggle.toggled.connect(
			_on_player_surface_map_toggled.bind(map_kind))
		content.add_child(toggle)
		player_surface_toggles[map_kind] = toggle
	player_smooth_normal_toggle = CheckButton.new()
	player_smooth_normal_toggle.text = "使用平滑法线（A/B）"
	player_smooth_normal_toggle.add_theme_font_size_override("font_size", 16)
	player_smooth_normal_toggle.button_pressed = \
		spring_lighting.player_smooth_normal_enabled
	player_smooth_normal_toggle.toggled.connect(
		_on_player_smooth_normal_toggled)
	content.add_child(player_smooth_normal_toggle)
	player_shared_atlas_uv_toggle = CheckButton.new()
	player_shared_atlas_uv_toggle.text = "直接使用图集 UV（A/B）"
	player_shared_atlas_uv_toggle.add_theme_font_size_override("font_size", 16)
	player_shared_atlas_uv_toggle.button_pressed = \
		spring_lighting.player_shared_atlas_uv
	player_shared_atlas_uv_toggle.toggled.connect(
		_on_player_shared_atlas_uv_toggled)
	content.add_child(player_shared_atlas_uv_toggle)
	var definitions := [
		{
			"key": "window_head_opacity",
			"label": "窗头透明度",
			"min": 0.0, "max": 1.0, "step": 0.01, "format": "percent",
		},
		{
			"key": "window_head_brightness",
			"label": "窗头亮度",
			"min": 0.0, "max": 2.0, "step": 0.01, "format": "percent",
		},
		{
			"key": "window_ground_energy_ratio",
			"label": "窗地块亮度（相对路灯）",
			"min": 0.0, "max": 1.0, "step": 0.01, "format": "percent",
		},
		{
			"key": "window_ground_range_px",
			"label": "窗地块半径",
			"min": 5.0, "max": 100.0, "step": 0.5, "format": "px",
		},
		{
			"key": "window_ground_attenuation_multiplier",
			"label": "窗地块衰减距离",
			"min": 1.0, "max": 4.0, "step": 0.05, "format": "times",
		},
		{
			"key": "lamp_head_opacity",
			"label": "路灯头透明度",
			"min": 0.0, "max": 1.0, "step": 0.01, "format": "percent",
		},
		{
			"key": "lamp_head_brightness",
			"label": "路灯头亮度",
			"min": 0.0, "max": 2.0, "step": 0.01, "format": "percent",
		},
		{
			"key": "lamp_ground_energy_scale",
			"label": "路灯地块亮度",
			"min": 0.0, "max": 2.0, "step": 0.01, "format": "percent",
		},
		{
			"key": "lamp_ground_range_px",
			"label": "路灯地块半径",
			"min": 16.0, "max": 200.0, "step": 1.0, "format": "px",
		},
		{
			"key": "lamp_ground_attenuation_multiplier",
			"label": "路灯地块衰减距离",
			"min": 1.0, "max": 4.0, "step": 0.05, "format": "times",
		},
		{
			"key": "lamp_ground_falloff_power",
			"label": "路灯地块衰减指数",
			"min": 1.0, "max": 8.0, "step": 0.1, "format": "times",
		},
		{
			"key": "lamp_ground_ellipse_height_ratio",
			"label": "椭圆纵向半径（相对横向）",
			"min": 0.2, "max": 1.0, "step": 0.01, "format": "percent",
		},
	]
	for definition in definitions:
		_add_lighting_tuning_control(definition)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 8)
	content.add_child(button_row)
	var print_button := Button.new()
	print_button.text = "打印并复制当前光照数据"
	print_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	print_button.pressed.connect(_on_print_lighting_tuning)
	button_row.add_child(print_button)
	var reset_button := Button.new()
	reset_button.text = "恢复光照默认"
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(_on_reset_lighting_tuning)
	button_row.add_child(reset_button)

	lighting_tuning_output = TextEdit.new()
	lighting_tuning_output.editable = false
	lighting_tuning_output.custom_minimum_size = Vector2(0.0, 180.0)
	lighting_tuning_output.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	lighting_tuning_output.add_theme_font_size_override("font_size", 14)
	content.add_child(lighting_tuning_output)


func _add_lighting_tuning_control(definition: Dictionary) -> void:
	var key := str(definition["key"])
	var tuning := spring_lighting.get_lighting_tuning()
	var value := float(tuning.get(key, definition["min"]))
	var value_scale := 100.0 if str(definition["format"]) == "percent" else 1.0
	var value_label := Label.new()
	value_label.text = _format_lighting_tuning_value(
		value,
		str(definition["format"]))
	value_label.custom_minimum_size = Vector2(96.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 15)

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	content.add_child(row)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	row.add_child(top)
	var label := Label.new()
	label.text = str(definition["label"])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 16)
	top.add_child(label)
	top.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = float(definition["min"]) * value_scale
	slider.max_value = float(definition["max"]) * value_scale
	slider.step = float(definition["step"]) * value_scale
	slider.value = value * value_scale
	slider.value_changed.connect(
		_on_lighting_tuning_changed.bind(
			key,
			value_label,
			str(definition["format"]),
			value_scale))
	row.add_child(slider)
	lighting_tuning_controls[key] = {
		"definition": definition,
		"slider": slider,
		"value_label": value_label,
		"value_scale": value_scale,
	}


func _format_lighting_tuning_value(value: float, format: String) -> String:
	match format:
		"percent":
			return "%.1f%%" % (value * 100.0)
		"px":
			return "%.1f px" % value
		"times":
			return "%.2f×" % value
		_:
			return "%.2f" % value


func _on_trigger_cloud_event(size_id: String) -> void:
	_on_trigger_weather_event("cloud", size_id, cloud_duration_spin)


func _on_clear_cloud_event() -> void:
	_on_clear_weather_event("cloud")


func _on_trigger_weather_event(
		type_id: String,
		size_id: String,
		duration_spin: SpinBox) -> void:
	var duration := 6.0 if duration_spin == null else duration_spin.value
	WorldWeather.trigger_weather_event(type_id, size_id, duration)
	_refresh_all()


func _on_clear_weather_event(type_id: String) -> void:
	WorldWeather.clear_weather_event(type_id)
	_refresh_all()


func _on_lighting_tuning_changed(
		slider_value: float,
		key: String,
		value_label: Label,
		value_format: String,
		value_scale: float) -> void:
	if spring_lighting == null:
		return
	var value := slider_value / value_scale
	spring_lighting.set_lighting_tuning(key, value)
	value_label.text = _format_lighting_tuning_value(value, value_format)


func _refresh_lighting_tuning_controls() -> void:
	if spring_lighting == null:
		return
	for map_kind in player_surface_toggles.keys():
		var toggle := player_surface_toggles[map_kind] as CheckButton
		if toggle != null:
			toggle.set_block_signals(true)
			toggle.set_pressed_no_signal(
				spring_lighting.is_player_surface_map_disabled(str(map_kind)))
			toggle.set_block_signals(false)
	if player_smooth_normal_toggle != null:
		player_smooth_normal_toggle.set_block_signals(true)
		player_smooth_normal_toggle.set_pressed_no_signal(
			spring_lighting.player_smooth_normal_enabled)
		player_smooth_normal_toggle.set_block_signals(false)
	if player_shared_atlas_uv_toggle != null:
		player_shared_atlas_uv_toggle.set_block_signals(true)
		player_shared_atlas_uv_toggle.set_pressed_no_signal(
			spring_lighting.player_shared_atlas_uv)
		player_shared_atlas_uv_toggle.set_block_signals(false)
	var tuning := spring_lighting.get_lighting_tuning()
	for key in lighting_tuning_controls.keys():
		var control: Dictionary = lighting_tuning_controls[key]
		var slider := control["slider"] as HSlider
		var value_label := control["value_label"] as Label
		var value_scale := float(control["value_scale"])
		var format := str(control["definition"]["format"])
		var value := float(tuning.get(key, 0.0))
		if slider != null:
			slider.set_block_signals(true)
			slider.set_value_no_signal(value * value_scale)
			slider.set_block_signals(false)
		if value_label != null:
			value_label.text = _format_lighting_tuning_value(value, format)


func _on_player_surface_map_toggled(
		disabled: bool,
		map_kind: String) -> void:
	if spring_lighting == null:
		return
	spring_lighting.set_player_surface_map_disabled(map_kind, disabled)
	_refresh_player_surface_status()


func _on_player_smooth_normal_toggled(enabled: bool) -> void:
	if spring_lighting == null:
		return
	spring_lighting.set_player_smooth_normal_enabled(enabled)
	_refresh_player_surface_status()


func _on_player_shared_atlas_uv_toggled(enabled: bool) -> void:
	if spring_lighting == null:
		return
	spring_lighting.set_player_shared_atlas_uv(enabled)
	_refresh_player_surface_status()


func _refresh_player_surface_status() -> void:
	if spring_lighting == null or status_label == null:
		return
	var states := spring_lighting.player_surface_disables_snapshot()
	var disabled_names: Array[String] = []
	if bool(states["normal_disabled"]):
		disabled_names.append("法线")
	if bool(states["specular_disabled"]):
		disabled_names.append("Specular")
	if bool(states["occlusion_disabled"]):
		disabled_names.append("Occlusion")
	if bool(states["smooth_normal_enabled"]):
		disabled_names.append("平滑法线")
	if not bool(states["shared_atlas_uv"]):
		disabled_names.append("旧图集 UV")
	status_label.text = "角色材质 A/B：%s" % (
		"原材质" if disabled_names.is_empty()
		else "启用 " + " / ".join(disabled_names))


func _on_print_lighting_tuning() -> void:
	if spring_lighting == null or lighting_tuning_output == null:
		return
	var text := JSON.stringify(
		spring_lighting.lighting_tuning_snapshot(),
		"\t")
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	var file := FileAccess.open(LIGHTING_TUNING_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	DisplayServer.clipboard_set(text)
	lighting_tuning_output.text = text
	print("[LightingTuning] %s" % text)


func _on_reset_lighting_tuning() -> void:
	if spring_lighting == null:
		return
	spring_lighting._reset_lighting_tuning()
	spring_lighting.reset_player_surface_map_disables()
	_refresh_lighting_tuning_controls()
	if lighting_tuning_output != null:
		lighting_tuning_output.text = "光照参数已恢复默认。"


func _add_force_control(key: String, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	content.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 17)
	row.add_child(label)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(182.0, 34.0)
	option.add_item("自动", 0)
	option.add_item("强制出现 / 下雨", 1)
	option.add_item("强制关闭 / 不下雨", 2)
	option.item_selected.connect(_on_force_selected.bind(key))
	row.add_child(option)
	force_controls[key] = option


func _add_chance_section() -> void:
	_add_section_title("单项概率")
	var hint := Label.new()
	hint.text = "勾选“接管”后，滑杆会覆盖该事件的最终概率；前缀显示的基础值仍会随玩法公式实时更新。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.72, 0.80, 0.80, 1.0)
	hint.add_theme_font_size_override("font_size", 15)
	content.add_child(hint)

	var current_group := ""
	for definition in DevEvents.chance_definitions():
		var group := str(definition.get("group", "其他"))
		if group != current_group:
			current_group = group
			content.add_child(HSeparator.new())
			_add_group_title(group)
		_add_chance_control(definition)


func _add_chance_control(definition: Dictionary) -> void:
	var event_id := str(definition["id"])
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	content.add_child(row)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	row.add_child(top)
	var label := Label.new()
	label.text = str(definition["label"])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 17)
	top.add_child(label)
	var status := Label.new()
	status.custom_minimum_size = Vector2(210.0, 0.0)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.add_theme_font_size_override("font_size", 15)
	top.add_child(status)
	var take_over := CheckButton.new()
	take_over.text = "接管"
	take_over.add_theme_font_size_override("font_size", 15)
	take_over.toggled.connect(_on_chance_takeover_toggled.bind(event_id))
	top.add_child(take_over)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 0.1
	slider.value = float(definition.get("default", 0.0)) * 100.0
	slider.value_changed.connect(
		_on_chance_slider_changed.bind(event_id))
	row.add_child(slider)

	var hint := Label.new()
	var hint_text := str(definition.get("hint", ""))
	hint.text = hint_text
	hint.visible = hint_text != ""
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.66, 0.74, 0.74, 1.0)
	hint.add_theme_font_size_override("font_size", 14)
	row.add_child(hint)
	chance_controls[event_id] = {
		"definition": definition,
		"take_over": take_over,
		"slider": slider,
		"status": status,
	}


func _add_multiplier_section() -> void:
	_add_section_title("整体概率倍率")
	var hint := Label.new()
	hint.text = "1.00 表示项目默认；0.00 完全关闭，2.00 表示双倍概率。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.72, 0.80, 0.80, 1.0)
	hint.add_theme_font_size_override("font_size", 15)
	content.add_child(hint)
	for definition in DevEvents.multiplier_definitions():
		_add_multiplier_control(definition)


func _add_multiplier_control(definition: Dictionary) -> void:
	var event_id := str(definition["id"])
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	content.add_child(row)
	var top := HBoxContainer.new()
	row.add_child(top)
	var label := Label.new()
	label.text = str(definition["label"])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 17)
	top.add_child(label)
	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(72.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 16)
	top.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = float(definition.get("min", 0.0)) * 100.0
	slider.max_value = float(definition.get("max", 2.0)) * 100.0
	slider.step = 1.0
	slider.value = float(definition.get("default", 1.0)) * 100.0
	slider.value_changed.connect(
		_on_multiplier_changed.bind(event_id, value_label))
	row.add_child(slider)
	multiplier_controls[event_id] = {
		"definition": definition,
		"slider": slider,
		"value_label": value_label,
	}
	value_label.text = "%.2f×" % DevEvents.get_multiplier(event_id)


func _add_action_buttons() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	content.add_child(row)
	var refresh_button := Button.new()
	refresh_button.text = "立即重算天气"
	refresh_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_button.pressed.connect(_on_refresh_weather)
	row.add_child(refresh_button)
	var copy_button := Button.new()
	copy_button.text = "复制当前快照"
	copy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_button.pressed.connect(_on_copy_snapshot)
	row.add_child(copy_button)
	var reset_button := Button.new()
	reset_button.text = "全部恢复自动"
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(_on_reset_all)
	row.add_child(reset_button)


func _add_section_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 21)
	content.add_child(label)


func _add_group_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.modulate = Color(0.62, 0.88, 0.86, 1.0)
	label.add_theme_font_size_override("font_size", 18)
	content.add_child(label)


func _on_force_selected(index: int, key: String) -> void:
	var mode := 0
	if index == 1:
		mode = 1
	elif index == 2:
		mode = -1
	match key:
		"today_rain":
			WorldWeather.set_today_rain_force(mode)
		"yesterday_rain":
			WorldWeather.set_yesterday_rain_force(mode)
		"fog":
			WorldWeather.set_fog_force(mode)
	_refresh_all()


func _on_lighting_preview_phase(phase: String) -> void:
	_set_preview_hour(_lighting_preview_hour(phase), false)


func _set_preview_hour(hour: float, auto_play: bool) -> void:
	GameClock.progress = clampf(
		(hour - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.settle_24_done = false
	GameClock.night_managed = false
	GameClock.paused = not auto_play
	WorldWeather.refresh()
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())
	_refresh_all()


func _on_chance_takeover_toggled(enabled: bool, event_id: String) -> void:
	if enabled:
		var control: Dictionary = chance_controls.get(event_id, {})
		var slider := control.get("slider") as HSlider
		DevEvents.set_chance_override(
			event_id,
			slider.value / 100.0 if slider != null else 0.0)
	else:
		DevEvents.clear_chance_override(event_id)
	_refresh_dynamic_labels()


func _on_chance_slider_changed(value: float, event_id: String) -> void:
	var control: Dictionary = chance_controls.get(event_id, {})
	var take_over := control.get("take_over") as CheckButton
	if take_over != null and take_over.button_pressed:
		DevEvents.set_chance_override(event_id, value / 100.0)
		_refresh_dynamic_labels()


func _on_multiplier_changed(
		value: float,
		event_id: String,
		value_label: Label) -> void:
	var multiplier := value / 100.0
	DevEvents.set_multiplier(event_id, multiplier)
	value_label.text = "%.2f×" % multiplier


func _on_events_changed() -> void:
	_refresh_dynamic_labels()


func _on_weather_changed() -> void:
	_refresh_dynamic_labels()


func _on_day_step(delta: int) -> void:
	_apply_game_day(day_spin.value + float(delta))


func _on_apply_day() -> void:
	_apply_game_day(day_spin.value)


func _apply_game_day(value: float) -> void:
	var target := maxi(int(round(value)), 1)
	day_spin.set_value_no_signal(float(target))
	if target == GameState.day:
		_refresh_all()
		return
	GameState.day = target
	GameState.day_changed.emit(target)
	_refresh_all()


func _refresh_all() -> void:
	_refresh_day_control()
	_refresh_force_controls()
	_refresh_multiplier_controls()
	_refresh_cloud_shadow_tuning_controls()
	_refresh_lighting_tuning_controls()
	_refresh_dynamic_labels()


func _refresh_day_control() -> void:
	if day_spin != null and roundi(day_spin.value) != GameState.day:
		day_spin.set_value_no_signal(float(GameState.day))


func _refresh_force_controls() -> void:
	var modes := {
		"today_rain": WorldWeather.get_today_rain_force(),
		"yesterday_rain": WorldWeather.get_yesterday_rain_force(),
		"fog": WorldWeather.get_fog_force(),
	}
	for key in force_controls.keys():
		var option := force_controls[key] as OptionButton
		if option == null:
			continue
		var mode := int(modes.get(key, 0))
		var index := 0
		if mode > 0:
			index = 1
		elif mode < 0:
			index = 2
		option.set_block_signals(true)
		option.select(index)
		option.set_block_signals(false)


func _refresh_multiplier_controls() -> void:
	for event_id in multiplier_controls.keys():
		var control: Dictionary = multiplier_controls[event_id]
		var slider := control["slider"] as HSlider
		var value_label := control["value_label"] as Label
		var multiplier := DevEvents.get_multiplier(str(event_id))
		if slider != null:
			slider.set_block_signals(true)
			slider.set_value_no_signal(multiplier * 100.0)
			slider.set_block_signals(false)
		if value_label != null:
			value_label.text = "%.2f×" % multiplier


func _refresh_dynamic_labels() -> void:
	if status_label == null:
		return
	_refresh_lighting_preview_labels()
	var lighting_text := ""
	var spring := get_parent().get_node_or_null("SpringWorldLighting")
	if spring != null:
		var state: Dictionary = spring._rain_adjusted_light_state(
			spring._sample_light_state(GameClock.hour_of_day()))
		var sun_color: Color = state["sun_color"]
		lighting_text = " ｜ 太阳 #%s · %.0f%% ｜ 天空 %.0f%%" % [
			sun_color.to_html(false),
			float(state["sun_energy"]) * 100.0,
			float(state["sky_energy"]) * 100.0,
		]
	status_label.text = "%s · %s · %s%s" % [
		SeasonCalendar.format_date(GameState.day),
		GameClock.time_text(),
		"暂停" if GameClock.paused else "运行中",
		lighting_text,
	]
	_refresh_weather_status()
	_refresh_cloud_status()
	for event_id in chance_controls.keys():
		var control: Dictionary = chance_controls[event_id]
		var definition: Dictionary = control["definition"]
		var take_over := control["take_over"] as CheckButton
		var slider := control["slider"] as HSlider
		var status := control["status"] as Label
		var overridden := DevEvents.is_chance_overridden(str(event_id))
		var base := DevEvents.get_last_base(str(event_id))
		var effective := DevEvents.get_last_effective(str(event_id))
		if base < 0.0:
			base = float(definition.get("default", 0.0))
		if effective < 0.0:
			effective = base
		if take_over != null:
			take_over.set_block_signals(true)
			take_over.set_pressed_no_signal(overridden)
			take_over.set_block_signals(false)
		if slider != null:
			slider.set_block_signals(true)
			slider.set_value_no_signal(
				(DevEvents.get_chance_override(str(event_id))
					if overridden else effective) * 100.0)
			slider.set_block_signals(false)
		if status != null:
			if overridden:
				status.text = "接管 %.1f%%（基础 %.1f%%）" % [
					effective * 100.0,
					base * 100.0,
				]
			else:
				status.text = "自动 %.1f%%" % [effective * 100.0]


func _refresh_lighting_preview_labels() -> void:
	if lighting_preview_buttons.is_empty():
		return
	for index in range(mini(
			lighting_preview_buttons.size(),
			LIGHTING_PREVIEW_PHASES.size())):
		var button := lighting_preview_buttons[index]
		if button == null:
			continue
		var preview: Dictionary = LIGHTING_PREVIEW_PHASES[index]
		button.text = "%s\n%s" % [
			str(preview["label"]),
			_format_preview_hour(_lighting_preview_hour(
				str(preview["phase"]))),
		]


func _lighting_preview_hour(phase: String) -> float:
	var profile: Dictionary = season_light_preview.current_profile()
	if profile.is_empty():
		match phase:
			"blue_hour":
				return 4.2
			"sunrise":
				return 6.0 + 25.0 / 60.0
			"morning":
				return 10.0
			"noon":
				return 12.0
			"afternoon":
				return 15.0
			"sunset":
				return 19.0 + 25.0 / 60.0
			"dusk":
				return 20.0
			_:
				return 1.0
	var phases: Array = season_light_preview.phase_windows(profile)
	for phase_data in phases:
		if str(phase_data.get("id", "")) != phase:
			continue
		var start := float(phase_data.get("start_hour", 0.0))
		var end := float(phase_data.get("end_hour", start + 1.0))
		if end <= start:
			end += 24.0
		return fposmod(start + (end - start) * 0.5, 24.0)
	match phase:
		"blue_hour":
			return float(profile["sunrise_hour"]) - 1.5
		"sunrise":
			return float(profile["sunrise_hour"])
		"morning":
			return lerpf(
				float(profile["sunrise_hour"]),
				float(profile["solar_noon_hour"]),
				0.45)
		"noon":
			return float(profile["solar_noon_hour"])
		"afternoon":
			return lerpf(
				float(profile["solar_noon_hour"]),
				float(profile["sunset_hour"]),
				0.55)
		"sunset":
			return float(profile["sunset_hour"])
		"dusk":
			return float(profile["sunset_hour"]) + 1.5
		_:
			return 1.0


func _format_preview_hour(hour: float) -> String:
	var normalized := fmod(hour + 24.0, 24.0)
	var total_minutes := int(round(normalized * 60.0)) % (24 * 60)
	return "%02d:%02d" % [
		floori(float(total_minutes) / 60.0),
		total_minutes % 60,
	]


func _refresh_weather_status() -> void:
	if weather_status_label == null:
		return
	weather_status_label.text = (
		"今日自动事件：雨 %s ｜ 雾 %s ｜ 云 %s\n"
		+ "昨日降雨记录：%s ｜ 三种事件可同时在任意时段出现"
	) % [
		"是" if WorldWeather.today_rain else "否",
		"是" if WorldWeather.fog_event else "否",
		"是" if WorldWeather.cloud_event else "否",
		"是" if WorldWeather.yesterday_rain else "否",
	]
	if rain_event_status_label != null:
		rain_event_status_label.text = _weather_event_status_text("rain", "雨")
	if fog_event_status_label != null:
		fog_event_status_label.text = _weather_event_status_text("fog", "雾")


func _refresh_cloud_status() -> void:
	if cloud_event_status_label == null:
		return
	cloud_event_status_label.text = _weather_event_status_text("cloud", "云")


func _weather_event_status_text(type_id: String, label_text: String) -> String:
	var active := WorldWeather.get_active_weather_event(type_id)
	if not active.is_empty():
		var spec: Dictionary = active.get("spec", {})
		var envelope := WorldWeather.weather_event_envelope(type_id)
		return "%s事件：%s · %s ｜ 剩余 %.2f 小时 ｜ 包络 %.0f%%" % [
			label_text,
			str(spec.get("size_name", spec.get("size", ""))),
			str(spec.get("type_name", label_text)),
			float(active.get("remaining_hours", 0.0)),
			envelope * 100.0,
		]
	var scheduled := WorldWeather.get_scheduled_weather_events()
	if scheduled.has(type_id):
		var plan: Dictionary = scheduled[type_id]
		if not bool(plan.get("fired", false)):
			var start_hour := fposmod(
				GameClock.DAY_START_HOUR
					+ float(plan.get("start_progress", 0.0)) * 24.0,
				24.0)
			return "%s事件：无 ｜ 下次计划 %s · %s" % [
				label_text,
				_format_preview_hour(start_hour),
				str(plan.get("size", "small")),
			]
	if not _auto_event_flag(type_id):
		return "%s事件：无 ｜ 今日不自动安排" % label_text
	return "%s事件：无" % label_text


func _auto_event_flag(type_id: String) -> bool:
	match type_id:
		"rain":
			return WorldWeather.today_rain
		"fog":
			return WorldWeather.fog_event
		"cloud":
			return WorldWeather.cloud_event
	return false


func _on_refresh_weather() -> void:
	WorldWeather.refresh()
	_refresh_all()


func _on_reset_all() -> void:
	DevEvents.reset_all()
	WorldWeather.clear_force_overrides()
	WorldWeather.clear_weather_events()
	if spring_lighting != null:
		spring_lighting._reset_cloud_shadow_tuning()
		spring_lighting._reset_lighting_tuning()
		spring_lighting.reset_player_surface_map_disables()
	_refresh_all()


func _on_copy_snapshot() -> void:
	var text := JSON.stringify(DevEvents.snapshot(), "\t")
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	var file := FileAccess.open(SNAPSHOT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	DisplayServer.clipboard_set(text)
	print("[DevEvents] %s" % text)
	status_label.text = "快照已复制，并写入 %s" % SNAPSHOT_PATH
