extends "res://scripts/actors/actor.gd"
class_name Customer
## 住客：带着预算来到度假村，在招待厅办理入住，住进度假屋之后四处消费，
## 直到「预算花完」或「心情掉到谷底」才回招待厅结账离开。
## 度假屋的钱按住宿天数在结账时结算。
## 走位（寻路 / 行走 / 取帧 / 卡住检测）继承自 actor.gd，和保洁工人共用一套。

enum State { TO_TARGET, INSIDE, SEEK_CLINIC, WAITING_CURE, TREATMENT, LEAVING, DONE }
enum Purpose { NONE, CHECK_IN, TO_ROOM, CONSUME, REST, CHECK_OUT, WANDER, QUEUE }

const MOOD_START := 70.0
const MOOD_LEAVE := 25.0        # 心情低于这个值就提前退房
const BUDGET_LEAVE := 300       # 预算少于这个数就当作花完了
const MOOD_DECAY_PER_HOUR := 0.35
const INSIDE_TIMEOUT := 25.0    # 在建筑里待超过这么久就被强行请出来
const QUEUE_GIVE_UP_SECONDS := 20.0  # 在门口排队最多等这么久（scaled 秒），等不到就换一家
const NEAR_CLAIM_TILES := 5          # 走到店铺几格以内才真正占位（使用位 / 预定位）
const NEAR_CLAIM_PX := NEAR_CLAIM_TILES * 32.0
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
var _sleeping_night := false     # 是否正在「过夜睡觉」（白天打盹不算，两种状态出的房门条件不同）
var _last_facility: Building = null
var _inside_building: Building = null    # 当前是否在某个建筑内部（用于保证能走出来）
var _fail_count := 0                     # 连续找不到路的次数
var _inside_time := 0.0                  # 在建筑里待了多久（防止卡在室内）
var _reserved_building: Building = null  # 我拿了谁家的「使用位」（走过去的路上也占着）
var _queued_building: Building = null    # 我排的是谁家的「预定位」（走到门口站着等）
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
	add_to_group("customers")       # 游客状态面板等按组枚举（住进建筑内部被换父节点也不受影响）
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


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# 兜底：不管从哪条路被销毁（离场 / 读档 / 清场…），都把自己占的位子还回去，
	# 否则店铺的访客名单、排队位、使用位预定会留下「僵尸占位」，越积越多
	if _reserved_building != null and is_instance_valid(_reserved_building):
		_reserved_building.release_use_slot()
	if _queued_building != null and is_instance_valid(_queued_building):
		_queued_building.leave_queue(self)
	if _inside_building != null and is_instance_valid(_inside_building):
		_inside_building.release_patient(self)
		_inside_building.remove_visitor(self)


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
	# 生病计时：deadline_hours（默认 6 游戏小时）内没得到治疗就带病离开。
	# 走路 / 消费 / 排队都照常倒计时，只有「正在治疗」不算。
	if not illness.is_empty() and state != State.TREATMENT \
			and state != State.LEAVING and state != State.DONE:
		cure_left -= scaled
		if cure_left <= 0.0:
			_fail_cure()
			return
	match state:
		State.TO_TARGET:
			if purpose == Purpose.WANDER:
				if _follow_path(scaled):
					action_left = randf_range(3.0, 8.0)
					state = State.INSIDE
			elif target == null or not is_instance_valid(target):
				_choose_activity()
				return
			else:
				var claimed_target := target
				_claim_near_facility()      # 走到 5 格以内才算占位（被抢先就顶到预定位）
				if target != claimed_target:
					return                  # 刚才重新选目标了：这一帧不再推进
				if _follow_path(scaled):
					# 走到选定的那个出入口（门口优先，或外圈上最近的一格）
					var entry_point: Vector2 = world.cell_center(_entry_cell)
					_step_towards(entry_point, scaled)
					if global_position.distance_to(entry_point) < 6.0:
						_arrive()
		State.INSIDE:
			if purpose == Purpose.QUEUE:
				_tick_queue(scaled)
				return
			# 过夜睡觉：天亮了、也到醒来时间（06:30~07:30 随机）才出门；
			# 白天打盹没有这个判定，按计时器自然结束。
			if purpose == Purpose.REST and _sleeping_night and not GameClock.is_night() and _sleep_done():
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
			# 在诊所里排队等治疗；诊所没了就另找一家，找不到就照常消费（不再原地罚站）
			if clinic == null or not is_instance_valid(clinic):
				if not _try_go_to_clinic():
					_choose_activity()
		State.TREATMENT:
			# 由医院推进治疗进度；医院没了（被拆 / 清场）就自己脱身，别永远停在「治疗中」
			if clinic == null or not is_instance_valid(clinic):
				clinic = null
				_force_exit()
		State.LEAVING:
			if _follow_path(scaled):
				_step_towards(exit_point, scaled)
				if global_position.distance_to(exit_point) < 8.0:
					state = State.DONE
					queue_free()
	z_index = int(global_position.y)


func _check_stuck(delta: float) -> void:
	if state == State.INSIDE or state == State.TREATMENT:
		# 在建筑里：回房过夜（含天亮前赖床）、看病治疗都属于正常停留，其余情况超时就被强行请出来
		var staying := state == State.TREATMENT \
			or (purpose == Purpose.REST and (_sleeping_night or GameClock.is_night())) \
			or purpose == Purpose.QUEUE      # 门口排队等位也是正常停留
		_inside_time = 0.0 if staying else _inside_time + delta
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
		_release_reservation()      # 改回房间：把店里的位子让出来
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
	_release_reservation()      # 保险：这里之后会重新决策，别把旧预定留着
	var building := _inside_building
	_inside_building = null
	reparent(world.customers_root, true)
	if building != null and is_instance_valid(building):
		building.release_patient(self)   # 候诊/治疗引用一并摘掉，别让诊所留着悬空引用
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


func _is_standing_still() -> bool:
	# 候诊时站在诊所里排队不动是正常的，不该被 5 秒「卡住」看门狗请出去
	return state == State.WAITING_CURE


func _track_night() -> void:
	# 每跨过一次 24 点算住了一晚
	var is_night := GameClock.current_hour() >= 24.0
	if is_night and not _in_night:
		_in_night = true
		if lodge != null:
			nights += 1
			# 刚好在房里打盹的：直接转入过夜睡眠；还在外面的，回房时再定
			if purpose == Purpose.REST and state == State.INSIDE:
				sleep_for_night()
	elif not is_night:
		if _in_night:
			_on_morning()         # 天亮了：为下一晚重掷醒来时间
		_in_night = false


func sleep_for_night() -> void:
	# 住进度假屋过夜时调用：定下今晚的醒来时间（06:30~07:30 之间随机），并一觉睡到天亮。
	# 注意：计时器每次都要重设——跨 24 点时可能已经定过醒来时间，但客人之后还可能
	# 去别处再逛一圈，回房时要把「睡到天亮」重新盖上；否则旧计时器一进房就到期，
	# 客人会立刻出房再回来，看起来是在度假屋里乱闪。
	if _wake_hour <= 0.0:
		roll_wake_hour()
	action_left = 9999.0
	_sleeping_night = true


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


func is_sleeping_for_night() -> bool:
	# 正在睡「昨晚的这一觉」（区别于白天回房打盹）：起床条件只看这个
	return is_resting_in_room() and _sleeping_night


func goto_room_for_night() -> bool:	# 「休息一晚」跳过夜晚时调用：直接把住客安置进自己的房间睡觉，
	# 不走路上浪费时间（回来时天已经亮了）。没有房间的返回 false，由调用方安排离场。
	if lodge == null or not is_instance_valid(lodge):
		return false
	_release_reservation()
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

func _facility_available(b: Building) -> bool:
	# 只是「现在看起来能去」的判断（选择目标时用）；真正的占位要走到 5 格以内才开始
	# （见 _claim_near_facility），这样远处的空位不会被长期占着
	if b == null or not is_instance_valid(b):
		return false
	return b.has_use_slot() or b.has_queue_slot()


func _claim_near_facility() -> void:
	# 走到店铺 5 格以内：这时才真正占位——先抢使用位；
	# 使用位已经被别人（先到的客人）占了，就顶到门口的预定位去排队；两个都满了就换一家
	var b := target
	if b == null or not is_instance_valid(b) or purpose != Purpose.CONSUME:
		return
	if _reserved_building == b or _queued_building == b:
		return          # 已经占上了
	var door_far := global_position.distance_to(world.cell_center(b.door_cell())) > NEAR_CLAIM_PX
	var entry_far := global_position.distance_to(world.cell_center(_entry_cell)) > NEAR_CLAIM_PX
	if door_far and entry_far:
		return          # 还没走到 5 格以内
	if b.reserve_use_slot():
		_reserved_building = b
		return
	if b.reserve_queue_slot():
		_queued_building = b
		return
	_choose_activity()      # 使用位和预定位都被占了：重新找一家


func _release_reservation() -> void:
	# 把使用位、预定位都还回去（改道 / 放弃 / 离场时调用）
	if _reserved_building != null:
		if is_instance_valid(_reserved_building):
			_reserved_building.release_use_slot()
		_reserved_building = null
	if _queued_building != null:
		if is_instance_valid(_queued_building):
			_queued_building.leave_queue(self)
		_queued_building = null


func _go_to(building: Building, what: int) -> void:
	if (_reserved_building != null and _reserved_building != building) \
			or (_queued_building != null and _queued_building != building):
		_release_reservation()      # 改去别处了：使用位、排队位都要让出来（漏了会导致僵尸队列）
	if _inside_building != null and _inside_building != building:
		force_leave_current_building()   # 在别家店里还没出来：先干净地摘掉占位再走
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
		# 到访提示由 CustomerSpawner 在进场时统一播报（明星 / 富商都会弹，含名字），这里不重复
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
		_sleeping_night = false
		action_left = randf_range(6.0, 12.0)
	state = State.INSIDE


func _enter_facility() -> void:
	var b := target
	if b == null or not is_instance_valid(b):
		_choose_activity()
		return
	if _reserved_building == b:
		b.release_use_slot()      # 使用位转成正式占位（不会双份计数）
		_reserved_building = null
		_enter_shop_now(b)
		return
	if _queued_building == b:
		# 走到门口：把在途预定位转成「站到队里」，等店里腾出使用位
		b.join_queue(self)
		purpose = Purpose.QUEUE
		action_left = QUEUE_GIVE_UP_SECONDS
		state = State.INSIDE
		return
	# 没预订（少见）：现场有空位就进，没有就排队，再不行换一家
	if b.has_use_slot():
		_enter_shop_now(b)
		return
	if b.reserve_queue_slot():
		_queued_building = b
		b.join_queue(self)
		purpose = Purpose.QUEUE
		action_left = QUEUE_GIVE_UP_SECONDS
		state = State.INSIDE
		return
	_choose_activity()


func _enter_shop_now(b: Building) -> void:
	# 真正进店消费（预定位顶上来时也走这里）
	b.add_visitor(self)
	reparent(b.interior, true)
	global_position = b.interior_point()
	_inside_building = b
	action_left = randf_range(3.0, 7.0)
	purpose = Purpose.CONSUME
	state = State.INSIDE


func promote_from_queue(b: Building) -> void:
	# 店里腾出使用位：排在最前面的客人顶上去（由店铺调用）
	if _queued_building != b:
		return          # 已经不排这家了（放弃 / 改道）
	_queued_building = null
	_enter_shop_now(b)


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
		Purpose.QUEUE:
			_retry_facility()
		Purpose.WANDER:
			_choose_activity()
		_:
			_choose_activity()


func _tick_queue(scaled: float) -> void:
	# 在门口预定位上排队：慢慢挪到自己那一格，等到店里腾出使用位（店铺会直接把人叫进来）
	if _queued_building == null or not is_instance_valid(_queued_building):
		_choose_activity()
		return
	var spot: Vector2 = _queued_building.queue_point(self)
	if global_position.distance_to(spot) > 2.0:
		_step_towards(spot, scaled)
	action_left -= scaled
	if action_left <= 0.0:
		_retry_facility()      # 等太久：能进就进，进不去就换一家


func _retry_facility() -> void:
	# 排队超时（或者被叫到时兜底自检）：有空位就进去，还是没有就换一家
	var b := target
	if b == null or not is_instance_valid(b):
		_choose_activity()
		return
	if _reserved_building == b:
		_release_reservation()
		_enter_shop_now(b)      # 使用位本来就是我的：直接进
		return
	if _queued_building == b:
		if b.has_use_slot():
			_queued_building = null
			b.leave_queue(self)     # 从队里摘掉：预定位也让出来
			_enter_shop_now(b)
			return
		_choose_activity()          # 等太久还没位子：放弃（释放由 _release_reservation 处理）
		return
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
	# 起床：今晚的醒来时间用掉了，下一晚回房时重新定
	_wake_hour = 0.0
	_sleeping_night = false
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
	# 生病：每次做新决定都先找诊所（有能治的就去看病，没有就照常消费）
	if _try_go_to_clinic():
		return
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
	if not _facility_available(facility):
		_start_wander()      # 使用位和预定位都被抢了（极少见）：先逛逛，下次再挑
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
	if state == State.INSIDE:
		return      # 正在店里消费 / 回房休息 / 门口排队：不跟着同伴走（半途走掉会留下僵尸占位）
	if _try_go_to_clinic():
		return      # 生病了：被同伴拉着走之前，先去看病
	if not _facility_available(building):
		_choose_activity()      # 这家店使用位、预定位都满了：自己另找一家
		return
	_go_to(building, what)


func _start_wander() -> void:
	# 有时就在村里闲逛，不会一直消费（也避免在店铺之间来回横跳）。
	# 关键：必须验证路径真的走得通——以前不检查，随机点落在「孤立的可走格」上时
	# 寻路会失败，而空路径会被当成「已到达」，客人就在原地一轮轮发呆（表现为卡在门口）。
	_release_reservation()      # 不消费了：把店里的位子让出来
	target = null
	purpose = Purpose.WANDER
	for _attempt in range(8):
		var cell: Vector2i = world.wander_cell_near(global_position)
		if cell.x == -9999:
			break
		if _start_path_to(cell):
			state = State.TO_TARGET
			if party != null and not party.is_split_roll():
				for partner in party.partners_of(self):
					partner.follow_to_wander(cell)
			return
	# 找不到能走到的闲逛点：去招待厅门口
	var reception: Building = world.reception()
	if reception != null:
		var entry: Vector2i = world.best_entry_cell(reception, global_position)
		if entry.x != -9999 and _start_path_to(entry):
			state = State.TO_TARGET
			return
	# 连招待厅都走不到（例如站在一块孤立地砖上）：短暂站一会儿再重新决策，
	# 下一轮会重新挑目标（能走到的店铺 / 招待厅），不会原地循环发呆
	action_left = randf_range(2.0, 4.0)
	state = State.INSIDE


func follow_to_wander(cell: Vector2i) -> void:
	if state == State.SEEK_CLINIC or state == State.WAITING_CURE or state == State.TREATMENT:
		return
	if state == State.LEAVING or state == State.DONE:
		return
	_release_reservation()      # 跟着同伴闲逛：不占店里的位子
	if not _start_path_to(cell):
		_start_wander()          # 路径不通：自己重新挑一个能走到的闲逛点，避免「原地到达」发呆
		return
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
	_release_reservation()
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
	_release_reservation()
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
		from_building.release_patient(self)
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
	if not illness.is_empty():
		return false      # 已经病着：不叠加新病，也不重置治疗计时
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
	_apply_illness(pool[randi() % pool.size()])
	return true


func _apply_illness(new_illness: Dictionary) -> void:
	# 生病：先试着去能治的诊所；村里没有能治的医院就照常消费 / 闲逛，
	# 同时开始计时——deadline_hours（默认 6 游戏小时）内没治上，就带病离开
	illness = new_illness
	cure_left = _deadline_seconds()
	action_left = 0.0
	_popup(str(illness.get("name", "生病")), Color(0.95, 0.55, 0.55))
	if _try_go_to_clinic():
		return
	GameState.notice.emit("%s 得了%s，但没有能治疗的诊所" % [customer_name, str(illness.get("name", "病"))])
	_choose_activity()      # 没地方治：继续原本的行程（消费 / 闲逛）


func _try_go_to_clinic() -> bool:
	# 生病时的「优先看病」：找到能治的诊所就走过去。每次做决定都会先试一次，
	# 所以玩家中途把医院盖起来 / 升级，病人下一站就会去看病。
	if illness.is_empty() or world == null:
		return false
	if state == State.SEEK_CLINIC or state == State.TREATMENT:
		return false
	var found: Building = world.find_clinic(int(illness.get("level", 1)), global_position)
	if found == null:
		return false
	if not _start_path_to_building(found):
		return false      # 路暂时走不通：先照常活动，下次再试
	_release_reservation()      # 改去看病：不占店里的位子
	clinic = found
	state = State.SEEK_CLINIC
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
	illness = {}              # 治好了：清掉病情，生病计时不再跑
	clinic = null
	cure_left = 0.0
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
	# 病情到此为止：不清掉的话，下一帧倒计时又会触发一次「未治离开」，
	# 病人被反复重新寻路、站在街上永远走不出去（stuck_probe 抓到的就是这个）
	illness = {}
	clinic = null
	cure_left = 0.0
	_leave_world()


# ---------- 调试快照（指令台用） ----------

func state_name() -> String:
	match state:
		State.TO_TARGET:
			return "TO_TARGET(去目标)"
		State.INSIDE:
			return "INSIDE(在建筑内)"
		State.SEEK_CLINIC:
			return "SEEK_CLINIC(去诊所)"
		State.WAITING_CURE:
			return "WAITING_CURE(候诊)"
		State.TREATMENT:
			return "TREATMENT(治疗中)"
		State.LEAVING:
			return "LEAVING(离场中)"
		State.DONE:
			return "DONE(已结束)"
	return "未知(%d)" % state


func purpose_name() -> String:
	match purpose:
		Purpose.NONE:
			return "NONE"
		Purpose.CHECK_IN:
			return "CHECK_IN(办入住)"
		Purpose.TO_ROOM:
			return "TO_ROOM(去房间)"
		Purpose.CONSUME:
			return "CONSUME(消费)"
		Purpose.REST:
			return "REST(休息)"
		Purpose.CHECK_OUT:
			return "CHECK_OUT(结账)"
		Purpose.WANDER:
			return "WANDER(闲逛)"
		Purpose.QUEUE:
			return "QUEUE(使用位满了，在门口排队)"
	return "未知(%d)" % purpose


func stuck_reason() -> String:
	# 供指令台 /stuck 用：返回「看起来卡住了」的原因，正常时返回空串
	if world == null:
		return ""
	if state == State.WAITING_CURE:
		# 在诊所里排队是正常等待；「候诊却不在诊所里」才是异常
		if clinic == null or not is_instance_valid(clinic):
			return "候诊中却没在诊所里（治疗时限还剩 %.0f 秒）" % cure_left
		return ""
	if state == State.INSIDE or state == State.TREATMENT:
		if purpose == Purpose.QUEUE:
			return ""      # 在门口排队等位：正常状态，不算卡住
		if _inside_time > INSIDE_TIMEOUT * 0.6:
			return "在建筑里停留 %.1f 秒（超过 %.0f 秒会被请出）" % [_inside_time, INSIDE_TIMEOUT]
		return ""
	var cell: Vector2i = world.world_to_cell(global_position)
	if not world.is_walkable(cell):
		return "站在不可通行的格子上 %s" % str(cell)
	if _stuck_time > 2.0:
		return "位置 %.1f 秒没有变化" % _stuck_time
	if _no_path_time > 0.8:
		return "该走路却没有路径 %.1f 秒" % _no_path_time
	return ""


func debug_report() -> String:
	# 完整状态快照：指令台里显示（可复制），同时写进日志文件，排查「卡住 / 行为异常」用
	var lines: Array = []
	lines.append("【游客】%s ｜ 名册 id: %s ｜ 节点: %s" % [
		customer_name, str(type_data.get("id", "?")), name])
	var ident_text := "普通游客"
	if not identities.is_empty():
		var ident_parts: Array = []
		for i in identities:
			match str(i):
				"star":
					ident_parts.append("明星")
				"tycoon":
					ident_parts.append("富商")
				"ordinary":
					ident_parts.append("普通游客")
				_:
					ident_parts.append(str(i))
		ident_text = "+".join(ident_parts)
	var stay_text := "单日往返"
	if wants_lodging:
		stay_text = "多日（最多 %d 晚，已住 %d 晚）" % [max_nights, nights]
	var team_size := 1
	if party != null and is_instance_valid(party):
		team_size = party.members.size()
	lines.append("身份：%s ｜ 停留：%s ｜ 队伍：%d 人（共享预算）" % [ident_text, stay_text, team_size])
	if party != null and is_instance_valid(party):
		var partner_text: Array = []
		for p in party.partners_of(self):
			if is_instance_valid(p):
				partner_text.append("%s(%s,%s)" % [
					str(p.customer_name), str(p.type_data.get("id", "?")), str(p.state_name())])
		if not partner_text.is_empty():
			lines.append("队友：%s" % "、".join(partner_text))
	lines.append("状态：%s ｜ 目的：%s ｜ 动作剩余 %.1fs" % [
		state_name(), purpose_name(), action_left])
	var budget_line := "心情 %.0f/100 ｜ 预算 %d/%d（已花 %d）｜ 速度 %.1f ｜ 单车 %s" % [
		mood, budget_left, budget_total, spent_total, speed, str(has_bike)]
	lines.append(budget_line)
	if world == null:
		lines.append("位置：%s（找不到 world，快照不完整）" % str(global_position))
		return "\n".join(lines)
	var cell: Vector2i = world.world_to_cell(global_position)
	lines.append("位置：px(%.1f, %.1f) ｜ 格 %s（可走 %s）｜ 父节点 %s" % [
		global_position.x, global_position.y, str(cell), str(world.is_walkable(cell)),
		str(get_parent().name) if get_parent() != null else "-"])
	var target_text := "无"
	if target != null and is_instance_valid(target):
		var door_cell: Vector2i = target.door_cell()
		target_text = "%s「%s」格%s ｜ 门口 %s（可走 %s）｜ 可达 %s" % [
			str(target.id), target.display_name(), str(target.cell), str(door_cell),
			str(world.is_walkable(door_cell)), str(world.building_reachable(target))]
	lines.append("目标：%s" % target_text)
	var entry_dist := -1.0
	var entry_walk := false
	if _entry_cell.x != 0 or _entry_cell.y != 0:
		entry_walk = world.is_walkable(_entry_cell)
		entry_dist = global_position.distance_to(world.cell_center(_entry_cell))
	lines.append("本次入口格：%s（可走 %s）｜ 到入口 %.1f px" % [
		str(_entry_cell), str(entry_walk), entry_dist])
	var path_text := "无路径"
	if has_path():
		var next_cell: Vector2i = _path[_path_index]
		path_text = "有（共 %d 步，进度 %d）｜ 下一路点 %s（%.1f px）" % [
			_path.size(), _path_index, str(next_cell),
			global_position.distance_to(world.cell_center(next_cell))]
	lines.append("路径：%s" % path_text)
	lines.append("计时：静止 %.1fs ｜ 无路径 %.1fs ｜ 室内 %.1fs ｜ 连续失败 %d" % [
		_stuck_time, _no_path_time, _inside_time, _fail_count])
	var inside_text := "无"
	if _inside_building != null and is_instance_valid(_inside_building):
		inside_text = str(_inside_building.id)
	var lodge_text := "无"
	if lodge != null and is_instance_valid(lodge):
		lodge_text = "%s（%d 晚，醒来 %.1f 点）" % [str(lodge.id), nights, _wake_hour]
	var illness_text := "无"
	if not illness.is_empty():
		illness_text = "%s（治疗时限还剩 %.1fs ｜ 治疗剩余 %.1fs ｜ 诊所 %s）" % [
			str(illness.get("name", "?")), cure_left, treatment_left,
			str(clinic.id) if (clinic != null and is_instance_valid(clinic)) else "无"]
	lines.append("室内：%s ｜ 住宿：%s ｜ 病情：%s" % [inside_text, lodge_text, illness_text])
	return "\n".join(lines)


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
