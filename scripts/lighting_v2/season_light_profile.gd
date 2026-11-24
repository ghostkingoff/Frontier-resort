extends RefCounted

const CONFIG_PATH := "res://data/lighting_v2/season_environment.json"
const NUMERIC_PHASE_KEYS := [
	"sky_energy",
	"sun_energy",
	"exposure",
	"shadow_alpha",
	"shadow_softness",
	"bounce_energy",
]
const COLOR_PHASE_KEYS := [
	"sky_color",
	"sun_color",
	"bounce_color",
]

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
	var sunrise := _curve3(source.get("sunrise_hours", []), t)
	var noon := _curve3(source.get("solar_noon_hours", []), t)
	var sunset := _curve3(source.get("sunset_hours", []), t)
	var phases := _parse_phases(source.get("phases", []))
	var night_phase := _phase_by_id(phases, "night")
	var blue_phase := _phase_by_id(phases, "blue_hour")
	var sunrise_phase := _phase_by_id(phases, "sunrise")
	var noon_phase := _phase_by_id(phases, "noon")
	var sunset_phase := _phase_by_id(phases, "sunset")
	var dusk_phase := _phase_by_id(phases, "dusk")
	var representative_sunrise := _curve_mid(source.get("sunrise_hours", []), sunrise)
	var representative_sunset := _curve_mid(source.get("sunset_hours", []), sunset)
	var profile := {
		"season_id": season_id,
		"season_name": str(date["season_name"]),
		"season_day": season_day,
		"sunrise_hour": sunrise,
		"solar_noon_hour": noon,
		"sunset_hour": sunset,
		"noon_elevation_degrees": _curve3(
			source.get("noon_elevation_degrees", []), t),
		"min_elevation_degrees": float(
			source.get("min_elevation_degrees", -0.8)),
		"morning_azimuth": float(source.get("morning_azimuth", -0.98)),
		"evening_azimuth": float(source.get("evening_azimuth", 0.98)),
		"south_component": float(source.get("south_component", 0.2)),
		"cloud_coverage": float(source.get("cloud_coverage", 0.6)),
		"cloud_strength": float(source.get("cloud_strength", 0.55)),
		"bounce_color": _color(
			source, "bounce_color", "#71847A"),
		"bounce_energy": float(source.get("bounce_energy", 0.10)),
		"phases": phases,
		"phase_order": document.get("phase_order", []),
		"phase_time_offset_hours": (
			(sunrise - representative_sunrise)
			+ (sunset - representative_sunset)) * 0.5,
		"night_sky_color": _phase_color(
			night_phase, "sky_color", "#111D2E"),
		"blue_sky_color": _phase_color(
			blue_phase, "sky_color", "#2B3F56"),
		"twilight_sky_color": _phase_color(
			dusk_phase, "sky_color", "#2A3B51"),
		"day_sky_color": _phase_color(
			noon_phase, "sky_color", "#CADBD8"),
		"sunrise_color": _phase_color(
			sunrise_phase, "sun_color", "#F0A27A"),
		"sunset_color": _phase_color(
			sunset_phase, "sun_color", "#EDA17D"),
		"golden_color": _phase_color(
			sunrise_phase, "sun_color", "#FFE1B7"),
		"noon_color": _phase_color(
			noon_phase, "sun_color", "#FFF0D2"),
		"night_sun_color": _phase_color(
			night_phase, "sun_color", "#7E93AA"),
		"max_sun_energy": _max_phase_value(phases, "sun_energy", 0.68),
		"day_sky_energy": _phase_value(noon_phase, "sky_energy", 0.58),
		"twilight_sky_energy": _phase_value(
			dusk_phase, "sky_energy", 0.16),
		"night_sky_energy": _phase_value(
			night_phase, "sky_energy", 0.08),
		"day_exposure": _phase_value(noon_phase, "exposure", 0.73),
		"night_exposure": _phase_value(
			night_phase, "exposure", 0.22),
		"blue_hour_hours": maxf(
			sunrise - float(blue_phase.get("start_hour", sunrise - 1.5)),
			0.001),
		"twilight_hours": maxf(
			float(dusk_phase.get("end_hour", sunset + 1.5)) - sunset,
			0.001),
		"shadow_softness": _phase_value(
			noon_phase, "shadow_softness", 0.5),
	}
	profile["phase_windows"] = phase_windows(profile)
	return profile


func sample_light_state(at_hour: float, profile: Dictionary) -> Dictionary:
	if profile.is_empty():
		return {}
	var values := sample_phase_values(at_hour, profile)
	var sun_energy := float(values.get("sun_energy", 0.0))
	if float(values.get("sun_elevation_degrees", -90.0)) <= 0.0:
		sun_energy = 0.0
	return {
		"sky_color": values["sky_color"],
		"sky_energy": float(values["sky_energy"]),
		"sun_color": values["sun_color"],
		"sun_energy": sun_energy,
		"exposure": float(values["exposure"]),
		"shadow_alpha": float(values["shadow_alpha"]),
		"shadow_softness": float(values["shadow_softness"]),
		"bounce_color": values["bounce_color"],
		"bounce_energy": float(values["bounce_energy"]),
		"sun_elevation_degrees": float(values["sun_elevation_degrees"]),
		"phase_id": str(values["phase_id"]),
		"phase_name": str(values["phase_name"]),
		"phase_progress": float(values["phase_progress"]),
		"season_id": profile.get("season_id", ""),
		"season_name": profile.get("season_name", ""),
		"season_day": int(profile.get("season_day", 1)),
		"cloud_coverage": float(profile.get("cloud_coverage", 0.0)),
		"cloud_strength": float(profile.get("cloud_strength", 0.0)),
	}


func sample_phase_values(at_hour: float, profile: Dictionary) -> Dictionary:
	if profile.is_empty():
		return {}
	var phases: Array = phase_windows(profile)
	if phases.is_empty():
		return {}
	var shifted_hour := fposmod(at_hour, 24.0)
	var current := _phase_at_hour(phases, shifted_hour)
	var phase_start := float(current.get("start_hour", 0.0))
	var phase_end := float(current.get("end_hour", phase_start + 1.0))
	if phase_end <= phase_start:
		phase_end += 24.0
	var phase_hour := shifted_hour
	if phase_hour < phase_start:
		phase_hour += 24.0
	var phase_progress := clampf(
		(phase_hour - phase_start)
			/ maxf(phase_end - phase_start, 0.001),
		0.0,
		1.0)
	var phase_index := _phase_index_at_hour(phases, shifted_hour)
	var next_phase: Dictionary = phases[(phase_index + 1) % phases.size()]
	var duration := maxf(phase_end - phase_start, 0.001)
	var transition_hours := minf(0.75, maxf(0.08, duration * 0.35))
	var remaining_hours := maxf(phase_end - phase_hour, 0.0)
	var blend := 1.0 - smoothstep(
		0.0,
		transition_hours,
		remaining_hours)
	var values := {
		"phase_id": str(current.get("id", "")),
		"phase_name": str(current.get("name", "")),
		"phase_progress": phase_progress,
		"sun_elevation_degrees": lerpf(
			_phase_value(current, "sun_elevation_min_deg", 0.0),
			_phase_value(current, "sun_elevation_max_deg", 0.0),
			smoothstep(0.0, 1.0, phase_progress)),
	}
	for key in NUMERIC_PHASE_KEYS:
		values[key] = lerpf(
			_phase_value(current, key, _phase_value(next_phase, key, 0.0)),
			_phase_value(next_phase, key, _phase_value(current, key, 0.0)),
			blend)
	for key in COLOR_PHASE_KEYS:
		values[key] = _phase_color(
			current, key, "#FFFFFF").lerp(
				_phase_color(next_phase, key, "#FFFFFF"),
				blend)
	return values


func phase_windows(profile: Dictionary) -> Array:
	var raw: Array = profile.get("phases", [])
	if raw.is_empty():
		return []
	var sunrise := float(profile.get("sunrise_hour", 6.0))
	var noon := float(profile.get("solar_noon_hour", 12.0))
	var sunset := float(profile.get("sunset_hour", 18.0))
	var blue := _phase_by_id(raw, "blue_hour")
	var sunrise_phase := _phase_by_id(raw, "sunrise")
	var noon_phase := _phase_by_id(raw, "noon")
	var sunset_phase := _phase_by_id(raw, "sunset")
	var dusk := _phase_by_id(raw, "dusk")
	var blue_duration := _phase_duration(blue, 1.5)
	var sunrise_duration := _phase_duration(sunrise_phase, 0.6)
	var noon_duration := _phase_duration(noon_phase, 2.5)
	var sunset_duration := _phase_duration(sunset_phase, 0.6)
	var dusk_duration := _phase_duration(dusk, 1.5)
	var blue_start := sunrise - blue_duration
	var sunrise_end := sunrise + sunrise_duration
	var noon_start := noon - noon_duration * 0.5
	var noon_end := noon + noon_duration * 0.5
	var sunset_start := sunset - sunset_duration
	var dusk_end := sunset + dusk_duration
	var result: Array = []
	for phase_value in raw:
		var phase: Dictionary = (phase_value as Dictionary).duplicate(true)
		match str(phase.get("id", "")):
			"night":
				phase["start_hour"] = dusk_end
				phase["end_hour"] = blue_start + 24.0 \
					if blue_start < dusk_end else blue_start
			"blue_hour":
				phase["start_hour"] = blue_start
				phase["end_hour"] = sunrise
			"sunrise":
				phase["start_hour"] = sunrise
				phase["end_hour"] = sunrise_end
			"morning":
				phase["start_hour"] = sunrise_end
				phase["end_hour"] = noon_start
			"noon":
				phase["start_hour"] = noon_start
				phase["end_hour"] = noon_end
			"afternoon":
				phase["start_hour"] = noon_end
				phase["end_hour"] = sunset_start
			"sunset":
				phase["start_hour"] = sunset_start
				phase["end_hour"] = sunset
			"dusk":
				phase["start_hour"] = sunset
				phase["end_hour"] = dusk_end
		result.append(phase)
	return result


func sun_screen_direction(at_hour: float, profile: Dictionary) -> Vector3:
	if profile.is_empty():
		return Vector3(-1.0, 0.0, 0.2)
	var values := sample_phase_values(at_hour, profile)
	var elevation := deg_to_rad(float(values.get(
		"sun_elevation_degrees",
		float(profile.get("min_elevation_degrees", -0.8)))))
	var arc := _day_arc(
		clampf(
			at_hour,
			float(profile["sunrise_hour"]),
			float(profile["sunset_hour"])),
		float(profile["sunrise_hour"]),
		float(profile["solar_noon_hour"]),
		float(profile["sunset_hour"]))
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


func _parse_phases(raw: Array) -> Array:
	var phases: Array = []
	for source_value in raw:
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var phase: Dictionary = source.duplicate(true)
		for key in COLOR_PHASE_KEYS:
			phase[key] = _color(source, key, "#FFFFFF")
		phases.append(phase)
	return phases


func _phase_at_hour(phases: Array, hour: float) -> Dictionary:
	for phase in phases:
		var start := float(phase.get("start_hour", 0.0))
		var end := float(phase.get("end_hour", start + 1.0))
		if end <= start:
			if hour >= start or hour < end:
				return phase
		elif hour >= start and hour < end:
			return phase
	return phases[0] if not phases.is_empty() else {}


func _phase_index_at_hour(phases: Array, hour: float) -> int:
	for index in range(phases.size()):
		var phase: Dictionary = phases[index]
		var start := float(phase.get("start_hour", 0.0))
		var end := float(phase.get("end_hour", start + 1.0))
		if end <= start:
			if hour >= start or hour < end:
				return index
		elif hour >= start and hour < end:
			return index
	return 0


func _phase_duration(phase: Dictionary, fallback: float) -> float:
	if phase.is_empty():
		return fallback
	var start := float(phase.get("start_hour", 0.0))
	var end := float(phase.get("end_hour", start + fallback))
	if end <= start:
		end += 24.0
	return maxf(end - start, 0.001)


func _phase_by_id(phases: Array, phase_id: String) -> Dictionary:
	for phase in phases:
		if str(phase.get("id", "")) == phase_id:
			return phase
	return {}


func _phase_value(
		phase: Dictionary,
		key: String,
		fallback: float) -> float:
	return float(phase.get(key, fallback))


func _phase_color(
		phase: Dictionary,
		key: String,
		fallback: String) -> Color:
	var value: Variant = phase.get(key, fallback)
	if value is Color:
		return value
	return Color.from_string(str(value), Color.from_string(fallback, Color.WHITE))


func _max_phase_value(
		phases: Array,
		key: String,
		fallback: float) -> float:
	var result := fallback
	for phase in phases:
		result = maxf(result, _phase_value(phase, key, fallback))
	return result


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


func _curve_mid(values: Array, fallback: float) -> float:
	if values.is_empty():
		return fallback
	return float(values[mini(1, values.size() - 1)])


func _color(
		source: Dictionary,
		key: String,
		fallback: String) -> Color:
	return Color.from_string(
		str(source.get(key, fallback)),
		Color.from_string(fallback, Color.WHITE))
