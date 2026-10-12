extends CanvasLayer
## 游客状态面板：分两栏——「普通游客」与「明星 / 富商」，上方按钮切换。
## 每行 = 一张正面头像 + 名字；点名字 → 相机对焦 + 橙色中括号高亮，
## 下方显示状态 / 心情 / 已消费资金 / 同行伙伴（没有伙伴就不显示这一行）。
## 退出对焦的三种方式：再点一次同一个名字、按 ESC、点顶栏「游客状态」按钮——
## 退出后相机就停在当前位置（不回飞），面板本身保持打开。
## 名单每 0.4 秒刷新；对焦中的游客离开后自动取消对焦。

const HIGHLIGHT_SCRIPT := preload("res://scripts/world/visitor_highlight.gd")

const REFRESH_INTERVAL := 0.4     # 面板开着时的刷新间隔（秒）
const FOCUS_ZOOM := 2.4           # 对焦游客时的缩放

var world: Node2D
var camera: Node
var hud: Node

var panel: PanelContainer
var tab_normal: Button
var tab_special: Button
var count_label: Label
var list_box: VBoxContainer
var detail_hint: Label
var detail_title: Label
var detail_state: Label
var detail_mood: Label
var detail_spent: Label
var detail_party: Label

var _highlight: Node2D
var _face_cache: Dictionary = {}    # 贴图路径 → 正面头像（AtlasTexture）
var _rows: Array = []               # 当前列出的游客（与按钮一一对应）
var _buttons: Array = []
var _signature := "<init>"          # 名单签名：变化时才重建按钮
var _tab := 0                       # 0 = 普通游客 ｜ 1 = 明星 / 富商
var _selected: Customer = null
var _timer := 0.0


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	camera = get_node_or_null("../Camera")
	hud = get_node_or_null("../HUD")

	var root := UIKit.root_control()
	add_child(root)

	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -464
	panel.offset_right = -12
	panel.offset_top = 148
	panel.offset_bottom = -84
	panel.add_theme_stylebox_override("panel", UIKit.panel_style())
	panel.visible = false
	root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	box.add_child(UIKit.label("游客状态", 34, Color(0.98, 0.88, 0.55)))

	# 上方分栏切换：普通游客 / 明星·富商
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	box.add_child(tabs)
	tab_normal = UIKit.button("普通游客", Vector2(0, 48))
	tab_normal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_normal.add_theme_font_size_override("font_size", 21)
	tab_normal.pressed.connect(set_tab.bind(0))
	tabs.add_child(tab_normal)
	tab_special = UIKit.button("明星 / 富商", Vector2(0, 48))
	tab_special.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_special.add_theme_font_size_override("font_size", 21)
	tab_special.pressed.connect(set_tab.bind(1))
	tabs.add_child(tab_special)

	count_label = UIKit.label("", 21, Color(0.85, 0.88, 0.95))
	box.add_child(count_label)
	var tip := UIKit.label("点名字：相机跟过去并用橙色中括号标记；再点一次 / ESC / 顶栏按钮都可退出跟随（相机停在原地）。", 19, Color(0.78, 0.80, 0.88))
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(tip)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 200)
	box.add_child(scroll)

	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 6)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)

	box.add_child(UIKit.label("—— 游客详情 ——", 22, Color(0.95, 0.85, 0.5)))
	detail_hint = UIKit.label("点击上方名字，查看状态并让相机跟过去。", 20, Color(0.80, 0.82, 0.9))
	detail_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail_hint)
	detail_title = UIKit.label("", 24, Color(1.0, 0.74, 0.34))
	detail_state = UIKit.label("", 20, Color(0.90, 0.92, 0.97))
	detail_mood = UIKit.label("", 20, Color(0.90, 0.92, 0.97))
	detail_spent = UIKit.label("", 20, Color(0.98, 0.85, 0.55))
	detail_party = UIKit.label("", 20, Color(0.85, 0.95, 0.85))
	for l: Label in [detail_title, detail_state, detail_mood, detail_spent, detail_party]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.visible = false
		box.add_child(l)

	var close_button := UIKit.button("关闭", Vector2(160, 52))
	close_button.pressed.connect(close)
	box.add_child(close_button)

	# 橙色括号高亮：挂在 world 下（世界坐标），z_index 最高，盖过建筑与屋顶
	if world:
		_highlight = HIGHLIGHT_SCRIPT.new()
		_highlight.name = "VisitorHighlight"
		_highlight.z_index = 4096
		world.add_child(_highlight)

	_apply_tab_style()


func toggle() -> void:
	if panel.visible:
		close()
	else:
		panel.visible = true
		_refresh()


func close() -> void:
	if panel == null:
		return
	panel.visible = false
	clear_selection()


func is_open() -> bool:
	return panel != null and panel.visible


func is_focused() -> bool:
	return _selected != null and is_instance_valid(_selected)


func current_tab() -> int:
	return _tab


func set_tab(index: int) -> void:
	var target := clampi(index, 0, 1)
	if _tab == target:
		_apply_tab_style()
		return
	_tab = target
	_signature = "<switch>"          # 切换分栏：强制重建列表
	if is_open():
		_refresh()
	else:
		_apply_tab_style()


# ---------- 对焦 / 高亮 ----------

func focus_customer(c: Customer) -> void:
	if c == null or not is_instance_valid(c):
		return
	if _selected == c:
		exit_focus()          # 再点一次同一个名字 = 退出对焦（相机停在原地）
		return
	panel.visible = true
	_selected = c
	_timer = 0.0
	if _highlight != null:
		_highlight.set_target(c)
	if camera != null and is_instance_valid(camera) and camera.has_method("set_follow"):
		camera.set_follow(c, FOCUS_ZOOM)
	_refresh()


func exit_focus() -> void:
	# 退出对焦：清高亮、停跟随，相机就停在当前位置（不回飞）
	_clear_focus(true)
	if panel != null and panel.visible:
		_refresh()


func clear_selection(release_camera: bool = true) -> void:
	# release_camera=false：只清高亮与选中，相机交给调用方（如进入自我操纵模式）
	_clear_focus(release_camera)
	if panel != null and panel.visible:
		_refresh()


func _clear_focus(release_camera: bool) -> void:
	_selected = null
	if _highlight != null:
		_highlight.clear_target()
	if release_camera:
		_release_camera()


func _release_camera() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	if hud != null and is_instance_valid(hud) and hud.player_control_on():
		var avatar: Node2D = get_tree().get_first_node_in_group("player_avatar")
		if avatar != null and camera.has_method("set_follow"):
			camera.set_follow(avatar, FOCUS_ZOOM)
			return
	if camera.has_method("clear_follow_here"):
		camera.clear_follow_here()


# ---------- 刷新 ----------

func _process(delta: float) -> void:
	if not is_open():
		return
	_timer += delta
	if _timer < REFRESH_INTERVAL:
		return
	_timer = 0.0
	_refresh()


func _refresh() -> void:
	var all := _collect_all()
	var normal: Array = []
	var special: Array = []
	for c in all:
		if _is_special(c):
			special.append(c)
		else:
			normal.append(c)
	tab_normal.text = "普通游客（%d）" % normal.size()
	tab_special.text = "明星 / 富商（%d）" % special.size()
	_apply_tab_style()
	if _selected != null and not is_instance_valid(_selected):
		_clear_focus(true)            # 对焦中的游客已经离开
	var rows: Array = special if _tab == 1 else normal
	var sig := ""
	for c in rows:
		sig += "%d," % c.get_instance_id()
	if sig != _signature:
		_signature = sig
		_rebuild_list(rows, all.size())
	_apply_selection_style()
	_refresh_detail()


func _collect_all() -> Array:
	var out: Array = []
	if world == null:
		return out
	for node in get_tree().get_nodes_in_group("customers"):
		if not (node is Customer):
			continue
		var c: Customer = node
		if not is_instance_valid(c) or c.is_queued_for_deletion():
			continue
		if c.state == Customer.State.DONE:
			continue
		out.append(c)
	out.sort_custom(func(a: Customer, b: Customer) -> bool:
		return str(a.customer_name) < str(b.customer_name))
	return out


func _is_special(c: Customer) -> bool:
	# 明星 / 富商单独一栏；明星+富商只出现在这一栏，不会在两个列表里重复
	return c.is_star or c.is_tycoon


func _rebuild_list(rows: Array, total: int) -> void:
	for child in list_box.get_children():
		list_box.remove_child(child)
		child.queue_free()
	_rows = rows
	_buttons = []
	count_label.text = "当前在度假村里：%d 位游客 ｜ 本页 %d 位" % [total, rows.size()]
	if rows.is_empty():
		var empty_text := "这一栏暂时没有客人。" if _tab == 1 else "暂时没有普通游客。"
		list_box.add_child(UIKit.label(empty_text, 20, Color(0.80, 0.82, 0.9)))
		return
	for c in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var face := TextureRect.new()
		face.texture = _portrait(c)
		face.custom_minimum_size = Vector2(40, 40)
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		face.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		row.add_child(face)
		var b := UIKit.button(str(c.customer_name), Vector2(0, 46))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_row_pressed.bind(c))
		row.add_child(b)
		list_box.add_child(row)
		_buttons.append(b)


func _portrait(c: Customer) -> Texture2D:
	# 走路图是 4×4 的图集（列 = 朝向、行 = 走路帧）：第 0 帧就是正面站立的模样
	var base := str(c.type_data.get("sprite", ""))
	if base == "":
		return null
	var path := base + "/walk.png"
	if _face_cache.has(path):
		return _face_cache[path]
	if not ResourceLoader.exists(path):
		return null
	var sheet: Texture2D = load(path)
	if sheet == null:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(0, 0, float(sheet.get_width()) / 4.0, float(sheet.get_height()) / 4.0)
	_face_cache[path] = atlas
	return atlas


func _on_row_pressed(c: Customer) -> void:
	focus_customer(c)


func _apply_tab_style() -> void:
	if tab_normal == null or tab_special == null:
		return
	tab_normal.modulate = Color(1.0, 0.84, 0.52) if _tab == 0 else Color(0.72, 0.72, 0.78)
	tab_special.modulate = Color(1.0, 0.84, 0.52) if _tab == 1 else Color(0.72, 0.72, 0.78)


func _apply_selection_style() -> void:
	# 选中的那一行染成暖橙色，一眼能对上高亮的游客
	for i in range(_rows.size()):
		if i >= _buttons.size():
			break
		var b: Button = _buttons[i]
		if not is_instance_valid(b):
			continue
		var picked: bool = _rows[i] == _selected
		b.modulate = Color(1.0, 0.80, 0.48) if picked else Color(1, 1, 1)


func _refresh_detail() -> void:
	var c: Customer = _selected
	var has: bool = c != null and is_instance_valid(c)
	if not has:
		_selected = null
	detail_hint.visible = not has
	for l: Label in [detail_title, detail_state, detail_mood, detail_spent, detail_party]:
		l.visible = false
	if not has:
		return
	detail_title.text = str(c.customer_name)
	detail_title.visible = true
	detail_state.text = "状态：%s" % _status_text(c)
	detail_state.visible = true
	detail_mood.text = "心情：%d / 100" % int(round(c.mood))
	detail_mood.visible = true
	detail_spent.text = "已消费：%s" % GameState.format_money(c.spent_total)
	detail_spent.visible = true
	var partners: Array = []
	if c.party != null and is_instance_valid(c.party):
		for p in c.party.partners_of(c):
			if is_instance_valid(p):
				partners.append(str(p.customer_name))
	detail_party.visible = not partners.is_empty()      # 没有伙伴就不显示这一条
	detail_party.text = "同行伙伴：%s" % "、".join(partners)


func _status_text(c: Customer) -> String:
	match c.state:
		Customer.State.TO_TARGET:
			match c.purpose:
				Customer.Purpose.CHECK_IN:
					return "前往招待厅办理入住"
				Customer.Purpose.TO_ROOM:
					return "前往度假屋"
				Customer.Purpose.CONSUME:
					return "前往 %s 消费" % _building_name(c.target)
				Customer.Purpose.REST:
					return "回度假屋休息"
				Customer.Purpose.CHECK_OUT:
					return "前往招待厅结账"
				Customer.Purpose.WANDER:
					return "在度假村里闲逛"
				_:
					return "走动中"
		Customer.State.INSIDE:
			match c.purpose:
				Customer.Purpose.CONSUME:
					return "在 %s 消费中" % _building_name(c.target)
				Customer.Purpose.REST:
					var room: Building = c.lodge if (c.lodge != null and is_instance_valid(c.lodge)) else c.target
					if GameClock.is_night():
						return "在%s过夜休息" % _building_name(room)
					return "在%s小憩" % _building_name(room)
				Customer.Purpose.CHECK_OUT:
					return "在招待厅结账"
				Customer.Purpose.QUEUE:
					return "在 %s 门口排队等位" % _building_name(c.target)
				_:
					return "在建筑里"
		Customer.State.SEEK_CLINIC:
			return "前往诊所就医"
		Customer.State.WAITING_CURE:
			return "在诊所候诊"
		Customer.State.TREATMENT:
			return "正在接受治疗"
		Customer.State.LEAVING:
			return "正在离开度假村"
		Customer.State.DONE:
			return "已经离开"
	return "未知"


func _building_name(b: Building) -> String:
	if b == null or not is_instance_valid(b):
		return "设施"
	return str(b.display_name())


# ---------- 给冒烟测试 / 调试用的只读接口 ----------

func listed_names() -> Array:
	var out: Array = []
	for c in _rows:
		out.append(str(c.customer_name))
	return out


func listed_count() -> int:
	return _rows.size()


func highlighted() -> Node2D:
	if _highlight == null or not is_instance_valid(_highlight) or not _highlight.visible:
		return null
	var t: Node2D = _highlight.target
	return t


func portrait_ready_count() -> int:
	# 当前列表里「头像真的加载出来了」的行数（每行 = 头像 + 名字按钮）
	var n := 0
	for child in list_box.get_children():
		if not (child is HBoxContainer):
			continue
		for sub in child.get_children():
			if sub is TextureRect and sub.texture != null:
				n += 1
				break
	return n


func details() -> Dictionary:
	return {
		"name": detail_title.text,
		"state": detail_state.text,
		"mood": detail_mood.text,
		"spent": detail_spent.text,
		"partner": detail_party.text,
		"partner_visible": detail_party.visible,
	}
