class_name LightingRig3D
extends Node
## Hidden 3D shadow producer for the 2.5D renderer.
## Visible gameplay is still 2D. Only proxy geometry, light visibility and
## hard shadows are rendered here, then sampled by the 2D surface shaders.

var viewport_size := Vector2i(1280, 720)
var world_center := Vector2(640.0, 384.0)
var receiver_size := Vector2(4096.0, 4096.0)
var sun_pass: Dictionary = {}
var lamp_passes: Array[Dictionary] = []
var lamp_pass: Dictionary = {}
var active_lamp_page_count := 0
var player_proxies: Array[MeshInstance3D] = []
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
	camera.far = 5000.0
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
		directional.shadow_blur = 2.2
		directional.directional_shadow_mode = \
			DirectionalLight3D.SHADOW_ORTHOGONAL
		directional.directional_shadow_max_distance = 3000.0
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
			lamp.shadow_blur = 2.0
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
		include_in_lamp_pass: bool = true) -> bool:
	if resource_path == "" or not ResourceLoader.exists(resource_path):
		push_warning("[LightingRig3D] Missing shadow proxy: %s" % resource_path)
		return false
	var packed := load(resource_path) as PackedScene
	if packed == null:
		return false
	var passes: Array = [sun_pass]
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
	player_proxies.clear()
	for pass_data in _all_passes():
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


func set_player_foot(foot_position: Vector2, height: float = 62.0) -> void:
	for proxy in player_proxies:
		if proxy != null and is_instance_valid(proxy):
			proxy.position = Vector3(
				foot_position.x,
				height * 0.5,
				foot_position.y)


func set_player_visible(visible: bool) -> void:
	for proxy in player_proxies:
		if proxy != null and is_instance_valid(proxy):
			proxy.visible = visible


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
	actor_proxies.clear()
	for pass_data in _all_passes():
		var root := pass_data.get("proxy_root") as Node3D
		if root == null:
			continue
		for child in root.get_children():
			root.remove_child(child)
			child.queue_free()


func set_camera(camera_2d: Camera2D) -> void:
	if camera_2d == null:
		return
	for pass_data in _all_passes():
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
	var light := sun_pass.get("directional") as DirectionalLight3D
	if light == null:
		return
	var light_direction := -to_sun.normalized()
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
	for index in range(active_lamp_page_count):
		var viewport := lamp_passes[index].get("viewport") as SubViewport
		if viewport != null:
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func get_sun_texture() -> Texture2D:
	var viewport := sun_pass.get("viewport") as SubViewport
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
