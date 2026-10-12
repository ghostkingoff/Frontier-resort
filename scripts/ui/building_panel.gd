extends CanvasLayer
## 建筑详情面板：升级、员工、展厅展示位、医院治疗信息、保洁工人。

const JANITOR := preload("res://scripts/customers/janitor.gd")

var world: Node2D
var building: Building = null
var confirm_demolish := false

var panel: PanelContainer
var content: VBoxContainer


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	var root := UIKit.root_control()
	add_child(root)

	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -560
	panel.offset_right = -16
	panel.offset_top = 148
	panel.offset_bottom = -70
	panel.add_theme_stylebox_override("panel", UIKit.panel_style())
	panel.visible = false
	root.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)

	GameState.money_changed.connect(func(_v): _refresh_if_open())
	GameState.inventory_changed.connect(_refresh_if_open)


func open(target: Building) -> void:
	building = target
	confirm_demolish = false
	panel.visible = true
	_refresh()


func close() -> void:
	building = null
	panel.visible = false


func is_open() -> bool:
	return panel != null and panel.visible


func _refresh_if_open() -> void:
	if is_open() and building and is_instance_valid(building):
		_refresh()


func _refresh() -> void:
	if building == null or not is_instance_valid(building):
		close()
		return
	for child in content.get_children():
		child.queue_free()

	var b := building
	content.add_child(UIKit.label(b.display_name(), 32, Color(0.98, 0.88, 0.55)))
	var desc := str(b.data.get("description", ""))
	if desc != "":
		content.add_child(UIKit.label(desc, 20, Color(0.80, 0.82, 0.88)))
	# 只显示这栋楼「真有的东西」：路灯没有客人/消费，这些行就不会出现
	var info_parts: Array = []
	if b.capacity() > 0 and not b.is_lodging() and not b.is_reception():
		var guest_text := "同时招待 %d / %d 人" % [b.visitors.size(), b.capacity()]
		if b.reserved > 0:
			guest_text += "（在途 %d）" % b.reserved
		info_parts.append(guest_text)
	if b.spend_value() > 0 and not b.is_lodging() and not b.is_reception():
		info_parts.append("平均消费 %s" % GameState.format_money(b.spend_value()))
	if b.mood_bonus() > 0:
		info_parts.append("心情加成 %+.0f" % b.mood_bonus())
	if not info_parts.is_empty():
		content.add_child(UIKit.label(" ｜ ".join(info_parts), 22, Color(0.85, 0.92, 1.0)))
	if b.is_lodging():
		content.add_child(UIKit.label("住客 %d / %d 人 ｜ 住宿费 %s / 晚（结账时进账）" % [
			b.guests.size(), b.room_capacity(), GameState.format_money(b.spend_value())], 22, Color(0.9, 0.92, 0.7)))
	if b.is_reception():
		content.add_child(UIKit.label("累计办理入住 %d 次 ｜ 客人在这里登记与结账" % b.check_ins, 22, Color(0.9, 0.92, 0.7)))
	if not (int(b.data.get("open_hour", 0)) == 0 and int(b.data.get("close_hour", 24)) == 24):
		var hours_title := "照明时间" if str(b.data.get("light_shape", "")) == "circle" else "营业时间"
		content.add_child(UIKit.label("%s %s" % [hours_title, b.hours_text()], 20, Color(0.85, 0.88, 0.95)))
	if b.capacity() > 0 and world and not world.building_reachable(b):
		content.add_child(UIKit.paragraph("客人过不来：门口没有连到主路。用「建造 → 地面」把地砖铺到门口。", 20, Color(0.95, 0.6, 0.6), 420.0))
	if not b.is_reception() and (b.capacity() > 0 or b.spend_value() > 0):
		content.add_child(UIKit.label("累计收入 %s ｜ 接待 %d 人" % [
			GameState.format_money(b.total_earned), b.cured_count + b.visitors.size()], 20, Color(0.9, 0.9, 0.6)))
	if b.is_rotatable():
		_add_rotate_section(b)
	content.add_child(UIKit.spacer(4))

	if b.max_level() > 1:
		_add_upgrade_section(b)
	if b.staff_slots() > 0:
		_add_staff_section(b)
	if b.is_showroom():
		_add_showroom_section(b)
	if b.is_clinic():
		_add_clinic_section(b)
	if b.service() == "cleaning":
		_add_cleaning_section(b)

	var close_button := UIKit.button("关闭面板", Vector2(160, 52))
	close_button.pressed.connect(close)
	content.add_child(UIKit.spacer(4))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	actions.add_child(close_button)
	actions.add_child(_make_demolish_button(b))
	content.add_child(actions)


func _add_rotate_section(b: Building) -> void:
	content.add_child(UIKit.spacer(4))
	content.add_child(UIKit.label("—— 朝向 ——", 24, Color(0.95, 0.85, 0.5)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(UIKit.label("当前朝向：%s ｜ 灯光偏在该方向一格" % b.rotation_text(), 20, Color(0.85, 0.92, 1.0)))
	var btn := UIKit.button("顺时针旋转", Vector2(170, 48))
	btn.pressed.connect(func() -> void:
		b.rotate_clockwise()
		_refresh())
	row.add_child(btn)
	content.add_child(row)


func _add_cleaning_section(b: Building) -> void:
	content.add_child(UIKit.spacer(6))
	content.add_child(UIKit.label("—— 保洁 ——", 24, Color(0.95, 0.85, 0.5)))
	var counts := b.shift_counts()
	content.add_child(UIKit.label("白班 %d 位 ｜ 夜班 %d 位 ｜ 当前在岗 %d 位" % [
		int(counts.get("day", 0)), int(counts.get("night", 0)), b.janitors.size()], 22, Color(0.85, 0.92, 1.0)))
	if b.staff.is_empty():
		content.add_child(UIKit.paragraph(
			"还没有雇保洁。雇人后他们按班次出来清扫（白班 08:00-20:00、夜班 20:00-08:00），负责半径 %d 格内的垃圾。"
			% JANITOR.ROAM_RADIUS_CELLS, 20, Color(0.9, 0.8, 0.7), 420.0))
	else:
		content.add_child(UIKit.paragraph(
			"当班的工人在外面走动清扫，负责半径 %d 格；下班立即回到保洁间、不在地图上出现，范围外的垃圾不会去清。"
			% JANITOR.ROAM_RADIUS_CELLS, 20, Color(0.82, 0.9, 0.98), 420.0))
	content.add_child(UIKit.label("累计清理垃圾 %d 个" % b.janitor_total_cleaned(), 20, Color(0.8, 0.92, 0.8)))


func _make_demolish_button(b: Building) -> Button:
	var demolish := UIKit.button("拆除建筑（返还 %s）" % GameState.format_money(b.refund_value()), Vector2(320, 52))
	if confirm_demolish:
		demolish.text = "确认拆除？"
	demolish.pressed.connect(func():
		if not confirm_demolish:
			confirm_demolish = true
			_refresh()
			return
		var result: Dictionary = world.demolish(b)
		GameState.notice.emit("已拆除 %s，返还 %s" % [
			str(result.get("name", "")), GameState.format_money(int(result.get("refund", 0)))])
		close())
	return demolish


func _add_upgrade_section(b: Building) -> void:
	content.add_child(UIKit.label("—— 升级 ——", 24, Color(0.95, 0.85, 0.5)))
	if b.level >= b.max_level():
		content.add_child(UIKit.label("已经满级", 20, Color(0.8, 0.8, 0.85)))
		return
	var need_money := b.upgrade_cost()
	var line := "升到 Lv.%d：资金 %s" % [b.level + 1, GameState.format_money(need_money)]
	content.add_child(UIKit.label(line, 22, Color(0.95, 0.9, 0.7)))
	var item_reqs := b.upgrade_items()
	if not item_reqs.is_empty():
		for item_id in item_reqs.keys():
			var need := int(item_reqs[item_id])
			var have := GameState.item_count(item_id)
			var color := Color(0.75, 0.95, 0.75) if have >= need else Color(0.95, 0.6, 0.6)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			row.add_child(UIKit.icon(DataRegistry.item_icon(item_id), Vector2(32, 32)))
			row.add_child(UIKit.label("%s  %d / %d" % [DataRegistry.item_name(item_id), have, need], 20, color))
			content.add_child(row)
	var btn := UIKit.button("升级到 Lv.%d" % (b.level + 1), Vector2(200, 54))
	btn.disabled = not b.can_upgrade()
	if btn.disabled:
		btn.text = "无法升级：%s" % b.upgrade_block_reason()
	btn.pressed.connect(func():
		if b.upgrade():
			GameState.notice.emit("%s 升级到 Lv.%d" % [str(b.data.get("name", "")), b.level]))
	content.add_child(btn)


func _add_staff_section(b: Building) -> void:
	content.add_child(UIKit.label("—— 员工 ——", 24, Color(0.95, 0.85, 0.5)))
	var energy := b.staff_energy()
	var energy_color := Color(0.7, 0.95, 0.7)
	if energy < 30.0:
		energy_color = Color(0.95, 0.5, 0.5)
	elif energy < 60.0:
		energy_color = Color(0.95, 0.85, 0.5)
	content.add_child(UIKit.label("在职 %d / %d ｜ 平均状态 %.0f" % [b.staff.size(), b.staff_slots(), energy], 22, energy_color))
	content.add_child(UIKit.label("每日工资合计 %s" % GameState.format_money(b.daily_wage()), 20, Color(0.9, 0.9, 0.7)))
	if b.staff.is_empty():
		content.add_child(UIKit.label("没有员工：客人消费后心情会明显下降", 20, Color(0.95, 0.6, 0.6)))
	elif energy < 30.0:
		content.add_child(UIKit.label("员工状态很低：客人消费后心情会下降", 20, Color(0.95, 0.6, 0.6)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var hire_text := "雇佣（日薪 %d）" % int(b.data.get("staff_wage", 0))
	if b.service() == "cleaning":
		hire_text = "雇佣保洁（日薪 %d ｜ 编入%s班）" % [
			int(b.data.get("staff_wage", 0)), "白" if b.next_shift() == "day" else "夜"]
	var hire := UIKit.button(hire_text, Vector2(280, 52))
	hire.disabled = b.staff.size() >= b.staff_slots()
	hire.pressed.connect(func():
		if b.hire_staff():
			GameState.notice.emit("已雇佣员工"))
	row.add_child(hire)
	var fire := UIKit.button("解雇", Vector2(120, 52))
	fire.disabled = b.staff.is_empty()
	fire.pressed.connect(func():
		if b.fire_staff():
			GameState.notice.emit("已解雇员工"))
	row.add_child(fire)
	content.add_child(row)


func _add_showroom_section(b: Building) -> void:
	content.add_child(UIKit.label("—— 展示位 ——", 24, Color(0.95, 0.85, 0.5)))
	content.add_child(UIKit.label("占用 %d / %d ｜ 吸引力 %d" % [b.display_used(), b.display_capacity(), b.display_score()], 22, Color(0.85, 0.92, 1.0)))
	if b.displayed.is_empty():
		content.add_child(UIKit.label("还没有展示任何物资", 20, Color(0.8, 0.8, 0.85)))
	for i in range(b.displayed.size()):
		var entry: Dictionary = b.displayed[i]
		var item_id := str(entry.get("item_id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(UIKit.icon(DataRegistry.item_icon(item_id), Vector2(34, 34)))
		row.add_child(UIKit.label("%s ×%d" % [DataRegistry.item_name(item_id), int(entry.get("count", 1))], 20, DataRegistry.rarity_color(item_id)))
		var take := UIKit.button("取出", Vector2(96, 44))
		var index := i
		take.pressed.connect(func():
			if b.remove_display(index):
				GameState.notice.emit("已取回仓库"))
		row.add_child(take)
		content.add_child(row)
	content.add_child(UIKit.label("从仓库放入：" if b.display_used() < b.display_capacity() else "展示位已满", 20, Color(0.9, 0.9, 0.75)))
	for entry in GameState.sorted_inventory():
		var item_id := str(entry.get("id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(UIKit.icon(DataRegistry.item_icon(item_id), Vector2(34, 34)))
		row.add_child(UIKit.label("%s ×%d（%s）" % [
			DataRegistry.item_name(item_id), int(entry.get("count", 0)),
			str(DataRegistry.item_rarity(item_id).get("name", ""))], 20, DataRegistry.rarity_color(item_id)))
		var put := UIKit.button("放入", Vector2(96, 44))
		put.disabled = b.display_used() >= b.display_capacity()
		put.pressed.connect(func():
			if b.add_display(item_id, 1):
				GameState.notice.emit("已放入展厅"))
		row.add_child(put)
		content.add_child(row)


func _add_clinic_section(b: Building) -> void:
	content.add_child(UIKit.label("—— 医院 ——", 24, Color(0.95, 0.85, 0.5)))
	content.add_child(UIKit.label("可治疗病症等级：%d 级" % b.treat_level(), 22, Color(0.85, 0.92, 1.0)))
	content.add_child(UIKit.label("医生水平：%d 级 ｜ 同时接诊 %d 人" % [b.doctor_quality(), b.treat_capacity()], 22, Color(0.85, 0.92, 1.0)))
	content.add_child(UIKit.label("候诊 %d 人 ｜ 治疗中 %d 人 ｜ 已治愈 %d 人" % [b.patients.size(), b.treating.size(), b.cured_count], 20, Color(0.9, 0.9, 0.75)))
	var btn := UIKit.button("聘请更好的医生（%s）" % GameState.format_money(b.upgrade_doctor_cost()), Vector2(320, 52))
	btn.disabled = not b.can_upgrade_doctor() or not GameState.can_afford(b.upgrade_doctor_cost())
	if not b.can_upgrade_doctor():
		btn.text = "医生已是最高水平"
	btn.pressed.connect(func():
		if b.upgrade_doctor():
			GameState.notice.emit("聘请了更好的医生"))
	content.add_child(btn)
