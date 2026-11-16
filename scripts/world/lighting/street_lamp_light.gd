extends RefCounted
class_name StreetLampLight

const LIGHT_RADIAL := preload("res://art/generated/light_radial.png")
const GROUND_ACTOR_SHADOW_SHADER := preload(
	"res://shaders/lighting/ground_actor_shadow.gdshader")

var host
var world: Node2D
var config: Dictionary = {}
var point_light: PointLight2D
var head_glow: Sprite2D
var shadow_root: Node2D
var actor_shadow: Sprite2D
var base_center := Vector2.ZERO
var pool_radius_px := Vector2.ZERO
var energy := 0.0
var next_lighting: Node


func setup(building_host, world_ref: Node2D) -> void:
	host = building_host
	world = world_ref
	config = host.data.get("street_lamp_lighting", {})
	next_lighting = world.get_parent().get_node_or_null("NextLightingSystem")
	var color := Color.from_string(
		str(config.get("color", "#ffd36a")), Color(1.0, 0.82, 0.42))
	var radius_px := float(config.get("range_px", 156.0))

	point_light = PointLight2D.new()
	point_light.name = "StreetLampPointLight"
	point_light.texture = LIGHT_RADIAL
	point_light.texture_scale = radius_px / 128.0
	point_light.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	point_light.color = color
	point_light.energy = 0.0
	point_light.height = float(config.get("point_height_px", 18.0))
	# 玩家只走 surface shader 的法线局部受光，不接受平面光图覆盖。
	point_light.range_item_cull_mask = Building.LIGHT_LAYER_GROUND_LAMP
	point_light.shadow_enabled = false
	point_light.blend_mode = Light2D.BLEND_MODE_ADD
	point_light.top_level = true
	world.add_child(point_light)

	shadow_root = Node2D.new()
	shadow_root.name = "StreetLampGroundShadows_%s" % host.get_instance_id()
	shadow_root.z_index = 1
	world.map_layer_root.add_child(shadow_root)

	var shadow_image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	shadow_image.fill(Color.WHITE)
	actor_shadow = Sprite2D.new()
	actor_shadow.name = "PlayerGroundShadow"
	actor_shadow.texture = ImageTexture.create_from_image(shadow_image)
	actor_shadow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = GROUND_ACTOR_SHADOW_SHADER
	shadow_material.set_shader_parameter(
		"shadow_opacity", float(config.get("shadow_opacity", 0.55)))
	shadow_material.set_shader_parameter(
		"edge_softness", float(config.get("shadow_edge_softness", 0.45)))
	actor_shadow.material = shadow_material
	actor_shadow.visible = false
	shadow_root.add_child(actor_shadow)

	head_glow = Sprite2D.new()
	head_glow.name = "StreetLampHeadGlow"
	head_glow.texture = LIGHT_RADIAL
	var glow_radius := float(config.get("glow_radius_px", 13.0))
	head_glow.scale = Vector2.ONE * (
		glow_radius * 2.0 / float(LIGHT_RADIAL.get_width()))
	head_glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	head_glow.material = CanvasItemMaterial.new()
	head_glow.material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	head_glow.modulate = Color(color.r, color.g, color.b, 0.0)
	head_glow.z_index = 1
	host.roof_light_root.add_child(head_glow)
	refresh_positions()
	update(0.0)


func update(hour: float) -> void:
	energy = host.lamp_energy_at(hour)
	if point_light != null:
		var brightness_scale := 1.0
		if next_lighting != null and next_lighting.street_lamp_config is Dictionary:
			var global_config: Dictionary = next_lighting.street_lamp_config
			brightness_scale = float(global_config.get("brightness", 5.0)) / 5.0
			point_light.texture = next_lighting.get_street_lamp_pool_texture()
		point_light.energy = energy * float(
			config.get("point_energy", 0.82)) * brightness_scale
		point_light.visible = energy > 0.002
	if head_glow != null:
		head_glow.modulate.a = energy * float(config.get("glow_energy", 0.72))
		head_glow.visible = energy > 0.002
	_update_player_ground_shadow()


func refresh_positions() -> void:
	var head: Array = config.get("head_local", [16.0, -28.0])
	var head_position := Vector2(float(head[0]), float(head[1]))
	if point_light != null:
		var footprint: Array = host.data.get("footprint", [1, 1])
		base_center = host.global_position + Vector2(
			float(footprint[0]) * Building.CELL * 0.5,
			float(footprint[1]) * Building.CELL * 0.5)
		point_light.global_position = base_center
		point_light.scale = Vector2(
			float(config.get("point_pool_scale_x", 1.45)),
			float(config.get("point_pool_scale_y", 0.85)))
		pool_radius_px = Vector2(
			float(config.get("range_px", 64.0))
				* float(config.get("point_pool_scale_x", 1.45)),
			float(config.get("range_px", 64.0))
				* float(config.get("point_pool_scale_y", 0.85)))
		if actor_shadow != null and actor_shadow.material is ShaderMaterial:
			var shadow_material: ShaderMaterial = actor_shadow.material
			shadow_material.set_shader_parameter("lamp_center", base_center)
			shadow_material.set_shader_parameter("lamp_radius_px", pool_radius_px)
	if head_glow != null:
		head_glow.position = head_position


func _update_player_ground_shadow() -> void:
	if actor_shadow == null or next_lighting == null \
			or next_lighting.sun_shadow_3d == null:
		if actor_shadow != null:
			actor_shadow.visible = false
		return
	var player := world.player_avatar as Node2D
	if player == null or not is_instance_valid(player) or energy <= 0.002 \
			or (player.light_mask & 8) == 0 \
			or not player.is_visible_in_tree():
		actor_shadow.visible = false
		return
	var actor_position: Vector2 = next_lighting.sun_shadow_3d.player_foot_world_position(
		player)
	var delta := actor_position - base_center
	var normalized := Vector2(
		delta.x / maxf(pool_radius_px.x, 1.0),
		delta.y / maxf(pool_radius_px.y, 1.0))
	if normalized.length() >= 1.0:
		actor_shadow.visible = false
		return
	var proxy_width := 18.0
	var player_proxy: MeshInstance3D = next_lighting.sun_shadow_3d.player_shadow
	if player_proxy != null:
		proxy_width = maxf(player_proxy.get_aabb().size.x, 4.0)
	var distance := delta.length()
	var direction := delta / distance if distance > 0.001 else Vector2.ZERO
	var edge_distance := pool_radius_px.x
	if direction != Vector2.ZERO:
		edge_distance = 1.0 / sqrt(
			pow(direction.x / maxf(pool_radius_px.x, 1.0), 2.0)
			+ pow(direction.y / maxf(pool_radius_px.y, 1.0), 2.0))
	var distance_ratio := clampf(distance / maxf(edge_distance, 1.0), 0.0, 1.0)
	var min_length := width_for_contact_shadow(proxy_width)
	var long_axis := min_length + pow(distance_ratio, 1.15) \
		* float(config.get("shadow_max_length_px", 110.0))
	actor_shadow.visible = true
	actor_shadow.rotation = 0.0 if direction == Vector2.ZERO \
		else direction.angle() - PI * 0.5
	actor_shadow.global_position = actor_position if direction == Vector2.ZERO \
		else actor_position + direction * long_axis * 0.5
	actor_shadow.scale = Vector2(
		proxy_width / actor_shadow.texture.get_width(),
		long_axis / actor_shadow.texture.get_height())
	var shadow_material: ShaderMaterial = actor_shadow.material
	shadow_material.set_shader_parameter(
		"shadow_opacity",
		energy * float(config.get("shadow_opacity", 0.55)))


func width_for_contact_shadow(proxy_width: float) -> float:
	return maxf(proxy_width * 0.55, 2.0)


func apply_view_state(_show_interior: bool, _show_roof: bool) -> void:
	if point_light != null:
		point_light.visible = energy > 0.002
	if head_glow != null:
		head_glow.visible = energy > 0.002
	if actor_shadow != null:
		actor_shadow.visible = actor_shadow.visible and energy > 0.002


func release() -> void:
	if point_light != null and is_instance_valid(point_light):
		point_light.queue_free()
	if head_glow != null and is_instance_valid(head_glow):
		head_glow.queue_free()
	if shadow_root != null and is_instance_valid(shadow_root):
		shadow_root.queue_free()
	point_light = null
	head_glow = null
	shadow_root = null
	actor_shadow = null
