extends Node

const SEASON_LIGHT_PROFILE_SCRIPT := preload(
	"res://scripts/lighting_v2/season_light_profile.gd")


func _ready() -> void:
	var checks: Array[String] = []
	var helper = SEASON_LIGHT_PROFILE_SCRIPT.new()
	var previous_day := GameState.day
	var representative_days := {
		"spring": 15,
		"summer": 45,
		"autumn": 75,
		"winter": 105,
	}
	var profiles := {}
	var states := {}
	var night_states := {}
	for season_id in representative_days:
		GameState.day = int(representative_days[season_id])
		var profile := helper.current_profile()
		profiles[season_id] = profile
		states[season_id] = helper.sample_light_state(
			float(profile["solar_noon_hour"]),
			profile)
		night_states[season_id] = helper.sample_light_state(
			_phase_center(profile, "night"),
			profile)
		checks.append("%s：日出 %.3f ｜ 正午 %.3f ｜ 日落 %.3f ｜ 高度 %.1f° ｜ 云 %.2f" % [
			str(profile["season_name"]),
			float(profile["sunrise_hour"]),
			float(profile["solar_noon_hour"]),
			float(profile["sunset_hour"]),
			float(profile["noon_elevation_degrees"]),
			float(profile["cloud_coverage"]),
		])
	var expected_phase_ids := [
		"night",
		"blue_hour",
		"sunrise",
		"morning",
		"noon",
		"afternoon",
		"sunset",
		"dusk",
	]
	var phase_tables_ok := true
	for season_id in profiles:
		var profile: Dictionary = profiles[season_id]
		var windows: Array = profile.get("phase_windows", [])
		if windows.size() != 8:
			phase_tables_ok = false
			break
		for index in range(expected_phase_ids.size()):
			if str(windows[index].get("id", "")) != expected_phase_ids[index]:
				phase_tables_ok = false
				break
		if not phase_tables_ok:
			break
	checks.append("四季八阶段光照表：%s" % [str(phase_tables_ok)])
	var night_ambient_ok := true
	var night_ambient_summary: Array[String] = []
	for season_id in night_states:
		var night_state: Dictionary = night_states[season_id]
		var night_sky := float(night_state["sky_energy"])
		var night_bounce := float(night_state["bounce_energy"])
		night_ambient_ok = night_ambient_ok \
			and night_sky <= 0.003 \
			and night_bounce <= 0.003 \
			and is_zero_approx(float(night_state["sun_energy"]))
		night_ambient_summary.append(
			"%s %.3f/%.3f" % [
				str(profiles[season_id]["season_name"]),
				night_sky,
				night_bounce,
			])
	checks.append("四季夜间环境天光与反弹光接近 0：%s（%s）" % [
		str(night_ambient_ok),
		" / ".join(night_ambient_summary),
	])
	var expected_document_values := {
		"spring": {
			"sky_color": "#A9E6D7", "sky_energy": 0.64,
			"sun_color": "#FFF1C4", "sun_energy": 0.76,
			"exposure": 0.80, "shadow_alpha": 0.52,
			"shadow_softness": 0.28,
			"bounce_color": "#57C49A", "bounce_energy": 0.16,
			"night_sky": "#08142D", "night_exposure": 0.12,
		},
		"summer": {
			"sky_color": "#95E8E7", "sky_energy": 0.72,
			"sun_color": "#FFFBDE", "sun_energy": 0.98,
			"exposure": 0.84, "shadow_alpha": 0.58,
			"shadow_softness": 0.24,
			"bounce_color": "#1D9B67", "bounce_energy": 0.15,
			"night_sky": "#07142E", "night_exposure": 0.13,
		},
		"autumn": {
			"sky_color": "#EAC57F", "sky_energy": 0.55,
			"sun_color": "#FFE198", "sun_energy": 0.68,
			"exposure": 0.72, "shadow_alpha": 0.44,
			"shadow_softness": 0.38,
			"bounce_color": "#C56F2D", "bounce_energy": 0.12,
			"night_sky": "#130E27", "night_exposure": 0.11,
		},
		"winter": {
			"sky_color": "#B9DFEE", "sky_energy": 0.60,
			"sun_color": "#FFF0CC", "sun_energy": 0.40,
			"exposure": 0.69, "shadow_alpha": 0.24,
			"shadow_softness": 0.55,
			"bounce_color": "#BCE2F2", "bounce_energy": 0.32,
			"night_sky": "#0B122A", "night_exposure": 0.10,
		},
	}
	var document_values_ok := true
	for season_id in expected_document_values:
		var expected: Dictionary = expected_document_values[season_id]
		var noon_state: Dictionary = states[season_id]
		var night_state: Dictionary = night_states[season_id]
		if not (noon_state["sky_color"] as Color).is_equal_approx(
				Color.from_string(str(expected["sky_color"]), Color.BLACK)) \
				or not is_equal_approx(
					float(noon_state["sky_energy"]),
					float(expected["sky_energy"])) \
				or not (noon_state["sun_color"] as Color).is_equal_approx(
					Color.from_string(str(expected["sun_color"]), Color.BLACK)) \
				or not is_equal_approx(
					float(noon_state["sun_energy"]),
					float(expected["sun_energy"])) \
				or not is_equal_approx(
					float(noon_state["exposure"]),
					float(expected["exposure"])) \
				or not is_equal_approx(
					float(noon_state["shadow_alpha"]),
					float(expected["shadow_alpha"])) \
				or not is_equal_approx(
					float(noon_state["shadow_softness"]),
					float(expected["shadow_softness"])) \
				or not (noon_state["bounce_color"] as Color).is_equal_approx(
					Color.from_string(
						str(expected["bounce_color"]),
						Color.BLACK)) \
				or not is_equal_approx(
					float(noon_state["bounce_energy"]),
					float(expected["bounce_energy"])):
			document_values_ok = false
			break
		if not (night_state["sky_color"] as Color).is_equal_approx(
				Color.from_string(str(expected["night_sky"]), Color.BLACK)) \
				or not is_equal_approx(
					float(night_state["exposure"]),
					float(expected["night_exposure"])) \
				or not (night_state["sun_color"] as Color).is_equal_approx(
					Color.BLACK) \
				or not is_zero_approx(float(night_state["sun_energy"])) \
				or not is_zero_approx(float(night_state["shadow_alpha"])) \
				or not is_equal_approx(
					float(night_state["shadow_softness"]),
					1.0) \
				or not is_equal_approx(
					float(night_state["bounce_energy"]),
					0.002):
			document_values_ok = false
			break
	checks.append("四季高饱和光照基准与夜间无方向光符合文档：%s" % [
		str(document_values_ok)])

	var summer_profile: Dictionary = profiles["summer"]
	var autumn_profile: Dictionary = profiles["autumn"]
	var winter_profile: Dictionary = profiles["winter"]
	var summer_noon: Dictionary = states["summer"]
	var autumn_noon: Dictionary = states["autumn"]
	var winter_noon: Dictionary = states["winter"]
	var summer_length := float(summer_profile["sunset_hour"]) \
		- float(summer_profile["sunrise_hour"])
	var autumn_length := float(autumn_profile["sunset_hour"]) \
		- float(autumn_profile["sunrise_hour"])
	var winter_length := float(winter_profile["sunset_hour"]) \
		- float(winter_profile["sunrise_hour"])
	checks.append("夏季白昼最长且正午最高：%s（%.2f / %.2f / %.2f 小时）" % [
		str(summer_length > autumn_length and autumn_length > winter_length
			and float(summer_profile["noon_elevation_degrees"])
				> float(autumn_profile["noon_elevation_degrees"])
			and float(autumn_profile["noon_elevation_degrees"])
				> float(winter_profile["noon_elevation_degrees"])),
		summer_length,
		autumn_length,
		winter_length,
	])
	checks.append("夏季直射最强、冬季最弱：%s（%.3f / %.3f / %.3f）" % [
		str(float(summer_noon["sun_energy"])
			> float(autumn_noon["sun_energy"])
			and float(autumn_noon["sun_energy"])
				> float(winter_noon["sun_energy"])),
		float(summer_noon["sun_energy"]),
		float(autumn_noon["sun_energy"]),
		float(winter_noon["sun_energy"]),
	])
	checks.append("秋季散射最明显、阴影最柔：%s（云 %.2f ｜ 柔度 %.2f）" % [
		str(float(autumn_profile["cloud_coverage"])
			> float(summer_profile["cloud_coverage"])
			and float(autumn_profile["shadow_softness"])
				> float(summer_profile["shadow_softness"])),
		float(autumn_profile["cloud_coverage"]),
		float(autumn_profile["shadow_softness"]),
	])
	for season_id in representative_days:
		var profile: Dictionary = profiles[season_id]
		var noon := float(profile["solar_noon_hour"])
		var direction := helper.sun_screen_direction(noon, profile)
		checks.append("%s 正午太阳在南方：%s（方向 %s）" % [
			str(profile["season_name"]),
			str(direction.y > 0.0 and direction.z > 0.2),
			str(direction),
		])

	GameState.day = 1
	var spring_start := helper.current_profile()
	GameState.day = 30
	var spring_end := helper.current_profile()
	GameState.day = 120
	var winter_end := helper.current_profile()
	GameState.day = previous_day
	checks.append("春季太阳逐日升高并提前：%s（%.2f→%.2f，%.1f°→%.1f°）" % [
		str(float(spring_end["sunrise_hour"])
				< float(spring_start["sunrise_hour"])
			and float(spring_end["noon_elevation_degrees"])
				> float(spring_start["noon_elevation_degrees"])),
		float(spring_start["sunrise_hour"]),
		float(spring_end["sunrise_hour"]),
		float(spring_start["noon_elevation_degrees"]),
		float(spring_end["noon_elevation_degrees"]),
	])
	checks.append("冬末日照回升：%s（%.2f 小时，%.1f°）" % [
		str(float(winter_end["sunrise_hour"])
				< float(winter_profile["sunrise_hour"])
			and float(winter_end["noon_elevation_degrees"])
				> float(winter_profile["noon_elevation_degrees"])),
		float(winter_end["sunset_hour"])
			- float(winter_end["sunrise_hour"]),
		float(winter_end["noon_elevation_degrees"]),
	])

	var failed := 0
	for line in checks:
		var ok := not line.contains("：false") and not line.ends_with("：false")
		print("[season-lighting-check] %s" % line)
		if not ok:
			failed += 1
	print("[season-lighting-check] 结果：%s（失败 %d）" % [
		"通过" if failed == 0 else "失败",
		failed,
	])
	get_tree().quit(0 if failed == 0 else 1)


func _phase_center(profile: Dictionary, phase_id: String) -> float:
	for phase in profile.get("phase_windows", []):
		if str(phase.get("id", "")) != phase_id:
			continue
		var start := float(phase.get("start_hour", 0.0))
		var end := float(phase.get("end_hour", start + 1.0))
		if end <= start:
			end += 24.0
		return fposmod(start + (end - start) * 0.5, 24.0)
	return 1.0
