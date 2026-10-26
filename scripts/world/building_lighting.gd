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

const LIGHT_RECT := "res://art/generated/light_rect.png"
const LIGHT_RADIAL := "res://art/generated/light_radial.png"
const RECT_FLAT_RATIO := 0.667

var host
var world: Node2D
var data: Dictionary = {}
var cell := Vector2i.ZERO
var footprint := Vector2i(4, 4)
var roof_root: Node2D
var interior: Node2D

var night_light: PointLight2D
var interior_light: PointLight2D
var roof_light: PointLight2D
var spill_light: PointLight2D
var roof_light_overlay: Sprite2D
var spill_light_overlay: Sprite2D
var spill_light_overlays: Array[Sprite2D] = []
var light_on_hour := LIGHT_ON_LATEST
var light_off_hour := 0.0
var light_base_pos := Vector2.ZERO


func setup(building_host, world_ref: Node2D) -> void:
	host = building_host
	world = world_ref
	if host == null or world == null:
		return
	data = host.data
	cell = host.cell
	footprint = host.footprint
	roof_root = host.roof_root
	interior = host.interior

	if str(data.get("light_shape", "rect")) == "circle":
		_build_legacy()
		return
	_build_layered()
	if spill_light == null:
		_build_legacy()


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
	if interior_light:
		interior_light.energy = energy * LIGHT_ENERGY
	if roof_light:
		roof_light.energy = energy * LIGHT_ENERGY
	if spill_light:
		spill_light.energy = energy * LIGHT_ENERGY * 0.48
	elif night_light:
		night_light.energy = energy * LIGHT_ENERGY
	if roof_light_overlay:
		roof_light_overlay.modulate.a = energy * LIGHT_ENERGY
	if spill_light_overlay:
		spill_light_overlay.modulate.a = energy * 0.70
	for overlay in spill_light_overlays:
		overlay.modulate.a = energy * 0.70


func apply_view_state(show_interior_layer: bool, show_roof_layer: bool) -> void:
	if interior_light:
		interior_light.visible = show_interior_layer
	if roof_light:
		roof_light.visible = show_roof_layer
	if spill_light:
		spill_light.visible = true
	if roof_light_overlay:
		roof_light_overlay.visible = show_roof_layer
	if spill_light_overlay:
		spill_light_overlay.visible = true
	for overlay in spill_light_overlays:
		overlay.visible = true


func refresh_positions() -> void:
	if interior_light:
		interior_light.global_position = light_base_pos
	if roof_light:
		_position_light(roof_light)
	if spill_light:
		_position_light(spill_light)
	elif night_light:
		night_light.global_position = light_base_pos \
			+ Vector2(host.light_offset_cells()) * float(CELL)


func release() -> void:
	# 世界根节点下的灯不随建筑自动释放，拆除建筑时必须显式回收。
	var lights: Array = [interior_light, roof_light, spill_light, night_light]
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
	spill_light_overlay = null
	spill_light_overlays.clear()


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

	var layered_cfg: Dictionary = data.get("sprite_layers", {})
	var roof_origin_arr: Array = layered_cfg.get(
		"light_roof_origin", layered_cfg.get("light_origin", [0, 0]))
	var roof_origin := Vector2i(int(roof_origin_arr[0]), int(roof_origin_arr[1]))
	var spill_origin_arr: Array = layered_cfg.get(
		"light_spill_origin", layered_cfg.get("light_origin", [0, 0]))
	var spill_origin := Vector2i(int(spill_origin_arr[0]), int(spill_origin_arr[1]))
	var roof_path := str(layered_cfg.get("light_roof", ""))
	if roof_path != "" and ResourceLoader.exists(roof_path):
		roof_light = _make_texture_light(
			roof_path, warm, LIGHT_LAYER_ROOF, roof_origin)
		roof_light_overlay = _make_light_overlay(
			"RoofLightGlow", roof_path, roof_origin)
		roof_root.add_child(roof_light_overlay)
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

	var spill_path := str(layered_cfg.get("light_spill", ""))
	if spill_path != "" and ResourceLoader.exists(spill_path):
		spill_light = _make_texture_light(
			spill_path, warm, LIGHT_LAYER_SPILL, spill_origin)
		spill_light_overlays.clear()
		var guides: Array = layered_cfg.get("light_spill_guides", [])
		for index in range(guides.size()):
			var guide: Dictionary = guides[index]
			var overlay := _make_directional_overlay(
				"SpillLight%d" % index, guide, spill_origin)
			host.add_child(overlay)
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
	night_light = spill_light
	_apply_light_mask(interior, LIGHT_LAYER_INTERIOR)
	_apply_light_mask(roof_root, LIGHT_LAYER_ROOF)


func _build_legacy() -> void:
	var color := Color(1.0, 0.86, 0.62)
	if str(data.get("light_shape", "rect")) == "circle":
		night_light = _make_circle_light(
			float(data.get("light_radius_cells", 2.0)) * float(CELL), color)
	else:
		night_light = _make_rect_light(
			Vector2(footprint.x, footprint.y) * CELL,
			LIGHT_SPREAD_CELLS * float(CELL),
			color)
	if night_light == null and interior_light == null \
			and roof_light == null and spill_light == null:
		return
	night_light.name = "NightLight"
	night_light.top_level = true
	light_base_pos = world.cell_center(cell) \
		+ Vector2(float(footprint.x - 1), float(footprint.y - 1)) * CELL * 0.5
	world.add_child(night_light)
	refresh_positions()
	_configure_timing()
	var glow := float(data.get("light_glow_scale", 1.0))
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


func _apply_light_mask(node: Node, bit: int) -> void:
	if node == null:
		return
	if node is CanvasItem:
		node.light_mask = int(node.light_mask) | bit
	for child in node.get_children():
		_apply_light_mask(child, bit)
