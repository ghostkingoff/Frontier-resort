shader_type canvas_item;
render_mode unshaded, blend_add;

uniform sampler2D light_texture : filter_linear, repeat_disable;
uniform float strength = 0.9;

void fragment() {
	vec3 local_light = texture(light_texture, SCREEN_UV).rgb;
	COLOR = vec4(local_light * strength, 1.0);
}
