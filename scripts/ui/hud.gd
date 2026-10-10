extends CanvasLayer
## 界面：顶部信息栏、建造菜单、提示、每日结算面板。

var world: Node2D
var build_system: Node2D
var building_panel: CanvasLayer
var inventory_panel: CanvasLayer
var exploration_panel: CanvasLayer
var stats_panel: CanvasLayer

var money_label: Label
var day_label: Label
var clock_label: Label
var facility_label: Label
var guest_label: Label
var fame_label: Label
var reputation_label: Label
var _guest_timer := 0.0
var pause_button: Button
var roof_button: Button
var build_button: Button
var build_panel: PanelContainer
var build_list: VBoxContainer
var notice_label: Label
var settlement: Control
var settlement_box: VBoxContainer
var speed_buttons: Dictionary = {}
var pause_menu: Control
var pause_menu_button: Button
var pan_button: Button
var build_status: Label
var _cycle_settled := false
var _settlement_can_choose := true     # 当天还没做过选择时才显示「休息 / 探索 / 夜晚管理」
var ui_root: Control
var hide_button: Button
var ui_hidden := false


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	build_system = get_node_or_null("../BuildSystem")
	building_panel = get_node_or_null("../BuildingPanel")
	inventory_panel = get_node_or_null("../InventoryPanel")
	exploration_panel = get_node_or_null("../ExplorationPanel")
	stats_panel = get_node_or_null("../StatsPanel")
	var root := UIKit.root_control()
	root.name = "UIRoot"
	add_child(root)

	# 常规界面统一挂在 ui_root 下，方便一键隐藏
	ui_root = Control.new()
	ui_root.name = "GameUI"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ui_root)

	_build_top_bar(ui_root)
	_build_menu(ui_root)
	_build_hint(ui_root)
	_build_notice(ui_root)
	_build_settlement(ui_root)
	_build_pause_menu(ui_root)
	_build_hide_button(root)

	GameState.money_changed.connect(_on_money_changed)
	GameState.day_changed.connect(_on_day_changed)
	GameState.reputation_changed.connect(_on_reputation_changed)
	GameState.fame_changed.connect(_on_fame_changed)
	GameState.notice.connect(show_notice)
	GameClock.tick.connect(_on_tick)
	GameClock.day_finished.connect(_on_day_finished)
	GameClock.morning_started.connect(_on_morning_started)
	if world:
		world.building_placed.connect(func(_b): _refresh_facility_label())
	if build_system and build_system.has_signal("selection_changed"):
		build_system.selection_changed.connect(_on_build_selection_changed)
	_refresh_all()
	_hide_pause_menu()


func _on_build_selection_changed(_what: String) -> void:
	_refresh_build_status()


func _refresh_build_status() -> void:
	# 明确告诉玩家：现在处于建造模式、拿着什么工具、怎么退出
	if build_status == null or build_system == null:
		return
	var what := ""
	if build_system.is_demolishing():
		what = "拆除建筑：先点建筑选中，再点一次确认"
	elif build_system.is_painting():
		what = "铺地面：点或按住拖动地面生效"
	elif str(build_system.selected_id) != "":
		var data: Dictionary = DataRegistry.get_building(str(build_system.selected_id))
		what = "放置 %s：点地面放下" % str(data.get("name", build_system.selected_id))
	if what == "":
		build_status.text = "未选择工具：点上面的项目开始建造。"
		build_status.add_theme_color_override("font_color", Color(0.78, 0.80, 0.88))
	else:
		build_status.text = "▶ %s　｜　右键（或 ESC）退出建造模式" % what
		build_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	# 建造模式下把顶栏按钮高亮，一眼能看出当前状态
	if build_button:
		build_button.text = "建造中… (B)" if what != "" else "建造 (B)"


func _process(delta: float) -> void:
	# 累计游玩时长（会写进存档，标题界面里显示）
	if not GameClock.paused:
		GameState.playtime += delta
	_guest_timer += delta
	if _guest_timer >= 1.0:
		_guest_timer = 0.0
		_refresh_guest_label()


func _make_theme() -> Theme:
	return UIKit.theme()


func _panel_style(bg: Color, border: Color) -> StyleBoxFlat:
	return UIKit.panel_style(bg, border)


func _style_button(b: Button) -> void:
	var styles := {
		"normal": _panel_style(Color(0.16, 0.14, 0.20, 0.92), Color(0.42, 0.38, 0.52)),
		"hover": _panel_style(Color(0.24, 0.21, 0.30, 0.95), Color(0.72, 0.62, 0.35)),
		"pressed": _panel_style(Color(0.30, 0.26, 0.16, 0.98), Color(0.95, 0.80, 0.40)),
		"focus": _panel_style(Color(0.22, 0.20, 0.28, 0.95), Color(0.72, 0.62, 0.35)),
	}
	b.add_theme_font_size_override("font_size", 24)
	for key in styles.keys():
		b.add_theme_stylebox_override(key, styles[key])


func _build_top_bar(root: Control) -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 12
	bar.offset_top = 12
	bar.offset_right = -12
	bar.offset_bottom = 136
	bar.add_theme_stylebox_override("panel", _panel_style(Color(0.10, 0.09, 0.13, 0.88), Color(0.35, 0.32, 0.42)))
	root.add_child(bar)

	# 分两行排，避免按钮被挤出屏幕右边
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	bar.add_child(column)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	column.add_child(row)

	money_label = _make_label("", 30, Color(0.98, 0.85, 0.35))
	day_label = _make_label("", 26, Color(0.92, 0.92, 0.96))
	clock_label = _make_label("", 26, Color(0.80, 0.90, 1.0))
	reputation_label = _make_label("", 24, Color(0.90, 0.82, 1.0))
	for l: Label in [money_label, day_label, clock_label, reputation_label]:
		row.add_child(l)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# 注意：这是「时间暂停」，和右上角的「菜单」（暂停菜单）是两件事
	pause_button = _make_button("暂停时间")
	pause_button.tooltip_text = "只停住时间，不打开菜单。"
	pause_button.pressed.connect(_toggle_pause)
	row.add_child(pause_button)

	for pair in [[GameClock.Speed.X1, "1x"], [GameClock.Speed.X2, "2x"], [GameClock.Speed.X4, "4x"]]:
		var b := _make_button(str(pair[1]))
		b.pressed.connect(_set_speed.bind(pair[0]))
		row.add_child(b)
		speed_buttons[pair[0]] = b

	# 64 倍速：调试 / 测试用，正式发布前删掉
	var fast := _make_button("64x")
	fast.tooltip_text = "测试用：64 倍速（正式版会移除）"
	fast.pressed.connect(_set_speed.bind(GameClock.Speed.X64))
	row.add_child(fast)
	speed_buttons[GameClock.Speed.X64] = fast

	# 第二行：设施概况与功能按钮
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 18)
	column.add_child(row2)

	facility_label = _make_label("", 24, Color(0.80, 0.94, 0.80))
	guest_label = _make_label("", 24, Color(0.95, 0.88, 0.75))
	fame_label = _make_label("", 24, Color(0.98, 0.86, 0.98))
	for l: Label in [facility_label, guest_label, fame_label]:
		row2.add_child(l)

	var spacer2 := Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(spacer2)

	roof_button = _make_button("屋顶：开")
	roof_button.pressed.connect(_toggle_roof)
	row2.add_child(roof_button)

	var inventory_button := _make_button("物资")
	inventory_button.pressed.connect(_toggle_inventory)
	row2.add_child(inventory_button)

	var stats_button := _make_button("属性")
	stats_button.pressed.connect(_toggle_stats)
	row2.add_child(stats_button)

	build_button = _make_button("建造 (B)")
	build_button.pressed.connect(_toggle_build_panel)
	row2.add_child(build_button)

	# 移动视口模式：进入后按住左键拖动即可平移视角（触控板 / 单键鼠标也方便）
	pan_button = _make_button("移动视口")
	pan_button.tooltip_text = "进入后按住鼠标左键拖动即可移动视角，再点一次退出。"
	pan_button.pressed.connect(_toggle_pan_mode)
	row2.add_child(pan_button)

	# 暂停菜单的鼠标入口（原本只能按 ESC 打开，纯鼠标玩家无法存盘 / 回主菜单）
	pause_menu_button = _make_button("菜单")
	pause_menu_button.tooltip_text = "继续游戏 / 保存进度 / 回到主菜单（等同 ESC）"
	pause_menu_button.pressed.connect(_toggle_pause_menu)
	row2.add_child(pause_menu_button)


func _toggle_pan_mode() -> void:
	var cam := get_node_or_null("../Camera")
	if cam == null or not cam.has_method("toggle_pan_mode"):
		GameState.notice.emit("找不到相机，无法进入移动视口模式")
		return
	var on: bool = cam.toggle_pan_mode()
	pan_button.text = "移动视口：开" if on else "移动视口"
	if on:
		show_notice("移动视口模式：按住左键拖动视角，再点一次按钮退出")
	else:
		show_notice("已退出移动视口模式")


func _build_menu(root: Control) -> void:
	build_panel = PanelContainer.new()
	build_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	build_panel.offset_left = 16
	build_panel.offset_top = 148
	# 宽度用 offset_right 钉死。只设 size= 的话和锚点预设会互相覆盖，
	# 实测面板会缩到约 275 宽，按钮文字右边被切掉。
	build_panel.offset_right = 16 + 420
	build_panel.offset_bottom = 148 + 560
	build_panel.custom_minimum_size = Vector2(420, 0)
	build_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.10, 0.09, 0.13, 0.94), Color(0.40, 0.36, 0.50)))
	build_panel.visible = false
	root.add_child(build_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	# 必须显式横向填满：否则 VBox 只按子控件最小宽度排布，
	# 面板明明 420 宽，按钮和文字却被挤在约 285 宽的位置、右边被切掉
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	build_panel.add_child(box)

	box.add_child(_make_label("建造", 32, Color(0.98, 0.88, 0.55)))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 600)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# 地面工具放最前面，铺路是最常用的操作
	list.add_child(_make_label("地面", 26, Color(0.85, 0.78, 0.55)))
	# 当前建造状态：告诉玩家现在拿着什么工具、怎么退出
	build_status = _make_label("", 21, Color(1.0, 0.85, 0.45))
	build_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(build_status)
	var demolish_button := _make_button("")
	demolish_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	demolish_button.text = "拆除建筑（返还一半投入）"
	demolish_button.tooltip_text = "先点建筑选中，再点一次确认拆除。展厅里的展品会退回仓库。"
	demolish_button.pressed.connect(_on_demolish_selected)
	list.add_child(demolish_button)
	var path_button := _make_button("")
	path_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	path_button.text = "铺地砖   %s/格" % GameState.format_money(3)
	path_button.tooltip_text = "客人可以在上面行走。按住左键可以连着铺。"
	path_button.pressed.connect(_on_ground_selected.bind(World.GROUND_PATH))
	list.add_child(path_button)
	var lawn_button := _make_button("")
	lawn_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	lawn_button.text = "铺可行走草坪   %s/格" % GameState.format_money(1)
	lawn_button.tooltip_text = "整理过的草坪，客人可以行走。"
	lawn_button.pressed.connect(_on_ground_selected.bind(World.GROUND_LAWN))
	list.add_child(lawn_button)
	var grass_button := _make_button("")
	grass_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	grass_button.text = "恢复普通草坪   %s/格" % GameState.format_money(1)
	grass_button.tooltip_text = "地图默认的草坪，客人不会走上去。可以用来撤掉铺错的地面。"
	grass_button.pressed.connect(_on_ground_selected.bind(World.GROUND_WILD))
	list.add_child(grass_button)
	var walk_hint := _make_label("客人只走地砖和可行走草坪，记得把店门口连到主路。", 19, Color(0.85, 0.85, 0.9))
	walk_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(walk_hint)

	# 建筑清单单独放一个容器：知名度涨上去以后要能重新生成，
	# 否则「（知名度 XXX 解锁）」的置灰按钮会一直灰着，直到重开游戏。
	build_list = VBoxContainer.new()
	build_list.add_theme_constant_override("separation", 8)
	build_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_child(build_list)
	_refresh_build_list()


func _refresh_build_list() -> void:
	for child in build_list.get_children():
		child.queue_free()
	for cat_id in DataRegistry.category_order:
		var cat: Dictionary = DataRegistry.categories[cat_id]
		var header := _make_label(str(cat.get("name", cat_id)), 26, DataRegistry.get_category_color(cat_id))
		build_list.add_child(header)
		for id in DataRegistry.building_order:
			var data: Dictionary = DataRegistry.get_building(id)
			if str(data.get("category", "")) != str(cat_id):
				continue
			if bool(data.get("hidden", false)):
				continue      # 已淘汰的旧建筑不再显示
			var b := _make_button("")
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			var unlock_fame := int(data.get("unlock_fame", 0))
			if GameState.fame < float(unlock_fame):
				b.text = "%s   （知名度 %d 解锁）" % [str(data.get("name", id)), unlock_fame]
				b.disabled = true
			else:
				b.text = "%s   %s" % [str(data.get("name", id)), GameState.format_money(int(data.get("cost", 0)))]
			b.tooltip_text = "%s\n造价 %s ｜ 容量 %d ｜ 平均消费 %d" % [
				str(data.get("description", "")),
				GameState.format_money(int(data.get("cost", 0))),
				int(data.get("capacity", 0)),
				int(data.get("spend", 0)),
			]
			b.pressed.connect(_on_build_selected.bind(id))
			build_list.add_child(b)


func _build_hint(root: Control) -> void:
	# 提示条：键盘都是快捷方式，鼠标都能做（右键退出建造、顶栏「菜单」存盘）
	var hint := _make_label("点建筑查看详情 ｜ 建造：顶栏「建造」→ 点地面，右键退出 ｜ 视角：中键拖 / 「移动视口」后左键拖 / 滚轮缩放 ｜ 顶栏：物资 属性 屋顶 倍速 菜单 ｜ 快捷键 B V R H 空格 1/2/3/4 ESC", 20, Color(0.85, 0.85, 0.92, 0.85))
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -46
	hint.offset_bottom = -12
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(hint)


func _build_hide_button(root: Control) -> void:
	# 右下角：一键隐藏 / 显示界面（放在 ui_root 之外，隐藏后依然能点回来）
	hide_button = _make_button("隐藏界面 (H)")
	hide_button.custom_minimum_size = Vector2(200, 56)
	hide_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hide_button.offset_left = -220
	hide_button.offset_right = -16
	hide_button.offset_top = -74
	hide_button.offset_bottom = -18
	hide_button.pressed.connect(_toggle_ui)
	root.add_child(hide_button)


func _toggle_ui() -> void:
	ui_hidden = not ui_hidden
	ui_root.visible = not ui_hidden
	for panel in [building_panel, inventory_panel, stats_panel, exploration_panel]:
		if panel and ui_hidden:
			panel.visible = false
	hide_button.text = "显示界面 (H)" if ui_hidden else "隐藏界面 (H)"
	if ui_hidden:
		show_notice("界面已隐藏，按 H 或点右下角按钮可以恢复")
		notice_label.modulate.a = 1.0
		var tween := create_tween()
		tween.tween_interval(2.0)
		tween.tween_property(notice_label, "modulate:a", 0.0, 0.8)
		if pause_menu:
			pause_menu.visible = false


func _build_pause_menu(root: Control) -> void:
	pause_menu = Control.new()
	pause_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(pause_menu)

	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.04, 0.06, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.12, 0.11, 0.16, 0.98), Color(0.85, 0.72, 0.40)))
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	box.add_child(_make_label("游戏暂停", 52, Color(0.98, 0.88, 0.55)))
	box.add_child(_make_label("时间已经停住，慢慢安排就好。按 ESC 也可以回到游戏。", 22, Color(0.85, 0.88, 0.95)))
	box.add_child(_make_label("提示：点建筑可以升级、雇员工；右上角「物资」「属性」是仓库与属性面板。", 20, Color(0.78, 0.80, 0.88)))
	box.add_child(UIKit.spacer(6))

	var resume := _make_button("继续游戏")
	resume.custom_minimum_size = Vector2(360, 64)
	resume.pressed.connect(_toggle_pause_menu)
	box.add_child(resume)

	var save_button := _make_button("保存进度")
	save_button.custom_minimum_size = Vector2(360, 64)
	save_button.pressed.connect(_manual_save)
	box.add_child(save_button)

	var menu_button := _make_button("回到主菜单")
	menu_button.custom_minimum_size = Vector2(360, 64)
	menu_button.pressed.connect(_back_to_title)
	box.add_child(menu_button)

	box.add_child(_make_label("每天 24 点结算时会自动保存到当前存档。", 20, Color(0.8, 0.83, 0.9)))


func _hide_pause_menu() -> void:
	# 主菜单已经在标题界面处理，这里不再弹开始菜单
	pause_menu.visible = false
	GameClock.paused = false
	pause_button.text = "暂停时间"


func _toggle_pause_menu() -> void:
	pause_menu.visible = not pause_menu.visible
	GameClock.paused = pause_menu.visible
	pause_button.text = "继续时间" if pause_menu.visible else "暂停时间"


func _manual_save() -> void:
	if SaveManager.save_game():
		GameState.notice.emit("已保存到存档 %d" % SaveManager.active_slot)
		show_notice("已保存到存档 %d（第 %d 天）" % [SaveManager.active_slot, GameState.day])
	else:
		GameState.notice.emit("保存失败")


func _back_to_title() -> void:
	SaveManager.save_game()
	pause_menu.visible = false
	GameClock.paused = false
	get_tree().change_scene_to_file("res://scenes/title.tscn")


func _toggle_inventory() -> void:
	if inventory_panel:
		inventory_panel.toggle()


func _toggle_stats() -> void:
	if stats_panel:
		stats_panel.toggle()


func _build_notice(root: Control) -> void:
	notice_label = _make_label("", 26, Color(1, 1, 1))
	notice_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	notice_label.offset_top = -110
	notice_label.offset_bottom = -70
	notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notice_label.modulate.a = 0.0
	root.add_child(notice_label)


func _build_settlement(root: Control) -> void:
	settlement = Control.new()
	settlement.set_anchors_preset(Control.PRESET_FULL_RECT)
	settlement.visible = false
	root.add_child(settlement)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	settlement.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	settlement.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.12, 0.11, 0.16, 0.98), Color(0.85, 0.72, 0.40)))
	panel.custom_minimum_size = Vector2(720, 0)
	center.add_child(panel)

	settlement_box = VBoxContainer.new()
	settlement_box.add_theme_constant_override("separation", 14)
	panel.add_child(settlement_box)


func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 5)
	return l


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(96, 56)
	_style_button(b)
	return b


# ---------- 交互 ----------

func _unhandled_input(event: InputEvent) -> void:
	if pause_menu and pause_menu.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_toggle_pause_menu()
		return
	if exploration_panel and exploration_panel.is_open():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			exploration_panel.close()
		return
	if stats_panel and stats_panel.is_open():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			stats_panel.close()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_handle_world_click(event.position)
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.keycode
	match key:
		KEY_SPACE:
			_toggle_pause()
		KEY_R:
			_toggle_roof()
		KEY_B:
			_toggle_build_panel()
		KEY_V:
			_toggle_inventory()
		KEY_H:
			_toggle_ui()
		KEY_ESCAPE:
			if building_panel:
				building_panel.close()
			if inventory_panel:
				inventory_panel.close()
			if build_system and (build_system.selected_id != "" or build_system.is_painting() or build_system.is_demolishing()):
				build_system.cancel()
			else:
				_toggle_pause_menu()
		KEY_F:
			GameClock.skip_to_end_of_day()
		KEY_1:
			_set_speed(GameClock.Speed.X1)
		KEY_2:
			_set_speed(GameClock.Speed.X2)
		KEY_3:
			_set_speed(GameClock.Speed.X4)
		KEY_4:
			_set_speed(GameClock.Speed.X64)


func _handle_world_click(screen_pos: Vector2) -> void:
	if world == null:
		return
	if build_system and build_system.selected_id != "":
		return   # 建造模式下点击由建造系统处理
	var canvas := get_viewport().get_canvas_transform()
	var world_pos: Vector2 = canvas.affine_inverse() * screen_pos
	var cell: Vector2i = world.world_to_cell(world_pos)
	var picked: Building = world.building_at(cell)
	if picked:
		if building_panel:
			building_panel.open(picked)
	elif building_panel and building_panel.is_open():
		building_panel.close()


func _toggle_pause() -> void:
	GameClock.toggle_pause()
	pause_button.text = "继续时间" if GameClock.paused else "暂停时间"


func _set_speed(speed: int) -> void:
	GameClock.set_speed(speed)
	for key in speed_buttons.keys():
		var b: Button = speed_buttons[key]
		b.modulate = Color(1, 1, 1) if key == speed else Color(0.62, 0.62, 0.68)


func _toggle_roof() -> void:
	if world == null:
		return
	world.toggle_roof_mode()
	roof_button.text = "屋顶：开" if world.show_roofs else "屋顶：关"


func _toggle_build_panel() -> void:
	build_panel.visible = not build_panel.visible
	if build_panel.visible:
		_refresh_build_list()      # 打开时重算一次解锁状态


func _on_build_selected(id: String) -> void:
	if build_system:
		build_system.select(id)
	show_notice("已选择：%s ｜ 点击地面放置，右键或 ESC 取消" % str(DataRegistry.get_building(id).get("name", id)))


func _on_ground_selected(kind: String) -> void:
	if build_system:
		build_system.select_ground(kind)
	var name := "地砖"
	if kind == World.GROUND_LAWN:
		name = "可行走草坪"
	elif kind == World.GROUND_WILD:
		name = "普通草坪"
	show_notice("铺设%s：点击或按住左键刷，右键 / ESC 取消" % name)


func _on_demolish_selected() -> void:
	if build_system:
		build_system.select_demolish()
	show_notice("拆除模式：点建筑选中，再点一次确认；ESC 取消")


func _on_money_changed(_value: int) -> void:
	_refresh_money()


func _on_day_changed(_day: int) -> void:
	_refresh_day()


func _on_reputation_changed(_value: float) -> void:
	_refresh_reputation()


func _on_fame_changed(_value: float) -> void:
	_refresh_fame()
	# 知名度跨过门槛时，建造菜单里的置灰项要立刻变成可点
	if build_panel and build_panel.visible:
		_refresh_build_list()


func _on_tick(_progress: float, _hour: float) -> void:
	clock_label.text = "时间 %s" % GameClock.time_text()


func _refresh_all() -> void:
	_refresh_money()
	_refresh_day()
	_refresh_facility_label()
	_refresh_guest_label()
	_refresh_reputation()
	_refresh_fame()
	clock_label.text = "时间 %s" % GameClock.time_text()


func _refresh_money() -> void:
	money_label.text = "资金 %s" % GameState.format_money(GameState.money)


func _refresh_day() -> void:
	day_label.text = "第 %d 天" % GameState.day


func _refresh_facility_label() -> void:
	var count: int = world.buildings.size() if world else 0
	facility_label.text = "设施 %d 座" % count


func _refresh_guest_label() -> void:
	if world == null:
		return
	guest_label.text = "游客 %d 人" % world.customers_root.get_child_count()


func _refresh_reputation() -> void:
	reputation_label.text = "口碑 %.1f" % GameState.reputation


func _refresh_fame() -> void:
	fame_label.text = "知名度 %.0f" % GameState.fame


func show_notice(text: String) -> void:
	notice_label.text = text
	notice_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_property(notice_label, "modulate:a", 0.0, 0.8)


func _on_day_finished() -> void:
	# 每日结算顺序：展厅成交 → 发工资 → 夜间带回物资 → 生成结算报告 → 自动存档
	if world and not _cycle_settled:
		_cycle_settled = true
		world.settle_showroom_sales()
		world.pay_daily_wages()
		var gained: Array = world.night_yield()
		if not gained.is_empty():
			var parts: Array = []
			for entry in gained:
				parts.append("%s×%d" % [DataRegistry.item_name(str(entry.get("id", ""))), int(entry.get("count", 1))])
			GameState.notice.emit("夜间带回：" + ", ".join(parts))
	var report := GameState.day_report()
	var fame_report := GameState.apply_daily_fame()
	SaveManager.save_game()
	GameClock.paused = true
	pause_button.text = "继续时间"
	_settlement_can_choose = true        # 新的一次结算：重新给出三个选择
	_show_settlement(report)
	if not fame_report.is_empty():
		show_notice("知名度 %+.0f（游客 %d 人 ｜ 明星 +%d ｜ 日常 -1）" % [
			float(fame_report.get("delta", 0.0)), int(fame_report.get("visitors", 0)),
			int(fame_report.get("star", 0.0))])


func _show_settlement(report: Dictionary) -> void:
	# 先藏起来再重建，避免 queue_free 还没生效时新旧按钮同时显示
	for child in settlement_box.get_children():
		settlement_box.remove_child(child)
		child.queue_free()
	settlement.visible = true
	settlement_box.add_child(_make_label("第 %d 天 · 结算" % int(report.get("day", 1)), 40, Color(0.98, 0.88, 0.55)))
	settlement_box.add_child(_make_label("本日营业额：%s" % GameState.format_money(int(report.get("revenue", 0))), 28, Color(0.98, 0.85, 0.35)))
	settlement_box.add_child(_make_label("其中展厅成交：%s" % GameState.format_money(int(report.get("item_income", 0))), 22, Color(0.90, 0.80, 0.95)))
	settlement_box.add_child(_make_label("员工工资支出：-%s" % GameState.format_money(int(report.get("wages", 0))), 22, Color(0.95, 0.75, 0.75)))
	settlement_box.add_child(_make_label("到访客人：%d 位" % int(report.get("visitors", 0)), 26, Color(0.90, 0.92, 1.0)))
	settlement_box.add_child(_make_label("当前口碑：%.1f" % float(report.get("reputation", 0.0)), 26, Color(0.90, 0.82, 1.0)))
	settlement_box.add_child(_make_label("仓库物资：%d 种，估值 %s" % [GameState.inventory.size(), GameState.format_money(GameState.inventory_value())], 22, Color(0.85, 0.92, 1.0)))
	settlement_box.add_child(_make_label("自动存档已完成（探索系统开放后会另存一个探索前的存档点）", 20, Color(0.75, 0.78, 0.85)))

	if not _settlement_can_choose:
		# 今天已经做过选择（休息过 / 探索回来了）：只给一个「开始第二天」
		settlement_box.add_child(_make_label("今天已经安排过了。", 22, Color(0.85, 0.88, 0.95)))
		var actions_done := HBoxContainer.new()
		actions_done.add_theme_constant_override("separation", 16)
		settlement_box.add_child(actions_done)
		var next_day := _make_button("开始第二天")
		next_day.custom_minimum_size = Vector2(300, 64)
		next_day.pressed.connect(_start_next_day)
		actions_done.add_child(next_day)
		return

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 16)
	settlement_box.add_child(actions)

	var rest := _make_button("休息一晚（自动结算夜间收益）")
	rest.custom_minimum_size = Vector2(360, 64)
	rest.pressed.connect(_rest_for_night)
	actions.add_child(rest)

	var explore := _make_button("外出探索")
	explore.custom_minimum_size = Vector2(260, 64)
	explore.disabled = false
	explore.pressed.connect(_open_exploration)
	actions.add_child(explore)

	if GameClock.night_available():
		var night := _make_button("夜晚继续管理")
		night.custom_minimum_size = Vector2(260, 64)
		night.pressed.connect(_manage_night)
		actions.add_child(night)

	var night_preview: int = world.night_income_total() if world else 0
	if GameClock.night_available() and night_preview > 0:
		settlement_box.add_child(_make_label("若现在休息或出发探索：酒吧等夜间店铺自动结算约 %s" % GameState.format_money(night_preview), 22, Color(0.95, 0.85, 0.6)))
	elif not GameClock.night_available():
		settlement_box.add_child(_make_label("夜晚已经营业结束，直接开始第二天。", 22, Color(0.85, 0.88, 0.95)))


func _open_exploration() -> void:
	if exploration_panel == null:
		GameState.notice.emit("探索界面不可用")
		return
	_apply_auto_night_income()
	settlement.visible = false
	exploration_panel.open()


func _apply_auto_night_income() -> int:
	# 选择休息 / 探索时，夜间营业的店铺（酒吧等）自动结算一次
	if world == null or not GameClock.night_available():
		return 0
	var total: int = world.apply_night_income()
	if total > 0:
		GameState.notice.emit("夜间自动营业收益 +%s" % GameState.format_money(total))
	return total


func _rest_for_night() -> void:
	# 先结算夜间营业收益，再把场地上的顾客位置统一重置：
	# 有房间的回房睡觉，当日往返的直接离开（回来时已经是第二天早上）
	var night_income := _apply_auto_night_income()
	if world:
		var reset: Dictionary = world.rest_night()
		if int(reset.get("slept", 0)) + int(reset.get("left", 0)) > 0:
			show_notice("住客回房休息 %d 位 ｜ 当日往返 %d 位已在夜里离开%s" % [
				int(reset.get("slept", 0)), int(reset.get("left", 0)),
				"" if night_income <= 0 else " ｜ 夜间收益 +%s" % GameState.format_money(night_income)])
	_start_next_day()


func _manage_night() -> void:
	settlement.visible = false
	# 天数先翻页：0 点到 6 点的收益算进新的一天，合并到下一次 24 点结算
	GameState.finish_day()
	GameState.start_next_day()
	_cycle_settled = false
	GameClock.resume_night()
	GameClock.paused = false
	pause_button.text = "暂停时间"
	show_notice("夜晚继续经营：只有酒吧这类夜间店铺接客；0 点到 6 点的收益会并到下一次 24 点结算")


func _on_morning_started() -> void:
	# 夜里走到早上 6 点：不再弹结算，直接开始新一天的营业
	if world:
		world.rest_all_staff()
	PlayerStats.daily_restore()
	show_notice("早上 6 点，度假村开门营业")


func on_exploration_closed() -> void:
	# 从探索界面返回时，如果还停在当天结算，就把结算面板重新显示出来。
	# 这时候今天已经安排过了，只给「开始第二天」，不再重复摆出三个选择。
	if GameClock.phase == GameClock.Phase.SETTLEMENT and not GameState.last_report().is_empty():
		_settlement_can_choose = false
		_show_settlement(GameState.last_report())


func begin_next_day() -> void:
	_start_next_day()


func _start_next_day() -> void:
	settlement.visible = false
	if world:
		world.rest_all_staff()
	PlayerStats.daily_restore()
	GameState.finish_day()
	_cycle_settled = false
	GameState.start_next_day()
	GameClock.start_new_day()
	GameClock.paused = false
	pause_button.text = "暂停时间"
	_refresh_all()
	show_notice("第 %d 天开始了" % GameState.day)
