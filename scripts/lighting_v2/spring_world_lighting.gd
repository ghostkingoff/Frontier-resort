class_name SpringWorldLighting
extends Node2D
## Main-world bridge for the new 2.5D lighting pipeline.
## Owns ambient light, sun shadows, local light selection and post grading.

const RIG_SCRIPT := preload("res://scripts/lighting_v2/lighting_rig_3d.gd")
const SURFACE_SHADER := preload("res://shaders/lighting_v2/spring_surface.gdshader")
const TILE_SHADER := preload("res://shaders/lighting_v2/spring_tile.gdshader")
const ATMOSPHERE_SHADER := preload(
	"res://shaders/lighting_v2/spring_atmosphere.gdshader")
const FOG_SHADER := preload(
	"res://shaders/lighting_v2/spring_fog.gdshader")
const LAMP_HEAD_GLOW_SHADER := preload(
	"res://shaders/lighting_v2/lamp_head_glow.gdshader")
const WINDOW_EMISSION_SHADER := preload(
	"res://shaders/lighting_v2/spring_window_emission.gdshader")
const INTERIOR_PORTAL_SHADER := preload(
	"res://shaders/lighting_v2/spring_interior_portal.gdshader")
const CONFIG_PATH := "res://data/lighting_v2/spring_clear.json"
const WINDOW_TEXTURE_SIZE := 64
const SHADOW_REGION_CELLS := 20
const SHADOW_LIGHTS_PER_REGION := 3
const MAX_SHADOW_LIGHTS := 12
const MAX_LOCAL_LIGHTS := 32
const PLAYER_SHADOW_PROXY_PATH := \
	"res://art/characters/player/star2a/shadow_proxy.glb"
const PLAYER_SHADOW_HEIGHT_PX := 44.0
const WINDOW_HEAD_OPACITY := 0.3
const LAMP_HEAD_OPACITY := 0.12
const LAMP_HEAD_BRIGHTNESS := 0.18

var world: Node2D
var camera: Camera2D
var config: Dictionary = {}
var rig: LightingRig3D
var ground_materials: Array[ShaderMaterial] = []
var surface_materials: Array[ShaderMaterial] = []
var surface_meta: Dictionary = {}
var building_materials: Dictionary = {}
var interior_materials: Dictionary = {}
var portal_entries: Dictionary = {}
var lamp_glows: Dictionary = {}
var post_material: ShaderMaterial
var fog_layer: CanvasLayer
var fog_rect: ColorRect
var fog_material: ShaderMaterial
var player_material: ShaderMaterial
var _player_surface_mode := ""
var _player_atlas_frame_uv := Vector4(-1.0, -1.0, 0.0, 0.0)
var player_normal_disabled := false
var player_specular_disabled := false
var player_occlusion_disabled := false
var player_smooth_normal_enabled := false
var player_shared_atlas_uv := true
var region_debug_root: Node2D
var use_sun_screen_override := false
var sun_screen_override := Vector3.ZERO

var neutral_normal: ImageTexture
var neutral_specular: ImageTexture
var neutral_occlusion: ImageTexture
var flat_black: ImageTexture
var radial_texture: ImageTexture
var window_texture: ImageTexture
var lighting_tuning: Dictionary = {}
var last_shadow_key := ""
var last_player_foot := Vector2(-INF, -INF)
var debug_mode := 0
var zone_shadow_history: Dictionary = {}
var global_shadow_history: Array[Building] = []
var _fog_time := 0.0


func _ready() -> void:
	name = "SpringWorldLighting"
	process_priority = 50
	get_viewport().use_hdr_2d = true
	world = get_tree().get_first_node_in_group("world")
	if world == null:
		push_error("[SpringWorldLighting] World not found")
		return
	config = _read_json(CONFIG_PATH)
	_reset_lighting_tuning()
	_make_neutral_textures()
	camera = get_viewport().get_camera_2d()
	if camera == null:
		camera = get_parent().get_node_or_null("Camera") as Camera2D
	_create_shadow_rig()
	_setup_ground_materials()
	_create_fog_layer()
	_create_atmosphere()
	_create_region_debug_grid()
	_setup_pines()
	_setup_player_material()
	for building in world.buildings:
		_setup_building(building)
	world.building_placed.connect(_on_building_placed)
	world.building_removed.connect(_on_building_removed)
	_rebuild_proxies()
	set_process(true)


func _process(delta: float) -> void:
	if world == null or rig == null:
		return
	var hour := GameClock.hour_of_day()
	var state := _sample_light_state(hour)
	var sun_screen := _sun_to_screen_direction(hour)
	var sun_3d := Vector3(
		sun_screen.x,
		sun_screen.z,
		sun_screen.y).normalized()
	var lamp_state := _update_lamp_state(
		hour,
		float(state["sun_energy"]))
	var player_foot := _player_foot_position()
	var player_shadow_foot := Vector2(
		roundf(player_foot.x),
		roundf(player_foot.y))

	camera = get_viewport().get_camera_2d()
	if camera != null:
		rig.set_camera(camera)
	rig.set_sun(sun_3d)
	var shadow_lights: Array = []
	for shadow_index in range(int(lamp_state.get("shadow_count", 0))):
		var light: Dictionary = lamp_state["lights"][shadow_index]
		shadow_lights.append({
			"position": light["position"],
			"height": float(light["shadow_height"]),
			"range": float(light["shadow_range"]),
			"active": true,
		})
	rig.set_lamps(shadow_lights)
	var actor_signature := _sync_actor_proxies()
	if player_shadow_foot != last_player_foot:
		rig.set_player_foot(player_shadow_foot)
		last_player_foot = player_shadow_foot
	var player: Node2D = world.player_avatar as Node2D
	rig.set_player_visible(
		player != null
		and is_instance_valid(player)
		and player.is_visible_in_tree()
		and not bool(player.inside_reception))
	if player != null:
		rig.set_player_facing(int(player.get("_facing")))

	var shadow_key := _shadow_state_key(
		sun_screen,
		lamp_state,
		player_shadow_foot) + "|" + actor_signature
	if shadow_key != last_shadow_key:
		rig.refresh_shadow_maps()
		last_shadow_key = shadow_key

	_sync_player_surface()
	_update_surface_parameters(state, sun_screen, lamp_state, delta)
	_update_window_effects(state, sun_screen, hour)
	_update_fog(hour, delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F1:
		set_debug_mode((debug_mode + 1) % 12)
		get_viewport().set_input_as_handled()


func set_debug_mode(value: int) -> void:
	debug_mode = clampi(value, 0, 11)
	_apply_debug_mode()


func set_sun_screen_override(value: Vector3) -> void:
	use_sun_screen_override = value.length_squared() > 0.000001
	sun_screen_override = value.normalized() \
		if use_sun_screen_override else Vector3.ZERO
	last_shadow_key = ""


func clear_sun_screen_override() -> void:
	use_sun_screen_override = false
	sun_screen_override = Vector3.ZERO
	last_shadow_key = ""


func _apply_debug_mode() -> void:
	for material in ground_materials:
		material.set_shader_parameter("debug_mode", debug_mode)
	for material in surface_materials:
		material.set_shader_parameter("debug_mode", debug_mode)
	if region_debug_root != null:
		region_debug_root.visible = debug_mode == 11


func _create_region_debug_grid() -> void:
	region_debug_root = Node2D.new()
	region_debug_root.name = "RegionDebugGrid"
	region_debug_root.z_index = 4000
	region_debug_root.visible = false
	add_child(region_debug_root)
	var world_size: Vector2 = world.world_size()
	for x in range(0, int(world_size.x) + 1, SHADOW_REGION_CELLS * 32):
		var line := Line2D.new()
		line.width = 2.0
		line.default_color = Color(0.22, 1.0, 0.42, 0.62)
		line.points = PackedVector2Array([
			Vector2(float(x), 0.0),
			Vector2(float(x), world_size.y),
		])
		region_debug_root.add_child(line)
	for y in range(0, int(world_size.y) + 1, SHADOW_REGION_CELLS * 32):
		var line := Line2D.new()
		line.width = 2.0
		line.default_color = Color(0.22, 1.0, 0.42, 0.62)
		line.points = PackedVector2Array([
			Vector2(0.0, float(y)),
			Vector2(world_size.x, float(y)),
		])
		region_debug_root.add_child(line)


func _create_shadow_rig() -> void:
	rig = RIG_SCRIPT.new()
	rig.name = "LightingRig3D"
	add_child(rig)
	var viewport_size := Vector2i(get_viewport().get_visible_rect().size)
	var scene_size: Vector2 = world.world_size()
	rig.setup(
		viewport_size,
		scene_size * 0.5,
		scene_size + Vector2(4096.0, 4096.0))
	if camera != null:
		rig.set_camera(camera)


func _setup_ground_materials() -> void:
	var grass_wild := _make_tile_material(
		"res://art/characters/ground/grass_wild/normal.png",
		"res://art/characters/ground/grass_wild/specular.png",
		"res://art/characters/ground/grass_wild/occlusion.png",
		1.10,
		0.28,
		0.84)
	var grass_trimmed := _make_tile_material(
		"res://art/characters/ground/grass_trimmed/normal.png",
		"res://art/characters/ground/grass_trimmed/specular.png",
		"res://art/characters/ground/grass_trimmed/occlusion.png",
		1.10,
		0.28,
		0.84)
	var stone := _make_tile_material(
		"res://art/characters/ground/tiles/stone_normal.png",
		"res://art/characters/ground/tiles/stone_specular.png",
		"res://art/characters/ground/tiles/stone_occlusion.png",
		0.92,
		0.42,
		0.78)
	var fallback := _make_tile_material_from_textures(
		neutral_normal,
		neutral_specular,
		neutral_occlusion,
		0.4,
		0.1,
		0.4)
	world.ground.material = grass_wild
	world.ground_lawn.material = grass_trimmed
	world.ground_path.material = stone
	world.ground_misc.material = fallback


func _make_tile_material(
		normal_path: String,
		specular_path: String,
		occlusion_path: String,
		normal_amount: float,
		specular_amount: float,
		occlusion_amount: float) -> ShaderMaterial:
	return _make_tile_material_from_textures(
		load(normal_path),
		load(specular_path),
		load(occlusion_path),
		normal_amount,
		specular_amount,
		occlusion_amount)


func _make_tile_material_from_textures(
		normal_texture: Texture2D,
		specular_texture: Texture2D,
		occlusion_texture: Texture2D,
		normal_amount: float,
		specular_amount: float,
		occlusion_amount: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = TILE_SHADER
	material.set_shader_parameter("normal_texture", normal_texture)
	material.set_shader_parameter("specular_texture", specular_texture)
	material.set_shader_parameter("occlusion_texture", occlusion_texture)
	material.set_shader_parameter(
		"sun_shadow_texture", rig.get_sun_texture())
	material.set_shader_parameter(
		"player_sun_shadow_texture", rig.get_player_sun_texture())
	material.set_shader_parameter(
		"lamp_shadow_texture_0", rig.get_lamp_texture(0))
	material.set_shader_parameter(
		"lamp_shadow_texture_1", rig.get_lamp_texture(1))
	material.set_shader_parameter(
		"lamp_shadow_texture_2", rig.get_lamp_texture(2))
	material.set_shader_parameter(
		"lamp_shadow_texture_3", rig.get_lamp_texture(3))
	material.set_shader_parameter("normal_strength", normal_amount)
	material.set_shader_parameter("specular_strength", specular_amount)
	material.set_shader_parameter("occlusion_strength", occlusion_amount)
	ground_materials.append(material)
	return material


func _create_atmosphere() -> void:
	var layer := CanvasLayer.new()
	layer.name = "SpringAtmosphere"
	layer.layer = 5
	add_child(layer)
	var rect := ColorRect.new()
	rect.name = "SpringGrade"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_material = ShaderMaterial.new()
	post_material.shader = ATMOSPHERE_SHADER
	rect.material = post_material
	layer.add_child(rect)


func _create_fog_layer() -> void:
	fog_layer = CanvasLayer.new()
	fog_layer.name = "SpringFog"
	fog_layer.layer = 4
	fog_layer.visible = false
	add_child(fog_layer)
	fog_rect = ColorRect.new()
	fog_rect.name = "NoiseDepthFog"
	fog_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fog_material = ShaderMaterial.new()
	fog_material.shader = FOG_SHADER
	fog_material.set_shader_parameter(
		"noise_texture",
		load("res://art/generated/lighting_v2/fog_density.png"))
	fog_material.set_shader_parameter(
		"depth_texture",
		load("res://art/generated/lighting_v2/fog_depth.png"))
	fog_rect.material = fog_material
	fog_layer.add_child(fog_rect)


func _setup_pines() -> void:
	for node in get_tree().get_nodes_in_group("lighting_pines"):
		var root := node as Node2D
		if root == null:
			continue
		var sprite := root.get_node_or_null("PineSurface") as Sprite2D
		if sprite == null:
			continue
		sprite.material = _make_surface_material(
			"res://art/characters/trees/pine/normal.png",
			"res://art/characters/trees/pine/specular.png",
			"res://art/characters/trees/pine/occlusion.png",
			true,
			false,
			1.0,
			128.0,
			0.86,
			0.2,
			0.78)


func _setup_player_material() -> void:
	var player = world.get("player_avatar")
	if player == null or player.sprite == null:
		return
	player_material = _make_surface_material(
		"res://art/characters/player/star2a/idle_n.png",
		"res://art/characters/player/star2a/idle_s.png",
		"res://art/characters/player/star2a/idle_o.png",
		true,
		false,
		1.0,
		144.0,
		0.9,
		0.42,
		0.72)
	player.surface_material = player_material
	player.sprite.material = player_material
	player_material.set_shader_parameter("use_nearest_surface", true)
	player_material.set_shader_parameter(
		"apply_character_facing_gate",
		true)
	player_material.set_shader_parameter(
		"character_shadow_transition_px",
		48.0)
	player_material.set_shader_parameter(
		"character_sun_transition",
		0.08)
	player_material.set_shader_parameter(
		"ignore_self_projected_shadow",
		true)
	_sync_player_surface()


func _sync_player_surface() -> void:
	var player = world.get("player_avatar")
	if player == null or player.sprite == null or player_material == null:
		return
	var use_walk := bool(player.get("_using_walk_surface"))
	var prefix := "walk" if use_walk else "idle"
	var base := "res://art/characters/player/star2a/"
	if _player_surface_mode != prefix:
		_player_surface_mode = prefix
		var normal_path := base + prefix + (
			"_n_smooth.png" if player_smooth_normal_enabled else "_n.png")
		if not ResourceLoader.exists(normal_path):
			normal_path = base + prefix + "_n.png"
		var normal_map: Texture2D = neutral_normal if player_normal_disabled \
			else load(normal_path) as Texture2D
		var specular_map: Texture2D = flat_black if player_specular_disabled \
			else load(base + prefix + "_s.png") as Texture2D
		var occlusion_map: Texture2D = neutral_occlusion if player_occlusion_disabled \
			else load(base + prefix + "_o.png") as Texture2D
		player_material.set_shader_parameter(
			"normal_texture", normal_map)
		player_material.set_shader_parameter(
			"specular_texture", specular_map)
		player_material.set_shader_parameter(
			"occlusion_texture", occlusion_map)
		player_material.set_shader_parameter(
			"normal_texture_nearest", normal_map)
		player_material.set_shader_parameter(
			"specular_texture_nearest", specular_map)
		player_material.set_shader_parameter(
			"occlusion_texture_nearest", occlusion_map)
	var columns := maxi(player.sprite.hframes, 1)
	var rows := maxi(player.sprite.vframes, 1)
	var column: int = player.sprite.frame % columns
	var row := int(player.sprite.frame / columns)
	var frame_uv := Vector4(
		float(column) / float(columns),
		float(row) / float(rows),
		1.0 / float(columns),
		1.0 / float(rows))
	if frame_uv != _player_atlas_frame_uv:
		_player_atlas_frame_uv = frame_uv
		player_material.set_shader_parameter("atlas_frame_uv", frame_uv)
	player_material.set_shader_parameter(
		"use_shared_atlas_uv",
		player_shared_atlas_uv)
	var foot := _player_foot_position()
	player_material.set_shader_parameter(
		"character_facing_anchor_world",
		foot)
	player_material.set_shader_parameter(
		"self_shadow_world_rect",
		_player_surface_world_rect(player.sprite))


func set_player_surface_map_disabled(map_kind: String, disabled: bool) -> void:
	match map_kind:
		"normal":
			player_normal_disabled = disabled
		"specular":
			player_specular_disabled = disabled
		"occlusion":
			player_occlusion_disabled = disabled
		_:
			push_warning("[SpringWorldLighting] 未知角色材质开关：%s" % map_kind)
			return
	_player_surface_mode = ""
	_sync_player_surface()


func is_player_surface_map_disabled(map_kind: String) -> bool:
	match map_kind:
		"normal":
			return player_normal_disabled
		"specular":
			return player_specular_disabled
		"occlusion":
			return player_occlusion_disabled
	return false


func set_player_smooth_normal_enabled(enabled: bool) -> void:
	player_smooth_normal_enabled = enabled
	_player_surface_mode = ""
	_sync_player_surface()


func set_player_shared_atlas_uv(enabled: bool) -> void:
	player_shared_atlas_uv = enabled
	if player_material != null:
		player_material.set_shader_parameter(
			"use_shared_atlas_uv",
			player_shared_atlas_uv)


func reset_player_surface_map_disables() -> void:
	player_normal_disabled = false
	player_specular_disabled = false
	player_occlusion_disabled = false
	player_smooth_normal_enabled = false
	player_shared_atlas_uv = true
	_player_surface_mode = ""
	_sync_player_surface()


func player_surface_disables_snapshot() -> Dictionary:
	return {
		"normal_disabled": player_normal_disabled,
		"specular_disabled": player_specular_disabled,
		"occlusion_disabled": player_occlusion_disabled,
		"smooth_normal_enabled": player_smooth_normal_enabled,
		"shared_atlas_uv": player_shared_atlas_uv,
	}


func _setup_building(building: Building) -> void:
	if building == null or not is_instance_valid(building):
		return
	var materials: Array[ShaderMaterial] = []
	var layers: Dictionary = building.data.get("sprite_layers", {})
	if building.wall_texture != null:
		var wall_material := _make_building_surface_material(
			building,
			layers,
			"wall",
			true)
		building.wall_texture.material = wall_material
		materials.append(wall_material)
	if building.roof_texture != null:
		var roof_material := _make_building_surface_material(
			building,
			layers,
			"roof",
			false)
		building.roof_texture.material = roof_material
		materials.append(roof_material)

	if layers.is_empty():
		for node in [
			building.exterior,
			building.front_face,
			building.side_face,
			building.roof_face,
		]:
			if node is Sprite2D and node.material == null:
				var fallback := _make_fallback_surface_material()
				(node as Sprite2D).material = fallback
				materials.append(fallback)

	if building.interior_texture != null:
		var interior := _make_fallback_surface_material()
		building.interior_texture.material = interior
		materials.append(interior)
		interior_materials[building] = interior
	if building.ground_terrain != null:
		var terrain_material := _make_terrain_ground_material(layers)
		building.ground_terrain.material = terrain_material
		ground_materials.append(terrain_material)

	building_materials[building] = materials
	_ensure_lamp_glow(building)
	_setup_window_effects(building, layers)


func _make_terrain_ground_material(layers: Dictionary) -> ShaderMaterial:
	var normal_path := str(layers.get("ground_normal", ""))
	var specular_path := str(layers.get("ground_specular", ""))
	var occlusion_path := str(layers.get("ground_occlusion", ""))
	return _make_tile_material_from_textures(
		load(normal_path) if normal_path != "" \
			and ResourceLoader.exists(normal_path) else neutral_normal,
		load(specular_path) if specular_path != "" \
			and ResourceLoader.exists(specular_path) else neutral_specular,
		load(occlusion_path) if occlusion_path != "" \
			and ResourceLoader.exists(occlusion_path) else neutral_occlusion,
		1.10,
		0.28,
		0.84)


func _make_building_surface_material(
		building: Building,
		layers: Dictionary,
		prefix: String,
		receives_projection: bool) -> ShaderMaterial:
	var normal_path := str(layers.get(prefix + "_normal", ""))
	var specular_path := str(layers.get(prefix + "_specular", ""))
	var occlusion_path := str(layers.get(prefix + "_occlusion", ""))
	if normal_path == "":
		return _make_fallback_surface_material()
	var canvas: Array = layers.get("canvas", [256, 256])
	var canvas_height := float(canvas[1])
	var origin: Array = layers.get("origin", [0, 0])
	var fallback_foot_y := float(origin[1]) \
		+ float(building.footprint.y) * 32.0 - 6.0
	var foot_y := float(layers.get(
		"wall_foot_y_px",
		fallback_foot_y))
	var wall_region: Array = layers.get("wall_region_px", [])
	if prefix == "wall" and wall_region.size() >= 4:
		foot_y = float(wall_region[1]) + float(wall_region[3])
	var material := _make_surface_material(
		normal_path,
		specular_path,
		occlusion_path,
		true,
		receives_projection,
		foot_y / maxf(canvas_height, 1.0),
		canvas_height,
		0.88,
		0.3,
		0.72)
	var facing_array: Array = layers.get("wall_facing_normal", [0.0, 1.0])
	var facing_normal := Vector2(
		float(facing_array[0]) if facing_array.size() > 0 else 0.0,
		float(facing_array[1]) if facing_array.size() > 1 else 1.0)
	var is_wall := prefix == "wall" and receives_projection
	var apply_gate := is_wall \
		and str(building.data.get("lighting_kind", "")) != "street_lamp"
	material.set_shader_parameter("wall_facing_normal", facing_normal)
	material.set_shader_parameter("apply_wall_facing_gate", apply_gate)
	var wall_softness := float(layers.get(
		"wall_facing_softness",
		config.get("sun", {}).get("wall_facing_softness", 0.08)))
	material.set_shader_parameter(
		"wall_facing_softness",
		clampf(wall_softness, 0.001, 0.25))
	material.set_shader_parameter("apply_wall_shadow_projection", is_wall)
	material.set_shader_parameter(
		"wall_shadow_rect_uv",
		Vector4(0.0, 0.0, 1.0, 1.0))
	material.set_shader_parameter("apply_player_sun_shadow", is_wall)
	material.set_shader_parameter(
		"player_wall_shadow_height_px",
		PLAYER_SHADOW_HEIGHT_PX)
	surface_meta[material] = {
		"building": building,
		"is_building_surface": true,
		"is_wall": is_wall,
		"apply_wall_facing_gate": apply_gate,
	}
	return material


func _make_surface_material(
		normal_path: String,
		specular_path: String,
		occlusion_path: String,
		clip_normal_alpha: bool,
		receives_projection: bool,
		foot_uv_y: float,
		canvas_height: float,
		normal_amount: float,
		specular_amount: float,
		occlusion_amount: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	var normal_map: Texture2D = load(normal_path)
	var specular_map: Texture2D = load(specular_path)
	var occlusion_map: Texture2D = load(occlusion_path)
	material.set_shader_parameter("normal_texture", normal_map)
	material.set_shader_parameter("specular_texture", specular_map)
	material.set_shader_parameter("occlusion_texture", occlusion_map)
	material.set_shader_parameter("normal_texture_nearest", normal_map)
	material.set_shader_parameter("specular_texture_nearest", specular_map)
	material.set_shader_parameter("occlusion_texture_nearest", occlusion_map)
	material.set_shader_parameter(
		"sun_shadow_texture", rig.get_sun_texture())
	material.set_shader_parameter(
		"building_sun_shadow_texture", rig.get_building_sun_texture())
	material.set_shader_parameter(
		"player_sun_shadow_texture", rig.get_player_sun_texture())
	material.set_shader_parameter("apply_player_sun_shadow", false)
	material.set_shader_parameter(
		"lamp_shadow_texture_0", rig.get_lamp_texture(0))
	material.set_shader_parameter(
		"lamp_shadow_texture_1", rig.get_lamp_texture(1))
	material.set_shader_parameter(
		"lamp_shadow_texture_2", rig.get_lamp_texture(2))
	material.set_shader_parameter(
		"lamp_shadow_texture_3", rig.get_lamp_texture(3))
	material.set_shader_parameter("clip_to_normal_alpha", clip_normal_alpha)
	material.set_shader_parameter(
		"receive_projected_shadow", receives_projection)
	material.set_shader_parameter("surface_foot_uv_y", foot_uv_y)
	material.set_shader_parameter("canvas_height_px", canvas_height)
	material.set_shader_parameter("normal_strength", normal_amount)
	material.set_shader_parameter("specular_strength", specular_amount)
	material.set_shader_parameter("occlusion_strength", occlusion_amount)
	surface_materials.append(material)
	return material


func _make_fallback_surface_material() -> ShaderMaterial:
	return _make_surface_material_from_textures(
		neutral_normal,
		neutral_specular,
		neutral_occlusion,
		false,
		false,
		1.0,
		256.0,
		0.2,
		0.05,
		0.35)


func _make_surface_material_from_textures(
		normal_texture: Texture2D,
		specular_texture: Texture2D,
		occlusion_texture: Texture2D,
		clip_normal_alpha: bool,
		receives_projection: bool,
		foot_uv_y: float,
		canvas_height: float,
		normal_amount: float,
		specular_amount: float,
		occlusion_amount: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter("normal_texture", normal_texture)
	material.set_shader_parameter("specular_texture", specular_texture)
	material.set_shader_parameter("occlusion_texture", occlusion_texture)
	material.set_shader_parameter("normal_texture_nearest", normal_texture)
	material.set_shader_parameter("specular_texture_nearest", specular_texture)
	material.set_shader_parameter("occlusion_texture_nearest", occlusion_texture)
	material.set_shader_parameter(
		"sun_shadow_texture", rig.get_sun_texture())
	material.set_shader_parameter(
		"building_sun_shadow_texture", rig.get_building_sun_texture())
	material.set_shader_parameter(
		"player_sun_shadow_texture", rig.get_player_sun_texture())
	material.set_shader_parameter("apply_player_sun_shadow", false)
	material.set_shader_parameter(
		"lamp_shadow_texture_0", rig.get_lamp_texture(0))
	material.set_shader_parameter(
		"lamp_shadow_texture_1", rig.get_lamp_texture(1))
	material.set_shader_parameter(
		"lamp_shadow_texture_2", rig.get_lamp_texture(2))
	material.set_shader_parameter(
		"lamp_shadow_texture_3", rig.get_lamp_texture(3))
	material.set_shader_parameter("clip_to_normal_alpha", clip_normal_alpha)
	material.set_shader_parameter(
		"receive_projected_shadow", receives_projection)
	material.set_shader_parameter("surface_foot_uv_y", foot_uv_y)
	material.set_shader_parameter("canvas_height_px", canvas_height)
	material.set_shader_parameter("normal_strength", normal_amount)
	material.set_shader_parameter("specular_strength", specular_amount)
	material.set_shader_parameter("occlusion_strength", occlusion_amount)
	surface_materials.append(material)
	return material


func _ensure_lamp_glow(building: Building) -> void:
	if building == null or not is_instance_valid(building):
		return
	if str(building.data.get("lighting_kind", "")) != "street_lamp":
		return
	if lamp_glows.has(building):
		return
	if building.roof_root == null and building.roof_light_root == null:
		return
	var lamp_config: Dictionary = building.data.get(
		"street_lamp_lighting", {})
	var glow := Sprite2D.new()
	glow.name = "NewLightingLampGlow"
	glow.texture = radial_texture
	var head: Array = lamp_config.get("head_local", [15.5, -25.5])
	glow.position = Vector2(float(head[0]), float(head[1]))
	var radius := float(lamp_config.get("glow_radius_px", 12.0))
	glow.scale = Vector2.ONE * maxf(radius * 2.0 / 128.0, 0.05)
	glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var glow_material := ShaderMaterial.new()
	glow_material.shader = LAMP_HEAD_GLOW_SHADER
	glow_material.set_shader_parameter(
		"glow_color",
		Color.from_string(
			str(lamp_config.get("color", "#ffd36a")),
			Color("#ffd36a")))
	glow_material.set_shader_parameter("opacity", 0.0)
	glow_material.set_shader_parameter(
		"brightness",
		LAMP_HEAD_BRIGHTNESS)
	glow.material = glow_material
	glow.modulate = Color.WHITE
	glow.z_index = 2
	var display_parent := building.roof_root \
		if building.roof_root != null else building.roof_light_root
	display_parent.add_child(glow)
	if building.roof_root != null and building.roof_texture != null:
		building.roof_root.move_child(
			glow,
			building.roof_texture.get_index())
	lamp_glows[building] = glow


func _window_lamp_light_style() -> Dictionary:
	var lamp_data: Dictionary = DataRegistry.get_building("street_lamp")
	var lamp_config: Dictionary = lamp_data.get("street_lamp_lighting", {})
	return {
		"color": Color.from_string(
			str(lamp_config.get("color", "#ffd36a")),
			Color("#ffd36a")),
		"head_energy": float(lamp_config.get("glow_energy", 1.0))
			* float(lighting_tuning.get(
				"window_head_opacity",
				WINDOW_HEAD_OPACITY))
			* float(lighting_tuning.get("window_head_brightness", 1.0)),
		"spill_range_px": maxf(
			float(lighting_tuning.get(
				"window_ground_range_px",
				17.5)),
			1.0),
		"spill_energy": float(lamp_config.get("player_energy", 2.6))
			* float(lighting_tuning.get(
				"window_ground_energy_ratio",
				0.09)),
		"spill_height_px": float(lamp_config.get("height_px", 44.0)),
	}


func _reset_lighting_tuning() -> void:
	var lamp_config: Dictionary = DataRegistry.get_building(
		"street_lamp").get("street_lamp_lighting", {})
	var lamp_range := maxf(float(lamp_config.get("range_px", 64.0)), 1.0)
	var defaults := {
		"window_head_opacity": WINDOW_HEAD_OPACITY,
		"window_head_brightness": 1.0,
		"window_ground_energy_ratio": 0.09,
		"window_ground_range_px": 17.5,
		"window_ground_attenuation_multiplier": 1.75,
		"window_ground_attenuation_curve": 2.0,
		"lamp_head_opacity": LAMP_HEAD_OPACITY,
		"lamp_head_brightness": LAMP_HEAD_BRIGHTNESS,
		"lamp_ground_energy_scale": 1.0,
		"lamp_ground_range_px": lamp_range,
		"lamp_ground_attenuation_multiplier": 2.0,
		"lamp_ground_falloff_power": 4.0,
		"lamp_ground_ellipse_height_ratio": 1.0 / sqrt(2.0),
	}
	var configured: Dictionary = config.get("lighting_tuning", {})
	for key in defaults.keys():
		if configured.has(key):
			defaults[key] = float(configured[key])
	lighting_tuning = defaults
	last_shadow_key = ""


func set_lighting_tuning(key: String, value: float) -> void:
	if not lighting_tuning.has(key):
		push_warning("[SpringWorldLighting] 未知光照调参项：%s" % key)
		return
	lighting_tuning[key] = maxf(value, 0.0)
	last_shadow_key = ""


func get_lighting_tuning() -> Dictionary:
	return lighting_tuning.duplicate(true)


func lighting_tuning_snapshot() -> Dictionary:
	var tuning := get_lighting_tuning()
	var lamp_config: Dictionary = DataRegistry.get_building(
		"street_lamp").get("street_lamp_lighting", {})
	var lamp_local_energy := float(lamp_config.get("player_energy", 2.6))
	return {
		"build_marker": "LIGHTING BUILD 2026-11-13-RGB-FOG-SUN-V3",
		"captured_at": Time.get_datetime_string_from_system(),
		"game_day": GameState.day,
		"game_time": GameClock.time_text(),
		"player_surface_disables": player_surface_disables_snapshot(),
		"settings": tuning,
		"derived": {
			"window_ground_energy": lamp_local_energy * float(
				tuning["window_ground_energy_ratio"]),
			"window_attenuation_range_px": float(
				tuning["window_ground_range_px"])
				* float(tuning["window_ground_attenuation_multiplier"]),
			"lamp_attenuation_range_px": float(
				tuning["lamp_ground_range_px"])
				* float(tuning["lamp_ground_attenuation_multiplier"]),
			"lamp_ellipse_width_height_ratio": 1.0 / maxf(
				float(tuning["lamp_ground_ellipse_height_ratio"]),
				0.001),
		},
	}


func _collect_window_light_candidates(
		hour: float,
		sun_energy: float,
		reference: Vector2) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var night_factor := 1.0 - smoothstep(0.03, 0.35, sun_energy)
	if night_factor <= 0.001:
		return result
	var window_light := _window_lamp_light_style()
	var light_color: Color = window_light["color"]
	var light_range := float(window_light["spill_range_px"])
	var light_height := float(window_light["spill_height_px"])
	var light_energy := float(window_light["spill_energy"])
	for building_key in portal_entries.keys():
		var building := building_key as Building
		if building == null or not is_instance_valid(building) \
				or not building.is_open_at(hour):
			continue
		var entry: Dictionary = portal_entries.get(building, {})
		var sprites: Array = entry.get("emission_sprites", [])
		var portals: Array = entry.get("emission_portals", [])
		for index in range(mini(sprites.size(), portals.size())):
			var window_sprite := sprites[index] as Sprite2D
			if window_sprite == null:
				continue
			var portal: Dictionary = portals[index]
			var leak_strength := maxf(
				float(portal.get("leak_strength", 1.0)),
				0.0)
			if leak_strength <= 0.001:
				continue
			var position := window_sprite.global_position
			var camera_distance := reference.distance_to(position)
			result.append({
				"building": building,
				"distance": camera_distance,
				"camera_score": light_energy * leak_strength \
					/ (1.0 + camera_distance / 1800.0),
				"position": position,
				"height": light_height,
				"range": light_range,
				"attenuation_range": light_range * float(
					lighting_tuning.get(
						"window_ground_attenuation_multiplier",
						2.0)),
				"attenuation_power": 4.0,
				"attenuation_curve": float(lighting_tuning.get(
					"window_ground_attenuation_curve",
					2.0)),
				"ground_ellipse_aspect": 1.0,
				"color": light_color,
				"energy": night_factor * leak_strength * light_energy,
				"window_light": true,
			})
	return result


func _setup_window_effects(building: Building, layers: Dictionary) -> void:
	if portal_entries.has(building):
		return
	var portal_path := str(layers.get("portal_config", ""))
	if portal_path == "" or not FileAccess.file_exists(portal_path):
		return
	var document: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(portal_path))
	if document is not Dictionary:
		return
	var groups: Dictionary = document.get("interior_light_groups", {})
	var source_portals: Array = []
	for portal in document.get("portals", []):
		if str(portal.get("type", "")) not in ["window", "glass_door"]:
			continue
		if not groups.has(str(portal.get("interior_light_group", ""))):
			continue
		source_portals.append(portal)
	if source_portals.is_empty():
		return

	var emission_sprites: Array[Sprite2D] = []
	var emission_materials: Array[ShaderMaterial] = []
	var emission_portals: Array[Dictionary] = []
	var window_light := _window_lamp_light_style()
	var window_color: Color = window_light["color"]
	var window_energy_coefficient := float(window_light["head_energy"])
	if building.window_leak_root != null:
		for portal in source_portals:
			var strength := float(portal.get("leak_strength", 0.0))
			if strength <= 0.001:
				continue
			var sprite := Sprite2D.new()
			sprite.name = "WindowEmission_%s" % str(portal.get("id", "window"))
			sprite.texture = window_texture
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			var center: Array = portal.get("marker_center_local", [0.0, 0.0])
			sprite.position = Vector2(float(center[0]), float(center[1]))
			var width := maxf(float(portal.get("width_px", 1.0)), 1.0)
			var height := maxf(float(portal.get("height_px", width)), 1.0)
			sprite.scale = Vector2(
				width / float(window_texture.get_width()),
				height / float(window_texture.get_height()))
			var material := ShaderMaterial.new()
			material.shader = WINDOW_EMISSION_SHADER
			material.set_shader_parameter(
				"emission_color", window_color)
			material.set_shader_parameter("emission_energy", 0.0)
			material.set_shader_parameter("edge_strength", 1.25)
			sprite.material = material
			sprite.visible = false
			building.window_leak_root.add_child(sprite)

			emission_sprites.append(sprite)
			emission_materials.append(material)
			emission_portals.append(portal)

	var interior_overlay: Sprite2D = null
	var interior_material: ShaderMaterial = null
	if building.interior_texture != null and building.interior_texture.texture != null:
		interior_overlay = Sprite2D.new()
		interior_overlay.name = "WindowSunProjection"
		interior_overlay.texture = building.interior_texture.texture
		interior_overlay.centered = false
		interior_overlay.position = building.interior_texture.position
		interior_overlay.offset = building.interior_texture.offset
		interior_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		interior_overlay.z_index = 1
		interior_material = ShaderMaterial.new()
		interior_material.shader = INTERIOR_PORTAL_SHADER
		var canvas: Array = layers.get("canvas", [256, 256])
		interior_material.set_shader_parameter(
			"canvas_size_px",
			Vector2(float(canvas[0]), float(canvas[1])))
		var walk_mask_path := str(layers.get("walk_mask", ""))
		interior_material.set_shader_parameter(
			"floor_mask_texture",
			load(walk_mask_path) if walk_mask_path != "" \
				and ResourceLoader.exists(walk_mask_path) \
				else neutral_occlusion)
		interior_material.set_shader_parameter(
			"portal_color", Color("#ffe1ae"))
		interior_material.set_shader_parameter(
			"portal_softness_px", 7.0)
		interior_material.set_shader_parameter(
			"softness_growth", 0.18)
		interior_material.set_shader_parameter("portal_energy", 0.0)
		interior_overlay.material = interior_material
		building.interior.add_child(interior_overlay)

	portal_entries[building] = {
		"portals": source_portals,
		"origin": layers.get("origin", [0, 0]),
		"emission_sprites": emission_sprites,
		"emission_materials": emission_materials,
		"emission_portals": emission_portals,
		"window_light_energy": window_energy_coefficient,
		"interior_overlay": interior_overlay,
		"interior_material": interior_material,
	}


func _update_window_effects(
		state: Dictionary,
		sun_screen: Vector3,
		hour: float) -> void:
	var sun_energy := float(state["sun_energy"])
	var night_factor := 1.0 - smoothstep(0.03, 0.35, sun_energy)
	var ray := Vector2(-sun_screen.x, -sun_screen.y)
	if ray.length_squared() > 0.0001:
		ray = ray.normalized()
	for building_key in portal_entries.keys():
		var building := building_key as Building
		var entry: Dictionary = portal_entries.get(building, {})
		if building == null or not is_instance_valid(building) or entry.is_empty():
			continue
		var is_open := building.is_open_at(hour)
		var emission_strength := night_factor * (1.0 if is_open else 0.0)
		var sprites: Array = entry.get("emission_sprites", [])
		var materials: Array = entry.get("emission_materials", [])
		var emission_portals: Array = entry.get("emission_portals", [])
		var window_light_energy := float(entry.get("window_light_energy", 0.8))
		for index in range(mini(sprites.size(), materials.size())):
			var sprite := sprites[index] as Sprite2D
			var material := materials[index] as ShaderMaterial
			if sprite == null or material == null:
				continue
			var portal: Dictionary = emission_portals[index]
			var energy := emission_strength * float(
				portal.get("leak_strength", 1.0))
			material.set_shader_parameter(
				"emission_energy", energy * window_light_energy)
			sprite.visible = energy > 0.005

		var overlay := entry.get("interior_overlay") as Sprite2D
		var overlay_material := entry.get("interior_material") as ShaderMaterial
		if overlay == null or overlay_material == null:
			continue
		var portal_length := clampf(
			42.0 * Vector2(sun_screen.x, sun_screen.y).length()
				/ maxf(sun_screen.z, 0.12),
			24.0,
			180.0)
		overlay_material.set_shader_parameter(
			"sun_ray_direction",
			ray if ray.length_squared() > 0.0001 else Vector2(0.0, 1.0))
		overlay_material.set_shader_parameter(
			"portal_length_px", portal_length)
		overlay_material.set_shader_parameter(
			"portal_energy",
			clampf(sun_energy * 0.42, 0.0, 1.0))
		var origin_array: Array = entry.get("origin", [0, 0])
		var origin := Vector2(
			float(origin_array[0]),
			float(origin_array[1]))
		var portals: Array = entry.get("portals", [])
		_set_portal_param(overlay_material, "portal_a", portals, 0, origin)
		_set_portal_param(overlay_material, "portal_b", portals, 1, origin)
		overlay.visible = sun_energy > 0.01


func _set_portal_param(
		material: ShaderMaterial,
		parameter: String,
		portals: Array,
		index: int,
		origin: Vector2) -> void:
	if index >= portals.size():
		material.set_shader_parameter(parameter, Vector4.ZERO)
		return
	var portal: Dictionary = portals[index]
	var center_array: Array = portal.get("marker_center_local", [0.0, 0.0])
	var center := Vector2(float(center_array[0]), float(center_array[1])) + origin
	material.set_shader_parameter(parameter, Vector4(
		center.x,
		center.y,
		float(portal.get("width_px", 0.0)),
		1.0))


func _update_lamp_state(hour: float, sun_energy: float = -1.0) -> Dictionary:
	var candidates: Array[Dictionary] = []
	var default_lamp: Dictionary = config.get("lamp", {})
	var reference: Vector2 = camera.global_position if camera != null \
		else world.player_avatar.global_position
	if sun_energy < 0.0:
		sun_energy = float(_sample_light_state(hour)["sun_energy"])
	for building in world.buildings:
		if building == null or not is_instance_valid(building):
			continue
		if str(building.data.get("lighting_kind", "")) != "street_lamp":
			continue
		_ensure_lamp_glow(building)
		var lamp_config: Dictionary = building.data.get(
			"street_lamp_lighting", {})
		var energy := float(building.lamp_energy_at(hour))
		var glow := lamp_glows.get(building) as Sprite2D
		if glow != null:
			var color := Color.from_string(
				str(lamp_config.get("color", "#ffd36a")),
				Color(1.0, 0.82, 0.42))
			var glow_material := glow.material as ShaderMaterial
			if glow_material != null:
				glow_material.set_shader_parameter("glow_color", color)
				glow_material.set_shader_parameter(
					"opacity",
					energy
						* float(lamp_config.get("glow_energy", 0.8))
						* float(lighting_tuning.get(
							"lamp_head_opacity",
							LAMP_HEAD_OPACITY)))
				glow_material.set_shader_parameter(
					"brightness",
					float(lighting_tuning.get(
						"lamp_head_brightness",
						LAMP_HEAD_BRIGHTNESS)))
			glow.visible = energy > 0.002
		if energy <= 0.002:
			continue
		var center: Vector2 = building.global_position + Vector2(
			building.footprint.x * 32.0 * 0.5,
			building.footprint.y * 32.0 * 0.5)
		var light_color := Color.from_string(
			str(lamp_config.get("color", "#ffd36a")),
			Color(1.0, 0.82, 0.42))
		var light_range := float(lamp_config.get(
			"range_px", default_lamp.get("range_px", 260.0)))
		light_range = maxf(float(lighting_tuning.get(
			"lamp_ground_range_px",
			light_range)), 1.0)
		var camera_distance := sqrt(reference.distance_squared_to(center))
		candidates.append({
			"building": building,
			"distance": camera_distance,
			"camera_score": energy / (1.0 + camera_distance / 1800.0),
			"position": center,
			"height": float(lamp_config.get(
				"height_px",
				default_lamp.get("head_height_px", 58.0))),
			"range": light_range,
			"attenuation_range": light_range * float(
				lighting_tuning.get(
					"lamp_ground_attenuation_multiplier",
					2.0)),
			"attenuation_power": float(lighting_tuning.get(
				"lamp_ground_falloff_power",
				4.0)),
			"attenuation_curve": 0.0,
			"ground_ellipse_aspect": 1.0 / maxf(
				float(lighting_tuning.get(
					"lamp_ground_ellipse_height_ratio",
					1.0 / sqrt(2.0))),
				0.05),
			"color": light_color,
			"energy": energy
				* float(lamp_config.get("player_energy", 2.6))
				* float(lighting_tuning.get(
					"lamp_ground_energy_scale",
					1.0)),
			"shadow_height": float(lamp_config.get(
				"shadow_light_height_px",
				default_lamp.get("shadow_light_height_px", 180.0))),
			"shadow_range": float(lamp_config.get(
				"shadow_range_px",
				default_lamp.get("shadow_range_px", 360.0))),
		})
	var local_candidates := candidates.duplicate()
	local_candidates.append_array(_collect_window_light_candidates(
		hour,
		sun_energy,
		reference))
	local_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"]))
	if local_candidates.is_empty():
		zone_shadow_history.clear()
		global_shadow_history.clear()
		return {
			"active": false,
			"lights": [],
			"shadow_count": 0,
			"position": Vector2.ZERO,
			"energy": 0.0,
			"color": Color.from_string(
				str(default_lamp.get("color", "#ffd072")),
				Color(1.0, 0.82, 0.42)),
			"height": float(default_lamp.get("head_height_px", 58.0)),
			"range": float(default_lamp.get("range_px", 260.0)),
			"shadow_height": float(
				default_lamp.get("shadow_light_height_px", 180.0)),
			"shadow_range": float(
				default_lamp.get("shadow_range_px", 360.0)),
			"shadow_strength": float(
				default_lamp.get("shadow_strength", 0.88)),
		}
	var zone_candidates: Dictionary = {}
	var zone_pixels := float(SHADOW_REGION_CELLS * 32)
	for candidate in candidates:
		var position: Vector2 = candidate["position"]
		var radius := float(candidate["range"])
		var min_zone := Vector2i(
			floori((position.x - radius) / zone_pixels),
			floori((position.y - radius) / zone_pixels))
		var max_zone := Vector2i(
			floori((position.x + radius) / zone_pixels),
			floori((position.y + radius) / zone_pixels))
		for zone_y in range(min_zone.y, max_zone.y + 1):
			for zone_x in range(min_zone.x, max_zone.x + 1):
				var zone := Vector2i(zone_x, zone_y)
				var zone_rect := Rect2(
					Vector2(zone) * zone_pixels,
					Vector2(zone_pixels, zone_pixels))
				var nearest := Vector2(
					clampf(position.x, zone_rect.position.x, zone_rect.end.x),
					clampf(position.y, zone_rect.position.y, zone_rect.end.y))
				var zone_distance := position.distance_to(nearest)
				if zone_distance > radius:
					continue
				var zone_light: Dictionary = candidate.duplicate()
				zone_light["zone"] = zone
				zone_light["zone_score"] = (
					float(candidate["energy"])
					* pow(1.0 - zone_distance / maxf(radius, 1.0), 1.4)
					* (1.0 / (1.0 + float(candidate["distance"]) / 1800.0)))
				if not zone_candidates.has(zone):
					zone_candidates[zone] = []
				(zone_candidates[zone] as Array).append(zone_light)
	var shadow_eligible: Array[Dictionary] = []
	var unique_eligible: Dictionary = {}
	for zone in zone_candidates.keys():
		var zone_lights: Array = zone_candidates[zone]
		zone_lights.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["zone_score"]) > float(b["zone_score"]))
		var selected: Array[Dictionary] = []
		for index in range(mini(
				zone_lights.size(),
				SHADOW_LIGHTS_PER_REGION)):
			selected.append(zone_lights[index])
		# Keep an incumbent unless a new light is at least 20% stronger.
		var previous: Array = zone_shadow_history.get(zone, [])
		for previous_building in previous:
			if previous_building == null or not is_instance_valid(previous_building):
				continue
			var previous_light: Dictionary = {}
			for light in zone_lights:
				if light["building"] == previous_building:
					previous_light = light
					break
			if previous_light.is_empty():
				continue
			var already_selected := false
			var weakest_index := -1
			var weakest_score := INF
			for index in range(selected.size()):
				if selected[index]["building"] == previous_building:
					already_selected = true
					break
				var score := float(selected[index]["zone_score"])
				if score < weakest_score:
					weakest_score = score
					weakest_index = index
			if already_selected or weakest_index < 0:
				continue
			if float(previous_light["zone_score"]) >= weakest_score * 0.8:
				selected[weakest_index] = previous_light
		selected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["zone_score"]) > float(b["zone_score"]))
		var selected_buildings: Array[Building] = []
		for light in selected:
			var building := light["building"] as Building
			selected_buildings.append(building)
			if not unique_eligible.has(building) \
					or float(light["zone_score"]) > float(
						(unique_eligible[building] as Dictionary)["zone_score"]):
				unique_eligible[building] = light
		zone_shadow_history[zone] = selected_buildings
	for eligible_light in unique_eligible.values():
		shadow_eligible.append(eligible_light)
	shadow_eligible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["camera_score"]) > float(b["camera_score"]))
	var shadow_lights: Array[Dictionary] = []
	for index in range(mini(shadow_eligible.size(), MAX_SHADOW_LIGHTS)):
		shadow_lights.append(shadow_eligible[index])
	for previous_building in global_shadow_history:
		if previous_building == null or not is_instance_valid(previous_building):
			continue
		var previous_index := -1
		var previous_light: Dictionary = {}
		for index in range(shadow_eligible.size()):
			if shadow_eligible[index]["building"] == previous_building:
				previous_index = index
				previous_light = shadow_eligible[index]
				break
		if previous_light.is_empty():
			continue
		var already_selected := false
		var weakest_index := -1
		var weakest_score := INF
		for index in range(shadow_lights.size()):
			if shadow_lights[index]["building"] == previous_building:
				already_selected = true
				break
			var score := float(shadow_lights[index]["camera_score"])
			if score < weakest_score:
				weakest_score = score
				weakest_index = index
		if already_selected or weakest_index < 0:
			continue
		if float(previous_light["camera_score"]) >= weakest_score * 0.85:
			shadow_lights[weakest_index] = previous_light
	shadow_lights.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["camera_score"]) > float(b["camera_score"]))
	global_shadow_history.clear()
	for light in shadow_lights:
		global_shadow_history.append(light["building"])
	var shadow_buildings: Dictionary = {}
	for light in shadow_lights:
		shadow_buildings[light["building"]] = true
	var active_lights: Array[Dictionary] = shadow_lights.duplicate()
	for candidate in local_candidates:
		if active_lights.size() >= MAX_LOCAL_LIGHTS:
			break
		if shadow_buildings.has(candidate["building"]):
			continue
		active_lights.append(candidate)
	if active_lights.is_empty():
		return {
			"active": false,
			"lights": active_lights,
			"shadow_count": 0,
			"position": Vector2.ZERO,
			"energy": 0.0,
			"color": Color.from_string(
				str(default_lamp.get("color", "#ffd072")),
				Color(1.0, 0.82, 0.42)),
			"height": float(default_lamp.get("head_height_px", 58.0)),
			"range": float(default_lamp.get("range_px", 260.0)),
			"shadow_height": float(
				default_lamp.get("shadow_light_height_px", 180.0)),
			"shadow_range": float(
				default_lamp.get("shadow_range_px", 360.0)),
			"shadow_strength": float(
				default_lamp.get("shadow_strength", 0.88)),
		}
	var primary: Dictionary = active_lights[0]
	return {
		"active": true,
		"lights": active_lights,
		"shadow_count": shadow_lights.size(),
		"position": primary["position"],
		"energy": primary["energy"],
		"color": primary["color"],
		"height": primary["height"],
		"range": primary["range"],
		"shadow_height": float(primary.get(
			"shadow_height",
			default_lamp.get("shadow_light_height_px", 180.0))),
		"shadow_range": float(primary.get(
			"shadow_range",
			default_lamp.get("shadow_range_px", 360.0))),
		"shadow_strength": float(
			default_lamp.get("shadow_strength", 0.88)),
	}


func _update_surface_parameters(
		state: Dictionary,
		sun_screen: Vector3,
		lamp_state: Dictionary,
		_delta: float) -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	for material in ground_materials:
		_set_material_parameters(
			material,
			state,
			sun_screen,
			lamp_state,
			viewport_size)
	for material in surface_materials:
		_set_material_parameters(
			material,
			state,
			sun_screen,
			lamp_state,
			viewport_size)
		material.set_shader_parameter(
			"sun_screen_direction",
			sun_screen)
		material.set_shader_parameter("camera_zoom", camera.zoom if camera != null else Vector2.ONE)
		material.set_shader_parameter("viewport_size_px", viewport_size)
		_update_wall_shadow_parameters(material)
	_update_interior_lighting(state)


func _update_wall_shadow_parameters(material: ShaderMaterial) -> void:
	var meta: Dictionary = surface_meta.get(material, {})
	if meta.is_empty():
		return
	var building := meta.get("building") as Building
	if building == null or not is_instance_valid(building):
		return
	var is_building_surface := bool(
		meta.get("is_building_surface", false))
	material.set_shader_parameter(
		"ignore_self_projected_shadow",
		is_building_surface)
	material.set_shader_parameter(
		"apply_wall_facing_gate",
		bool(meta.get("apply_wall_facing_gate", false)))
	var is_wall := bool(meta.get("is_wall", false))
	material.set_shader_parameter("apply_wall_shadow_projection", is_wall)
	if is_wall and building.wall_texture != null:
		material.set_shader_parameter(
			"wall_shadow_rect_uv",
			_wall_shadow_rect_uv(building))
	if is_building_surface:
		material.set_shader_parameter(
			"self_shadow_world_rect",
			_building_shadow_world_rect(building))


func _wall_shadow_rect_uv(building: Building) -> Vector4:
	var layers: Dictionary = building.data.get("sprite_layers", {})
	var canvas_array: Array = layers.get("canvas", [256.0, 256.0])
	var canvas := Vector2(
		float(canvas_array[0]) if canvas_array.size() > 0 else 256.0,
		float(canvas_array[1]) if canvas_array.size() > 1 else 256.0)
	var region_array: Array = layers.get(
		"wall_region_px",
		[0.0, 0.0, canvas.x, canvas.y])
	var region := Rect2(
		float(region_array[0]) if region_array.size() > 0 else 0.0,
		float(region_array[1]) if region_array.size() > 1 else 0.0,
		float(region_array[2]) if region_array.size() > 2 else canvas.x,
		float(region_array[3]) if region_array.size() > 3 else canvas.y)
	var canvas_transform := get_viewport().get_canvas_transform()
	var top_left := canvas_transform * building.wall_texture.to_global(
		region.position)
	var bottom_right := canvas_transform * building.wall_texture.to_global(
		region.end)
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var top_left_uv := top_left / viewport_size
	var bottom_right_uv := bottom_right / viewport_size
	return Vector4(
		minf(top_left_uv.x, bottom_right_uv.x),
		minf(top_left_uv.y, bottom_right_uv.y),
		maxf(top_left_uv.x, bottom_right_uv.x),
		maxf(top_left_uv.y, bottom_right_uv.y))


func _building_shadow_world_rect(building: Building) -> Vector4:
	var footprint_size := Vector2(
		float(building.footprint.x) * 32.0,
		float(building.footprint.y) * 32.0)
	var corners := [
		building.to_global(Vector2.ZERO),
		building.to_global(Vector2(footprint_size.x, 0.0)),
		building.to_global(Vector2(0.0, footprint_size.y)),
		building.to_global(footprint_size),
	]
	var minimum: Vector2 = corners[0]
	var maximum: Vector2 = corners[0]
	for corner in corners:
		var point: Vector2 = corner
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	var wall_sprite := building.wall_texture
	if wall_sprite != null and wall_sprite.texture != null:
		var sprite_rect := wall_sprite.get_rect()
		var sprite_corners := [
			wall_sprite.to_global(sprite_rect.position),
			wall_sprite.to_global(Vector2(sprite_rect.end.x, sprite_rect.position.y)),
			wall_sprite.to_global(Vector2(sprite_rect.position.x, sprite_rect.end.y)),
			wall_sprite.to_global(sprite_rect.end),
		]
		for corner in sprite_corners:
			var point: Vector2 = corner
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.y)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.y)
	minimum -= Vector2(8.0, 8.0)
	maximum += Vector2(8.0, 8.0)
	return Vector4(minimum.x, minimum.y, maximum.x, maximum.y)


func _update_interior_lighting(state: Dictionary) -> void:
	var hour := GameClock.hour_of_day()
	for building_key in interior_materials.keys():
		var building := building_key as Building
		var material := interior_materials.get(building) as ShaderMaterial
		if building == null or not is_instance_valid(building) or material == null:
			continue
		var center := building.global_position + Vector2(
			building.footprint.x * 32.0 * 0.5,
			building.footprint.y * 32.0 * 0.5)
		var open_energy := 0.95 if building.is_open_at(hour) else 0.14
		material.set_shader_parameter(
			"sun_energy", float(state["sun_energy"]) * 0.08)
		material.set_shader_parameter(
			"sky_energy", float(state["sky_energy"]) * 0.42)
		material.set_shader_parameter(
			"interior_light_color", Color("#ffd39a"))
		material.set_shader_parameter(
			"interior_light_energy",
			0.58 if building.is_open_at(hour) else 0.08)
		_set_local_light_arrays(material, [{
			"position": center,
			"height": 34.0,
			"range": maxf(
				float(maxi(building.footprint.x, building.footprint.y)) * 42.0,
				96.0),
			"color": Color("#ffd39a"),
			"energy": open_energy * 0.45,
		}], 0)
		material.set_shader_parameter("lamp_shadow_strength", 0.0)


func _set_material_parameters(
		material: ShaderMaterial,
		state: Dictionary,
		sun_screen: Vector3,
		lamp_state: Dictionary,
		_viewport_size: Vector2) -> void:
	material.set_shader_parameter("sun_direction", sun_screen)
	material.set_shader_parameter("sun_color", state["sun_color"])
	material.set_shader_parameter("sun_energy", float(state["sun_energy"]))
	material.set_shader_parameter("sky_color", state["sky_color"])
	material.set_shader_parameter("sky_energy", float(state["sky_energy"]))
	material.set_shader_parameter("exposure", float(state["exposure"]))
	_set_local_light_arrays(
		material,
		lamp_state["lights"],
		int(lamp_state.get("shadow_count", 0)))
	material.set_shader_parameter(
		"lamp_shadow_strength",
		float(lamp_state["shadow_strength"]))
	material.set_shader_parameter("debug_mode", debug_mode)


func _set_local_light_arrays(
		material: ShaderMaterial,
		lights: Array,
		shadow_count: int) -> void:
	var positions: Array[Vector4] = []
	var colors: Array[Vector4] = []
	var falloff_powers: Array[float] = []
	var ground_ellipse_aspects: Array[float] = []
	var attenuation_curves: Array[float] = []
	for index in range(32):
		if index < lights.size():
			var light: Dictionary = lights[index]
			var position: Vector2 = light["position"]
			var color: Color = light["color"]
			positions.append(Vector4(
				position.x,
				position.y,
				float(light["height"]),
				float(light.get(
					"attenuation_range",
					light["range"]))))
			colors.append(Vector4(
				color.r,
				color.g,
				color.b,
				float(light["energy"])))
			falloff_powers.append(float(light.get(
				"attenuation_power",
				2.0)))
			ground_ellipse_aspects.append(float(light.get(
				"ground_ellipse_aspect",
				1.0)))
			attenuation_curves.append(float(light.get(
				"attenuation_curve",
				0.0)))
		else:
			positions.append(Vector4.ZERO)
			colors.append(Vector4.ZERO)
			falloff_powers.append(2.0)
			ground_ellipse_aspects.append(1.0)
			attenuation_curves.append(0.0)
	material.set_shader_parameter(
		"local_light_count",
		mini(lights.size(), MAX_LOCAL_LIGHTS))
	material.set_shader_parameter(
		"shadowed_light_count",
		clampi(shadow_count, 0, MAX_SHADOW_LIGHTS))
	material.set_shader_parameter(
		"local_light_positions",
		PackedVector4Array(positions))
	material.set_shader_parameter(
		"local_light_colors",
		PackedVector4Array(colors))
	material.set_shader_parameter(
		"local_light_falloff_powers",
		PackedFloat32Array(falloff_powers))
	material.set_shader_parameter(
		"local_light_ground_ellipse_aspects",
		PackedFloat32Array(ground_ellipse_aspects))
	material.set_shader_parameter(
		"local_light_attenuation_curves",
		PackedFloat32Array(attenuation_curves))


func _update_fog(hour: float, delta: float) -> void:
	_fog_time += delta
	if fog_layer == null or fog_material == null:
		return
	var intensity := WorldWeather.fog_strength(hour)
	fog_layer.visible = intensity > 0.0001
	if not fog_layer.visible:
		return
	var weather_config: Dictionary = WorldWeather.config
	var camera_origin: Vector2 = camera.get_screen_center_position() \
		if camera != null else Vector2.ZERO
	var zoom: Vector2 = camera.zoom if camera != null else Vector2.ONE
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var drift_array: Array = weather_config.get(
		"fog_drift_speed",
		[0.006, 0.003])
	var drift := Vector2(
		float(drift_array[0]) if drift_array.size() > 0 else 0.006,
		float(drift_array[1]) if drift_array.size() > 1 else 0.003)
	fog_material.set_shader_parameter("fog_intensity", intensity)
	fog_material.set_shader_parameter("fog_time", _fog_time)
	fog_material.set_shader_parameter(
		"fog_color",
		Color.from_string(
			str(weather_config.get("fog_color", "#c2cecd")),
			Color(0.76, 0.82, 0.82)))
	fog_material.set_shader_parameter(
		"fog_max_alpha",
		float(weather_config.get("fog_max_alpha", 0.52)))
	fog_material.set_shader_parameter(
		"noise_scale_px",
		float(weather_config.get("fog_noise_scale_px", 620.0)))
	fog_material.set_shader_parameter(
		"depth_scale_px",
		float(weather_config.get("fog_depth_scale_px", 940.0)))
	fog_material.set_shader_parameter("drift_speed", drift)
	fog_material.set_shader_parameter(
		"depth_drift_scale",
		float(weather_config.get("fog_depth_drift_scale", -0.067)))
	fog_material.set_shader_parameter("camera_origin_px", camera_origin)
	fog_material.set_shader_parameter("camera_zoom", zoom)
	fog_material.set_shader_parameter("viewport_size_px", viewport_size)


func _shadow_state_key(
		sun_screen: Vector3,
		lamp_state: Dictionary,
		player_foot: Vector2) -> String:
	var camera_position := camera.global_position if camera != null \
		else Vector2.ZERO
	var zoom := camera.zoom if camera != null else Vector2.ONE
	var light_signature: Array[String] = []
	for light in lamp_state["lights"]:
		var position: Vector2 = light["position"]
		light_signature.append("%s:%s:%s" % [
			snappedf(position.x, 1.0),
			snappedf(position.y, 1.0),
			snappedf(float(light["energy"]), 0.01),
		])
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
		snappedf(camera_position.x, 0.5),
		snappedf(camera_position.y, 0.5),
		snappedf(zoom.x, 0.001),
		snappedf(sun_screen.x, 0.002),
		snappedf(sun_screen.y, 0.002),
		snappedf(sun_screen.z, 0.002),
		snappedf(player_foot.x, 1.0),
		snappedf(player_foot.y, 1.0),
		",".join(light_signature),
	]


func _sync_actor_proxies() -> String:
	var seen: Dictionary = {}
	var signature_parts: Array[String] = []
	for actor in get_tree().get_nodes_in_group("customers"):
		if actor == null or not is_instance_valid(actor):
			continue
		var node := actor as Node2D
		if node == null or not node.is_visible_in_tree():
			continue
		var sprite := node.get_node_or_null("Sprite") as Sprite2D
		if sprite == null:
			continue
		var foot := sprite.to_global(Vector2(0.0, sprite.get_rect().end.y))
		seen[node] = true
		rig.add_actor_proxy(node, foot, 7.5, 52.0)
		rig.set_actor_foot(node, foot)
		signature_parts.append("%s:%s:%s" % [
			str(node.get_instance_id()),
			snappedf(foot.x, 1.0),
			snappedf(foot.y, 1.0),
		])
	for actor_id in rig.actor_proxies.keys():
		if not seen.has(actor_id):
			rig.remove_actor_proxy(actor_id)
	signature_parts.sort()
	return ",".join(signature_parts)


func _rebuild_proxies() -> void:
	if rig == null or world == null:
		return
	rig.clear_proxies()
	for node in get_tree().get_nodes_in_group("lighting_pines"):
		var pine := node as Node2D
		if pine != null and is_instance_valid(pine):
			rig.add_pine_proxy(pine.global_position, 126.0)
	for building in world.buildings:
		if building == null or not is_instance_valid(building):
			continue
		var layers: Dictionary = building.data.get("sprite_layers", {})
		var proxy_path := str(layers.get("shadow_proxy", ""))
		if proxy_path == "" or not ResourceLoader.exists(proxy_path):
			continue
		var center: Vector2 = building.global_position + Vector2(
			building.footprint.x * 32.0 * 0.5,
			building.footprint.y * 32.0 * 0.5)
		var height_scale := 1.0
		if str(building.data.get("lighting_kind", "")) == "street_lamp":
			var lamp_config: Dictionary = building.data.get(
				"street_lamp_lighting", {})
			height_scale = float(lamp_config.get(
				"shadow_proxy_height_scale",
				1.0))
		rig.add_building_proxy(
			proxy_path,
			center,
			height_scale,
			str(building.data.get("lighting_kind", "")) != "street_lamp",
			str(building.data.get("lighting_kind", "")) != "street_lamp")
	if world.player_avatar != null:
		var foot := _player_foot_position()
		foot = Vector2(roundf(foot.x), roundf(foot.y))
		if not rig.add_player_proxy(
				PLAYER_SHADOW_PROXY_PATH,
				foot,
				PLAYER_SHADOW_HEIGHT_PX):
			rig.add_capsule_proxy(foot, 9.0, 62.0)
		last_player_foot = foot
	last_shadow_key = ""


func _player_foot_position() -> Vector2:
	var player = world.get("player_avatar") if world != null else null
	if player == null or not is_instance_valid(player):
		return Vector2.ZERO
	var sprite := player.get_node_or_null("Sprite") as Sprite2D
	if sprite != null:
		return sprite.to_global(Vector2(0.0, sprite.get_rect().end.y))
	return player.global_position + Vector2(0.0, 18.0)


func _player_surface_world_rect(sprite: Sprite2D) -> Vector4:
	if sprite == null:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var local_rect := sprite.get_rect()
	var corners := [
		sprite.to_global(local_rect.position),
		sprite.to_global(Vector2(local_rect.end.x, local_rect.position.y)),
		sprite.to_global(Vector2(local_rect.position.x, local_rect.end.y)),
		sprite.to_global(local_rect.end),
	]
	var minimum: Vector2 = corners[0]
	var maximum: Vector2 = corners[0]
	for corner in corners:
		var point: Vector2 = corner
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	minimum -= Vector2(4.0, 4.0)
	maximum += Vector2(4.0, 4.0)
	return Vector4(minimum.x, minimum.y, maximum.x, maximum.y)


func _on_building_placed(building: Building) -> void:
	zone_shadow_history.clear()
	global_shadow_history.clear()
	_setup_building(building)
	_rebuild_proxies()


func _on_building_removed(building: Building) -> void:
	zone_shadow_history.clear()
	global_shadow_history.clear()
	building_materials.erase(building)
	interior_materials.erase(building)
	portal_entries.erase(building)
	var glow := lamp_glows.get(building) as Sprite2D
	if glow != null and is_instance_valid(glow):
		glow.queue_free()
	lamp_glows.erase(building)
	_rebuild_proxies()


func _make_neutral_textures() -> void:
	neutral_normal = _make_solid_texture(Color(0.5, 0.5, 1.0, 1.0))
	neutral_specular = _make_solid_texture(Color(0.15, 0.15, 0.15, 1.0))
	neutral_occlusion = _make_solid_texture(Color.WHITE)
	flat_black = _make_solid_texture(Color.BLACK)
	radial_texture = _make_radial_texture(128)
	window_texture = _make_window_texture(WINDOW_TEXTURE_SIZE)


func _make_solid_texture(color: Color) -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, color)
	return ImageTexture.create_from_image(image)


func _make_radial_texture(size: int) -> ImageTexture:
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


func _make_window_texture(size: int) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var edge_softness := 0.16
	for y in range(size):
		for x in range(size):
			var normalized := Vector2(
				(float(x) + 0.5) / float(size),
				(float(y) + 0.5) / float(size))
			var edge_distance := minf(
				minf(normalized.x, 1.0 - normalized.x),
				minf(normalized.y, 1.0 - normalized.y))
			var alpha := smoothstep(0.0, edge_softness, edge_distance)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)


func _sun_to_screen_direction(at_hour: float) -> Vector3:
	if use_sun_screen_override:
		return sun_screen_override
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
	var t := smoothstep(
		0.0,
		1.0,
		clampf((at_hour - float(before["hour"])) / span, 0.0, 1.0))
	var sun_config: Dictionary = config.get("sun", {})
	var sunrise := float(sun_config.get("sunrise_hour", 6.0 + 25.0 / 60.0))
	var sunset := float(sun_config.get("sunset_hour", 19.0 + 25.0 / 60.0))
	var daylight_epsilon := 0.00001
	var is_daylight := at_hour >= sunrise - daylight_epsilon \
		and at_hour <= sunset + daylight_epsilon
	var sampled_sun_energy := lerpf(
		float(before["sun_energy"]),
		float(after["sun_energy"]),
		t)
	# 太阳只在日出到日落之间发光。关键帧提供端点上的低能量红光，
	# 这样日出刚出现、日落即将消失时仍能看见最红的颜色。
	if not is_daylight:
		sampled_sun_energy = 0.0
	var sampled_exposure := lerpf(
		float(config.get("exposure_night", 1.0)),
		float(config.get("exposure_day", 0.78)),
		smoothstep(0.02, 0.82, sampled_sun_energy))
	var sun_color := Color.from_string(
		str(before["sun_color"]), Color.WHITE).lerp(
			Color.from_string(str(after["sun_color"]), Color.WHITE), t)
	if is_daylight:
		var arc := clampf(
			(at_hour - sunrise) / maxf(sunset - sunrise, 0.001),
			0.0,
			1.0)
		var height := sin(arc * PI)
		var horizon_weight := pow(
			clampf(1.0 - height, 0.0, 1.0),
			float(sun_config.get("warm_curve_power", 1.35)))
		var horizon_color := Color.from_string(
			str(sun_config.get("morning_horizon_color", "#ff3b24")),
			Color("#ff3b24")).lerp(
				Color.from_string(
					str(sun_config.get("evening_horizon_color", "#ff261b")),
					Color("#ff261b")),
				arc)
		var noon_color := Color.from_string(
			str(sun_config.get("noon_color", "#fff8ef")),
			Color("#fff8ef"))
		sun_color = noon_color.lerp(horizon_color, horizon_weight)
	return {
		"sky_color": Color.from_string(
			str(before["sky_color"]), Color.WHITE).lerp(
				Color.from_string(str(after["sky_color"]), Color.WHITE), t),
		"sky_energy": lerpf(
			float(before["sky_energy"]),
			float(after["sky_energy"]),
			t),
		"sun_color": sun_color,
		"sun_energy": sampled_sun_energy,
		"exposure": sampled_exposure,
	}


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[SpringWorldLighting] Missing config: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
