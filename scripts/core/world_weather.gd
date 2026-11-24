extends Node
## Deterministic daily weather state for the spring prototype.
## Rain drives all-day visual VFX on the main map.

signal changed

const CONFIG_PATH := "res://data/lighting_v2/spring_weather.json"
const EVENT_CONFIG_PATH := "res://data/lighting_v2/weather_events.json"
const FORCE_AUTO := 0
const FORCE_ON := 1
const FORCE_OFF := -1

var config: Dictionary = {}
var event_catalog: Dictionary = {}
var day := 1
var today_rain := false
var yesterday_rain := false
var fog_event := false
var rain_chance := 0.24
var fog_chance := 0.18
var active_weather_events: Dictionary = {}

var _today_rain_force := FORCE_AUTO
var _yesterday_rain_force := FORCE_AUTO
var _fog_force := FORCE_AUTO


func _ready() -> void:
	config = _read_json(CONFIG_PATH)
	event_catalog = _read_json(EVENT_CONFIG_PATH)
	rain_chance = clampf(float(config.get("rain_chance", 0.24)), 0.0, 1.0)
	fog_chance = clampf(
		float(config.get("fog_chance", 0.18)),
		0.0,
		1.0)
	GameState.day_changed.connect(_on_day_changed)
	GameClock.morning_started.connect(_on_morning_started)
	DevEvents.changed.connect(_on_dev_events_changed)
	refresh()


func _process(delta: float) -> void:
	if active_weather_events.is_empty():
		return
	if GameClock.paused or GameClock.phase != GameClock.Phase.RUNNING:
		return
	var cycle_seconds := maxf(GameClock.cycle_length_seconds, 0.001)
	var game_hours := delta * GameClock.time_scale() * 24.0 / cycle_seconds
	if game_hours <= 0.0:
		return
	var expired: Array[String] = []
	for type_id in active_weather_events.keys():
		var event: Dictionary = active_weather_events[type_id]
		event["remaining_hours"] = maxf(
			float(event.get("remaining_hours", 0.0)) - game_hours,
			0.0)
		if float(event["remaining_hours"]) <= 0.0:
			expired.append(str(type_id))
	for type_id in expired:
		active_weather_events.erase(type_id)
	if not expired.is_empty():
		changed.emit()


func _on_day_changed(_new_day: int) -> void:
	refresh()


func _on_morning_started() -> void:
	refresh()


func _on_dev_events_changed() -> void:
	refresh()


func refresh() -> void:
	day = GameState.day
	var rain_roll := _daily_roll("rain", day)
	var effective_rain_chance := DevEvents.chance(
		"weather.rain",
		rain_chance)
	today_rain = _resolve_forced(
		_today_rain_force,
		rain_roll < effective_rain_chance)

	yesterday_rain = _rain_for_day(day - 1)
	if _yesterday_rain_force != FORCE_AUTO:
		yesterday_rain = _yesterday_rain_force == FORCE_ON

	var fog_roll := _daily_roll("fog", day)
	var effective_fog_chance := DevEvents.chance(
		"weather.fog",
		fog_chance)
	fog_event = fog_roll < effective_fog_chance
	fog_event = _resolve_forced(_fog_force, fog_event)
	changed.emit()


func fog_strength(at_hour: float) -> float:
	if not fog_event:
		return 0.0
	var start := float(config.get("fog_start_hour", 6.0))
	var full := float(config.get("fog_full_hour", 6.5))
	var fade_start := float(config.get("fog_fade_start_hour", 8.5))
	var end := float(config.get("fog_end_hour", 9.0))
	var hour := fmod(at_hour, 24.0)
	if hour < start or hour >= end:
		return 0.0
	if hour < full:
		return smoothstep(start, maxf(full, start + 0.001), hour)
	if hour <= fade_start:
		return 1.0
	return 1.0 - smoothstep(
		fade_start,
		maxf(end, fade_start + 0.001),
		hour)


func set_today_rain_force(mode: int) -> void:
	_today_rain_force = _normalize_force(mode)
	refresh()


func set_yesterday_rain_force(mode: int) -> void:
	_yesterday_rain_force = _normalize_force(mode)
	refresh()


func set_fog_force(mode: int) -> void:
	_fog_force = _normalize_force(mode)
	refresh()


func get_today_rain_force() -> int:
	return _today_rain_force


func get_yesterday_rain_force() -> int:
	return _yesterday_rain_force


func get_fog_force() -> int:
	return _fog_force


func clear_force_overrides() -> void:
	_today_rain_force = FORCE_AUTO
	_yesterday_rain_force = FORCE_AUTO
	_fog_force = FORCE_AUTO
	refresh()


func weather_types() -> Array[String]:
	var types: Dictionary = event_catalog.get("types", {})
	var result: Array[String] = []
	for type_id in types.keys():
		result.append(str(type_id))
	result.sort()
	return result


func weather_sizes() -> Array[String]:
	var sizes: Dictionary = event_catalog.get("sizes", {})
	var result: Array[String] = []
	for size_id in sizes.keys():
		result.append(str(size_id))
	result.sort()
	return result


func weather_event_spec(type_id: String, size_id: String) -> Dictionary:
	var type_data: Dictionary = event_catalog.get(
		"types", {}).get(type_id, {})
	if type_data.is_empty():
		return {}
	var size_data: Variant = type_data.get(size_id, null)
	if not size_data is Dictionary:
		return {}
	var size_meta: Dictionary = event_catalog.get(
		"sizes", {}).get(size_id, {})
	var spec: Dictionary = (size_data as Dictionary).duplicate(true)
	spec["id"] = "%s.%s" % [type_id, size_id]
	spec["type"] = type_id
	spec["type_name"] = str(type_data.get("name", type_id))
	spec["size"] = size_id
	spec["size_name"] = str(size_meta.get("name", size_id))
	spec["rank"] = int(size_meta.get("rank", 0))
	return spec


func all_weather_event_specs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for type_id in weather_types():
		for size_id in ["small", "medium", "large"]:
			var spec := weather_event_spec(type_id, size_id)
			if not spec.is_empty():
				result.append(spec)
	return result


func season_event_weights(
		season_id: String = "",
		type_id: String = "") -> Variant:
	if season_id == "":
		season_id = str(SeasonCalendar.current_date().get("season_id", "spring"))
	var weights: Dictionary = event_catalog.get(
		"season_event_weights", {}).get(season_id, {})
	if type_id == "":
		return weights.duplicate(true)
	return weights.get(type_id, []).duplicate()


func trigger_weather_event(
		type_id: String,
		size_id: String,
		duration_hours: float = -1.0) -> Dictionary:
	var spec := weather_event_spec(type_id, size_id)
	if spec.is_empty():
		push_warning("[WorldWeather] Unknown weather event: %s.%s" % [
			type_id,
			size_id,
		])
		return {}
	var duration := duration_hours
	if duration < 0.0:
		var range: Array = spec.get("duration_hours", [1.0, 1.0])
		if range.size() >= 2:
			duration = (float(range[0]) + float(range[1])) * 0.5
		else:
			duration = 1.0
	var event := {
		"id": spec["id"],
		"type": type_id,
		"size": size_id,
		"duration_hours": maxf(duration, 0.001),
		"remaining_hours": maxf(duration, 0.001),
		"started_day": GameState.day,
		"started_hour": GameClock.hour_of_day(),
		"spec": spec,
	}
	active_weather_events[type_id] = event
	changed.emit()
	return event.duplicate(true)


func clear_weather_event(type_id: String) -> bool:
	if not active_weather_events.erase(type_id):
		return false
	changed.emit()
	return true


func clear_weather_events() -> void:
	if active_weather_events.is_empty():
		return
	active_weather_events.clear()
	changed.emit()


func get_active_weather_event(type_id: String) -> Dictionary:
	return (active_weather_events.get(type_id, {}) as Dictionary).duplicate(true)


func get_active_weather_events() -> Dictionary:
	return active_weather_events.duplicate(true)


func get_weather_event_effects() -> Dictionary:
	var effects := {
		"sky_energy_factor": 1.0,
		"sun_energy_factor": 1.0,
		"exposure_factor": 1.0,
		"shadow_alpha_factor": 1.0,
		"cloud_coverage": 0.0,
		"fog_density": 0.0,
		"intensity": 0.0,
	}
	for event_value in active_weather_events.values():
		var event: Dictionary = event_value
		var spec: Dictionary = event.get("spec", {})
		for key in [
			"sky_energy_factor",
			"sun_energy_factor",
			"exposure_factor",
			"shadow_alpha_factor",
		]:
			if spec.has(key):
				effects[key] = float(effects[key]) * float(spec[key])
		for key in ["cloud_coverage", "fog_density", "intensity"]:
			if spec.has(key):
				effects[key] = maxf(float(effects[key]), float(spec[key]))
	for key in effects:
		effects[key] = float(effects[key])
	return effects


func snapshot() -> Dictionary:
	var calendar := SeasonCalendar.date_info(day)
	return {
		"day": day,
		"year": int(calendar["year"]),
		"season_id": str(calendar["season_id"]),
		"season_name": str(calendar["season_name"]),
		"day_in_season": int(calendar["day_in_season"]),
		"day_in_year": int(calendar["day_in_year"]),
		"today_rain": today_rain,
		"yesterday_rain": yesterday_rain,
		"fog_event": fog_event,
		"fog_strength": fog_strength(GameClock.hour_of_day()),
		"rain_chance": rain_chance,
		"fog_chance": fog_chance,
		"today_rain_force": _today_rain_force,
		"yesterday_rain_force": _yesterday_rain_force,
		"fog_force": _fog_force,
		"active_weather_events": get_active_weather_events(),
		"weather_event_effects": get_weather_event_effects(),
	}


func _rain_for_day(target_day: int) -> bool:
	if target_day < 1:
		return false
	var effective := DevEvents.chance("weather.rain", rain_chance)
	return _daily_roll("rain", target_day) < effective


func _daily_roll(kind: String, target_day: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = _stable_seed(kind, target_day)
	return rng.randf()


func _stable_seed(kind: String, target_day: int) -> int:
	var key := "spring:%s:%d" % [kind, target_day]
	var value := 2166136261
	for index in range(key.length()):
		value = value ^ key.unicode_at(index)
		value = int((value * 16777619) & 0x7fffffff)
	return value


func _resolve_forced(mode: int, automatic: bool) -> bool:
	if mode == FORCE_ON:
		return true
	if mode == FORCE_OFF:
		return false
	return automatic


func _normalize_force(mode: int) -> int:
	if mode > 0:
		return FORCE_ON
	if mode < 0:
		return FORCE_OFF
	return FORCE_AUTO


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[WorldWeather] Missing config: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
