shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec3 emission_color : source_color = vec3(1.0, 0.82, 0.58);
uniform float emission_energy : hint_range(0.0, 4.0) = 0.0;
uniform float edge_strength : hint_range(0.0, 3.0) = 1.2;

void fragment() {
	float alpha = clamp(texture(TEXTURE, UV).a * edge_strength, 0.0, 1.0);
	COLOR = vec4(
		emission_color * emission_energy,
		alpha * clamp(emission_energy, 0.0, 1.0));
}
