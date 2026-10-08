class_name Party
extends RefCounted
## 同行小组：双人 / 三人客人共享一份预算，满足离开条件后一起离开。

var budget_total := 0
var budget_left := 0
var members: Array = []
var leaving := false
var waitress_paid := 0        # 这组客人带来的总消费（统计用）
var split_chance := 0.2       # 小概率分头行动，其余时间同进同出


func setup(budget: int) -> void:
	budget_total = budget
	budget_left = budget


func add_member(customer: Node2D) -> void:
	members.append(customer)


func spend(amount: int) -> int:
	var paid: int = clampi(amount, 0, budget_left)
	budget_left -= paid
	waitress_paid += paid
	return paid


func begin_leave() -> void:
	if leaving:
		return
	leaving = true
	for member in members:
		if is_instance_valid(member):
			member.on_party_leave()


func partners_of(customer: Node2D) -> Array:
	var out: Array = []
	for member in members:
		if member != customer and is_instance_valid(member):
			out.append(member)
	return out


func remove_member(customer: Node2D) -> void:
	members.erase(customer)


func is_split_roll() -> bool:
	return randf() < split_chance
