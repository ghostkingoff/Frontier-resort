shader_type canvas_item;
render_mode unshaded;

uniform sampler2D normal_texture : filter_linear, repeat_disable;
uniform sampler2D specular_texture : filter_linear, repeat_disable;
uniform sampler2D occlusion_texture : filter_linear, repeat_disable;
uniform sampler2D normal_texture_nearest : filter_nearest, repeat_disable;
uniform sampler2D specular_texture_nearest : filter_nearest, repeat_disable;
uniform sampler2D occlusion_texture_nearest : filter_nearest, repeat_disable;
uniform bool use_nearest_surface = false;
uniform sampler2D sun_shadow_texture : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_0 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_1 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_2 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_3 : filter_linear, repeat_disable;

uniform vec4 atlas_frame_uv = vec4(0.0, 0.0, 1.0, 1.0);
uniform bool use_shared_atlas_uv = false;
uniform bool receive_projected_shadow = false;
uniform bool ignore_self_projected_shadow = false;
uniform vec4 self_shadow_world_rect = vec4(
	-1000000.0, -1000000.0, 1000000.0, 1000000.0);
uniform bool apply_wall_facing_gate = false;
uniform vec2 wall_facing_normal = vec2(0.0, 1.0);
uniform float wall_facing_softness : hint_range(0.001, 0.25) = 0.08;
uniform bool apply_character_facing_gate = false;
uniform vec2 character_facing_anchor_world = vec2(0.0);
uniform float character_shadow_transition_px : hint_range(0.1, 128.0) = 48.0;
uniform float character_sun_transition : hint_range(0.001, 0.5) = 0.08;
uniform bool clip_to_normal_alpha = true;
uniform float canvas_height_px = 256.0;
uniform float surface_foot_uv_y = 1.0;

uniform vec3 sun_direction = vec3(0.0, 0.6, 0.8);
uniform vec3 sun_screen_direction = vec3(0.0, 0.0, 1.0);
uniform vec3 sun_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float sun_energy : hint_range(0.0, 4.0) = 1.0;
uniform vec3 sky_color : source_color = vec3(0.62, 0.72, 0.66);
uniform float sky_energy : hint_range(0.0, 2.0) = 0.58;
uniform float exposure : hint_range(0.1, 3.0) = 1.0;
uniform vec3 interior_light_color : source_color = vec3(1.0, 0.78, 0.52);
uniform float interior_light_energy : hint_range(0.0, 3.0) = 0.0;

uniform int local_light_count = 0;
uniform int shadowed_light_count = 0;
uniform vec4 local_light_positions[32];
uniform vec4 local_light_colors[32];
uniform float local_light_falloff_powers[32];
uniform float lamp_shadow_strength : hint_range(0.0, 1.0) = 0.85;

uniform vec2 camera_zoom = vec2(1.0);
uniform vec2 viewport_size_px = vec2(1280.0, 720.0);
uniform float max_projected_offset_px = 260.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.9;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.3;
uniform float occlusion_strength : hint_range(0.0, 1.0) = 0.7;
uniform int debug_mode = 0;

varying vec2 v_map_uv;
varying vec2 v_world_position;

void vertex() {
	v_map_uv = atlas_frame_uv.xy + UV * atlas_frame_uv.zw;
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 map_uv = use_shared_atlas_uv ? UV : v_map_uv;
	if (!use_shared_atlas_uv
			&& (atlas_frame_uv.z < 0.999 || atlas_frame_uv.w < 0.999)) {
		vec2 atlas_size = vec2(textureSize(normal_texture, 0));
		vec2 half_texel = 0.5 / atlas_size;
		vec2 frame_min = atlas_frame_uv.xy + half_texel;
		vec2 frame_max = atlas_frame_uv.xy + atlas_frame_uv.zw - half_texel;
		map_uv = clamp(v_map_uv, frame_min, frame_max);
	}
	vec4 normal_sample = use_nearest_surface
		? texture(normal_texture_nearest, map_uv)
		: texture(normal_texture, map_uv);
	float alpha_mask = base.a;
	if (clip_to_normal_alpha) {
		alpha_mask *= normal_sample.a;
	}
	if (alpha_mask <= 0.001) {
		discard;
	}

	vec3 encoded_normal = normal_sample.rgb * 2.0 - 1.0;
	encoded_normal.xy *= normal_strength;
	vec3 normal = normalize(vec3(
		encoded_normal.x,
		-encoded_normal.y,
		max(encoded_normal.z, 0.08)));

	float ao = use_nearest_surface
		? texture(occlusion_texture_nearest, map_uv).r
		: texture(occlusion_texture, map_uv).r;
	float gloss = use_nearest_surface
		? texture(specular_texture_nearest, map_uv).r
		: texture(specular_texture, map_uv).r;
	float ambient_ao = mix(1.0, ao, occlusion_strength);

	vec3 to_sun = normalize(sun_direction);
	float sun_ndotl = max(dot(normal, to_sun), 0.0);

	vec2 shadow_uv = SCREEN_UV;
	vec2 projected_world = v_world_position;
	if (receive_projected_shadow) {
		float height_px = max(
			(surface_foot_uv_y - UV.y) * canvas_height_px,
			0.0);
		float horizontal_light = length(sun_screen_direction.xy);
		float vertical_light = max(sun_screen_direction.z, 0.12);
		float stretch = horizontal_light / vertical_light;
		float projected_distance = min(
			height_px * stretch,
			max_projected_offset_px);
		vec2 projected_direction = normalize(
			sun_screen_direction.xy + vec2(0.00001));
		projected_world += projected_direction * projected_distance;
		vec2 screen_offset = projected_direction * projected_distance
			* camera_zoom
			/ viewport_size_px;
		shadow_uv = clamp(
			SCREEN_UV + screen_offset,
			vec2(0.0),
			vec2(1.0));
	}

	float sun_visibility_luminance = dot(
		texture(sun_shadow_texture, shadow_uv).rgb,
		vec3(0.2126, 0.7152, 0.0722));
	float self_shadow_mask = step(
		self_shadow_world_rect.x,
		projected_world.x)
		* step(projected_world.x, self_shadow_world_rect.z)
		* step(self_shadow_world_rect.y, projected_world.y)
		* step(projected_world.y, self_shadow_world_rect.w);
	float self_world_mask = step(
		self_shadow_world_rect.x,
		v_world_position.x)
		* step(v_world_position.x, self_shadow_world_rect.z)
		* step(self_shadow_world_rect.y, v_world_position.y)
		* step(v_world_position.y, self_shadow_world_rect.w);
	sun_visibility_luminance = mix(
		sun_visibility_luminance,
		1.0,
		self_shadow_mask * float(ignore_self_projected_shadow));
	float sun_visibility = smoothstep(
		0.015,
		0.72,
		sun_visibility_luminance);
	float wall_facing_visibility = 1.0;
	if (apply_wall_facing_gate) {
		float facing = dot(
			normalize(wall_facing_normal),
			sun_screen_direction.xy);
		wall_facing_visibility = smoothstep(
			-wall_facing_softness,
			wall_facing_softness,
			facing);
	}
	sun_visibility *= wall_facing_visibility;
	if (apply_character_facing_gate) {
		float sun_above_foot = max(-sun_screen_direction.y, 0.0);
		float character_sun_facing = 1.0 - smoothstep(
			0.0,
			character_sun_transition,
			sun_above_foot);
		sun_visibility *= character_sun_facing;
	}
	vec3 sun_direct = sun_color * sun_energy
		* sun_ndotl * sun_visibility * mix(0.55, 1.0, ao);
	vec3 sky_ambient = sky_color * sky_energy * ambient_ao;
	vec3 interior_ambient = interior_light_color
		* interior_light_energy * ambient_ao;

	vec3 local_direct = vec3(0.0);
	vec3 local_specular = vec3(0.0);
	float lamp_visibility = 0.0;
	vec4 lamp_page_0 = texture(lamp_shadow_texture_0, SCREEN_UV);
	vec4 lamp_page_1 = texture(lamp_shadow_texture_1, SCREEN_UV);
	vec4 lamp_page_2 = texture(lamp_shadow_texture_2, SCREEN_UV);
	vec4 lamp_page_3 = texture(lamp_shadow_texture_3, SCREEN_UV);
	for (int light_index = 0; light_index < 32; light_index++) {
		if (light_index >= local_light_count) {
			break;
		}
		vec4 light_position = local_light_positions[light_index];
		vec4 light_color = local_light_colors[light_index];
		vec2 light_world = light_position.xy;
		float light_height = light_position.z;
		float light_range = max(light_position.w, 1.0);
		float light_energy = light_color.a;
		if (light_energy <= 0.001) {
			continue;
		}
		vec3 lamp_delta = vec3(
			light_world - v_world_position,
			light_height);
		float ground_distance = length(
			light_world - v_world_position);
		float radial = pow(
			clamp(1.0 - ground_distance / light_range, 0.0, 1.0),
			local_light_falloff_powers[light_index]);

		float light_visibility = 1.0;
		if (light_index < shadowed_light_count) {
			vec4 lamp_channels;
			if (light_index < 3) {
				lamp_channels = lamp_page_0;
			} else if (light_index < 6) {
				lamp_channels = lamp_page_1;
			} else if (light_index < 9) {
				lamp_channels = lamp_page_2;
			} else {
				lamp_channels = lamp_page_3;
			}
			int channel_index = light_index % 3;
			if (channel_index == 0) {
				light_visibility = lamp_channels.r;
			} else if (channel_index == 1) {
				light_visibility = lamp_channels.g;
			} else {
				light_visibility = lamp_channels.b;
			}
			light_visibility = smoothstep(
				0.008,
				0.20,
				light_visibility);
			light_visibility = mix(
				1.0,
				light_visibility,
				lamp_shadow_strength);
			if (ignore_self_projected_shadow) {
				light_visibility = mix(
					light_visibility,
					1.0,
					self_world_mask);
			}
		}
		if (apply_character_facing_gate) {
			float foot_below_light = max(
				character_facing_anchor_world.y - light_world.y,
				0.0);
			float light_facing = 1.0 - smoothstep(
				0.0,
				character_shadow_transition_px,
				foot_below_light);
			light_visibility *= light_facing;
		}
		lamp_visibility = max(lamp_visibility, light_visibility);

		vec3 to_lamp = normalize(lamp_delta);
		float lamp_ndotl = max(dot(normal, to_lamp), 0.0);
		local_direct += light_color.rgb * light_energy
			* radial * lamp_ndotl * light_visibility;

		vec3 view_dir = vec3(0.0, 0.0, 1.0);
		vec3 half_dir = normalize(to_lamp + view_dir);
		float shininess = mix(10.0, 72.0, gloss);
		float specular = pow(
			max(dot(normal, half_dir), 0.0),
			shininess) * gloss;
		local_specular += light_color.rgb * light_energy
			* radial * specular * specular_strength * light_visibility;
	}

	vec3 view_dir_sun = vec3(0.0, 0.0, 1.0);
	vec3 sun_half = normalize(to_sun + view_dir_sun);
	float sun_shininess = mix(10.0, 72.0, gloss);
	float sun_specular = pow(
		max(dot(normal, sun_half), 0.0),
		sun_shininess) * gloss;

	vec3 lit = base.rgb * (
		sky_ambient + interior_ambient + sun_direct + local_direct)
		+ sun_color * sun_energy * sun_specular
			* sun_visibility * specular_strength
		+ local_specular;
	if (debug_mode == 1) {
		COLOR = vec4(base.rgb, alpha_mask);
	} else if (debug_mode == 2) {
		COLOR = vec4(normal * 0.5 + 0.5, alpha_mask);
	} else if (debug_mode == 3) {
		COLOR = vec4(vec3(gloss), alpha_mask);
	} else if (debug_mode == 4) {
		COLOR = vec4(vec3(ao), alpha_mask);
	} else if (debug_mode == 5) {
		COLOR = vec4(vec3(sun_visibility), alpha_mask);
	} else if (debug_mode == 6) {
		COLOR = vec4(vec3(lamp_visibility), alpha_mask);
	} else if (debug_mode == 7) {
		COLOR = vec4(
			clamp(lamp_page_0.rgb * 4.0, 0.0, 1.0),
			alpha_mask);
	} else if (debug_mode == 8) {
		COLOR = vec4(
			clamp(lamp_page_1.rgb * 4.0, 0.0, 1.0),
			alpha_mask);
	} else if (debug_mode == 9) {
		COLOR = vec4(
			clamp(lamp_page_2.rgb * 4.0, 0.0, 1.0),
			alpha_mask);
	} else if (debug_mode == 10) {
		COLOR = vec4(
			clamp(lamp_page_3.rgb * 4.0, 0.0, 1.0),
			alpha_mask);
	} else {
		COLOR = vec4(lit * exposure, alpha_mask);
	}
}
