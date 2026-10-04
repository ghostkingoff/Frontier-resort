extends Node
## 全天 24 小时连成一条时间轴：
## 06:00 出发 → 24:00 暂停结算 → （可选）夜晚继续经营 24:00 → 次日 06:00 → 新的一天。
## 白天和夜晚的时间流速完全一致；休息 / 探索会直接跳过 24:00 → 06:00 这一段。

signal tick(progress: float, hour: float)
signal phase_changed(phase: int)
signal day_finished()
signal morning_started()

enum Phase { RUNNING, SETTLEMENT }
enum Speed { X1, X2, X4, X64 }

const DAY_START_HOUR := 6.0        # 每天早上 6 点开始
const SETTLE_PROGRESS := 0.75      # 进度 0.75 = 24:00，暂停结算
const SPEED_VALUES := { Speed.X1: 1.0, Speed.X2: 2.0, Speed.X4: 4.0, Speed.X64: 64.0 }

var cycle_length_seconds := 1440.0  # 24 小时 = 24 分钟（游戏内 1 小时 = 现实 1 分钟）
var speed: int = Speed.X1
var paused := false
var progress := 0.0                 # 0.0 = 06:00 ｜ 0.75 = 24:00 ｜ 1.0 = 次日 06:00
var phase: int = Phase.RUNNING
var settle_24_done := false         # 24 点那次结算是否已经弹过
var night_managed := false          # 今晚是否已经经营过（经营过就不再显示「夜晚继续管理」）


func _process(delta: float) -> void:
	if paused or phase == Phase.SETTLEMENT:
		return
	var step: float = delta * float(SPEED_VALUES[speed]) / maxf(cycle_length_seconds, 1.0)
	if step <= 0.0:
		return
	_advance_to(progress + step)


func _advance_to(target: float) -> void:
	# 24 点暂停结算；夜里走到早上 6 点则直接进入新的一天（不再弹第二次结算）
	if not settle_24_done and target >= SETTLE_PROGRESS:
		progress = SETTLE_PROGRESS
		settle_24_done = true
		_enter_settlement()
		return
	if target >= 1.0:
		progress = fmod(target, 1.0)
		settle_24_done = false
		night_managed = false
		morning_started.emit()
		tick.emit(progress, current_hour())
		return
	progress = target
	tick.emit(progress, current_hour())


func _enter_settlement() -> void:
	phase = Phase.SETTLEMENT
	phase_changed.emit(phase)
	day_finished.emit()


# ---------- 时间换算 ----------

func current_hour() -> float:
	# 06:00 → 30:00（30 点 = 次日 6 点），方便显示成 24:00 之后的时间
	return DAY_START_HOUR + progress * 24.0


func hour_of_day() -> float:
	return fmod(current_hour(), 24.0)


func time_text() -> String:
	var raw := current_hour()
	var hour := raw if raw <= 24.0 else fmod(raw, 24.0)
	var h := int(hour)
	var m := int((hour - float(h)) * 60.0)
	return "%02d:%02d" % [h, m]


func time_scale() -> float:
	return float(SPEED_VALUES[speed])


func is_night() -> bool:
	return current_hour() >= 24.0


func is_business() -> bool:
	return not is_night()


func night_available() -> bool:
	# 站在 24 点结算面板上、且今晚还没经营过 → 可以选「夜晚继续管理」
	return settle_24_done and not night_managed


# ---------- 控制 ----------

func set_speed(new_speed: int) -> void:
	speed = new_speed


func toggle_pause() -> void:
	paused = not paused


func skip_to_end_of_day() -> void:
	# F 键：白天跳到 24 点结算（仍然保留夜晚继续管理），夜里直接跳到早上 6 点（不弹结算）
	if phase == Phase.SETTLEMENT:
		return
	if not settle_24_done:
		progress = SETTLE_PROGRESS
		settle_24_done = true
		_enter_settlement()
	else:
		progress = 0.0
		settle_24_done = false
		night_managed = false
		morning_started.emit()
		tick.emit(progress, current_hour())


func resume_night() -> void:
	# 结算面板上选「夜晚继续管理」：从 24 点接着往下走
	if phase != Phase.SETTLEMENT or night_managed:
		return
	paused = false
	phase = Phase.RUNNING
	phase_changed.emit(phase)
	tick.emit(progress, current_hour())


func start_new_day() -> void:
	progress = 0.0
	paused = false
	phase = Phase.RUNNING
	settle_24_done = false
	night_managed = false
	phase_changed.emit(phase)
	tick.emit(progress, current_hour())


func to_dict() -> Dictionary:
	# 时间轴状态不写进存档：读档一律从当天早上 6 点开始，
	# 「一天多长」「倍速」这类设计参数也永远用当前版本的设定，
	# 避免旧存档把新调整的流速覆盖回去。
	return {}


func apply_dict(_d: Dictionary) -> void:
	speed = Speed.X1
	paused = false
	# 读档后从当天早上 6 点重新开始
	progress = 0.0
	phase = Phase.RUNNING
	settle_24_done = false
	night_managed = false
	phase_changed.emit(phase)
