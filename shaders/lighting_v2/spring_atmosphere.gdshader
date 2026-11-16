shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec3 tint : source_color = vec3(1.0, 0.995, 0.98);
uniform float contrast : hint_range(0.8, 1.4) = 1.0;
uniform float saturation : hint_range(0.0, 1.5) = 0.98;
uniform float chroma_preserve_mix : hint_range(0.0, 1.0) = 0.50;
uniform float bloom_threshold : hint_range(0.0, 4.0) = 0.82;
uniform float bloom_strength : hint_range(0.0, 1.0) = 0.20;

vec3 shoulder_tonemap(vec3 color) {
	vec3 knee = vec3(0.78);
	vec3 over = max(color - knee, vec3(0.0));
	return min(color, knee) + over / (vec3(1.0) + over);
}

vec3 bright_sample(vec2 uv) {
	vec3 sample_color = textureLod(screen_texture, uv, 2.0).rgb;
	float luminance = dot(
		sample_color,
		vec3(0.2126, 0.7152, 0.0722));
	return sample_color * smoothstep(
		bloom_threshold,
		bloom_threshold + 0.55,
		luminance);
}

void fragment() {
	vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));
	vec3 scene = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	vec3 bloom = (
		bright_sample(SCREEN_UV + vec2(texel.x * 5.0, 0.0))
		+ bright_sample(SCREEN_UV - vec2(texel.x * 5.0, 0.0))
		+ bright_sample(SCREEN_UV + vec2(0.0, texel.y * 5.0))
		+ bright_sample(SCREEN_UV - vec2(0.0, texel.y * 5.0))
		+ bright_sample(SCREEN_UV + texel * 4.0)
		+ bright_sample(SCREEN_UV - texel * 4.0)
		+ bright_sample(SCREEN_UV + vec2(texel.x, -texel.y) * 6.0)
		+ bright_sample(SCREEN_UV + vec2(-texel.x, texel.y) * 6.0)
	) * 0.125;
	scene += bloom * bloom_strength;

	scene = shoulder_tonemap(scene);
	float luminance = dot(scene, vec3(0.2126, 0.7152, 0.0722));
	float display_luminance = pow(
		clamp(luminance, 0.0, 1.0),
		1.0 / 2.2);
	vec3 channel_gamma = pow(
		clamp(scene, vec3(0.0), vec3(1.0)),
		vec3(1.0 / 2.2));
	vec3 preserved_color = scene
		* display_luminance
		/ max(luminance, 0.0001);
	scene = mix(
		channel_gamma,
		preserved_color,
		chroma_preserve_mix);
	scene = mix(vec3(luminance), scene, saturation);
	scene = (scene - 0.5) * contrast + 0.5;
	scene *= tint;

	vec2 centered = SCREEN_UV * 2.0 - 1.0;
	float vignette = smoothstep(0.35, 1.28, length(centered));
	scene *= 1.0 - vignette * 0.06;

	COLOR = vec4(clamp(scene, 0.0, 1.0), 1.0);
}
