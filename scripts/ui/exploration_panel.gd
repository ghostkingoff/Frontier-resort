extends CanvasLayer
## 探索界面（整屏，不是弹窗）：
## 左边是地图（局部格子 / 大地图 / 十字过渡区），右边是状态与操作。

var root: Control
var screen: Control
var map_view: MapView
var side: VBoxContainer

var _event_panel: PanelContainer
var _event_box: VBoxContainer


func _ready() -> void:
	root = UIKit.root_control()
	add_child(root)

	# 整屏界面：不透明背景盖住整个游戏画面
	screen = Control.new()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.visible = false
	root.add_child(screen)

	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.06, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(bg)

	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_right = -12
	top.offset_top = 10
	top.offset_bottom = 84
	top.add_theme_stylebox_override("panel", UIKit.panel_style(Color(0.09, 0.10, 0.14, 0.98), Color(0.36, 0.34, 0.46)))
	screen.add_child(top)
	var top_box := HBoxContainer.new()
	top_box.name = "TopBox"
	top_box.add_theme_constant_override("separation", 18)
	top.add_child(top_box)

	var body := HBoxContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 12
	body.offset_right = -12
	body.offset_top = 92
	body.offset_bottom = -56
	body.add_theme_constant_override("separation", 12)
	screen.add_child(body)

	map_view = MapView.new()
	map_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_view.cell_clicked.connect(_on_cell_clicked)
	body.add_child(map_view)

	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(460, 0)
	side_panel.add_theme_stylebox_override("panel", UIKit.panel_style(Color(0.085, 0.09, 0.125, 0.98), Color(0.36, 0.34, 0.46)))
	body.add_child(side_panel)
	var scroll := ScrollContainer.new()
	side_panel.add_child(scroll)
	side = VBoxContainer.new()
	side.add_theme_constant_override("separation", 8)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)

	var hint := UIKit.label("点击相邻格子移动 ｜ M 开关大地图 ｜ 走到边缘后从对应方向出图 ｜ ESC 或按钮结束探索", 20, Color(0.8, 0.82, 0.9, 0.85))
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -48
	hint.offset_bottom = -12
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	screen.add_child(hint)

	# 事件 / 结果用的大卡片，出现在地图下方，不遮住整屏
	_event_panel = PanelContainer.new()
	_event_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_event_panel.offset_left = -520
	_event_panel.offset_right = 520
	_event_panel.offset_top = -330
	_event_panel.offset_bottom = -70
	_event_panel.add_theme_stylebox_override("panel", UIKit.panel_style(Color(0.10, 0.10, 0.15, 0.98), Color(0.72, 0.62, 0.36)))
	_event_panel.visible = false
	screen.add_child(_event_panel)
	var event_scroll := ScrollContainer.new()
	_event_panel.add_child(event_scroll)
	_event_box = VBoxContainer.new()
	_event_box.add_theme_constant_override("separation", 8)
	_event_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	event_scroll.add_child(_event_box)

	Exploration.state_changed.connect(_refresh_if_open)
	Exploration.map_changed.connect(_refresh_if_open)
	Exploration.run_finished.connect(_on_run_finished)


func open() -> void:
	screen.visible = true
	# 点「外出探索」进来时直接出发；如果状态不允许，先提示
	if not Exploration.active:
		if PlayerStats.san <= 0.0:
			GameState.notice.emit("SAN 见底了，今晚先休息吧")
			close()
			return
		elif PlayerStats.stamina <= 1.0:
			GameState.notice.emit("体力不足，今晚先休息吧")
			close()
			return
		else:
			Exploration.start_run()
	_refresh()


func close(notify := true) -> void:
	screen.visible = false
	if notify:
		var hud := get_parent().get_node_or_null("HUD")
		if hud and hud.has_method("on_exploration_closed"):
			hud.on_exploration_closed()


func is_open() -> bool:
	return screen != null and screen.visible


func _refresh_if_open() -> void:
	if is_open():
		_refresh()


func _on_run_finished(_result: String, _summary: Dictionary) -> void:
	if is_open():
		_refresh()


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M and Exploration.active:
			Exploration.toggle_world()
			get_viewport().set_input_as_handled()


func _refresh() -> void:
	_build_top()
	_build_side()
	_refresh_map()
	_build_event_card()


# ---------- 顶部状态栏 ----------

func _build_top() -> void:
	var top_box: HBoxContainer = screen.find_child("TopBox", true, false)
	if top_box == null:
		return
	for child in top_box.get_children():
		child.queue_free()
	top_box.add_child(UIKit.label("探索 · %s" % _current_terrain_name(), 30, Color(0.98, 0.88, 0.55)))
	top_box.add_child(_bar("体力", Exploration.stamina, PlayerStats.stamina_max(), Color(0.45, 0.85, 0.5), 220.0))
	top_box.add_child(_bar("SAN", Exploration.san, PlayerStats.san_max(), Color(0.6, 0.65, 0.95), 220.0))
	top_box.add_child(UIKit.label("灰石 %d" % Exploration.grey_stones, 26, Color(0.85, 0.87, 0.92)))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_box.add_child(spacer)
	if Exploration.active:
		var map_button := UIKit.button("大地图 (M)", Vector2(170, 54))
		map_button.pressed.connect(func(): Exploration.toggle_world())
		top_box.add_child(map_button)
		var home := UIKit.button("结束探索回家", Vector2(210, 54))
		home.pressed.connect(func(): Exploration.go_home())
		top_box.add_child(home)
	else:
		var close_button := UIKit.button("关闭", Vector2(140, 54))
		close_button.pressed.connect(func(): close())
		top_box.add_child(close_button)


func _current_terrain_name() -> String:
	if not Exploration.active and Exploration.end_result != "":
		return "已结束"
	if Exploration.state == Exploration.STATE_TRANSITION:
		var to_tile: Vector2i = Exploration.transition.get("to", Vector2i.ZERO)
		return "过渡区 → %s" % DataRegistry.terrain_name(Exploration.terrain_at(to_tile))
	return DataRegistry.terrain_name(Exploration.terrain_at(Exploration.current_tile))


# ---------- 地图 ----------

func _refresh_map() -> void:
	var cells := {}
	if Exploration.show_world or not Exploration.active:
		cells = _world_cells()
		map_view.set_marker(Exploration.current_tile)
	elif Exploration.state == Exploration.STATE_TRANSITION:
		cells = _transition_cells()
		map_view.set_marker(Exploration.transition_cell)
	else:
		cells = _local_cells()
		map_view.set_marker(Exploration.player_cell)
	map_view.set_cells(cells)


func _local_cells() -> Dictionary:
	var out := {}
	var terrain := Exploration.terrain_at(Exploration.current_tile)
	var base := DataRegistry.terrain_color(terrain)
	var local := Exploration.current_local_map()
	for cell in local.keys():
		var visited := bool(local[cell].get("visited", false))
		var color := base if visited else base.darkened(0.25)
		var sub := "走过" if visited else "未探索"
		# 标出这一格能不能出图、往哪个方向出
		var marks: Array = []
		for info in Exploration.neighbor_exits():
			if Exploration.can_exit_from(cell, info["dir"]):
				marks.append("%s出口" % _dir_arrow(info["dir"]))
		if not marks.is_empty():
			sub = sub + " ｜ " + " ".join(marks)
		out[cell] = {"color": color, "label": "", "sub": sub, "border": Color(0.05, 0.05, 0.08)}
	return out


func _transition_cells() -> Dictionary:
	var out := {}
	for cell in Exploration.transition_cells():
		var label := ""
		var color := Color(0.30, 0.32, 0.38)
		if cell == Vector2i.ZERO:
			label = "空地"
			color = Color(0.22, 0.23, 0.28)
		elif cell == Exploration.transition.get("entry"):
			label = "入口"
			color = Color(0.30, 0.38, 0.50)
		elif cell == Exploration.transition.get("exit"):
			var to_tile: Vector2i = Exploration.transition.get("to", Vector2i.ZERO)
			label = "前往\n%s" % DataRegistry.terrain_name(Exploration.terrain_at(to_tile))
			color = Color(0.32, 0.46, 0.34)
		elif cell == Exploration.transition.get("tent"):
			label = "帐篷"
			color = Color(0.50, 0.40, 0.26)
		else:
			label = "商人" if bool(Exploration.transition.get("has_merchant", false)) else "空"
			color = Color(0.42, 0.30, 0.44)
		out[cell] = {"color": color, "label": label, "sub": "", "border": Color(0.05, 0.05, 0.08)}
	return out


func _world_cells() -> Dictionary:
	var out := {}
	for tile in Exploration.world_map.keys():
		var terrain := Exploration.terrain_at(tile)
		if Exploration.is_revealed(tile):
			out[tile] = {
				"color": DataRegistry.terrain_color(terrain),
				"label": DataRegistry.terrain_name(terrain),
				"sub": "",
				"border": Color(0.05, 0.05, 0.08),
			}
		else:
			out[tile] = {
				"color": Color(0.62, 0.18, 0.68),
				"label": "?",
				"sub": "",
				"border": Color(0.05, 0.05, 0.08),
			}
	return out


func _dir_arrow(dir: Vector2i) -> String:
	if dir.x > 0:
		return "→"
	if dir.x < 0:
		return "←"
	if dir.y > 0:
		return "↓"
	return "↑"


func _on_cell_clicked(cell: Vector2i) -> void:
	if not Exploration.active:
		return
	if Exploration.state == Exploration.STATE_TRANSITION:
		Exploration.transition_move(cell)
	elif Exploration.state == Exploration.STATE_MAP:
		Exploration.move_to(cell)


# ---------- 右侧操作栏 ----------

func _build_side() -> void:
	for child in side.get_children():
		child.queue_free()
	side.add_child(UIKit.paragraph(Exploration.last_text, 22, Color(0.92, 0.94, 0.98), 420.0))
	side.add_child(UIKit.spacer(6))

	if Exploration.ended or Exploration.end_result != "":
		_build_result_actions()
		return

	if not Exploration.active:
		side.add_child(UIKit.label("还没有出发。", 22, Color(0.85, 0.88, 0.95)))
		return

	match Exploration.state:
		Exploration.STATE_MAP:
			side.add_child(UIKit.paragraph("点击相邻格子移动：没走过的格子 2 体力，走过的 1 体力。", 20, Color(0.8, 0.86, 0.8), 420.0))
			_build_exit_buttons()
		Exploration.STATE_TRANSITION:
			side.add_child(UIKit.paragraph("过渡区：中间是空地，走到帐篷或商人那一格才能互动；踏上出口格就进入下一个地形。", 20, Color(0.86, 0.84, 0.72), 420.0))
			if Exploration.tent_ready():
				side.add_child(UIKit.label("帐篷：选一个", 24, Color(0.95, 0.85, 0.5)))
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 10)
				var rest := UIKit.button("休息（体力 +%d）" % int(Exploration.settings().get("tent_rest_stamina", 3)), Vector2(200, 52))
				rest.pressed.connect(func(): Exploration.tent_action("rest"))
				row.add_child(rest)
				var meditate := UIKit.button("冥想（SAN +%d）" % int(Exploration.settings().get("tent_meditate_san", 2)), Vector2(200, 52))
				meditate.pressed.connect(func(): Exploration.tent_action("meditate"))
				row.add_child(meditate)
				side.add_child(row)
			if Exploration.merchant_ready():
				if Exploration.trade_offers.is_empty():
					var trade := UIKit.button("看看商人的货（用灰石交换）", Vector2(340, 54))
					trade.pressed.connect(func(): Exploration.roll_trade_offers())
					side.add_child(trade)
				else:
					side.add_child(UIKit.label("商人（灰石 %d）" % Exploration.grey_stones, 24, Color(0.95, 0.85, 0.5)))
					for i in range(Exploration.trade_offers.size()):
						var offer: Dictionary = Exploration.trade_offers[i]
						var item_id := str(offer.get("item", ""))
						var row := HBoxContainer.new()
						row.add_theme_constant_override("separation", 8)
						row.add_child(UIKit.icon(DataRegistry.item_icon(item_id), Vector2(34, 34)))
						row.add_child(UIKit.label("%s" % DataRegistry.item_name(item_id), 22, DataRegistry.rarity_color(item_id)))
						var buy := UIKit.button("%d 灰石" % int(offer.get("cost", 0)), Vector2(140, 46))
						buy.disabled = bool(offer.get("sold", false)) or Exploration.grey_stones < int(offer.get("cost", 0))
						if bool(offer.get("sold", false)):
							buy.text = "已换走"
						var index := i
						buy.pressed.connect(func(): Exploration.buy_offer(index))
						row.add_child(buy)
						side.add_child(row)
		Exploration.STATE_EVENT:
			pass

	_build_consumables()
	_build_loot()


func _build_exit_buttons() -> void:
	var exits: Array = Exploration.neighbor_exits()
	if exits.is_empty():
		return
	side.add_child(UIKit.label("这个地形四周：", 22, Color(0.9, 0.9, 0.75)))
	for info in exits:
		var dir: Vector2i = info["dir"]
		var terrain := str(info["terrain"])
		var exit_ready := bool(info.get("ready", false))
		var text := "%s %s%s" % [_dir_arrow(dir), DataRegistry.terrain_name(terrain), "（可以出图）" if exit_ready else "（需走到边缘）"]
		var button := UIKit.button(text, Vector2(340, 52))
		button.disabled = not exit_ready
		button.pressed.connect(func(): Exploration.exit_to(dir))
		side.add_child(button)


func _build_consumables() -> void:
	var owned: Array = []
	for id in DataRegistry.consumable_order:
		if PlayerStats.consumable_count(id) > 0:
			owned.append(id)
	if owned.is_empty():
		return
	side.add_child(UIKit.spacer(4))
	side.add_child(UIKit.label("使用消耗品", 22, Color(0.95, 0.85, 0.5)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for id in owned:
		var c := DataRegistry.get_consumable(id)
		var button := UIKit.button("%s ×%d" % [str(c.get("name", id)), PlayerStats.consumable_count(id)], Vector2(150, 48))
		button.tooltip_text = str(c.get("desc", ""))
		button.pressed.connect(func(): Exploration.use_consumable(id))
		row.add_child(button)
	side.add_child(row)


func _build_loot() -> void:
	side.add_child(UIKit.spacer(4))
	side.add_child(UIKit.label("本次收获（估值 %s）" % GameState.format_money(Exploration.loot_value()), 22, Color(0.95, 0.85, 0.5)))
	var list: Array = Exploration.loot_list()
	if list.is_empty():
		side.add_child(UIKit.label("还什么都没有。", 20, Color(0.8, 0.8, 0.85)))
		return
	for entry in list:
		var item_id := str(entry.get("id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(UIKit.icon(DataRegistry.item_icon(item_id), Vector2(28, 28)))
		row.add_child(UIKit.label("%s ×%d" % [DataRegistry.item_name(item_id), int(entry.get("count", 1))], 20, DataRegistry.rarity_color(item_id)))
		side.add_child(row)


# ---------- 事件卡片 ----------

func _build_event_card() -> void:
	for child in _event_box.get_children():
		child.queue_free()
	if Exploration.state != Exploration.STATE_EVENT or Exploration.ended:
		_event_panel.visible = false
		return
	_event_panel.visible = true
	_event_box.add_child(UIKit.label(str(Exploration.current_event.get("title", "事件")), 30, Color(0.98, 0.88, 0.55)))
	_event_box.add_child(UIKit.label(Exploration.last_text, 24, Color(0.92, 0.94, 0.98)))
	_event_box.add_child(UIKit.spacer(4))
	var options: Array = Exploration.current_event.get("options", [])
	for i in range(options.size()):
		var option: Dictionary = options[i]
		var text := "%s（体力 -%d ｜ SAN -%d）" % [
			str(option.get("label", "选择")), int(option.get("stamina", 0)), int(option.get("san", 0))]
		var button := UIKit.button(text, Vector2(0, 54))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var index := i
		button.pressed.connect(func(): Exploration.choose(index))
		_event_box.add_child(button)


# ---------- 结果 ----------

func _build_result_actions() -> void:
	var titles := {
		"returned": "平安回到度假村",
		"auto_return": "自己走回了家",
	}
	side.add_child(UIKit.label(str(titles.get(Exploration.end_result, "探索结束")), 30, Color(0.7, 0.95, 0.7)))
	side.add_child(UIKit.label("灰石已由边境军队按 %d 金/块收走" % int(Exploration.settings().get("grey_stone_money_rate", 3)), 20, Color(0.85, 0.88, 0.95)))
	side.add_child(UIKit.spacer(6))
	if PlayerStats.stamina > 4.0:
		var again := UIKit.button("再探索一次（重新随机地图）", Vector2(340, 56))
		again.pressed.connect(func(): Exploration.start_run())
		side.add_child(again)
	var finish := UIKit.button("结束这一天", Vector2(340, 56))
	finish.pressed.connect(_end_day)
	side.add_child(finish)


func _end_day() -> void:
	close()
	var hud := get_parent().get_node_or_null("HUD")
	if hud:
		hud.begin_next_day()


# ---------- 小工具 ----------

func _bar(title: String, value: float, max_value: float, color: Color, width: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.custom_minimum_size = Vector2(width, 0)
	box.add_child(UIKit.label("%s %.0f / %.0f" % [title, value, max_value], 20, Color(0.92, 0.94, 0.98)))
	var bar := ProgressBar.new()
	bar.max_value = maxf(1.0, max_value)
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(width, 22)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.16, 0.16, 0.20, 0.95)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	box.add_child(bar)
	return box
