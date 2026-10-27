extends CanvasModulate
const HIGH_QUALITY_LIGHT_MASK := 8

var sun: DirectionalLight2D
var shadow_sun: DirectionalLight2D
## 随时间变化的世界光照：早上偏暖、白天中性、傍晚转橙、收工转蓝变暗。
## CanvasModulate 只影响同一画布里的场景（地面、建筑、顾客），
## 界面在独立的 CanvasLayer 上，亮度始终不变。

func _ready() -> void:
	GameClock.tick.connect(_on_tick)
	GameClock.phase_changed.connect(_on_phase_changed)
	if str(ProjectSettings.get_setting("lighting/quality", "high")) == "high":
		_build_sun()
	_apply(GameClock.progress)


func _on_tick(progress: float, _hour: float) -> void:
	_apply(progress)


func _on_phase_changed(_phase: int) -> void:
	_apply(GameClock.progress)


func _apply(_progress: float) -> void:
	var frames: Array = DataRegistry.lighting_keyframes
	var hour := GameClock.hour_of_day()
	if frames.is_empty():
		color = Color.WHITE
	else:
		color = _sample(frames, hour)
	_apply_sun(hour)


func _build_sun() -> void:
	sun = DirectionalLight2D.new()
	sun.name = "HighQualitySunMoon"
	sun.blend_mode = Light2D.BLEND_MODE_ADD
	sun.range_item_cull_mask = HIGH_QUALITY_LIGHT_MASK
	sun.height = 18.0
	sun.max_distance = 6000.0
	add_child(sun)

	shadow_sun = DirectionalLight2D.new()
	shadow_sun.name = "HighQualitySunMoonShadow"
	shadow_sun.blend_mode = Light2D.BLEND_MODE_ADD
	shadow_sun.range_item_cull_mask = 1
	shadow_sun.height = 18.0
	shadow_sun.max_distance = 6000.0
	shadow_sun.shadow_enabled = true
	shadow_sun.shadow_color = Color(0.0, 0.0, 0.0, 0.62)
	shadow_sun.shadow_filter = Light2D.SHADOW_FILTER_PCF5
	shadow_sun.shadow_filter_smooth = 1.2
	shadow_sun.shadow_item_cull_mask = HIGH_QUALITY_LIGHT_MASK
	add_child(shadow_sun)


func _apply_sun(hour: float) -> void:
	if sun == null:
		return
	var daylight_t := clampf((hour - 5.5) / 14.0, 0.0, 1.0)
	var day_arc := sin(daylight_t * PI)
	if hour >= 5.5 and hour <= 19.5:
		var warmth := 1.0 - smoothstep(0.2, 0.48, daylight_t)
		sun.color = Color.WHITE.lerp(Color(1.0, 0.62, 0.28), warmth)
		sun.energy = lerpf(0.16, 0.38, day_arc)
	else:
		sun.color = Color(0.52, 0.63, 0.92)
		sun.energy = 0.13
	sun.rotation = lerpf(deg_to_rad(-62.0), deg_to_rad(62.0), daylight_t)
	if shadow_sun != null:
		shadow_sun.color = sun.color
		shadow_sun.energy = sun.energy * 0.85
		shadow_sun.rotation = sun.rotation


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
			var frac := 0.0 if pb <= pa else (hour - pa) / (pb - pa)
			return (a["color"] as Color).lerp(b["color"] as Color, frac)
	# 超过最后一帧就朝次日 0 点过渡
	var last: Dictionary = frames[frames.size() - 1]
	var first: Dictionary = frames[0]
	var span := (24.0 - float(last["hour"])) + float(first["hour"])
	var wrap_frac := 0.0 if span <= 0.0 else (hour - float(last["hour"])) / span
	return (last["color"] as Color).lerp(first["color"] as Color, clampf(wrap_frac, 0.0, 1.0))
