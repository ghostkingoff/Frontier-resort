extends Node
## Renders deterministic spring lighting states for visual review.
## Run:
##   godot --path . res://tools/lighting_lab_shot.tscn -- --lighting-lab-shot

const OUT_DIR := "res://.tmp/lighting_v2"

var lab: Node2D
var render_viewport: SubViewport
var frame := 0
var schedule_index := 0
var wait_after_change := 0
var captures: Array[String] = []
var schedule := [
	{"hour": 7.5, "name": "spring_0730.png"},
	{"hour": 12.0, "name": "spring_1200.png"},
	{"hour": 17.5, "name": "spring_1730.png"},
	{"hour": 21.5, "name": "spring_2130.png"},
	{"hour": 12.0, "debug_mode": 5, "name": "spring_1200_shadow_debug.png"},
	{"hour": 21.5, "debug_mode": 6, "name": "spring_2130_lamp_debug.png"},
]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	render_viewport = SubViewport.new()
	render_viewport.name = "FullHDRenderViewport"
	render_viewport.size = Vector2i(1920, 1080)
	render_viewport.use_hdr_2d = true
	render_viewport.transparent_bg = false
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(render_viewport)
	var packed := load("res://scenes/lighting_lab.tscn") as PackedScene
	lab = packed.instantiate() as Node2D
	render_viewport.add_child(lab)
	lab.set("auto_advance", false)


func _process(_delta: float) -> void:
	frame += 1
	if schedule_index == 0 and frame == 8:
		_set_next_hour()
		return
	if wait_after_change > 0:
		wait_after_change -= 1
		if wait_after_change == 0:
			var entry: Dictionary = schedule[schedule_index]
			_capture(str(entry["name"]))
			schedule_index += 1
			if schedule_index >= schedule.size():
				_finish()
			else:
				_set_next_hour()


func _set_next_hour() -> void:
	var entry: Dictionary = schedule[schedule_index]
	lab.call("set_hour", float(entry["hour"]))
	lab.call(
		"set_debug_mode",
		int(entry.get("debug_mode", 0)))
	wait_after_change = 24


func _capture(file_name: String) -> void:
	var image := render_viewport.get_texture().get_image()
	var path := "%s/%s" % [OUT_DIR, file_name]
	var err := image.save_png(path)
	if err == OK:
		captures.append(file_name)
	print("[lighting-lab-shot] %s -> %s" % [
		file_name,
		error_string(err),
	])


func _finish() -> void:
	var ok := captures.size() == schedule.size()
	for file_name in captures:
		var path := "%s/%s" % [OUT_DIR, file_name]
		var image := Image.load_from_file(path)
		if image == null or image.get_width() != 1920 \
				or image.get_height() != 1080:
			push_error("[lighting-lab-shot] invalid output: %s" % path)
			ok = false
	print("[lighting-lab-shot] 结果：%s（%d/%d 张 1920×1080）" % [
		"通过" if ok else "失败",
		captures.size(),
		schedule.size(),
	])
	get_tree().quit(0 if ok else 1)
