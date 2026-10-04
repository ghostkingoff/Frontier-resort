extends Node
## 主角属性：体力 / SAN / 采集 / 运气 / 议价 / 声望，以及探索消耗品。
## 属性用探索物资在「属性与打造」面板里升级，同时影响探索与经营。

signal stats_changed
signal consumables_changed

var levels: Dictionary = {}        # 属性 id -> 已升级次数
var stamina: float = 100.0
var san: float = 100.0
var consumables: Dictionary = {}   # 消耗品 id -> 数量
var achievements: Dictionary = {}  # 成就道具 id -> true


func _ready() -> void:
	reset()


func reset() -> void:
	levels.clear()
	for id in DataRegistry.attribute_order:
		levels[id] = 0
	consumables.clear()
	achievements.clear()
	stamina = stamina_max()
	san = san_max()
	stats_changed.emit()
	consumables_changed.emit()


# ---------- 数值 ----------

func level(id: String) -> int:
	return int(levels.get(id, 0))


func max_level(id: String) -> int:
	return int(DataRegistry.get_attribute(id).get("max_level", 5))


func is_maxed(id: String) -> bool:
	return level(id) >= max_level(id)


func all_maxed() -> bool:
	for id in DataRegistry.attribute_order:
		if not is_maxed(id):
			return false
	return true


func value_of(id: String) -> float:
	var a := DataRegistry.get_attribute(id)
	var base := float(a.get("base", 0.0))
	var per := float(a.get("per_level", 0.0))
	return base + per * float(level(id))


func stamina_max() -> float:
	return value_of("stamina")


func san_max() -> float:
	return value_of("san")


func gather_multiplier() -> float:
	return value_of("gather")


func luck_bonus() -> float:
	return value_of("luck")


func bargain_multiplier() -> float:
	return value_of("bargain")


func fame_multiplier() -> float:
	return value_of("fame")


# ---------- 升级 ----------

func upgrade_money_cost(id: String) -> int:
	var a := DataRegistry.get_attribute(id)
	var per := int(a.get("money_per_level", 300))
	return per * (level(id) + 1)


func upgrade_items(id: String) -> Dictionary:
	var a := DataRegistry.get_attribute(id)
	var table: Dictionary = a.get("items", {})
	var out: Dictionary = {}
	var lv := level(id)
	for item_id in table.keys():
		var spec: Array = table[item_id]
		var base := int(spec[0]) if spec.size() > 0 else 1
		var per := int(spec[1]) if spec.size() > 1 else 0
		out[item_id] = base + per * lv
	return out


func upgrade_block_reason(id: String) -> String:
	if is_maxed(id):
		return "已经满级"
	if not GameState.can_afford(upgrade_money_cost(id)):
		return "资金不足"
	for item_id in upgrade_items(id).keys():
		var need := int(upgrade_items(id)[item_id])
		if GameState.item_count(item_id) < need:
			return "缺少 %s ×%d" % [DataRegistry.item_name(item_id), need - GameState.item_count(item_id)]
	return ""


func can_upgrade(id: String) -> bool:
	return upgrade_block_reason(id) == ""


func upgrade(id: String) -> bool:
	if not can_upgrade(id):
		return false
	GameState.spend(upgrade_money_cost(id), "属性升级")
	for item_id in upgrade_items(id).keys():
		GameState.remove_item(item_id, int(upgrade_items(id)[item_id]))
	levels[id] = level(id) + 1
	# 升级体力/SAN 上限时，当前值一起提高
	if id == "stamina":
		stamina = stamina_max()
	if id == "san":
		san = san_max()
	stats_changed.emit()
	return true


# ---------- 体力与 SAN ----------

func daily_restore() -> void:
	# 体力每天回满，SAN 恢复得慢一些
	var san_gain := float(DataRegistry.exploration_settings.get("san_restore_per_day", 25))
	stamina = stamina_max()
	san = clampf(san + san_gain, 0.0, san_max())
	stats_changed.emit()


# ---------- 消耗品 ----------

func add_consumable(id: String, count: int = 1) -> void:
	if id == "" or count <= 0:
		return
	consumables[id] = int(consumables.get(id, 0)) + count
	consumables_changed.emit()


func consumable_count(id: String) -> int:
	return int(consumables.get(id, 0))


func remove_consumable(id: String, count: int = 1) -> bool:
	if consumable_count(id) < count:
		return false
	consumables[id] = consumable_count(id) - count
	if int(consumables[id]) <= 0:
		consumables.erase(id)
	consumables_changed.emit()
	return true


func craft_consumable(id: String) -> bool:
	var c := DataRegistry.get_consumable(id)
	if c.is_empty():
		return false
	var recipe: Dictionary = c.get("recipe", {})
	var money := int(recipe.get("money", 0))
	if not GameState.can_afford(money):
		return false
	var items: Dictionary = recipe.get("items", {})
	for item_id in items.keys():
		if GameState.item_count(item_id) < int(items[item_id]):
			return false
	GameState.spend(money, "打造消耗品")
	for item_id in items.keys():
		GameState.remove_item(item_id, int(items[item_id]))
	add_consumable(id, 1)
	return true


func craft_block_reason(id: String) -> String:
	var c := DataRegistry.get_consumable(id)
	var recipe: Dictionary = c.get("recipe", {})
	if not GameState.can_afford(int(recipe.get("money", 0))):
		return "资金不足"
	for item_id in (recipe.get("items", {}) as Dictionary).keys():
		var need := int(recipe["items"][item_id])
		if GameState.item_count(item_id) < need:
			return "缺少 %s ×%d" % [DataRegistry.item_name(item_id), need - GameState.item_count(item_id)]
	return ""


# ---------- 存档 ----------

func to_dict() -> Dictionary:
	return {
		"levels": levels,
		"stamina": stamina,
		"san": san,
		"consumables": consumables,
		"achievements": achievements,
	}


func apply_dict(d: Dictionary) -> void:
	levels = d.get("levels", {})
	for id in DataRegistry.attribute_order:
		if not levels.has(id):
			levels[id] = 0
	stamina = float(d.get("stamina", stamina_max()))
	san = float(d.get("san", san_max()))
	consumables = d.get("consumables", {})
	achievements = d.get("achievements", {})
	stats_changed.emit()
	consumables_changed.emit()
