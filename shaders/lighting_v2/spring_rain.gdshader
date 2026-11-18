shader_type canvas_item;
render_mode unshaded;

uniform vec2 camera_origin_px = vec2(0.0);
uniform vec2 camera_zoom = vec2(1.0);
uniform vec2 viewport_size_px = vec2(1920.0, 1080.0);
uniform float rain_time_seconds = 0.0;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float rain_density : hint_range(0.0, 1.0) = 0.33;
uniform float rain_slant : hint_range(-0.5, 0.5) = 0.10;
uniform vec3 rain_color : source_color = vec3(0.72, 0.83, 0.86);
uniform float rain_opacity : hint_range(0.0, 1.0) = 0.52;
uniform float rain_mist : hint_range(0.0, 0.5) = 0.08;
uniform int local_light_count = 0;
uniform vec4 local_light_positions[32];
uniform vec4 local_light_colors[32];
uniform float local_light_falloff_powers[32];

float rain_hash_12(vec2 value) {
	vec3 p3 = fract(vec3(value.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float rain_layer(
		vec2 world_position,
		vec2 cell_size,
		float fall_speed,
		float layer_seed,
		float line_width,
		float opacity) {
	vec2 rain_position = world_position;
	rain_position.x += rain_position.y * rain_slant;
	rain_position.y -= rain_time_seconds * fall_speed;
	vec2 grid = rain_position / cell_size;
	vec2 cell = floor(grid);
	vec2 local = fract(grid);
	float random_value = rain_hash_12(cell + vec2(layer_seed, layer_seed * 0.37));
	if (random_value > rain_density) {
		return 0.0;
	}
	float center_x = 0.22 + 0.56 * fract(random_value * 91.73);
	float top = 0.08 + 0.20 * fract(random_value * 37.11);
	float bottom = 0.62 + 0.33 * fract(random_value * 57.47);
	float across = abs(local.x - center_x);
	float line = 1.0 - smoothstep(line_width, line_width * 2.6, across);
	float segment = smoothstep(top, top + 0.035, local.y)
		* (1.0 - smoothstep(bottom - 0.08, bottom, local.y));
	float length_fade = smoothstep(0.18, 0.86, local.y);
	return line * segment * mix(0.62, 1.0, length_fade)
		* mix(0.45, 1.0, fract(random_value * 113.9)) * opacity;
}

void fragment() {
	vec2 world_px = camera_origin_px
		+ (SCREEN_UV - vec2(0.5))
		* viewport_size_px
		/ max(camera_zoom, vec2(0.001));
	float far_rain = rain_layer(
		world_px,
		vec2(15.0, 74.0),
		560.0,
		11.0,
		0.030,
		0.34);
	float near_rain = rain_layer(
		world_px + vec2(5.0, 17.0),
		vec2(25.0, 118.0),
		920.0,
		31.0,
		0.018,
		0.58);
	float streak = clamp(far_rain + near_rain, 0.0, 1.0);
	vec3 local_light = vec3(0.0);
	for (int light_index = 0; light_index < 32; light_index++) {
		if (light_index >= local_light_count) {
			break;
		}
		vec4 light_position = local_light_positions[light_index];
		vec4 light_color = local_light_colors[light_index];
		float energy = light_color.a;
		if (energy <= 0.001) {
			continue;
		}
		float light_range = max(light_position.w, 1.0);
		float radial = pow(
			clamp(
				1.0 - distance(
					world_px,
					light_position.xy) / light_range,
				0.0,
				1.0),
			max(local_light_falloff_powers[light_index], 0.1));
		local_light += light_color.rgb * energy * radial;
	}
	float local_light_energy = dot(
		local_light,
		vec3(0.2126, 0.7152, 0.0722));
	float local_light_visibility = smoothstep(
		0.006,
		0.22,
		local_light_energy);
	float mist_wave = 0.5 + 0.5 * sin(
		world_px.y * 0.011
		+ world_px.x * 0.007
		- rain_time_seconds * 0.28);
	mist_wave *= 0.55 + 0.45 * sin(
		world_px.x * 0.004
		- rain_time_seconds * 0.13);
	float alpha = (
		streak
		+ mist_wave * rain_mist
			* smoothstep(0.15, 0.9, SCREEN_UV.y))
		* rain_intensity * rain_opacity;
	alpha += streak * local_light_visibility
		* rain_intensity * 0.34;
	vec3 color = rain_color * mix(0.78, 1.15, near_rain)
		+ local_light * 0.24;
	COLOR = vec4(color, clamp(alpha, 0.0, 1.0));
}
