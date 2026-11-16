shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D noise_texture : filter_linear, repeat_enable;
uniform sampler2D depth_texture : filter_linear, repeat_enable;

uniform vec3 fog_color : source_color = vec3(0.76, 0.82, 0.82);
uniform float fog_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float fog_max_alpha : hint_range(0.0, 1.0) = 0.52;
uniform float fog_time = 0.0;
uniform vec2 drift_speed = vec2(0.006, 0.003);
uniform float depth_drift_scale = -0.067;
uniform float noise_scale_px = 620.0;
uniform float depth_scale_px = 940.0;
uniform vec2 camera_origin_px = vec2(0.0);
uniform vec2 camera_zoom = vec2(1.0);
uniform vec2 viewport_size_px = vec2(1920.0, 1080.0);

vec2 rotate_uv(vec2 value, float angle) {
	float sine = sin(angle);
	float cosine = cos(angle);
	return mat2(vec2(cosine, -sine), vec2(sine, cosine)) * value;
}

void fragment() {
	vec3 scene = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	vec2 world_px = camera_origin_px
		+ (SCREEN_UV - vec2(0.5))
		* viewport_size_px
		/ max(camera_zoom, vec2(0.001));
	vec2 base_uv = world_px / max(noise_scale_px, 1.0);
	float time = mod(fog_time, 8192.0);
	vec2 drift = drift_speed * time;
	vec2 warp_sample = texture(
		noise_texture,
		rotate_uv(base_uv * 0.37 + drift * 0.15, 0.81)).rg;
	vec2 warped_uv = base_uv + (warp_sample - vec2(0.5)) * 0.22;

	float n1 = texture(noise_texture, rotate_uv(
		warped_uv + drift * 1.0,
		0.17)).r;
	float n2 = texture(noise_texture, rotate_uv(
		warped_uv * 0.73 - drift * 0.75,
		-0.41)).g;
	float n3 = texture(noise_texture, rotate_uv(
		warped_uv * 1.31 + drift * 0.5,
		1.22)).b;
	float n4 = texture(noise_texture, rotate_uv(
		warped_uv * 0.51 + drift * 0.25,
		2.03)).r;
	float n5 = texture(noise_texture, rotate_uv(
		warped_uv * 0.91 + drift * 1.25,
		-1.57)).g;
	vec4 depth_sample = texture(
		depth_texture,
		rotate_uv(
			world_px / max(depth_scale_px, 1.0)
				+ drift * depth_drift_scale,
			0.29));
	float depth = mix(depth_sample.r, depth_sample.g, 0.42);
	depth = mix(0.01, 0.99, depth);

	float density = (
		n1 * 1.25
		+ n2 * 2.0
		+ n3 * 1.5
		+ n4 * 1.0
		+ n5 * 0.5) / 6.25;
	float fog_mask = sqrt(max(density * depth, 0.0));
	float alpha = clamp(
		fog_mask * fog_max_alpha * fog_intensity,
		0.0,
		1.0);
	scene = mix(scene, fog_color, alpha);
	COLOR = vec4(scene, 1.0);
}
