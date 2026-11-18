extends Node


func _ready() -> void:
	var checks: Array[String] = []
	var cases := [
		{"day": 1, "text": "第 1 年 · 春季 · 第 1 天"},
		{"day": 30, "text": "第 1 年 · 春季 · 第 30 天"},
		{"day": 31, "text": "第 1 年 · 夏季 · 第 1 天"},
		{"day": 40, "text": "第 1 年 · 夏季 · 第 10 天"},
		{"day": 60, "text": "第 1 年 · 夏季 · 第 30 天"},
		{"day": 61, "text": "第 1 年 · 秋季 · 第 1 天"},
		{"day": 90, "text": "第 1 年 · 秋季 · 第 30 天"},
		{"day": 91, "text": "第 1 年 · 冬季 · 第 1 天"},
		{"day": 120, "text": "第 1 年 · 冬季 · 第 30 天"},
		{"day": 121, "text": "第 2 年 · 春季 · 第 1 天"},
		{"day": 160, "text": "第 2 年 · 夏季 · 第 10 天"},
		{"day": 241, "text": "第 3 年 · 春季 · 第 1 天"},
	]
	for entry in cases:
		var day := int(entry["day"])
		var expected := str(entry["text"])
		var actual := SeasonCalendar.format_date(day)
		checks.append("%d 日 -> %s：%s" % [
			day,
			actual,
			str(actual == expected),
		])
	checks.append("每季 30 天且一年 4 季：%s" % [
		str(SeasonCalendar.days_per_season == 30
			and SeasonCalendar.seasons.size() == 4),
	])
	checks.append("夏季剩余天数：%s" % [
		str(SeasonCalendar.season_remaining_days(40) == 21),
	])

	var previous_day := GameState.day
	var observed: Array[String] = []
	var season_listener := func(info: Dictionary) -> void:
		observed.append("season:%s" % str(info["season_id"]))
	var year_listener := func(info: Dictionary) -> void:
		observed.append("year:%d" % int(info["year"]))
	SeasonCalendar.season_changed.connect(season_listener)
	SeasonCalendar.year_changed.connect(year_listener)
	GameState.day = 30
	GameState.day_changed.emit(30)
	GameState.day = 31
	GameState.day_changed.emit(31)
	GameState.day = 121
	GameState.day_changed.emit(121)
	SeasonCalendar.season_changed.disconnect(season_listener)
	SeasonCalendar.year_changed.disconnect(year_listener)
	GameState.day = previous_day
	GameState.day_changed.emit(previous_day)
	checks.append("换季与跨年信号：%s（%s）" % [
		str(observed.has("season:summer")
			and observed.has("season:spring")
			and observed.has("year:2")),
		" / ".join(observed),
	])

	var failed := 0
	for line in checks:
		var ok := line.ends_with("：true") \
			or line.ends_with("（true）") \
			or "：true（" in line
		print("[season-calendar-check] %s" % line)
		if not ok:
			failed += 1
	print("[season-calendar-check] 结果：%s（失败 %d）" % [
		"通过" if failed == 0 else "失败",
		failed,
	])
	get_tree().quit(0 if failed == 0 else 1)
