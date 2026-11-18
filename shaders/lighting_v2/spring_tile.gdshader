shader_type canvas_item;
render_mode unshaded;

#include "res://shaders/lighting_v2/world_cloud_shadow.gdshaderinc"
#include "res://shaders/lighting_v2/rain_ground.gdshaderinc"

uniform sampler2D normal_texture : filter_linear, repeat_disable;
uniform sampler2D specular_texture : filter_linear, repeat_disable;
uniform sampler2D occlusion_texture : filter_linear, repeat_disable;
uniform sampler2D sun_shadow_texture : filter_linear, repeat_disable;
uniform sampler2D detail_sun_shadow_texture : filter_linear, repeat_disable;
uniform sampler2D player_sun_shadow_texture : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_0 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_1 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_2 : filter_linear, repeat_disable;
uniform sampler2D lamp_shadow_texture_3 : filter_linear, repeat_disable;
uniform sampler2D grass_noise_shadow_texture : filter_linear, repeat_enable;
uniform float grass_noise_shadow_strength : hint_range(0.0, 0.6) = 0.0;
uniform float grass_noise_shadow_time = 0.0;
uniform vec2 grass_noise_shadow_offset_px = vec2(0.0);
uniform float grass_noise_shadow_rotation = 0.0;
uniform float grass_noise_shadow_scale_px = 1800.0;
uniform vec2 grass_noise_shadow_drift_px = vec2(1.2, 0.4);
uniform float grass_noise_shadow_threshold : hint_range(0.0, 1.0) = 0.40;
uniform float grass_noise_shadow_softness : hint_range(0.01, 0.5) = 0.26;

uniform vec3 sun_direction = vec3(0.0, 0.6, 0.8);
uniform vec3 sun_screen_direction = vec3(0.0, 0.0, 1.0);
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
uniform float local_light_window_cutoff_ys[32];
uniform float local_light_window_cutoff_fades[32];
uniform float local_light_window_flags[32];
uniform float lamp_shadow_strength : hint_range(0.0, 1.0) = 0.85;

uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.35;
uniform float occlusion_strength : hint_range(0.0, 1.0) = 0.82;
uniform int debug_mode = 0;

varying vec2 v_world_position;

void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

vec2 _grass_shadow_rotate(vec2 value, float angle) {
	float sine = sin(angle);
	float cosine = cos(angle);
	return mat2(vec2(cosine, -sine), vec2(sine, cosine)) * value;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	if (base.a <= 0.001) {
		discard;
	}
	float macro_variation = sin(v_world_position.x * 0.019)
		+ sin(v_world_position.y * 0.027 + 1.7)
		+ sin((v_world_position.x + v_world_position.y) * 0.011);
	base.rgb *= clamp(1.0 + macro_variation * 0.022, 0.90, 1.10);

	vec3 encoded_normal = texture(normal_texture, UV).rgb * 2.0 - 1.0;
	encoded_normal.xy *= normal_strength;
	vec3 normal = normalize(vec3(
		encoded_normal.x,
		-encoded_normal.y,
		max(encoded_normal.z, 0.08)));

	float ao = texture(occlusion_texture, UV).r;
	float gloss = texture(specular_texture, UV).r;
	vec3 rain_puddle_fields = rain_puddle_masks(v_world_position);
	float rain_puddle = rain_puddle_fields.x;
	float rain_inner = rain_puddle_fields.y;
	float rain_reflection_value = rain_puddle_fields.z;
	float rain_shore = clamp(rain_puddle - rain_inner, 0.0, 1.0);
	float rain_splash = rain_splash_mask(v_world_position);
	float ripple_center = rain_ripple_sample(SCREEN_UV);
	float ripple_left = rain_ripple_sample(
		SCREEN_UV - vec2(water_ripple_texel_size.x * 1.5, 0.0));
	float ripple_right = rain_ripple_sample(
		SCREEN_UV + vec2(water_ripple_texel_size.x * 1.5, 0.0));
	float ripple_up = rain_ripple_sample(
		SCREEN_UV - vec2(0.0, water_ripple_texel_size.y * 1.5));
	float ripple_down = rain_ripple_sample(
		SCREEN_UV + vec2(0.0, water_ripple_texel_size.y * 1.5));
	vec2 ripple_gradient = vec2(
		ripple_right - ripple_left,
		ripple_down - ripple_up);
	vec2 reflection_uv = clamp(
		SCREEN_UV
		+ ripple_gradient * rain_ripple_uv_strength
			* rain_puddle,
		vec2(0.0),
		vec2(1.0));
	vec3 rain_reflection = texture(
		water_reflection_texture,
		reflection_uv).rgb;
	normal = normalize(mix(
		normal,
		vec3(0.0, 0.0, 1.0),
		rain_puddle * 0.92));
	normal = normalize(normal + vec3(
		ripple_gradient.x * 9.0 * rain_puddle,
		ripple_gradient.y * 9.0 * rain_puddle,
		0.0));
	ao = mix(ao, 1.0, rain_puddle);
	gloss = mix(gloss, max(gloss, 0.90), rain_puddle);
	base.rgb *= mix(1.0, 0.88, rain_intensity);
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
	float detail_sun_luminance = dot(
		texture(detail_sun_shadow_texture, SCREEN_UV).rgb,
		vec3(0.2126, 0.7152, 0.0722));
	float detail_sun_visibility = smoothstep(
		0.08,
		0.72,
		detail_sun_luminance);
	sun_visibility *= detail_sun_visibility;
	float player_sun_luminance = dot(
		texture(player_sun_shadow_texture, SCREEN_UV).rgb,
		vec3(0.2126, 0.7152, 0.0722));
	float player_sun_visibility = smoothstep(
		0.10,
		0.82,
		player_sun_luminance);
	sun_visibility *= player_sun_visibility;
	float cloud_shadow_transmission = sample_world_cloud_transmission(
		v_world_position,
		sun_screen_direction);
	sun_visibility *= cloud_shadow_transmission;
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
		float ground_distance = length(ground_delta);
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
		float window_ground_gate = smoothstep(
			local_light_window_cutoff_ys[light_index]
				- local_light_window_cutoff_fades[light_index],
			local_light_window_cutoff_ys[light_index]
				+ local_light_window_cutoff_fades[light_index],
			v_world_position.y);
		light_visibility *= mix(
			1.0,
			window_ground_gate,
			local_light_window_flags[light_index]);
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
	lit *= 1.0 - 0.22 * (1.0 - detail_sun_visibility)
		* smoothstep(0.015, 0.22, sun_energy);
	vec3 water_lighting = sky_ambient + sun_direct + local_direct;
	float water_light_energy = dot(
		water_lighting,
		vec3(0.2126, 0.7152, 0.0722));
	float water_light_driver = smoothstep(
		0.012,
		0.42,
		water_light_energy);
	float water_alpha = mix(0.045, 1.0, water_light_driver);
	float water_brightness = mix(0.08, 1.0, water_light_driver);
	vec3 puddle_base = mix(
		base.rgb * 0.24,
		sky_color * 0.15,
		mix(0.30, 0.58, rain_inner));
	vec3 puddle_lit = puddle_base * water_lighting
		+ local_specular * 0.82
		+ sun_color * sun_energy * sun_specular
			* sun_visibility * specular_strength * 0.28;
	puddle_lit *= water_brightness;
	vec3 reflected_water = puddle_lit * 0.16
		+ rain_reflection * mix(0.35, 0.85, rain_inner)
			* water_brightness;
	float reflection_weight = rain_reflection_strength
		* mix(0.25, 0.92, rain_reflection_value);
	vec3 water_color = mix(
		puddle_lit,
		reflected_water,
		reflection_weight);
	float puddle_alpha = rain_puddle * water_alpha
		* mix(0.32, 1.0, rain_reflection_value);
	lit = mix(
		lit * mix(1.0, 0.88, rain_intensity),
		water_color,
		puddle_alpha);
	lit += sky_color * rain_shore * 0.08
		* water_alpha * water_brightness;
	lit += sky_color * ripple_center * rain_puddle
		* rain_ripple_strength * (0.045 + sky_energy * 0.065)
		* water_alpha * water_brightness;
	vec3 splash_lighting = sky_ambient + sun_direct + local_direct;
	float splash_light_energy = dot(
		splash_lighting,
		vec3(0.2126, 0.7152, 0.0722));
	float splash_visibility = mix(
		0.06,
		1.0,
		smoothstep(0.006, 0.20, splash_light_energy));
	vec3 splash_color = sky_color * (0.06 + sky_energy * 0.28)
		+ sun_color * sun_energy * 0.16
		+ local_direct * 0.42;
	lit += splash_color * rain_splash * splash_visibility;
	float grass_noise_shadow = 0.0;
	if (grass_noise_shadow_strength > 0.001) {
		vec2 grass_uv = (
			v_world_position
			+ grass_noise_shadow_offset_px
			+ grass_noise_shadow_drift_px * grass_noise_shadow_time)
			/ max(grass_noise_shadow_scale_px, 1.0);
		grass_uv = _grass_shadow_rotate(
			grass_uv,
			grass_noise_shadow_rotation);
		float grass_noise_a = texture(
			grass_noise_shadow_texture,
			grass_uv).r;
		float grass_noise_b = texture(
			grass_noise_shadow_texture,
			_grass_shadow_rotate(
				grass_uv * 1.73,
				-0.61)).g;
		float grass_density = grass_noise_a * 0.68
			+ grass_noise_b * 0.32;
		grass_noise_shadow = smoothstep(
			grass_noise_shadow_threshold,
			grass_noise_shadow_threshold
				+ grass_noise_shadow_softness,
			grass_density);
	}
	lit *= 1.0 - grass_noise_shadow_strength * grass_noise_shadow;
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
	} else if (debug_mode == 12) {
		COLOR = vec4(vec3(rain_puddle), 1.0);
	} else if (debug_mode == 13) {
		COLOR = vec4(vec3(ripple_center), 1.0);
	} else if (debug_mode == 14) {
		COLOR = vec4(rain_reflection, 1.0);
	} else {
		COLOR = vec4(lit * exposure, base.a);
	}
}
