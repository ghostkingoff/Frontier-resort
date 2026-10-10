extends Node
## 经营数据：金钱、天数、口碑与每日结算。

signal money_changed(value: int)
signal day_changed(day: int)
signal reputation_changed(value: float)
signal fame_changed(value: float)
signal notice(message: String)
signal inventory_changed()

const START_MONEY := 35000     # 开局资金：够盖一栋小型建筑 + 铺一些路
const FULL_TEST_FAME := 1000.0      # 完全测试模式：知名度一次给到 1000（最高门槛是 600）
const FULL_TEST_ITEM_COUNT := 1000  # 完全测试模式：每种物资各 1000 件

var money: int = START_MONEY
var day: int = 1
var reputation: float = 0.0
var fame: float = 100.0          # 知名度：初始 100，每天 -1；游客 +1，明星 +10~20
var daily_star_fame: float = 0.0 # 当天明星带来的知名度（结算时统一入账）
var daily_revenue: int = 0
var daily_visitors: int = 0
var total_revenue: int = 0
var total_visitors: int = 0
var inventory: Dictionary = {}          # 物资 id -> 数量
var daily_wages: int = 0                # 当日工资支出
var daily_item_income: int = 0          # 当日展厅成交收入
var placeholder_night_yield := false    # 探索系统开放前的临时夜间产出（已由探索系统取代，测试时可打开）
var smoke_mode := false                 # 自动化测试模式：跳过开始菜单
var verbose_log := false                # 详细日志（--verbose）：打印每次花钱 / 存盘等高频信息
var playtime := 0.0                     # 累计游玩时长（秒）

var _last_day_report: Dictionary = {}


func reset() -> void:
	money = START_MONEY
	day = 1
	reputation = 0.0
	fame = 100.0
	daily_star_fame = 0.0
	daily_revenue = 0
	daily_visitors = 0
	total_revenue = 0
	total_visitors = 0
	inventory.clear()
	daily_wages = 0
	daily_item_income = 0
	playtime = 0.0
	money_changed.emit(money)
	day_changed.emit(day)
	reputation_changed.emit(reputation)
	fame_changed.emit(fame)
	inventory_changed.emit()


func apply_new_game_mode(mode: String) -> void:
	# 开局模式在 reset() 之后调用：只改「新游戏」的起始条件，读档一律以存档内容为准
	if mode == SaveManager.MODE_FULL_TEST:
		fame = FULL_TEST_FAME
		fame_changed.emit(fame)
		for id in DataRegistry.item_order:
			add_item(id, FULL_TEST_ITEM_COUNT)
		print("[GameState] 完全测试模式：知名度 %d ｜ 物资 %d 种各 %d 件" % [
			int(fame), DataRegistry.item_order.size(), FULL_TEST_ITEM_COUNT])


func can_afford(amount: int) -> bool:
	return money >= amount


func spend(amount: int, reason: String = "") -> bool:
	if amount <= 0:
		return true
	if not can_afford(amount):
		notice.emit("资金不足：需要 %s" % format_money(amount))
		return false
	money -= amount
	money_changed.emit(money)
	if reason != "" and verbose_log:
		print("[花钱] %s -%d，余额 %d" % [reason, amount, money])
	return true


func earn(amount: int, _reason: String = "") -> void:
	if amount <= 0:
		return
	money += amount
	daily_revenue += amount
	total_revenue += amount
	money_changed.emit(money)


func add_reputation(value: float) -> void:
	reputation = max(0.0, reputation + value)
	reputation_changed.emit(reputation)
	fame_changed.emit(fame)


func add_fame(value: float) -> void:
	fame = maxf(0.0, fame + value)
	fame_changed.emit(fame)


func add_star_fame(value: float) -> void:
	# 明星带来的知名度先记账，等夜里结算再一起加
	daily_star_fame += value


func apply_daily_fame() -> Dictionary:
	# 每天结算：每位到访游客 +1、明星额外 +10~20（已记账）、日常自然 -1
	var visitors := daily_visitors
	var gain := float(visitors) + float(daily_star_fame) - 1.0
	var before := fame
	add_fame(gain)
	var result := {
		"before": before,
		"after": fame,
		"visitors": visitors,
		"star": daily_star_fame,
		"delta": gain,
	}
	daily_star_fame = 0.0
	return result


func star_arrival_chance() -> float:
	# 知名度 500 以下为 0；500 → 0%，约 1000 → 19%，再高也不会超过 20%
	if fame <= 500.0:
		return 0.0
	return minf(0.20, 0.20 * (1.0 - exp(-(fame - 500.0) / 150.0)))


func register_visit() -> void:
	daily_visitors += 1
	total_visitors += 1


# ---------- 物资仓库 ----------

func add_item(id: String, count: int = 1) -> void:
	if id == "" or count <= 0:
		return
	inventory[id] = int(inventory.get(id, 0)) + count
	inventory_changed.emit()


func remove_item(id: String, count: int = 1) -> bool:
	if count <= 0:
		return true
	if int(inventory.get(id, 0)) < count:
		return false
	inventory[id] = int(inventory[id]) - count
	if int(inventory[id]) <= 0:
		inventory.erase(id)
	inventory_changed.emit()
	return true


func item_count(id: String) -> int:
	return int(inventory.get(id, 0))


func inventory_value() -> int:
	var total := 0
	for id in inventory.keys():
		total += DataRegistry.item_value(id) * int(inventory[id])
	return total


func sorted_inventory() -> Array:
	# 按品质从高到低、价值从高到低排列，方便玩家先看到值钱的东西
	var ids := inventory.keys()
	ids.sort_custom(func(a, b):
		var wa := DataRegistry.rarity_weight(a)
		var wb := DataRegistry.rarity_weight(b)
		if wa == wb:
			return DataRegistry.item_value(a) > DataRegistry.item_value(b)
		return wa > wb)
	var out: Array = []
	for id in ids:
		out.append({"id": id, "count": int(inventory[id])})
	return out


func pay_wages(amount: int) -> void:
	if amount <= 0:
		return
	daily_wages += amount
	money = maxi(0, money - amount)
	money_changed.emit(money)


func earn_item_sale(amount: int) -> void:
	if amount <= 0:
		return
	daily_item_income += amount
	earn(amount, "展厅成交")


func day_report() -> Dictionary:
	var report := {
		"day": day,
		"revenue": daily_revenue,
		"visitors": daily_visitors,
		"reputation": reputation,
		"fame": fame,
		"wages": daily_wages,
		"item_income": daily_item_income,
	}
	_last_day_report = report
	return report


func finish_day() -> Dictionary:
	var report := day_report()
	return report


func start_next_day() -> void:
	day += 1
	daily_revenue = 0
	daily_visitors = 0
	daily_wages = 0
	daily_item_income = 0
	day_changed.emit(day)


func last_report() -> Dictionary:
	return _last_day_report


func format_money(value: int) -> String:
	var s := str(abs(value))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out + "g"


func to_dict() -> Dictionary:
	return {
		"money": money,
		"day": day,
		"reputation": reputation,
		"fame": fame,
		"total_revenue": total_revenue,
		"total_visitors": total_visitors,
		"inventory": inventory,
		"playtime": playtime,
	}


func apply_dict(d: Dictionary) -> void:
	money = int(d.get("money", START_MONEY))
	day = int(d.get("day", 1))
	reputation = float(d.get("reputation", 0.0))
	fame = float(d.get("fame", 100.0))
	total_revenue = int(d.get("total_revenue", 0))
	total_visitors = int(d.get("total_visitors", 0))
	inventory = d.get("inventory", {})
	playtime = float(d.get("playtime", 0.0))
	daily_revenue = 0
	daily_visitors = 0
	daily_wages = 0
	daily_item_income = 0
	money_changed.emit(money)
	day_changed.emit(day)
	reputation_changed.emit(reputation)
	fame_changed.emit(fame)
	inventory_changed.emit()
