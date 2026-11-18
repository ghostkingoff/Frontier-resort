uniform sampler2D rain_noise_texture : filter_linear, repeat_enable;
uniform sampler2D water_reflection_texture : filter_linear, repeat_disable;
uniform sampler2D water_ripple_texture : filter_linear, repeat_disable;
uniform vec2 water_ripple_texel_size = vec2(0.001953125, 0.003472222);
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float rain_time_seconds = 0.0;
uniform float rain_puddle_threshold : hint_range(0.0, 1.0) = 0.48;
uniform float rain_puddle_deep_threshold : hint_range(0.0, 1.0) = 0.56;
uniform float rain_puddle_scale_px = 1680.0;
uniform float rain_puddle_y_compression : hint_range(1.0, 2.0) = 1.38;
uniform vec2 rain_puddle_offset_px = vec2(0.0);
uniform float rain_ripple_strength : hint_range(0.0, 1.0) = 0.90;
uniform float rain_reflection_strength : hint_range(0.0, 1.0) = 0.78;
uniform float rain_ripple_uv_strength : hint_range(0.0, 0.08) = 0.018;

float rain_hash_12(vec2 value) {
	vec3 p3 = fract(vec3(value.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 rain_rotate_uv(vec2 value, float angle) {
	float sine = sin(angle);
	float cosine = cos(angle);
	return mat2(vec2(cosine, -sine), vec2(sine, cosine)) * value;
}

vec3 rain_puddle_masks(vec2 world_position) {
	if (rain_intensity <= 0.001) {
		return vec3(0.0);
	}
	vec2 shifted_world = world_position + rain_puddle_offset_px;
	vec2 compressed_world = vec2(
		shifted_world.x,
		shifted_world.y * rain_puddle_y_compression);
	vec2 base_uv = compressed_world / max(rain_puddle_scale_px, 1.0);
	vec2 warp = texture(
		rain_noise_texture,
		rain_rotate_uv(base_uv * 0.31, 0.61)).rg - vec2(0.5);
	vec2 warped_uv = base_uv + warp * 0.23;
	float n1 = texture(
		rain_noise_texture,
		rain_rotate_uv(warped_uv, 0.17)).r;
	float n2 = texture(
		rain_noise_texture,
		rain_rotate_uv(warped_uv * 0.73, -0.41)).g;
	float n3 = texture(
		rain_noise_texture,
		rain_rotate_uv(warped_uv * 1.31, 1.22)).b;
	float n4 = texture(
		rain_noise_texture,
		rain_rotate_uv(warped_uv * 0.51, 2.03)).r;
	float n5 = texture(
		rain_noise_texture,
		rain_rotate_uv(warped_uv * 0.91, -1.57)).g;
	float density = (
		n1 * 1.25
		+ n2 * 2.0
		+ n3 * 1.5
		+ n4
		+ n5 * 0.5) / 6.25;
	float outer_mask = step(rain_puddle_threshold, density);
	float inner_mask = step(rain_puddle_deep_threshold, density);
	float reflection_value = smoothstep(
		rain_puddle_threshold,
		min(rain_puddle_deep_threshold + 0.10, 1.0),
		density);
	return vec3(
		outer_mask,
		inner_mask,
		reflection_value) * rain_intensity;
}

float rain_ripple_sample(vec2 screen_uv) {
	return texture(water_ripple_texture, screen_uv).r;
}

float rain_splash_mask(vec2 world_position) {
	if (rain_intensity <= 0.001) {
		return 0.0;
	}
	vec2 cell_size = vec2(34.0, 25.0);
	vec2 grid = world_position / cell_size;
	vec2 cell = floor(grid);
	vec2 local = fract(grid);
	float random_value = rain_hash_12(cell + vec2(7.0, 29.0));
	float phase = fract(
		rain_time_seconds * mix(0.82, 1.46, random_value)
		+ random_value * 9.37);
	float active = step(phase, 0.20);
	float fade = 1.0 - phase / 0.20;
	vec2 center = vec2(
		0.24 + fract(random_value * 53.1) * 0.52,
		0.28 + fract(random_value * 97.3) * 0.44);
	vec2 delta = local - center;
	float vertical = 1.0 - smoothstep(0.012, 0.040, abs(delta.x));
	vertical *= 1.0 - smoothstep(0.008, 0.095, abs(delta.y));
	float side_x = abs(abs(delta.x) - 0.055);
	float side_y = abs(delta.y - 0.018);
	float side = (1.0 - smoothstep(0.010, 0.025, side_x))
		* (1.0 - smoothstep(0.008, 0.025, side_y));
	float splash = max(vertical, side) * active * fade;
	return splash * mix(0.28, 1.0, random_value) * rain_intensity;
}
