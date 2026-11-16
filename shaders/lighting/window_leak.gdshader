shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec3 leak_color = vec3(1.0, 0.827, 0.604);
uniform float brightness = 3.6;
uniform float edge_strength = 1.4;
uniform float energy = 0.0;

void fragment() {
	float mask = clamp(texture(TEXTURE, UV).a * edge_strength, 0.0, 1.0);
	COLOR = vec4(leak_color * brightness, mask * energy);
}
