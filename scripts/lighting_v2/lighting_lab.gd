extends Node2D
## Spring/flat-ground vertical slice for the rebuilt 2.5D lighting pipeline.
## The visible world remains 2D; a hidden 3D rig produces light visibility maps.

const GROUND_SHADER := preload("res://shaders/lighting_v2/spring_ground.gdshader")
const SURFACE_SHADER := preload("res://shaders/lighting_v2/spring_surface.gdshader")
const ATMOSPHERE_SHADER := preload(
	"res://shaders/lighting_v2/spring_atmosphere.gdshader")
const RIG_SCRIPT := preload("res://scripts/lighting_v2/lighting_rig_3d.gd")
const CONFIG_PATH := "res://data/lighting_v2/spring_clear.json"

const CELL := 32
const MAP_CELLS := Vector2i(40, 24)
const MAP_SIZE := Vector2i(MAP_CELLS.x * CELL, MAP_CELLS.y * CELL)
const ATLAS_MARGIN := 2
const ATLAS_STEP := 35
const ATLAS_COLUMNS := 3

const GRASS_DIR := "res://art/characters/ground/grass_spring/"
const STONE_DIR := "res://art/characters/ground/stone_path/"
const PINE_DIR := "res://art/characters/trees/pine/"
const LODGE_DIR := "res://art/characters/buildings/lodge_ordinary/"
const LAMP_DIR := "res://art/characters/buildings/street_lamp/"
const PLAYER_DIR := "res://art/characters/player/star2a/"

const LODGE_CELL := Vector2i(15, 6)
const LAMP_CELL := Vector2i(23, 10)
const PLAYER_FOOT := Vector2(696.0, 405.0)
const PINE_FEET := [
	Vector2(342.0, 268.0),
	Vector2(268.0, 392.0),
	Vector2(930.0, 284.0),
	Vector2(1012.0, 432.0),
]

@export var initial_hour := 10.0
@export var auto_advance := false
@export var hours_per_second := 0.03

var config: Dictionary = {}
var hour := 10.0
var paused := false
var camera: Camera2D
var rig: LightingRig3D
var ground_material: ShaderMaterial
var surface_materials: Array[ShaderMaterial] = []
var lamp_glow: Sprite2D
var lamp_foot := Vector2.ZERO
var lamp_head := Vector2.ZERO
var post_material: ShaderMaterial
var hud_time: Label
var hud_state: Label
var debug_mode := 0


func _ready() -> void:
	name = "SpringLightingLab"
	get_viewport().use_hdr_2d = true
	config = _read_json(CONFIG_PATH)
	hour = clampf(initial_hour, 0.0, 23.999)

	_create_camera()
	_create_shadow_rig()
	_create_ground()
	_create_outdoor_objects()
	_create_atmosphere()
	_create_hud()
	_apply_lighting()
	set_process(true)


func _process(delta: float) -> void:
	if auto_advance and not paused:
		var previous := hour
		hour = fmod(hour + delta * hours_per_second, 24.0)
		if int(previous) != int(hour):
			_apply_lighting()
		else:
			_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:
				_change_hour(-0.25)
			KEY_RIGHT:
				_change_hour(0.25)
			KEY_1:
				_set_hour_preset(7.5)
			KEY_2:
				_set_hour_preset(12.0)
			KEY_3:
				_set_hour_preset(17.5)
			KEY_4:
				_set_hour_preset(21.5)
			KEY_SPACE:
				paused = not paused
				_update_hud()
			KEY_F1:
				debug_mode = (debug_mode + 1) % 11
				_apply_debug_mode()
				_update_hud()


func set_hour(value: float) -> void:
	hour = clampf(value, 0.0, 23.999)
	_apply_lighting()


func set_debug_mode(value: int) -> void:
	debug_mode = clampi(value, 0, 10)
	_apply_debug_mode()
	_update_hud()


func _change_hour(delta: float) -> void:
	hour = fmod(hour + delta + 24.0, 24.0)
	_apply_lighting()


func _set_hour_preset(value: float) -> void:
	hour = value
	_apply_lighting()


func _create_camera() -> void:
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.position = Vector2(640.0, 376.0)
	camera.zoom = Vector2(2.0, 2.0)
	camera.enabled = true
	add_child(camera)


func _create_shadow_rig() -> void:
	rig = RIG_SCRIPT.new()
	rig.name = "LightingRig3D"
	add_child(rig)
	rig.setup(Vector2i(1920, 1080))
	rig.set_camera(camera)

	var f: Array = [6, 4]
	var lodge_center := Vector2(
		LODGE_CELL.x * CELL + float(f[0]) * CELL * 0.5,
		LODGE_CELL.y * CELL + float(f[1]) * CELL * 0.5)
	rig.add_building_proxy(
		LODGE_DIR + "shadow_proxy.glb",
		lodge_center,
		1.0)

	var lamp_center := Vector2(
		LAMP_CELL.x * CELL + CELL * 0.5,
		LAMP_CELL.y * CELL + CELL * 0.5)
	rig.add_building_proxy(
		LAMP_DIR + "shadow_proxy.glb",
		lamp_center,
		0.54,
		false)

	for foot in PINE_FEET:
		rig.add_pine_proxy(foot, 124.0)
	rig.add_capsule_proxy(PLAYER_FOOT, 9.0, 62.0)


func _create_ground() -> void:
	var maps := _build_ground_maps()
	ground_material = ShaderMaterial.new()
	ground_material.shader = GROUND_SHADER
	ground_material.set_shader_parameter(
		"normal_texture",
		ImageTexture.create_from_image(maps["normal"]))
	ground_material.set_shader_parameter(
		"specular_texture",
		ImageTexture.create_from_image(maps["specular"]))
	ground_material.set_shader_parameter(
		"occlusion_texture",
		ImageTexture.create_from_image(maps["occlusion"]))
	ground_material.set_shader_parameter(
		"sun_shadow_texture", rig.get_sun_texture())
	ground_material.set_shader_parameter(
		"lamp_shadow_texture_0", rig.get_lamp_texture(0))
	ground_material.set_shader_parameter(
		"lamp_shadow_texture_1", rig.get_lamp_texture(1))
	ground_material.set_shader_parameter(
		"lamp_shadow_texture_2", rig.get_lamp_texture(2))
	ground_material.set_shader_parameter(
		"lamp_shadow_texture_3", rig.get_lamp_texture(3))
	ground_material.set_shader_parameter("normal_strength", 1.05)
	ground_material.set_shader_parameter("specular_strength", 0.28)
	ground_material.set_shader_parameter("occlusion_strength", 0.82)

	var ground := Sprite2D.new()
	ground.name = "SpringGround"
	ground.texture = ImageTexture.create_from_image(maps["color"])
	ground.centered = false
	ground.position = Vector2.ZERO
	ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ground.material = ground_material
	ground.z_index = -100
	add_child(ground)


func _build_ground_maps() -> Dictionary:
	var channels := [
		_load_image(GRASS_DIR + "color.png"),
		_load_image(GRASS_DIR + "normal.png"),
		_load_image(GRASS_DIR + "specular.png"),
		_load_image(GRASS_DIR + "occlusion.png"),
	]
	var stone_channels := [
		_load_image(STONE_DIR + "color.png"),
		_load_image(STONE_DIR + "normal.png"),
		_load_image(STONE_DIR + "specular.png"),
		_load_image(STONE_DIR + "occlusion.png"),
	]
	var outputs: Array[Image] = []
	for _index in range(channels.size()):
		var image := Image.create(
			MAP_SIZE.x,
			MAP_SIZE.y,
			false,
			Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		outputs.append(image)

	for y in range(MAP_CELLS.y):
		for x in range(MAP_CELLS.x):
			var is_path := _is_path_cell(Vector2i(x, y))
			# The official 3x3 sheet contains deliberately different lighting
			# studies, not seamless variants. Repeating one tile avoids visible
			# checkerboard blocks; the shader adds gentle world-space variation.
			var variation := 6 if is_path else 4
			var source_px := Vector2i(
				ATLAS_MARGIN
					+ (variation % ATLAS_COLUMNS) * ATLAS_STEP,
				ATLAS_MARGIN
					+ int(variation / ATLAS_COLUMNS) * ATLAS_STEP)
			var source_rect := Rect2i(source_px, Vector2i(CELL, CELL))
			var destination := Vector2i(x * CELL, y * CELL)
			for channel_index in range(channels.size()):
				var source_images: Array = \
					stone_channels if is_path else channels
				var tile := (source_images[channel_index] as Image).get_region(
					source_rect)
				# Alternating mirrors make the AI-authored tile edge values meet
				# themselves, removing the visible 32px checker seams.
				if not is_path and x % 2 == 1:
					tile.flip_x()
				if not is_path and y % 2 == 1:
					tile.flip_y()
				outputs[channel_index].blit_rect(
					tile,
					Rect2i(Vector2i.ZERO, Vector2i(CELL, CELL)),
					destination)

	return {
		"color": outputs[0],
		"normal": outputs[1],
		"specular": outputs[2],
		"occlusion": outputs[3],
	}


func _load_image(path: String) -> Image:
	var texture := load(path) as Texture2D
	if texture == null:
		push_error("[LightingLab] Missing texture: %s" % path)
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var image := texture.get_image()
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	return image


func _is_path_cell(cell: Vector2i) -> bool:
	if cell.x >= 19 and cell.x <= 20 and cell.y >= 8 and cell.y <= 21:
		return true
	if cell.y >= 15 and cell.y <= 16 and cell.x >= 9 and cell.x <= 31:
		return true
	return false


func _create_outdoor_objects() -> void:
	var outdoor := Node2D.new()
	outdoor.name = "Outdoor"
	outdoor.y_sort_enabled = true
	add_child(outdoor)

	_create_lodge(outdoor)
	for foot in PINE_FEET:
		_create_pine(outdoor, foot)
	_create_lamp(outdoor)
	_create_player(outdoor)


func _create_lodge(parent: Node2D) -> void:
	var origin := Vector2(32.0, 95.0)
	var root := Node2D.new()
	root.name = "Lodge"
	root.position = Vector2(LODGE_CELL.x * CELL, LODGE_CELL.y * CELL)
	parent.add_child(root)

	var wall := Sprite2D.new()
	wall.name = "Wall"
	wall.texture = load(LODGE_DIR + "layers/wall.png")
	wall.centered = false
	wall.position = -origin
	wall.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	wall.material = _make_surface_material(
		LODGE_DIR + "lighting/wall_n.png",
		LODGE_DIR + "lighting/wall_s.png",
		LODGE_DIR + "lighting/wall_o.png",
		true,
		217.0 / 256.0,
		256.0,
		0.88,
		0.30,
		0.72)
	root.add_child(wall)

	var roof := Sprite2D.new()
	roof.name = "Roof"
	roof.texture = load(LODGE_DIR + "layers/roof.png")
	roof.centered = false
	roof.position = -origin
	roof.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	roof.material = _make_surface_material(
		LODGE_DIR + "lighting/roof_n.png",
		LODGE_DIR + "lighting/roof_s.png",
		LODGE_DIR + "lighting/roof_o.png",
		false,
		1.0,
		256.0,
		0.90,
		0.38,
		0.68)
	root.add_child(roof)


func _create_pine(parent: Node2D, foot: Vector2) -> void:
	var root := Node2D.new()
	root.name = "Pine"
	root.position = foot
	parent.add_child(root)

	var sprite := Sprite2D.new()
	sprite.name = "PineSurface"
	sprite.texture = load(PINE_DIR + "color.png")
	sprite.centered = false
	sprite.position = Vector2(-32.0, -128.0)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.material = _make_surface_material(
		PINE_DIR + "normal.png",
		PINE_DIR + "specular.png",
		PINE_DIR + "occlusion.png",
		false,
		1.0,
		128.0,
		0.86,
		0.20,
		0.78)
	root.add_child(sprite)


func _create_lamp(parent: Node2D) -> void:
	var origin := Vector2(16.0, 32.0)
	var root := Node2D.new()
	root.name = "StreetLamp"
	root.position = Vector2(LAMP_CELL.x * CELL, LAMP_CELL.y * CELL)
	parent.add_child(root)
	lamp_foot = root.position + Vector2(16.0, 16.0)
	lamp_head = root.position + Vector2(15.0, -26.0)

	var wall := Sprite2D.new()
	wall.name = "Wall"
	wall.texture = load(LAMP_DIR + "layers/wall.png")
	wall.centered = false
	wall.position = -origin
	wall.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	wall.material = _make_surface_material(
		LAMP_DIR + "lighting/wall_n.png",
		LAMP_DIR + "lighting/wall_s.png",
		LAMP_DIR + "lighting/wall_o.png",
		false,
		50.0 / 64.0,
		64.0,
		0.78,
		0.62,
		0.72)
	root.add_child(wall)

	var roof := Sprite2D.new()
	roof.name = "Roof"
	roof.texture = load(LAMP_DIR + "layers/roof.png")
	roof.centered = false
	roof.position = -origin
	roof.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	roof.material = _make_surface_material(
		LAMP_DIR + "lighting/roof_n.png",
		LAMP_DIR + "lighting/roof_s.png",
		LAMP_DIR + "lighting/roof_o.png",
		false,
		1.0,
		64.0,
		0.78,
		0.80,
		0.60)
	root.add_child(roof)

	lamp_glow = Sprite2D.new()
	lamp_glow.name = "LampGlow"
	lamp_glow.texture = _make_radial_texture(128)
	lamp_glow.position = lamp_head - root.position
	lamp_glow.scale = Vector2(1.05, 1.05)
	lamp_glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	lamp_glow.modulate = Color(1.0, 0.75, 0.35, 0.0)
	lamp_glow.material = CanvasItemMaterial.new()
	(lamp_glow.material as CanvasItemMaterial).blend_mode = \
		CanvasItemMaterial.BLEND_MODE_ADD
	root.add_child(lamp_glow)


func _create_player(parent: Node2D) -> void:
	var player := Sprite2D.new()
	player.name = "Player"
	player.texture = load(PLAYER_DIR + "idle.png")
	player.hframes = 4
	player.vframes = 2
	player.frame = 0
	player.position = PLAYER_FOOT
	player.offset = Vector2(0.0, -6.0)
	player.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	player.material = _make_surface_material(
		PLAYER_DIR + "idle_n.png",
		PLAYER_DIR + "idle_s.png",
		PLAYER_DIR + "idle_o.png",
		false,
		1.0,
		144.0,
		0.90,
		0.42,
		0.72)
	(player.material as ShaderMaterial).set_shader_parameter(
		"atlas_frame_uv",
		Vector4(0.0, 0.0, 0.25, 0.5))
	parent.add_child(player)


func _make_surface_material(
		normal_path: String,
		specular_path: String,
		occlusion_path: String,
		receive_projected_shadow_arg: bool,
		foot_uv_y: float,
		canvas_height: float,
		normal_strength_arg: float,
		specular_strength_arg: float,
		occlusion_strength_arg: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter("normal_texture", load(normal_path))
	material.set_shader_parameter("specular_texture", load(specular_path))
	material.set_shader_parameter("occlusion_texture", load(occlusion_path))
	material.set_shader_parameter(
		"sun_shadow_texture", rig.get_sun_texture())
	material.set_shader_parameter(
		"lamp_shadow_texture_0", rig.get_lamp_texture(0))
	material.set_shader_parameter(
		"lamp_shadow_texture_1", rig.get_lamp_texture(1))
	material.set_shader_parameter(
		"lamp_shadow_texture_2", rig.get_lamp_texture(2))
	material.set_shader_parameter(
		"lamp_shadow_texture_3", rig.get_lamp_texture(3))
	material.set_shader_parameter(
		"receive_projected_shadow",
		receive_projected_shadow_arg)
	material.set_shader_parameter("surface_foot_uv_y", foot_uv_y)
	material.set_shader_parameter("canvas_height_px", canvas_height)
	material.set_shader_parameter("normal_strength", normal_strength_arg)
	material.set_shader_parameter("specular_strength", specular_strength_arg)
	material.set_shader_parameter("occlusion_strength", occlusion_strength_arg)
	surface_materials.append(material)
	return material


func _create_atmosphere() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Atmosphere"
	layer.layer = 10
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_material = ShaderMaterial.new()
	post_material.shader = ATMOSPHERE_SHADER
	rect.material = post_material
	layer.add_child(rect)


func _create_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Hud"
	layer.layer = 20
	add_child(layer)

	var panel := ColorRect.new()
	panel.color = Color(0.035, 0.045, 0.052, 0.82)
	panel.position = Vector2(28.0, 26.0)
	panel.size = Vector2(440.0, 102.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)

	var title := Label.new()
	title.text = "春·晴天  平面地形光照样板"
	title.position = Vector2(46.0, 36.0)
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.95, 0.98, 0.91))
	layer.add_child(title)

	hud_time = Label.new()
	hud_time.position = Vector2(46.0, 73.0)
	hud_time.add_theme_font_size_override("font_size", 21)
	hud_time.add_theme_color_override("font_color", Color(1.0, 0.84, 0.48))
	layer.add_child(hud_time)

	hud_state = Label.new()
	hud_state.position = Vector2(46.0, 101.0)
	hud_state.add_theme_font_size_override("font_size", 16)
	hud_state.add_theme_color_override("font_color", Color(0.76, 0.83, 0.78))
	layer.add_child(hud_state)

	var help := Label.new()
	help.text = "←/→ 调时间  1 清晨  2 正午  3 傍晚  4 夜晚  Space 暂停  F1 调试通道"
	help.position = Vector2(36.0, 1024.0)
	help.add_theme_font_size_override("font_size", 18)
	help.add_theme_color_override("font_color", Color(0.9, 0.92, 0.86))
	help.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.03, 0.9))
	help.add_theme_constant_override("outline_size", 5)
	layer.add_child(help)


func _apply_lighting() -> void:
	var state := _sample_light_state(hour)
	var sun_direction_xy := _sun_to_screen_direction(hour)
	var to_sun_3d := Vector3(
		sun_direction_xy.x,
		sun_direction_xy.z,
		sun_direction_xy.y).normalized()
	rig.set_camera(camera)
	rig.set_sun(to_sun_3d)

	var lamp_config: Dictionary = config.get("lamp", {})
	var lamp_energy := _lamp_factor(hour) * float(
		lamp_config.get("energy", 2.4))
	var lamp_active := lamp_energy > 0.001
	var lamp_height := float(lamp_config.get("head_height_px", 58.0))
	var lamp_range := float(lamp_config.get("range_px", 260.0))
	rig.set_lamp(
		lamp_foot,
		float(lamp_config.get("shadow_light_height_px", lamp_height * 3.0)),
		float(lamp_config.get("shadow_range_px", lamp_range * 1.4)),
		lamp_active)
	rig.refresh_shadow_maps()

	var sun_color: Color = state["sun_color"]
	var sky_color: Color = state["sky_color"]
	ground_material.set_shader_parameter(
		"sun_direction", sun_direction_xy)
	ground_material.set_shader_parameter("sun_color", sun_color)
	ground_material.set_shader_parameter(
		"sun_energy", float(state["sun_energy"]))
	ground_material.set_shader_parameter("sky_color", sky_color)
	ground_material.set_shader_parameter(
		"sky_energy", float(state["sky_energy"]))
	ground_material.set_shader_parameter(
		"exposure", float(state["exposure"]))
	_set_lamp_parameters(ground_material, lamp_energy)

	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	for material in surface_materials:
		material.set_shader_parameter(
			"sun_direction", sun_direction_xy)
		material.set_shader_parameter(
			"sun_screen_direction", sun_direction_xy)
		material.set_shader_parameter("sun_color", sun_color)
		material.set_shader_parameter(
			"sun_energy", float(state["sun_energy"]))
		material.set_shader_parameter("sky_color", sky_color)
		material.set_shader_parameter(
			"sky_energy", float(state["sky_energy"]))
		material.set_shader_parameter(
			"exposure", float(state["exposure"]))
		material.set_shader_parameter("camera_zoom", camera.zoom)
		material.set_shader_parameter("viewport_size_px", viewport_size)
		_set_lamp_parameters(material, lamp_energy)

	if lamp_glow != null:
		var lamp_color := Color.from_string(
			str(lamp_config.get("color", "#ffd072")),
			Color(1.0, 0.82, 0.42))
		lamp_color.a = clampf(lamp_energy / 2.4, 0.0, 1.0) * 0.72
		lamp_glow.modulate = lamp_color
		lamp_glow.visible = lamp_active

	_apply_debug_mode()
	_update_hud()


func _apply_debug_mode() -> void:
	if ground_material == null:
		return
	ground_material.set_shader_parameter("debug_mode", debug_mode)
	for material in surface_materials:
		material.set_shader_parameter("debug_mode", debug_mode)


func _set_lamp_parameters(material: ShaderMaterial, energy: float) -> void:
	var lamp_config: Dictionary = config.get("lamp", {})
	var color := Color.from_string(
		str(lamp_config.get("color", "#ffd072")),
		Color(1.0, 0.82, 0.42))
	material.set_shader_parameter(
		"local_light_count",
		1 if energy > 0.001 else 0)
	material.set_shader_parameter(
		"shadowed_light_count",
		1 if energy > 0.001 else 0)
	var positions: Array[Vector4] = []
	var colors: Array[Vector4] = []
	for index in range(32):
		if index == 0:
			positions.append(Vector4(
				lamp_foot.x,
				lamp_foot.y,
				float(lamp_config.get("head_height_px", 58.0)),
				float(lamp_config.get("range_px", 260.0))))
			colors.append(Vector4(color.r, color.g, color.b, energy))
		else:
			positions.append(Vector4.ZERO)
			colors.append(Vector4.ZERO)
	material.set_shader_parameter(
		"local_light_positions",
		PackedVector4Array(positions))
	material.set_shader_parameter(
		"local_light_colors",
		PackedVector4Array(colors))
	material.set_shader_parameter(
		"lamp_shadow_strength",
		float(lamp_config.get("shadow_strength", 0.88)))


func _sun_to_screen_direction(at_hour: float) -> Vector3:
	var sun_config: Dictionary = config.get("sun", {})
	var sunrise := float(sun_config.get("sunrise_hour", 6.0 + 25.0 / 60.0))
	var sunset := float(sun_config.get("sunset_hour", 19.0 + 25.0 / 60.0))
	var t := clampf(
		(at_hour - sunrise) / maxf(sunset - sunrise, 0.001),
		0.0,
		1.0)
	var x := lerpf(
		float(sun_config.get("morning_azimuth", -1.0)),
		float(sun_config.get("evening_azimuth", 1.0)),
		t)
	var elevation_curve := sin(t * PI)
	var elevation := lerpf(
		float(sun_config.get("min_elevation", 0.12)),
		float(sun_config.get("max_elevation", 1.15)),
		elevation_curve)
	var north_south := sin((t - 0.5) * PI) * float(
		sun_config.get("north_south_arc", 0.32))
	return Vector3(x, north_south, elevation).normalized()


func _sample_light_state(at_hour: float) -> Dictionary:
	var keyframes: Array = config.get("keyframes", [])
	if keyframes.is_empty():
		return {
			"sky_color": Color("#adc2ae"),
			"sky_energy": 0.65,
			"sun_color": Color("#fff1d6"),
			"sun_energy": 1.0,
			"exposure": 1.0,
		}
	var before: Dictionary = keyframes[0]
	var after: Dictionary = keyframes[keyframes.size() - 1]
	for index in range(keyframes.size() - 1):
		var a: Dictionary = keyframes[index]
		var b: Dictionary = keyframes[index + 1]
		if at_hour >= float(a["hour"]) and at_hour <= float(b["hour"]):
			before = a
			after = b
			break
	var span := maxf(float(after["hour"]) - float(before["hour"]), 0.001)
	var t := clampf(
		(at_hour - float(before["hour"])) / span,
		0.0,
		1.0)
	t = smoothstep(0.0, 1.0, t)
	var sampled_sun_energy := lerpf(
		float(before["sun_energy"]),
		float(after["sun_energy"]),
		t)
	var sampled_exposure := lerpf(
		float(config.get("exposure_night", 1.0)),
		float(config.get("exposure_day", 0.78)),
		smoothstep(0.02, 0.82, sampled_sun_energy))
	return {
		"sky_color": Color.from_string(
			str(before["sky_color"]), Color.WHITE).lerp(
				Color.from_string(str(after["sky_color"]), Color.WHITE), t),
		"sky_energy": lerpf(
			float(before["sky_energy"]),
			float(after["sky_energy"]),
			t),
		"sun_color": Color.from_string(
			str(before["sun_color"]), Color.WHITE).lerp(
				Color.from_string(str(after["sun_color"]), Color.WHITE), t),
		"sun_energy": sampled_sun_energy,
		"exposure": sampled_exposure,
	}


func _lamp_factor(at_hour: float) -> float:
	var lamp_config: Dictionary = config.get("lamp", {})
	var on_hour := float(lamp_config.get("on_hour", 18.0))
	var off_hour := float(lamp_config.get("off_hour", 7.0))
	var fade := maxf(float(lamp_config.get("fade_hours", 0.45)), 0.001)
	var h := at_hour
	if h < on_hour:
		h += 24.0
	var on_extended := on_hour
	var off_extended := off_hour + 24.0
	if h < on_extended:
		return 0.0
	if h < off_extended:
		return smoothstep(on_extended, on_extended + fade, h)
	return 1.0 - smoothstep(off_extended, off_extended + fade, h)


func _make_radial_texture(size: int) -> Texture2D:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := (float(size) - 1.0) * 0.5
	for y in range(size):
		for x in range(size):
			var distance := Vector2(
				float(x) - center,
				float(y) - center).length() / center
			var alpha := pow(clampf(1.0 - distance, 0.0, 1.0), 2.4)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)


func _update_hud() -> void:
	if hud_time == null:
		return
	var h := int(hour)
	var m := int((hour - float(h)) * 60.0)
	hud_time.text = "时间 %02d:%02d" % [h, m]
	var state := _sample_light_state(hour)
	var sun_energy := float(state["sun_energy"])
	var lamp_energy := _lamp_factor(hour)
	var debug_names := [
		"最终画面",
		"颜色",
		"法线",
		"高光",
		"遮蔽",
		"太阳阴影",
		"路灯阴影",
		"路灯三通道",
		"路灯第二页",
		"路灯第三页",
		"路灯第四页",
	]
	hud_state.text = "太阳 %.2f  ·  路灯 %.2f  ·  %s  ·  %s" % [
		sun_energy,
		lamp_energy,
		"自动时间" if auto_advance and not paused else "手动时间",
		debug_names[debug_mode],
	]


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[LightingLab] Missing config: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
