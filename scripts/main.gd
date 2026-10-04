extends Node2D
## 游戏主场景入口。

func _enter_tree() -> void:
	# 自动化测试模式要在子节点 _ready 之前设好，避免弹出开始菜单把时钟暂停
	var args := OS.get_cmdline_user_args()
	if args.has("--smoke") or args.has("--screenshot"):
		GameState.smoke_mode = true


func _ready() -> void:
	var mode := SaveManager.consume_pending()
	if mode == "load":
		var data := SaveManager.load_game(SaveManager.active_slot)
		if data.is_empty():
			push_warning("[Main] 读取存档失败，按新游戏处理")
		else:
			SaveManager.apply_save(data)
			print("[Main] 已读取存档 %d（第 %d 天）" % [SaveManager.active_slot, GameState.day])
	elif mode == "new":
		print("[Main] 新游戏：存档 %d，第 1 天" % SaveManager.active_slot)
		SaveManager.save_game()
	print("[Main] 边境度假村启动 —— 第 %d 天" % GameState.day)
	if OS.get_cmdline_user_args().has("--smoke"):
		print("[Main] 进入自动化冒烟测试模式")
		add_child(load("res://tools/smoke_runner.gd").new())
