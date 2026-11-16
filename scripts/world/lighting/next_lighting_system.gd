class_name NextLightingSystem
extends Node2D

const SURFACE_SHADER := preload("res://shaders/lighting/surface_sun.gdshader")
const PORTAL_SHADER := preload("res://shaders/lighting/interior_portal.gdshader")
const GROUND_SHADER := preload("res://shaders/lighting/ground_sun.gdshader")
const EXPOSURE_SHADER := preload("res://shaders/lighting/world_exposure.gdshader")
const WINDOW_LEAK_SHADER := preload("res://shaders/lighting/window_leak.gdshader")
const SUN_SHADOW_3D := preload("res://scripts/world/lighting/sun_shadow_3d.gd")
const CONFIG_PATH := "res://data/lighting_next.json"
const WINDOW_LEAK_TEXTURE_SIZE := 64
const STREET_LAMP_POOL_TEXTURE_SIZE := 256

var world: Node2D
var config: Dictionary = {}
var surface_config: Dictionary = {}
var player_surface_config: Dictionary = {}
var portal_config: Dictionary = {}
var leak_config: Dictionary = {}
var street_lamp_config: Dictionary = {}
var building_entries: Dictionary = {}
var sun_shadow_3d: SunShadow3D
var ground_material: ShaderMaterial
var exposure_overlay: Sprite2D
var exposure_material: ShaderMaterial
var window_leak_texture: ImageTexture
var lamp_pool_texture: ImageTexture
var lamp_pool_texture_falloff := -1.0


func _ready() -> void:
	name = "NextLightingSystem"
	process_priority = 50
	world = get_tree().get_first_node_in_group("world")
	if world == null:
		push_error("[NextLighting] World not found")
		return
	config = _read_json(CONFIG_PATH)
	surface_config = config.get("surface", {})
	player_surface_config = config.get("player_surface", {})
	portal_config = config.get("portal", {})
	leak_config = config.get("window_leak", {})
	street_lamp_config = config.get("street_lamp", {})
	window_leak_texture = _make_window_leak_texture()
	world.building_placed.connect(_on_building_placed)
	world.building_removed.connect(_on_building_removed)
	sun_shadow_3d = SUN_SHADOW_3D.new()
	add_child(sun_shadow_3d)
	sun_shadow_3d.setup(world)
	ground_material = ShaderMaterial.new()
	ground_material.shader = GROUND_SHADER
	ground_material.set_shader_parameter("sun_light_texture", sun_shadow_3d.get_texture())
	world.ground.material = ground_material
	world.ground.light_mask |= Building.LIGHT_LAYER_GROUND_LAMP
	_build_exposure_overlay()
	for building in world.buildings:
		_setup_building(building)


func _process(_delta: float) -> void:
	if world == null:
		return
	var hour := GameClock.hour_of_day()
	for building in world.buildings:
		if building != null and is_instance_valid(building):
			building.update_lights(hour)
	_update_player_local_light(hour)
	for building in world.buildings:
		if not building_entries.has(building) or not is_instance_valid(building):
			continue
		_update_building(building, building_entries[building], _delta)
	var sun := _sun_state(GameClock.hour_of_day())
	var shadow_fade := _shadow_fade(hour)
	if sun_shadow_3d != null:
		sun_shadow_3d.update_frame(
			get_viewport().get_camera_2d(),
			sun["to_sun"],
			sun["color"],
			float(sun["energy"]),
			shadow_fade)
	_update_exposure_overlay()


func _on_building_placed(building: Building) -> void:
	_setup_building(building)
	if sun_shadow_3d != null:
		sun_shadow_3d.rebuild_buildings()


func _on_building_removed(building: Building) -> void:
	building_entries.erase(building)
	if sun_shadow_3d != null:
		sun_shadow_3d.rebuild_buildings()


func _update_player_local_light(hour: float) -> void:
	var player = world.player_avatar
	if player == null or player.surface_material == null:
		return
	var material: ShaderMaterial = player.surface_material
	material.set_shader_parameter(
		"normal_strength",
		float(player_surface_config.get("normal_strength", 0.9)))
	material.set_shader_parameter(
		"specular_strength",
		float(player_surface_config.get("specular_strength", 0.35)))
	material.set_shader_parameter(
		"occlusion_strength",
		float(player_surface_config.get("occlusion_strength", 0.65)))
	var best_lamp: Building = null
	var best_distance := INF
	var best_head := Vector2.ZERO
	var best_energy := 0.0
	for building in world.buildings:
		if building == null or not is_instance_valid(building) \
				or str(building.data.get("lighting_kind", "")) != "street_lamp":
			continue
		var config: Dictionary = building.data.get("street_lamp_lighting", {})
		var head: Array = config.get("head_local", [16.0, -28.0])
		var head_position: Vector2 = building.global_position \
			+ Vector2(float(head[0]), float(head[1]))
		var distance: float = head_position.distance_to(player.global_position)
		if distance >= float(config.get("range_px", 64.0)):
			continue
		var energy: float = building.lamp_energy_at(hour) \
			* float(config.get("player_energy", 1.8))
		if energy <= 0.002 or distance >= best_distance:
			continue
		best_lamp = building
		best_distance = distance
		best_head = head_position
		best_energy = energy
	if best_lamp == null:
		material.set_shader_parameter("local_light_energy", 0.0)
		return
	var config: Dictionary = best_lamp.data.get("street_lamp_lighting", {})
	material.set_shader_parameter("local_light_position", best_head)
	material.set_shader_parameter("local_light_color", Color.from_string(
		str(config.get("color", "#ffd36a")), Color(1.0, 0.82, 0.42)))
	material.set_shader_parameter("local_light_energy", best_energy)
	material.set_shader_parameter(
		"local_light_range_px", float(config.get("range_px", 64.0)))
	material.set_shader_parameter(
		"local_light_height_px", float(config.get("height_px", 44.0)))


func _build_exposure_overlay() -> void:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	exposure_material = ShaderMaterial.new()
	exposure_material.shader = EXPOSURE_SHADER
	exposure_material.set_shader_parameter(
		"exposure", float(config.get("scene_exposure_night", 0.60)))
	exposure_overlay = Sprite2D.new()
	exposure_overlay.name = "WorldExposure"
	exposure_overlay.texture = texture
	exposure_overlay.centered = true
	exposure_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	exposure_overlay.material = exposure_material
	exposure_overlay.z_as_relative = false
	exposure_overlay.z_index = 4090
	exposure_overlay.top_level = true
	add_child(exposure_overlay)


func _update_exposure_overlay() -> void:
	if exposure_overlay == null:
		return
	var daylight_factor := _daytime_light_factor(GameClock.hour_of_day())
	var day_exposure := float(config.get("scene_exposure_day", 0.42))
	var night_exposure := float(config.get("scene_exposure_night", 0.60))
	exposure_material.set_shader_parameter(
		"exposure", lerpf(night_exposure, day_exposure, daylight_factor))
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	exposure_overlay.global_position = camera.global_position
	exposure_overlay.scale = viewport_size / camera.zoom
	exposure_overlay.rotation = -camera.global_rotation


func _setup_building(building: Building) -> void:
	if building == null or not is_instance_valid(building):
		return
	if str(building.data.get("lighting_backend", "legacy")) != "next":
		return
	var layers: Dictionary = building.data.get("sprite_layers", {})
	if building.wall_texture == null or building.roof_texture == null:
		return
	var entry := {
		"wall_material": _make_surface_material(building, layers, "wall"),
		"roof_material": _make_surface_material(building, layers, "roof"),
		"interior_material": _make_portal_material(layers),
		"portal_document": _load_portal_document(layers),
		"layer_origin": layers.get("origin", [0, 0]),
		"leak_a": 0.0,
		"leak_b": 0.0,
	}
	entry["portals"] = _portals_from_document(entry["portal_document"])
	_configure_window_leak_timing(building, entry)
	entry["leak_sprites"] = _make_window_leak_sprites(building, entry["portals"])
	building.wall_texture.material = entry["wall_material"]
	building.roof_texture.material = entry["roof_material"]
	if building.interior_texture != null:
		building.interior_texture.material = entry["interior_material"]
	building_entries[building] = entry
	_update_building(building, entry, 0.0)


func _make_surface_material(
		building: Building, layers: Dictionary, prefix: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter(
		"normal_texture", _load_texture(str(layers.get(prefix + "_normal", ""))))
	material.set_shader_parameter(
		"specular_texture", _load_texture(str(layers.get(prefix + "_specular", ""))))
	material.set_shader_parameter(
		"occlusion_texture", _load_texture(str(layers.get(prefix + "_occlusion", ""))))
	material.set_shader_parameter("normal_strength", float(surface_config.get("normal_strength", 0.85)))
	material.set_shader_parameter(
		"specular_strength", float(surface_config.get("specular_strength", 0.06)))
	material.set_shader_parameter(
		"occlusion_direct_strength",
		float(surface_config.get("occlusion_direct_strength", 0.35)))
	material.set_shader_parameter(
		"projected_shadow_texture", sun_shadow_3d.get_wall_shadow_texture())
	material.set_shader_parameter(
		"projected_shadow_strength",
		float(surface_config.get("wall_shadow_strength", 0.78)))
	material.set_shader_parameter(
		"receive_projected_shadow", 1.0 if prefix == "wall" else 0.0)
	material.set_shader_parameter(
		"max_shadow_offset_px",
		float(surface_config.get("wall_shadow_max_offset_px", 160.0)))
	material.set_shader_parameter(
		"wall_shadow_fade_start_ratio",
		float(surface_config.get("wall_shadow_fade_start_ratio", 1.5)))
	material.set_shader_parameter(
		"wall_shadow_fade_end_ratio",
		float(surface_config.get("wall_shadow_fade_end_ratio", 2.5)))
	var canvas: Array = layers.get("canvas", [256, 256])
	material.set_shader_parameter(
		"canvas_height_px", float(canvas[1]))
	var origin: Array = layers.get("origin", [0, 0])
	var footprint: Array = building.data.get("footprint", [1, 1])
	var fallback_foot_y := float(origin[1]) \
		+ float(footprint[1]) * float(Building.CELL) - 6.0
	material.set_shader_parameter(
		"wall_foot_y_px", float(
			layers.get("wall_foot_y_px", fallback_foot_y)))
	return material


func _make_portal_material(layers: Dictionary) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PORTAL_SHADER
	var canvas: Array = layers.get("canvas", [256, 256])
	material.set_shader_parameter(
		"canvas_size_px", Vector2(float(canvas[0]), float(canvas[1])))
	material.set_shader_parameter(
		"softness_growth", float(portal_config.get("softness_growth", 0.18)))
	material.set_shader_parameter(
		"portal_color", Color.from_string(
			str(portal_config.get("color", "#ffe3a8")), Color.WHITE))
	return material


func _make_window_leak_sprites(building: Building, portals: Array) -> Array:
	var result: Array = []
	if building.window_leak_root == null:
		return result
	var color := Color.from_string(
		str(leak_config.get("color", "#ffd39a")), Color.WHITE)
	var brightness := float(leak_config.get("brightness", 3.6))
	var texture_size := Vector2(
		window_leak_texture.get_width(), window_leak_texture.get_height())
	for portal in portals:
		if float(portal.get("leak_strength", 0.0)) <= 0.0:
			continue
		var center_array: Array = portal.get("marker_center_local", [0, 0])
		var sprite := Sprite2D.new()
		sprite.name = "WindowLeak_%s" % str(portal.get("id", result.size()))
		sprite.texture = window_leak_texture
		sprite.position = Vector2(
			float(center_array[0]), float(center_array[1]))
		var width_px := maxf(float(portal.get("width_px", 1.0)), 1.0)
		var height_px := maxf(
			float(portal.get("height_px", width_px)), 1.0)
		sprite.scale = Vector2(
			width_px / texture_size.x,
			height_px / texture_size.y)
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var material := ShaderMaterial.new()
		material.shader = WINDOW_LEAK_SHADER
		material.set_shader_parameter(
			"leak_color", Vector3(color.r, color.g, color.b))
		material.set_shader_parameter("brightness", brightness)
		material.set_shader_parameter(
			"edge_strength", float(leak_config.get("edge_strength", 1.4)))
		material.set_shader_parameter("energy", 0.0)
		sprite.material = material
		sprite.visible = false
		building.window_leak_root.add_child(sprite)
		result.append({
			"portal": portal,
			"sprite": sprite,
			"current": 0.0,
			"color": color,
			"brightness": brightness,
		})
	return result


func _make_window_leak_texture() -> ImageTexture:
	var size := WINDOW_LEAK_TEXTURE_SIZE
	var softness := clampf(
		float(leak_config.get("edge_softness", 0.16)), 0.01, 0.48)
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var nx := (float(x) + 0.5) / float(size)
			var ny := (float(y) + 0.5) / float(size)
			var edge_distance := minf(
				minf(nx, 1.0 - nx), minf(ny, 1.0 - ny))
			var alpha := smoothstep(0.0, softness, edge_distance)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)


func get_street_lamp_pool_texture() -> ImageTexture:
	var falloff := clampf(
		float(street_lamp_config.get("falloff_power", 0.8)), 0.2, 3.0)
	if lamp_pool_texture != null \
			and is_equal_approx(lamp_pool_texture_falloff, falloff):
		return lamp_pool_texture
	var size := STREET_LAMP_POOL_TEXTURE_SIZE
	var center := (float(size) - 1.0) * 0.5
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var distance := Vector2(
				float(x) - center, float(y) - center).length() / center
			var alpha := 0.0
			if distance < 1.0:
				alpha = pow(1.0 - distance, falloff)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	lamp_pool_texture = ImageTexture.create_from_image(image)
	lamp_pool_texture_falloff = falloff
	return lamp_pool_texture


func apply_street_lamp_config() -> void:
	lamp_pool_texture = null
	lamp_pool_texture_falloff = -1.0
	var hour := GameClock.hour_of_day()
	for building in world.buildings:
		if building == null or not is_instance_valid(building) \
				or building.local_lighting == null:
			continue
		building.local_lighting.refresh_positions()
		building.local_lighting.update(hour)


func _configure_window_leak_timing(building: Building, entry: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(building.id) \
		^ (building.cell.x * 73856093) \
		^ (building.cell.y * 19349663)
	entry["leak_on_hour"] = rng.randf_range(
		float(leak_config.get("on_start_hour", 18.0)),
		float(leak_config.get("on_end_hour", 18.75)))
	entry["leak_off_hour"] = rng.randf_range(
		float(leak_config.get("off_start_hour", 24.0)),
		float(leak_config.get("off_end_hour", 24.5)))


func _load_portal_document(layers: Dictionary) -> Dictionary:
	var path := str(layers.get("portal_config", ""))
	if path == "":
		return {}
	return _read_json(path)


func _portals_from_document(document: Dictionary) -> Array:
	var groups: Dictionary = document.get("interior_light_groups", {})
	var result: Array = []
	for portal in document.get("portals", []):
		if str(portal.get("type", "")) not in ["window", "glass_door"]:
			continue
		if not groups.has(str(portal.get("interior_light_group", ""))):
			continue
		result.append(portal)
	return result


func _update_building(building: Building, entry: Dictionary, delta: float) -> void:
	var sun := _sun_state(GameClock.hour_of_day())
	var to_sun: Vector3 = sun["to_sun"]
	var shadow_fade := _shadow_fade(GameClock.hour_of_day())
	var camera := get_viewport().get_camera_2d()
	var camera_zoom := camera.zoom if camera != null else Vector2.ONE
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	for key in ["wall_material", "roof_material"]:
		var material: ShaderMaterial = entry[key]
		material.set_shader_parameter("to_sun", to_sun)
		material.set_shader_parameter("sun_color", sun["color"])
		material.set_shader_parameter("sun_energy", float(sun["energy"]))
		material.set_shader_parameter("projected_shadow_fade", shadow_fade)
		material.set_shader_parameter("camera_zoom", camera_zoom)
		material.set_shader_parameter("viewport_size_px", viewport_size)
		material.set_shader_parameter(
			"normal_strength",
			float(surface_config.get("normal_strength", 0.85)))
		material.set_shader_parameter(
			"specular_strength",
			float(surface_config.get("specular_strength", 0.06)))
		material.set_shader_parameter(
			"occlusion_direct_strength",
			float(surface_config.get("occlusion_direct_strength", 0.35)))
		material.set_shader_parameter(
			"projected_shadow_strength",
			float(surface_config.get("wall_shadow_strength", 0.78)))
		material.set_shader_parameter(
			"max_shadow_offset_px",
			float(surface_config.get("wall_shadow_max_offset_px", 160.0)))
		material.set_shader_parameter(
			"wall_shadow_fade_start_ratio",
			float(surface_config.get("wall_shadow_fade_start_ratio", 1.5)))
		material.set_shader_parameter(
			"wall_shadow_fade_end_ratio",
			float(surface_config.get("wall_shadow_fade_end_ratio", 2.5)))
	var portal_material: ShaderMaterial = entry["interior_material"]
	var ray := Vector2(-to_sun.x, -to_sun.y).normalized()
	var length := float(portal_config.get("window_height_px", 42.0)) \
		* Vector2(to_sun.x, to_sun.y).length() / maxf(to_sun.z, 0.1)
	length = clampf(
		length,
		float(portal_config.get("minimum_length_px", 24.0)),
		float(portal_config.get("maximum_length_px", 180.0)))
	portal_material.set_shader_parameter("sun_ray_direction", ray)
	portal_material.set_shader_parameter("portal_length_px", length)
	portal_material.set_shader_parameter(
		"portal_softness_px",
		float(portal_config.get("minimum_softness_px", 7.0)))
	portal_material.set_shader_parameter(
		"portal_energy",
		float(portal_config.get("energy", 0.42)) * float(sun["energy"]))
	var origin_array: Array = entry["layer_origin"]
	var origin := Vector2(float(origin_array[0]), float(origin_array[1]))
	var portals: Array = entry["portals"]
	_set_portal_parameter(portal_material, "portal_a", portals, 0, origin)
	_set_portal_parameter(portal_material, "portal_b", portals, 1, origin)
	_update_window_leak(building, entry, delta)


func _set_portal_parameter(
		material: ShaderMaterial,
		parameter: String,
		portals: Array,
		index: int,
		origin: Vector2) -> void:
	if index >= portals.size():
		material.set_shader_parameter(parameter, Vector4.ZERO)
		return
	var portal: Dictionary = portals[index]
	var center_array: Array = portal.get("marker_center_local", [0, 0])
	var center := Vector2(float(center_array[0]), float(center_array[1])) + origin
	material.set_shader_parameter(parameter, Vector4(
		center.x, center.y, float(portal.get("width_px", 0.0)), 1.0))


func _update_window_leak(building: Building, entry: Dictionary, delta: float) -> void:
	var hour := GameClock.hour_of_day()
	var light_factor := _building_light_factor(
		hour,
		float(entry["leak_on_hour"]),
		float(entry["leak_off_hour"]),
		float(leak_config.get("fade_hours", 0.12)))
	var fade_seconds := maxf(float(leak_config.get("fade_seconds", 0.12)), 0.01)
	var blend := 0.0 if delta <= 0.0 else 1.0 - exp(-delta / fade_seconds * 4.0)
	var leak_sprites: Array = entry["leak_sprites"]
	for index in range(leak_sprites.size()):
		var leak_entry: Dictionary = leak_sprites[index]
		var portal: Dictionary = leak_entry["portal"]
		var target := 0.0
		target = float(portal.get("leak_strength", 0.0)) * light_factor
		var current := lerpf(float(leak_entry["current"]), target, blend)
		leak_entry["current"] = current
		var sprite: Sprite2D = leak_entry["sprite"]
		var material: ShaderMaterial = sprite.material
		material.set_shader_parameter("energy", current)
		sprite.visible = current > 0.002
		if index == 0:
			entry["leak_a"] = current
		elif index == 1:
			entry["leak_b"] = current


func _building_light_factor(
		hour: float, on_hour: float, off_hour: float, fade_hours: float) -> float:
	var h := hour
	if h < 12.0:
		h += 24.0
	var on := on_hour
	var off := off_hour
	if off < on:
		off += 24.0
	if h < on:
		return 0.0
	var fade := maxf(fade_hours, 0.001)
	var turn_on := smoothstep(on, on + fade, h)
	if h < off:
		return turn_on
	return turn_on * (1.0 - smoothstep(off, off + fade, h))


func _sun_state(hour: float) -> Dictionary:
	var cfg: Dictionary = config.get("sun", {})
	var sunrise := float(cfg.get("sunrise_hour", 7.0))
	var full_day := float(cfg.get("full_day_hour", 10.0))
	var fade_start := float(cfg.get("fade_start_hour", 16.0))
	var night := float(cfg.get("night_hour", 19.0))
	if hour < sunrise or hour >= night:
		return {
			"to_sun": Vector3(0.0, 0.0, 1.0),
			"color": Color.WHITE,
			"energy": 0.0,
		}
	var t := clampf((hour - sunrise) / maxf(night - sunrise, 0.001), 0.0, 1.0)
	var rise_energy := smoothstep(sunrise, full_day, hour)
	var set_energy := 1.0 - smoothstep(fade_start, night, hour)
	var day_energy := minf(rise_energy, set_energy)
	var energy := lerpf(
		float(cfg.get("minimum_energy", 0.0)),
		float(cfg.get("maximum_energy", 0.18)),
		day_energy)
	var morning := Color.from_string(
		str(cfg.get("minimum_color", "#f2b06c")), Color.WHITE)
	var noon := Color.from_string(
		str(cfg.get("noon_color", "#fff4d8")), Color.WHITE)
	var color := morning.lerp(noon, day_energy)
	return {
		"to_sun": Vector3(cos(t * PI), 0.35, 0.72).normalized(),
		"color": color,
		"energy": energy,
	}


func _shadow_fade(hour: float) -> float:
	var cfg: Dictionary = config.get("sun", {})
	var start := float(cfg.get("shadow_start_hour", 8.0))
	var full_day := float(cfg.get("full_day_hour", 10.0))
	var fade_start := float(cfg.get("fade_start_hour", 16.0))
	var shadow_end := float(cfg.get("shadow_end_hour", 18.0))
	var rise := smoothstep(start, full_day, hour)
	var fade_out := 1.0 - smoothstep(fade_start, shadow_end, hour)
	return minf(rise, fade_out)


func _daytime_light_factor(hour: float) -> float:
	var cfg: Dictionary = config.get("sun", {})
	var sunrise := float(cfg.get("sunrise_hour", 7.0))
	var full_day := float(cfg.get("full_day_hour", 10.0))
	var fade_start := float(cfg.get("fade_start_hour", 16.0))
	var night := float(cfg.get("night_hour", 19.0))
	var rise := smoothstep(sunrise, full_day, hour)
	var fade_out := 1.0 - smoothstep(fade_start, night, hour)
	return minf(rise, fade_out)


func _load_texture(path: String) -> Texture2D:
	return load(path) if path != "" and ResourceLoader.exists(path) else null


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[NextLighting] missing JSON: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
