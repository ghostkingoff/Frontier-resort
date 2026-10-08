extends Node
## 游客生成：按口碑与设施数量决定来客频率，并挑选顾客类型。

@export var max_customers := 48
@export var base_interval := 180.0     # 开局大约每 3 分钟来一位住客（一天 ≈ 6 位）
@export var min_interval := 60.0       # 再热闹也不会快过这个间隔

var world: Node2D
var timer := 2.0


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")


func _process(delta: float) -> void:
	if world == null:
		return
	if GameClock.phase == GameClock.Phase.SETTLEMENT or GameClock.paused:
		return
	if GameClock.is_business() and GameClock.progress > 0.72:
		return
	if GameClock.is_night() and GameClock.progress > 0.97:
		return
	if world.customers_root.get_child_count() >= max_customers:
		return
	timer -= delta * GameClock.time_scale()
	if timer > 0.0:
		return
	timer = _next_interval()
	_try_spawn()


func _next_interval() -> float:
	# 设施越多、口碑越高，客人来得越密
	var interval := base_interval - float(world.buildings.size()) * 8.0 - GameState.reputation * 1.5
	# 声望越高，客人来得越勤
	interval /= maxf(1.0, PlayerStats.fame_multiplier())
	# 夜里继续经营时客流明显减少
	if GameClock.is_night():
		interval *= 2.6
	return clampf(interval, min_interval, base_interval)


func _try_spawn() -> void:
	if world.reception() == null:
		return      # 没有招待厅就没法入住，先不来客人
	var entry := _pick_type()
	if entry.is_empty():
		return
	# 一组客人共享预算（双人 / 三人），离开时一起走
	var party := Party.new()
	party.setup(int(entry.get("budget", 2000)))
	var names: Array = entry.get("names", [])
	if names.is_empty():
		names = [str(entry.get("id", "游客"))]
	for i in range(names.size()):
		var customer := Customer.new()
		customer.name = "Customer_%s_%d" % [str(entry.get("id", "x")), i]
		world.customers_root.add_child(customer)
		customer.setup(entry, world, world.random_entrance(), str(names[i]), party)


func _pick_type() -> Dictionary:
	# 先掷「特殊客人」（明星 / 富商）：概率由知名度函数给出，最高 20%
	var special := _pick_special()
	if not special.is_empty():
		return special
	var pool: Array = []
	for t in DataRegistry.customer_types:
		if _is_special(t):
			continue          # 特殊客人只走上面的概率通道
		if GameState.reputation < float(t.get("reputation_required", 0)):
			continue
		var weight := float(t.get("weight", 1))
		for _i in range(maxi(1, int(round(weight)))):
			pool.append(t)
	if pool.is_empty():
		return {}
	return pool[randi() % pool.size()]


func _is_special(entry: Dictionary) -> bool:
	var ids: Array = entry.get("identities", [])
	return ids.has("star") or ids.has("tycoon")


func _pick_special() -> Dictionary:
	var chance := GameState.star_arrival_chance()
	if chance <= 0.0:
		return {}
	if randf() > chance:
		return {}
	var showroom_value: int = world.showroom_display_value()
	var showroom_score: int = world.showroom_score()
	var pool: Array = []
	for t in DataRegistry.customer_types:
		if not _is_special(t):
			continue
		if GameState.reputation < float(t.get("reputation_required", 0)):
			continue          # 口碑门槛仍然要满足
		var ids: Array = t.get("identities", [])
		var weight := float(t.get("weight", 1))
		if ids.has("star"):
			# 明星：知名度和口碑越高越容易来
			weight *= 1.0 + GameState.fame * 0.003 + GameState.reputation * 0.02
		if ids.has("tycoon"):
			# 富商：知名度 + 展厅展品总价值（以及稀有度分）
			weight *= 1.0 + GameState.fame * 0.002 + float(showroom_value) / 200000.0 + float(showroom_score) * 0.05
		weight = maxf(weight, 0.05)
		for _i in range(maxi(1, int(round(weight)))):
			pool.append(t)
	if pool.is_empty():
		return {}
	return pool[randi() % pool.size()]
