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
	var customer_type := _pick_type()
	if customer_type.is_empty():
		return
	var customer := Customer.new()
	customer.name = "Customer_%s" % str(customer_type.get("id", "x"))
	world.customers_root.add_child(customer)
	customer.setup(customer_type, world, world.random_entrance())
	GameState.register_visit()


func _pick_type() -> Dictionary:
	var pool: Array = []
	var showroom: int = world.showroom_score()
	for t in DataRegistry.customer_types:
		if GameState.reputation < float(t.get("reputation_required", 0)):
			continue
		var weight := float(t.get("weight", 1))
		if bool(t.get("attracted_by_showroom", false)):
			# 展厅里的珍贵展品越多，富商与明星越容易被吸引过来
			weight *= 1.0 + 0.35 * float(showroom)
		for _i in range(maxi(1, int(round(weight)))):
			pool.append(t)
	if pool.is_empty():
		return {}
	return pool[randi() % pool.size()]
