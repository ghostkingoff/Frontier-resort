extends Node2D
## 游戏主场景入口。

var _pending := ""      # _enter_tree() 里取一次就存下来，_ready() 里直接用


func _enter_tree() -> void:
	# 自动化测试模式要在子节点 _ready 之前设好，避免弹出开始菜单把时钟暂停
	var args := OS.get_cmdline_user_args()
	var dev_tool: bool = args.has("--smoke") or args.has("--screenshot") or args.has("--wake")
	if dev_tool:
		GameState.smoke_mode = true
	# 开局模式必须在这里应用：World 是子节点，它的 _ready() 会先于本节点的 _ready() 跑，
	# 而摆建筑时要读 GameState.fame（例如完全测试模式要一次给到 1000）。
	# 开发工具（冒烟测试 / 截图）是直接实例化 main.tscn 的，不走标题界面，
	# 所以只要处于开发工具模式就按 new_game_mode 初始化一次。
	_pending = SaveManager.consume_pending()
	if _pending == "new" or (dev_tool and _pending == ""):
		GameState.reset()
		PlayerStats.reset()
		Exploration.reset()
		GameClock.start_new_day()
		GameState.apply_new_game_mode(SaveManager.new_game_mode)


func _ready() -> void:
	if _pending == "load":
		var data := SaveManager.load_game(SaveManager.active_slot)
		if data.is_empty():
			push_warning("[Main] 读取存档失败，按新游戏处理")
		else:
			SaveManager.apply_save(data)
			print("[Main] 已读取存档 %d（第 %d 天）" % [SaveManager.active_slot, GameState.day])
	else:
		print("[Main] 新游戏：存档 %d，第 1 天" % SaveManager.active_slot)
		SaveManager.save_game()
	print("[Main] 边境度假村启动 —— 第 %d 天" % GameState.day)
	if OS.get_cmdline_user_args().has("--smoke"):
		print("[Main] 进入自动化冒烟测试模式")
		add_child(load("res://tools/smoke_runner.gd").new())
	elif OS.get_cmdline_user_args().has("--wake"):
		print("[Main] 进入住客作息专项体检模式")
		add_child(load("res://tools/wake_check.gd").new())
