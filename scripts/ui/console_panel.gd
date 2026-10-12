extends CanvasLayer
## 指令台（类似《我的世界》的聊天栏）：游戏里按「/」呼出，输入指令回车执行。
## 输出区可选中 / 右键复制；/who 与 /stuck 会同时写进日志文件（路径见抬头或 /log）。
## 打开期间键盘交给输入框：相机与玩家角色不会因为打字（WASD）而乱动。

const COMMANDS := preload("res://scripts/core/console_commands.gd")

const HISTORY_MAX := 40
const OUTPUT_MAX_CHARS := 20000     # 输出区保留上限，防止长时间挂机越堆越长

var world: Node2D

var panel: PanelContainer
var output: RichTextLabel
var input: LineEdit
var commands: RefCounted

var _open := false
var _history: Array = []
var _history_index := 0
var _buffer := ""


func _ready() -> void:
	world = get_tree().get_first_node_in_group("world")
	commands = COMMANDS.new()
	commands.setup(world)

	var root := UIKit.root_control()
	add_child(root)

	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 220
	panel.offset_right = -220
	panel.offset_top = -400
	panel.offset_bottom = -56
	panel.add_theme_stylebox_override("panel",
		UIKit.panel_style(Color(0.05, 0.05, 0.08, 0.96), Color(0.85, 0.72, 0.40)))
	panel.visible = false
	root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(UIKit.label("指令台　（/help 查看指令 ｜ ESC 关闭 ｜ 输出可选中复制）", 22, Color(0.95, 0.85, 0.5)))

	output = RichTextLabel.new()
	output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output.scroll_following = true
	output.selection_enabled = true          # 可选中、右键复制
	output.context_menu_enabled = true
	output.bbcode_enabled = false
	output.add_theme_font_size_override("normal_font_size", 20)
	output.add_theme_color_override("default_color", Color(0.92, 0.93, 0.97))
	box.add_child(output)

	input = LineEdit.new()
	input.placeholder_text = "输入指令后回车（/help 查看；↑↓ 翻历史；ESC 关闭）"
	input.add_theme_font_size_override("font_size", 22)
	input.text_submitted.connect(_on_submit)
	box.add_child(input)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.keycode
	if key == KEY_SLASH and not _open:
		open_console()
		get_viewport().set_input_as_handled()
		return
	if not _open:
		return
	if key == KEY_ESCAPE:
		close_console()
		get_viewport().set_input_as_handled()
	elif key == KEY_UP:
		_history_step(-1)
		get_viewport().set_input_as_handled()
	elif key == KEY_DOWN:
		_history_step(1)
		get_viewport().set_input_as_handled()


func open_console() -> void:
	_open = true
	panel.visible = true
	GameState.text_input_active = true
	input.text = ""
	input.grab_focus()
	_show(str(commands.header_text()))       # 每次打开先打一行现场抬头（第几天 / 时间 / 日志路径）


func close_console() -> void:
	_open = false
	panel.visible = false
	GameState.text_input_active = false
	if input != null:
		input.release_focus()


func is_open() -> bool:
	return _open


func run_command(line: String) -> String:
	# 供测试 / 其它系统直接调用：等价于在输入框里敲这一行
	_show("> " + line)
	var result := str(commands.run(line))
	if result.strip_edges() != "":
		_show(result)
	return result


func log_path() -> String:
	return str(commands.log_path())


func _on_submit(text: String) -> void:
	var line := text.strip_edges()
	input.text = ""
	if line == "":
		return
	_history.append(line)
	if _history.size() > HISTORY_MAX:
		_history.pop_front()
	_history_index = _history.size()
	run_command(line)


func _history_step(direction: int) -> void:
	if _history.is_empty():
		return
	_history_index = clampi(_history_index + direction, 0, _history.size())
	if _history_index >= _history.size():
		input.text = ""
	else:
		input.text = str(_history[_history_index])
	input.caret_column = input.text.length()


func _show(text: String) -> void:
	if output == null or text == "":
		return
	_buffer += text + "\n"
	if _buffer.length() > OUTPUT_MAX_CHARS:
		# 只保留最近的内容：从头砍掉一段，切在换行处，避免留半行
		var cut := _buffer.length() - OUTPUT_MAX_CHARS / 2
		var newline_pos := _buffer.find("\n", cut)
		if newline_pos >= 0:
			_buffer = "……（更早的输出已省略，历史在日志文件里）\n" + _buffer.substr(newline_pos + 1)
	output.text = _buffer          # bbcode 已关：整段纯文本，方便鼠标划选复制
	output.scroll_to_line(output.get_line_count() - 1)
