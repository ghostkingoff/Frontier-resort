shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform vec2 lamp_center = vec2(0.0);
uniform vec2 lamp_radius_px = vec2(64.0, 40.0);
uniform float shadow_opacity : hint_range(0.0, 1.0) = 0.55;
uniform float edge_softness : hint_range(0.01, 0.95) = 0.45;

varying vec2 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 local = UV * 2.0 - 1.0;
	float ellipse_distance = length(local);
	float shape = 1.0 - smoothstep(
		1.0 - edge_softness,
		1.0,
		ellipse_distance);
	vec2 lamp_delta = (world_position - lamp_center)
		/ max(lamp_radius_px, vec2(1.0));
	float lamp_distance = length(lamp_delta);
	float ground_mask = 1.0 - smoothstep(0.94, 1.04, lamp_distance);
	float alpha = shape * ground_mask * shadow_opacity;
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}
