extends Node
## 标题界面截图工具：开场动画 / 主菜单 / 存档 / 设置。
## 运行：godot --path . res://tools/title_shot.tscn -- --screenshot

var title: Node
var elapsed := 0.0
var step := 0


func _ready() -> void:
	var packed: PackedScene = load("res://scenes/title.tscn")
	title = packed.instantiate()
	add_child(title)


func _process(delta: float) -> void:
	elapsed += delta
	match step:
		0:
			if elapsed > 1.1:
				_capture("title_01_intro.png")
				step = 1
		1:
			if elapsed > 4.5:
				_capture("title_02_menu.png")
				title._open_slot_panel("new")
				step = 2
		2:
			if elapsed > 5.2:
				_capture("title_03_slots.png")
				SaveManager.new_game_mode = SaveManager.MODE_FULL_TEST
				title._refresh_slot_list()
				step = 3
		3:
			if elapsed > 5.9:
				_capture("title_05_new_game_full_test.png")
				SaveManager.new_game_mode = SaveManager.MODE_INITIAL
				title._open_settings()
				step = 4
		4:
			if elapsed > 6.6:
				_capture("title_04_settings.png")
				step = 5
		5:
			if elapsed > 7.0:
				get_tree().quit()


func _capture(file_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png("res://.tmp/%s" % file_name)
	print("[title_shot] %s -> %s" % [file_name, error_string(err)])
