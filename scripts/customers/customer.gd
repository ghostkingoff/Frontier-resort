extends "res://scripts/actors/actor.gd"
class_name Customer
## 住客：带着预算来到度假村，在招待厅办理入住，住进度假屋之后四处消费，
## 直到「预算花完」或「心情掉到谷底」才回招待厅结账离开。
## 度假屋的钱按住宿天数在结账时结算。
## 走位（寻路 / 行走 / 取帧 / 卡住检测）继承自 actor.gd，和保洁工人共用一套。

enum State { TO_TARGET, INSIDE, SEEK_CLINIC, WAITING_CURE, TREATMENT, LEAVING, DONE }
enum Purpose { NONE, CHECK_IN, TO_ROOM, CONSUME, REST, CHECK_OUT, WANDER }

const MOOD_START := 70.0
const MOOD_LEAVE := 25.0        # 心情低于这个值就提前退房
const BUDGET_LEAVE := 300       # 预算少于这个数就当作花完了
const MOOD_DECAY_PER_HOUR := 0.35
const INSIDE_TIMEOUT := 25.0    # 在建筑里待超过这么久就被强行请出来
# 住客早上陆续醒来：不早于最早时间，且在 [最早, 最晚) 内随机
const WAKE_EARLIEST := 6.5      # 06:30
const WAKE_LATEST := 7.5        # 07:30

var type_data: Dictionary = {}
var customer_name := "游客"
var budget_total := 0
var budget_left := 0
var spent_total := 0
var mood := MOOD_START
var max_nights := 2
var wants_lodging := true
var party: Party = null                 # 同行小组（单人也是只有一名成员的小组）
var identities: Array = []              # 普通游客 / 明星 / 富商，可共存（明星+富商）
var spend_frequency := 0.6              # 越高越勤于消费，越低越常闲逛
var is_star := false
var is_tycoon := false
var has_bike := false
var _litter_accum := 0.0
var _litter_interval := 0.0

var target: Building = null
var purpose: int = Purpose.NONE
var state: int = State.TO_TARGET
var lodge: Building = null
var nights := 0
var exit_point := Vector2.ZERO

var action_left := 0.0
var _entrance_cell := Vector2i.ZERO
var _entry_cell := Vector2i.ZERO          # 这次要去的是哪个出入口（门口优先，否则外圈最近一格）
var _no_path_time := 0.0                  # 「该走路却没路径」持续了多久，用于重新决策
var _in_night := false
var _wake_hour := 0.0            # 今晚这位住客几点醒（06:30~07:30）
var _last_facility: Building = null
var _inside_building: Building = null    # 当前是否在某个建筑内部（用于保证能走出来）
var _fail_count := 0                     # 连续找不到路的次数
var _inside_time := 0.0                  # 在建筑里待了多久（防止卡在室内）
var illness: Dictionary = {}
var clinic: Building = null
var cure_left := 0.0
var treatment_left := 0.0


func setup(customer_type: Dictionary, world_ref: Node2D, spawn_pos: Vector2,
		member_name := "", shared_party: Party = null) -> void:
	type_data = customer_type
	world = world_ref
	customer_name = member_name if member_name != "" else str(customer_type.get("name", "游客"))
	budget_total = int(customer_type.get("budget", 2000))
	budget_left = budget_total
	max_nights = int(customer_type.get("max_nights", 0))   # 没写就是当天往返，不留宿
	wants_lodging = max_nights > 0
	identities = customer_type.get("identities", ["ordinary"])
	is_star = identities.has("star")
	is_tycoon = identities.has("tycoon")
	spend_frequency = float(customer_type.get("spend_frequency", 0.6))
	if shared_party != null:
		party = shared_party
		party.add_member(self)
	else:
		party = Party.new()
		party.setup(budget_total)
		party.add_member(self)
	GameState.register_visit()      # 到访人数按人头统计
	mood = MOOD_START
	position = spawn_pos
	z_index = int(position.y)
	_build_sprite()
	# 从主路一端进场，先去招待厅
	var reception: Building = world.reception()
	if reception == null:
		_leave_world()
		return
	_entrance_cell = world.entrance_cell(reception.door_cell())
	position = world.cell_center(_entrance_cell)
	_go_to(reception, Purpose.CHECK_IN)


func _build_sprite() -> void:
	var base := str(type_data.get("sprite", "res://art/placeholder/characters/Boy"))
	_build_sprite_base(base + "/walk.png")


func _start_cell_candidates(from_cell: Vector2i) -> Array:
	# 从建筑里走出来时，把这栋楼的所有出入口都当候选（门口排第一），
	# 逐个试到「既能走、又能算到目标」的那个为止。
	var out: Array = []
	if _inside_building != null and is_instance_valid(_inside_building):
		var door: Vector2i = _inside_building.door_cell()
		out.append(door)
		var ring: Array = _inside_building.perimeter_cells()
		ring.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return world.cell_center(a).distance_to(world.cell_center(from_cell)) \
				< world.cell_center(b).distance_to(world.cell_center(from_cell)))
		for c in ring:
			if c != door:
				out.append(c)
	out.append(world.nearest_walkable(from_cell, 12))
	return out


func _on_start_cell_moved(_to_cell: Vector2i) -> void:
	# 已经离开建筑：挂回场地层并清掉「在建筑内」的标记
	reparent(world.customers_root, true)
	_inside_building = null


# ---------- 主循环 ----------

func _process(delta: float) -> void:
	if GameClock.paused or GameClock.phase == GameClock.Phase.SETTLEMENT:
		return
	var scaled := delta * GameClock.time_scale()
	_track_night()
	_tick_mood(scaled)
	_check_stuck(delta)
	_tick_litter(scaled)
	_recover_if_no_path(delta)
	match state:
		State.TO_TARGET:
			if purpose == Purpose.WANDER:
				if _follow_path(scaled):
					action_left = randf_range(3.0, 8.0)
					state = State.INSIDE
			elif target == null or not is_instance_valid(target):
				_choose_activity()
				return
			elif _follow_path(scaled):
				# 走到选定的那个出入口（门口优先，或外圈上最近的一格）
				var entry_point: Vector2 = world.cell_center(_entry_cell)
				_step_towards(entry_point, scaled)
				if global_position.distance_to(entry_point) < 6.0:
					_arrive()
		State.INSIDE:
			# 夜里睡觉：到了自己的醒来时间（06:30~07:30 之间随机）才出门
			if purpose == Purpose.REST and not GameClock.is_night() and _sleep_done():
				_finish_action()      # 天亮了、也到点了，才出房间
				return
			action_left -= scaled
			if action_left <= 0.0:
				_finish_action()
		State.SEEK_CLINIC:
			if clinic == null or not is_instance_valid(clinic):
				state = State.WAITING_CURE
				return
			if _follow_path(scaled):
				var clinic_entry: Vector2 = world.cell_center(_entry_cell)
				_step_towards(clinic_entry, scaled)
				if global_position.distance_to(clinic_entry) < 6.0:
					_enter_clinic()
		State.WAITING_CURE:
			cure_left -= scaled
			if cure_left <= 0.0:
				_fail_cure()
		State.TREATMENT:
			pass    # 由医院推进治疗进度
		State.LEAVING:
			if _follow_path(scaled):
				_step_towards(exit_point, scaled)
				if global_position.distance_to(exit_point) < 8.0:
					state = State.DONE
					queue_free()
	z_index = int(global_position.y)


func _check_stuck(delta: float) -> void:
	if state == State.INSIDE or state == State.TREATMENT:
		# 在建筑里：夜里睡觉属于正常停留，其余情况超时就被强行请出来
		var sleeping := purpose == Purpose.REST and GameClock.is_night()
		_inside_time = 0.0 if sleeping else _inside_time + delta
		if _inside_time > INSIDE_TIMEOUT:
			_inside_time = 0.0
			_force_exit()
		reset_stuck_timer()
		return
	_inside_time = 0.0
	# 走路时踩在不可通行格上（典型原因：路线中途被新盖的建筑压住，或缓存过期）：
	# 立刻纠正到最近的可通行格，不要等 5 秒看门狗，否则会看到客人站在墙里
	if state == State.TO_TARGET and not world.is_walkable(world.world_to_cell(global_position)):
		var fixed: Vector2i = world.nearest_walkable(world.world_to_cell(global_position), 12)
		if fixed.x != -9999:
			reparent(world.customers_root, true)
			global_position = world.cell_center(fixed)
			clear_path()
			_inside_building = null
			reset_stuck_timer()
			return
	# 室外的卡住检测用基类那套（阈值与「站着不动不算卡住」的判断都在 actor.gd）
	super._check_stuck(delta)


func _recover_if_no_path(delta: float) -> void:
	# 该走路却没有路径（路线中途被新建筑压住、缓存过期、目标临时不可达…）：
	# 持续一小段时间就重新决策一次，避免客人永远杵在原地。
	if state != State.TO_TARGET and state != State.SEEK_CLINIC and state != State.LEAVING:
		_no_path_time = 0.0
		return
	if has_path():
		_no_path_time = 0.0
		return
	_no_path_time += delta
	if _no_path_time < 1.5:
		return
	_no_path_time = 0.0
	match state:
		State.LEAVING:
			_leave_world()                 # 重新取一次离场路径，再不行就按进场口走
		State.SEEK_CLINIC:
			if clinic != null and is_instance_valid(clinic):
				_start_path_to_building(clinic)
			else:
				_finish_action()
		_:
			# 去设施 / 回房：重算一次；目标没了就重新挑事做
			if target != null and is_instance_valid(target) and _start_path_to_building(target):
				return
			_choose_activity()


func _on_stuck() -> void:
	# 卡住超过 5 秒：先纠正位置，再重新算路，还不行就闲逛 / 直接离场
	_last_pos = global_position
	if _inside_building != null and is_instance_valid(_inside_building):
		_force_exit()
		return
	var cell: Vector2i = world.world_to_cell(global_position)
	if not world.is_walkable(cell):
		# 站在门口点 / 建筑格上：先挪到最近的能走格子，否则永远算不出路
		var fixed: Vector2i = world.nearest_walkable(cell, 12)
		if fixed.x != -9999:
			reparent(world.customers_root, true)
			global_position = world.cell_center(fixed)
	if purpose == Purpose.CHECK_OUT:
		_leave_world()
		return
	if target != null and is_instance_valid(target) and _start_path_to_building(target):
		state = State.TO_TARGET
		return
	if lodge != null and is_instance_valid(lodge) and _start_path_to_building(lodge):
		state = State.TO_TARGET
		return
	_start_wander()


func _start_path_to_building(building: Building) -> bool:
	# 去某栋建筑：出入口优先门口，门口走不通就从外圈其它面进（全开放）。
	# 选中的口记进 _entry_cell，到达判定与 State.TO_TARGET 都用它。
	if building == null or not is_instance_valid(building):
		return false
	var entry: Vector2i = world.best_entry_cell(building, global_position)
	if entry.x == -9999:
		return false
	_entry_cell = entry
	return _start_path_to(entry)


func _force_exit() -> void:
	# 强行从建筑里脱出：位置对齐到门口那一格，然后继续原本的行程
	var building := _inside_building
	_inside_building = null
	reparent(world.customers_root, true)
	if building != null and is_instance_valid(building):
		if building.visitors.has(self):
			building.remove_visitor(self)
		var _exit_cell: Vector2i = world.nearest_entry_cell(building, world.world_to_cell(global_position))
		if _exit_cell.x != -9999:
			global_position = world.cell_center(_exit_cell)
	else:
		var fixed: Vector2i = world.nearest_walkable(world.world_to_cell(global_position), 12)
		if fixed.x != -9999:
			global_position = world.cell_center(fixed)
	_choose_activity()


func _track_night() -> void:
	# 每跨过一次 24 点算住了一晚
	var is_night := GameClock.current_hour() >= 24.0
	if is_night and not _in_night:
		_in_night = true
		if lodge != null:
			nights += 1
			sleep_for_night()     # 今晚几点醒，这时候定下来
	elif not is_night:
		if _in_night:
			_on_morning()         # 天亮了：为下一晚重掷醒来时间
		_in_night = false


func sleep_for_night() -> void:
	# 住进度假屋过夜时调用：定下今晚的醒来时间（06:30~07:30 之间随机），并一觉睡到天亮
	if purpose == Purpose.REST and _wake_hour > 0.0:
		return                      # 今晚已经定过了，别每次回房都重掷
	roll_wake_hour()
	action_left = 9999.0


func roll_wake_hour() -> float:
	_wake_hour = randf_range(WAKE_EARLIEST, WAKE_LATEST)
	return _wake_hour


func _on_morning() -> void:
	# 走到早上 6 点：今晚的醒来时间已经用掉了，清掉它。
	# 注意不能在这里重掷——6 点的时候住客还在睡，重掷会把「陆续醒来」的错峰打乱。
	# 下一天晚上回房时由 sleep_for_night() 重新定。
	if purpose == Purpose.REST and state == State.INSIDE:
		return                      # 还在睡的这一位，保留今晚定好的时间
	_wake_hour = 0.0


func wake_hour() -> float:
	return _wake_hour


func is_resting_in_room() -> bool:
	# 正在房间里过夜（用于「休息一晚」之后核对谁该在房里）
	return state == State.INSIDE and purpose == Purpose.REST \
		and _inside_building != null and is_instance_valid(_inside_building)


func goto_room_for_night() -> bool:	# 「休息一晚」跳过夜晚时调用：直接把住客安置进自己的房间睡觉，
	# 不走路上浪费时间（回来时天已经亮了）。没有房间的返回 false，由调用方安排离场。
	if lodge == null or not is_instance_valid(lodge):
		return false
	force_leave_current_building()
	reparent(lodge.interior, true)
	global_position = lodge.interior_point()
	_inside_building = lodge
	target = lodge
	purpose = Purpose.REST
	state = State.INSIDE
	action_left = 9999.0          # 一觉睡到自己的醒来时间
	# 跳过夜晚时时间不会真的走，_track_night() 不会触发，所以这里自己定醒来时间
	sleep_for_night()
	return true


func force_leave_current_building() -> void:
	# 从当前所在的建筑里干净地脱身（不改变行程，只处理引用与所在层）
	var b := _inside_building
	if b == null or not is_instance_valid(b):
		_inside_building = null
		return
	if b.visitors.has(self):
		b.remove_visitor(self)
	b.release_patient(self)
	_inside_building = null


func _sleep_done() -> bool:
	# 天亮之后，还要等到「今晚定下的醒来时间」才起床
	var hour := GameClock.hour_of_day()
	var wake := _wake_hour if _wake_hour > 0.0 else WAKE_EARLIEST
	return hour >= wake


func _tick_mood(scaled: float) -> void:
	var hour_seconds := maxf(1.0, GameClock.cycle_length_seconds / 24.0)
	# 附近有垃圾会持续掉心情（保洁间清掉后恢复）
	var dirty: int = world.litter_near(global_position, 6.0 * 32.0)
	var decay := MOOD_DECAY_PER_HOUR + 0.35 * float(dirty)
	mood = clampf(mood - decay * scaled / hour_seconds, 0.0, 100.0)


func _gain_mood(amount: float) -> void:
	mood = clampf(mood + amount, 0.0, 100.0)


# ---------- 行程 ----------

func _go_to(building: Building, what: int) -> void:
	if building == null or not is_instance_valid(building):
		_choose_activity()
		return
	# 出入口：优先贴图上的门口，门口走不通就从外圈其它面进（全开放）
	var entry: Vector2i = world.best_entry_cell(building, global_position)
	if entry.x == -9999:
		# 一个口都进不去：先换个地方闲逛，连续三次都找不到路就干脆回家
		_fail_count += 1
		target = null
		purpose = Purpose.NONE
		if _fail_count >= 3:
			_fail_count = 0
			_leave_world()
		else:
			_start_wander()
		return
	target = building
	purpose = what
	_entry_cell = entry
	if not _start_path_to(entry):
		# 走不过去：先换个地方闲逛，连续几次都找不到路就干脆回家
		_fail_count += 1
		target = null
		purpose = Purpose.NONE
		if _fail_count >= 3:
			_fail_count = 0
			_leave_world()
		else:
			_start_wander()
		return
	_fail_count = 0
	state = State.TO_TARGET


func _arrive() -> void:
	match purpose:
		Purpose.CHECK_IN:
			_do_check_in()
		Purpose.TO_ROOM:
			_do_enter_room()
		Purpose.CONSUME:
			_enter_facility()
		Purpose.REST:
			_enter_room_rest()
		Purpose.CHECK_OUT:
			_enter_checkout()
		_:
			_choose_activity()


func _do_check_in() -> void:
	var reception := target
	if reception:
		reception.check_ins += 1
	if is_star:
		GameState.add_star_fame(randf_range(10.0, 20.0))
		GameState.notice.emit("明星 %s 来到了度假村" % customer_name)
	var room: Building = null
	if wants_lodging:
		var party_size: int = party.members.size() if party != null else 1
		room = world.lodge_with_free_room(party_size)
	if room == null:
		if wants_lodging:
			GameState.notice.emit("度假屋没有空房，%s 只能当天往返" % customer_name)
		_choose_activity()
		return
	lodge = room
	_gain_mood(10.0)
	_go_to(room, Purpose.TO_ROOM)


func _do_enter_room() -> void:
	lodge.add_guest(self)
	_gain_mood(10.0)
	_go_to(lodge, Purpose.REST)


func _enter_room_rest() -> void:
	var room := lodge if (lodge != null and is_instance_valid(lodge)) else target
	if room:
		reparent(room.interior, true)
		global_position = room.interior_point()
		_inside_building = room
	# 夜里就一觉睡到天亮，避免整晚在门口进进出出
	if GameClock.is_night():
		sleep_for_night()
	else:
		action_left = randf_range(6.0, 12.0)
	state = State.INSIDE


func _enter_facility() -> void:
	var b := target
	b.add_visitor(self)
	reparent(b.interior, true)
	global_position = b.interior_point()
	_inside_building = b
	action_left = randf_range(3.0, 7.0)
	state = State.INSIDE


func _enter_checkout() -> void:
	var reception := target
	if reception:
		reparent(reception.interior, true)
		global_position = reception.interior_point()
		_inside_building = reception
	action_left = 2.5
	state = State.INSIDE


func _finish_action() -> void:
	match purpose:
		Purpose.CONSUME:
			_finish_consume()
		Purpose.REST:
			_finish_rest()
		Purpose.CHECK_OUT:
			_finish_checkout()
		Purpose.WANDER:
			_choose_activity()
		_:
			_choose_activity()


func _finish_consume() -> void:
	var b := target
	if b == null or not is_instance_valid(b):
		_choose_activity()
		return
	b.remove_visitor(self)
	reparent(world.customers_root, true)
	var _exit_cell: Vector2i = world.nearest_entry_cell(b, world.world_to_cell(global_position))
	if _exit_cell.x != -9999:
		global_position = world.cell_center(_exit_cell)
	_inside_building = null
	# 特殊设施：卫生间不花钱只涨心情，单车租借所给加速
	if b.service() == "toilet":
		_gain_mood(b.mood_bonus())
		_popup("心情 +%d" % int(b.mood_bonus()), Color(0.7, 0.95, 0.8))
		b.on_guest_served()
		_choose_activity()
		return
	if b.service() == "bike":
		if not has_bike:
			has_bike = true
			speed *= 2.2
			_popup("租了共享单车", Color(0.7, 0.9, 1.0))
		_choose_activity()
		return
	_pay_facility(b)
	b.on_guest_served()
	if _roll_illness():
		return
	_choose_activity()


func _finish_rest() -> void:
	var room := lodge if (lodge != null and is_instance_valid(lodge)) else null
	if room:
		reparent(world.customers_root, true)
		var _exit_cell: Vector2i = world.nearest_entry_cell(room, world.world_to_cell(global_position))
		if _exit_cell.x != -9999:
			global_position = world.cell_center(_exit_cell)
		_inside_building = null
	_gain_mood(8.0)
	_choose_activity()


func _finish_checkout() -> void:
	var reception := target
	if reception:
		reparent(world.customers_root, true)
		var _exit_cell: Vector2i = world.nearest_entry_cell(reception, world.world_to_cell(global_position))
		if _exit_cell.x != -9999:
			global_position = world.cell_center(_exit_cell)
		_inside_building = null
	# 结算住宿费：按住的天数算，钱在结账时进账
	if lodge != null and is_instance_valid(lodge):
		var n := maxi(1, nights)
		var fee := lodge.charge_stay(self, n)
		if fee > 0:
			if party != null:
				party.spend(fee)
				budget_left = party.budget_left
			GameState.earn(fee, "住宿结算")
			_popup("住宿 %d 晚 +%s" % [n, GameState.format_money(fee)], Color(0.98, 0.85, 0.35))
		lodge.remove_guest(self)
		lodge = null
	_leave_world()


func on_party_leave() -> void:	# 同行小组决定离开时，所有成员一起退房走人
	if state == State.LEAVING or state == State.DONE:
		return
	if state == State.SEEK_CLINIC or state == State.WAITING_CURE or state == State.TREATMENT:
		return    # 治病中先不打断，治好后再跟着走
	var reception: Building = world.reception()
	if lodge != null and is_instance_valid(lodge) and reception != null:
		_go_to(reception, Purpose.CHECK_OUT)
	else:
		_leave_world()


func _choose_activity() -> void:
	if _should_check_out():
		# 同行小组一起走：由小组统一通知所有成员
		if party != null:
			if party.leaving:
				on_party_leave()
			else:
				party.begin_leave()
		else:
			_leave_world()
		return
	# 只有晚上才回度假屋休息（白天一直在外面活动）
	if GameClock.is_night() and lodge != null and is_instance_valid(lodge):
		_go_to(lodge, Purpose.REST)
		return
	# 白天也偶尔回房间歇一会儿
	if lodge != null and is_instance_valid(lodge) and randf() < 0.2:
		_go_to(lodge, Purpose.REST)
		return
	# 有时就在村里闲逛，不会一直消费（也避免在店铺之间来回横跳）
	if randf() > spend_frequency:
		_start_wander()
		return
	var prefers: Array = type_data.get("prefers", [])
	var facility: Building = world.random_target_building(prefers, -1.0, _last_facility)
	if facility == null:
		facility = world.random_target_building(prefers)
	if facility == null:
		_start_wander()
		return
	_last_facility = facility
	_go_to(facility, Purpose.CONSUME)
	# 同行小组大部分时间一起行动
	if party != null and not party.is_split_roll():
		for partner in party.partners_of(self):
			partner.follow_to(facility, Purpose.CONSUME)


func follow_to(building: Building, what: int) -> void:
	# 被同伴叫上一起去某处（治病中不响应）
	if state == State.SEEK_CLINIC or state == State.WAITING_CURE or state == State.TREATMENT:
		return
	if state == State.LEAVING or state == State.DONE:
		return
	_go_to(building, what)


func _start_wander() -> void:
	var cell: Vector2i = world.wander_cell_near(global_position)
	if cell.x == -9999:
		# 实在找不到闲逛点，就回招待厅旁边待着，不因此赶客人走
		var reception: Building = world.reception()
		if reception == null:
			_leave_world()
			return
		var entry: Vector2i = world.best_entry_cell(reception, global_position)
		cell = entry if entry.x != -9999 else reception.door_cell()
	target = null
	purpose = Purpose.WANDER
	_start_path_to(cell)
	state = State.TO_TARGET
	if party != null and not party.is_split_roll():
		for partner in party.partners_of(self):
			partner.follow_to_wander(cell)


func follow_to_wander(cell: Vector2i) -> void:
	if state == State.SEEK_CLINIC or state == State.WAITING_CURE or state == State.TREATMENT:
		return
	if state == State.LEAVING or state == State.DONE:
		return
	_start_path_to(cell)
	target = null
	purpose = Purpose.WANDER
	state = State.TO_TARGET


func _should_check_out() -> bool:
	var left: int = party.budget_left if party != null else budget_left
	if left < BUDGET_LEAVE:
		return true
	if mood < MOOD_LEAVE:
		return true
	if wants_lodging and nights >= max_nights and nights > 0:
		return true
	return false


func _pay_facility(b: Building) -> void:
	if party == null or party.budget_left <= 0:
		return
	var mood_factor := lerpf(0.7, 1.25, clampf(mood, 0.0, 100.0) / 100.0)
	var amount := int(round(float(b.spend_value()) * float(type_data.get("spend_multiplier", 1.0)) * mood_factor))
	amount = maxi(amount, 1)
	var paid := party.spend(amount)
	if paid <= 0:
		return
	budget_left = party.budget_left
	spent_total += paid
	b.total_earned += paid
	GameState.earn(paid, customer_name)
	_gain_mood(b.mood_bonus())
	_popup("+%s" % GameState.format_money(paid), Color(0.98, 0.85, 0.35))


func _leave_world() -> void:
	# 退房（如果还没退），然后沿小路走出地图
	if lodge != null and is_instance_valid(lodge):
		lodge.remove_guest(self)
		lodge = null
	if target != null and is_instance_valid(target) and target.visitors.has(self):
		target.remove_visitor(self)
	reparent(world.customers_root, true)
	_entrance_cell = world.entrance_cell(world.world_to_cell(global_position))
	_start_path_to(_entrance_cell)
	exit_point = world.cell_center(_entrance_cell)
	state = State.LEAVING


func leave_now() -> void:
	# 「休息一晚」跳过夜晚时用：当日往返的客人不留下过夜，夜里收益结算完直接走人。
	# 不做离场动画——反正回来时已经是第二天早上了。
	if state == State.DONE:
		return
	force_leave_current_building()
	if lodge != null and is_instance_valid(lodge):
		lodge.remove_guest(self)
		lodge = null
	if party != null and is_instance_valid(party):
		party.remove_member(self)
	state = State.DONE
	queue_free()


func force_leave(from_building: Building) -> void:
	# 建筑被拆除时调用
	if from_building and is_instance_valid(from_building):
		from_building.remove_visitor(self)
	if lodge != null and is_instance_valid(lodge):
		lodge.remove_guest(self)
		lodge = null
	reparent(world.customers_root, true)
	if from_building and is_instance_valid(from_building):
		var _exit_cell: Vector2i = world.nearest_entry_cell(from_building, world.world_to_cell(global_position))
		if _exit_cell.x != -9999:
			global_position = world.cell_center(_exit_cell)
	_leave_world()


# ---------- 移动 ----------
# _step_towards / _update_animation / _start_path_to / _follow_path 都在 actor.gd，
# 顾客这边只覆盖 _fix_start_cell()（从建筑里走出来）和 _on_stuck()。

func _tick_litter(scaled: float) -> void:
	# 垃圾：平均每位客人 2~3 个游戏日留下一个
	if _litter_interval <= 0.0:
		_litter_interval = randf_range(48.0, 72.0)     # 游戏内小时
	var hour_seconds := maxf(1.0, GameClock.cycle_length_seconds / 24.0)
	_litter_accum += scaled / hour_seconds
	if _litter_accum < _litter_interval:
		return
	_litter_accum = 0.0
	_litter_interval = randf_range(48.0, 72.0)
	world.spawn_litter(world.world_to_cell(global_position))


# ---------- 生病 ----------

func _roll_illness() -> bool:
	var cfg := DataRegistry.illness_config
	var chance := float(cfg.get("base_chance", 0.035))
	if target:
		chance += float(cfg.get("crowding_chance", 0.012)) * float(target.visitors.size())
	if randf() > chance:
		return false
	var max_level := int(DataRegistry.illness_config.get("max_level", 2))
	var pool := DataRegistry.illness_pool(max_level)
	if pool.is_empty():
		return false
	illness = pool[randi() % pool.size()]
	cure_left = _deadline_seconds()
	clinic = world.find_clinic(int(illness.get("level", 1)), global_position)
	if clinic:
		state = State.SEEK_CLINIC
		_start_path_to_building(clinic)
		_popup(str(illness.get("name", "生病")), Color(0.95, 0.55, 0.55))
	else:
		state = State.WAITING_CURE
		GameState.notice.emit("%s 得了%s，但没有能治疗的诊所" % [customer_name, str(illness.get("name", "病"))])
	return true


func _deadline_seconds() -> float:
	var hours := float(DataRegistry.illness_config.get("deadline_hours", 6.0))
	return hours * (GameClock.cycle_length_seconds / 24.0)


func _enter_clinic() -> void:
	if clinic == null:
		return
	clinic.accept_patient(self)
	reparent(clinic.interior, true)
	global_position = clinic.interior_point()
	_inside_building = clinic
	sprite.frame = DIR_DOWN
	state = State.WAITING_CURE


func begin_treatment(building: Building) -> void:
	state = State.TREATMENT
	treatment_left = building.treatment_seconds(illness)


func finish_treatment(building: Building) -> void:
	var fee := int(illness.get("fee", 500))
	building.total_earned += fee
	building.cured_count += 1
	GameState.earn(fee, "治疗")
	GameState.add_reputation(0.35)
	_gain_mood(float(DataRegistry.illness_config.get("cured_mood", 12.0)))
	_popup("治愈 +%s" % GameState.format_money(fee), Color(0.6, 0.95, 0.7))
	reparent(world.customers_root, true)
	_inside_building = null
	if building:
		var _exit_cell: Vector2i = world.nearest_entry_cell(building, world.world_to_cell(global_position))
		if _exit_cell.x != -9999:
			global_position = world.cell_center(_exit_cell)
	_choose_activity()


func _fail_cure() -> void:
	if clinic:
		clinic.release_patient(self)
	GameState.add_reputation(float(DataRegistry.illness_config.get("failed_reputation", -1.5)))
	GameState.notice.emit("%s 因病未得到治疗离开了" % customer_name)
	if clinic:
		var _exit_cell: Vector2i = world.nearest_entry_cell(clinic, world.world_to_cell(global_position))
		if _exit_cell.x != -9999:
			global_position = world.cell_center(_exit_cell)
	_leave_world()


# ---------- 小工具 ----------

func _popup(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 5)
	l.position = Vector2(-20, -48)
	add_child(l)
	var tween := create_tween()
	tween.tween_property(l, "position:y", l.position.y - 34.0, 0.9)
	tween.parallel().tween_property(l, "modulate:a", 0.0, 0.9)
	tween.tween_callback(l.queue_free)
