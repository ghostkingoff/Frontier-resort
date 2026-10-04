extends CanvasLayer
## 属性与打造面板：用探索物资提升自身属性，并制作探索用消耗品。

var panel: PanelContainer
var content: VBoxContainer


func _ready() -> void:
	var root := UIKit.root_control()
	add_child(root)

	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 240
	panel.offset_right = -240
	panel.offset_top = 100
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

	GameState.money_changed.connect(func(_value): _refresh_if_open())
	GameState.inventory_changed.connect(_refresh_if_open)
	PlayerStats.stats_changed.connect(_refresh_if_open)
	PlayerStats.consumables_changed.connect(_refresh_if_open)


func toggle() -> void:
	panel.visible = not panel.visible
	if panel.visible:
		_refresh()


func close() -> void:
	panel.visible = false


func is_open() -> bool:
	return panel != null and panel.visible


func _refresh_if_open() -> void:
	if is_open():
		_refresh()


func _refresh() -> void:
	for child in content.get_children():
		child.queue_free()
	content.add_child(UIKit.label("属性与打造", 40, Color(0.98, 0.88, 0.55)))
	content.add_child(UIKit.label("体力 %.0f / %.0f ｜ SAN %.0f / %.0f ｜ 体力每天回满，SAN 恢复较慢" % [
		PlayerStats.stamina, PlayerStats.stamina_max(), PlayerStats.san, PlayerStats.san_max()],
		22, Color(0.85, 0.92, 1.0)))
	if PlayerStats.all_maxed():
		content.add_child(UIKit.label("全部属性已满级：可以尝试进入边境最深处。", 24, Color(0.7, 0.95, 0.7)))
	content.add_child(UIKit.spacer(6))
	content.add_child(UIKit.label("—— 自身属性 ——", 26, Color(0.95, 0.85, 0.5)))
	for id in DataRegistry.attribute_order:
		_add_attribute_row(id)
	content.add_child(UIKit.spacer(8))
	content.add_child(UIKit.label("—— 打造消耗品 ——", 26, Color(0.95, 0.85, 0.5)))
	for id in DataRegistry.consumable_order:
		_add_consumable_row(id)
	content.add_child(UIKit.spacer(10))
	var close_button := UIKit.button("关闭", Vector2(160, 54))
	close_button.pressed.connect(close)
	content.add_child(close_button)


func _add_attribute_row(id: String) -> void:
	var a := DataRegistry.get_attribute(id)
	var lv := PlayerStats.level(id)
	var max_lv := PlayerStats.max_level(id)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(UIKit.label("%s  Lv.%d / %d" % [str(a.get("name", id)), lv, max_lv], 24, Color(0.95, 0.9, 0.75)))
	box.add_child(UIKit.label(str(a.get("desc", "")), 20, Color(0.82, 0.84, 0.9)))
	if lv < max_lv:
		var costs: Array = [GameState.format_money(PlayerStats.upgrade_money_cost(id))]
		for item_id in PlayerStats.upgrade_items(id).keys():
			costs.append("%s×%d" % [DataRegistry.item_name(item_id), int(PlayerStats.upgrade_items(id)[item_id])])
		box.add_child(UIKit.label("下一级需要：" + " ｜ ".join(costs), 20, Color(0.85, 0.9, 0.95)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var upgrade := UIKit.button("升级", Vector2(140, 50))
	upgrade.disabled = not PlayerStats.can_upgrade(id)
	if upgrade.disabled and lv < max_lv:
		upgrade.text = PlayerStats.upgrade_block_reason(id)
	if lv >= max_lv:
		upgrade.text = "已满级"
	upgrade.pressed.connect(func():
		if PlayerStats.upgrade(id):
			GameState.notice.emit("%s 提升到 Lv.%d" % [str(a.get("name", id)), PlayerStats.level(id)]))
	row.add_child(upgrade)
	box.add_child(row)
	box.add_child(UIKit.spacer(4))
	content.add_child(box)


func _add_consumable_row(id: String) -> void:
	var c := DataRegistry.get_consumable(id)
	var recipe: Dictionary = c.get("recipe", {})
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(UIKit.icon(str(c.get("icon", "")), Vector2(40, 40)))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UIKit.label("%s ｜ 持有 %d" % [str(c.get("name", id)), PlayerStats.consumable_count(id)], 22, Color(0.95, 0.9, 0.75)))
	var cost_text := "材料：" + GameState.format_money(int(recipe.get("money", 0)))
	for item_id in (recipe.get("items", {}) as Dictionary).keys():
		cost_text += " ｜ %s×%d" % [DataRegistry.item_name(item_id), int(recipe["items"][item_id])]
	col.add_child(UIKit.label(cost_text, 19, Color(0.82, 0.84, 0.9)))
	col.add_child(UIKit.label(str(c.get("desc", "")), 19, Color(0.75, 0.85, 0.8)))
	row.add_child(col)
	var craft := UIKit.button("打造", Vector2(120, 50))
	craft.disabled = PlayerStats.craft_block_reason(id) != ""
	if craft.disabled:
		craft.text = PlayerStats.craft_block_reason(id)
	craft.pressed.connect(func():
		if PlayerStats.craft_consumable(id):
			GameState.notice.emit("打造了 %s" % str(c.get("name", id))))
	row.add_child(craft)
	content.add_child(row)
