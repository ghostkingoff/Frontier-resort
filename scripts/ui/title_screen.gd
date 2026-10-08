extends Control
## 标题界面：开场短动画 → 主菜单（新游戏 / 读取存档 / 设置）。
## 存档类似星露谷：每个槽位是一局独立的游戏，进游戏后每天结算自动保存。

const MUSIC_PATH := "res://art/placeholder/audio/bgm_clearing.ogg"

const MAIN_SCENE := "res://scenes/main.tscn"

var bg_layer: Node2D
var curtain: ColorRect
var title_box: VBoxContainer
var menu_box: VBoxContainer
var slot_panel: PanelContainer
var slot_list: VBoxContainer
var settings_panel: PanelContainer
var slot_mode := "new"     # new / load
var confirm_slot := 0      # 覆盖确认用
var intro_done := false
var mode_row: HBoxContainer
var mode_hint: Label


func _ready() -> void:
	# 自动化测试 / 专项体检：直接以存档 1 开新游戏并进入游戏场景，不放开场动画也不放音乐
	if _is_dev_tool():
		GameState.smoke_mode = true
		SaveManager.begin_new_game(1, _mode_from_args())
		_go_to_game()
		return

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UIKit.theme()
	_build_background()
	_build_ui()
	_play_intro()
	Settings.play_music(MUSIC_PATH)


# ---------- 背景小场景 ----------

func _build_background() -> void:
	# 天空（渐变）
	var sky := TextureRect.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0.13, 0.15, 0.28))
	grad.set_color(1, Color(0.42, 0.38, 0.46))
	var sky_tex := GradientTexture2D.new()
	sky_tex.gradient = grad
	sky_tex.fill_from = Vector2(0, 0)
	sky_tex.fill_to = Vector2(0, 1)
	sky.texture = sky_tex
	sky.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(sky)

	# 地面（草地色块 + 深色收边）
	var ground := ColorRect.new()
	ground.color = Color(0.36, 0.46, 0.26)
	ground.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	ground.offset_top = -420
	add_child(ground)
	var ground_dark := ColorRect.new()
	ground_dark.color = Color(0.28, 0.36, 0.20)
	ground_dark.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	ground_dark.offset_top = -120
	add_child(ground_dark)
	# 一条通往度假村的小路
	var road := ColorRect.new()
	road.color = Color(0.72, 0.60, 0.42)
	road.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	road.offset_top = -300
	road.offset_left = 880
	road.offset_right = -880
	add_child(road)

	bg_layer = Node2D.new()
	bg_layer.position = Vector2(960, 760)
	add_child(bg_layer)
	_add_sprite("res://art/placeholder/tiles/house.png", [0, 0, 64, 64], Vector2(-360, -60))
	_add_sprite("res://art/placeholder/tiles/house.png", [320, 0, 64, 64], Vector2(300, -50))
	_add_sprite("res://art/placeholder/tiles/house.png", [192, 0, 64, 64], Vector2(0, -80))
	_add_sprite("res://art/placeholder/tiles/nature.png", [0, 0, 32, 48], Vector2(-620, -120))
	_add_sprite("res://art/placeholder/tiles/nature.png", [32, 0, 32, 48], Vector2(-520, -95))
	_add_sprite("res://art/placeholder/tiles/nature.png", [0, 0, 32, 48], Vector2(560, -110))
	_add_sprite("res://art/placeholder/tiles/nature.png", [32, 0, 32, 48], Vector2(660, -85))
	_add_sprite("res://art/placeholder/tiles/nature.png", [0, 0, 32, 48], Vector2(-200, -95))
	_add_sprite("res://art/placeholder/tiles/nature.png", [192, 48, 64, 48], Vector2(180, -110))

	# 压暗，保证文字清楚
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.04, 0.08, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)


func _add_sprite(atlas_path: String, rect_arr: Array, pos: Vector2) -> void:
	var s := Sprite2D.new()
	s.texture = load(atlas_path)
	s.region_enabled = true
	s.region_rect = Rect2(rect_arr[0], rect_arr[1], rect_arr[2], rect_arr[3])
	s.centered = true
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	s.position = pos
	bg_layer.add_child(s)


# ---------- 界面 ----------

func _build_ui() -> void:
	title_box = VBoxContainer.new()
	title_box.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title_box.offset_top = 150
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	title_box.add_theme_constant_override("separation", 6)
	title_box.modulate.a = 0.0
	add_child(title_box)

	var title := UIKit.label("边境度假村", 96, Color(0.99, 0.90, 0.60))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.10, 0.07, 0.03, 0.95))
	title.add_theme_constant_override("outline_size", 10)
	title_box.add_child(title)
	var subtitle := UIKit.label("白天经营度假村，夜晚深入边境搜集珍贵物资", 28, Color(0.90, 0.92, 0.98))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_box.add_child(subtitle)

	menu_box = VBoxContainer.new()
	menu_box.set_anchors_preset(Control.PRESET_CENTER)
	menu_box.offset_left = -210
	menu_box.offset_right = 210
	menu_box.offset_top = -60
	menu_box.offset_bottom = 220
	menu_box.alignment = BoxContainer.ALIGNMENT_CENTER
	menu_box.add_theme_constant_override("separation", 16)
	menu_box.modulate.a = 0.0
	add_child(menu_box)

	_add_menu_button("新游戏", func(): _open_slot_panel("new"))
	var load_button := _make_menu_button("读取存档", func(): _open_slot_panel("load"))
	load_button.disabled = not SaveManager.any_save()
	if load_button.disabled:
		load_button.tooltip_text = "还没有任何存档"
	menu_box.add_child(load_button)
	_add_menu_button("设置", func(): _open_settings())

	var hint := UIKit.label("点击任意位置可以跳过开场动画 ｜ 每天 24 点结算时自动保存", 20, Color(0.8, 0.83, 0.9, 0.85))
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -56
	hint.offset_bottom = -18
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint)

	_build_slot_panel()
	_build_settings_panel()

	curtain = ColorRect.new()
	curtain.color = Color(0.02, 0.02, 0.04, 1.0)
	curtain.set_anchors_preset(Control.PRESET_FULL_RECT)
	curtain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(curtain)


func _add_menu_button(text: String, action: Callable) -> void:
	menu_box.add_child(_make_menu_button(text, action))


func _make_menu_button(text: String, action: Callable) -> Button:
	var b := UIKit.button(text, Vector2(420, 74))
	b.add_theme_font_size_override("font_size", 30)
	b.pressed.connect(func():
		if not intro_done:
			return      # 开场动画还没结束，忽略误触
		Settings.play_click()
		action.call())
	return b


func _play_intro() -> void:
	# 开场期间菜单保持隐藏，避免「点击跳过」的那一下同时按到菜单按钮
	menu_box.visible = false
	var tween := create_tween()
	tween.tween_property(curtain, "modulate:a", 0.0, 0.9)
	tween.parallel().tween_property(bg_layer, "scale", Vector2.ONE, 2.6).from(Vector2(1.10, 1.10)).set_trans(Tween.TRANS_SINE)
	tween.parallel().tween_property(title_box, "modulate:a", 1.0, 0.7)
	tween.tween_callback(_reveal_menu)


func _reveal_menu() -> void:
	intro_done = true
	menu_box.visible = true
	menu_box.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(menu_box, "modulate:a", 1.0, 0.5)


func _input(event: InputEvent) -> void:
	if intro_done:
		return
	if (event is InputEventKey and event.pressed) or (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed):
		# 吃掉这次输入，不再往下传给菜单按钮
		get_viewport().set_input_as_handled()
		curtain.modulate.a = 0.0
		title_box.modulate.a = 1.0
		bg_layer.scale = Vector2.ONE
		_reveal_menu()


# ---------- 存档槽 ----------

func _build_slot_panel() -> void:
	slot_panel = PanelContainer.new()
	slot_panel.set_anchors_preset(Control.PRESET_CENTER)
	slot_panel.offset_left = -430
	slot_panel.offset_right = 430
	slot_panel.offset_top = -250
	slot_panel.offset_bottom = 250
	slot_panel.add_theme_stylebox_override("panel", UIKit.panel_style(Color(0.09, 0.09, 0.13, 0.98), Color(0.62, 0.54, 0.36)))
	slot_panel.visible = false
	add_child(slot_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	slot_panel.add_child(box)
	var header := UIKit.label("存档", 36, Color(0.98, 0.88, 0.55))
	header.name = "Header"
	box.add_child(header)

	# 开局模式：只在「新游戏」时出现，选完存档位再进游戏
	mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 12)
	mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(mode_row)
	mode_hint = UIKit.paragraph("", 19, Color(0.78, 0.80, 0.88), 800.0)
	box.add_child(mode_hint)

	slot_list = VBoxContainer.new()
	slot_list.add_theme_constant_override("separation", 10)
	box.add_child(slot_list)
	var back := UIKit.button("返回", Vector2(160, 54))
	back.pressed.connect(func():
		Settings.play_click()
		slot_panel.visible = false
		confirm_slot = 0)
	box.add_child(back)


func _open_slot_panel(mode: String) -> void:
	slot_mode = mode
	confirm_slot = 0
	_refresh_slot_list()
	slot_panel.visible = true
	settings_panel.visible = false


func _refresh_slot_list() -> void:
	for child in slot_list.get_children():
		child.queue_free()
	var header: Label = slot_panel.find_child("Header", true, false)
	if header:
		header.text = "新游戏：选择开局模式与存档位" if slot_mode == "new" else "读取存档"
	_refresh_mode_row()
	for slot in range(1, SaveManager.SLOT_COUNT + 1):
		var info := SaveManager.slot_summary(slot)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var text := "存档 %d ｜ 空存档" % slot
		if bool(info.get("exists", false)):
			text = "存档 %d ｜ 第 %d 天 ｜ 资金 %s ｜ 设施 %d 座 ｜ 游玩 %s" % [
				slot, int(info.get("day", 1)), GameState.format_money(int(info.get("money", 0))),
				int(info.get("buildings", 0)), _format_playtime(float(info.get("playtime", 0.0)))]
		var label := UIKit.paragraph(text, 22, Color(0.9, 0.92, 0.98) if bool(info.get("exists", false)) else Color(0.6, 0.62, 0.68), 520.0)
		row.add_child(label)
		if slot_mode == "new":
			var b := UIKit.button("新游戏", Vector2(180, 52))
			if bool(info.get("exists", false)):
				b.text = "确认覆盖？" if confirm_slot == slot else "覆盖并新建"
			b.pressed.connect(func(): _on_new_game_slot(slot))
			row.add_child(b)
		else:
			var load_button := UIKit.button("读取", Vector2(140, 52))
			load_button.disabled = not bool(info.get("exists", false))
			if load_button.disabled:
				load_button.text = "空存档"
			load_button.pressed.connect(func(): _on_load_slot(slot))
			row.add_child(load_button)
			var del := UIKit.button("删除", Vector2(120, 52))
			del.disabled = not bool(info.get("exists", false))
			del.pressed.connect(func():
				Settings.play_click()
				SaveManager.delete_save(slot)
				_refresh_slot_list())
			row.add_child(del)
		slot_list.add_child(row)


func _refresh_mode_row() -> void:
	for child in mode_row.get_children():
		child.queue_free()
	mode_row.visible = slot_mode == "new"
	mode_hint.visible = slot_mode == "new"
	if slot_mode != "new":
		return
	for entry in [
		{"mode": SaveManager.MODE_INITIAL, "text": "初始模式"},
		{"mode": SaveManager.MODE_FULL_TEST, "text": "完全测试"},
	]:
		var picked: bool = SaveManager.new_game_mode == str(entry["mode"])
		var b := UIKit.button(str(entry["text"]), Vector2(220, 52))
		b.toggle_mode = true
		b.button_pressed = picked
		if picked:
			b.text = "▶ %s" % str(entry["text"])
		b.pressed.connect(func():
			Settings.play_click()
			SaveManager.new_game_mode = str(entry["mode"])
			confirm_slot = 0
			_refresh_slot_list())
		mode_row.add_child(b)
	mode_hint.text = _mode_description(SaveManager.new_game_mode)


func _mode_description(mode: String) -> String:
	if mode == SaveManager.MODE_FULL_TEST:
		return "完全测试：知名度 1000，建造菜单里全部 28 栋建筑都已建好并接好路，员工招满，每种物资各 1000 件。用来快速验证各个系统。"
	return "初始模式：知名度 100，正常的开局配置（8 栋常用建筑 + 招待厅），门口小路已接好。正式玩就用这个。"


func _format_playtime(seconds: float) -> String:
	var total := int(seconds)
	var hours := total / 3600
	var minutes := (total % 3600) / 60
	if hours > 0:
		return "%d 小时 %d 分" % [hours, minutes]
	return "%d 分钟" % minutes


func _on_new_game_slot(slot: int) -> void:
	Settings.play_click()
	var info := SaveManager.slot_summary(slot)
	if bool(info.get("exists", false)) and confirm_slot != slot:
		confirm_slot = slot
		_refresh_slot_list()
		return
	SaveManager.begin_new_game(slot, SaveManager.new_game_mode)
	_go_to_game()


func _on_load_slot(slot: int) -> void:
	Settings.play_click()
	SaveManager.begin_load_game(slot)
	_go_to_game()


func _go_to_game() -> void:
	# 必须延迟一帧：_ready() 期间场景树正在把本场景挂到根节点上，
	# 这时直接 change_scene_to_file() 会报
	# 「Parent node is busy adding/removing children, remove_child() can't be called at this time」。
	get_tree().change_scene_to_file.call_deferred(MAIN_SCENE)


func _mode_from_args() -> String:
	# 自动化测试用：-- --smoke --mode=full_test 可以直接用完全测试模式跑回归
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			return arg.split("=")[1]
	return SaveManager.MODE_INITIAL


func _is_dev_tool() -> bool:
	# 开发工具都不走标题界面：冒烟测试 / 截图 / 住客作息专项体检
	var args := OS.get_cmdline_user_args()
	return args.has("--smoke") or args.has("--screenshot") or args.has("--wake")


# ---------- 设置 ----------

func _open_settings() -> void:
	settings_panel.visible = true
	slot_panel.visible = false


func _build_settings_panel() -> void:
	settings_panel = PanelContainer.new()
	settings_panel.set_anchors_preset(Control.PRESET_CENTER)
	settings_panel.offset_left = -360
	settings_panel.offset_right = 360
	settings_panel.offset_top = -240
	settings_panel.offset_bottom = 240
	settings_panel.add_theme_stylebox_override("panel", UIKit.panel_style(Color(0.09, 0.09, 0.13, 0.98), Color(0.62, 0.54, 0.36)))
	settings_panel.visible = false
	add_child(settings_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	settings_panel.add_child(box)
	box.add_child(UIKit.label("设置", 36, Color(0.98, 0.88, 0.55)))
	_add_slider(box, "主音量", Settings.master_volume, func(v): Settings.set_master(v))
	_add_slider(box, "音乐", Settings.music_volume, func(v): Settings.set_music(v))
	_add_slider(box, "音效", Settings.sfx_volume, func(v): Settings.set_sfx(v))
	var full := CheckButton.new()
	full.text = "全屏"
	full.button_pressed = Settings.fullscreen
	full.add_theme_font_size_override("font_size", 24)
	full.toggled.connect(func(pressed): Settings.set_fullscreen(pressed))
	box.add_child(full)
	var back := UIKit.button("返回", Vector2(160, 54))
	back.pressed.connect(func():
		Settings.play_click()
		settings_panel.visible = false)
	box.add_child(back)


func _add_slider(parent: VBoxContainer, title: String, value: float, on_change: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := UIKit.label(title, 24, Color(0.9, 0.92, 0.98))
	label.custom_minimum_size = Vector2(140, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(300, 32)
	row.add_child(slider)
	var value_label := UIKit.label("%d%%" % int(round(value * 100)), 22, Color(0.85, 0.88, 0.95))
	value_label.custom_minimum_size = Vector2(80, 0)
	row.add_child(value_label)
	slider.value_changed.connect(func(v):
		value_label.text = "%d%%" % int(round(v * 100))
		on_change.call(v))
	parent.add_child(row)
