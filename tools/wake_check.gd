extends Node
## 专项体检：住客早上陆续醒来（06:30~07:30）+「休息一晚」后位置重置。
## 运行：godot --headless --path . -- --wake
##
## 一次跑完，把要看的东西全部打印出来，不用反复跑引擎。

var world: Node2D
var passed := true
var guests: Array = []          # 有房间的住客
var day_trips: Array = []       # 当日往返


func _ready() -> void:
	seed(20261008)               # 固定随机种子，结果可复现
	world = get_tree().get_first_node_in_group("world")
	var spawner := world.get_parent().get_node_or_null("CustomerSpawner")
	if spawner:
		spawner.max_customers = 0        # 关掉自动来客，保证这一轮人数可控
	DataRegistry.illness_config["base_chance"] = 0.0
	GameClock.set_speed(GameClock.Speed.X1)
	await get_tree().create_timer(0.4).timeout
	_spawn_fixtures()
	_run_checks()
	get_tree().quit(0 if passed else 1)


func _check(label: String, ok: bool, detail: String) -> void:
	if not ok:
		passed = false
	print("[wake] %s %s ｜ %s" % ["OK  " if ok else "FAIL", label, detail])


func _spawn_fixtures() -> void:
	# 手动放一批住客：多日的会去住度假屋，单日的当天往返。
	# 度假屋房位是 1 + 2 + 3 = 6，所以多日客人不超过 6 位。
	var multi: Array = []
	var single: Array = []
	for t in DataRegistry.customer_types:
		if int(t.get("max_nights", 0)) > 0:
			multi.append(t)
		else:
			single.append(t)
	var room_capacity := 0
	for b in world.buildings:
		if b.is_lodging():
			room_capacity += b.room_capacity()
	var used := 0
	for t in multi:
		var names: Array = t.get("names", [])
		if used + names.size() > room_capacity:
			continue
		var party := Party.new()
		party.setup(int(t.get("budget", 2000)))
		for i in range(names.size()):
			var c: Customer = Customer.new()
			world.customers_root.add_child(c)
			c.setup(t, world, world.random_entrance(), str(names[i]), party)
			guests.append(c)
		used += names.size()
	for t in single:
		if day_trips.size() >= 2:
			break
		var c2: Customer = Customer.new()
		world.customers_root.add_child(c2)
		c2.setup(t, world, world.random_entrance())
		day_trips.append(c2)
	print("[wake] 场景：度假屋房位 %d ｜ 多日住客 %d 位 ｜ 当日往返 %d 位" % [
		room_capacity, guests.size(), day_trips.size()])


func _all_guests() -> Array:
	var out: Array = []
	for c in guests:
		if is_instance_valid(c):
			out.append(c)
	for c in day_trips:
		if is_instance_valid(c):
			out.append(c)
	return out


func _advance(frames: int, step: float = 0.05) -> void:
	# 结算阶段顾客是被冻结的（正常玩法里他们就一直睡到天亮），
	# 这里要模拟「夜晚继续经营」那样让时间真的走起来
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.paused = false
	for _i in range(frames):
		for c in _all_guests():
			c._process(step)


func _count_in_room(list: Array) -> int:
	var n := 0
	for c in list:
		if is_instance_valid(c) and c.is_resting_in_room():
			n += 1
	return n


func _count_sleeping(list: Array) -> int:
	# 「还在睡昨晚这一觉」的住客数；白天回房打盹不算（那本来就会在屋里待一会儿）
	var n := 0
	for c in list:
		if is_instance_valid(c) and c.is_sleeping_for_night():
			n += 1
	return n


func _run_checks() -> void:
	# ---------- 0. 先让住客走到招待厅办入住、拿到房间 ----------
	# （入住是在「走到招待厅」那一刻发生的，所以这里要放足够多帧让他们走完）
	for _i in range(40):
		_advance(200)
		if _count_with_room() == guests.size():
			break
	_check("多日住客都拿到了房间", _count_with_room() == guests.size(),
		"有房间 %d / %d 位" % [_count_with_room(), guests.size()])
	if guests.is_empty() or _count_with_room() == 0:
		print("[wake] 结果：未通过（住客没能入住，后面的检查没法做）")
		passed = false
		return

	# ---------- 1. 夜里大家进屋睡觉，并各自定下醒来时间 ----------
	GameClock.skip_to_end_of_day()             # 24:00 结算
	_advance(900)
	var slept := _count_in_room(guests)
	_check("夜里住客进屋睡觉", slept == guests.size(),
		"%d / %d 位在房间里" % [slept, guests.size()])

	var hours: Array = []
	var in_range := 0
	for c in guests:
		if not is_instance_valid(c):
			continue
		var h: float = c.wake_hour()
		hours.append("%.2f" % h)
		if h >= Customer.WAKE_EARLIEST - 0.001 and h <= Customer.WAKE_LATEST + 0.001:
			in_range += 1
	_check("醒来时间随机落在 06:30~07:30", in_range == guests.size(),
		"%d / %d 位合格 ｜ 各自醒来时间 %s" % [in_range, guests.size(), ", ".join(hours)])
	var distinct := {}
	for c in guests:
		if is_instance_valid(c):
			distinct[snappedf(c.wake_hour(), 0.01)] = true
	_check("不是同一个时间点集体起床", distinct.size() > 1 or guests.size() == 1,
		"%d 位住客 → %d 个不同的醒来时间" % [guests.size(), distinct.size()])

	# ---------- 2. 06:00 全都没出门 ----------
	GameClock.progress = 0.0                   # 06:00
	_advance(200)
	var out_at_0600 := guests.size() - _count_in_room(guests)
	_check("06:00 全都还赖在床上", out_at_0600 == 0, "06:00 时房外有 %d 位" % out_at_0600)

	# ---------- 3. 到了各自的醒来时间陆续出门 ----------
	# 挑一个「只有一位住客在这个时间点醒」的时刻，才能验证是陆续而不是一起
	var by_hour: Dictionary = {}
	for c in guests:
		if is_instance_valid(c):
			var key := snappedf(c.wake_hour(), 0.01)
			by_hour[key] = int(by_hour.get(key, 0)) + 1
	var lonely_wake := -1.0
	var keys: Array = by_hour.keys()
	keys.sort()
	for k in keys:
		if int(by_hour[k]) == 1:
			lonely_wake = float(k)
			break
	if lonely_wake > 0.0:
		# 只推进到这位独苗醒来之后一点点（不能推太多，否则会越过别人的醒来时间）
		GameClock.progress = (lonely_wake - GameClock.DAY_START_HOUR) / 24.0 + 0.0005
		_advance(6, 0.05)
		var still_in := _count_in_room(guests)
		var rows: Array = []
		for c in guests:
			if is_instance_valid(c):
				rows.append("%.2f:%s" % [c.wake_hour(), "房内" if c.is_resting_in_room() else "已在外面"])
		_check("到最早那位的时间点时，只有他起床", still_in == guests.size() - 1,
			"%.2f 时房里还剩 %d / %d 位 ｜ %s" % [
				lonely_wake, still_in, guests.size(), "  ".join(rows)])
	else:
		_check("到最早那位的时间点时，只有他起床", false,
			"六位住客的醒来时间都有重复，挑不出单个时间点（%s）" % str(by_hour))

	GameClock.progress = (Customer.WAKE_LATEST - GameClock.DAY_START_HOUR) / 24.0 + 0.01
	_advance(400)
	var still_late := _count_sleeping(guests)
	_check("过了最晚醒来时间都出门了", still_late == 0,
		"07:30 之后仍在过夜睡眠 %d 位（屋里合计 %d 位）" % [still_late, _count_in_room(guests)])

	# ---------- 4.「休息一晚」：位置重置 ----------
	GameClock.start_new_day()
	GameClock.skip_to_end_of_day()
	# 先把所有人撒到地图各处，模拟白天在外面乱走的散乱状态
	var scattered: Array = _all_guests()
	for c in scattered:
		c.reparent(world.customers_root, true)
		c.global_position = world.cell_center(world.random_walkable_cell())
		c.force_leave_current_building()
		c._path = []
		c._path_index = 0
		c.state = Customer.State.TO_TARGET
		c.target = null
	var room_before := _count_in_room(guests)
	var result: Dictionary = world.rest_night()
	var slept_now: int = int(result.get("slept", 0))
	var left_now: int = int(result.get("left", 0))
	_check("休息一晚：有房间的都进房间", slept_now == guests.size(),
		"多日住客 %d 位 → 进房 %d 位（重置前房里 %d 位）" % [guests.size(), slept_now, room_before])
	_check("休息一晚：当日往返的离开", left_now == day_trips.size(),
		"当日往返 %d 位 → 离开 %d 位" % [day_trips.size(), left_now])

	var wrong_place: Array = []
	var in_room_now := 0
	for c in guests:
		if not is_instance_valid(c):
			continue
		if not c.is_resting_in_room():
			continue
		in_room_now += 1
		var at: Vector2i = world.world_to_cell(c.global_position)
		var lc: Vector2i = c.lodge.cell if (c.lodge != null and is_instance_valid(c.lodge)) else Vector2i(-1, -1)
		var fp: Vector2i = c.lodge.footprint if (c.lodge != null and is_instance_valid(c.lodge)) else Vector2i.ZERO
		var inside: bool = at.x >= lc.x and at.x < lc.x + fp.x and at.y >= lc.y and at.y < lc.y + fp.y
		if not inside:
			wrong_place.append("%s 在 %s，房间占 %s~%s" % [c.customer_name, str(at), str(lc), str(lc + fp)])
	_check("在房里的住客确实在自己房间范围内", wrong_place.is_empty() and in_room_now == guests.size(),
		"房里 %d 位 ｜ 位置不对 %d 位%s" % [in_room_now, wrong_place.size(),
			"" if wrong_place.is_empty() else "（%s）" % "; ".join(wrong_place)])
	_check("当日往返的已从场地移除", _live_day_trips() == 0,
		"场上还剩 %d 位当日往返" % _live_day_trips())

	# ---------- 5. 重置后第二天早上仍按各自时间起床 ----------
	GameClock.start_new_day()
	GameClock.progress = 0.0
	_advance(200)
	var still_in_0600 := _count_in_room(guests)
	_check("重置后 06:00 仍在房里，不会提前跑掉", still_in_0600 == in_room_now,
		"06:00 仍在房间 %d 位（重置后 %d 位）" % [still_in_0600, in_room_now])

	GameClock.progress = (Customer.WAKE_LATEST - GameClock.DAY_START_HOUR) / 24.0 + 0.01
	_advance(400)
	_check("重置后过了最晚醒来时间也都出门了", _count_sleeping(guests) == 0,
		"07:30 之后仍在过夜睡眠 %d 位（屋里合计 %d 位）" % [_count_sleeping(guests), _count_in_room(guests)])

	print("[wake] 结果：%s" % ("通过" if passed else "未通过"))


func _count_with_room() -> int:
	var n := 0
	for c in guests:
		if is_instance_valid(c) and c.lodge != null and is_instance_valid(c.lodge):
			n += 1
	return n


func _live_day_trips() -> int:
	var n := 0
	for c in day_trips:
		# 用了 leave_now() 的客人 state 会变成 DONE（已经离场）
		if is_instance_valid(c) and c.state != Customer.State.DONE:
			n += 1
	return n
