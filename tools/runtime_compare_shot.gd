extends Node
## Captures the real root window so the editor/game viewport can be compared
## against the isolated SubViewport regression shots.

const OUT_DIR := "res://.tmp/runtime_compare"
const WAIT_FRAMES := 12
const SUNRISE_HOUR := 6.0 + 25.0 / 60.0
const SUNSET_HOUR := 19.0 + 25.0 / 60.0

var main: Node
var camera: Camera2D
var spring: Node
var frame := 0
var schedule_index := 0
var wait_left := 0
var schedule := [
	{
		"name": "runtime_0625_sunrise.png",
		"hour": SUNRISE_HOUR,
		"fog": false,
		"atmosphere": true,
	},
	{
		"name": "runtime_1000_morning.png",
		"hour": 10.0,
		"fog": false,
		"atmosphere": true,
	},
	{
		"name": "runtime_1200_noon.png",
		"hour": 12.0,
		"fog": false,
		"atmosphere": true,
	},
	{
		"name": "runtime_1830_evening.png",
		"hour": 18.5,
		"fog": false,
		"atmosphere": true,
	},
	{
		"name": "runtime_1925_sunset.png",
		"hour": SUNSET_HOUR,
		"fog": false,
		"atmosphere": true,
	},
	{
		"name": "runtime_0100_night.png",
		"hour": 1.0,
		"fog": false,
		"atmosphere": true,
	},
	{
		"name": "runtime_0820_fog.png",
		"hour": 8.0 + 20.0 / 60.0,
		"fog": true,
		"atmosphere": true,
	},
]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	SaveManager.read_only = true
	GameState.reset()
	PlayerStats.reset()
	Exploration.reset()
	GameClock.start_new_day()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)


func _process(_delta: float) -> void:
	frame += 1
	if frame == 6:
		_prepare()
		_apply_schedule()
		return
	if wait_left > 0:
		wait_left -= 1
		if wait_left == 0:
			_capture(str(schedule[schedule_index]["name"]))
			schedule_index += 1
			if schedule_index >= schedule.size():
				print("[runtime-compare] 结果：通过")
				get_tree().quit()
			else:
				_apply_schedule()


func _prepare() -> void:
	var world := main.get_node("World")
	camera = main.get_node("Camera")
	camera.set_process(false)
	camera.zoom = Vector2(2.35, 2.35)
	var lodge: Building = null
	for building in world.buildings:
		if building.id == "lodge_ordinary":
			lodge = building
			break
	camera.position = lodge.global_position + Vector2(96.0, 58.0) \
		if lodge != null else world.cell_center(Vector2i(58, 39))
	spring = main.get_node("SpringWorldLighting")


func _apply_schedule() -> void:
	var entry: Dictionary = schedule[schedule_index]
	WorldWeather.set_fog_force(1 if bool(entry["fog"]) else -1)
	var hour := float(entry["hour"])
	var target := hour if hour >= GameClock.DAY_START_HOUR else hour + 24.0
	GameClock.progress = clampf(
		(target - GameClock.DAY_START_HOUR) / 24.0,
		0.0,
		1.0)
	GameClock.phase = GameClock.Phase.RUNNING
	GameClock.paused = true
	GameClock.tick.emit(GameClock.progress, GameClock.current_hour())
	var grade := spring.get_node_or_null(
		"SpringAtmosphere/SpringGrade") as ColorRect
	if grade != null:
		grade.visible = bool(entry["atmosphere"])
	wait_left = WAIT_FRAMES


func _capture(file_name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s" % [OUT_DIR, file_name]
	var error := image.save_png(path)
	print("[runtime-compare] %s %dx%d -> %s" % [
		file_name,
		image.get_width(),
		image.get_height(),
		error_string(error),
	])
