extends RefCounted

const CONFIG_PATH := "res://data/lighting_v2/season_environment.json"

var document: Dictionary = {}


func _init(loaded_document: Dictionary = {}) -> void:
	document = loaded_document
	if document.is_empty():
		var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(CONFIG_PATH))
		if parsed is Dictionary:
			document = parsed


func current_profile() -> Dictionary:
	var date := SeasonCalendar.current_date()
	var season_id := str(date["season_id"])
	var seasons: Dictionary = document.get("seasons", {})
	var source: Dictionary = seasons.get(season_id, {})
	if source.is_empty():
		return {}
	var season_day := int(date["day_in_season"])
	var season_days := maxi(int(date["days_in_season"]), 2)
	var t := clampf(
		float(season_day - 1) / float(season_days - 1),
		0.0,
		1.0)
	var night: Dictionary = document.get("night", {})
	var profile := {
		"season_id": season_id,
		"season_name": str(date["season_name"]),
		"season_day": season_day,
		"sunrise_hour": _curve3(source.get("sunrise_hours", []), t),
		"solar_noon_hour": _curve3(
			source.get("solar_noon_hours", []), t),
		"sunset_hour": _curve3(source.get("sunset_hours", []), t),
		"noon_elevation_degrees": _curve3(
			source.get("noon_elevation_degrees", []), t),
		"min_elevation_degrees": float(
			source.get("min_elevation_degrees", 1.0)),
		"morning_azimuth": float(source.get("morning_azimuth", -0.8)),
		"evening_azimuth": float(source.get("evening_azimuth", 0.8)),
		"south_component": float(source.get("south_component", 0.3)),
		"night_sky_color": _color_value(
			source, night, "night_sky_color", "sky_color", "#142137"),
		"blue_sky_color": _color(
			source, "blue_sky_color", "#7b91a0"),
		"twilight_sky_color": _color(
			source, "twilight_sky_color", "#887b8c"),
		"day_sky_color": _color(
			source, "day_sky_color", "#c9ded5"),
		"sunrise_color": _color(
			source, "sunrise_color", "#dca380"),
		"sunset_color": _color(
			source, "sunset_color", "#d29a82"),
		"golden_color": _color(
			source, "golden_color", "#ffd7a6"),
		"noon_color": _color(source, "noon_color", "#fff0cc"),
		"night_sun_color": _color_value(
			night, {}, "sun_color", "", "#7f95c5"),
		"max_sun_energy": float(source.get("max_sun_energy", 0.82)),
		"day_sky_energy": float(source.get("day_sky_energy", 0.46)),
		"twilight_sky_energy": float(
			source.get("twilight_sky_energy", 0.20)),
		"night_sky_energy": float(night.get("sky_energy", 0.04)),
		"day_exposure": float(source.get("day_exposure", 0.78)),
		"night_exposure": float(source.get(
			"night_exposure",
			night.get("exposure", 0.20))),
		"blue_hour_hours": float(night.get("blue_hour_hours", 0.47)),
		"twilight_hours": float(night.get("twilight_hours", 0.47)),
		"cloud_coverage": float(source.get("cloud_coverage", 0.4)),
		"cloud_shadow_strength": float(
			source.get("cloud_shadow_strength", 0.7)),
		"shadow_softness": float(source.get("shadow_softness", 0.5)),
	}
	profile["cloud_shadow_threshold"] = lerpf(
		0.68,
		0.38,
		clampf(float(profile["cloud_coverage"]), 0.0, 1.0))
	profile["cloud_shadow_softness"] = lerpf(
		0.18,
		0.30,
		clampf(float(profile["shadow_softness"]), 0.0, 1.0))
	return profile


func sample_light_state(at_hour: float, profile: Dictionary) -> Dictionary:
	if profile.is_empty():
		return {}
	var hour := fmod(at_hour + 24.0, 24.0)
	var sunrise := float(profile["sunrise_hour"])
	var sunset := float(profile["sunset_hour"])
	var noon := float(profile["solar_noon_hour"])
	var blue_start := sunrise - float(profile["blue_hour_hours"])
	var twilight_end := sunset + float(profile["twilight_hours"])
	var night_sky: Color = profile["night_sky_color"]
	var blue_sky: Color = profile["blue_sky_color"]
	var twilight_sky: Color = profile["twilight_sky_color"]
	var day_sky: Color = profile["day_sky_color"]
	var sunrise_color: Color = profile["sunrise_color"]
	var sunset_color: Color = profile["sunset_color"]
	var golden_color: Color = profile["golden_color"]
	var noon_color: Color = profile["noon_color"]

	if hour < blue_start or hour > twilight_end:
		return _state(
			profile,
			night_sky,
			float(profile["night_sky_energy"]),
			profile["night_sun_color"],
			0.0,
			float(profile["night_exposure"]))
	if hour < sunrise:
		var blue_t := smoothstep(blue_start, sunrise, hour)
		return _state(
			profile,
			night_sky.lerp(twilight_sky, blue_t),
			lerpf(
				float(profile["night_sky_energy"]),
				float(profile["twilight_sky_energy"]),
				blue_t),
			sunrise_color,
			0.0,
			lerpf(
				float(profile["night_exposure"]),
				lerpf(float(profile["night_exposure"]),
					float(profile["day_exposure"]), 0.35),
				blue_t))
	if hour > sunset:
		var twilight_t := 1.0 - smoothstep(sunset, twilight_end, hour)
		return _state(
			profile,
			night_sky.lerp(twilight_sky, twilight_t),
			lerpf(
				float(profile["night_sky_energy"]),
				float(profile["twilight_sky_energy"]),
				twilight_t),
			sunset_color,
			0.0,
			lerpf(
				float(profile["night_exposure"]),
				lerpf(float(profile["night_exposure"]),
					float(profile["day_exposure"]), 0.35),
				twilight_t))

	var arc := _day_arc(hour, sunrise, noon, sunset)
	var height := sin(arc * PI)
	var energy_curve := clampf(pow(height, 0.62), 0.10, 1.0)
	var cloud_factor := lerpf(
		1.0,
		0.70,
		clampf(float(profile["cloud_coverage"]), 0.0, 1.0))
	var sun_energy := float(profile["max_sun_energy"]) \
		* cloud_factor * energy_curve
	var horizon_color := sunrise_color if arc <= 0.5 else sunset_color
	var warm := clampf(pow(1.0 - height, 1.15), 0.0, 1.0)
	var sun_color := noon_color.lerp(golden_color, warm)
	if warm > 0.68:
		sun_color = sun_color.lerp(
			horizon_color,
			(warm - 0.68) / 0.32)
	var ambient_t := smoothstep(0.0, 0.62, height)
	var sky_color := blue_sky.lerp(day_sky, ambient_t)
	var sky_energy := lerpf(
		float(profile["twilight_sky_energy"]),
		float(profile["day_sky_energy"]),
		ambient_t)
	var exposure := lerpf(
		float(profile["night_exposure"]),
		float(profile["day_exposure"]),
		smoothstep(
			0.02,
			maxf(float(profile["max_sun_energy"]), 0.02),
			sun_energy))
	return _state(
		profile,
		sky_color,
		sky_energy,
		sun_color,
		sun_energy,
		exposure)


func sun_screen_direction(at_hour: float, profile: Dictionary) -> Vector3:
	if profile.is_empty():
		return Vector3(-1.0, 0.0, 0.2)
	var hour := fmod(at_hour + 24.0, 24.0)
	var sunrise := float(profile["sunrise_hour"])
	var sunset := float(profile["sunset_hour"])
	var noon := float(profile["solar_noon_hour"])
	var arc := _day_arc(
		clampf(hour, sunrise, sunset),
		sunrise,
		noon,
		sunset)
	var height := sin(arc * PI)
	var elevation_degrees := lerpf(
		float(profile["min_elevation_degrees"]),
		float(profile["noon_elevation_degrees"]),
		height)
	var elevation := deg_to_rad(elevation_degrees)
	var azimuth_x := lerpf(
		float(profile["morning_azimuth"]),
		float(profile["evening_azimuth"]),
		arc)
	var horizontal := Vector2(
		azimuth_x,
		float(profile["south_component"])).normalized()
	var horizontal_length := cos(elevation)
	return Vector3(
		horizontal.x * horizontal_length,
		horizontal.y * horizontal_length,
		sin(elevation)).normalized()


func sunrise_transition(
		at_hour: float,
		profile: Dictionary,
		duration_hours: float = 0.5) -> float:
	if profile.is_empty():
		return 0.0
	var sunrise := float(profile["sunrise_hour"])
	return smoothstep(
		sunrise,
		sunrise + maxf(duration_hours, 0.001),
		at_hour)


func _state(
		profile: Dictionary,
		sky_color: Color,
		sky_energy: float,
		sun_color: Color,
		sun_energy: float,
		exposure: float) -> Dictionary:
	var state := {
		"sky_color": sky_color,
		"sky_energy": sky_energy,
		"sun_color": sun_color,
		"sun_energy": sun_energy,
		"exposure": exposure,
	}
	for key in [
		"season_id",
		"season_name",
		"season_day",
		"cloud_coverage",
		"cloud_shadow_strength",
		"cloud_shadow_threshold",
		"cloud_shadow_softness",
		"shadow_softness",
	]:
		state[key] = profile.get(key)
	return state


func _day_arc(
		hour: float,
		sunrise: float,
		noon: float,
		sunset: float) -> float:
	if hour <= noon:
		return 0.5 * clampf(
			(hour - sunrise) / maxf(noon - sunrise, 0.001),
			0.0,
			1.0)
	return 0.5 + 0.5 * clampf(
		(hour - noon) / maxf(sunset - noon, 0.001),
		0.0,
		1.0)


func _curve3(values: Array, t: float) -> float:
	if values.is_empty():
		return 0.0
	if values.size() == 1:
		return float(values[0])
	if values.size() == 2:
		return lerpf(float(values[0]), float(values[1]), t)
	if t <= 0.5:
		return lerpf(float(values[0]), float(values[1]), t * 2.0)
	return lerpf(float(values[1]), float(values[2]), (t - 0.5) * 2.0)


func _color(
		source: Dictionary,
		key: String,
		fallback: String) -> Color:
	return Color.from_string(
		str(source.get(key, fallback)),
		Color.from_string(fallback, Color.WHITE))


func _color_value(
		source: Dictionary,
		secondary: Dictionary,
		key: String,
		secondary_key: String,
		fallback: String) -> Color:
	var value: Variant = source.get(key, null)
	if value == null and secondary_key != "":
		value = secondary.get(secondary_key, fallback)
	if value == null:
		value = fallback
	return Color.from_string(str(value), Color.WHITE)
