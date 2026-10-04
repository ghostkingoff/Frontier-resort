extends Node
## 夜晚探索（当前只做低危区）：
## 每次出发随机生成一张世界地图（由方块地形拼成，形状不规则），
## 玩家在当前地形里按格子移动、随机触发事件，走到边界按方向出图，
## 经过十字形过渡区（帐篷 / 有概率的商人）进入相邻地形。

signal state_changed
signal map_changed
signal run_finished(result: String, summary: Dictionary)

const STATE_MAP := "map"
const STATE_TRANSITION := "transition"
const STATE_EVENT := "event"
const STATE_RESULT := "result"

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var active := false
var ended := false
var state := STATE_MAP

var stamina := 0.0
var san := 0.0
var loot: Dictionary = {}
var grey_stones := 0
var luck_bonus := 0.0
var san_shield := 0

# 世界地图
var world_map: Dictionary = {}        # Vector2i -> { terrain: String, revealed: bool }
var current_tile := Vector2i.ZERO
var start_tile := Vector2i.ZERO
var local_maps: Dictionary = {}       # tile -> { cells: { cell: { visited: bool } }, entry: Vector2i }
var player_cell := Vector2i.ZERO

# 过渡区
var transition: Dictionary = {}
var transition_cell := Vector2i.ZERO
var trade_offers: Array = []

# 事件
var current_event: Dictionary = {}
var last_text := ""
var end_result := ""
var end_text := ""
var show_world := false

var _used_events: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func settings() -> Dictionary:
	return DataRegistry.exploration_settings


func _ready() -> void:
	_rng.randomize()


func reset() -> void:
	active = false
	ended = false
	state = STATE_MAP
	show_world = false
	stamina = 0.0
	san = 0.0
	loot.clear()
	grey_stones = 0
	luck_bonus = 0.0
	san_shield = 0
	local_maps.clear()
	world_map.clear()
	transition.clear()
	trade_offers.clear()
	current_event = {}
	last_text = ""
	end_result = ""
	end_text = ""
	state_changed.emit()


# ---------- 出发 ----------

func start_run() -> void:
	SaveManager.save_game(SaveManager.explore_slot())
	active = true
	ended = false
	state = STATE_MAP
	show_world = false
	end_result = ""
	end_text = ""
	stamina = PlayerStats.stamina
	san = PlayerStats.san
	loot.clear()
	grey_stones = 0
	luck_bonus = 0.0
	san_shield = 0
	_used_events.clear()
	local_maps.clear()
	transition.clear()
	trade_offers.clear()
	current_event = {}
	_generate_world()
	_reveal(start_tile)
	current_tile = start_tile
	var local := _local_map_for(current_tile, Vector2i(0, -1))
	player_cell = local["entry"]
	last_text = "你从度假村出发，走进了%s。" % DataRegistry.terrain_name(terrain_at(start_tile))
	state_changed.emit()
	map_changed.emit()


func toggle_world() -> void:
	show_world = not show_world
	map_changed.emit()


# ---------- 世界地图生成 ----------

func _generate_world() -> void:
	world_map.clear()
	var cols := int(settings().get("world_cols", 6))
	var rows := int(settings().get("world_rows", 7))
	var want := _rng.randi_range(int(settings().get("world_cells_min", 15)), int(settings().get("world_cells_max", 21)))
	want = mini(want, cols * rows)
	start_tile = Vector2i(int(cols / 2), rows - 1)
	var cells := {start_tile: true}
	var frontier: Array = [start_tile]
	while cells.size() < want and not frontier.is_empty():
		var base: Vector2i = frontier[_rng.randi() % frontier.size()]
		var options: Array = []
		for d in DIRS:
			var n: Vector2i = base + d
			if n.x < 0 or n.y < 0 or n.x >= cols or n.y >= rows:
				continue
			if cells.has(n):
				continue
			options.append(n)
		if options.is_empty():
			frontier.erase(base)
			continue
		var pick: Vector2i = options[_rng.randi() % options.size()]
		cells[pick] = true
		frontier.append(pick)
	# 地形分配：相邻更容易是同一种地形，看起来更自然
	var order: Array = cells.keys()
	_shuffle(order)
	for cell in order:
		var terrain := ""
		for d in DIRS:
			var n: Vector2i = cell + d
			if world_map.has(n) and _rng.randf() < 0.55:
				terrain = str(world_map[n]["terrain"])
				break
		if terrain == "":
			var ids := DataRegistry.terrain_order
			terrain = str(ids[_rng.randi() % ids.size()])
		world_map[cell] = {"terrain": terrain, "revealed": false}


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi() % (i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _reveal(tile: Vector2i) -> void:
	if world_map.has(tile):
		world_map[tile]["revealed"] = true
	for d in DIRS:
		var n: Vector2i = tile + d
		if world_map.has(n):
			world_map[n]["revealed"] = true


func terrain_at(tile: Vector2i) -> String:
	return str(world_map.get(tile, {}).get("terrain", ""))


func is_revealed(tile: Vector2i) -> bool:
	return bool(world_map.get(tile, {}).get("revealed", false))


# ---------- 局部地图 ----------

func _local_map_for(tile: Vector2i, travel_dir: Vector2i) -> Dictionary:
	if local_maps.has(tile):
		return local_maps[tile]
	var cols := int(settings().get("local_cols", 5))
	var rows := int(settings().get("local_rows", 5))
	var want := _rng.randi_range(int(settings().get("local_cells_min", 9)), int(settings().get("local_cells_max", 15)))
	want = mini(want, cols * rows)
	var entry := _entry_cell(travel_dir, cols, rows)
	var cells := {entry: true}
	var frontier: Array = [entry]
	while cells.size() < want and not frontier.is_empty():
		var base: Vector2i = frontier[_rng.randi() % frontier.size()]
		var options: Array = []
		for d in DIRS:
			var n: Vector2i = base + d
			if n.x < 0 or n.y < 0 or n.x >= cols or n.y >= rows:
				continue
			if cells.has(n):
				continue
			options.append(n)
		if options.is_empty():
			frontier.erase(base)
			continue
		var pick: Vector2i = options[_rng.randi() % options.size()]
		cells[pick] = true
		frontier.append(pick)
	var map := {}
	for c in cells.keys():
		map[c] = {"visited": false}
	map[entry] = {"visited": true}
	var data := {"cells": map, "entry": entry}
	local_maps[tile] = data
	return data


func _entry_cell(travel_dir: Vector2i, cols: int, rows: int) -> Vector2i:
	# 往左走就从这个地形的右边进入，依此类推
	if travel_dir.x < 0:
		return Vector2i(cols - 1, int(rows / 2))
	if travel_dir.x > 0:
		return Vector2i(0, int(rows / 2))
	if travel_dir.y > 0:
		return Vector2i(int(cols / 2), 0)
	return Vector2i(int(cols / 2), rows - 1)


func current_local_map() -> Dictionary:
	var data: Dictionary = local_maps.get(current_tile, {})
	return data.get("cells", {})


func is_cell_visited(cell: Vector2i) -> bool:
	return bool(current_local_map().get(cell, {}).get("visited", false))


func can_exit_from(cell: Vector2i, dir: Vector2i) -> bool:
	return not current_local_map().has(cell + dir)


func exits() -> Array:
	var out: Array = []
	for d in DIRS:
		var target: Vector2i = current_tile + d
		if not world_map.has(target):
			continue
		if not can_exit_from(player_cell, d):
			continue
		out.append({"dir": d, "tile": target, "terrain": terrain_at(target)})
	return out


func neighbor_exits() -> Array:
	# 不管站在哪里，都列出这个地形四周有什么，用来提示方向
	var out: Array = []
	for d in DIRS:
		var target: Vector2i = current_tile + d
		if not world_map.has(target):
			continue
		out.append({
			"dir": d,
			"tile": target,
			"terrain": terrain_at(target),
			"ready": can_exit_from(player_cell, d),
		})
	return out


# ---------- 局部移动 ----------

func move_to(cell: Vector2i) -> void:
	if not active or ended or state != STATE_MAP:
		return
	var cells := current_local_map()
	if not cells.has(cell):
		return
	if not _is_adjacent(player_cell, cell):
		last_text = "只能走到相邻的格子上。"
		state_changed.emit()
		return
	var visited := bool(cells[cell].get("visited", false))
	var cost := float(settings().get("step_cost_visited" if visited else "step_cost_new", 2))
	stamina = maxf(0.0, stamina - cost)
	player_cell = cell
	cells[cell]["visited"] = true
	var messages: Array = []
	if not visited:
		var found := _find_grey_stone()
		if found > 0:
			messages.append("捡到灰石 ×%d" % found)
	map_changed.emit()
	if _check_depletion():
		return
	var chance := float(settings().get("event_chance_revisit" if visited else "event_chance_new", 0.5))
	if _rng.randf() < chance:
		_trigger_event(messages)
		return
	if not messages.is_empty():
		last_text = "、".join(messages)
	state_changed.emit()


func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return absi(a.x - b.x) + absi(a.y - b.y) == 1


func _find_grey_stone() -> int:
	var terrain := DataRegistry.get_terrain(terrain_at(current_tile))
	if _rng.randf() > float(terrain.get("grey_chance", 0.5)):
		return 0
	var amount: Array = terrain.get("grey_amount", [1, 1])
	var n := _rng.randi_range(int(amount[0]), int(amount[1]))
	grey_stones += n
	return n


# ---------- 过渡区 ----------

func exit_to(dir: Vector2i) -> void:
	if not active or ended or state != STATE_MAP:
		return
	var target: Vector2i = current_tile + dir
	if not world_map.has(target):
		last_text = "这个方向没有路了。"
		state_changed.emit()
		return
	if not can_exit_from(player_cell, dir):
		last_text = "要先走到这张图的边缘，才能从这边出图。"
		state_changed.emit()
		return
	_setup_transition(current_tile, target, dir)
	state = STATE_TRANSITION
	last_text = "你走出了%s，前面是一小片过渡地带。" % DataRegistry.terrain_name(terrain_at(current_tile))
	map_changed.emit()
	state_changed.emit()


func _setup_transition(from_tile: Vector2i, to_tile: Vector2i, dir: Vector2i) -> void:
	var horizontal := dir.x != 0
	var sides := [Vector2i(0, 1), Vector2i(0, -1)] if horizontal else [Vector2i(1, 0), Vector2i(-1, 0)]
	var tent_dir: Vector2i = sides[_rng.randi() % 2]
	var merchant_dir: Vector2i = sides[1] if tent_dir == sides[0] else sides[0]
	transition = {
		"from": from_tile,
		"to": to_tile,
		"dir": dir,
		"entry": -dir,
		"exit": dir,
		"tent": tent_dir,
		"merchant": merchant_dir,
		"has_merchant": _rng.randf() < float(settings().get("merchant_chance", 0.4)),
		"tent_used": false,
	}
	transition_cell = -dir
	trade_offers.clear()


func transition_cells() -> Array:
	if transition.is_empty():
		return []
	return [
		Vector2i.ZERO,
		transition["entry"],
		transition["exit"],
		transition["tent"],
		transition["merchant"],
	]


func transition_move(cell: Vector2i) -> void:
	if state != STATE_TRANSITION or ended:
		return
	if not transition_cells().has(cell):
		return
	if cell == transition_cell:
		return
	# 十字形：从一个臂到另一个臂必须先经过中间的空地
	if cell != Vector2i.ZERO and transition_cell != Vector2i.ZERO:
		last_text = "得先走到中间的空地。"
		state_changed.emit()
		return
	transition_cell = cell
	if cell == transition["exit"]:
		_enter_terrain(transition["to"], transition["dir"])
		return
	last_text = _transition_cell_text(cell)
	map_changed.emit()
	state_changed.emit()


func _transition_cell_text(cell: Vector2i) -> String:
	if cell == Vector2i.ZERO:
		return "中间是一片空地，风从缺口吹过去。"
	if cell == transition.get("tent"):
		return "一顶旧帐篷支在这里，看样子是边境人留下的。"
	if cell == transition.get("merchant"):
		if bool(transition.get("has_merchant", false)):
			return "一个提着货箱的怪物坐在这里，它看着你，眼神很清醒。"
		return "这边什么都没有。"
	return ""


func tent_ready() -> bool:
	return state == STATE_TRANSITION and transition_cell == transition.get("tent") and not bool(transition.get("tent_used", false))


func tent_action(kind: String) -> void:
	if state != STATE_TRANSITION or bool(transition.get("tent_used", false)):
		return
	if transition_cell != transition.get("tent"):
		last_text = "要先走到帐篷那一格。"
		state_changed.emit()
		return
	transition["tent_used"] = true
	if kind == "rest":
		var gain := int(settings().get("tent_rest_stamina", 3))
		stamina = minf(PlayerStats.stamina_max(), stamina + float(gain))
		last_text = "你在帐篷里眯了一会儿，体力 +%d。" % gain
	else:
		var gain := int(settings().get("tent_meditate_san", 2))
		san = minf(PlayerStats.san_max(), san + float(gain))
		last_text = "你闭眼静坐，边境的杂音退开了，SAN +%d。" % gain
	state_changed.emit()


# ---------- 商人 ----------

func merchant_ready() -> bool:
	return state == STATE_TRANSITION and bool(transition.get("has_merchant", false)) and transition_cell == transition.get("merchant")


func roll_trade_offers() -> void:
	if not merchant_ready():
		return
	trade_offers.clear()
	var pools := [
		{"rarity": "uncommon", "cost": [2, 3]},
		{"rarity": "rare", "cost": [4, 6]},
		{"rarity": "epic", "cost": [8, 12]},
	]
	for pool in pools:
		var items: Array = DataRegistry.items_by_rarity(str(pool["rarity"]))
		if items.is_empty():
			continue
		var item_id := str(items[_rng.randi() % items.size()])
		var cost_range: Array = pool["cost"]
		trade_offers.append({
			"item": item_id,
			"cost": _rng.randi_range(int(cost_range[0]), int(cost_range[1])),
			"sold": false,
		})
	state_changed.emit()


func buy_offer(index: int) -> void:
	if index < 0 or index >= trade_offers.size():
		return
	var offer: Dictionary = trade_offers[index]
	if bool(offer.get("sold", false)):
		return
	var cost := int(offer.get("cost", 0))
	if grey_stones < cost:
		last_text = "灰石不够，商人摇了摇头。"
		state_changed.emit()
		return
	grey_stones -= cost
	offer["sold"] = true
	var item_id := str(offer.get("item", ""))
	loot[item_id] = int(loot.get(item_id, 0)) + 1
	last_text = "你用 %d 块灰石换到了 %s。" % [cost, DataRegistry.item_name(item_id)]
	state_changed.emit()


# ---------- 事件 ----------

func _trigger_event(intro: Array = []) -> void:
	var pool: Array = DataRegistry.events_for_zone("low")
	if pool.is_empty():
		return
	var fresh: Array = []
	for e in pool:
		if not _used_events.has(str(e.get("id", ""))):
			fresh.append(e)
	if fresh.is_empty():
		_used_events.clear()
		fresh = pool
	current_event = fresh[_rng.randi() % fresh.size()]
	_used_events[str(current_event.get("id", ""))] = true
	var prefix := ""
	if not intro.is_empty():
		prefix = "、".join(intro) + "\n"
	last_text = prefix + str(current_event.get("text", ""))
	state = STATE_EVENT
	state_changed.emit()


func choose(index: int) -> void:
	if state != STATE_EVENT or ended:
		return
	var options: Array = current_event.get("options", [])
	if index < 0 or index >= options.size():
		return
	var option: Dictionary = options[index]
	var text := str(option.get("result", ""))
	stamina = maxf(0.0, stamina - float(option.get("stamina", 0)))
	san = _pay_san(float(option.get("san", 0)))
	if _check_depletion():
		last_text = text + "\n\n" + end_text
		state_changed.emit()
		return

	var risk: Dictionary = option.get("risk", {})
	if not risk.is_empty():
		var chance := maxf(0.0, float(risk.get("chance", 0.0)) - (PlayerStats.luck_bonus() + luck_bonus) * 0.5)
		if _rng.randf() < chance:
			text += "\n\n" + str(risk.get("text", ""))
			if str(risk.get("type", "")) == "monster":
				# 低危区不会致死，只是被狠狠吓一跳
				text += "\n\n你连滚带爬地退开，它没有追出来。"
			stamina = maxf(0.0, stamina - float(risk.get("stamina", 0)))
			san = _pay_san(float(risk.get("san", 0)))
			if _check_depletion():
				last_text = text + "\n\n" + end_text
				state_changed.emit()
				return

	var gained := _gain_rewards(option.get("rewards", []))
	if not gained.is_empty():
		var parts: Array = []
		for entry in gained:
			parts.append("%s×%d" % [DataRegistry.item_name(str(entry["id"])), int(entry["count"])])
		text += "\n\n获得：" + ", ".join(parts)
	last_text = text
	state = STATE_MAP
	map_changed.emit()
	state_changed.emit()


func _pay_san(amount: float) -> float:
	if amount <= 0.0:
		return san
	if san_shield > 0:
		san_shield -= 1
		amount *= 0.5
	return maxf(0.0, san - amount)


func _gain_rewards(rewards: Array) -> Array:
	var gained: Array = []
	var luck := PlayerStats.luck_bonus() + luck_bonus
	var gather := maxf(1.0, PlayerStats.gather_multiplier())
	for r in rewards:
		var item_id := str(r.get("item", ""))
		if item_id == "":
			continue
		var once := bool(r.get("once", false))
		if once and PlayerStats.achievements.has(item_id):
			continue
		var chance := minf(1.0, float(r.get("chance", 1.0)) + luck * 0.3)
		if _rng.randf() > chance:
			continue
		var count := _rng.randi_range(int(r.get("min", 1)), int(r.get("max", 1)))
		count = maxi(1, int(round(float(count) * gather)))
		loot[item_id] = int(loot.get(item_id, 0)) + count
		gained.append({"id": item_id, "count": count})
		if once:
			PlayerStats.achievements[item_id] = true
	return gained


# ---------- 消耗品 ----------

func use_consumable(id: String) -> void:
	if not active or ended:
		return
	if not PlayerStats.remove_consumable(id):
		return
	var effect: Dictionary = DataRegistry.get_consumable(id).get("effect", {})
	if effect.has("stamina"):
		stamina = minf(PlayerStats.stamina_max(), stamina + float(effect["stamina"]))
	if effect.has("san"):
		san = minf(PlayerStats.san_max(), san + float(effect["san"]))
	if effect.has("san_shield"):
		san_shield += int(effect["san_shield"])
	if effect.has("luck_bonus"):
		luck_bonus += float(effect["luck_bonus"])
	last_text = "你使用了 %s。" % str(DataRegistry.get_consumable(id).get("name", ""))
	state_changed.emit()


# ---------- 结束 ----------

func loot_list() -> Array:
	var out: Array = []
	for id in loot.keys():
		out.append({"id": id, "count": int(loot[id])})
	return out


func loot_value() -> int:
	var total := 0
	for id in loot.keys():
		total += DataRegistry.item_value(id) * int(loot[id])
	return total


func _check_depletion() -> bool:
	if stamina <= 0.0:
		_finish("auto_return", "体力见底，你顺着原路走回了度假村。")
		return true
	if san <= 0.0:
		_finish("auto_return", "SAN 见底，你几乎是被自己拖回度假村的。")
		return true
	return false


func go_home() -> void:
	if not active or ended:
		return
	_finish("returned", "你带着这一趟的东西回到了度假村。")


func _finish(result: String, text: String) -> void:
	active = false
	ended = true
	state = STATE_RESULT
	end_result = result
	end_text = text
	last_text = text
	PlayerStats.stamina = maxf(0.0, stamina)
	PlayerStats.san = maxf(0.0, san)
	PlayerStats.stats_changed.emit()
	for id in loot.keys():
		GameState.add_item(str(id), int(loot[id]))
	# 灰石带出边境会造成不好的影响，军方按低比例直接收走
	var rate := int(settings().get("grey_stone_money_rate", 3))
	var money := grey_stones * rate
	if money > 0:
		GameState.earn(money, "灰石收购")
	var summary := {
		"result": result,
		"loot": loot.duplicate(),
		"value": loot_value(),
		"grey_stones": grey_stones,
		"grey_money": money,
	}
	grey_stones = 0
	state_changed.emit()
	run_finished.emit(result, summary)


func _enter_terrain(tile: Vector2i, travel_dir: Vector2i) -> void:
	current_tile = tile
	_reveal(tile)
	var local := _local_map_for(tile, travel_dir)
	player_cell = local["entry"]
	state = STATE_MAP
	transition.clear()
	trade_offers.clear()
	transition_cell = Vector2i.ZERO
	last_text = "你走进了%s。" % DataRegistry.terrain_name(terrain_at(tile))
	map_changed.emit()
	state_changed.emit()
