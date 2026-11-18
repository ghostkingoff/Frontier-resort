class_name LightingRig3D
extends Node
## Hidden 3D shadow producer for the 2.5D renderer.
## Visible gameplay is still 2D. Only proxy geometry, light visibility and
## hard shadows are rendered here, then sampled by the 2D surface shaders.

var viewport_size := Vector2i(1280, 720)
var world_center := Vector2(640.0, 384.0)
var receiver_size := Vector2(4096.0, 4096.0)
var sun_pass: Dictionary = {}
var building_sun_pass: Dictionary = {}
var lamp_passes: Array[Dictionary] = []
var lamp_pass: Dictionary = {}
var player_sun_pass: Dictionary = {}
var active_lamp_page_count := 0
var player_proxies: Array[Node3D] = []
var player_proxy_y_offset := 31.0
var player_proxy_base_yaw := 0.0
var player_facing_yaw := 0.0
var player_proxy_resource_path := ""
var player_contact_proxy: MeshInstance3D
var actor_proxies: Dictionary = {}
var pine_shadow_mesh: QuadMesh


func setup(
		target_viewport_size: Vector2i,
		target_world_center: Vector2 = Vector2(640.0, 384.0),
		target_receiver_size: Vector2 = Vector2(4096.0, 4096.0)) -> void:
	viewport_size = target_viewport_size
	world_center = target_world_center
	receiver_size = target_receiver_size
	sun_pass = _create_pass("SunShadowPass", true, false)
	building_sun_pass = _create_pass("BuildingSunShadowPass", true, false)
	player_sun_pass = _create_pass("PlayerSunShadowPass", true, false)
	var building_sun := building_sun_pass.get("directional") as DirectionalLight3D
	if building_sun != null:
		building_sun.light_angular_distance = 0.35
		building_sun.shadow_bias = 0.025
		building_sun.shadow_normal_bias = 0.7
		building_sun.shadow_blur = 2.2
	var player_sun := player_sun_pass.get("directional") as DirectionalLight3D
	if player_sun != null:
		player_sun.light_angular_distance = 0.18
		player_sun.shadow_bias = 0.012
		player_sun.shadow_normal_bias = 0.18
		player_sun.shadow_blur = 1.2
	lamp_passes.clear()
	for index in range(4):
		lamp_passes.append(_create_pass(
			"LampShadowPass_%d" % index,
			false,
			true))
	lamp_pass = lamp_passes[0]


func _create_pass(
		pass_name: String,
		with_sun: bool,
		with_lamp: bool) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = pass_name
	viewport.size = viewport_size
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	add_child(viewport)

	var world := Node3D.new()
	world.name = "ShadowWorld"
	viewport.add_child(world)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)

	var camera := Camera3D.new()
	camera.name = "ShadowCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 1.0
	camera.far = 12000.0
	camera.current = true
	world.add_child(camera)

	var plane := PlaneMesh.new()
	plane.size = receiver_size
	var receiver := MeshInstance3D.new()
	receiver.name = "ShadowReceiver"
	receiver.mesh = plane
	receiver.position = Vector3(world_center.x, -1.0, world_center.y)
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var receiver_material := StandardMaterial3D.new()
	receiver_material.albedo_color = Color.WHITE
	receiver_material.metallic = 0.0
	receiver_material.roughness = 1.0
	receiver_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	receiver.material_override = receiver_material
	world.add_child(receiver)

	var proxy_root := Node3D.new()
	proxy_root.name = "ShadowProxies"
	world.add_child(proxy_root)

	var directional: DirectionalLight3D = null
	if with_sun:
		directional = DirectionalLight3D.new()
		directional.name = "SunVisibility"
		directional.light_color = Color.WHITE
		directional.light_energy = 1.0
		directional.shadow_enabled = true
		directional.light_angular_distance = 0.9
		directional.shadow_bias = 0.035
		directional.shadow_normal_bias = 1.2
		directional.shadow_blur = 3.0
		directional.directional_shadow_mode = \
			DirectionalLight3D.SHADOW_ORTHOGONAL
		directional.directional_shadow_max_distance = 12000.0
		world.add_child(directional)

	var lamps: Array[SpotLight3D] = []
	if with_lamp:
		var channel_colors := [
			Color(1.0, 0.0, 0.0),
			Color(0.0, 1.0, 0.0),
			Color(0.0, 0.0, 1.0),
		]
		for index in range(channel_colors.size()):
			var lamp := SpotLight3D.new()
			lamp.name = "LampVisibility_%d" % index
			lamp.light_color = channel_colors[index]
			lamp.light_energy = 0.0
			lamp.spot_range = 512.0
			lamp.spot_angle = 150.0
			lamp.spot_angle_attenuation = 0.72
			lamp.spot_attenuation = 0.9
			lamp.shadow_enabled = true
			lamp.shadow_bias = 0.025
			lamp.shadow_normal_bias = 0.8
			lamp.shadow_blur = 2.6
			lamp.shadow_opacity = 0.9
			lamp.visible = false
			world.add_child(lamp)
			lamps.append(lamp)

	return {
		"viewport": viewport,
		"world": world,
		"camera": camera,
		"proxy_root": proxy_root,
		"directional": directional,
		"lamp": lamps[0] if not lamps.is_empty() else null,
		"lamps": lamps,
	}


func add_building_proxy(
		resource_path: String,
		center: Vector2,
		height_scale: float = 1.0,
		include_in_lamp_pass: bool = true,
		include_in_building_mask: bool = true) -> bool:
	if resource_path == "" or not ResourceLoader.exists(resource_path):
		push_warning("[LightingRig3D] Missing shadow proxy: %s" % resource_path)
		return false
	var packed := load(resource_path) as PackedScene
	if packed == null:
		return false
	var passes: Array = [sun_pass]
	if include_in_building_mask:
		passes.append(building_sun_pass)
	if include_in_lamp_pass:
		passes.append_array(lamp_passes)
	for pass_data in passes:
		var proxy := packed.instantiate() as Node3D
		if proxy == null:
			continue
		proxy.position = Vector3(center.x, 0.0, center.y)
		proxy.scale.y *= height_scale
		_set_shadow_only(proxy)
		(pass_data["proxy_root"] as Node3D).add_child(proxy)
	return true


func add_pine_proxy(foot_position: Vector2, height_px: float = 124.0) -> void:
	if pine_shadow_mesh == null:
		pine_shadow_mesh = QuadMesh.new()
		pine_shadow_mesh.size = Vector2(64.0, 128.0)
	for pass_data in _all_passes():
		var proxy := MeshInstance3D.new()
		proxy.name = "PineShadowProxy"
		proxy.mesh = pine_shadow_mesh
		proxy.position = Vector3(foot_position.x, 64.0, foot_position.y)
		proxy.scale = Vector3(1.0, height_px / 128.0, 1.0)
		proxy.layers = 2
		proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var material := StandardMaterial3D.new()
		material.albedo_texture = load(
			"res://art/characters/trees/pine/normal.png")
		material.albedo_color = Color.WHITE
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.3
		material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		material.roughness = 1.0
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		proxy.material_override = material
		(pass_data["proxy_root"] as Node3D).add_child(proxy)


func add_capsule_proxy(foot_position: Vector2, radius: float, height: float) -> void:
	_remove_player_contact_proxy()
	player_proxies.clear()
	player_proxy_resource_path = ""
	player_proxy_y_offset = height * 0.5
	var passes: Array = [player_sun_pass]
	passes.append_array(lamp_passes)
	for pass_data in passes:
		var proxy := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = radius
		capsule.height = height
		capsule.radial_segments = 12
		capsule.rings = 4
		proxy.mesh = capsule
		proxy.position = Vector3(foot_position.x, height * 0.5, foot_position.y)
		_set_shadow_only(proxy)
		(pass_data["proxy_root"] as Node3D).add_child(proxy)
		player_proxies.append(proxy)


func add_player_proxy(
		resource_path: String,
		foot_position: Vector2,
		target_height_px: float = 44.0) -> bool:
	player_proxies.clear()
	player_proxy_resource_path = ""
	if resource_path == "" or not ResourceLoader.exists(resource_path):
		return false
	var packed := load(resource_path) as PackedScene
	if packed == null:
		return false
	var template := packed.instantiate() as Node3D
	if template == null:
		return false
	var bounds := _mesh_bounds_under(template)
	var model_height := bounds.size.y
	if model_height <= 0.0001:
		template.free()
		return false
	var model_scale := target_height_px / model_height
	var model_y_offset := -bounds.position.y * model_scale
	player_proxy_base_yaw = template.rotation.y
	player_proxy_y_offset = model_y_offset
	template.free()
	_remove_player_contact_proxy()
	var passes: Array = [player_sun_pass]
	passes.append_array(lamp_passes)
	for pass_data in passes:
		var proxy := packed.instantiate() as Node3D
		if proxy == null:
			continue
		proxy.position = Vector3(
			foot_position.x,
			model_y_offset,
			foot_position.y)
		proxy.scale *= model_scale
		proxy.rotation.y = player_proxy_base_yaw + player_facing_yaw
		_set_shadow_only(proxy)
		(pass_data["proxy_root"] as Node3D).add_child(proxy)
		player_proxies.append(proxy)
	_add_player_contact_proxy(foot_position)
	player_proxy_resource_path = resource_path
	return not player_proxies.is_empty()


func set_player_foot(foot_position: Vector2, _height: float = 62.0) -> void:
	for proxy in player_proxies:
		if proxy != null and is_instance_valid(proxy):
			proxy.position = Vector3(
				foot_position.x,
				player_proxy_y_offset,
				foot_position.y)
	if player_contact_proxy != null and is_instance_valid(player_contact_proxy):
		player_contact_proxy.position = Vector3(
			foot_position.x,
			5.0,
			foot_position.y)


func set_player_visible(visible: bool) -> void:
	for proxy in player_proxies:
		if proxy != null and is_instance_valid(proxy):
			proxy.visible = visible
	if player_contact_proxy != null and is_instance_valid(player_contact_proxy):
		player_contact_proxy.visible = visible


func set_player_facing(facing: int) -> void:
	player_facing_yaw = match_facing_yaw(facing)
	for proxy in player_proxies:
		if proxy != null and is_instance_valid(proxy):
			proxy.rotation.y = player_proxy_base_yaw + player_facing_yaw


func match_facing_yaw(facing: int) -> float:
	match clampi(facing, 0, 3):
		0:
			return 0.0
		1:
			return PI
		2:
			return -PI * 0.5
		_:
			return PI * 0.5


func _add_player_contact_proxy(foot_position: Vector2) -> void:
	if player_sun_pass.is_empty():
		return
	var contact := MeshInstance3D.new()
	contact.name = "PlayerSunContactProxy"
	var capsule := CapsuleMesh.new()
	capsule.radius = 7.0
	capsule.height = 10.0
	capsule.radial_segments = 10
	capsule.rings = 3
	contact.mesh = capsule
	contact.position = Vector3(foot_position.x, 5.0, foot_position.y)
	_set_shadow_only(contact)
	(player_sun_pass["proxy_root"] as Node3D).add_child(contact)
	player_contact_proxy = contact


func _remove_player_contact_proxy() -> void:
	if player_contact_proxy != null and is_instance_valid(player_contact_proxy):
		player_contact_proxy.queue_free()
	player_contact_proxy = null


func _mesh_bounds_under(root: Node3D) -> AABB:
	var accumulator := [
		Vector3(INF, INF, INF),
		Vector3(-INF, -INF, -INF),
		false,
	]
	_collect_mesh_bounds(root, Transform3D.IDENTITY, accumulator)
	if not bool(accumulator[2]):
		return AABB()
	var minimum: Vector3 = accumulator[0]
	var maximum: Vector3 = accumulator[1]
	return AABB(minimum, maximum - minimum)


func _collect_mesh_bounds(
		node: Node,
		parent_transform: Transform3D,
		accumulator: Array) -> void:
	var current_transform := parent_transform
	if node is Node3D:
		current_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var bounds := mesh_instance.get_aabb()
		var minimum: Vector3 = accumulator[0]
		var maximum: Vector3 = accumulator[1]
		for endpoint in range(8):
			var point := current_transform * bounds.get_endpoint(endpoint)
			minimum = Vector3(
				minf(minimum.x, point.x),
				minf(minimum.y, point.y),
				minf(minimum.z, point.z))
			maximum = Vector3(
				maxf(maximum.x, point.x),
				maxf(maximum.y, point.y),
				maxf(maximum.z, point.z))
		accumulator[0] = minimum
		accumulator[1] = maximum
		accumulator[2] = true
	for child in node.get_children():
		_collect_mesh_bounds(child, current_transform, accumulator)


func add_actor_proxy(
		actor_id: Variant,
		foot_position: Vector2,
		radius: float = 8.0,
		height: float = 54.0) -> void:
	if actor_proxies.has(actor_id):
		return
	var nodes: Array[MeshInstance3D] = []
	for pass_data in _all_passes():
		var proxy := MeshInstance3D.new()
		proxy.name = "ActorShadow_%s" % str(actor_id)
		var capsule := CapsuleMesh.new()
		capsule.radius = radius
		capsule.height = height
		capsule.radial_segments = 10
		capsule.rings = 3
		proxy.mesh = capsule
		proxy.position = Vector3(
			foot_position.x,
			height * 0.5,
			foot_position.y)
		_set_shadow_only(proxy)
		(pass_data["proxy_root"] as Node3D).add_child(proxy)
		nodes.append(proxy)
	actor_proxies[actor_id] = {
		"nodes": nodes,
		"height": height,
	}


func set_actor_foot(actor_id: Variant, foot_position: Vector2) -> void:
	var entry: Dictionary = actor_proxies.get(actor_id, {})
	if entry.is_empty():
		return
	var height := float(entry.get("height", 54.0))
	for proxy in entry.get("nodes", []):
		if proxy != null and is_instance_valid(proxy):
			(proxy as MeshInstance3D).position = Vector3(
				foot_position.x,
				height * 0.5,
				foot_position.y)


func remove_actor_proxy(actor_id: Variant) -> void:
	var entry: Dictionary = actor_proxies.get(actor_id, {})
	for proxy in entry.get("nodes", []):
		if proxy != null and is_instance_valid(proxy):
			proxy.queue_free()
	actor_proxies.erase(actor_id)


func clear_proxies() -> void:
	player_proxies.clear()
	player_contact_proxy = null
	actor_proxies.clear()
	var passes: Array = [sun_pass, building_sun_pass]
	passes.append_array(lamp_passes)
	for pass_data in passes:
		var root := pass_data.get("proxy_root") as Node3D
		if root == null:
			continue
		for child in root.get_children():
			root.remove_child(child)
			child.queue_free()


func set_camera(camera_2d: Camera2D) -> void:
	if camera_2d == null:
		return
	var passes: Array = [sun_pass, building_sun_pass, player_sun_pass]
	passes.append_array(lamp_passes)
	for pass_data in passes:
		var camera := pass_data["camera"] as Camera3D
		camera.position = Vector3(
			camera_2d.global_position.x,
			1000.0,
			camera_2d.global_position.y)
		camera.look_at(
			Vector3(
				camera_2d.global_position.x,
				0.0,
				camera_2d.global_position.y),
			Vector3(0.0, 0.0, -1.0))
		camera.size = float(viewport_size.y) / maxf(camera_2d.zoom.y, 0.001)


func set_sun(to_sun: Vector3) -> void:
	var light_direction := -to_sun.normalized()
	var passes: Array = [sun_pass, building_sun_pass, player_sun_pass]
	for pass_data in passes:
		var light := pass_data.get("directional") as DirectionalLight3D
		if light == null:
			continue
		light.position = Vector3(0.0, 1000.0, 0.0)
		light.look_at(
			light.position + light_direction,
			Vector3(0.0, 0.0, -1.0))


func set_lamp(
		world_position: Vector2,
		height_px: float,
		range_px: float,
		active: bool) -> void:
	set_lamps([{
		"position": world_position,
		"height": height_px,
		"range": range_px,
		"active": active,
	}])


func set_lamps(light_specs: Array) -> void:
	active_lamp_page_count = clampi(
		int(ceil(float(mini(
			light_specs.size(),
			lamp_passes.size() * 3)) / 3.0)),
		0,
		lamp_passes.size())
	for page_index in range(lamp_passes.size()):
		var page_viewport := lamp_passes[page_index].get("viewport") as SubViewport
		var lamps: Array = lamp_passes[page_index].get("lamps", [])
		for channel_index in range(lamps.size()):
			var light := lamps[channel_index] as SpotLight3D
			if light == null:
				continue
			var light_index := page_index * 3 + channel_index
			if light_index >= light_specs.size():
				light.light_energy = 0.0
				light.visible = false
				continue
			var spec: Dictionary = light_specs[light_index]
			var position: Vector2 = spec.get("position", Vector2.ZERO)
			var height := float(spec.get("height", 180.0))
			var range_px := float(spec.get("range", 360.0))
			var active := bool(spec.get("active", false))
			light.position = Vector3(position.x, height, position.y)
			light.look_at(
				Vector3(position.x, 0.0, position.y),
				Vector3(0.0, 0.0, -1.0))
			light.spot_range = range_px
			light.light_energy = 1.0 if active else 0.0
			light.visible = active
		if page_viewport != null and page_index >= active_lamp_page_count:
			page_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func refresh_shadow_maps() -> void:
	var sun_viewport := sun_pass.get("viewport") as SubViewport
	if sun_viewport != null:
		sun_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var building_sun_viewport := building_sun_pass.get("viewport") as SubViewport
	if building_sun_viewport != null:
		building_sun_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var player_sun_viewport := player_sun_pass.get("viewport") as SubViewport
	if player_sun_viewport != null:
		player_sun_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for index in range(active_lamp_page_count):
		var viewport := lamp_passes[index].get("viewport") as SubViewport
		if viewport != null:
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func get_sun_texture() -> Texture2D:
	var viewport := sun_pass.get("viewport") as SubViewport
	return viewport.get_texture() if viewport != null else null


func get_building_sun_texture() -> Texture2D:
	var viewport := building_sun_pass.get("viewport") as SubViewport
	return viewport.get_texture() if viewport != null else null


func get_player_sun_texture() -> Texture2D:
	var viewport := player_sun_pass.get("viewport") as SubViewport
	return viewport.get_texture() if viewport != null else null


func get_lamp_texture(page_index: int = 0) -> Texture2D:
	if page_index < 0 or page_index >= lamp_passes.size():
		return null
	var viewport := lamp_passes[page_index].get("viewport") as SubViewport
	return viewport.get_texture() if viewport != null else null


func _all_passes() -> Array:
	var passes: Array = [sun_pass]
	passes.append_array(lamp_passes)
	return passes


func _set_shadow_only(node: Node) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		geometry.cast_shadow = \
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		geometry.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	for child in node.get_children():
		_set_shadow_only(child)
