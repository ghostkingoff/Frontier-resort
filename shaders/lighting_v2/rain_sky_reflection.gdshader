shader_type canvas_item;
render_mode unshaded;

uniform vec3 sky_top_color : source_color = vec3(0.30, 0.40, 0.43);
uniform vec3 sky_horizon_color : source_color = vec3(0.56, 0.66, 0.67);
uniform vec3 sun_color : source_color = vec3(0.82, 0.85, 0.82);
uniform vec3 sun_screen_direction = vec3(0.0, 0.0, 1.0);
uniform float sun_energy : hint_range(0.0, 1.5) = 0.0;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	float vertical = smoothstep(0.0, 1.0, SCREEN_UV.y);
	vec3 color = mix(sky_top_color, sky_horizon_color, vertical);
	vec2 sun_side = normalize(
		sun_screen_direction.xy + vec2(0.0001, 0.0));
	float glow = smoothstep(
		-0.25,
		0.95,
		dot(SCREEN_UV - vec2(0.5), sun_side));
	color += sun_color * glow * sun_energy
		* mix(0.035, 0.085, 1.0 - vertical);
	color *= mix(1.0, 0.96, rain_intensity);
	COLOR = vec4(color, 1.0);
}
