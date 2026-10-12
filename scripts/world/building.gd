extends Node2D
class_name Building

const JANITOR := preload("res://scripts/customers/janitor.gd")
const LIGHT_ON_EARLIEST := 20.0    # 20:00 起陆续开灯
const LIGHT_ON_LATEST := 20.75     # 20:45 全部亮起
const LIGHT_FADE_HOURS := 0.12     # 每栋楼自己的渐变时长（约 7 分钟游戏时间）
const LIGHT_SPREAD_CELLS := 1.0    # 光往建筑外扩几格（这一圈就是渐变带）
const LIGHT_ENERGY := 0.72         # 灯光强度。用加法混合，太高会让外圈过曝成「黄框」
const LIGHT_OFF_SPREAD_HOURS := 0.5   # 打烊后「陆续关灯」的错峰窗口：常规店 24:00 打烊 → 24:00~24:30 之间各自熄灭
# 熄灯时间不再写死：常规店在打烊后 0~0.5 小时里陆续关，跨夜店跟自己的打烊时间（见 update_lights）
## 单栋建筑：外观、屋顶开关、同时招待人数、员工、升级、展厅展示位、诊所治疗。


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
var reserved := 0              # 已被「正在走过来的客人」预定走的使用位（进店时转成 visitors）
var queued: Array = []         # 站在门口预定位上排队的客人
var queue_reserved := 0        # 已被「正在走过来排队的客人」占住的预定位
var guests: Array = []         # 已入住的客人（度假屋）
var check_ins: int = 0         # 办过多少次入住（招待厅）
var cleaned_total: int = 0     # 保洁间累计清理的垃圾数（汇总自保洁工人）
var janitors: Array = []       # 保洁间雇的工人（在外面走动扫地）
var cured_count: int = 0
var failed_count: int = 0
var understaffed_notice := false
var night_light: PointLight2D          # 建筑灯光（矩形＝内部均匀，圆形＝中心衰减，见 _build_lights）
var light_on_hour := LIGHT_ON_LATEST   # 这栋楼今晚几点开灯（20:00~20:45 之间各自随机）
var light_off_hour := 0.0              # 这栋楼今晚几点熄灯（打烊后 0~0.5 小时之间各自随机；跨夜店不拖）
var rot_step := 0                      # 可旋转建筑的朝向：0=下、1=左、2=上、3=右（顺时针一档 90°）
var _light_base_pos := Vector2.ZERO    # 灯光基准位置（建筑中心），朝向偏移从这里算


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
	# 用 World 的光源工厂：
	#   默认（矩形）= 平顶区对到建筑占地（内部均匀）+ 外圈一圈渐变带；
	#   数据里写 light_shape=circle 的（路灯）改用圆形衰减光。
	if world == null or not world.has_method("make_rect_light"):
		return
	var color := Color(1.0, 0.86, 0.62)
	if str(data.get("light_shape", "rect")) == "circle" and world.has_method("make_circle_light"):
		night_light = world.make_circle_light(
			float(data.get("light_radius_cells", 2.0)) * float(CELL), color)
	else:
		night_light = world.make_rect_light(
			Vector2(footprint.x, footprint.y) * CELL,
			LIGHT_SPREAD_CELLS * float(CELL),
			color)
	if night_light == null:
		return
	night_light.name = "NightLight"
	# 灯挂在 world 下（而不是建筑自己下面）：建筑的 z_index = position.y（可达 2000+），
	# 灯作为它的子节点会继承这个大 z，容易掉出 PointLight2D 的 z 范围而完全失效。
	# 挂到 world 根、用全局坐标定位；绘制顺序靠 make_rect_light 里压低的 z_index 控制。
	# 位置 = 建筑中心：cell_center(cell) 已经是建筑左上格的**中心**，
	# 所以只需再偏移「半个占地」（之前多加了半个占地，导致光偏向右下）。
	night_light.top_level = true
	# 基准位置 = 建筑中心：cell_center(cell) 已经是建筑左上格的**中心**，
	# 所以只需再偏移「半个占地」。可旋转建筑（路灯）的灯光会从这里再偏出去一格。
	_light_base_pos = world.cell_center(cell) \
		+ Vector2(float(footprint.x - 1), float(footprint.y - 1)) * CELL * 0.5
	world.add_child(night_light)
	_refresh_light_position()
	# 层次：地板 → 灯光 → 屋顶/外墙。
	# 灯光必须夹在中间：开着屋顶时屋顶把灯光和地板一起盖住；
	# 关了屋顶（透视）时就只剩地板 + 灯光，室内才亮得起来。
	# 原来的添加顺序是「外墙 → 地板 → 灯」，地板反而盖在灯上面，光进不去。
	_relayer()

	# 开灯时间：默认在 20:00~20:45 之间随机，形成「陆续开灯」的错落感；
	# 数据里写了 light_on_hour 就固定用它（路灯这类小物件要准点点亮）。
	if data.has("light_on_hour"):
		light_on_hour = float(data.get("light_on_hour"))
	else:
		light_on_hour = randf_range(LIGHT_ON_EARLIEST, LIGHT_ON_LATEST)
	# 熄灯时间：常规店打烊后在 0~0.5 小时里陆续熄灭（24:00 打烊 → 24:00~24:30）；
	# 跨夜店（如酒吧 22→4）关门时已经很晚，直接按打烊时间熄，不再往后拖。
	var close_h := close_hour()
	light_off_hour = close_h if close_h < open_hour() else close_h + randf_range(0.0, LIGHT_OFF_SPREAD_HOURS)
	# 光晕大小默认按占地自动算（见 World.make_rect_light）；
	# 小建筑可以用 light_glow_scale 把光晕整体放大（路灯 1×1 的光晕靠它照到周围）。
	var glow := float(data.get("light_glow_scale", 1.0))
	if glow != 1.0:
		night_light.texture_scale *= glow


# ---------- 朝向（可旋转建筑：路灯） ----------

func is_rotatable() -> bool:
	return bool(data.get("rotatable", false))


func rotation_dir() -> Vector2i:
	# 0=下、1=左、2=上、3=右：顺时针每转一档 90°，灯光就偏到对应的那一格。
	match rot_step:
		1: return Vector2i(-1, 0)
		2: return Vector2i(0, -1)
		3: return Vector2i(1, 0)
		_: return Vector2i(0, 1)


func rotation_text() -> String:
	match rot_step:
		1: return "左"
		2: return "上"
		3: return "右"
		_: return "下"


func rotate_clockwise() -> void:
	if not is_rotatable():
		return
	rot_step = (rot_step + 1) % 4
	_apply_rotation()
	_refresh_light_position()


func dir_rects() -> Array:
	# 四方向素材：sprite.dir_rects 按朝向 0~3（下/左/上/右）给出四帧的裁剪区
	var cfg: Dictionary = data.get("sprite", {})
	return cfg.get("dir_rects", [])


func _apply_rotation() -> void:
	# 旋转只作用在「正面贴图」这一层：优先用四方向素材换帧（dir_rects），
	# 没有分方向素材时才退回「把贴图旋转 90° 的整数倍」。
	# （兜底路径注意：精灵原点在左上角，要先让绘制区以原点居中、节点放到建筑中心，
	#   旋转才是绕建筑中心转，否则会绕角转飞。）
	if not is_rotatable():
		return
	var vis: Sprite2D = exterior
	if vis == null:
		return   # 备用 3/4 视角没有这条路径，需要时再补
	var frames := dir_rects()
	if not frames.is_empty():
		# 有四个方向的素材：直接换帧（灯头朝向由画的那一帧决定，不做节点旋转）
		var r: Array = frames[mini(rot_step, frames.size() - 1)]
		vis.region_rect = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
		vis.position = Vector2.ZERO
		vis.offset = Vector2.ZERO
		vis.rotation = 0.0
		return
	# 没有分方向素材时的兜底：只画「朝下」一版，游戏里把贴图转 90° 的整数倍
	vis.position = Vector2(footprint.x, footprint.y) * CELL * 0.5
	vis.offset = -vis.region_rect.size * 0.5
	vis.rotation = float(rot_step) * PI / 2.0


func light_offset_cells() -> Vector2i:
	# 灯光相对建筑中心的偏移（格）。不可旋转的建筑恒为 0。
	return rotation_dir() if is_rotatable() else Vector2i.ZERO


func _refresh_light_position() -> void:
	if night_light == null:
		return
	night_light.global_position = _light_base_pos + Vector2(light_offset_cells()) * float(CELL)


func _exit_tree() -> void:
	# 灯挂在 World 根下（不在建筑子节点里），建筑被拆 / 清场时要顺手回收，
	# 否则会留下一盏孤儿灯继续亮在原地。
	if night_light != null and is_instance_valid(night_light):
		night_light.queue_free()
	night_light = null


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
	#   跨夜打烊（close < open）→ 熄灯时间 += 24
	# 这样无论普通店还是跨夜店，都变成简单的区间判断，不需要特判。
	if night_light == null:
		return
	var h := hour
	if h < 12.0:
		h += 24.0                      # 凌晨 → 算作次日的 24~36 点
	var off := light_off_hour
	if off < open_hour():
		off += 24.0                    # 跨夜店：熄灯时间算到次日
	var k := clampf((h - light_on_hour) / LIGHT_FADE_HOURS, 0.0, 1.0)
	if h >= off:
		k = clampf(1.0 - (h - off) / LIGHT_FADE_HOURS, 0.0, 1.0)   # 到熄灯时间渐渐熄灯
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
		if patient == null or not is_instance_valid(patient):
			treating.erase(patient)      # 病人已被释放/离场：清掉引用，别访问到旧对象
			continue
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
	# 只保留「当前在班」的工人（白班 08:00-20:00、夜班 20:00-08:00）。
	# 交班 / 人数变化时整队重建——工人数量少，代价可以忽略，
	# 而且下班的工人会立即从地图上消失，不会留在场上。
	var counts := shift_counts()
	var want_day: int = int(counts.get("day", 0)) if shift_on_duty("day") else 0
	var want_night: int = int(counts.get("night", 0)) if shift_on_duty("night") else 0
	var have_day := 0
	var have_night := 0
	var intact := janitors.size() == want_day + want_night
	if intact:
		for j in janitors:
			if j == null or not is_instance_valid(j):
				intact = false
				break
			if str(j.shift) == "night":
				have_night += 1
			else:
				have_day += 1
		intact = intact and have_day == want_day and have_night == want_night
	if intact:
		return
	for j in janitors:
		if j != null and is_instance_valid(j):
			j.home = null          # 断开引用，工人下一帧会自己清理掉
			j.queue_free()
	janitors.clear()
	if world == null or world.staff_root == null:
		return
	for i in range(want_day):
		_spawn_janitor("day", i)
	for i in range(want_night):
		_spawn_janitor("night", i)


func _spawn_janitor(shift_name: String, index: int) -> void:
	var j: Node2D = JANITOR.new()
	j.name = "Janitor_%s_%s_%d" % [id, shift_name, index]
	world.staff_root.add_child(j)
	j.setup(self, world)
	j.shift = shift_name
	janitors.append(j)


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


func charge_stay(_customer: Node2D, nights: int) -> int:
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
	# 最大同时招待人数：默认 1 级 3 人、每升一级 +1
	# （数据里可用 capacity_base / capacity_per_level 覆盖；不接客的设施如路灯写 capacity_base: 0，
	#  这样它永远不会被客人选中，也不会被算进「开门店铺」）
	var base := int(data.get("capacity_base", 3))
	if base <= 0:
		return 0
	return base + (level - 1) * int(data.get("capacity_per_level", 1))


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


# ---------- 使用位 / 预定位（排队）----------
# 每个「使用位」配一个「预定位」：使用位是客人真正在店里消费的位子；
# 预定位是门口那一列排队位。客人拿到使用位（哪怕还在路上）就算占用；
# 使用位满了之后，别的客人会来占预定位、走到门口排着，等使用位空出来再顶上去。

func queue_slots() -> int:
	return capacity()


func _prune_slots() -> void:
	# 兜底：清掉已释放的客人引用。正常情况客人销毁时会自己还位子（customer 的 PREDELETE），
	# 这里只是保险，避免个别漏网路径让店铺的名单里留下「僵尸占位」。
	if not visitors.is_empty():
		for i in range(visitors.size() - 1, -1, -1):
			if not is_instance_valid(visitors[i]):
				visitors.remove_at(i)
	if not queued.is_empty():
		for i in range(queued.size() - 1, -1, -1):
			if not is_instance_valid(queued[i]):
				queued.remove_at(i)


func has_use_slot() -> bool:
	_prune_slots()
	return visitors.size() + reserved < capacity()


func has_queue_slot() -> bool:
	_prune_slots()
	return capacity() > 0 and queued.size() + queue_reserved < queue_slots()


func reserve_use_slot() -> bool:
	# 客人定下这家店时占住使用位：别的客人不会再选这家，直到他消费完（或改道 / 离场）
	if not has_use_slot():
		return false
	reserved += 1
	return true


func release_use_slot() -> void:
	# 使用位释放：客人改道 / 离场 / 进店（预定转正式占位）时都会走这里；
	# 空出来的位子立刻让排队的第一位顶上去
	reserved = maxi(0, reserved - 1)
	promote_queue()


func reserve_queue_slot() -> bool:
	# 占一个预定位（客人正在走过来排队的路上）
	if not has_queue_slot():
		return false
	queue_reserved += 1
	return true


func join_queue(customer: Node2D) -> void:
	# 走到门口：把「在途预定位」转成「站在队里」
	queue_reserved = maxi(0, queue_reserved - 1)
	if not queued.has(customer):
		queued.append(customer)


func leave_queue(customer: Node2D) -> void:
	# 客人不等了 / 离场：在队里就摘掉，还在半路就把在途预定位还回来
	if queued.has(customer):
		queued.erase(customer)
	else:
		queue_reserved = maxi(0, queue_reserved - 1)


func promote_queue() -> void:
	# 使用位空出来：让排队最前面的客人顶上（他会直接进店）
	_prune_slots()
	while visitors.size() + reserved < capacity() and not queued.is_empty():
		var next: Node2D = queued.pop_front()
		if next == null or not is_instance_valid(next):
			continue
		if next.has_method("promote_from_queue"):
			next.promote_from_queue(self)


func queue_cell(index: int) -> Vector2i:
	# 预定位：门口那一列往街上一格格排开（走不通就停在最后一格，客人会叠在一起）
	var door := door_cell()
	if index <= 0 or world == null:
		return door
	var last := door
	for i in range(1, index + 1):
		var candidate := door + Vector2i(0, i)
		if not world.is_walkable(candidate):
			break
		last = candidate
	return last


func queue_point(customer: Node2D) -> Vector2:
	_prune_slots()
	var idx: int = maxi(queued.find(customer), 0)
	return world.cell_center(queue_cell(idx))


func add_visitor(customer: Node2D) -> void:
	visitors.append(customer)


func remove_visitor(customer: Node2D) -> void:
	visitors.erase(customer)
	promote_queue()      # 有人消费完出来了：排队的第一位顶上


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
	var member := {"energy": 85.0, "quality": quality}
	if service() == "cleaning":
		member["shift"] = next_shift()      # 保洁分白班/夜班，往人少的那班补
	staff.append(member)
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


# ---------- 班次（保洁间：白班 08:00-20:00，夜班 20:00-08:00；其它建筑不排班） ----------

func shift_counts() -> Dictionary:
	var day := 0
	var night := 0
	for m in staff:
		if str(m.get("shift", "day")) == "night":
			night += 1
		else:
			day += 1
	return {"day": day, "night": night}


func next_shift() -> String:
	# 下一名员工编入哪一班：哪班人少去哪个（一样多时先补白班）
	var counts := shift_counts()
	return "day" if int(counts.get("day", 0)) <= int(counts.get("night", 0)) else "night"


func shift_on_duty(shift_name: String, hour: float = -1.0) -> bool:
	# 白班 08:00-20:00，夜班 20:00-08:00；hour 省略时取当前游戏时间
	var h := hour if hour >= 0.0 else GameClock.hour_of_day()
	var is_day := h >= 8.0 and h < 20.0
	return is_day if shift_name != "night" else not is_day


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
	for patient in treating.duplicate():
		if is_instance_valid(patient):
			patient.force_leave(self)    # 正在治疗的也要通知，否则他们会永远停在「治疗中」
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
		if next == null or not is_instance_valid(next):
			continue                     # 已经离场的病人：跳过，别塞进治疗列表
		treating.append(next)
		next.begin_treatment(self)


func door_point() -> Vector2:
	return global_position + Vector2(footprint.x * CELL * 0.5, footprint.y * CELL - 4)


func door_cell() -> Vector2i:
	# 门口：建筑正下方那一格。它是「首选」出入口（贴图上的门在这边），
	# 但不再是唯一出入口 —— 见 perimeter_cells()。
	@warning_ignore("integer_division")
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
		staff_save.append({
			"energy": float(member.get("energy", 100.0)),
			"quality": int(member.get("quality", 1)),
			"shift": str(member.get("shift", "day")),
		})
	return {
		"id": id,
		"cell": [cell.x, cell.y],
		"level": level,
		"rot": rot_step,
		"staff": staff_save,
		"displayed": displayed.duplicate(true),
	}


func apply_save(d: Dictionary) -> void:
	set_level(int(d.get("level", 1)))
	staff.clear()
	for member in d.get("staff", []):
		var staff_entry := {
			"energy": float(member.get("energy", 100.0)),
			"quality": int(member.get("quality", 1)),
		}
		if member.has("shift"):
			staff_entry["shift"] = str(member["shift"])
		staff.append(staff_entry)
	_ensure_staff_shifts()
	displayed.clear()
	for entry in d.get("displayed", []):
		displayed.append({"item_id": str(entry.get("item_id", "")), "count": int(entry.get("count", 1))})
	rot_step = int(d.get("rot", 0)) % 4
	_apply_rotation()
	_refresh_light_position()
	_refresh_label()


func _ensure_staff_shifts() -> void:
	# 旧存档的保洁员工没有班次字段：按「往人少的一班补」的规则补上，保证白夜两班均衡
	if service() != "cleaning":
		return
	var missing := false
	for m in staff:
		if not m.has("shift"):
			missing = true
			break
	if not missing:
		return
	for m in staff:
		if not m.has("shift"):
			m["shift"] = next_shift()
