extends CanvasLayer
## 仓库面板：查看探索所得物资，一键低价倾销给内陆商人。

const DUMP_RATE := 0.35   # 倾销价 = 价值的 35%

var panel: PanelContainer
var content: VBoxContainer


func _ready() -> void:
	var root := UIKit.root_control()
	add_child(root)

	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.offset_left = 16
	panel.offset_right = 560
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

	GameState.inventory_changed.connect(_refresh_if_open)


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

	content.add_child(UIKit.label("仓库物资", 32, Color(0.98, 0.88, 0.55)))
	content.add_child(UIKit.label("合计价值 %s ｜ 共 %d 种" % [
		GameState.format_money(GameState.inventory_value()), GameState.inventory.size()], 22, Color(0.85, 0.92, 1.0)))
	content.add_child(UIKit.label("倾销给内陆商人只能拿到 %d%% 的价格，用于清理滞销物资。" % int(DUMP_RATE * 100), 20, Color(0.85, 0.85, 0.9)))
	content.add_child(UIKit.spacer(6))

	var entries := GameState.sorted_inventory()
	if entries.is_empty():
		content.add_child(UIKit.label("仓库是空的（夜间探索会带回物资）", 20, Color(0.8, 0.8, 0.85)))
	for entry in entries:
		var item_id := str(entry.get("id", ""))
		var count := int(entry.get("count", 0))
		var unit := int(round(float(DataRegistry.item_value(item_id)) * DUMP_RATE * PlayerStats.bargain_multiplier()))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(UIKit.icon(DataRegistry.item_icon(item_id), Vector2(38, 38)))
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(UIKit.label("%s ×%d" % [DataRegistry.item_name(item_id), count], 22, DataRegistry.rarity_color(item_id)))
		col.add_child(UIKit.label("单价 %s ｜ 倾销 %s" % [
			GameState.format_money(DataRegistry.item_value(item_id)), GameState.format_money(unit)], 18, Color(0.82, 0.82, 0.88)))
		row.add_child(col)
		var one := UIKit.button("卖 1", Vector2(88, 48))
		one.pressed.connect(func(): _dump(item_id, 1, unit))
		row.add_child(one)
		var all := UIKit.button("全卖", Vector2(96, 48))
		all.pressed.connect(func(): _dump(item_id, GameState.item_count(item_id), unit))
		row.add_child(all)
		content.add_child(row)

	content.add_child(UIKit.spacer(8))
	var close_button := UIKit.button("关闭", Vector2(140, 52))
	close_button.pressed.connect(close)
	content.add_child(close_button)


func _dump(item_id: String, count: int, unit_price: int) -> void:
	if count <= 0:
		return
	if unit_price <= 0:
		GameState.notice.emit("%s 不能卖给内陆商人" % DataRegistry.item_name(item_id))
		return
	if not GameState.remove_item(item_id, count):
		return
	var total := unit_price * count
	GameState.earn(total, "内陆倾销")
	GameState.notice.emit("倾销 %s ×%d，收入 %s" % [DataRegistry.item_name(item_id), count, GameState.format_money(total)])
