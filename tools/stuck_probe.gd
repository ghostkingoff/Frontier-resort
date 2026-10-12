extends Node
## 专项体检：64 倍速跑几天，抓「该走路却长时间不动」的顾客并打印现场。
## 用来定位「卡在店铺门口」一类问题。
## 运行：godot --headless --path . res://tools/stuck_probe.tscn -- --days=3

const STUCK_SECONDS := 3.0     # 现实秒；64 倍速下 ≈ 192 游戏秒，正常走路不可能停这么久

var main: Node
var hud: Node
var days := 0
var target_days := 3
var reports := 0
var _anchor: Dictionary = {}     # customer -> Vector2（计时起点位置）
var _still: Dictionary = {}      # customer -> float（现实秒）
var _reported: Dictionary = {}   # customer -> bool（这一轮只报一次）


func _ready() -> void:
	# 与其它开发工具一致：独立测试存档、只读，绝不动玩家存档
	SaveManager.save_dir = SaveManager.TEST_SAVE_DIR
	SaveManager.read_only = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="):
			target_days = int(arg.split("=")[1])
		elif arg.begins_with("--mode="):
			SaveManager.new_game_mode = arg.split("=")[1]
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)


func _process(delta: float) -> void:
	if hud == null:
		hud = main.get_node_or_null("HUD")
		if hud == null:
			return
		GameClock.set_speed(GameClock.Speed.X64)
		GameClock.day_finished.connect(_on_day_finished)
		print("[stuck] 开始：64 倍速跑 %d 天，盯「走路状态但不动」的顾客" % target_days)
	var world: Node2D = main.get_node_or_null("World")
	if world == null:
		return
	var live: Dictionary = {}
	for c in world.customers_root.get_children():
		if not (c is Customer):
			continue
		if c.state == Customer.State.INSIDE or c.state == Customer.State.WAITING_CURE \
				or c.state == Customer.State.TREATMENT or c.state == Customer.State.DONE:
			continue    # 消费中 / 候诊 / 治疗 / 已结束：站着不动是正常的
		live[c] = true
		var pos: Vector2 = c.global_position
		if not _anchor.has(c):
			_anchor[c] = pos
			_still[c] = 0.0
			_reported[c] = false
			continue
		if pos.distance_to(_anchor[c]) > 6.0:
			_anchor[c] = pos          # 移动超过 6 像素：重新计时（小抖动也算卡住）
			_still[c] = 0.0
			_reported[c] = false
			continue
		_still[c] = float(_still.get(c, 0.0)) + delta
		if _still[c] >= STUCK_SECONDS and not bool(_reported.get(c, false)):
			_reported[c] = true
			reports += 1
			_dump(c, world, pos)
	for c in _anchor.keys():
		if not live.has(c):
			_anchor.erase(c)
			_still.erase(c)
			_reported.erase(c)


func _dump(c: Customer, world: Node2D, pos: Vector2) -> void:
	var cell: Vector2i = world.world_to_cell(pos)
	var target_name := "-"
	if c.target != null and is_instance_valid(c.target):
		target_name = "%s @ %s" % [str(c.target.display_name()), str(c.target.cell)]
	var entry_dist: float = pos.distance_to(world.cell_center(c._entry_cell))
	print("[stuck] #%d %s ｜ 状态 %d 目的 %d ｜ 位置 %s（格 %s 可走 %s）｜ 目标 %s ｜ 出入口 %s（可走 %s，距离 %.1f）｜ 路径 %d/%d ｜ 无路计时 %.2f ｜ 失败 %d ｜ 卡住 %.1fs" % [
		reports, str(c.customer_name), c.state, c.purpose, str(pos.round()),
		str(cell), str(world.is_walkable(cell)), target_name,
		str(c._entry_cell), str(world.is_walkable(c._entry_cell)), entry_dist,
		c._path_index, c._path.size(), float(c._no_path_time), int(c._fail_count),
		float(_still.get(c, 0.0))])


func _on_day_finished() -> void:
	days += 1
	print("[stuck] 第 %d 天结束（累计报告 %d 例）" % [days, reports])
	if days >= target_days:
		print("[stuck] 结束：共报告 %d 例" % reports)
		get_tree().quit(0)
		return
	if hud:
		hud._start_next_day()
