extends RefCounted
class_name BuildingLighting
## 建筑光照适配层。
##
## 建筑只通过本类更新灯光、显示层和位置。当前内部仍是原有的 PointLight2D
## 实现，后续替换为 SDF/光线步进后端时不需要改动建筑生命周期代码。

const CELL := 32
const LIGHT_ON_EARLIEST := 20.0
const LIGHT_ON_LATEST := 20.75
const LIGHT_FADE_HOURS := 0.12
const LIGHT_SPREAD_CELLS := 1.0
const LIGHT_ENERGY := 0.72
const LIGHT_OFF_SPREAD_HOURS := 0.5

const LIGHT_LAYER_SPILL := 1
const LIGHT_LAYER_ROOF := 2
const LIGHT_LAYER_INTERIOR := 4
const PLAYER_QUALITY_LIGHT_MASK := 8

const BuildingLightingAssetScript := preload("res://scripts/world/lighting/building_lighting_asset.gd")
const SdfSpillOverlayScript := preload("res://scripts/world/lighting/sdf_spill_overlay.gd")
const SDF_SPILL_SHADER := preload("res://shaders/lighting/spill_occlusion.gdshader")
const WINDOW_HALO_SHADER := preload("res://shaders/lighting/window_halo.gdshader")

const LIGHT_RECT := "res://art/generated/light_rect.png"
const LIGHT_RADIAL := "res://art/generated/light_radial.png"
const RECT_FLAT_RATIO := 0.667

var host
var world: Node2D
var data: Dictionary = {}
var asset: BuildingLightingAsset
var cell := Vector2i.ZERO
var footprint := Vector2i(4, 4)
var roof_root: Node2D
var roof_light_root: Node2D
var interior: Node2D

var night_light: PointLight2D
var interior_light: PointLight2D
var roof_light: PointLight2D
var spill_light: PointLight2D
var roof_light_overlay: Sprite2D
var window_halo_overlay: Sprite2D
var spill_light_overlay: Sprite2D
var spill_light_overlays: Array[Sprite2D] = []
var lamp_head_overlays: Array[Sprite2D] = []
var lamp_point_lights: Array[PointLight2D] = []
var light_on_hour := LIGHT_ON_LATEST
var light_off_hour := 0.0
var light_base_pos := Vector2.ZERO
var backend_id := "legacy"
var quality_id := "high"
var sdf_occluders: Array[LightOccluder2D] = []


func setup(building_host, world_ref: Node2D) -> void:
	host = building_host
	world = world_ref
	if host == null or world == null:
		return
	data = host.data
	asset = BuildingLightingAssetScript.from_building_data(data)
	cell = host.cell
	footprint = host.footprint
	roof_root = host.roof_root
	roof_light_root = host.roof_light_root
	interior = host.interior
	backend_id = str(ProjectSettings.get_setting(
		"lighting/building_backend", "legacy"))
	if backend_id != "legacy" and backend_id != "sdf":
		push_warning("未知建筑光照后端 %s，回退 legacy" % backend_id)
		backend_id = "legacy"
	quality_id = str(ProjectSettings.get_setting("lighting/quality", "high"))
	if quality_id != "high" and quality_id != "low":
		push_warning("未知建筑光照画质 %s，回退 high" % quality_id)
		quality_id = "high"

	if asset.shape == "circle":
		_build_legacy()
	else:
		_build_layered()
		if interior_light == null and roof_light == null and spill_light == null:
			_build_legacy()
	if backend_id == "sdf":
		_build_sdf_occluder()


func update(hour: float) -> void:
	# 一律换算成连续小时再比较，兼容普通店和跨夜店。
	if night_light == null:
		return
	var h := hour
	if h < 12.0:
		h += 24.0
	var off := light_off_hour
	if off < light_on_hour:
		off += 24.0
	var k := clampf((h - light_on_hour) / LIGHT_FADE_HOURS, 0.0, 1.0)
	if h >= off:
		k = clampf(1.0 - (h - off) / LIGHT_FADE_HOURS, 0.0, 1.0)
	if h < light_on_hour:
		k = 0.0
	var energy := k * k * (3.0 - 2.0 * k)
	var window_energy := energy * LIGHT_ENERGY * asset.window_energy_scale
	var lamp_energy := energy * LIGHT_ENERGY * asset.lamp_energy_scale
	var spill_energy := energy * 0.70 * asset.lamp_energy_scale
	if interior_light:
		interior_light.energy = window_energy
	if roof_light:
		roof_light.energy = window_energy
	if spill_light:
		spill_light.energy = lamp_energy * 0.48
	elif night_light:
		night_light.energy = window_energy
	if roof_light_overlay:
		roof_light_overlay.modulate.a = window_energy
	if window_halo_overlay and window_halo_overlay.material is ShaderMaterial:
		window_halo_overlay.material.set_shader_parameter(
			"energy", window_energy * 0.55)
	if spill_light_overlay:
		spill_light_overlay.modulate.a = spill_energy
	for overlay in spill_light_overlays:
		overlay.modulate.a = spill_energy
	for overlay in lamp_head_overlays:
		overlay.modulate.a = lamp_energy * 0.60
	for light in lamp_point_lights:
		var role := str(light.get_meta("lighting_role", "direct"))
		light.energy = lamp_energy * (1.0 if role == "direct" else 0.35)


func apply_view_state(show_interior_layer: bool, show_roof_layer: bool) -> void:
	if interior_light:
		interior_light.visible = show_interior_layer
	if roof_light:
		roof_light.visible = show_roof_layer
	if spill_light:
		spill_light.visible = true
	if roof_light_overlay:
		roof_light_overlay.visible = show_roof_layer
	if window_halo_overlay:
		window_halo_overlay.visible = show_roof_layer
	if spill_light_overlay:
		spill_light_overlay.visible = true
	for overlay in spill_light_overlays:
		overlay.visible = true
	for overlay in lamp_head_overlays:
		overlay.visible = true
	for light in lamp_point_lights:
		light.visible = true


func refresh_positions() -> void:
	if interior_light:
		interior_light.global_position = light_base_pos
	if roof_light:
		_position_light(roof_light)
	if spill_light:
		_position_light(spill_light)
	for light in lamp_point_lights:
		_position_light(light)
	if spill_light == null and night_light != null and night_light != roof_light:
		night_light.global_position = light_base_pos \
			+ Vector2(host.light_offset_cells()) * float(CELL)


func release() -> void:
	# 世界根节点下的灯不随建筑自动释放，拆除建筑时必须显式回收。
	var lights: Array = [interior_light, roof_light, spill_light, night_light]
	lights.append_array(lamp_point_lights)
	var freed_ids: Dictionary = {}
	for light in lights:
		if light == null or not is_instance_valid(light):
			continue
		var light_id: int = light.get_instance_id()
		if freed_ids.has(light_id):
			continue
		freed_ids[light_id] = true
		light.queue_free()
	interior_light = null
	roof_light = null
	spill_light = null
	night_light = null
	roof_light_overlay = null
	window_halo_overlay = null
	spill_light_overlay = null
	spill_light_overlays.clear()
	lamp_head_overlays.clear()
	lamp_point_lights.clear()
	for occluder in sdf_occluders:
		if occluder != null and is_instance_valid(occluder):
			occluder.queue_free()
	sdf_occluders.clear()


func _build_layered() -> void:
	_configure_timing()
	var warm := Color(1.0, 0.82, 0.54)
	var size_px := Vector2(footprint) * float(CELL)
	var radius := maxf(size_px.x, size_px.y) * 0.62
	var interior_size := Vector2(
		maxf(size_px.x - float(CELL) * 0.55, float(CELL) * 0.5),
		maxf(size_px.y - float(CELL) * 0.55, float(CELL) * 0.5))
	light_base_pos = world.cell_center(cell) \
		+ Vector2(float(footprint.x - 1), float(footprint.y - 1)) * CELL * 0.5

	interior_light = _make_rect_light(interior_size, float(CELL) * 0.22, warm)
	if interior_light:
		interior_light.name = "InteriorLight"
		interior_light.range_item_cull_mask = LIGHT_LAYER_INTERIOR
		interior_light.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_add_world_light(interior_light)
		interior_light.global_position = light_base_pos

	var roof_origin := asset.roof_origin
	var spill_origin := asset.spill_origin
	var roof_path := asset.roof_texture_path
	if roof_path != "" and ResourceLoader.exists(roof_path):
		roof_light = _make_texture_light(
			roof_path, warm, LIGHT_LAYER_ROOF, roof_origin)
		roof_light_overlay = _make_light_overlay(
			"RoofLightGlow", roof_path, roof_origin)
		roof_light_root.add_child(roof_light_overlay)
		if quality_id == "high":
			window_halo_overlay = _make_window_halo(
				roof_path, roof_origin, asset.window_halo_radius_px)
			roof_light_root.add_child(window_halo_overlay)
	else:
		roof_light = _make_circle_light(radius * 0.7, warm)
		if roof_light:
			roof_light.range_item_cull_mask = LIGHT_LAYER_ROOF
			roof_light.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if roof_light:
		roof_light.name = "RoofLight"
		roof_light.enabled = true
		_add_world_light(roof_light)
		_position_light(roof_light)

	var spill_path := asset.spill_texture_path
	if not asset.lamps.is_empty():
		_build_lamp_markers()
	elif spill_path != "" and ResourceLoader.exists(spill_path):
		spill_light = _make_texture_light(
			spill_path, warm, LIGHT_LAYER_SPILL, spill_origin)
		spill_light_overlays.clear()
		var guides: Array = asset.spill_guides
		for index in range(guides.size()):
			var guide: Dictionary = guides[index]
			var overlay := _make_directional_overlay(
				"SpillLight%d" % index, guide, spill_origin)
			roof_light_root.add_child(overlay)
			spill_light_overlays.append(overlay)
			if spill_light_overlay == null:
				spill_light_overlay = overlay
	else:
		spill_light = _make_rect_light(
			size_px, LIGHT_SPREAD_CELLS * float(CELL), warm)
		if spill_light:
			spill_light.range_item_cull_mask = LIGHT_LAYER_SPILL
	if spill_light:
		spill_light.name = "SpillLight"
		_add_world_light(spill_light)
		_position_light(spill_light)
	night_light = spill_light if spill_light != null else roof_light
	_apply_light_mask(interior, LIGHT_LAYER_INTERIOR)
	_apply_light_mask(roof_root, LIGHT_LAYER_ROOF)


func _build_legacy() -> void:
	var color := Color(1.0, 0.86, 0.62)
	if asset.shape == "circle":
		night_light = _make_circle_light(
			asset.radius_cells * float(CELL), color)
	else:
		night_light = _make_rect_light(
			Vector2(footprint.x, footprint.y) * CELL,
			LIGHT_SPREAD_CELLS * float(CELL),
			color)
	if night_light != null and asset.shape == "circle" and quality_id == "high":
		night_light.shadow_enabled = true
		night_light.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
		night_light.shadow_filter = Light2D.SHADOW_FILTER_PCF5
		night_light.shadow_filter_smooth = 1.2
		night_light.shadow_item_cull_mask = PLAYER_QUALITY_LIGHT_MASK
	if night_light == null and interior_light == null \
			and roof_light == null and spill_light == null:
		return
	night_light.name = "NightLight"
	night_light.top_level = true
	light_base_pos = world.cell_center(cell) \
		+ Vector2(float(footprint.x - 1), float(footprint.y - 1)) * CELL * 0.5
	world.add_child(night_light)
	if asset.shape == "circle" and quality_id == "high":
		var direct := _make_circle_light(
			asset.radius_cells * float(CELL), color)
		if direct != null:
			direct.name = "LampPointLightDirect"
			direct.range_item_cull_mask = PLAYER_QUALITY_LIGHT_MASK
			direct.set_meta("lighting_role", "direct")
			direct.set_meta("follow_lamp_offset", true)
			_add_world_light(direct)
			lamp_point_lights.append(direct)
	refresh_positions()
	_configure_timing()
	var glow := asset.glow_scale
	if glow != 1.0:
		night_light.texture_scale *= glow


func _configure_timing() -> void:
	if data.has("light_on_hour"):
		light_on_hour = float(data.get("light_on_hour"))
	else:
		light_on_hour = randf_range(LIGHT_ON_EARLIEST, LIGHT_ON_LATEST)
	var close_h: float = float(host.close_hour())
	if data.has("light_off_hour"):
		light_off_hour = float(data.get("light_off_hour"))
	else:
		light_off_hour = close_h if close_h < host.open_hour() \
			else close_h + randf_range(0.0, LIGHT_OFF_SPREAD_HOURS)


func _build_lamp_markers() -> void:
	for index in range(asset.lamps.size()):
		var lamp: Dictionary = asset.lamps[index]
		var overlay := _make_lamp_fan(index, lamp, asset.spill_origin)
		roof_light_root.add_child(overlay)
		spill_light_overlays.append(overlay)
		if spill_light_overlay == null:
			spill_light_overlay = overlay
		if quality_id == "high":
			_add_key_lamp_lights(index, overlay)
			var head_glow := _make_lamp_head_glow(index, lamp, asset.spill_origin)
			roof_light_root.add_child(head_glow)
			lamp_head_overlays.append(head_glow)


func _make_lamp_fan(index: int, lamp: Dictionary,
		origin: Vector2i) -> Sprite2D:
	var source_rect: Array = lamp.get("source", [0, 0, 0, 0])
	var source_a := Vector2(float(source_rect[0]), float(source_rect[1]))
	var source_b := Vector2(float(source_rect[2]), float(source_rect[3]))
	var source_center := (source_a + source_b) * 0.5
	var source_half_width := maxf((source_a.distance_to(source_b) + 1.0) * 0.5, 0.5)

	var left: Array = lamp.get("left", [])
	var right: Array = lamp.get("right", [])
	var left_start := _point_from_values(left, 0, source_center + Vector2.LEFT)
	var left_end := _point_from_values(left, 2, source_center + Vector2.DOWN)
	var right_start := _point_from_values(right, 0, source_center + Vector2.RIGHT)
	var right_end := _point_from_values(right, 2, source_center + Vector2.DOWN)

	var axis_end := (left_end + right_end) * 0.5
	var forward_axis := (axis_end - source_center).normalized()
	if forward_axis == Vector2.ZERO:
		forward_axis = Vector2.DOWN
	var side_axis := Vector2(-forward_axis.y, forward_axis.x)
	var left_angle := absf(forward_axis.angle_to((left_end - source_center).normalized()))
	var right_angle := absf(forward_axis.angle_to((right_end - source_center).normalized()))
	var half_angle := clampf((left_angle + right_angle) * 0.5, 0.01, PI * 0.48)
	var fade_radius := maxf(
		(source_center.distance_to(left_end) + source_center.distance_to(right_end)) * 0.5,
		1.0)
	var extent := ceili(fade_radius + source_half_width + 3.0)
	var bounds_min := Vector2i(
		floori(source_center.x) - extent,
		floori(source_center.y) - extent)
	var image_size := Vector2i(extent * 2 + 1, extent * 2 + 1)
	var image := Image.create(
		image_size.x, image_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 0.0))
	var slope := tan(half_angle)
	for py in range(image_size.y):
		for px in range(image_size.x):
			var point := Vector2(bounds_min) + Vector2(float(px), float(py))
			var delta := point - source_center
			var forward := delta.dot(forward_axis)
			if forward < -source_half_width:
				continue
			var lateral := absf(delta.dot(side_axis))
			var half_width := source_half_width + maxf(forward, 0.0) * slope
			if lateral > half_width:
				continue
			var radial := delta.length()
			if radial > fade_radius:
				continue
			var radial_t := clampf(radial / fade_radius, 0.0, 1.0)
			var radial_fade := 1.0 - smoothstep(0.28, 1.0, radial_t)
			var side_fade := smoothstep(0.0, 2.25, half_width - lateral)
			var start_fade := smoothstep(0.0, 1.25, radial)
			var alpha := radial_fade * side_fade * start_fade
			if alpha > 0.0:
				image.set_pixel(px, py, Color(1.0, 1.0, 1.0, alpha))

	var overlay := Sprite2D.new()
	overlay.name = "LampFan%d" % index
	overlay.texture = ImageTexture.create_from_image(image)
	overlay.centered = false
	overlay.position = source_center - Vector2(origin)
	overlay.offset = Vector2(bounds_min) - source_center
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	overlay.material = CanvasItemMaterial.new()
	overlay.material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	overlay.modulate = Color(
		asset.lamp_color.r, asset.lamp_color.g, asset.lamp_color.b, 0.0)
	overlay.z_index = 0
	overlay.light_mask = LIGHT_LAYER_SPILL
	overlay.set_meta("lamp_source_center", source_center)
	overlay.set_meta("lamp_source_half_width_px", source_half_width)
	overlay.set_meta("lamp_half_angle_radians", half_angle)
	overlay.set_meta("lamp_fade_radius_px", fade_radius)
	overlay.set_meta("lamp_texture_source_px",
		source_center - Vector2(bounds_min))
	if backend_id == "sdf":
		overlay.set_script(SdfSpillOverlayScript)
		overlay.call("enable_sdf_occlusion", SDF_SPILL_SHADER)
	return overlay


func _make_lamp_head_glow(index: int, lamp: Dictionary,
		origin: Vector2i) -> Sprite2D:
	var source_rect: Array = lamp.get("source", [0, 0, 0, 0])
	var source_a := Vector2(float(source_rect[0]), float(source_rect[1]))
	var source_b := Vector2(float(source_rect[2]), float(source_rect[3]))
	var source_center := (source_a + source_b) * 0.5
	var radius := maxf(asset.lamp_head_radius_px, 1.0)
	var size := ceili(radius * 2.0) + 1
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 0.0))
	var center := Vector2(size - 1, size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			var distance := Vector2(float(x), float(y)).distance_to(center)
			var alpha := pow(maxf(1.0 - distance / radius, 0.0), 1.7)
			if alpha > 0.0:
				image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	var glow := Sprite2D.new()
	glow.name = "LampHeadGlow%d" % index
	glow.texture = ImageTexture.create_from_image(image)
	glow.position = source_center - Vector2(origin)
	glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	glow.material = CanvasItemMaterial.new()
	glow.material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.modulate = Color(
		asset.lamp_color.r, asset.lamp_color.g, asset.lamp_color.b, 0.0)
	glow.z_index = 1
	glow.light_mask = LIGHT_LAYER_SPILL
	return glow


func _add_key_lamp_lights(index: int, fan: Sprite2D) -> void:
	var radius := maxf(float(fan.get_meta("lamp_fade_radius_px", 48.0)) * 0.9, 8.0)
	var direct := _make_circle_light(radius, asset.lamp_color)
	if direct != null:
		direct.name = "LampPointLightDirect%d" % index
		direct.energy = 0.0
		direct.height = 18.0
		direct.range_item_cull_mask = PLAYER_QUALITY_LIGHT_MASK
		direct.set_meta("lighting_role", "direct")
		_add_world_light(direct)
		direct.global_position = host.global_position + fan.position
		lamp_point_lights.append(direct)

	var shadow := _make_circle_light(radius, asset.lamp_color)
	if shadow != null:
		shadow.name = "LampPointLightShadow%d" % index
		shadow.energy = 0.0
		shadow.height = 18.0
		shadow.range_item_cull_mask = 1
		shadow.shadow_enabled = true
		shadow.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
		shadow.shadow_filter = Light2D.SHADOW_FILTER_PCF5
		shadow.shadow_filter_smooth = 1.2
		shadow.shadow_item_cull_mask = PLAYER_QUALITY_LIGHT_MASK
		shadow.set_meta("lighting_role", "shadow")
		_add_world_light(shadow)
		shadow.global_position = host.global_position + fan.position
		lamp_point_lights.append(shadow)


func _make_window_halo(path: String, origin: Vector2i, radius_px: float) -> Sprite2D:
	var overlay := Sprite2D.new()
	overlay.name = "WindowHalo"
	overlay.texture = load(path)
	overlay.centered = false
	overlay.position = -Vector2(origin)
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var material := ShaderMaterial.new()
	material.shader = WINDOW_HALO_SHADER
	material.set_shader_parameter("radius_px", maxf(radius_px, 1.0))
	material.set_shader_parameter("glow_color", Color(1.0, 0.74, 0.38))
	material.set_shader_parameter("energy", 0.0)
	overlay.material = material
	overlay.light_mask = LIGHT_LAYER_ROOF
	return overlay


func _point_from_values(values: Array, offset: int, fallback: Vector2) -> Vector2:
	if values.size() < offset + 2:
		return fallback
	return Vector2(float(values[offset]), float(values[offset + 1]))


func _make_rect_light(inner_size: Vector2, _spread: float, color: Color) -> PointLight2D:
	if not ResourceLoader.exists(LIGHT_RECT):
		return null
	var texture: Texture2D = load(LIGHT_RECT)
	if texture == null:
		return null
	var light := PointLight2D.new()
	light.texture = texture
	light.color = color
	light.energy = 0.0
	light.blend_mode = Light2D.BLEND_MODE_ADD
	light.z_index = -4000
	light.range_z_min = -8192
	light.range_z_max = 8192
	var texture_width := float(texture.get_width())
	var full := Vector2(inner_size.x / RECT_FLAT_RATIO, inner_size.y / RECT_FLAT_RATIO)
	light.texture_scale = full.x / texture_width
	light.scale = Vector2(1.0, full.y / full.x)
	return light


func _make_circle_light(radius: float, color: Color) -> PointLight2D:
	if not ResourceLoader.exists(LIGHT_RADIAL):
		return null
	var texture: Texture2D = load(LIGHT_RADIAL)
	if texture == null:
		return null
	var light := PointLight2D.new()
	light.texture = texture
	light.color = color
	light.energy = 0.0
	light.blend_mode = Light2D.BLEND_MODE_ADD
	light.z_index = -4000
	light.range_z_min = -8192
	light.range_z_max = 8192
	light.texture_scale = radius / (float(texture.get_width()) * 0.5)
	return light


func _make_texture_light(path: String, color: Color, cull_mask: int,
		origin: Vector2i) -> PointLight2D:
	var texture: Texture2D = load(path)
	if texture == null:
		return null
	var light := PointLight2D.new()
	light.texture = texture
	light.color = color
	light.energy = 0.0
	light.texture_scale = 1.0
	light.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	light.blend_mode = Light2D.BLEND_MODE_ADD
	light.range_item_cull_mask = cull_mask
	light.range_z_min = -8192
	light.range_z_max = 8192
	light.z_index = -4000
	light.enabled = false
	light.set_meta("building_light_origin", origin)
	return light


func _make_light_overlay(node_name: String, path: String, origin: Vector2i) -> Sprite2D:
	var overlay := Sprite2D.new()
	overlay.name = node_name
	overlay.texture = load(path)
	overlay.centered = false
	overlay.position = -Vector2(origin)
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	overlay.material = CanvasItemMaterial.new()
	overlay.material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	overlay.modulate = Color(1.0, 0.82, 0.54, 0.0)
	overlay.light_mask = LIGHT_LAYER_SPILL
	return overlay


func _make_directional_overlay(node_name: String,
		guide: Dictionary, origin: Vector2i) -> Sprite2D:
	var start_arr: Array = guide.get("start", [0, 0])
	var end_arr: Array = guide.get("end", [0, 0])
	var start_edge := Vector2(float(start_arr[0]), float(start_arr[1]))
	var end_edge := Vector2(float(end_arr[0]), float(end_arr[1]))
	var start_width := start_edge.distance_to(end_edge) + 1.0
	var length_px := maxf(float(guide.get("length", float(CELL) * 1.5)), 2.0)
	var spread_degrees := maxf(float(guide.get("spread_degrees", 45.0)), 0.0)
	var side_slope := tan(deg_to_rad(spread_degrees))
	var image_width := maxi(ceili(length_px) + 1, 2)
	var image_height := maxi(ceili(length_px * 2.0) + 2, 2)
	var image := Image.create(image_width, image_height, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 0.0))
	var center_y := float(image_height - 1) * 0.5
	var start_half_width := start_width * 0.5
	for x in range(image_width):
		var side_half_width := start_half_width + float(x) * side_slope
		for y in range(image_height):
			var lateral := absf(float(y) - center_y)
			if lateral > side_half_width:
				continue
			var radius := sqrt(float(x * x) + lateral * lateral)
			if radius > length_px:
				continue
			var radial_t := clampf(radius / length_px, 0.0, 1.0)
			var radial_fade := 1.0 - smoothstep(0.38, 1.0, radial_t)
			var side_fade := smoothstep(0.0, 2.5, side_half_width - lateral)
			var arc_fade := smoothstep(0.0, 1.5, length_px - radius)
			var alpha := radial_fade * side_fade * arc_fade
			if alpha > 0.0:
				image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))

	var overlay := Sprite2D.new()
	overlay.name = node_name
	overlay.texture = ImageTexture.create_from_image(image)
	overlay.centered = false
	overlay.offset = Vector2(0.0, -float(image_height) * 0.5)
	overlay.position = (start_edge + end_edge) * 0.5 - Vector2(origin)
	var direction_arr: Array = guide.get("direction", [0, 1])
	var direction := Vector2(float(direction_arr[0]), float(direction_arr[1])).normalized()
	overlay.rotation = direction.angle()
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	overlay.material = CanvasItemMaterial.new()
	overlay.material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	overlay.modulate = Color(2.4, 1.15, 0.18, 0.0)
	overlay.z_index = 0
	overlay.light_mask = LIGHT_LAYER_SPILL
	overlay.set_meta("start_width_px", start_width)
	overlay.set_meta("length_px", length_px)
	overlay.set_meta("spread_degrees", spread_degrees)
	if backend_id == "sdf":
		overlay.set_script(SdfSpillOverlayScript)
		overlay.call("enable_sdf_occlusion", SDF_SPILL_SHADER)
	return overlay


func _add_world_light(light: PointLight2D) -> void:
	light.top_level = true
	world.add_child(light)


func _position_light(light: PointLight2D) -> void:
	if light == null:
		return
	if light.texture != null and light.has_meta("building_light_origin"):
		var origin: Vector2i = light.get_meta("building_light_origin")
		light.global_position = host.global_position \
			+ Vector2(light.texture.get_width(), light.texture.get_height()) * 0.5 \
			- Vector2(origin)
	else:
		light.global_position = light_base_pos
		if bool(light.get_meta("follow_lamp_offset", false)):
			light.global_position += Vector2(host.light_offset_cells()) * float(CELL)


func _apply_light_mask(node: Node, bit: int) -> void:
	if node == null:
		return
	if node is CanvasItem:
		node.light_mask = int(node.light_mask) | bit
	for child in node.get_children():
		_apply_light_mask(child, bit)


func _build_sdf_occluder() -> void:
	# 占地矩形是建筑光源自身墙体与后续场景遮挡的共同 SDF 基础。
	var occluder := LightOccluder2D.new()
	occluder.name = "BuildingLightOccluder"
	occluder.occluder_light_mask = 1
	occluder.sdf_collision = true
	var polygon := OccluderPolygon2D.new()
	var size := Vector2(footprint) * float(CELL)
	polygon.polygon = PackedVector2Array([
		Vector2.ZERO,
		Vector2(size.x, 0.0),
		size,
		Vector2(0.0, size.y),
	])
	occluder.occluder = polygon
	host.add_child(occluder)
	sdf_occluders.append(occluder)
