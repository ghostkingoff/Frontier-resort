shader_type canvas_item;

uniform vec2 canvas_size_px = vec2(256.0, 256.0);
uniform vec4 portal_a = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec4 portal_b = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 sun_ray_direction = vec2(0.0, -1.0);
uniform float portal_length_px = 32.0;
uniform float portal_softness_px = 8.0;
uniform float softness_growth = 0.18;
uniform vec3 portal_color : source_color = vec3(1.0, 0.88, 0.65);
uniform float portal_energy = 0.0;

float portal_contribution(vec2 pixel, vec4 portal) {
	if (portal.w <= 0.0 || portal.z <= 0.0) {
		return 0.0;
	}
	vec2 center = portal.xy;
	vec2 direction = normalize(sun_ray_direction);
	vec2 perpendicular = vec2(-direction.y, direction.x);
	vec2 relative = pixel - center;
	float along = dot(relative, direction);
	if (along < 0.0 || along > portal_length_px) {
		return 0.0;
	}
	float half_width = portal.z * 0.5 + portal_softness_px;
	float lateral = abs(dot(relative, perpendicular));
	float lateral_fade = 1.0 - smoothstep(
		half_width,
		half_width + portal_softness_px + along * softness_growth,
		lateral);
	float length_fade = 1.0 - smoothstep(
		portal_length_px * 0.55,
		portal_length_px,
		along);
	return lateral_fade * length_fade;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float interior_mask = base.a;
	vec2 pixel = UV * canvas_size_px;
	float light = max(
		portal_contribution(pixel, portal_a),
		portal_contribution(pixel, portal_b));
	vec3 portal_light = portal_color * portal_energy * light;
	COLOR = vec4(
		clamp(base.rgb + portal_light * interior_mask, 0.0, 1.0),
		base.a);
}
