extends Node
## 经营平衡体检：用正式参数（含 64 倍速）跑若干游戏内天数，
## 打印每天的到访人数、营业额、工资、展厅成交与设施数，用来判断节奏是否合适。
## 运行：godot --headless --path . res://tools/balance_check.tscn -- --days=3

var main: Node
var hud: Node
var days := 0
var target_days := 3


func _ready() -> void:
	# 平衡测试永远使用独立目录 + 只读，绝不动玩家存档
	SaveManager.save_dir = SaveManager.TEST_SAVE_DIR
	SaveManager.read_only = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="):
			target_days = int(arg.split("=")[1])
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)


func _process(_delta: float) -> void:
	if hud != null:
		return
	hud = main.get_node_or_null("HUD")
	if hud == null:
		return
	GameClock.set_speed(GameClock.Speed.X64)
	GameClock.day_finished.connect(_on_day_finished)
	print("[balance] 开始：正式参数 + 64 倍速，跑 %d 天" % target_days)


func _on_day_finished() -> void:
	days += 1
	var report := GameState.day_report()
	var world := main.get_node("World")
	print("[balance] 第 %d 天：到访 %d 人 ｜ 营业额 %s ｜ 展厅 %s ｜ 工资 %s ｜ 设施 %d 座 ｜ 资金 %s ｜ 口碑 %.1f" % [
		days, int(report.get("visitors", 0)), GameState.format_money(int(report.get("revenue", 0))),
		GameState.format_money(int(report.get("item_income", 0))),
		GameState.format_money(int(report.get("wages", 0))),
		world.buildings.size(), GameState.format_money(GameState.money), GameState.reputation])
	if days >= target_days:
		print("[balance] 结束")
		get_tree().quit(0)
		return
	if hud:
		hud._start_next_day()
