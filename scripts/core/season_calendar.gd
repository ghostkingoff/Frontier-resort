extends Node
## Four-season calendar derived from GameState.day. No extra save state is stored.

signal season_changed(info: Dictionary)
signal year_changed(info: Dictionary)

const CONFIG_PATH := "res://data/seasons.json"

var days_per_season := 30
var seasons: Array[Dictionary] = []
var _last_season_key := ""
var _last_year := 0


func _ready() -> void:
	_load_config()
	GameState.day_changed.connect(_on_day_changed)
	var initial := date_info(GameState.day)
	_last_season_key = _season_key(initial)
	_last_year = int(initial["year"])


func date_info(day: int = -1) -> Dictionary:
	var absolute_day := maxi(day if day >= 0 else GameState.day, 1)
	var days_per_year := maxi(days_per_season * seasons.size(), 1)
	var day_index := (absolute_day - 1) % days_per_year
	var year_index := floori(
		float(absolute_day - 1) / float(days_per_year))
	var season_index := floori(
		float(day_index) / float(maxi(days_per_season, 1)))
	var season: Dictionary = seasons[season_index] if season_index < seasons.size() \
		else {"id": "unknown", "name": "未知"}
	var day_in_year := day_index + 1
	var day_in_season := day_index % maxi(days_per_season, 1) + 1
	return {
		"absolute_day": absolute_day,
		"year": year_index + 1,
		"day_in_year": day_in_year,
		"season_index": season_index,
		"season_id": str(season.get("id", "unknown")),
		"season_name": str(season.get("name", "未知")),
		"day_in_season": day_in_season,
		"days_in_season": days_per_season,
	}


func current_date() -> Dictionary:
	return date_info(GameState.day)


func current_year() -> int:
	return int(current_date()["year"])


func current_season_id() -> String:
	return str(current_date()["season_id"])


func current_season_name() -> String:
	return str(current_date()["season_name"])


func current_day_in_season() -> int:
	return int(current_date()["day_in_season"])


func current_day_in_year() -> int:
	return int(current_date()["day_in_year"])


func format_date(day: int = -1) -> String:
	var info := date_info(day)
	return "第 %d 年 · %s · 第 %d 天" % [
		int(info["year"]),
		str(info["season_name"]),
		int(info["day_in_season"]),
	]


func season_remaining_days(day: int = -1) -> int:
	var info := date_info(day)
	return int(info["days_in_season"]) - int(info["day_in_season"]) + 1


func _on_day_changed(day: int) -> void:
	var info := date_info(day)
	var season_key := _season_key(info)
	if season_key != _last_season_key:
		_last_season_key = season_key
		season_changed.emit(info)
	var year_value := int(info["year"])
	if year_value != _last_year:
		_last_year = year_value
		year_changed.emit(info)


func _season_key(info: Dictionary) -> String:
	return "%d:%s" % [int(info["year"]), str(info["season_id"])]


func _load_config() -> void:
	seasons.clear()
	days_per_season = 30
	if not FileAccess.file_exists(CONFIG_PATH):
		push_warning("[SeasonCalendar] Missing config: %s" % CONFIG_PATH)
		_use_fallback_seasons()
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(CONFIG_PATH))
	if parsed is not Dictionary:
		push_error("[SeasonCalendar] Invalid config: %s" % CONFIG_PATH)
		_use_fallback_seasons()
		return
	days_per_season = maxi(int(parsed.get("days_per_season", 30)), 1)
	var configured: Array = parsed.get("seasons", [])
	for entry in configured:
		if entry is not Dictionary:
			continue
		var id := str(entry.get("id", "")).strip_edges()
		var name := str(entry.get("name", "")).strip_edges()
		if id == "" or name == "":
			continue
		seasons.append({"id": id, "name": name})
	if seasons.size() != 4:
		push_error("[SeasonCalendar] Expected 4 seasons, got %d" % seasons.size())
		_use_fallback_seasons()


func _use_fallback_seasons() -> void:
	seasons = [
		{"id": "spring", "name": "春季"},
		{"id": "summer", "name": "夏季"},
		{"id": "autumn", "name": "秋季"},
		{"id": "winter", "name": "冬季"},
	]
