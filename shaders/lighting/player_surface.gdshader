shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D normal_atlas : filter_nearest, repeat_disable;
uniform sampler2D specular_atlas : filter_nearest, repeat_disable;
uniform sampler2D occlusion_atlas : filter_nearest, repeat_disable;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.9;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.35;
uniform float occlusion_strength : hint_range(0.0, 1.0) = 0.65;

varying vec2 v_map_uv;

void vertex() {
	v_map_uv = UV;
}

void fragment() {
	vec3 encoded_normal = texture(normal_atlas, v_map_uv).rgb * 2.0 - 1.0;
	encoded_normal.xy *= normal_strength;
	NORMAL = normalize(vec3(encoded_normal.x, -encoded_normal.y, encoded_normal.z));
	float ao = texture(occlusion_atlas, v_map_uv).r;
	COLOR.rgb *= mix(1.0, ao, occlusion_strength);
}

void light() {
	vec3 to_light = normalize(LIGHT_DIRECTION);
	float ndotl = clamp(dot(normalize(NORMAL), to_light), 0.0, 1.0);
	vec3 diffuse = COLOR.rgb * LIGHT_COLOR.rgb * LIGHT_ENERGY * ndotl;

	float gloss = texture(specular_atlas, v_map_uv).r;
	vec3 view_dir = vec3(0.0, 0.0, 1.0);
	vec3 half_dir = normalize(to_light + view_dir);
	float shininess = mix(8.0, 64.0, gloss);
	float specular = pow(clamp(dot(normalize(NORMAL), half_dir), 0.0, 1.0),
			shininess) * gloss * specular_strength;

	LIGHT = vec4(
		diffuse + LIGHT_COLOR.rgb * LIGHT_ENERGY * specular,
		LIGHT_COLOR.a);
}
