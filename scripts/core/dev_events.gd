extends Node
## Shared development controls for high-level probability events.
## Gameplay code reads the same definitions that the F10 panel edits.

signal changed

const CHANCE_DEFINITIONS := [
	{
		"id": "weather.rain",
		"group": "天气",
		"label": "每日自动雨事件",
		"default": 0.24,
		"hint": "当天是否安排一次随机时段降雨事件。",
	},
	{
		"id": "weather.fog",
		"group": "天气",
		"label": "每日自动雾事件",
		"default": 0.18,
		"hint": "雾不再固定清晨出现，可在全天任意时段触发。",
	},
	{
		"id": "weather.cloud",
		"group": "天气",
		"label": "每日自动云事件",
		"default": 0.24,
		"hint": "云与雨、雾独立安排，可在任意时段开始。",
	},
	{
		"id": "visitor.star_arrival",
		"group": "游客与经营",
		"label": "明星 / 富商到访",
		"default": 0.0,
		"hint": "自动模式使用知名度曲线与每日上限；接管后直接使用此处概率。",
	},
	{
		"id": "visitor.lodge_priority",
		"group": "游客与经营",
		"label": "有空房时优先住宿客",
		"default": 0.85,
		"hint": "仍会检查房间容量与可达性。",
	},
	{
		"id": "visitor.split_party",
		"group": "游客与经营",
		"label": "同行客人分头行动",
		"default": 0.20,
		"hint": "关闭后同行小组会一直一起行动。",
	},
	{
		"id": "visitor.daytime_lodge_rest",
		"group": "游客与经营",
		"label": "住客白天回房休息",
		"default": 0.20,
		"hint": "仅对已经入住且有度假屋的游客生效。",
	},
	{
		"id": "visitor.spend_decision",
		"group": "游客与经营",
		"label": "游客本次选择消费",
		"default": 0.60,
		"hint": "自动模式使用游客类型自己的消费倾向。",
	},
	{
		"id": "gameplay.illness",
		"group": "游客与经营",
		"label": "游客生病",
		"default": 0.007,
		"hint": "自动模式仍会叠加拥挤带来的额外概率。",
	},
	{
		"id": "economy.showroom_sale",
		"group": "游客与经营",
		"label": "展厅单件商品成交",
		"default": 0.10,
		"hint": "自动模式由陈列评分与当日客流共同决定。",
	},
	{
		"id": "exploration.event_new",
		"group": "探索",
		"label": "新格触发探索事件",
		"default": 0.55,
	},
	{
		"id": "exploration.event_revisit",
		"group": "探索",
		"label": "旧格触发探索事件",
		"default": 0.12,
	},
	{
		"id": "exploration.terrain_continuity",
		"group": "探索",
		"label": "相邻方块延续原地形",
		"default": 0.55,
		"hint": "影响探索世界生成，不改变已经生成的地图。",
	},
	{
		"id": "exploration.grey_stone",
		"group": "探索",
		"label": "新格发现灰石",
		"default": 0.50,
	},
	{
		"id": "exploration.merchant",
		"group": "探索",
		"label": "过渡区出现商人",
		"default": 0.40,
	},
]

const MULTIPLIER_DEFINITIONS := [
	{
		"id": "exploration.reward_multiplier",
		"group": "整体倍率",
		"label": "探索奖励概率",
		"default": 1.0,
		"min": 0.0,
		"max": 2.0,
	},
	{
		"id": "exploration.risk_multiplier",
		"group": "整体倍率",
		"label": "探索风险概率",
		"default": 1.0,
		"min": 0.0,
		"max": 2.0,
	},
]

var _chance_overrides: Dictionary = {}
var _multipliers: Dictionary = {}
var _last_base: Dictionary = {}
var _last_effective: Dictionary = {}


func chance(event_id: String, base_chance: float) -> float:
	var safe_base := clampf(base_chance, 0.0, 1.0)
	_last_base[event_id] = safe_base
	var effective := safe_base
	if _chance_overrides.has(event_id):
		effective = clampf(float(_chance_overrides[event_id]), 0.0, 1.0)
	_last_effective[event_id] = effective
	return effective


func roll(event_id: String, base_chance: float) -> bool:
	return randf() < chance(event_id, base_chance)


func rng_roll(
	rng: RandomNumberGenerator,
	event_id: String,
	base_chance: float) -> bool:
	return rng.randf() < chance(event_id, base_chance)


func scale(event_id: String, base_value: float) -> float:
	return base_value * float(_multipliers.get(event_id, 1.0))


func set_chance_override(event_id: String, value: float) -> void:
	_chance_overrides[event_id] = clampf(value, 0.0, 1.0)
	changed.emit()


func clear_chance_override(event_id: String) -> void:
	if _chance_overrides.erase(event_id):
		changed.emit()


func is_chance_overridden(event_id: String) -> bool:
	return _chance_overrides.has(event_id)


func get_chance_override(event_id: String) -> float:
	return float(_chance_overrides.get(event_id, -1.0))


func get_last_base(event_id: String) -> float:
	return float(_last_base.get(event_id, -1.0))


func get_last_effective(event_id: String) -> float:
	return float(_last_effective.get(event_id, -1.0))


func set_multiplier(event_id: String, value: float) -> void:
	_multipliers[event_id] = maxf(value, 0.0)
	changed.emit()


func get_multiplier(event_id: String) -> float:
	return float(_multipliers.get(event_id, 1.0))


func reset_all() -> void:
	_chance_overrides.clear()
	_multipliers.clear()
	changed.emit()


func definitions() -> Array:
	var out: Array = []
	out.append_array(CHANCE_DEFINITIONS)
	out.append_array(MULTIPLIER_DEFINITIONS)
	return out


func chance_definitions() -> Array:
	return CHANCE_DEFINITIONS


func multiplier_definitions() -> Array:
	return MULTIPLIER_DEFINITIONS


func snapshot() -> Dictionary:
	return {
		"day": GameState.day,
		"hour": GameClock.hour_of_day(),
		"chance_overrides": _chance_overrides.duplicate(true),
		"multipliers": _multipliers.duplicate(true),
		"last_base": _last_base.duplicate(true),
		"last_effective": _last_effective.duplicate(true),
		"weather": WorldWeather.snapshot(),
	}
