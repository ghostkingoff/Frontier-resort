extends Node
## 冒烟测试的「内容回归」部分：建筑表 / 知名度解锁 / 卫生间 / 共享单车 / 保洁工人 / 垃圾与心情。
## 由 smoke_runner.gd 在 _finish() 里挂载，共用它的 world 与 checks。
##
## 拆出来的原因：smoke_runner.gd 原本 1100 多行，这一块是历次内容扩充堆上去的，
## 单独成文件以后加新系统的回归检查不用在 1000 行的文件里找位置。

const JANITOR_SCRIPT := preload("res://scripts/customers/janitor.gd")

var runner: Node          # smoke_runner 实例：读它的 world / checks
var world: Node2D
var checks: Array


func setup(runner_ref: Node) -> void:
	runner = runner_ref
	world = runner_ref.world
	checks = runner_ref.checks


func run() -> void:
	# 1. 两份建筑配置不能有同名 id（有的话扩充表会静默覆盖主表，改了数据却没反应）
	var extra_ids: Dictionary = {}
	for item in _read_data_file("res://data/buildings_extra.json").get("buildings", []):
		extra_ids[str(item.get("id", ""))] = true
	var clashes: Array = []
	for item in _read_data_file("res://data/buildings.json").get("buildings", []):
		var id := str(item.get("id", ""))
		if extra_ids.has(id):
			clashes.append(id)
	checks.append("建筑配置冲突：同名 id %d 个%s" % [
		clashes.size(), "" if clashes.is_empty() else "（%s，实际生效的是扩充表）" % ", ".join(clashes)])

	# 2. 建造菜单里实际会显示多少栋（hidden 的不显示）
	var visible := 0
	var hidden := 0
	for id in DataRegistry.building_order:
		if bool(DataRegistry.get_building(id).get("hidden", false)):
			hidden += 1
		else:
			visible += 1
	checks.append("建筑表：%d 种（建造菜单显示 %d ｜ 已淘汰 hidden %d）" % [
		DataRegistry.building_order.size(), visible, hidden])

	# 3. 知名度解锁门槛：构造玩家知名度 500，核对门槛判定
	var fame_before: float = GameState.fame
	GameState.fame = 500.0
	var want := 0
	var mismatched: Array = []
	for id in DataRegistry.building_order:
		var data: Dictionary = DataRegistry.get_building(id)
		var need := int(data.get("unlock_fame", 0))
		if need <= 0 or need > 600:
			continue
		want += 1
		if (GameState.fame >= float(need)) != (need <= 500):
			mismatched.append("%s(%d)" % [str(data.get("name", id)), need])
	checks.append("知名度解锁：门槛在 (0, 600] 的建筑 %d 栋 ｜ 知名度 500 时判定不一致 %d 个%s" % [
		want, mismatched.size(), "" if mismatched.is_empty() else "（%s）" % ", ".join(mismatched)])
	GameState.fame = fame_before

	# 3b. 口碑规则：新游戏初始 50、下限 0、上限 200
	var rep_backup: float = GameState.reputation
	GameState.add_reputation(-9999.0)
	var rep_floor: float = GameState.reputation
	GameState.add_reputation(9999.0)
	var rep_cap: float = GameState.reputation
	GameState.reputation = rep_backup
	checks.append("口碑规则：初始 %.0f ｜ 下限 %.0f ｜ 上限 %.0f（应为 50 / 0 / 200）" % [
		GameState.REPUTATION_START, rep_floor, rep_cap])

	# 3c. 客流量：目标 =（知名度系数 × 口碑系数）×（开门店铺 × 2）
	var flow_spawner: Node = world.get_parent().get_node_or_null("CustomerSpawner")
	if flow_spawner:
		var flow_shops: int = flow_spawner.open_business_count()
		var flow_fame_backup: float = GameState.fame
		GameState.fame = 100.0
		GameState.reputation = 50.0
		var flow_low: float = flow_spawner.target_flow()
		var flow_low_people: int = flow_spawner.target_people()
		GameState.fame = 1000.0
		GameState.reputation = 200.0
		var flow_cap: float = flow_spawner.target_flow()
		var flow_cap_people: int = flow_spawner.target_people()
		GameState.fame = flow_fame_backup
		GameState.reputation = rep_backup
		checks.append("客流量（向上取整）：%s 开门店铺 %d 家 ｜ 开局 %.2f → %d 人（应 %d）｜ 满配 %.2f → %d 人（上限 = 店铺×2 = %.0f）" % [
			GameClock.time_text(), flow_shops, flow_low, flow_low_people,
			int(ceil(0.15 * float(flow_shops) * 2.0)), flow_cap, flow_cap_people, float(flow_shops) * 2.0])
		# 计数规则：已入住度假屋的不计入客流量
		var flow_lodging: Building = runner._find_building("lodge_ordinary")
		if flow_lodging:
			var flow_base_count: int = flow_spawner.current_flow()
			var flow_probe := Customer.new()
			world.customers_root.add_child(flow_probe)
			flow_probe.setup(DataRegistry.customer_types[0], world, world.random_entrance())
			var flow_plus: int = flow_spawner.current_flow()
			flow_probe.lodge = flow_lodging
			var flow_lodged: int = flow_spawner.current_flow()
			flow_probe.lodge = null
			flow_probe.queue_free()
			checks.append("客流量计数：普通游客计入 %s ｜ 标记入住后不计 %s（应为 true / true）" % [
				str(flow_plus == flow_base_count + 1), str(flow_lodged == flow_base_count)])
	else:
		checks.append("客流量：找不到 CustomerSpawner，跳过")

	# 4. 占地格数（10-07 已从代码里的临时覆盖搬进 data/*.json）
	var lodge_cells: Array = []
	for id in ["lodge_ordinary", "lodge_nature", "lodge_modern"]:
		lodge_cells.append("%s %s" % [
			str(DataRegistry.get_building(id).get("name", id)),
			runner._str_footprint(DataRegistry.get_building(id))])
	checks.append("度假屋规格：%s" % " ｜ ".join(lodge_cells))
	var too_big: Array = []
	for id in DataRegistry.building_order:
		var f: Array = DataRegistry.get_building(id).get("footprint", [4, 4])
		if int(f[0]) <= 0 or int(f[1]) <= 0 or int(f[0]) > 8 or int(f[1]) > 8:
			too_big.append("%s%s" % [id, f])
	checks.append("占地格数：全部在 1~8 格内 = %s%s" % [
		str(too_big.is_empty()), "" if too_big.is_empty() else "（越界：%s）" % ", ".join(too_big)])

	# 5. 三个新机制：公共卫生间 / 共享单车 / 保洁间
	#    注意：客人只会去「门口连得上主路」的建筑，所以测试里必须像玩家一样把路铺到门口，
	#    否则 random_target_building() 根本不会把它们放进候选池。
	var toilet: Building = _place_and_connect("amenity_toilet")
	var bike: Building = _place_and_connect("amenity_bike")
	# 保洁间直接盖在已经有地砖的地方，这样它门口就是客人会走的路（垃圾也只落在这里）
	var cleaner: Building = _place_on_pavement("amenity_cleaning")
	checks.append("服务设施：公共卫生间 %s ｜ 共享单车 %s ｜ 保洁间 %s ｜ 三家都接上主路 %s" % [
		str(toilet != null), str(bike != null), str(cleaner != null),
		str(toilet != null and world.building_reachable(toilet)
			and bike != null and world.building_reachable(bike)
			and cleaner != null and world.building_reachable(cleaner))])
	if toilet and bike and cleaner and world.reception():
		checks.append("自助设施：卫生间/单车 员工编制 %d/%d ｜ 缺员工心情惩罚 %d/%d（应为 0）｜ 保洁间编制 %d" % [
			toilet.staff_slots(), bike.staff_slots(),
			int(toilet.staff_mood_bonus()), int(bike.staff_mood_bonus()), cleaner.staff_slots()])
		# 客人真的会挑中这三个设施（random_target_building 的池子里必须包含它们）
		var picked: Dictionary = {}
		for _i in range(240):
			var target_b: Building = world.random_target_building([], 12.0)
			if target_b:
				picked[target_b.id] = true
		checks.append("客人可选：卫生间进池 %s ｜ 共享单车进池 %s ｜ 保洁间进池 %s" % [
			str(picked.has("amenity_toilet")), str(picked.has("amenity_bike")),
			str(picked.has("amenity_cleaning"))])

		# 卫生间：不花钱，只涨心情（服务效果在客人「离开设施」时结算）
		var guest := Customer.new()
		world.customers_root.add_child(guest)
		guest.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		var money_0 := GameState.money
		var budget_0: int = guest.budget_left
		var mood_0: float = guest.mood
		guest.target = toilet
		guest.purpose = Customer.Purpose.CONSUME
		guest._enter_facility()
		guest._finish_consume()
		checks.append("公共卫生间：心情 %.1f → %.1f（+%.1f）｜ 客人预算 %d → %d ｜ 收入 %d（应为 0）" % [
			mood_0, guest.mood, guest.mood - mood_0, budget_0, guest.budget_left,
			GameState.money - money_0])

		# 共享单车：租一次，速度翻倍
		var speed_0: float = guest.speed
		guest.target = bike
		guest.purpose = Customer.Purpose.CONSUME
		guest._enter_facility()
		guest._finish_consume()
		checks.append("共享单车：速度 %.0f → %.0f（×%.1f）｜ 已租 %s" % [
			speed_0, guest.speed, guest.speed / maxf(speed_0, 1.0), str(guest.has_bike)])
		guest.queue_free()
	else:
		checks.append("服务设施：建造或接路失败，跳过机制检查")

	# 6. 保洁工人：雇了人才会出现，会在外面走动，只清负责范围（半径 40 格）内的垃圾
	if cleaner:
		cleaner = _setup_cleaning_scene(cleaner)
		if cleaner:
			_run_janitor_checks(cleaner)
		else:
			checks.append("保洁工人：没找到能贴着地砖的保洁间位置，跳过（场地排不下）")
	else:
		checks.append("保洁工人：保洁间没建起来，跳过")

	# 7. 垃圾会持续掉心情：同一个客人、同一位置，做「干净 vs 脏」两次对照
	_run_litter_mood_check()

	# 8. 玩家角色与自我操纵模式
	var avatar: Node2D = get_tree().get_first_node_in_group("player_avatar")
	var hud: Node = world.get_parent().get_node_or_null("HUD")
	var reception: Building = world.reception()
	var cam: Node = world.get_parent().get_node_or_null("Camera")
	if avatar == null or hud == null or reception == null:
		checks.append("玩家角色：缺少角色 / HUD / 招待厅，跳过")
	else:
		var start_inside: bool = avatar.inside_reception
		hud.set_player_control(true)
		var following: bool = cam != null and cam.follow_target == avatar
		for _i in range(20):
			avatar.move_step(Vector2(1, 0), 0.02)          # 在厅里一直往右走
		var stayed: bool = avatar.inside_reception \
			and avatar.global_position.distance_to(reception.global_position) < 220.0
		var leave_ok: bool = avatar.try_interact() == "leave" and not avatar.inside_reception
		var near_door: bool = avatar.global_position.distance_to(world.cell_center(reception.door_cell())) < 8.0
		var use_ok: bool = avatar.try_interact() == "use_reception"
		var popup_ok: bool = hud.player_confirm.visible
		hud._on_player_confirm_yes()
		var home_ok: bool = avatar.inside_reception and not hud.player_control_on()
		# 退出模式后停在原地；不在操纵模式时 24 点结算会把他放回厅里
		hud.set_player_control(true)
		avatar.leave_reception()
		var pos_out: Vector2 = avatar.global_position
		hud.set_player_control(false)
		var kept: bool = avatar.global_position.distance_to(pos_out) < 0.5 and not avatar.inside_reception
		hud.reset_player_if_idle()
		var reset_ok: bool = avatar.inside_reception
		checks.append("玩家角色：初始在厅内 %s ｜ 厅内走不出去 %s ｜ F 离厅到门口 %s ｜ 门口 F 请求回厅 %s（弹窗 %s）｜ 确认回厅并退模式 %s ｜ 相机跟随 %s ｜ 退出停原地 %s ｜ 结算归位 %s" % [
			str(start_inside), str(stayed), str(leave_ok and near_door), str(use_ok), str(popup_ok),
			str(home_ok), str(following), str(kept), str(reset_ok)])
		# 碰撞框：走到「可行走格子的下边界」时应停住（脚不越到不可行走的地砖上）；贴着边界也能横向走
		var edge_cell := Vector2i(-1, -1)
		for cell in world.walkable_path_cells():
			if not world.is_walkable(cell + Vector2i(0, 1)):
				edge_cell = cell
				break
		if edge_cell.x >= 0:
			avatar.detach_to(world.cell_center(edge_cell))
			for _i in range(40):
				avatar.move_step(Vector2(0, 1), 0.02)
			var boundary_y: float = float(edge_cell.y + 1) * 32.0
			var foot_ok: bool = avatar.global_position.y + 16.0 <= boundary_y + 0.6
			var x_before: float = avatar.global_position.x
			for _i in range(10):
				avatar.move_step(Vector2(1, 0), 0.02)
			var slide_ok: bool = absf(avatar.global_position.x - x_before) > 0.5
			# 往上：上半身允许「半截出格」（俯视角）；身体框上边界贴到交界线就停
			var top_cell := Vector2i(-1, -1)
			for cell in world.walkable_path_cells():
				if not world.is_walkable(cell + Vector2i(0, -1)):
					top_cell = cell
					break
			var up_ok := false
			var up_edge := 0.0
			if top_cell.x >= 0:
				avatar.detach_to(world.cell_center(top_cell))
				for _i in range(40):
					avatar.move_step(Vector2(0, -1), 0.02)
				var boundary_top: float = float(top_cell.y) * 32.0
				up_edge = boundary_top - (avatar.global_position.y - 16.0)
				up_ok = up_edge > 10.0 and avatar.global_position.y + 1.0 >= boundary_top - 0.6
			checks.append("玩家碰撞：下边界停住（脚不越线）%s ｜ 贴边可横移 %s ｜ 往上半截出格 %s（越过 %.0f 像素）" % [
				str(foot_ok), str(slide_ok), str(up_ok), up_edge])
			avatar.reset_to_reception()
		else:
			checks.append("玩家碰撞：没找到下边界测试点，跳过")

	# 9. 闲逛寻路健壮性：站在孤立地砖上时，不能出现「标记在走却没有路径」（卡门口发呆的根因）
	var iso_cell := Vector2i(5, 5)
	world.set_ground(iso_cell, World.GROUND_PATH)
	var iso_probe := Customer.new()
	world.customers_root.add_child(iso_probe)
	iso_probe.setup(DataRegistry.customer_types[0], world, world.cell_center(iso_cell))
	var wander_bad := 0
	for _i in range(20):
		iso_probe._start_wander()
		if iso_probe.state == Customer.State.TO_TARGET and not iso_probe.has_path():
			wander_bad += 1
	checks.append("闲逛寻路：孤立地砖上 20 次抽样，「无路径却标记在走」%d 次（应为 0）" % wander_bad)
	iso_probe.queue_free()
	world.set_ground(iso_cell, World.GROUND_WILD)

	# 9b. 使用位 / 预定位（排队）：使用位 1 级 3 人每级 +1；使用位满了客人去门口预定位排队
	var cap_shop: Building = runner._find_building("food_diner")
	if cap_shop == null:
		for b in world.buildings:
			if b.capacity() > 0 and not b.is_lodging() and not b.is_reception():
				cap_shop = b
				break
	if cap_shop == null:
		checks.append("同时招待人数：没有可检查的设施，跳过")
	else:
		var cap_lv1: int = cap_shop.capacity()
		cap_shop.set_level(2)
		var cap_lv2: int = cap_shop.capacity()
		cap_shop.set_level(3)
		var cap_lv3: int = cap_shop.capacity()
		cap_shop.set_level(1)
		# 1) 使用位预定：拿到就算占住（人在路上也算），放满后第 4 个被拒
		var u1: bool = cap_shop.reserve_use_slot()
		var u2: bool = cap_shop.reserve_use_slot()
		var u3: bool = cap_shop.reserve_use_slot()
		var u4: bool = cap_shop.reserve_use_slot()
		var reserve_full_ok: bool = u1 and u2 and u3 and not u4 and not cap_shop.has_use_slot()
		cap_shop.reserved = 0
		var reserve_free_ok: bool = cap_shop.has_use_slot()
		# 使用位 / 预定位：使用位 = 店里消费的位子；预定位 = 门口的排队位（数量相同）
		# 2) 顾客占满使用位 → has_use_slot 为 false，但还能拿预定位去排队
		var dummies: Array = []
		for _i in range(cap_shop.capacity()):
			var d := Node2D.new()
			world.add_child(d)
			cap_shop.add_visitor(d)
			dummies.append(d)
		var full_ok: bool = not cap_shop.has_use_slot() and cap_shop.has_queue_slot()
		var q1: bool = cap_shop.reserve_queue_slot()
		var q2: bool = cap_shop.reserve_queue_slot()
		var q3: bool = cap_shop.reserve_queue_slot()
		var q4: bool = cap_shop.reserve_queue_slot()
		var queue_full_ok: bool = q1 and q2 and q3 and not q4 and not cap_shop.has_queue_slot()
		cap_shop.queue_reserved = 0
		# 3) 5 格内才占位：远处不算占用；走到 5 格内被抢先 → 顶到预定位
		var cap_probe := Customer.new()
		world.customers_root.add_child(cap_probe)
		cap_probe.setup(DataRegistry.customer_types[0], world, world.random_entrance(), "排队甲")
		cap_probe.target = cap_shop
		cap_probe.purpose = Customer.Purpose.CONSUME
		cap_probe.global_position = world.cell_center(cap_shop.door_cell()) + Vector2(0, 40 * 32)
		cap_probe._claim_near_facility()
		var far_ok: bool = cap_probe._reserved_building == null and cap_probe._queued_building == null \
			and cap_shop.reserved == 0 and cap_shop.queue_reserved == 0
		cap_probe.global_position = world.cell_center(cap_shop.door_cell())
		cap_probe._claim_near_facility()      # 使用位满着 → 被顶到预定位
		var bumped_ok: bool = cap_probe._queued_building == cap_shop and cap_shop.queue_reserved == 1
		cap_probe._enter_facility()           # 走到门口：进队（还不是访客）
		var queued_ok: bool = bumped_ok and cap_shop.queued.has(cap_probe) \
			and not cap_shop.visitors.has(cap_probe) and cap_probe.purpose == Customer.Purpose.QUEUE
		var freed: Node2D = dummies.pop_back()
		cap_shop.remove_visitor(freed)        # 走一位：自动把队首顶上去
		freed.queue_free()
		var promoted_ok: bool = cap_shop.visitors.has(cap_probe) \
			and not cap_shop.queued.has(cap_probe) and cap_probe.purpose == Customer.Purpose.CONSUME
		# 4) 有空使用位的客人：5 格内占位直接拿到使用位；放弃要还回来
		cap_shop.remove_visitor(cap_probe)
		cap_probe.global_position = world.cell_center(cap_shop.door_cell()) + Vector2(0, 40 * 32)
		cap_probe._claim_near_facility()
		cap_probe.global_position = world.cell_center(cap_shop.door_cell())
		cap_probe._claim_near_facility()
		var use_claim_ok: bool = cap_probe._reserved_building == cap_shop and cap_shop.reserved == 1
		cap_probe._start_wander()             # 不等了，去闲逛
		var given_back_ok: bool = cap_shop.reserved == 0 and cap_probe._reserved_building == null
		cap_probe.queue_free()
		# 5) 队伍位置：第一位就是门口那一格，后面的沿街往下排
		var door_cell: Vector2i = cap_shop.door_cell()
		var line_ok: bool = cap_shop.queue_cell(0) == door_cell
		var below: Vector2i = door_cell + Vector2i(0, 1)
		if world.is_walkable(below):
			line_ok = line_ok and cap_shop.queue_cell(1) == below
		for d in dummies:
			cap_shop.remove_visitor(d)
			d.queue_free()
		var lamp_text := "本模式没建路灯"
		var lamp: Building = runner._find_building("street_lamp")
		if lamp != null:
			lamp_text = "路灯同时招待 %d（应 0）" % lamp.capacity()
		checks.append("使用位/预定位：%s 1 级 %d 人（应 3）｜ 2 级 %d（应 4）｜ 3 级 %d（应 5）｜ 使用位满仍可排队 %s ｜ 预定位也占满 %s ｜ 远处不占位 %s ｜ 5 格内被抢先→顶预定位 %s ｜ 到门口进队 %s ｜ 让位后队首顶上 %s ｜ 有空位时拿使用位 %s ｜ 放弃后归还 %s ｜ 在途占使用位 %s ｜ 释放后空出 %s ｜ 队伍位置 %s ｜ %s" % [
			str(cap_shop.id), cap_lv1, cap_lv2, cap_lv3, str(full_ok), str(queue_full_ok),
			str(far_ok), str(bumped_ok), str(queued_ok), str(promoted_ok),
			str(use_claim_ok), str(given_back_ok),
			str(reserve_full_ok), str(reserve_free_ok), str(line_ok), lamp_text])

	# 9c. 有空房时优先来住宿客人（而且不会放「房位住不下」的组合）
	var lodge_spawner: Node = world.get_parent().get_node_or_null("CustomerSpawner")
	if lodge_spawner == null:
		checks.append("住宿优先：找不到 CustomerSpawner，跳过")
	else:
		var free_slots: int = lodge_spawner.max_free_room_slots()
		var multi_hits := 0
		var oversize := 0
		var picked := 0
		for _i in range(120):
			var lp_pick: Dictionary = lodge_spawner._pick_type()
			if lp_pick.is_empty():
				continue
			picked += 1
			if str(lp_pick.get("stay", "")) == "multi_day":
				multi_hits += 1
				if int(lodge_spawner._party_size(lp_pick)) > free_slots:
					oversize += 1
		var share := 0.0 if picked == 0 else 100.0 * float(multi_hits) / float(picked)
		# 「超出房位」只可能来自那 15% 的普通池（会住不下、当天往返），所以放宽到 ≤20%
		var oversize_ppk := 0.0 if picked == 0 else 100.0 * float(oversize) / float(picked)
		var priority_ok: bool = free_slots > 0 and picked > 0 and share >= 65.0 and oversize_ppk <= 20.0
		checks.append("住宿优先：最大空房位 %d（空房总位数 %d，都会算进补人目标）｜ 120 次抽样里住宿客 %d / %d（%.0f%%，应 ≥65%%）｜ 住不下的 %d（%.0f%%，应 ≤20%%，只来自普通池）｜ %s" % [
			free_slots, lodge_spawner.free_room_people(), multi_hits, picked, share,
			oversize, oversize_ppk, str(priority_ok)])

	# 10. 游客状态面板：分栏 / 头像 / 点名字对焦 + 橙色高亮 / 详情 / 三种退出对焦方式
	var vpanel: Node = world.get_parent().get_node_or_null("VisitorPanel")
	if vpanel == null:
		checks.append("游客面板：找不到 VisitorPanel，跳过")
	else:
		var star_type := {}
		for t in DataRegistry.customer_types:
			var ids_t: Array = t.get("identities", [])
			if ids_t.has("star"):
				star_type = t
				break
		var probe_party := Party.new()
		probe_party.setup(6000)
		var probe_a := Customer.new()
		world.customers_root.add_child(probe_a)
		probe_a.setup(DataRegistry.customer_types[0], world, world.random_entrance(), "面板甲", probe_party)
		var probe_b := Customer.new()
		world.customers_root.add_child(probe_b)
		probe_b.setup(DataRegistry.customer_types[0], world, world.random_entrance(), "面板乙", probe_party)
		var probe_star := Customer.new()
		world.customers_root.add_child(probe_star)
		probe_star.setup(star_type, world, world.random_entrance(), "面板星")
		vpanel.set_tab(0)
		vpanel.toggle()
		var opened_ok: bool = vpanel.is_open()
		var normal_listed: Array = vpanel.listed_names()
		var split_normal_ok: bool = normal_listed.has("面板甲") and not normal_listed.has("面板星")
		var portrait_ok: bool = int(vpanel.listed_count()) > 0 \
			and int(vpanel.portrait_ready_count()) == int(vpanel.listed_count())
		vpanel.set_tab(1)
		var special_listed: Array = vpanel.listed_names()
		var split_special_ok: bool = special_listed.has("面板星") and not special_listed.has("面板甲")
		vpanel.set_tab(0)
		vpanel.focus_customer(probe_a)
		var cam_view: Node = world.get_parent().get_node_or_null("Camera")
		var follow_ok: bool = cam_view != null and cam_view.follow_target == probe_a
		var hl_ok: bool = vpanel.highlighted() == probe_a
		var det: Dictionary = vpanel.details()
		var state_text := str(det.get("state", ""))
		var partner_ok: bool = bool(det.get("partner_visible", false)) and str(det.get("partner", "")).contains("面板乙")
		var detail_ok: bool = state_text.begins_with("状态：") \
			and str(det.get("mood", "")).begins_with("心情：") \
			and str(det.get("spent", "")).begins_with("已消费：")
		# 再点一次同一个名字 → 退出对焦，相机停在原地
		var cam_pos: Vector2 = cam_view.position
		vpanel.focus_customer(probe_a)
		var again_ok: bool = not vpanel.is_focused() and cam_view.follow_target == null
		var stay_ok: bool = cam_view.position.distance_to(cam_pos) < 0.5
		# 顶栏「游客状态」按钮：第一次点退出对焦（面板仍开着），再点关闭
		vpanel.focus_customer(probe_b)
		hud._toggle_visitor_panel()
		var button_exit_ok: bool = not vpanel.is_focused() and vpanel.is_open()
		hud._toggle_visitor_panel()
		var closed_ok: bool = not vpanel.is_open()
		var released_ok: bool = cam_view == null or cam_view.follow_target == null
		var cleared_ok: bool = vpanel.highlighted() == null
		probe_a.queue_free()
		probe_b.queue_free()
		probe_star.queue_free()
		checks.append("游客面板：开启 %s ｜ 分栏（普通含新客 %s ｜ 明星栏有明星且不串栏 %s）｜ 头像 %d/%d ｜ 对焦 %s ｜ 橙色高亮 %s ｜ 状态/心情/消费 %s（%s）｜ 伙伴「面板乙」%s ｜ 再点名字退出对焦 %s（相机留在原地 %s）｜ 顶栏按钮退出对焦 %s 再点关闭 %s ｜ 关闭后解除跟随 %s、清高亮 %s" % [
			str(opened_ok and closed_ok), str(split_normal_ok), str(split_special_ok),
			int(vpanel.portrait_ready_count()), int(vpanel.listed_count()),
			str(follow_ok), str(hl_ok), str(detail_ok), state_text, str(partner_ok),
			str(again_ok), str(stay_ok), str(button_exit_ok), str(closed_ok),
			str(released_ok), str(cleared_ok)])

	# 10b. 游客不重复出现 + 明星 / 富商到来提示
	var spawner2: Node = world.get_parent().get_node_or_null("CustomerSpawner")
	if spawner2 == null:
		checks.append("游客不重复：找不到 CustomerSpawner，跳过")
	else:
		var present: Dictionary = spawner2.present_ids()
		var dup_hits := 0
		for _i in range(60):
			var pick: Dictionary = spawner2._pick_type()
			if pick.is_empty():
				continue
			if present.has(str(pick.get("id", ""))):
				dup_hits += 1
		var star_entry := {}
		var tycoon_entry := {}
		for t in DataRegistry.customer_types:
			var ids_e: Array = t.get("identities", [])
			if ids_e.has("star") and star_entry.is_empty():
				star_entry = t
			if ids_e.has("tycoon") and tycoon_entry.is_empty():
				tycoon_entry = t
		var notice_star := str(spawner2.special_notice_text(star_entry, ["测试星"]))
		var notice_tycoon := str(spawner2.special_notice_text(tycoon_entry, ["测试商"]))
		var notice_ok: bool = notice_star.contains("测试星") and notice_star.contains("明星") \
			and notice_tycoon.contains("测试商") and notice_tycoon.contains("富商")
		var linked: bool = GameState.celebrity_notice.get_connections().size() > 0
		checks.append("游客不重复：名册 %d 组 ｜ 在场条目 %d 个 ｜ 60 次抽样重复命中 %d（应为 0）｜ 贵客提示 %s（「%s」/「%s」）｜ HUD 已接信号 %s ｜ 提示时长 %.0f 秒" % [
			DataRegistry.customer_types.size(), present.size(), dup_hits, str(notice_ok),
			notice_star, notice_tycoon, str(linked), float(hud.celebrity_notice_seconds)])

	# 11. 指令台：/ 呼出、/who 完整快照、/stuck 可疑名单、/mark 记录进日志
	var console: Node = world.get_parent().get_node_or_null("ConsolePanel")
	if console == null:
		checks.append("指令台：找不到 ConsolePanel，跳过")
	else:
		var probe_c := Customer.new()
		world.customers_root.add_child(probe_c)
		probe_c.setup(DataRegistry.customer_types[0], world, world.random_entrance(), "指令甲")
		console.open_console()
		var opened_ok: bool = bool(console.is_open()) and GameState.text_input_active
		var help_text := str(console.run_command("/help"))
		var help_ok: bool = help_text.contains("/who") and help_text.contains("/stuck") \
			and help_text.contains("/mark") and help_text.contains("/list")
		var list_text := str(console.run_command("/list"))
		var list_ok: bool = list_text.contains("指令甲")
		var report := str(console.run_command("/who 指令甲"))
		var report_ok: bool = report.contains("指令甲") and report.contains("名册 id") \
			and report.contains("状态：") and report.contains("位置：") and report.contains("路径：") \
			and report.contains("计时：") and report.contains("心情")
		var miss_text := str(console.run_command("/who 查无此人"))
		var miss_ok: bool = miss_text.contains("没有找到")
		# 卡住识别：把探针标成「位置长时间没变化」，/stuck 应该点名它
		probe_c._stuck_time = 4.0
		var stuck_text := str(console.run_command("/stuck"))
		var stuck_ok: bool = stuck_text.contains("指令甲")
		probe_c._stuck_time = 0.0
		var mark_text := str(console.run_command("/mark 测试记录：门口卡住"))
		var log_file := str(console.log_path())
		var log_body := FileAccess.get_file_as_string(log_file)
		var log_ok: bool = mark_text.contains("已记录") and log_body.contains("测试记录：门口卡住") \
			and log_body.contains("指令甲")
		var unknown_text := str(console.run_command("/nope"))
		var unknown_ok: bool = unknown_text.contains("未知指令")
		console.close_console()
		var closed_ok: bool = not bool(console.is_open()) and not GameState.text_input_active
		probe_c.queue_free()
		checks.append("指令台：开启 %s ｜ /help 列全 %s ｜ /list 含新客 %s ｜ /who 快照（名册 id/状态/位置/路径/计时/心情）%s ｜ 查不到有提示 %s ｜ /stuck 点名卡住探针 %s ｜ /mark 落盘 %s（%s）｜ 未知指令提示 %s ｜ 关闭复位 %s" % [
			str(opened_ok), str(help_ok), str(list_ok), str(report_ok), str(miss_ok),
			str(stuck_ok), str(log_ok), log_file, str(unknown_ok), str(closed_ok)])

		# 11b. 生病规则：没诊所能治就照常消费；6 游戏小时没治上就离开；有诊所则优先去看病
		var sick := Customer.new()
		world.customers_root.add_child(sick)
		sick.setup(DataRegistry.customer_types[0], world, world.random_entrance(), "病号甲")
		var max_treat := 0
		for b in world.buildings:
			if b.is_clinic():
				max_treat = maxi(max_treat, b.treat_level())
		var hour_seconds: float = maxf(1.0, GameClock.cycle_length_seconds / 24.0)
		sick._apply_illness({"id": "test_curse", "name": "测试怪病", "level": max_treat + 1,
			"treat_hours": 2.0, "fee": 1000})
		var keeps_living_ok: bool = sick.state != Customer.State.WAITING_CURE \
			and sick.state != Customer.State.DONE
		var six_hours_ok: bool = is_equal_approx(sick.cure_left, hour_seconds * 6.0) \
			and is_equal_approx(float(DataRegistry.illness_config.get("deadline_hours", 0.0)), 6.0)
		# 有能治的诊所时：下一次做决定会优先去看病
		var priority_ok := false
		var priority_note := "村里没有能治 1 级病的诊所，跳过"
		if world.find_clinic(1, sick.global_position) != null:
			sick.illness = {"id": "cold", "name": "风寒", "level": 1, "treat_hours": 1.0, "fee": 400}
			sick.cure_left = hour_seconds * 6.0
			sick._choose_activity()
			priority_ok = sick.state == Customer.State.SEEK_CLINIC and sick.clinic != null
			priority_note = "SEEK_CLINIC = %s" % str(priority_ok)
		# 计时到点：带病离开（推一帧 _process，验证倒计时真的会赶人走）
		var clock_paused_backup: bool = GameClock.paused
		var clock_phase_backup: int = GameClock.phase
		var rep_backup2: float = GameState.reputation
		GameClock.paused = false
		GameClock.phase = GameClock.Phase.RUNNING
		sick.cure_left = 0.5
		sick._process(1.0)
		var leaves_ok: bool = sick.state == Customer.State.LEAVING
		var sick_pos_before: Vector2 = sick.global_position
		sick._process(0.5)      # 再推一帧：他应该开始往出口走，而不是被反复重新寻路定在原地
		var walks_out_ok: bool = sick.global_position.distance_to(sick_pos_before) > 1.0
		GameClock.paused = clock_paused_backup
		GameClock.phase = clock_phase_backup
		GameState.reputation = rep_backup2
		sick.queue_free()
		checks.append("生病规则：没诊所能治时照常活动 %s ｜ 时限 %.1f 秒（%.1f 游戏小时）%s ｜ 有诊所则优先看病（%s）｜ 到点带病离开 %s 且真的走出去 %s" % [
			str(keeps_living_ok), hour_seconds * 6.0,
			float(DataRegistry.illness_config.get("deadline_hours", 0.0)), str(six_hours_ok),
			priority_note, str(leaves_ok), str(walks_out_ok)])


# ---------- 保洁工人 ----------

func _run_janitor_checks(cleaner: Building) -> void:
	# 1) 班次：白班 08:00-20:00、夜班 20:00-08:00；雇人时自动往人少的一班补
	cleaner.hire_staff()
	cleaner.hire_staff()
	var counts: Dictionary = cleaner.shift_counts()
	checks.append("保洁班次：雇 2 人 → 白班 %d 位 / 夜班 %d 位（应为 1 / 1）" % [
		int(counts.get("day", 0)), int(counts.get("night", 0))])
	checks.append("班次时段：08:00 白班 %s ｜ 20:00 白班 %s ｜ 03:00 夜班 %s ｜ 07:59 夜班 %s（应为 true / false / true / true）" % [
		str(cleaner.shift_on_duty("day", 8.0)), str(cleaner.shift_on_duty("day", 20.0)),
		str(cleaner.shift_on_duty("night", 3.0)), str(cleaner.shift_on_duty("night", 7.98))])

	# 2) 在岗人数随时间切换；下班的人立即从地图上消失
	runner._set_hour(10.0)
	cleaner._sync_janitors()
	var day_on: int = cleaner.janitors.size()
	runner._set_hour(22.0)
	cleaner._sync_janitors()
	var night_on: int = cleaner.janitors.size()
	cleaner.fire_staff()          # 解雇夜班，只剩白班
	cleaner._sync_janitors()
	var night_after_fire: int = cleaner.janitors.size()
	runner._set_hour(10.0)
	cleaner._sync_janitors()
	var day_after_fire: int = cleaner.janitors.size()
	checks.append("保洁班次切换：10 点在岗 %d ｜ 22 点在岗 %d ｜ 解雇夜班后 22 点 %d、10 点 %d（应为 1 / 1 / 0 / 1）" % [
		day_on, night_on, night_after_fire, day_after_fire])
	cleaner.hire_staff()          # 补回夜班；后面的走动/清扫都在白班时段验证
	runner._set_hour(10.0)
	cleaner._sync_janitors()

	# 3) 会在外面走动：给足时间看位置有没有变化
	var janitor: Node2D = null
	for j in cleaner.janitors:
		if j != null and is_instance_valid(j):
			janitor = j
			break
	if janitor == null:
		checks.append("保洁工人：没拿到工人实例，跳过走动检查")
		return
	var start_pos: Vector2 = janitor.global_position
	var moved := 0.0
	for _i in range(40):
		janitor._process(0.25)
		moved = maxf(moved, start_pos.distance_to(janitor.global_position))
	checks.append("保洁工人：40 次推进后累计走动 %.0f 像素（会动 %s）｜ 负责半径 %d 格" % [
		moved, str(moved > 8.0), janitor.roam_radius_cells()])

	# 4) 范围内的垃圾会被清掉
	var near_cell: Vector2i = runner._nearest_walkable(janitor.global_position)
	var near_planted := 0
	for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var c: Vector2i = near_cell + d
		if world.is_walkable(c) and not world.litter_cells.has(c):
			world.spawn_litter(c)
			near_planted += 1
	var janitor_ref: Node2D = janitor
	var real_total: int = janitor.cleaned_total
	for _i in range(30):
		janitor_ref._process(0.4)
		if janitor_ref.cleaned_total > real_total:
			break
	# 兜底：万一寻路没走到，直接站到垃圾上确认清扫动作本身有效
	if janitor_ref.cleaned_total == real_total and world.litter_cells.has(near_cell):
		janitor_ref.global_position = world.cell_center(near_cell)
		janitor_ref._look_for_litter()
	var near_left := 0
	for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		if world.litter_cells.has(near_cell + d):
			near_left += 1
	checks.append("保洁工人清扫：范围内种下 %d 个 ｜ 走了一轮后剩 %d 个 ｜ 工人累计清掉 %d 个" % [
		near_planted, near_left, janitor_ref.cleaned_total])

	# 5) 负责范围外的垃圾不清（放在离保洁间 40 格以外的地方）
	var far_cell := Vector2i(-9999, -9999)
	for cell in world.walkable_path_cells():
		if world.litter_cells.has(cell):
			continue
		if world.cell_center(cell).distance_to(cleaner.global_position) > float(JANITOR_SCRIPT.ROAM_RADIUS_CELLS + 5) * 32.0:
			far_cell = cell
			break
	if far_cell.x != -9999:
		world.spawn_litter(far_cell)
		janitor_ref.global_position = world.cell_center(runner._nearest_walkable(cleaner.global_position))
		var found := Vector2i(-9999, -9999)
		for _i in range(30):
			janitor_ref._look_for_litter()
			found = janitor_ref.current_target()
			if found.x != -9999:
				break
		checks.append("保洁工人范围：范围外 %d 格外放 1 个垃圾 ｜ 工人是否去清 = %s（应为 false）" % [
			int(world.cell_center(far_cell).distance_to(cleaner.global_position) / 32.0),
			str(found == far_cell)])
		world.remove_litter_at(far_cell)
	else:
		checks.append("保洁工人范围：地图上找不到 40 格以外的可通行格，跳过")


# 把保洁间挪到一片「旁边还有别的可通行格」的地砖上，让工人一出门就有垃圾可扫
func _setup_cleaning_scene(fallback: Building) -> Building:
	for cell in world.walkable_path_cells():
		if not world.can_place(cell, Vector2i(2, 2)):
			continue
		var b: Building = world.place_building("amenity_cleaning", cell)
		if b == null:
			continue
		if not world.building_reachable(b):
			world.demolish(b)
			continue
		# 门口附近至少有 2 格可通行地砖才算合格
		if runner._walkable_neighbours(cell, Vector2i(2, 2)) >= 3:
			if fallback and is_instance_valid(fallback):
				world.demolish(fallback)
			return b
		world.demolish(b)
	return fallback


func _place_and_connect(id: String) -> Building:
	# 完全测试模式下这类建筑开局就已经摆好了，直接借用现成的那栋，不再重复建造
	var existing: Building = runner._find_building(id)
	if existing:
		return existing
	var data: Dictionary = DataRegistry.get_building(id)
	var f: Array = data.get("footprint", [3, 3])
	var size := Vector2i(int(f[0]), int(f[1]))
	var spots: Array = []
	for y in range(3, 62):
		for x in range(4, 124):
			var cell := Vector2i(x, y)
			if world.can_place(cell, size):
				spots.append(cell)
	spots.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return absi(a.y - world.road_row) < absi(b.y - world.road_row))
	for cell in spots:
		if world.place_building(id, cell) == null:
			continue
		var b: Building = world.buildings[world.buildings.size() - 1]
		for py in range(b.door_cell().y, world.road_row + 1):
			var c := Vector2i(b.door_cell().x, py)
			if not world.occupancy.has(c) and world.ground_type(c) != World.GROUND_PATH:
				world.set_ground(c, World.GROUND_PATH)
		if world.building_reachable(b):
			return b
		world.demolish(b)      # 接不上就还原，继续找下一块
	return null


func _place_on_pavement(id: String) -> Building:
	# 直接把建筑盖在现成的地砖上（门口天然就是客人走的路），用于测试「附近有垃圾」一类机制
	var existing: Building = runner._find_building(id)
	if existing:
		return existing
	var data: Dictionary = DataRegistry.get_building(id)
	var f: Array = data.get("footprint", [2, 2])
	var size := Vector2i(int(f[0]), int(f[1]))
	var fallback: Building = null
	for cell in world.walkable_path_cells():
		if not world.can_place(cell, size):
			continue
		var b: Building = world.place_building(id, cell)
		if b == null or not world.building_reachable(b):
			continue
		if runner._walkable_neighbours(cell, size) >= 3:
			return b
		if fallback == null:
			fallback = b      # 先留住一个能用的，实在没有更好的就用它
	if fallback:
		return fallback
	return null


# ---------- 垃圾与心情 ----------

func _run_litter_mood_check() -> void:
	var mood_at: Vector2i = runner._nearest_walkable(world.cell_center(Vector2i(world.ENTRANCE_X0, world.road_row)))
	var guest := Customer.new()
	world.customers_root.add_child(guest)
	if world.reception():
		guest.setup(DataRegistry.customer_types[0], world, world.random_entrance())
		guest.global_position = world.cell_center(mood_at)
		# 先在客人脚下种几个垃圾，否则「脏」这一组根本没东西可脏
		var seeded := 0
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var c: Vector2i = mood_at + Vector2i(dx, dy)
				if world.is_walkable(c) and not world.litter_cells.has(c):
					world.spawn_litter(c)
					seeded += 1
		var dirty_at: int = world.litter_near(guest.global_position, 6.0 * 32.0)
		guest.mood = 80.0
		guest._tick_mood(60.0)
		var decay_dirty := 80.0 - guest.mood
		# 把这一带的垃圾清空，再测一次「干净」的衰减做对照
		var cleaned := 0
		for cell in world.litter_cells.keys():
			if guest.global_position.distance_to(world.cell_center(cell)) <= 6.0 * 32.0:
				world.remove_litter_at(cell)
				cleaned += 1
		guest.mood = 80.0
		guest._tick_mood(60.0)
		var decay_clean := 80.0 - guest.mood
		checks.append("脏乱掉心情：站在 %s，种下 %d 个垃圾（6 格内 %d 个，清掉 %d 个）｜ 1 分钟心情 -%.2f（脏）vs -%.2f（干净）" % [
			str(mood_at), seeded, dirty_at, cleaned, decay_dirty, decay_clean])
	guest.queue_free()


func _read_data_file(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}
