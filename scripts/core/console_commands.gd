extends RefCounted
## 指令台命令：/help、/list、/who <名字>、/stuck、/mark <文本>、/log
## 用途：运行中随时把问题「针对性记录」下来——
##   · 输出直接显示在指令台里（可选中 / 右键复制）
##   · /who 与 /stuck 的结果同时追加到日志文件，事后可以整段拷出来排查

const LOG_FILE := "user://console_log.txt"           # 正常运行时写这里
const FALLBACK_LOG_DIR := "res://.tmp"               # user:// 不可写（沙箱等）时的落点
const FALLBACK_LOG_FILE := "res://.tmp/console_log.txt"
const LOG_TAIL_LINES := 12

var world: Node2D
var _log_path := ""


func setup(world_ref: Node2D) -> void:
	world = world_ref


# ---------- 入口 ----------

func run(line: String) -> String:
	var text := line.strip_edges()
	if text.begins_with("/"):
		text = text.substr(1)
	text = text.strip_edges()
	if text == "":
		return "输入指令后再回车；/help 看有哪些指令。"
	var parts := _split(text)
	var cmd := str(parts[0]).to_lower()
	var args: Array = parts.slice(1)
	match cmd:
		"help", "帮助", "?":
			return help_text()
		"list", "列表":
			return _cmd_list()
		"who", "查", "info", "信息":
			return _cmd_who(args)
		"stuck", "卡住":
			return _cmd_stuck()
		"mark", "记录", "note":
			return _cmd_mark(args)
		"log", "日志":
			return _cmd_log()
	return "未知指令：%s（试试 /help）" % cmd


func help_text() -> String:
	return "\n".join([
		"指令台 —— 输入后回车执行，ESC 关闭；输出可选中 / 右键复制。",
		"/list 或 /列表 —— 列出度假村里所有游客（名字 / 状态 / 位置 / 名册 id）",
		"/who <名字或 id> 或 /查 <名字> —— 打印这位游客的完整状态快照（自动写日志）",
		"/stuck 或 /卡住 —— 找出疑似卡住的游客（原地不动 / 该走路没路径 / 站在不可通行格上），附前两位的完整快照（自动写日志）",
		"/mark <文本> 或 /记录 <文本> —— 把一条备注写进日志（带游戏时间与现实时间）",
		"/log —— 显示日志文件路径和最后几行",
	])


func header_text() -> String:
	# 快照的抬头：截图 / 复制出去时，别人一眼知道是什么时候、什么状态下的现场
	var speed_text := "x%d" % int(GameClock.SPEED_VALUES.get(GameClock.speed, 1.0))
	if GameClock.paused:
		speed_text = "已暂停"
	if GameClock.phase == GameClock.Phase.SETTLEMENT:
		speed_text = "结算中"
	return "—— 第 %d 天 %s ｜ %s ｜ 在村游客 %d 人 ｜ 日志 %s ——" % [
		GameState.day, GameClock.time_text(), speed_text, _collect().size(), log_path()]


# ---------- 命令实现 ----------

func _cmd_list() -> String:
	var all := _collect()
	if all.is_empty():
		return header_text() + "\n度假村里现在没有游客。"
	var lines: Array = [header_text(), "在村游客 %d 人：" % all.size()]
	for c in all:
		var cell: Vector2i = world.world_to_cell(c.global_position) if world != null else Vector2i.ZERO
		lines.append("· %s（%s）—— %s ｜ 位置 %s ｜ 心情 %.0f" % [
			str(c.customer_name), str(c.type_data.get("id", "?")), str(c.state_name()),
			str(cell), c.mood])
	return "\n".join(lines)


func _cmd_who(args: Array) -> String:
	var all := _collect()
	var query := " ".join(args).strip_edges()
	if query == "":
		var names: Array = []
		for c in all:
			names.append(str(c.customer_name))
		return "用法：/who <名字或名册 id>。当前在村里的：%s" % (
			"、".join(names) if not names.is_empty() else "（没有）")
	var matches: Array = []
	var query_lower := query.to_lower()
	for c in all:
		var entry_id := str(c.type_data.get("id", ""))
		if str(c.customer_name) == query or entry_id == query:
			matches = [c]          # 精确命中：直接用这一位
			break
		if str(c.customer_name).to_lower().find(query_lower) >= 0 \
				or entry_id.to_lower().find(query_lower) >= 0:
			matches.append(c)
	if matches.is_empty():
		return "没有找到「%s」。用 /list 看看当前有哪些游客（已经离开的查不到）。" % query
	if matches.size() > 1:
		var brief: Array = []
		for c in matches:
			var cell2: Vector2i = world.world_to_cell(c.global_position) if world != null else Vector2i.ZERO
			brief.append("%s（位置 %s）" % [str(c.customer_name), str(cell2)])
		return "匹配到 %d 位，请写更精确的名字：%s" % [matches.size(), "、".join(brief)]
	var c2: Customer = matches[0]
	var out := header_text() + "\n" + c2.debug_report()
	_append_log("【查询】\n" + out)
	return out


func _cmd_stuck() -> String:
	var all := _collect()
	var suspects: Array = []
	for c in all:
		var why := str(c.stuck_reason())
		if why != "":
			suspects.append([c, why])
	if suspects.is_empty():
		return header_text() + "\n没有发现疑似卡住的游客（在村 %d 人）。" % all.size()
	suspects.sort_custom(func(a: Array, b: Array) -> bool:
		return float(a[0]._stuck_time) > float(b[0]._stuck_time))
	var lines: Array = [header_text(), "疑似卡住 %d 人（按静止时间排序）：" % suspects.size()]
	for pair in suspects:
		var c2: Customer = pair[0]
		var cell2: Vector2i = world.world_to_cell(c2.global_position) if world != null else Vector2i.ZERO
		lines.append("· %s（%s）—— %s ｜ 位置 %s ｜ 目标 %s" % [
			str(c2.customer_name), str(c2.type_data.get("id", "?")), str(pair[1]), str(cell2),
			str(c2.target.id) if (c2.target != null and is_instance_valid(c2.target)) else "无"])
	var out := "\n".join(lines)
	for i in range(mini(2, suspects.size())):
		out += "\n\n" + str(suspects[i][0].debug_report())
	_append_log("【可疑卡住】\n" + out)
	return out


func _cmd_mark(args: Array) -> String:
	var text := " ".join(args).strip_edges()
	if text == "":
		return "用法：/mark <想记下的内容>，例如：/mark 酒吧门口有位客人卡着不动"
	var line := "[%s]（现实时间）第 %d 天 %s（游戏时间）—— %s" % [
		Time.get_datetime_string_from_system(), GameState.day, GameClock.time_text(), text]
	_append_log(line)
	return "已记录到日志：%s\n%s" % [log_path(), line]


func _cmd_log() -> String:
	var path := log_path()
	if not FileAccess.file_exists(path):
		return "日志文件还没有内容：%s" % path
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	var tail: Array = []
	var start := maxi(0, lines.size() - 1 - LOG_TAIL_LINES)
	for i in range(start, lines.size()):
		if str(lines[i]).strip_edges() != "":
			tail.append(str(lines[i]))
	return "日志文件：%s\n最后 %d 行：\n%s" % [path, tail.size(), "\n".join(tail)]


# ---------- 工具 ----------

func _split(text: String) -> Array:
	var normalized := text.replace("　", " ").replace("\t", " ")
	var parts: Array = []
	for piece in normalized.split(" "):
		if str(piece).strip_edges() != "":
			parts.append(str(piece))
	return parts


func _collect() -> Array:
	# 当前在度假村里的游客（含住店 / 就诊中 / 正在离场），和游客状态面板同一口径
	var out: Array = []
	if world == null:
		return out
	for node in world.get_tree().get_nodes_in_group("customers"):
		if not (node is Customer):
			continue
		var c: Customer = node
		if not is_instance_valid(c) or c.is_queued_for_deletion():
			continue
		if c.state == Customer.State.DONE:
			continue
		out.append(c)
	out.sort_custom(func(a: Customer, b: Customer) -> bool:
		return str(a.customer_name) < str(b.customer_name))
	return out


func log_path() -> String:
	if _log_path != "":
		return _log_path
	var f: FileAccess = null
	if FileAccess.file_exists(LOG_FILE):
		f = FileAccess.open(LOG_FILE, FileAccess.READ_WRITE)
	else:
		f = FileAccess.open(LOG_FILE, FileAccess.WRITE)
	if f != null:
		f.close()
		_log_path = LOG_FILE
	else:
		_log_path = FALLBACK_LOG_FILE
	return _log_path


func _append_log(text: String) -> bool:
	var path := log_path()
	if path.begins_with("res://"):
		DirAccess.make_dir_recursive_absolute(FALLBACK_LOG_DIR)
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.seek_end()
	f.store_line(text)
	f.close()
	return true
