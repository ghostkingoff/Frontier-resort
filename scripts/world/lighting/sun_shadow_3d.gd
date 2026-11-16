class_name SunShadow3D
extends Node

const PLAYER_FOOT_FALLBACK_PX := 18.0

var world: Node2D
var viewport: SubViewport
var shadow_world: Node3D
var camera_3d: Camera3D
var ground: MeshInstance3D
var directional_light: DirectionalLight3D
var proxy_root: Node3D
var player_shadow: MeshInstance3D
var wall_viewport: SubViewport
var wall_shadow_world: Node3D
var wall_camera_3d: Camera3D
var wall_ground: MeshInstance3D
var wall_directional_light: DirectionalLight3D
var wall_player_shadow: MeshInstance3D
var proxy_scenes: Dictionary = {}
var building_proxies: Dictionary = {}
var lamp_lights: Dictionary = {}
var lamp_projector_texture: ImageTexture


func setup(world_ref: Node2D) -> void:
	name = "SunShadow3D"
	world = world_ref
	_create_viewport()
	rebuild_buildings()


func _create_viewport() -> void:
	viewport = SubViewport.new()
	viewport.name = "SunShadowViewport"
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	viewport.size = Vector2i(get_viewport().get_visible_rect().size)
	add_child(viewport)

	shadow_world = Node3D.new()
	shadow_world.name = "ShadowWorld"
	viewport.add_child(shadow_world)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	shadow_world.add_child(world_environment)

	camera_3d = Camera3D.new()
	camera_3d.name = "ShadowCamera"
	camera_3d.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera_3d.keep_aspect = Camera3D.KEEP_HEIGHT
	camera_3d.near = 1.0
	camera_3d.far = 5000.0
	camera_3d.current = true
	shadow_world.add_child(camera_3d)

	var plane := PlaneMesh.new()
	var world_size := Vector2(world.grid_size * world.CELL)
	plane.size = world_size + Vector2(1024.0, 1024.0)
	ground = MeshInstance3D.new()
	ground.name = "ShadowReceiver"
	ground.mesh = plane
	ground.position = Vector3(world_size.x * 0.5, -1.0, world_size.y * 0.5)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.metallic = 0.0
	material.roughness = 1.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	ground.material_override = material
	shadow_world.add_child(ground)

	directional_light = DirectionalLight3D.new()
	directional_light.name = "Sun"
	directional_light.shadow_enabled = true
	directional_light.light_angular_distance = 0.6
	directional_light.shadow_bias = 0.04
	directional_light.shadow_normal_bias = 1.0
	directional_light.shadow_blur = 2.0
	directional_light.directional_shadow_max_distance = 6000.0
	shadow_world.add_child(directional_light)

	proxy_root = Node3D.new()
	proxy_root.name = "ShadowProxies"
	shadow_world.add_child(proxy_root)

	var player_capsule := CapsuleMesh.new()
	player_capsule.radius = 9.0
	player_capsule.height = 52.0
	player_capsule.radial_segments = 12
	player_capsule.rings = 4
	player_shadow = MeshInstance3D.new()
	player_shadow.name = "PlayerShadowPlaceholder"
	player_shadow.mesh = player_capsule
	player_shadow.position.y = 26.0
	player_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	shadow_world.add_child(player_shadow)
	_create_wall_viewport()


func _create_wall_viewport() -> void:
	wall_viewport = SubViewport.new()
	wall_viewport.name = "WallShadowViewport"
	wall_viewport.own_world_3d = true
	wall_viewport.transparent_bg = false
	wall_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	wall_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	wall_viewport.msaa_3d = Viewport.MSAA_4X
	wall_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	wall_viewport.size = Vector2i(get_viewport().get_visible_rect().size)
	add_child(wall_viewport)

	wall_shadow_world = Node3D.new()
	wall_shadow_world.name = "WallShadowWorld"
	wall_viewport.add_child(wall_shadow_world)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	wall_shadow_world.add_child(world_environment)

	wall_camera_3d = Camera3D.new()
	wall_camera_3d.name = "WallShadowCamera"
	wall_camera_3d.projection = Camera3D.PROJECTION_ORTHOGONAL
	wall_camera_3d.keep_aspect = Camera3D.KEEP_HEIGHT
	wall_camera_3d.near = 1.0
	wall_camera_3d.far = 5000.0
	wall_camera_3d.current = true
	wall_shadow_world.add_child(wall_camera_3d)

	var world_size := Vector2(world.grid_size * world.CELL)
	var plane := PlaneMesh.new()
	plane.size = world_size + Vector2(1024.0, 1024.0)
	wall_ground = MeshInstance3D.new()
	wall_ground.name = "WallShadowReceiver"
	wall_ground.mesh = plane
	wall_ground.position = Vector3(
		world_size.x * 0.5, -1.0, world_size.y * 0.5)
	wall_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.metallic = 0.0
	material.roughness = 1.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	wall_ground.material_override = material
	wall_shadow_world.add_child(wall_ground)

	wall_directional_light = DirectionalLight3D.new()
	wall_directional_light.name = "WallShadowSun"
	wall_directional_light.shadow_enabled = true
	wall_directional_light.light_angular_distance = 0.6
	wall_directional_light.shadow_bias = 0.04
	wall_directional_light.shadow_normal_bias = 1.0
	wall_directional_light.shadow_blur = 2.0
	wall_directional_light.directional_shadow_max_distance = 6000.0
	wall_shadow_world.add_child(wall_directional_light)

	var player_capsule := CapsuleMesh.new()
	player_capsule.radius = 9.0
	player_capsule.height = 52.0
	player_capsule.radial_segments = 12
	player_capsule.rings = 4
	wall_player_shadow = MeshInstance3D.new()
	wall_player_shadow.name = "WallPlayerShadowPlaceholder"
	wall_player_shadow.mesh = player_capsule
	wall_player_shadow.position.y = 26.0
	wall_player_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	wall_shadow_world.add_child(wall_player_shadow)


func rebuild_buildings() -> void:
	if proxy_root == null:
		return
	for child in proxy_root.get_children():
		proxy_root.remove_child(child)
		child.queue_free()
	building_proxies.clear()
	proxy_scenes.clear()
	for light in lamp_lights.values():
		if light != null and is_instance_valid(light):
			light.queue_free()
	lamp_lights.clear()
	for building in world.buildings:
		if building == null or not is_instance_valid(building):
			continue
		if str(building.data.get("lighting_backend", "legacy")) != "next":
			continue
		var layers: Dictionary = building.data.get("sprite_layers", {})
		var path := str(layers.get("shadow_proxy", ""))
		if path == "" or not ResourceLoader.exists(path):
			continue
		if not proxy_scenes.has(path):
			proxy_scenes[path] = load(path)
		var proxy := (proxy_scenes[path] as PackedScene).instantiate() as Node3D
		if proxy == null:
			continue
		_set_shadow_only(proxy)
		if str(building.data.get("lighting_kind", "")) == "street_lamp":
			var lamp_config: Dictionary = building.data.get("street_lamp_lighting", {})
			proxy.scale.y = float(
				lamp_config.get("shadow_proxy_height_scale", 1.0))
		var f: Array = building.data.get("footprint", [1, 1])
		var footprint := Vector2(float(f[0]) * world.CELL, float(f[1]) * world.CELL)
		var center: Vector2 = building.global_position + footprint * 0.5
		proxy.position = Vector3(center.x, 0.0, center.y)
		proxy_root.add_child(proxy)
		building_proxies[building] = proxy
	for building in world.buildings:
		if building != null and is_instance_valid(building) \
				and str(building.data.get("lighting_kind", "")) == "street_lamp":
			_create_lamp_light(building)


func _create_lamp_light(building: Building) -> void:
	var config: Dictionary = building.data.get("street_lamp_lighting", {})
	var light := SpotLight3D.new()
	light.name = "StreetLampShadowLight_%s" % building.get_instance_id()
	light.light_color = Color.from_string(
		str(config.get("color", "#ffd36a")), Color(1.0, 0.82, 0.42))
	light.light_energy = 0.0
	light.spot_range = float(config.get("spot_range_px", 140.0))
	light.spot_angle = float(config.get("spot_angle_degrees", 84.0))
	light.spot_angle_attenuation = 0.65
	light.spot_attenuation = 0.9
	light.light_projector = _get_lamp_projector_texture()
	light.shadow_enabled = true
	light.shadow_bias = 0.025
	light.shadow_normal_bias = 0.8
	light.shadow_blur = 2.0
	light.shadow_opacity = 0.82
	light.light_specular = 0.0
	light.visible = false
	shadow_world.add_child(light)
	lamp_lights[building] = light


func _get_lamp_projector_texture() -> ImageTexture:
	if lamp_projector_texture != null:
		return lamp_projector_texture
	var size := 128
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(size):
		for x in range(size):
			var normalized := Vector2(
				(float(x) + 0.5) / size * 2.0 - 1.0,
				(float(y) + 0.5) / size * 2.0 - 1.0)
			var distance := normalized.length()
			var value := 1.0 - smoothstep(0.72, 1.0, distance)
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	lamp_projector_texture = ImageTexture.create_from_image(image)
	return lamp_projector_texture


func _set_shadow_only(node: Node) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		geometry.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	for child in node.get_children():
		_set_shadow_only(child)


func get_texture() -> Texture2D:
	return viewport.get_texture() if viewport != null else null


func get_wall_shadow_texture() -> Texture2D:
	return wall_viewport.get_texture() if wall_viewport != null else null


func update_frame(
		camera_2d: Camera2D,
		to_sun: Vector3,
		sun_color: Color,
		sun_energy: float,
		projected_shadow_fade: float) -> void:
	if camera_2d == null or directional_light == null:
		return
	var viewport_size := Vector2i(get_viewport().get_visible_rect().size)
	if viewport.size != viewport_size:
		viewport.size = viewport_size
	if wall_viewport.size != viewport_size:
		wall_viewport.size = viewport_size
	var camera_position := camera_2d.global_position
	camera_3d.position = Vector3(camera_position.x, 1000.0, camera_position.y)
	camera_3d.look_at(
		Vector3(camera_position.x, 0.0, camera_position.y),
		Vector3(0.0, 0.0, -1.0))
	camera_3d.size = float(viewport_size.y) / maxf(camera_2d.zoom.y, 0.001)
	wall_camera_3d.position = camera_3d.position
	wall_camera_3d.rotation = camera_3d.rotation
	wall_camera_3d.size = camera_3d.size

	var to_sun_3d := Vector3(to_sun.x, to_sun.z, to_sun.y).normalized()
	var ray_direction := -to_sun_3d
	directional_light.position = Vector3(0.0, 1000.0, 0.0)
	directional_light.look_at(
		directional_light.position + ray_direction,
		Vector3(0.0, 0.0, -1.0))
	directional_light.light_color = sun_color
	directional_light.light_energy = sun_energy * projected_shadow_fade
	wall_directional_light.position = directional_light.position
	wall_directional_light.rotation = directional_light.rotation
	wall_directional_light.light_color = sun_color
	wall_directional_light.light_energy = sun_energy * projected_shadow_fade
	var player := world.player_avatar as Node2D
	player_shadow.visible = player != null and is_instance_valid(player) \
		and player.is_visible_in_tree()
	wall_player_shadow.visible = player_shadow.visible
	if player_shadow.visible:
		var foot_position := player_foot_world_position(player)
		player_shadow.position = Vector3(
			foot_position.x, 26.0, foot_position.y)
		wall_player_shadow.position = player_shadow.position
	update_lamp_lights(GameClock.hour_of_day())


func player_foot_world_position(player: Node2D) -> Vector2:
	if player == null or not is_instance_valid(player):
		return Vector2.ZERO
	var sprite := player.get_node_or_null("Sprite") as Sprite2D
	if sprite != null:
		return sprite.to_global(Vector2(0.0, sprite.get_rect().end.y))
	return player.global_position + Vector2(0.0, PLAYER_FOOT_FALLBACK_PX)


func update_lamp_lights(hour: float) -> void:
	for key in lamp_lights.keys():
		var building := key as Building
		var light: SpotLight3D = lamp_lights.get(key) as SpotLight3D
		if building == null or not is_instance_valid(building) \
				or light == null or not is_instance_valid(light):
			if light != null and is_instance_valid(light):
				light.queue_free()
			lamp_lights.erase(key)
			continue
		var config: Dictionary = building.data.get("street_lamp_lighting", {})
		var footprint: Array = building.data.get("footprint", [1, 1])
		var base_center: Vector2 = building.global_position + Vector2(
			float(footprint[0]) * world.CELL * 0.5,
			float(footprint[1]) * world.CELL * 0.5)
		light.position = Vector3(
			base_center.x,
			float(config.get("height_px", 44.0)),
			base_center.y)
		light.look_at(
			Vector3(base_center.x, 0.0, base_center.y),
			Vector3(0.0, 0.0, -1.0))
		var energy: float = building.lamp_energy_at(hour) \
			* float(config.get("shadow_energy", 7.0))
		light.light_energy = energy
		light.visible = energy > 0.001


func get_lamp_light(building: Building) -> SpotLight3D:
	return lamp_lights.get(building) as SpotLight3D
