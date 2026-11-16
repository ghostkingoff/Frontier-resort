shader_type canvas_item;

uniform sampler2D sun_light_texture : filter_linear, repeat_disable;
uniform float sun_light_strength = 1.0;
uniform float light_add_strength = 0.85;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 scene_light = texture(sun_light_texture, SCREEN_UV).rgb;
	COLOR = vec4(
		clamp(
			base.rgb * (1.0 + scene_light * sun_light_strength)
				+ scene_light * light_add_strength,
			0.0,
			1.0),
		base.a);
}
