extends CanvasModulate
## 随时间变化的世界光照：早上偏暖、白天中性、傍晚转橙、收工转蓝变暗。
## CanvasModulate 只影响同一画布里的场景（地面、建筑、顾客），
## 界面在独立的 CanvasLayer 上，亮度始终不变。

func _ready() -> void:
	GameClock.tick.connect(_on_tick)
	GameClock.phase_changed.connect(_on_phase_changed)
	_apply(GameClock.progress)


func _on_tick(progress: float, _hour: float) -> void:
	_apply(progress)


func _on_phase_changed(_phase: int) -> void:
	_apply(GameClock.progress)


func _apply(_progress: float) -> void:
	var frames: Array = DataRegistry.lighting_keyframes
	if frames.is_empty():
		color = Color.WHITE
		return
	color = _sample(frames, GameClock.hour_of_day())


func _sample(frames: Array, hour: float) -> Color:
	# 按一天中的小时采样，0 点与 24 点首尾相接
	if hour <= float(frames[0]["hour"]):
		return frames[0]["color"]
	for i in range(frames.size() - 1):
		var a: Dictionary = frames[i]
		var b: Dictionary = frames[i + 1]
		var pa := float(a["hour"])
		var pb := float(b["hour"])
		if hour <= pb:
			var t := 0.0 if pb <= pa else (hour - pa) / (pb - pa)
			return (a["color"] as Color).lerp(b["color"] as Color, t)
	# 超过最后一帧就朝次日 0 点过渡
	var last: Dictionary = frames[frames.size() - 1]
	var first: Dictionary = frames[0]
	var span := (24.0 - float(last["hour"])) + float(first["hour"])
	var t := 0.0 if span <= 0.0 else (hour - float(last["hour"])) / span
	return (last["color"] as Color).lerp(first["color"] as Color, clampf(t, 0.0, 1.0))
