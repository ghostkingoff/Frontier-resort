extends Node
## 全局静态配置表：建筑、顾客类型、装饰与地面贴图。
## 所有内容都放在 res://data/*.json 里，扩充内容不需要改代码。

const SPRITE_SCALE := 2.0      # 占位素材 16px → 正式规格 32px，统一放大 2 倍

const BUILDINGS_PATH := "res://data/buildings.json"
const BUILDINGS_EXTRA_PATH := "res://data/buildings_extra.json"
const CUSTOMERS_PATH := "res://data/customers.json"
const SPRITES_PATH := "res://data/sprites.json"
const ITEMS_PATH := "res://data/items.json"
const ILLNESS_PATH := "res://data/illnesses.json"
const ATTRIBUTES_PATH := "res://data/attributes.json"
const EXPLORATION_PATH := "res://data/exploration.json"
const EVENTS_PATH := "res://data/exploration_events.json"
const LIGHTING_PATH := "res://data/lighting.json"
const TERRAINS_PATH := "res://data/terrains.json"

var categories: Dictionary = {}
var category_order: Array = []
var buildings: Dictionary = {}
var building_order: Array = []
var customer_types: Array = []
var customer_tags: Dictionary = {}
var sprites: Dictionary = {}
var items: Dictionary = {}
var item_order: Array = []
var rarities: Dictionary = {}
var rarity_order: Array = []
var illnesses: Dictionary = {}
var illness_order: Array = []
var illness_config: Dictionary = {}
var attributes: Dictionary = {}
var attribute_order: Array = []
var consumables: Dictionary = {}
var consumable_order: Array = []
var exploration_settings: Dictionary = {}
var exploration_events: Array = []
var events_by_zone: Dictionary = {}
var lighting_keyframes: Array = []
var terrains: Dictionary = {}
var terrain_order: Array = []

func _ready() -> void:
	_load_buildings()
	_load_customers()
	_sprites_load()
	_load_items()
	_load_illnesses()
	_load_attributes()
	_load_exploration()
	_load_lighting()
	_load_terrains()


func _load_buildings() -> void:
	var raw := _read_json(BUILDINGS_PATH)
	for item in raw.get("categories", []):
		categories[item["id"]] = item
		category_order.append(item["id"])
	for item in raw.get("buildings", []):
		buildings[item["id"]] = item
		building_order.append(item["id"])
	# 扩充建筑放在单独文件里：即使它有问题，也不会影响原有建筑表
	var extra := _read_json(BUILDINGS_EXTRA_PATH)
	for item in extra.get("buildings", []):
		var id := str(item.get("id", ""))
		if id == "":
			continue
		if not buildings.has(id):
			building_order.append(id)
		buildings[id] = item
	_check_shadowed_buildings(raw, extra)
	print("[DataRegistry] 建筑 %d 种，分类 %d 个" % [building_order.size(), category_order.size()])


func _check_shadowed_buildings(main: Dictionary, extra: Dictionary) -> void:
	# 两处都定义了同名 id 时，扩充表的定义会静默生效，
	# 主表那份就变成了「改了数据却没反应」的陷阱。这里主动报出来。
	# 注：剩下这两条是有意保留的——旧存档里存的是同一批 id，主表那份还负责把老建筑解析出来，
	# 所以不能删、也不能改 id（改了旧档里的边境酒吧/边境诊所就会消失）。
	var main_names: Dictionary = {}
	for item in main.get("buildings", []):
		main_names[str(item.get("id", ""))] = str(item.get("name", ""))
	var shadowed: Array = []
	for item in extra.get("buildings", []):
		var id := str(item.get("id", ""))
		if main_names.has(id):
			shadowed.append("%s（主表 %s → 扩充表 %s）" % [id, main_names[id], str(item.get("name", ""))])
	if not shadowed.is_empty():
		print("[DataRegistry] 同名建筑 id %d 个，生效的是扩充表那份：%s" % [shadowed.size(), "；".join(shadowed)])


func _load_customers() -> void:
	var raw := _read_json(CUSTOMERS_PATH)
	customer_tags = raw.get("tags", {})
	customer_types = raw.get("guests", [])
	print("[DataRegistry] 游客名册 %d 组（停留 %d ｜ 人数 %d ｜ 身份 %d 个标签）" % [
		customer_types.size(),
		(customer_tags.get("stay", []) as Array).size(),
		(customer_tags.get("party", []) as Array).size(),
		(customer_tags.get("identity", []) as Array).size()])


func _sprites_load() -> void:
	sprites = _read_json(SPRITES_PATH)


func _load_items() -> void:
	var raw := _read_json(ITEMS_PATH)
	for r in raw.get("rarities", []):
		rarities[r["id"]] = r
		rarity_order.append(r["id"])
	for item in raw.get("items", []):
		items[item["id"]] = item
		item_order.append(item["id"])
	print("[DataRegistry] 物资 %d 种，品质 %d 级" % [item_order.size(), rarity_order.size()])


func _load_illnesses() -> void:
	var raw := _read_json(ILLNESS_PATH)
	illness_config = raw.get("config", {})
	for ill in raw.get("illnesses", []):
		illnesses[ill["id"]] = ill
		illness_order.append(ill["id"])
	print("[DataRegistry] 病症 %d 种" % illness_order.size())


func _load_attributes() -> void:
	var raw := _read_json(ATTRIBUTES_PATH)
	for a in raw.get("attributes", []):
		attributes[a["id"]] = a
		attribute_order.append(a["id"])
	for c in raw.get("consumables", []):
		consumables[c["id"]] = c
		consumable_order.append(c["id"])
	print("[DataRegistry] 属性 %d 项，消耗品 %d 种" % [attribute_order.size(), consumable_order.size()])


func _load_exploration() -> void:
	var raw := _read_json(EXPLORATION_PATH)
	exploration_settings = raw.get("settings", {})
	var ev := _read_json(EVENTS_PATH)
	exploration_events = ev.get("events", [])
	for e in exploration_events:
		var zone := str(e.get("zone", "low"))
		if not events_by_zone.has(zone):
			events_by_zone[zone] = []
		events_by_zone[zone].append(e)
	print("[DataRegistry] 探索事件 %d 个（低危 %d ｜ 高危 %d ｜ 深处 %d）" % [
		exploration_events.size(),
		(events_by_zone.get("low", []) as Array).size(),
		(events_by_zone.get("high", []) as Array).size(),
		(events_by_zone.get("deep", []) as Array).size()])


func get_attribute(id: String) -> Dictionary:
	return attributes.get(id, {})


func get_consumable(id: String) -> Dictionary:
	return consumables.get(id, {})


func events_for_zone(zone: String) -> Array:
	return events_by_zone.get(zone, [])


func _load_lighting() -> void:
	var raw := _read_json(LIGHTING_PATH)
	lighting_keyframes.clear()
	for k in raw.get("keyframes", []):
		lighting_keyframes.append({
			"hour": float(k.get("hour", 0.0)),
			"color": Color.from_string(str(k.get("color", "#ffffff")), Color.WHITE),
		})
	lighting_keyframes.sort_custom(func(a, b): return float(a["hour"]) < float(b["hour"]))
	print("[DataRegistry] 光照关键帧 %d 个" % lighting_keyframes.size())


func _load_terrains() -> void:
	var raw := _read_json(TERRAINS_PATH)
	for t in raw.get("terrains", []):
		terrains[t["id"]] = t
		terrain_order.append(t["id"])
	print("[DataRegistry] 地形 %d 种" % terrain_order.size())


func get_terrain(id: String) -> Dictionary:
	return terrains.get(id, {})


func terrain_name(id: String) -> String:
	return str(terrains.get(id, {}).get("name", id))


func terrain_color(id: String) -> Color:
	return Color.from_string(str(terrains.get(id, {}).get("color", "#666666")), Color(0.4, 0.4, 0.4))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[DataRegistry] 缺少配置文件：%s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[DataRegistry] 配置格式错误：%s" % path)
		return {}
	return parsed


func get_building(id: String) -> Dictionary:
	return buildings.get(id, {})


func get_category_color(id: String) -> Color:
	var c: Dictionary = categories.get(id, {})
	return Color.from_string(str(c.get("color", "#ffffff")), Color.WHITE)


func decorations() -> Array:
	return sprites.get("decorations", [])


func ground_config() -> Dictionary:
	return sprites.get("ground", {})


func item_name(id: String) -> String:
	return str(items.get(id, {}).get("name", id))


func item_value(id: String) -> int:
	return int(items.get(id, {}).get("value", 0))


func item_icon(id: String) -> String:
	return str(items.get(id, {}).get("icon", ""))


func item_rarity(id: String) -> Dictionary:
	var rid := str(items.get(id, {}).get("rarity", "common"))
	return rarities.get(rid, {})


func rarity_weight(id: String) -> int:
	return int(item_rarity(id).get("weight", 1))


func rarity_color(id: String) -> Color:
	return Color.from_string(str(item_rarity(id).get("color", "#ffffff")), Color.WHITE)


func items_by_rarity(rarity_id: String) -> Array:
	var out: Array = []
	for id in item_order:
		if str(items[id].get("rarity", "")) == rarity_id:
			out.append(id)
	return out


func illness_pool(max_level: int) -> Array:
	var out: Array = []
	for id in illness_order:
		var ill: Dictionary = illnesses[id]
		if int(ill.get("level", 1)) <= max_level:
			var weight := int(ill.get("weight", 1))
			for _i in range(weight):
				out.append(ill)
	return out
