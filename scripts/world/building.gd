extends Node2D
class_name Building

const JANITOR := preload("res://scripts/customers/janitor.gd")
const LIGHT_ON_EARLIEST := 20.0    # 20:00 起陆续开灯
const LIGHT_ON_LATEST := 20.75     # 20:45 全部亮起
const LIGHT_FADE_HOURS := 0.12     # 每栋楼自己的渐变时长（约 7 分钟游戏时间）
const LIGHT_SPREAD_CELLS := 1.0    # 光往建筑外扩几格（这一圈就是渐变带）
const LIGHT_ENERGY := 0.72         # 灯光强度。用加法混合，太高会让外圈过曝成「黄框」
# 熄灯时间不再写死：直接用各栋自己的 close_hour()（见 update_lights）
## 单栋建筑：外观、屋顶开关、容量、员工、升级、展厅展示位、诊所治疗。


const CELL := 32
const ENERGY_PER_GUEST := 10.0     # 每接待一位客人，全员合计消耗的体力
const ENERGY_REST := 55.0          # 每天休息恢复

var id: String = ""
var data: Dictionary = {}
var cell: Vector2i = Vector2i.ZERO
var footprint: Vector2i = Vector2i(4, 4)
var level: int = 1
var visitors: Array = []
var total_earned: int = 0
var invested: int = 0        # 建造 + 升级一共花掉的钱，拆除时按比例返还
var world: Node2D

var exterior: Sprite2D
var interior: Node2D
var interior_floor: Sprite2D
var label: Label

# 视角：false = 正面视角（星露谷那种，整张贴图铺满占地）；
#       true  = 备用 3/4 俯视（正面贴图 + 梯形屋顶 + 右侧墙，用分类色占位）。
const THREE_QUARTER_VIEW := false

var side_face: Sprite2D
var roof_face: Sprite2D
var front_face: Sprite2D

var staff: Array = []          # [{ energy: float, quality: int }]
var displayed: Array = []      # [{ item_id: String, count: int }]
var patients: Array = []       # 候诊顾客（医院）
var treating: Array = []       # 正在治疗的顾客（医院）
var guests: Array = []         # 已入住的客人（度假屋）
var check_ins: int = 0         # 办过多少次入住（招待厅）
var cleaned_total: int = 0     # 保洁间累计清理的垃圾数（汇总自保洁工人）
var janitors: Array = []       # 保洁间雇的工人（在外面走动扫地）
var cured_count: int = 0
var failed_count: int = 0
var understaffed_notice := false
var night_light: PointLight2D          # 建筑灯光（矩形：内部均匀 + 外圈渐变）
var light_on_hour := LIGHT_ON_LATEST   # 这栋楼今晚几点开灯（20:00~20:45 之间各自随机）


func setup(building_data: Dictionary, at_cell: Vector2i, world_ref: Node2D) -> void:
	data = building_data
	world = world_ref
	id = str(data.get("id", ""))
	cell = at_cell
	var f: Array = data.get("footprint", [4, 4])
	footprint = Vector2i(int(f[0]), int(f[1]))
	position = world.cell_to_world(cell)
	z_index = int(position.y)
	invested = int(data.get("cost", 0))
	_build_visuals()
	_build_lights()
	_apply_roof(bool(world.show_roofs))
	_refresh_label()
	set_process(is_clinic() or service() == "cleaning")   # 医院推进治疗，保洁间维持保洁工人


func _build_lights() -> void:
	# 用 World 的通用矩形光源工厂：平顶区对到建筑占地（内部均匀），
	# 渐变带对到外扩的那 1 格（只有周围一圈有渐变）。
	if world == null or not world.has_method("make_rect_light"):
		return
	night_light = world.make_rect_light(
		Vector2(footprint.x, footprint.y) * CELL,
		LIGHT_SPREAD_CELLS * float(CELL),
		Color(1.0, 0.86, 0.62))
	if night_light == null:
		return
	night_light.name = "NightLight"
	# 灯挂在 world 下（而不是建筑自己下面）：建筑的 z_index = position.y（可达 2000+），
	# 灯作为它的子节点会继承这个大 z，容易掉出 PointLight2D 的 z 范围而完全失效。
	# 挂到 world 根、用全局坐标定位；绘制顺序靠 make_rect_light 里压低的 z_index 控制。
	# 位置 = 建筑中心：cell_center(cell) 已经是建筑左上格的**中心**，
	# 所以只需再偏移「半个占地」（之前多加了半个占地，导致光偏向右下）。
	night_light.top_level = true
	var c: Vector2 = world.cell_center(cell) \
		+ Vector2(float(footprint.x - 1), float(footprint.y - 1)) * CELL * 0.5
	world.add_child(night_light)
	night_light.global_position = c
	# 层次：地板 → 灯光 → 屋顶/外墙。
	# 灯光必须夹在中间：开着屋顶时屋顶把灯光和地板一起盖住；
	# 关了屋顶（透视）时就只剩地板 + 灯光，室内才亮得起来。
	# 原来的添加顺序是「外墙 → 地板 → 灯」，地板反而盖在灯上面，光进不去。
	_relayer()

	# 每栋楼一个自己的开灯时间，形成「陆续开灯」的错落感
	light_on_hour = randf_range(LIGHT_ON_EARLIEST, LIGHT_ON_LATEST)


func _relayer() -> void:
	# 把子节点重排成：interior（地板）→ 灯光 → exterior / 各个面 → 标签
	# Godot 同 z_index 时按树顺序绘制，后添加的画在上面。
	for n in [interior, night_light, exterior, side_face, front_face, roof_face]:
		if n != null and n.get_parent() == self:
			move_child(n, -1)          # -1 = 移到末尾（最后绘制）
	for n2 in get_children():
		if n2 is Label:
			move_child(n2, -1)         # 名字标签永远在最上面


func update_lights(hour: float) -> void:
	# 由 World 每帧统一驱动。hour = GameClock.hour_of_day()（0~24），
	# 与 data/buildings*.json 的 open_hour/close_hour 同口径（酒吧是 22→4）。
	#
	# 关键：一律换算成「连续小时」再比较。
	#   凌晨（hour < 12）当作「前一天 24 点之后」→ hour += 24
	#   跨夜打烊（close < open）→ close += 24
	# 这样无论普通店还是跨夜店，都变成简单的区间判断，不需要特判。
	if night_light == null:
		return
	var h := hour
	if h < 12.0:
		h += 24.0                      # 凌晨 → 算作次日的 24~36 点
	var c := close_hour()
	if c < open_hour():
		c += 24.0                      # 跨夜店：打烊时间算到次日
	var k := clampf((h - light_on_hour) / LIGHT_FADE_HOURS, 0.0, 1.0)
	if h >= c:
		k = clampf(1.0 - (h - c) / LIGHT_FADE_HOURS, 0.0, 1.0)   # 到打烊时间渐渐熄灯
	if h < light_on_hour:
		k = 0.0                        # 傍晚之前不点灯
	var e := k * k * (3.0 - 2.0 * k)   # 平滑渐变（smoothstep）
	night_light.energy = e * LIGHT_ENERGY


func _process(delta: float) -> void:
	if service() == "cleaning":
		_process_cleaning(delta)
		return
	if treating.is_empty():
		return
	if GameClock.phase == GameClock.Phase.SETTLEMENT or GameClock.paused:
		return
	var scaled := delta * GameClock.time_scale()
	for patient in treating.duplicate():
		patient.treatment_left -= scaled
		if patient.treatment_left <= 0.0:
			treating.erase(patient)
			patient.finish_treatment(self)
	_promote_patient()


func _process_cleaning(_delta: float) -> void:
	# 保洁间本身不再"自动扫地"，改由雇来的保洁工人在外面走动清扫：
	# 几位员工就有几位工人，人走了工人也跟着消失。
	_sync_janitors()


func _sync_janitors() -> void:
	# 清掉已经失效的引用
	var alive: Array = []
	for j in janitors:
		if j != null and is_instance_valid(j):
			alive.append(j)
	janitors = alive
	# 员工数变化时补齐 / 减少工人
	while janitors.size() < staff.size():
		if world == null or world.staff_root == null:
			return
		var j: Node2D = JANITOR.new()
		j.name = "Janitor_%s_%d" % [id, janitors.size()]
		world.staff_root.add_child(j)
		j.setup(self, world)
		janitors.append(j)
	while janitors.size() > staff.size():
		var extra: Node = janitors.pop_back()
		if extra != null and is_instance_valid(extra):
			extra.queue_free()


func janitor_total_cleaned() -> int:
	var total := cleaned_total
	for j in janitors:
		if j != null and is_instance_valid(j):
			total += int(j.cleaned_total)
	return total


func remove_janitors() -> void:
	# 建筑被拆掉时调用：工人一并撤走
	for j in janitors:
		if j != null and is_instance_valid(j):
			j.home = null          # 断开引用，工人下一帧会自己清理掉
			j.queue_free()
	janitors.clear()


func unlock_fame() -> int:
	return int(data.get("unlock_fame", 0))


func is_unlocked() -> bool:
	return GameState.fame >= float(unlock_fame())


func service() -> String:
	return str(data.get("service", ""))


func _build_visuals() -> void:
	var cfg: Dictionary = data.get("sprite", {})
	var rect_arr: Array = cfg.get("rect", [0, 0, 64, 64])
	var rect := Rect2(rect_arr[0], rect_arr[1], rect_arr[2], rect_arr[3])
	var tex: Texture2D = load(str(cfg.get("atlas", "")))

	if THREE_QUARTER_VIEW:
		_build_three_quarter(tex, rect, footprint.x * CELL, footprint.y * CELL)
	else:
		_build_front_view(tex, rect)

	# 内部（关掉屋顶后可见）
	interior = Node2D.new()
	interior.name = "Interior"
	add_child(interior)

	interior_floor = Sprite2D.new()
	interior_floor.texture = load("res://art/placeholder/tiles/interior_floor.png")
	interior_floor.region_enabled = true
	interior_floor.region_rect = Rect2(0, 0, footprint.x * 16, footprint.y * 16)
	interior_floor.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	interior_floor.centered = false
	interior_floor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	interior_floor.scale = Vector2(DataRegistry.SPRITE_SCALE, DataRegistry.SPRITE_SCALE)
	interior.add_child(interior_floor)

	# 简易墙体边框，让“透视”状态看起来像室内
	var border := 6.0
	var w := footprint.x * CELL
	var h := footprint.y * CELL
	for spec in [
		Rect2(0, 0, w, border),
		Rect2(0, h - border, w, border),
		Rect2(0, 0, border, h),
		Rect2(w - border, 0, border, h),
	]:
		var cr := ColorRect.new()
		cr.color = Color(0.16, 0.12, 0.10, 0.85)
		cr.position = spec.position
		cr.size = spec.size
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		interior.add_child(cr)

	_build_label()


func _build_front_view(tex: Texture2D, rect: Rect2) -> void:
	# 旧的前视角：整张贴图铺满占地
	exterior = Sprite2D.new()
	exterior.name = "Exterior"
	exterior.texture = tex
	exterior.region_enabled = true
	exterior.region_rect = rect
	exterior.centered = false
	exterior.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	exterior.scale = Vector2(
		float(footprint.x * CELL) / maxf(rect.size.x, 1.0),
		float(footprint.y * CELL) / maxf(rect.size.y, 1.0))
	add_child(exterior)


func _build_three_quarter(tex: Texture2D, rect: Rect2, width: float, height: float) -> void:
	var cap_h := height * 0.26           # 屋顶顶面高度
	var side_w := width * 0.16           # 右侧墙宽度
	var base_color := DataRegistry.get_category_color(category())
	var roof_color := base_color.darkened(0.30)
	var side_color := base_color.darkened(0.55)
	var line := Color(0.08, 0.07, 0.10, 0.85)

	# 右侧墙：一块斜的深色面，接在正面右边
	side_face = Sprite2D.new()
	side_face.name = "SideFace"
	var side_poly := Polygon2D.new()
	side_poly.color = side_color
	side_poly.polygon = PackedVector2Array([
		Vector2(width - side_w * 0.2, 0),
		Vector2(width + side_w * 0.8, -cap_h * 0.75),
		Vector2(width + side_w * 0.8, height - cap_h * 0.75),
		Vector2(width - side_w * 0.2, height),
	])
	side_face.add_child(side_poly)
	add_child(side_face)

	# 正面：整张贴图保持原比例（不切图，避免把招牌、门窗切断）
	front_face = Sprite2D.new()
	front_face.name = "FrontFace"
	front_face.texture = tex
	front_face.region_enabled = true
	front_face.region_rect = rect
	front_face.centered = false
	front_face.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	front_face.scale = Vector2(width / rect.size.x, height / rect.size.y)
	front_face.position = Vector2.ZERO
	add_child(front_face)

	# 屋顶顶面：一块上窄下宽的梯形色块，盖在建筑上方
	roof_face = Sprite2D.new()
	roof_face.name = "RoofFace"
	var roof_poly := Polygon2D.new()
	roof_poly.color = roof_color
	roof_poly.polygon = PackedVector2Array([
		Vector2(0, 0),
		Vector2(width, 0),
		Vector2(width + side_w * 0.8, -cap_h),
		Vector2(side_w * 0.8, -cap_h),
	])
	roof_face.add_child(roof_poly)
	var roof_edge := Line2D.new()
	roof_edge.points = PackedVector2Array([
		Vector2(0, 0), Vector2(width, 0), Vector2(width + side_w * 0.8, -cap_h),
		Vector2(side_w * 0.8, -cap_h), Vector2(0, 0),
	])
	roof_edge.width = 2.0
	roof_edge.default_color = line
	roof_face.add_child(roof_edge)
	add_child(roof_face)

	exterior = front_face    # 兼容旧逻辑：用正面墙代表整体外观


func _build_label() -> void:
	label = Label.new()
	label.text = display_name()
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-CELL, -30)
	label.size = Vector2(footprint.x * CELL + CELL * 2, 28)
	add_child(label)


func display_name() -> String:
	var extra := ""
	if is_clinic() and doctor_quality() > 1:
		extra = " 名医%d" % doctor_quality()
	return "%s Lv.%d%s" % [str(data.get("name", id)), level, extra]


func set_level(new_level: int) -> void:
	level = max(1, new_level)
	_refresh_label()


func _refresh_label() -> void:
	if label:
		label.text = display_name()


func category() -> String:
	return str(data.get("category", ""))


func is_clinic() -> bool:
	return category() == "medical"


func is_showroom() -> bool:
	return category() == "special"


func is_lodging() -> bool:
	return category() == "lodging"


func is_reception() -> bool:
	return id == "reception"


func room_capacity() -> int:
	# 能住几位客人：普通 1 人、自然风 2 人、现代风 3 人
	return maxi(1, int(data.get("room_slots", 1)))


func has_free_room(party_size: int = 1) -> bool:
	return is_lodging() and guests.size() + party_size <= room_capacity()


func needs_staff() -> bool:
	# 度假屋和招待厅不需要雇员工
	return not (is_lodging() or is_reception())


func staff_slots() -> int:
	return int(data.get("staff_slots", 1))


func is_self_service() -> bool:
	# 自助设施（公共卫生间、共享单车租借所）：压根没有员工编制，
	# 所以既不该因为「没人上班」被扣心情，也不该因为「有人上班」被加心情。
	return staff_slots() <= 0


func add_guest(customer: Node2D) -> void:
	guests.append(customer)


func remove_guest(customer: Node2D) -> void:
	guests.erase(customer)


func charge_stay(customer: Node2D, nights: int) -> int:
	# 住宿费在结账时才产生
	if not is_lodging() or nights <= 0:
		return 0
	var fee := spend_value() * nights
	total_earned += fee
	return fee


func open_hour() -> float:
	return float(data.get("open_hour", 6))


func close_hour() -> float:
	return float(data.get("close_hour", 24))


func is_night_business() -> bool:
	# 营业时间跨过 24 点（例如 22 点到凌晨 4 点）
	return close_hour() < open_hour()


func is_open_at(hour: float) -> bool:
	var o := open_hour()
	var c := close_hour()
	if c > o:
		return hour >= o and hour < c
	return hour >= o or hour < c


func hours_text() -> String:
	return "%02d:00 - %02d:00" % [int(open_hour()), int(close_hour())]


func night_income_estimate() -> int:
	# 只在夜里营业的店（酒吧一类）：玩家选择休息 / 探索时按估算自动结算
	if not is_night_business():
		return 0
	var base := float(spend_value()) * float(capacity()) * 0.55
	var reputation_factor := clampf(0.6 + GameState.reputation / 120.0, 0.5, 1.8)
	var staff_factor := 0.25
	if not staff.is_empty():
		staff_factor = 0.35 + 0.65 * (staff_energy() / 100.0)
	return int(round(base * reputation_factor * staff_factor * (0.7 + 0.3 * PlayerStats.fame_multiplier())))


func capacity() -> int:
	var base := int(data.get("capacity", 4))
	return int(round(base * (1.0 + 0.5 * float(level - 1))))


func spend_value() -> int:
	var base := float(data.get("spend", 50))
	return int(round(base * (1.0 + 0.25 * float(level - 1))))


func mood_bonus() -> float:
	return float(data.get("mood_bonus", 0)) * float(level) + staff_mood_bonus()


func staff_mood_bonus() -> float:
	if not needs_staff():
		return 0.0      # 度假屋 / 招待厅没有员工也不影响心情
	if is_self_service():
		return 0.0      # 自助设施（卫生间 / 共享单车）没有员工编制
	if staff.is_empty():
		return -14.0    # 一个人都没有，客人体验很差
	var energy := staff_energy()
	if energy >= 60.0:
		return 4.0
	if energy >= 30.0:
		return 0.0
	return -12.0        # 全员状态很低


func has_room() -> bool:
	return visitors.size() < capacity()


func add_visitor(customer: Node2D) -> void:
	visitors.append(customer)


func remove_visitor(customer: Node2D) -> void:
	visitors.erase(customer)


func on_guest_served() -> void:
	if is_self_service():
		return          # 自助设施没有员工编制，不算「没人上班」
	if staff.is_empty():
		if not understaffed_notice:
			understaffed_notice = true
			GameState.notice.emit("%s 没有员工，客人体验受影响" % str(data.get("name", id)))
		return
	var per := ENERGY_PER_GUEST / float(staff.size())
	for member in staff:
		member["energy"] = clampf(float(member.get("energy", 100.0)) - per, 0.0, 100.0)


# ---------- 员工 ----------

func hire_staff(quality: int = 1) -> bool:
	if staff.size() >= staff_slots():
		return false
	staff.append({"energy": 85.0, "quality": quality})
	understaffed_notice = false
	_refresh_label()
	return true


func fill_staff() -> int:
	# 按编制把员工招满（完全测试模式用：所有建筑直接进入「人员齐备」状态）
	var hired := 0
	while hire_staff():
		hired += 1
	return hired


func fire_staff() -> bool:
	if staff.is_empty():
		return false
	staff.pop_back()
	_refresh_label()
	return true


func staff_energy() -> float:
	if staff.is_empty():
		return 0.0
	var total := 0.0
	for member in staff:
		total += float(member.get("energy", 0.0))
	return total / float(staff.size())


func daily_wage() -> int:
	return int(data.get("staff_wage", 0)) * staff.size()


func rest_staff() -> void:
	for member in staff:
		member["energy"] = clampf(float(member.get("energy", 0.0)) + ENERGY_REST, 0.0, 100.0)


func doctor_quality() -> int:
	if not is_clinic() or staff.is_empty():
		return 1
	var best := 1
	for member in staff:
		best = maxi(best, int(member.get("quality", 1)))
	return best


func upgrade_doctor_cost() -> int:
	var q := doctor_quality()
	if q >= 3:
		return 0
	return 1200 * q


func can_upgrade_doctor() -> bool:
	return is_clinic() and doctor_quality() < 3


func upgrade_doctor() -> bool:
	if not can_upgrade_doctor():
		return false
	var cost := upgrade_doctor_cost()
	if not GameState.spend(cost, "聘请名医"):
		return false
	for member in staff:
		member["quality"] = int(member.get("quality", 1)) + 1
		break
	if staff.is_empty():
		hire_staff(doctor_quality() + 1)
	_refresh_label()
	return true


# ---------- 升级 ----------

func max_level() -> int:
	return int(data.get("max_level", 3))


func upgrade_cost() -> int:
	var base := float(data.get("cost", 500))
	return int(round(base * (0.8 * float(level) + 0.4)))


func upgrade_items() -> Dictionary:
	var table: Dictionary = data.get("upgrade_items", {})
	return table.get(str(level + 1), {})


func can_upgrade() -> bool:
	if level >= max_level():
		return false
	if not GameState.can_afford(upgrade_cost()):
		return false
	for item_id in upgrade_items().keys():
		if GameState.item_count(item_id) < int(upgrade_items()[item_id]):
			return false
	return true


func upgrade_block_reason() -> String:
	if level >= max_level():
		return "已是最高等级"
	if not GameState.can_afford(upgrade_cost()):
		return "资金不足"
	for item_id in upgrade_items().keys():
		var need := int(upgrade_items()[item_id])
		if GameState.item_count(item_id) < need:
			return "缺少 %s ×%d" % [DataRegistry.item_name(item_id), need - GameState.item_count(item_id)]
	return ""


func upgrade() -> bool:
	if not can_upgrade():
		return false
	var cost := upgrade_cost()
	GameState.spend(cost, "升级")
	invested += cost
	for item_id in upgrade_items().keys():
		GameState.remove_item(item_id, int(upgrade_items()[item_id]))
	level += 1
	_refresh_label()
	return true


func refund_value() -> int:
	# 拆除时返还一半投入（升级花掉的也算进去）
	return int(round(float(invested) * 0.5))


func evacuate() -> void:
	# 拆除前把店里的客人 / 病人请出去，避免出现悬空引用
	for customer in visitors.duplicate():
		if is_instance_valid(customer):
			customer.force_leave(self)
	visitors.clear()
	for patient in patients.duplicate():
		if is_instance_valid(patient):
			patient.force_leave(self)
	patients.clear()
	treating.clear()
	for guest in guests.duplicate():
		if is_instance_valid(guest):
			guest.force_leave(self)
	guests.clear()
	remove_janitors()      # 保洁间被拆：工人一并撤走


# ---------- 展厅 ----------

func display_capacity() -> int:
	var base := int(data.get("display_slots", 0))
	if base <= 0:
		return 0
	return base + (level - 1) * 3


func display_used() -> int:
	var total := 0
	for entry in displayed:
		total += int(entry.get("count", 0))
	return total


func display_score() -> int:
	var total := 0
	for entry in displayed:
		total += DataRegistry.rarity_weight(str(entry.get("item_id", ""))) * int(entry.get("count", 1))
	return total


func add_display(item_id: String, count: int = 1) -> bool:
	if not is_showroom():
		return false
	if display_used() + count > display_capacity():
		return false
	if not GameState.remove_item(item_id, count):
		return false
	for entry in displayed:
		if str(entry.get("item_id", "")) == item_id:
			entry["count"] = int(entry.get("count", 0)) + count
			return true
	displayed.append({"item_id": item_id, "count": count})
	return true


func remove_display(index: int, count: int = 1) -> bool:
	if index < 0 or index >= displayed.size():
		return false
	var entry: Dictionary = displayed[index]
	var take: int = mini(count, int(entry.get("count", 0)))
	if take <= 0:
		return false
	GameState.add_item(str(entry.get("item_id", "")), take)
	entry["count"] = int(entry.get("count", 0)) - take
	if int(entry["count"]) <= 0:
		displayed.remove_at(index)
	return true


func settle_display_sales() -> int:
	# 每天结算时，展厅里的东西会按稀有度与客流概率被买走
	if not is_showroom() or displayed.is_empty():
		return 0
	var income := 0
	var score := display_score()
	var chance := clampf(0.10 + 0.01 * float(score) + 0.004 * float(GameState.daily_visitors), 0.05, 0.7)
	for entry in displayed.duplicate():
		if randf() > chance:
			continue
		var item_id := str(entry.get("item_id", ""))
		var price := int(round(float(DataRegistry.item_value(item_id)) * randf_range(1.05, 1.35) * PlayerStats.bargain_multiplier()))
		entry["count"] = int(entry.get("count", 0)) - 1
		income += price
		GameState.earn_item_sale(price)
		GameState.add_reputation(0.4)
		GameState.notice.emit("展厅成交：%s +%s" % [DataRegistry.item_name(item_id), GameState.format_money(price)])
		if int(entry["count"]) <= 0:
			displayed.erase(entry)
	return income


# ---------- 医院 ----------

func treat_level() -> int:
	return level if is_clinic() else 0


func treat_capacity() -> int:
	if not is_clinic():
		return 0
	return maxi(1, level + doctor_quality() - 1)


func treatment_seconds(illness: Dictionary) -> float:
	var hours := float(illness.get("treat_hours", 2.0))
	var quality := float(doctor_quality())
	# 一天 24 小时，按比例换算成游戏内秒数
	return hours * (GameClock.cycle_length_seconds / 24.0) / quality


func accept_patient(customer: Node2D) -> bool:
	if not is_clinic():
		return false
	patients.append(customer)
	_promote_patient()
	return true


func release_patient(customer: Node2D) -> void:
	patients.erase(customer)
	treating.erase(customer)


func _promote_patient() -> void:
	while treating.size() < treat_capacity() and not patients.is_empty():
		var next: Node2D = patients.pop_front()
		treating.append(next)
		next.begin_treatment(self)


func door_point() -> Vector2:
	return global_position + Vector2(footprint.x * CELL * 0.5, footprint.y * CELL - 4)


func door_cell() -> Vector2i:
	# 门口：建筑正下方那一格。它是「首选」出入口（贴图上的门在这边），
	# 但不再是唯一出入口 —— 见 perimeter_cells()。
	return cell + Vector2i(int(footprint.x / 2), footprint.y)


func perimeter_cells() -> Array:
	# 建筑外圈一圈格子（占地四周各向外一格），也就是「可以进出这栋楼的位置」。
	# 只返回格子，是否可通行由 world 判断。
	var out: Array = []
	var x0 := cell.x - 1
	var y0 := cell.y - 1
	var x1 := cell.x + footprint.x
	var y1 := cell.y + footprint.y
	for x in range(x0, x1 + 1):
		out.append(Vector2i(x, y0))
		out.append(Vector2i(x, y1))
	for y in range(y0 + 1, y1):
		out.append(Vector2i(x0, y))
		out.append(Vector2i(x1, y))
	return out


func entry_point() -> Vector2:
	# 入口的世界坐标（贴图上的门那一格中心），供朝向/距离判断用
	return Vector2(door_cell()) * float(CELL) + Vector2(CELL, CELL) * 0.5


func interior_point() -> Vector2:
	var margin := 20.0
	var w := footprint.x * CELL
	var h := footprint.y * CELL
	return global_position + Vector2(
		randf_range(margin, w - margin),
		randf_range(margin, h - margin))


func apply_roof_mode(show_roof: bool) -> void:
	_apply_roof(show_roof)


func _apply_roof(show_roof: bool) -> void:
	if exterior:
		exterior.visible = show_roof
	if front_face:
		front_face.visible = show_roof
	if side_face:
		side_face.visible = show_roof
	if roof_face:
		roof_face.visible = show_roof
	if interior:
		interior.visible = not show_roof


func save_data() -> Dictionary:
	var staff_save: Array = []
	for member in staff:
		staff_save.append({"energy": float(member.get("energy", 100.0)), "quality": int(member.get("quality", 1))})
	return {
		"id": id,
		"cell": [cell.x, cell.y],
		"level": level,
		"staff": staff_save,
		"displayed": displayed.duplicate(true),
	}


func apply_save(d: Dictionary) -> void:
	set_level(int(d.get("level", 1)))
	staff.clear()
	for member in d.get("staff", []):
		staff.append({"energy": float(member.get("energy", 100.0)), "quality": int(member.get("quality", 1))})
	displayed.clear()
	for entry in d.get("displayed", []):
		displayed.append({"item_id": str(entry.get("item_id", "")), "count": int(entry.get("count", 1))})
	_refresh_label()
