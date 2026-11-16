shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec3 glow_color : source_color = vec3(1.0, 0.827, 0.416);
uniform float opacity : hint_range(0.0, 1.0) = 0.5;
uniform float brightness : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 source = texture(TEXTURE, UV);
	float strength = source.a * opacity * brightness;
	COLOR = vec4(glow_color * source.rgb * strength, 1.0);
}
