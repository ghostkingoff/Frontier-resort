extends Node
## 存档体检工具：把某个存档读进游戏，打印关键状态（排查存档相关问题时用）。
## 运行：godot --headless --path . res://tools/save_check.tscn -- --slot=1

var main: Node
var frames := 0
var slot := 1


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--slot="):
			slot = int(arg.split("=")[1])
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)


func _process(_delta: float) -> void:
	frames += 1
	if frames < 5:
		return
	print("[save_check] 存档目录：%s" % SaveManager.save_dir)
	var info := SaveManager.slot_summary(slot)
	print("[save_check] 槽 %d 概要：%s" % [slot, JSON.stringify(info)])
	var data := SaveManager.load_game(slot)
	if data.is_empty():
		print("[save_check] 存档不存在或读不出来")
		get_tree().quit(1)
		return
	print("[save_check] 存档里记录的时间参数：%s" % JSON.stringify(data.get('clock', {})))
	SaveManager.active_slot = slot
	SaveManager.apply_save(data)
	print("[save_check] 读档后：第 %d 天 ｜ 资金 %d ｜ 一天 %.0f 秒 ｜ 倍速档 %d ｜ 时间 %s" % [
		GameState.day, GameState.money, GameClock.cycle_length_seconds, GameClock.speed, GameClock.time_text()])
	get_tree().quit(0)
