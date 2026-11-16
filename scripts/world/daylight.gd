extends CanvasModulate
const HIGH_QUALITY_LIGHT_MASK := 8
const LIGHTING_CONFIG := "res://data/lighting_next.json"

var sun: DirectionalLight2D
var shadow_sun: DirectionalLight2D
var sun_config: Dictionary = {}
## 随时间变化的世界光照：早上偏暖、白天中性、傍晚转橙、收工转蓝变暗。
## CanvasModulate 只影响同一画布里的场景（地面、建筑、顾客），
## 界面在独立的 CanvasLayer 上，亮度始终不变。

func _ready() -> void:
	sun_config = _read_lighting_config()
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
		var sampled := _sample(frames, hour)
		var multiplier := float(DataRegistry.lighting_ambient_multiplier)
		color = Color(
			sampled.r * multiplier,
			sampled.g * multiplier,
			sampled.b * multiplier,
			sampled.a)
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
	# 动态阴影统一由 SunShadow3D 的 3D 代理产生；此灯只补充地面光照。
	shadow_sun.shadow_enabled = false
	add_child(shadow_sun)


func _apply_sun(hour: float) -> void:
	if sun == null:
		return
	var sunrise := 7.0
	var full_day := 10.0
	var fade_start := 16.0
	var night := 19.0
	var daylight_t := clampf(
		(hour - sunrise) / (night - sunrise), 0.0, 1.0)
	if hour < sunrise or hour >= night:
		sun.energy = 0.0
		if shadow_sun != null:
			shadow_sun.energy = 0.0
		return
	var rise_energy := smoothstep(sunrise, full_day, hour)
	var set_energy := 1.0 - smoothstep(fade_start, night, hour)
	var day_energy := minf(rise_energy, set_energy)
	var dawn_color := Color.from_string(
		str(sun_config.get("legacy_dawn_color", "#ff9e47")),
		Color(1.0, 0.62, 0.28))
	var day_color := Color.from_string(
		str(sun_config.get("legacy_day_color", "#f3e0c2")),
		Color(1.0, 0.89, 0.76))
	sun.color = dawn_color.lerp(day_color, day_energy)
	sun.energy = float(sun_config.get("legacy_maximum_energy", 0.30)) \
		* day_energy
	sun.rotation = lerpf(deg_to_rad(-62.0), deg_to_rad(62.0), daylight_t)
	if shadow_sun != null:
		shadow_sun.color = sun.color
		shadow_sun.energy = sun.energy * 0.85
		shadow_sun.rotation = sun.rotation


func _read_lighting_config() -> Dictionary:
	if not FileAccess.file_exists(LIGHTING_CONFIG):
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(LIGHTING_CONFIG))
	if parsed is not Dictionary:
		return {}
	return parsed.get("sun", {})


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
			frac = frac * frac * (3.0 - 2.0 * frac)
			return (a["color"] as Color).lerp(b["color"] as Color, frac)
	# 超过最后一帧就朝次日 0 点过渡
	var last: Dictionary = frames[frames.size() - 1]
	var first: Dictionary = frames[0]
	var span := (24.0 - float(last["hour"])) + float(first["hour"])
	var wrap_frac := 0.0 if span <= 0.0 else (hour - float(last["hour"])) / span
	wrap_frac = wrap_frac * wrap_frac * (3.0 - 2.0 * wrap_frac)
	return (last["color"] as Color).lerp(first["color"] as Color, clampf(wrap_frac, 0.0, 1.0))
