uniform sampler2D snow_cover_noise_texture : filter_nearest, repeat_enable;
uniform float snow_cover_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_cover_threshold : hint_range(0.0, 1.0) = 0.50;
uniform float snow_cover_softness : hint_range(0.001, 0.25) = 0.006;
uniform float snow_cover_scale_px = 1800.0;
uniform vec2 snow_cover_offset_px = vec2(0.0);
uniform float snow_cover_pixel_size_px = 4.0;
uniform float snow_cover_y_compression : hint_range(1.0, 2.5) = 1.414214;
uniform vec3 snow_cover_color : source_color = vec3(0.86, 0.93, 0.96);
uniform float snow_surface_scale : hint_range(0.0, 1.0) = 0.0;
uniform float snow_surface_top_gate_strength : hint_range(0.0, 1.0) = 0.0;
uniform float snow_surface_local_uv_mix : hint_range(0.0, 1.0) = 0.0;
uniform float snow_surface_uv_size_px = 1024.0;

vec2 _snow_cover_rotate(vec2 value, float angle) {
	float sine = sin(angle);
	float cosine = cos(angle);
	return mat2(vec2(cosine, -sine), vec2(sine, cosine)) * value;
}

float snow_cover_mask(
		vec2 world_position,
		float surface_scale,
		float normal_y,
		float top_gate_strength) {
	float coverage = clamp(
		snow_cover_amount * max(surface_scale, 0.0),
		0.0,
		1.0);
	float coverage_gate = smoothstep(0.005, 0.08, coverage);
	if (coverage_gate <= 0.001) {
		return 0.0;
	}
	float pixel_size = max(snow_cover_pixel_size_px, 1.0);
	vec2 projected_world = project_ground_position(
		world_position + snow_cover_offset_px,
		snow_cover_y_compression);
	vec2 snapped_world = floor(
		projected_world / pixel_size) * pixel_size;
	vec2 uv = snapped_world / max(snow_cover_scale_px, 64.0);
	float body = texture(
		snow_cover_noise_texture,
		_snow_cover_rotate(uv + vec2(0.17, 0.43), 0.23)).r;
	float breakup = texture(
		snow_cover_noise_texture,
		_snow_cover_rotate(uv * 3.17 + vec2(0.61, 0.29), -0.71)).g;
	float shape = clamp(body + (breakup - 0.5) * 0.11, 0.0, 1.0);
	float threshold = mix(0.91, snow_cover_threshold, coverage)
		+ (breakup - 0.5) * 0.035;
	float softness = max(snow_cover_softness, 0.001);
	float mask = smoothstep(
		threshold - softness,
		threshold + softness,
		shape) * coverage_gate;
	float top_gate = mix(
		1.0,
		smoothstep(-0.18, 0.58, normal_y),
		clamp(top_gate_strength, 0.0, 1.0));
	return mask * top_gate;
}

vec3 apply_snow_cover(
		vec3 base_color,
		vec2 world_position,
		float normal_y,
		float surface_scale,
		float top_gate_strength) {
	float mask = snow_cover_mask(
		world_position,
		surface_scale,
		normal_y,
		top_gate_strength);
	return mix(base_color, snow_cover_color, mask);
}
