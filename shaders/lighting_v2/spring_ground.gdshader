shader_type canvas_item;
render_mode unshaded;

uniform sampler2D normal_texture : filter_linear, repeat_disable;
uniform sampler2D specular_texture : filter_linear, repeat_disable;
uniform sampler2D occlusion_texture : filter_linear, repeat_disable;
uniform sampler2D sun_shadow_texture : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_0 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_1 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_2 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_3 : filter_linear, repeat_disable;

uniform vec3 sun_direction = vec3(0.0, 0.6, 0.8);
uniform vec3 sun_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float sun_energy : hint_range(0.0, 4.0) = 1.0;
uniform vec3 sky_color : source_color = vec3(0.62, 0.72, 0.66);
uniform float sky_energy : hint_range(0.0, 2.0) = 0.58;
uniform float exposure : hint_range(0.1, 3.0) = 1.0;

uniform int local_light_count = 0;
uniform int shadowed_light_count = 0;
uniform vec4 local_light_positions[32];
uniform vec4 local_light_colors[32];
uniform float local_light_falloff_powers[32];
uniform float local_light_ground_ellipse_aspects[32];
uniform float local_light_attenuation_curves[32];
uniform float lamp_shadow_strength : hint_range(0.0, 1.0) = 0.85;

uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.35;
uniform float occlusion_strength : hint_range(0.0, 1.0) = 0.82;
uniform int debug_mode = 0;

varying vec2 v_world_position;

void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

vec2 _ground_tile_uv(vec2 uv) {
	vec2 texture_size = vec2(textureSize(normal_texture, 0));
	vec2 pixel = uv * texture_size;
	vec2 cell = floor(pixel / 32.0);
	vec2 local = pixel - cell * 32.0;
	local = clamp(local, vec2(1.25), vec2(30.75));
	return (cell * 32.0 + local) / texture_size;
}

void fragment() {
	vec2 tile_uv = _ground_tile_uv(UV);
	vec4 base = texture(TEXTURE, tile_uv);
	if (base.a <= 0.001) {
		discard;
	}
	float macro_variation = sin(v_world_position.x * 0.019)
		+ sin(v_world_position.y * 0.027 + 1.7)
		+ sin((v_world_position.x + v_world_position.y) * 0.011);
	base.rgb *= clamp(1.0 + macro_variation * 0.022, 0.90, 1.10);

	vec3 encoded_normal = texture(normal_texture, tile_uv).rgb * 2.0 - 1.0;
	encoded_normal.xy *= normal_strength;
	vec3 normal = normalize(vec3(
		encoded_normal.x,
		-encoded_normal.y,
		max(encoded_normal.z, 0.08)));

	float ao = texture(occlusion_texture, tile_uv).r;
	float gloss = texture(specular_texture, tile_uv).r;
	float ambient_ao = mix(1.0, ao, occlusion_strength);

	vec3 to_sun = normalize(sun_direction);
	float sun_ndotl = max(dot(normal, to_sun), 0.0);
	float sun_visibility_luminance = dot(
		texture(sun_shadow_texture, SCREEN_UV).rgb,
		vec3(0.2126, 0.7152, 0.0722));
	float sun_visibility = smoothstep(
		0.015,
		0.72,
		sun_visibility_luminance);
	vec3 sun_direct = sun_color * sun_energy
		* sun_ndotl * sun_visibility * mix(0.55, 1.0, ao);

	vec3 sky_ambient = sky_color * sky_energy * ambient_ao;

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
		vec2 ground_delta = light_world - v_world_position;
		ground_delta.y *= local_light_ground_ellipse_aspects[light_index];
		vec3 lamp_delta = vec3(ground_delta, light_height);
		float ground_distance = length(
			ground_delta);
		float radial_base = clamp(
			1.0 - ground_distance / light_range,
			0.0,
			1.0);
		float radial = pow(
			radial_base,
			local_light_falloff_powers[light_index]);
		if (local_light_attenuation_curves[light_index] > 1.5) {
			radial = radial_base;
		} else if (local_light_attenuation_curves[light_index] > 0.5) {
			float distance_ratio = 1.0 - radial_base;
			radial = radial_base / (1.0 + distance_ratio * 5.0);
		}

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
		sky_ambient + sun_direct + local_direct)
		+ sun_color * sun_energy * sun_specular
			* sun_visibility * specular_strength
		+ local_specular;
	if (debug_mode == 1) {
		COLOR = base;
	} else if (debug_mode == 2) {
		COLOR = vec4(normal * 0.5 + 0.5, 1.0);
	} else if (debug_mode == 3) {
		COLOR = vec4(vec3(gloss), 1.0);
	} else if (debug_mode == 4) {
		COLOR = vec4(vec3(ao), 1.0);
	} else if (debug_mode == 5) {
		COLOR = vec4(vec3(sun_visibility), 1.0);
	} else if (debug_mode == 6) {
		COLOR = vec4(vec3(lamp_visibility), 1.0);
	} else if (debug_mode == 7) {
		COLOR = vec4(clamp(lamp_page_0.rgb * 4.0, 0.0, 1.0), 1.0);
	} else if (debug_mode == 8) {
		COLOR = vec4(clamp(lamp_page_1.rgb * 4.0, 0.0, 1.0), 1.0);
	} else if (debug_mode == 9) {
		COLOR = vec4(clamp(lamp_page_2.rgb * 4.0, 0.0, 1.0), 1.0);
	} else if (debug_mode == 10) {
		COLOR = vec4(clamp(lamp_page_3.rgb * 4.0, 0.0, 1.0), 1.0);
	} else {
		COLOR = vec4(lit * exposure, base.a);
	}
}
