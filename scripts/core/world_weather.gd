extends Node
## Deterministic daily weather state for the spring prototype.
## Rain is logical-only for now; it drives next-morning fog and future rain VFX.

signal changed

const CONFIG_PATH := "res://data/lighting_v2/spring_weather.json"
const FORCE_AUTO := 0
const FORCE_ON := 1
const FORCE_OFF := -1

var config: Dictionary = {}
var day := 1
var today_rain := false
var yesterday_rain := false
var fog_event := false
var rain_chance := 0.24
var post_rain_fog_chance := 0.68

var _today_rain_force := FORCE_AUTO
var _yesterday_rain_force := FORCE_AUTO
var _fog_force := FORCE_AUTO


func _ready() -> void:
	config = _read_json(CONFIG_PATH)
	rain_chance = clampf(float(config.get("rain_chance", 0.24)), 0.0, 1.0)
	post_rain_fog_chance = clampf(
		float(config.get("post_rain_fog_chance", 0.68)),
		0.0,
		1.0)
	GameState.day_changed.connect(_on_day_changed)
	GameClock.morning_started.connect(_on_morning_started)
	DevEvents.changed.connect(_on_dev_events_changed)
	refresh()


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
		"weather.post_rain_fog",
		post_rain_fog_chance)
	fog_event = yesterday_rain and fog_roll < effective_fog_chance
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


func snapshot() -> Dictionary:
	return {
		"day": day,
		"today_rain": today_rain,
		"yesterday_rain": yesterday_rain,
		"fog_event": fog_event,
		"fog_strength": fog_strength(GameClock.hour_of_day()),
		"rain_chance": rain_chance,
		"post_rain_fog_chance": post_rain_fog_chance,
		"today_rain_force": _today_rain_force,
		"yesterday_rain_force": _yesterday_rain_force,
		"fog_force": _fog_force,
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
