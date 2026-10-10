extends Node
## 存档系统（类似星露谷）：多个存档槽，每个槽是一局独立的游戏。
## - 每天结算时自动保存到当前槽位
## - 探索前另存一个「探索前存档点」，死亡时读回
## - 标题界面可以看到每个槽的天数 / 资金 / 游玩时长

const SAVE_DIR := "user://saves"
const TEST_SAVE_DIR := "user://saves_test"   # 自动化测试专用，绝不动玩家存档
const SLOT_COUNT := 3
const EXPLORE_OFFSET := 100     # 槽位 + 100 = 该槽的探索前存档

# 开局模式：初始模式是正常玩法，完全测试模式铺满建筑 + 满员工 + 满物资，方便测系统
const MODE_INITIAL := "initial"
const MODE_FULL_TEST := "full_test"

var active_slot := 1
var pending_mode := ""          # "new" / "load"，由标题界面设置，进入游戏后执行
var pending_slot := 1
var new_game_mode := MODE_INITIAL   # 标题界面选的开局模式，仅对「新游戏」有效
var save_dir := SAVE_DIR
var read_only := false          # 截图等开发工具用：只读，绝不写存档


func _ready() -> void:
	# 开发工具一律与玩家存档隔离：测试写独立目录，截图工具只读不写
	var args := OS.get_cmdline_user_args()
	if args.has("--smoke"):
		save_dir = TEST_SAVE_DIR
		wipe_test_saves()      # 每次测试都从全新存档开始
	elif args.has("--screenshot"):
		save_dir = TEST_SAVE_DIR
		read_only = true
	var err := DirAccess.make_dir_recursive_absolute(save_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("[SaveManager] 存档目录暂不可用（%s）：%s" % [error_string(err), save_dir])


func path_for(slot: int) -> String:
	if slot >= EXPLORE_OFFSET:
		return "%s/slot_%d_explore.json" % [save_dir, slot - EXPLORE_OFFSET]
	return "%s/slot_%d.json" % [save_dir, slot]


func explore_slot() -> int:
	return EXPLORE_OFFSET + active_slot


func has_save(slot: int = -1) -> bool:
	if slot < 0:
		slot = active_slot
	return FileAccess.file_exists(path_for(slot))


func any_save() -> bool:
	for slot in range(1, SLOT_COUNT + 1):
		if has_save(slot):
			return true
	return false


func save_game(slot: int = -1) -> bool:
	if read_only:
		return false
	if slot < 0:
		slot = active_slot
	var world := get_tree().get_first_node_in_group("world")
	var data := {
		"version": 2,
		"saved_at": Time.get_datetime_string_from_system(),
		"state": GameState.to_dict(),
		"stats": PlayerStats.to_dict(),
		"clock": GameClock.to_dict(),
		"world": world.save_data() if world and world.has_method("save_data") else {},
	}
	var f := FileAccess.open(path_for(slot), FileAccess.WRITE)
	if f == null:
		push_error("[SaveManager] 无法写入存档：%s" % path_for(slot))
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	if GameState.verbose_log:
		print("[存档] 第 %d 天已保存到存档 %d" % [GameState.day, slot])
	return true


func load_game(slot: int = -1) -> Dictionary:
	if slot < 0:
		slot = active_slot
	if not has_save(slot):
		return {}
	var text := FileAccess.get_file_as_string(path_for(slot))
	if text.strip_edges() == "":
		push_warning("[SaveManager] 存档为空或不可读：%s" % path_for(slot))
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[SaveManager] 存档损坏：%s" % path_for(slot))
		return {}
	return parsed


func apply_save(data: Dictionary) -> void:
	if data.is_empty():
		return
	GameState.apply_dict(data.get("state", {}))
	PlayerStats.apply_dict(data.get("stats", {}))
	GameClock.apply_dict(data.get("clock", {}))
	var world := get_tree().get_first_node_in_group("world")
	if world and world.has_method("load_data"):
		world.load_data(data.get("world", {}))


func slot_summary(slot: int) -> Dictionary:
	# 给标题界面的存档列表用
	if not has_save(slot):
		return {"exists": false, "slot": slot}
	var data := load_game(slot)
	if data.is_empty():
		return {"exists": false, "slot": slot}
	var state: Dictionary = data.get("state", {})
	var world: Dictionary = data.get("world", {})
	return {
		"exists": true,
		"slot": slot,
		"day": int(state.get("day", 1)),
		"money": int(state.get("money", 0)),
		"reputation": float(state.get("reputation", 0.0)),
		"buildings": (world.get("buildings", []) as Array).size(),
		"playtime": float(state.get("playtime", 0.0)),
		"saved_at": str(data.get("saved_at", "")),
	}


func begin_new_game(slot: int, mode: String = MODE_INITIAL) -> void:
	# 标题界面点「新游戏」：清掉这个槽、记下开局模式，
	# 真正的状态重置放在 main.gd 的 _enter_tree()（必须在 World 子节点 _ready 之前完成）
	delete_save(slot)
	active_slot = slot
	pending_mode = "new"
	pending_slot = slot
	new_game_mode = mode


func begin_load_game(slot: int) -> void:
	active_slot = slot
	pending_mode = "load"
	pending_slot = slot


func consume_pending() -> String:
	# 游戏场景启动时调用：返回 "new" / "load" / ""
	var mode := pending_mode
	pending_mode = ""
	return mode


func delete_save(slot: int) -> void:
	for target in [slot, EXPLORE_OFFSET + slot]:
		if has_save(target):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path_for(target)))


func wipe_test_saves() -> void:
	# 只允许清空测试目录，永远不会碰玩家的存档
	if save_dir != TEST_SAVE_DIR or not save_dir.contains("saves_test"):
		push_warning("[SaveManager] 拒绝清空非测试目录：%s" % save_dir)
		return
	var dir := DirAccess.open(save_dir)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	print("[SaveManager] 测试存档已清空（%s），本轮从新游戏开始" % save_dir)
