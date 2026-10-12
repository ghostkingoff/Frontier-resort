extends Node
## 客流量：每游戏内 1 小时对账一次——
##   目标人数 =（知名度系数 × 口碑系数）×（当前开门店铺 × 2）
##   不足 → 按缺口慢慢补人；多了 → 请散客离场（同队一起走）。
## 只统计「没入住度假屋」的游客：已入住的既不计入、也不会被赶；
## 「当前开门店铺」只数当前营业中的消费设施（餐饮/商店/医疗/休闲/展厅），
## 度假屋、招待厅、卫生间、保洁间、路灯这类不算。

@export var max_customers := 48     # 硬保险：场上总人数（含住客）上限；设为 0 可整体关掉
@export var test_interval := 0.0    # >0：测试档——无视客流量，按这个间隔直接来人（冒烟测试用）

const ARRIVAL_MIN_GAP := 8.0        # 补人间隔下限（scaled 秒；缺口大时最快这个节奏）
const ARRIVAL_MAX_GAP := 60.0       # 补人间隔上限（缺口只有 1 人时约 1 游戏小时来一组）
const LODGE_PRIORITY_CHANCE := 0.85  # 有空房时，优先放「会住宿的客人」的概率（前期靠他们撑人气）

var world: Node2D
var _last_hour := -1
var _quota := 0                     # 这一小时还差多少「人」（不足补充用）
var _arrival_timer := 0.0


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")


func _process(delta: float) -> void:
	if world == null or max_customers <= 0:
		return
	if GameClock.phase == GameClock.Phase.SETTLEMENT or GameClock.paused:
		return
	var scaled := delta * GameClock.time_scale()
	if test_interval > 0.0:
		# 测试档：不看客流量，按固定间隔直接来人
		_arrival_timer -= scaled
		if _arrival_timer <= 0.0:
			_arrival_timer = test_interval
			_try_spawn()
		return
	var hour := int(GameClock.hour_of_day())
	if hour != _last_hour:
		_last_hour = hour
		_run_hourly_check()
	if _quota <= 0:
		return
	if world.customers_root.get_child_count() >= max_customers:
		return
	_arrival_timer -= scaled
	if _arrival_timer > 0.0:
		return
	var hour_seconds := maxf(1.0, GameClock.cycle_length_seconds / 24.0)
	_arrival_timer = clampf(hour_seconds / maxf(1.0, float(_quota)), ARRIVAL_MIN_GAP, ARRIVAL_MAX_GAP)
	_quota -= _try_spawn()


# ---------- 每小时对账 ----------

func _run_hourly_check() -> void:
	if world.reception() == null:
		return      # 没有招待厅就没法接待，先不控流
	# 目标人数 = 正常客流量 + 空房位总数：有空房时就多放人（优先放住宿客，见 _pick_type），
	# 否则会出现「明明有空房，却因为客流量已经满了而没人来住」的情况
	var want := target_people() + free_room_people()
	var current := current_flow()
	if current > want:
		_quota = 0
		_release_excess(current - want)
	else:
		_quota = want - current


func target_flow() -> float:
	# 目标人数 =（知名度系数 × 口碑系数）×（当前开门店铺 × 2）
	return fame_factor() * reputation_factor() * float(open_business_count()) * 2.0


func target_people() -> int:
	# 对账用的目标人数：向上取整（0.3 → 1 人；店铺全关时 0 人）
	return int(ceil(target_flow()))


func fame_factor() -> float:
	# 知名度 ≤500 时 0.5~1.0；>500 恒为 1
	return clampf(GameState.fame / 1000.0 + 0.5, 0.5, 1.0)


func reputation_factor() -> float:
	return clampf(GameState.reputation / 200.0, 0.0, 1.0)


func open_business_count() -> int:
	var hour := GameClock.hour_of_day()
	var n := 0
	for b in world.buildings:
		if not is_instance_valid(b):
			continue
		if b.is_lodging() or b.is_reception():
			continue
		if b.category() == "other":
			continue
		if b.capacity() <= 0:
			continue
		if b.is_open_at(hour):
			n += 1
	return n


func current_flow() -> int:
	# 当前「未入住」的游客数：已经入住度假屋的不算，正在离场的也不算
	var n := 0
	for c in world.customers_root.get_children():
		if not (c is Customer):
			continue
		if c.lodge != null:
			continue
		if c.state == Customer.State.LEAVING or c.state == Customer.State.DONE:
			continue
		n += 1
	return n


func _release_excess(over: int) -> void:
	# 多了离开：请整队散客离场（队友一起走；有人入住的组不碰）
	if over <= 0:
		return
	var groups := _releasable_groups()
	groups.shuffle()
	var released := 0
	for group in groups:
		if released >= over:
			break
		var lead: Customer = group[0]
		if lead.party != null and is_instance_valid(lead.party):
			lead.party.begin_leave()
		else:
			lead.on_party_leave()
		released += group.size()


func _releasable_groups() -> Array:
	# 可以请离场的客人：没入住、没在离场，而且所在小队里没有人入住（避免把住客一起带走）
	var lodged_parties := {}
	for c in world.customers_root.get_children():
		if c is Customer and c.lodge != null and c.party != null and is_instance_valid(c.party):
			lodged_parties[c.party.get_instance_id()] = true
	var by_party := {}
	var singles: Array = []
	for c in world.customers_root.get_children():
		if not (c is Customer):
			continue
		if c.lodge != null:
			continue
		if c.state == Customer.State.LEAVING or c.state == Customer.State.DONE:
			continue
		if c.party != null and is_instance_valid(c.party):
			var key: int = c.party.get_instance_id()
			if lodged_parties.has(key):
				continue
			if not by_party.has(key):
				by_party[key] = []
			by_party[key].append(c)
		else:
			singles.append([c])
	var groups: Array = singles.duplicate()
	for key in by_party.keys():
		groups.append(by_party[key])
	return groups


# ---------- 来人 ----------

func _try_spawn() -> int:
	# 来一组客人（1~3 人），返回实际来的人数；没来成返回 0
	if world.reception() == null:
		return 0      # 没有招待厅就没法入住，先不来客人
	if world.customers_root.get_child_count() >= max_customers:
		return 0
	var entry := _pick_type()
	if entry.is_empty():
		return 0
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
	if _is_special(entry):
		GameState.celebrity_notice.emit(special_notice_text(entry, names))   # 明星 / 富商到来：弹 3 秒提示
	return names.size()


func present_ids() -> Dictionary:
	# 当前还在度假村里的名册条目 id（含住店 / 就诊 / 正在离场的人）。
	# 抽新客人时跳过这些条目：同一个「人」不会在村里同时出现两份。
	var out := {}
	for node in get_tree().get_nodes_in_group("customers"):
		if not (node is Customer):
			continue
		var c: Customer = node
		if c.is_queued_for_deletion() or c.state == Customer.State.DONE:
			continue
		var id := str(c.type_data.get("id", ""))
		if id != "":
			out[id] = true
	return out


func special_notice_text(entry: Dictionary, names: Array) -> String:
	# 「明星 Isabel 来到了度假村！」：含名字，给特殊客人一点排面
	var ids: Array = entry.get("identities", [])
	var label := "贵客"
	if ids.has("star") and ids.has("tycoon"):
		label = "明星·富商"
	elif ids.has("star"):
		label = "明星"
	elif ids.has("tycoon"):
		label = "富商"
	var shown: Array = []
	for n in names:
		shown.append(str(n))
	return "%s %s 来到了度假村！" % [label, "、".join(shown)]


func _pick_type() -> Dictionary:
	# 先掷「特殊客人」（明星 / 富商）：概率由知名度函数给出，最高 20%
	var special := _pick_special()
	if not special.is_empty():
		return special
	# 有空房就优先放「会住宿且住得下」的客人：入住客人不计入客流量，
	# 前期就是靠他们把人撑起来的；没空房 / 没合适的就按普通池子抽
	var lodge_pool := _build_pool(true)
	if not lodge_pool.is_empty() and randf() < LODGE_PRIORITY_CHANCE:
		return lodge_pool[randi() % lodge_pool.size()]
	var pool := _build_pool(false)
	if pool.is_empty():
		return {}
	return pool[randi() % pool.size()]


func _build_pool(lodging_only: bool) -> Array:
	var present := present_ids()
	var free_slots := max_free_room_slots()
	var pool: Array = []
	for t in DataRegistry.customer_types:
		if _is_special(t):
			continue          # 特殊客人只走上面的概率通道
		if present.has(str(t.get("id", ""))):
			continue          # 已经在度假村里的人不会重复出现
		if GameState.reputation < float(t.get("reputation_required", 0)):
			continue
		if lodging_only and not _lodges_preferred(t, free_slots):
			continue
		var weight := float(t.get("weight", 1))
		for _i in range(maxi(1, int(round(weight)))):
			pool.append(t)
	return pool


func max_free_room_slots() -> int:
	# 现在还剩几个住宿位：取所有「能走到的」度假屋里剩余房位的最大值（没空房返回 0）
	var best := 0
	for b in world.buildings:
		if b.is_lodging() and world.building_reachable(b):
			best = maxi(best, b.room_capacity() - b.guests.size())
	return best


func free_room_people() -> int:
	# 空房位总数（还能住进来几个人）：补人目标用
	var total := 0
	for b in world.buildings:
		if b.is_lodging() and world.building_reachable(b):
			total += maxi(0, b.room_capacity() - b.guests.size())
	return total


func _party_size(entry: Dictionary) -> int:
	match str(entry.get("party", "solo")):
		"duo":
			return 2
		"trio":
			return 3
	return 1


func _lodges_preferred(entry: Dictionary, free_slots: int) -> bool:
	# 有空房时优先放「会住宿（多日）且住得下」的客人：
	# 入住客人不计入客流量，所以他们会把前期的人气顶起来
	if free_slots <= 0:
		return false
	if str(entry.get("stay", "")) != "multi_day":
		return false
	return _party_size(entry) <= free_slots


func _is_special(entry: Dictionary) -> bool:
	var ids: Array = entry.get("identities", [])
	return ids.has("star") or ids.has("tycoon")


func _pick_special() -> Dictionary:
	var chance := GameState.star_arrival_chance()
	if chance <= 0.0:
		return {}
	if randf() > chance:
		return {}
	var present := present_ids()
	var showroom_value: int = world.showroom_display_value()
	var showroom_score: int = world.showroom_score()
	var pool: Array = []
	for t in DataRegistry.customer_types:
		if not _is_special(t):
			continue
		if present.has(str(t.get("id", ""))):
			continue          # 明星 / 富商同样不重复出现
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
