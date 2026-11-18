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
	for season_id in representative_days:
		GameState.day = int(representative_days[season_id])
		var profile := helper.current_profile()
		profiles[season_id] = profile
		states[season_id] = helper.sample_light_state(
			float(profile["solar_noon_hour"]),
			profile)
		checks.append("%s：日出 %.3f ｜ 正午 %.3f ｜ 日落 %.3f ｜ 高度 %.1f° ｜ 云 %.2f" % [
			str(profile["season_name"]),
			float(profile["sunrise_hour"]),
			float(profile["solar_noon_hour"]),
			float(profile["sunset_hour"]),
			float(profile["noon_elevation_degrees"]),
			float(profile["cloud_coverage"]),
		])

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
