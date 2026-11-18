extends Node
## Focused regression check for weather timing, probability overrides and F10 UI.

const SUNRISE_HOUR := 6.0 + 25.0 / 60.0
const SUNSET_HOUR := 19.0 + 25.0 / 60.0


func _ready() -> void:
	var checks: Array[String] = []
	DevEvents.reset_all()
	WorldWeather.clear_force_overrides()
	WorldWeather.set_fog_force(1)
	var at_start := WorldWeather.fog_strength(6.0)
	var at_mid_fade_in := WorldWeather.fog_strength(6.25)
	var at_full := WorldWeather.fog_strength(7.0)
	var at_mid_fade_out := WorldWeather.fog_strength(8.75)
	var at_end := WorldWeather.fog_strength(9.0)
	checks.append("06:00 雾逻辑强度为 0：%s（%.3f）" % [
		str(is_zero_approx(at_start)), at_start])
	checks.append("06:15 雾逻辑淡入一半：%s（%.3f）" % [
		str(absf(at_mid_fade_in - 0.5) < 0.02), at_mid_fade_in])
	checks.append("07:00 雾逻辑满强度：%s（%.3f）" % [
		str(is_equal_approx(at_full, 1.0)), at_full])
	checks.append("08:45 雾逻辑淡出一半：%s（%.3f）" % [
		str(at_mid_fade_out > 0.1 and at_mid_fade_out < 0.95),
		at_mid_fade_out])
	checks.append("09:00 雾逻辑结束：%s（%.3f）" % [
		str(is_zero_approx(at_end)), at_end])

	WorldWeather.clear_force_overrides()
	WorldWeather.set_yesterday_rain_force(0)
	DevEvents.clear_chance_override("weather.post_rain_fog")
	WorldWeather.refresh()
	checks.append("昨日不下雨时不会起雾：%s" % [
		str(not WorldWeather.fog_event)])
	WorldWeather.set_yesterday_rain_force(1)
	DevEvents.set_chance_override("weather.post_rain_fog", 1.0)
	WorldWeather.refresh()
	checks.append("昨日下雨且雨后起雾概率 100%%：%s" % [
		str(WorldWeather.fog_event)])
	DevEvents.set_chance_override("weather.post_rain_fog", 0.0)
	WorldWeather.refresh()
	checks.append("昨日下雨但雨后起雾概率 0%%：%s" % [
		str(not WorldWeather.fog_event)])

	DevEvents.set_chance_override("visitor.lodge_priority", 0.25)
	checks.append("通用概率接管生效：%s" % [
		str(is_equal_approx(
			DevEvents.chance("visitor.lodge_priority", 0.85),
			0.25))])
	DevEvents.set_multiplier("exploration.risk_multiplier", 0.0)
	checks.append("整体倍率生效：%s" % [
		str(is_zero_approx(DevEvents.scale(
			"exploration.risk_multiplier",
			1.0)))])

	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	var panel := main.get_node_or_null(
		"LightingV2DebugPanel") as LightingV2DebugPanel
	checks.append("F10 面板已接入主场景：%s" % [str(panel != null)])
	if panel != null:
		checks.append("F10 面板层级在 HUD 之上：%s" % [
			str(panel.layer > 10)])
		var key_event := InputEventKey.new()
		key_event.keycode = KEY_F10
		key_event.pressed = true
		panel._input(key_event)
		checks.append("F10 可打开面板并锁定移动键：%s" % [
			str(panel.visible and GameState.text_input_active)])
		var close_event := key_event.duplicate() as InputEventKey
		panel._input(close_event)
		checks.append("再次按 F10 可关闭并恢复移动键：%s" % [
			str(not panel.visible and not GameState.text_input_active)])
		checks.append("F10 光照调参控件已接入：%s（%d 项）" % [
			str(panel.lighting_tuning_controls.size() >= 10),
			panel.lighting_tuning_controls.size(),
		])
		panel._on_print_lighting_tuning()
		var tuning_doc: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(
				"res://.tmp/lighting_tuning.json"))
		var tuning_ok: bool = tuning_doc is Dictionary \
			and tuning_doc.get("settings", {}) is Dictionary \
			and tuning_doc["settings"].size() >= 10 \
			and tuning_doc.get("derived", {}) is Dictionary
		checks.append("光照参数打印并写入 .tmp/lighting_tuning.json：%s" % [
			str(tuning_ok)])
		var spring_lighting: SpringWorldLighting = main.get_node_or_null(
			"SpringWorldLighting") as SpringWorldLighting
		var player: Node2D = main.get_node("World").player_avatar as Node2D
		if spring_lighting != null and player != null:
			spring_lighting.set_player_surface_map_disabled("normal", true)
			spring_lighting.set_player_surface_map_disabled("specular", true)
			spring_lighting.set_player_surface_map_disabled("occlusion", true)
			var normal_texture := player.surface_material.get_shader_parameter(
				"normal_texture") as Texture2D
			var specular_texture := player.surface_material.get_shader_parameter(
				"specular_texture") as Texture2D
			var occlusion_texture := player.surface_material.get_shader_parameter(
				"occlusion_texture") as Texture2D
			var maps_disabled_ok := false
			if normal_texture != null and specular_texture != null \
					and occlusion_texture != null:
				var normal_image := normal_texture.get_image()
				var specular_image := specular_texture.get_image()
				var occlusion_image := occlusion_texture.get_image()
				var neutral_normal := normal_image.get_pixel(0, 0)
				maps_disabled_ok = (
					absf(neutral_normal.r - 0.5) <= 0.01
					and absf(neutral_normal.g - 0.5) <= 0.01
					and neutral_normal.b >= 0.999
					and specular_image.get_pixel(0, 0).r <= 0.001
					and occlusion_image.get_pixel(0, 0).r >= 0.999
				)
			spring_lighting.reset_player_surface_map_disables()
			checks.append("F10 角色法线 / Specular / Occlusion 独立 A/B：%s" % [
				str(maps_disabled_ok)])
			spring_lighting.set_player_smooth_normal_enabled(true)
			var smooth_normal_texture := player.surface_material.get_shader_parameter(
				"normal_texture") as Texture2D
			var smooth_normal_ok := smooth_normal_texture != null \
				and smooth_normal_texture.resource_path.ends_with("_n_smooth.png")
			spring_lighting.reset_player_surface_map_disables()
			checks.append("F10 角色平滑法线 A/B：%s" % [
				str(smooth_normal_ok)])
			spring_lighting.reset_player_surface_map_disables()
			var shared_atlas_uv_default_ok := bool(
				player.surface_material.get_shader_parameter(
					"use_shared_atlas_uv"))
			spring_lighting.set_player_shared_atlas_uv(false)
			var shared_atlas_uv_toggle_ok := not bool(
				player.surface_material.get_shader_parameter(
					"use_shared_atlas_uv"))
			spring_lighting.reset_player_surface_map_disables()
			var shared_atlas_uv_ok := shared_atlas_uv_default_ok \
				and shared_atlas_uv_toggle_ok
			checks.append("F10 角色共享图集 UV A/B：%s" % [
				str(shared_atlas_uv_ok)])
			var walk_normal_texture := load(
				"res://art/characters/player/star2a/walk_n.png") as Texture2D
			var walk_normal_is_per_frame := false
			if walk_normal_texture != null:
				var walk_normal_image := walk_normal_texture.get_image()
				var frame_width := maxi(walk_normal_image.get_width() / 4, 1)
				var frame_height := maxi(walk_normal_image.get_height() / 4, 1)
				walk_normal_is_per_frame = true
				for direction in range(4):
					var first_frame := walk_normal_image.get_region(Rect2i(
						direction * frame_width,
						0,
						frame_width,
						frame_height)).get_data()
					var direction_has_variation := false
					for step in range(1, 4):
						var frame_data := walk_normal_image.get_region(Rect2i(
							direction * frame_width,
							step * frame_height,
							frame_width,
							frame_height)).get_data()
						if frame_data != first_frame:
							direction_has_variation = true
					if not direction_has_variation:
						walk_normal_is_per_frame = false
			checks.append("角色法线按每个序列帧导入：%s" % [
				str(walk_normal_is_per_frame)])
			var proxy_ok: bool = spring_lighting.rig != null \
				and spring_lighting.rig.player_proxy_resource_path.ends_with(
					"shadow_proxy.glb") \
				and spring_lighting.rig.player_proxies.size() >= 5 \
				and spring_lighting.rig.player_contact_proxy != null
			if proxy_ok:
				var proxy_root: Node3D = spring_lighting.rig.player_proxies[0]
				proxy_ok = proxy_root.find_children(
					"*",
					"MeshInstance3D",
					true,
					false).size() > 0
				var yaw_values: Dictionary = {}
				for facing in range(4):
					spring_lighting.rig.set_player_facing(facing)
					yaw_values[snappedf(
						proxy_root.rotation.y,
						0.001)] = true
				proxy_ok = proxy_ok and yaw_values.size() == 4
				spring_lighting.rig.set_player_facing(
					int(player.get("_facing")))
			var player_sun_viewport: SubViewport = null
			if spring_lighting.rig != null:
				player_sun_viewport = spring_lighting.rig.player_sun_pass.get(
					"viewport") as SubViewport
			proxy_ok = proxy_ok and player_sun_viewport != null \
				and player_sun_viewport.render_target_update_mode \
					== SubViewport.UPDATE_ALWAYS
			var player_sun_texture := spring_lighting.rig.get_player_sun_texture()
			var ground_material_ok := false
			if player_sun_texture != null:
				for material in spring_lighting.ground_materials:
					if material.get_shader_parameter(
							"player_sun_shadow_texture") == player_sun_texture:
						ground_material_ok = true
						break
			proxy_ok = proxy_ok and player_sun_texture != null \
				and ground_material_ok
			checks.append("角色 3D 代理、独立太阳通道与四向旋转：%s" % [
				str(proxy_ok)])

	var proxy_specs := {
		"lodge_ordinary": {
			"footprint": Vector2(146.0, 98.09375),
			"size": Vector3(146.0, 82.0, 98.0938),
		},
		"shop_general": {
			"footprint": Vector2(176.0, 118.25),
			"size": Vector3(176.0, 119.0, 118.25),
		},
		"shop_small": {
			"footprint": Vector2(192.0, 128.0),
			"size": Vector3(192.0, 90.0, 128.0),
		},
	}
	var building_proxy_specs_ok := true
	for asset_id in proxy_specs:
		var proxy_path := \
			"res://art/characters/buildings/%s/shadow_proxy.json" % asset_id
		var proxy_doc: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(proxy_path))
		if proxy_doc is not Dictionary:
			building_proxy_specs_ok = false
			break
		var footprint: Array = proxy_doc.get("footprint_px", [])
		var size: Array = proxy_doc.get("size_px", [])
		var pivot: Array = proxy_doc.get("pivot_px", [])
		var expected: Dictionary = proxy_specs[asset_id]
		var expected_footprint: Vector2 = expected["footprint"]
		var expected_size: Vector3 = expected["size"]
		var packed := load(
			"res://art/characters/buildings/%s/shadow_proxy.glb"
				% asset_id) as PackedScene
		var actual_size := Vector3.ZERO
		var actual_ground_y := INF
		if packed != null:
			var proxy_node := packed.instantiate() as Node3D
			if proxy_node != null:
				var proxy_bounds: AABB = main.get_node(
					"SpringWorldLighting").rig.call(
						"_mesh_bounds_under", proxy_node)
				actual_size = proxy_bounds.size
				actual_ground_y = proxy_bounds.position.y
				proxy_node.free()
		if not is_equal_approx(
				float(proxy_doc.get("uniform_scale", 0.0)),
				32.0) \
				or footprint.size() != 2 or size.size() != 3 \
				or pivot.size() != 3 \
				or not Vector2(
					float(footprint[0]),
					float(footprint[1])).is_equal_approx(
						expected_footprint) \
				or not Vector3(
					float(size[0]),
					float(size[2]),
					float(size[1])).is_equal_approx(
						expected_size) \
				or not Vector3(
					float(pivot[0]),
					float(pivot[1]),
					float(pivot[2])).is_zero_approx() \
				or not actual_size.is_equal_approx(expected_size) \
				or not is_zero_approx(actual_ground_y):
			building_proxy_specs_ok = false
			break
	checks.append("建筑 3D 代理使用真实包络与统一 32× 缩放：%s" % [
		str(building_proxy_specs_ok)])

	var spring := main.get_node_or_null("SpringWorldLighting")
	if spring != null:
		WorldWeather.set_fog_force(1)
		spring._update_fog(7.0, 0.0)
		checks.append("视觉雾层在满强度时显示：%s" % [
			str(
				spring.fog_layer != null
				and spring.fog_layer.visible
				and is_equal_approx(
					float(spring.fog_material.get_shader_parameter(
						"fog_intensity")),
					1.0))])
		spring._update_fog(6.25, 0.0)
		checks.append("视觉雾层参与 30 分钟淡入：%s" % [
			str(is_equal_approx(
				float(spring.fog_material.get_shader_parameter(
					"fog_intensity")),
				0.5))])
		var fog_time_before: float = float(spring.get("_fog_time"))
		var dawn_state: Dictionary = spring.call(
			"_sample_light_state", 7.0)
		var dawn_sun: Vector3 = spring.call(
			"_sun_to_screen_direction", 7.0)
		spring._update_fog(7.0, 0.5, dawn_state, dawn_sun)
		var drift: Vector2 = spring.fog_material.get_shader_parameter(
			"drift_speed")
		var dynamic_fog_ok: bool = float(spring.get("_fog_time")) \
			>= fog_time_before + 0.49 \
			and drift.length() >= 0.01 \
			and float(spring.fog_material.get_shader_parameter(
				"motion_speed")) >= 1.9 \
			and float(spring.fog_material.get_shader_parameter(
				"turbulence_strength")) > 0.0 \
			and float(spring.fog_material.get_shader_parameter(
				"pulse_strength")) > 0.0
		checks.append("视觉雾具有多层漂移、涡流与呼吸起伏：%s" % [
			str(dynamic_fog_ok)])
		var previous_speed := GameClock.speed
		var previous_paused := GameClock.paused
		var previous_phase := GameClock.phase
		GameClock.phase = GameClock.Phase.RUNNING
		GameClock.paused = false
		GameClock.set_speed(GameClock.Speed.X1)
		var fog_delta_x1: float = float(spring.call(
			"_fog_time_delta", 0.25))
		GameClock.set_speed(GameClock.Speed.X4)
		var fog_delta_x4: float = float(spring.call(
			"_fog_time_delta", 0.25))
		GameClock.paused = true
		var fog_delta_paused: float = float(spring.call(
			"_fog_time_delta", 0.25))
		GameClock.speed = previous_speed
		GameClock.paused = previous_paused
		GameClock.phase = previous_phase
		checks.append("雾速跟随游戏倍速并在暂停时冻结：%s（%.3f / %.3f / %.3f）" % [
			str(
				is_equal_approx(fog_delta_x1, 0.25)
				and is_equal_approx(fog_delta_x4, 1.0)
				and is_zero_approx(fog_delta_paused)),
			fog_delta_x1,
			fog_delta_x4,
			fog_delta_paused,
		])
		var light_response_ok: bool = float(
			spring.fog_material.get_shader_parameter(
				"sun_energy")) > 0.0 \
			and float(spring.fog_material.get_shader_parameter(
				"sun_response")) > 0.0 \
			and float(spring.fog_material.get_shader_parameter(
				"evaporation")) > 0.0 \
			and float(spring.fog_material.get_shader_parameter(
				"scatter_strength")) > 0.0 \
			and float(spring.fog_material.get_shader_parameter(
				"light_brightness")) > 0.5 \
			and float(spring.fog_material.get_shader_parameter(
				"no_light_brightness")) <= 0.10 \
			and float(spring.fog_material.get_shader_parameter(
				"sun_transition")) > 0.9
		checks.append("雾色、浓度与方向散射仅受太阳光影响：%s" % [
			str(light_response_ok)])
		var test_lamp_state: Dictionary = spring.call(
			"_update_lamp_state", 7.0)
		spring.call(
			"_update_surface_parameters",
			dawn_state,
			dawn_sun,
			test_lamp_state,
			0.0,
			7.0)
		var cloud_shadow_ok := true
		for material in spring.ground_materials + spring.surface_materials:
			var shader_material := material as ShaderMaterial
			if shader_material == null \
					or shader_material.get_shader_parameter(
						"cloud_shadow_texture") == null \
					or float(shader_material.get_shader_parameter(
						"cloud_shadow_active")) <= 0.9 \
					or float(shader_material.get_shader_parameter(
						"cloud_shadow_time")) <= 0.0:
				cloud_shadow_ok = false
				break
		var fog_cloud_independent: bool = \
			spring.fog_material.get_shader_parameter(
				"cloud_shadow_texture") == null \
			and spring.fog_material.get_shader_parameter(
				"world_building_shadow_texture") == null \
			and spring.fog_material.get_shader_parameter(
				"sky_energy") == null \
			and spring.fog_material.get_shader_parameter(
				"ambient_response") == null
		checks.append("天空云层独立作用于场景且不进入雾层：%s｜雾只受太阳光：%s" % [
			str(cloud_shadow_ok),
			str(fog_cloud_independent),
		])
		var predawn_state: Dictionary = spring.call(
			"_sample_light_state", 6.0)
		var lit_fog_state: Dictionary = spring.call(
			"_sample_light_state", 7.0)
		var predawn_brightness: float = float(spring.call(
			"_fog_light_brightness", predawn_state, 6.0))
		var lit_fog_brightness: float = float(spring.call(
			"_fog_light_brightness", lit_fog_state, 7.0))
		checks.append("无光时雾保持低亮度，受光后逐渐提亮：%s（%.3f → %.3f）" % [
			str(
				predawn_brightness < 0.18
				and lit_fog_brightness > 0.65
				and lit_fog_brightness - predawn_brightness > 0.5),
			predawn_brightness,
			lit_fog_brightness,
		])
		var sunrise_hour := SUNRISE_HOUR
		var sunrise_transition_start: float = float(spring.call(
			"_fog_sunrise_transition", sunrise_hour - 0.001))
		var sunrise_transition_begin: float = float(spring.call(
			"_fog_sunrise_transition", sunrise_hour))
		var sunrise_transition_mid: float = float(spring.call(
			"_fog_sunrise_transition", sunrise_hour + 0.25))
		var sunrise_transition_end: float = float(spring.call(
			"_fog_sunrise_transition", sunrise_hour + 0.5))
		checks.append("太阳出现时雾光照平滑过渡：%s（%.3f → %.3f → %.3f → %.3f）" % [
			str(
				sunrise_transition_start <= 0.001
				and sunrise_transition_begin <= 0.001
				and sunrise_transition_mid > 0.35
				and sunrise_transition_mid < 0.65
				and sunrise_transition_end >= 0.999),
			sunrise_transition_start,
			sunrise_transition_begin,
			sunrise_transition_mid,
			sunrise_transition_end,
		])
		spring._update_fog(9.0, 0.0)
		checks.append("视觉雾层在 09:00 隐藏：%s" % [
			str(not spring.fog_layer.visible)])
		WorldWeather.set_fog_force(-1)
		var midnight: Dictionary = spring._sample_light_state(2.0)
		var before_sunrise: Dictionary = spring._sample_light_state(
			SUNRISE_HOUR - 0.001)
		var sunrise: Dictionary = spring._sample_light_state(SUNRISE_HOUR)
		var dawn: Dictionary = spring._sample_light_state(6.5)
		var morning: Dictionary = spring._sample_light_state(7.0)
		var noon: Dictionary = spring._sample_light_state(12.0)
		var evening: Dictionary = spring._sample_light_state(18.5)
		var sunset: Dictionary = spring._sample_light_state(SUNSET_HOUR)
		var after_sunset: Dictionary = spring._sample_light_state(
			SUNSET_HOUR + 0.001)
		var dawn_color: Color = dawn["sun_color"]
		var evening_color: Color = evening["sun_color"]
		var sunrise_color: Color = sunrise["sun_color"]
		var noon_color: Color = noon["sun_color"]
		var sunset_color: Color = sunset["sun_color"]
		checks.append("清晨太阳偏红：%s" % [
			str(dawn_color.r - dawn_color.g > 0.35)])
		checks.append("傍晚太阳偏红：%s" % [
			str(evening_color.r - evening_color.g > 0.25)])
		checks.append("日出最红、正午最白、日落最红：%s" % [
			str(
				sunrise_color.r - sunrise_color.g > 0.45
				and sunset_color.r - sunset_color.g > 0.45
				and noon_color.r - noon_color.b < 0.08)])
		checks.append("太阳只在 06:25–19:25 发光：%s（%.4f→%.4f / %.4f→%.4f）" % [
			str(
				is_zero_approx(float(before_sunrise["sun_energy"]))
				and float(sunrise["sun_energy"]) > 0.0
				and float(sunset["sun_energy"]) > 0.0
				and is_zero_approx(float(after_sunset["sun_energy"]))),
			float(before_sunrise["sun_energy"]),
			float(sunrise["sun_energy"]),
			float(sunset["sun_energy"]),
			float(after_sunset["sun_energy"]),
		])
		checks.append("太阳能量晨增暮减：%s" % [
			str(
				float(sunrise["sun_energy"]) < float(morning["sun_energy"])
				and float(morning["sun_energy"]) < float(noon["sun_energy"])
				and float(sunset["sun_energy"]) < float(evening["sun_energy"])
				and float(evening["sun_energy"]) < float(noon["sun_energy"]))])
		var night_exposure := float(midnight["exposure"])
		var day_exposure := float(noon["exposure"])
		checks.append("夜间曝光低于白天且保持可辨识：%s（%.2f < %.2f）" % [
			str(
				night_exposure < day_exposure
				and night_exposure <= 0.62),
			night_exposure,
			day_exposure,
		])
		checks.append("夜间环境亮度已降低：%s（%.2f）" % [
			str(float(midnight["sky_energy"]) <= 0.05),
			float(midnight["sky_energy"]),
		])
		var softness := float(spring.config.get(
			"sun", {}).get("wall_facing_softness", 0.08))
		var wall_at_1130 := smoothstep(
			-softness,
			softness,
			spring._sun_to_screen_direction(11.5).y)
		var wall_at_1230 := smoothstep(
			-softness,
			softness,
			spring._sun_to_screen_direction(12.5).y)
		var wall_at_1330 := smoothstep(
			-softness,
			softness,
			spring._sun_to_screen_direction(13.5).y)
		var wall_at_1400 := smoothstep(
			-softness,
			softness,
			spring._sun_to_screen_direction(14.0).y)
		checks.append(
			"墙面背光变化连续且单调：%s（%.2f→%.2f→%.2f→%.2f）" % [
				str(
					wall_at_1130 < 0.02
					and wall_at_1130 < wall_at_1230
					and wall_at_1230 < wall_at_1330
					and wall_at_1330 < wall_at_1400
					and wall_at_1400 > 0.98),
				wall_at_1130,
				wall_at_1230,
				wall_at_1330,
				wall_at_1400,
			])
		var wall_building: Building = null
		for building in main.get_node("World").buildings:
			if building.id == "shop_small":
				wall_building = building
				break
		var materials: Array = spring.building_materials.get(wall_building, [])
		if materials.size() >= 2:
			var wall_material := materials[0] as ShaderMaterial
			var roof_material := materials[1] as ShaderMaterial
			checks.append("墙面排除自身投影并启用背光整面判定：%s / %s" % [
				str(bool(wall_material.get_shader_parameter(
					"ignore_self_projected_shadow"))),
				str(bool(wall_material.get_shader_parameter(
					"apply_wall_facing_gate"))),
			])
			checks.append("屋顶排除自身地面投影：%s" % [
				str(bool(roof_material.get_shader_parameter(
					"ignore_self_projected_shadow")))])
			checks.append("墙面整面渐变宽度已写入材质：%s（%.3f）" % [
				str(is_equal_approx(
					float(wall_material.get_shader_parameter(
						"wall_facing_softness")),
					softness)),
				float(wall_material.get_shader_parameter(
					"wall_facing_softness")),
			])
			var wall_rect: Vector4 = wall_material.get_shader_parameter(
				"wall_shadow_rect_uv")
			checks.append("墙面启用太阳长度与角度驱动的回正剪切：%s" % [
				str(
					bool(wall_material.get_shader_parameter(
						"apply_wall_shadow_projection"))
					and not bool(roof_material.get_shader_parameter(
						"apply_wall_shadow_projection"))
					and wall_rect.is_finite()
					and wall_rect.z > wall_rect.x
					and wall_rect.w > wall_rect.y)
			])
			checks.append("墙面判定区使用建筑专属太阳阴影通道：%s" % [
				str(
					not spring.rig.building_sun_pass.is_empty()
					and spring.rig.get_building_sun_texture() != null
					and wall_material.get_shader_parameter(
						"building_sun_shadow_texture") \
						== spring.rig.get_building_sun_texture())
			])
			var wall_foot_uv := float(wall_material.get_shader_parameter(
				"surface_foot_uv_y"))
			var wall_layers: Dictionary = wall_building.data.get(
				"sprite_layers", {})
			var wall_region: Array = wall_layers.get(
				"wall_region_px", [0.0, 0.0, 1.0, 240.0])
			var wall_canvas: Array = wall_layers.get(
				"canvas", [1.0, 256.0])
			var expected_wall_foot_uv := (
				float(wall_region[1]) + float(wall_region[3])) \
				/ maxf(float(wall_canvas[1]), 1.0)
			checks.append("墙面接入角色太阳阴影并在墙底接缝连续：%s" % [
				str(
					bool(wall_material.get_shader_parameter(
						"apply_player_sun_shadow"))
					and wall_material.get_shader_parameter(
						"player_sun_shadow_texture") \
						== spring.rig.get_player_sun_texture()
					and is_equal_approx(
						float(wall_material.get_shader_parameter(
							"player_wall_shadow_height_px")),
						44.0)
					and is_equal_approx(wall_foot_uv, expected_wall_foot_uv))
			])
		var lodge: Building = null
		for building in main.get_node("World").buildings:
			if building.id == "lodge_ordinary":
				lodge = building
				break
		var world := main.get_node("World")
		var terrain_material := lodge.ground_terrain.material as ShaderMaterial \
			if lodge != null and lodge.ground_terrain != null else null
		var previous_view := int(world.view_mode)
		world.set_view_mode(World.ViewMode.ROOF)
		var roof_visible := lodge.ground_terrain.visible \
			if lodge != null and lodge.ground_terrain != null else false
		world.set_view_mode(World.ViewMode.INTERIOR)
		var interior_hidden := not lodge.ground_terrain.visible \
			if lodge != null and lodge.ground_terrain != null else false
		world.set_view_mode(World.ViewMode.GROUND)
		var ground_hidden := not lodge.ground_terrain.visible \
			if lodge != null and lodge.ground_terrain != null else false
		world.set_view_mode(previous_view)
		checks.append("新增 ground 地形层仅屋顶视图显示：%s（%s / %s / %s）" % [
			str(roof_visible and interior_hidden and ground_hidden),
			str(roof_visible),
			str(interior_hidden),
			str(ground_hidden),
		])
		checks.append("ground 层使用地面光照材质：%s" % [
			str(
				terrain_material != null
				and spring.ground_materials.has(terrain_material)
				and terrain_material.shader != null
				and terrain_material.shader.resource_path.ends_with(
					"spring_tile.gdshader")
				and terrain_material.get_shader_parameter(
					"normal_texture") != null)])
		spring._update_window_effects(
			midnight,
			spring._sun_to_screen_direction(1.0),
			1.0)
		var portal_entry: Dictionary = spring.portal_entries.get(lodge, {})
		var emission_materials: Array = portal_entry.get(
			"emission_materials", [])
		var lamp_config: Dictionary = DataRegistry.get_building(
			"street_lamp").get("street_lamp_lighting", {})
		var lamp_color := Color.from_string(
			str(lamp_config.get("color", "#ffd36a")),
			Color("#ffd36a"))
		var expected_spill_range := 17.5
		var expected_spill_energy := float(
			lamp_config.get("player_energy", 2.6)) * 0.09
		var expected_spill_height := float(
			lamp_config.get("height_px", 44.0))
		var expected_head_energy := float(
			lamp_config.get("glow_energy", 1.0)) * 0.3
		var window_lamp_state: Dictionary = spring._update_lamp_state(
			1.0,
			float(midnight["sun_energy"]))
		var shadow_count := int(window_lamp_state.get("shadow_count", 0))
		var window_light_indices: Array[int] = []
		var all_lights: Array = window_lamp_state.get("lights", [])
		for index in range(all_lights.size()):
			var light_spec: Dictionary = all_lights[index]
			if bool(light_spec.get("window_light", false)):
				window_light_indices.append(index)
		var window_light_ok := window_light_indices.size() >= 2 \
			and emission_materials.size() >= 2
		var window_positions: Array[Vector2] = []
		for sprite_value in portal_entry.get("emission_sprites", []):
			var window_sprite := sprite_value as Sprite2D
			if window_sprite != null:
				window_positions.append(window_sprite.global_position)
		if window_light_ok:
			var emission_material := emission_materials[0] as ShaderMaterial
			var emission_sprite := portal_entry.get(
				"emission_sprites", [])[0] as Sprite2D
			var emission_color := emission_material.get_shader_parameter(
				"emission_color") as Color
			window_light_ok = emission_color.is_equal_approx(lamp_color) \
				and is_equal_approx(
					float(emission_material.get_shader_parameter(
						"emission_energy")),
					expected_head_energy) \
				and is_equal_approx(
					emission_sprite.scale.x * 64.0,
					19.0)
			for light_index in window_light_indices:
				var light_spec: Dictionary = all_lights[light_index]
				var matches_window_position := false
				for window_position in window_positions:
					if (light_spec["position"] as Vector2).is_equal_approx(
							window_position):
						matches_window_position = true
						break
				window_light_ok = window_light_ok \
					and light_index >= shadow_count \
					and matches_window_position \
					and (light_spec["color"] as Color).is_equal_approx(
						lamp_color) \
					and is_equal_approx(
						float(light_spec["energy"]),
						expected_spill_energy) \
					and is_equal_approx(
						float(light_spec["range"]),
						expected_spill_range) \
					and is_equal_approx(
						float(light_spec["attenuation_range"]),
						expected_spill_range * 1.75) \
					and is_equal_approx(
						float(light_spec["attenuation_power"]),
						4.0) \
					and is_equal_approx(
						float(light_spec["attenuation_curve"]),
						2.0) \
					and is_equal_approx(
						float(light_spec["ground_ellipse_aspect"]),
						1.0) \
					and is_equal_approx(
						float(light_spec["height"]),
						expected_spill_height)
		checks.append("窗户矩形灯头光 + 无阴影路灯局部光：%s（%d 盏）" % [
			str(window_light_ok),
			window_light_indices.size(),
		])
		var lamp_z_ok := true
		for building in main.get_node("World").buildings:
			var lamp_glow := spring.lamp_glows.get(building) as Sprite2D
			if lamp_glow != null and lamp_glow.z_index < 2:
				lamp_z_ok = false
		checks.append("灯头光层级：窗户在角色后方 %s｜路灯头盖住角色 %s" % [
			str(lodge.window_leak_root != null
				and lodge.window_leak_root.z_index == 0),
			str(lamp_z_ok),
		])

	var failed := 0
	for line in checks:
		print("[weather-event-check] %s" % line)
		if line.contains("false"):
			failed += 1
	print("[weather-event-check] 结果：%s（失败 %d）" % [
		"通过" if failed == 0 else "失败",
		failed,
	])
	get_tree().quit(0 if failed == 0 else 1)
