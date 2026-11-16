shader_type canvas_item;

uniform sampler2D normal_texture : hint_normal, filter_nearest, repeat_disable;
uniform sampler2D specular_texture : filter_nearest, repeat_disable;
uniform sampler2D occlusion_texture : filter_nearest, repeat_disable;
uniform sampler2D projected_shadow_texture : filter_linear, repeat_disable;
uniform vec3 to_sun = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_color : source_color = vec3(1.0);
uniform float sun_energy = 0.0;
uniform float normal_strength = 0.85;
uniform float specular_strength = 0.12;
uniform float occlusion_direct_strength = 0.35;
uniform float projected_shadow_strength = 0.62;
uniform float projected_shadow_fade = 0.0;
uniform float receive_projected_shadow = 0.0;
uniform float wall_foot_y_px = 0.0;
uniform float canvas_height_px = 256.0;
uniform float max_shadow_offset_px = 96.0;
uniform float wall_shadow_fade_start_ratio = 1.5;
uniform float wall_shadow_fade_end_ratio = 2.5;
uniform vec2 camera_zoom = vec2(1.0);
uniform vec2 viewport_size_px = vec2(1920.0, 1080.0);

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 encoded_normal = texture(normal_texture, UV).rgb * 2.0 - 1.0;
	encoded_normal.xy *= normal_strength;
	vec3 normal = normalize(vec3(
		encoded_normal.x, -encoded_normal.y, encoded_normal.z));
	vec3 light_direction = normalize(to_sun);
	float diffuse = max(dot(normal, light_direction), 0.0);
	float occlusion = texture(occlusion_texture, UV).r;
	float direct_occlusion = mix(1.0, occlusion, occlusion_direct_strength);
	vec3 direct = sun_color * sun_energy * diffuse * direct_occlusion;
	vec3 half_direction = normalize(light_direction + vec3(0.0, 0.0, 1.0));
	float specular = pow(max(dot(normal, half_direction), 0.0), 18.0);
	float specular_mask = texture(specular_texture, UV).r;
	vec3 highlight = sun_color * sun_energy * specular * specular_mask * specular_strength;
	float projected_shadow_amount = 0.0;
	if (receive_projected_shadow > 0.5 && sun_energy > 0.001) {
		float wall_height = max(wall_foot_y_px - UV.y * canvas_height_px, 0.0);
		float horizontal_light = length(to_sun.xy);
		float vertical_light = max(to_sun.z, 0.1);
		float projected_stretch = horizontal_light / vertical_light;
		float raw_offset = wall_height * projected_stretch;
		float offset_fade = 1.0 - smoothstep(
			wall_shadow_fade_start_ratio,
			wall_shadow_fade_end_ratio,
			projected_stretch);
		vec2 shadow_direction = length(to_sun.xy) > 0.0001
			? normalize(to_sun.xy)
			: vec2(0.0);
		vec2 world_offset = shadow_direction
			* min(raw_offset, max_shadow_offset_px);
		vec2 screen_offset = world_offset * camera_zoom / viewport_size_px;
		vec2 shadow_uv = clamp(SCREEN_UV + screen_offset, vec2(0.0), vec2(1.0));
		vec3 projected = texture(projected_shadow_texture, shadow_uv).rgb;
		float projected_luminance = dot(projected, vec3(0.299, 0.587, 0.114));
		float normalized_luminance = projected_luminance / max(sun_energy, 0.01);
		float lit_mask = smoothstep(0.08, 0.45, normalized_luminance);
		float sun_fade = smoothstep(0.005, 0.04, sun_energy);
		projected_shadow_amount = (1.0 - lit_mask) * offset_fade
			* sun_fade * projected_shadow_fade;
		direct *= 1.0 - projected_shadow_amount * projected_shadow_strength;
		highlight *= 1.0 - projected_shadow_amount * projected_shadow_strength;
	}
	vec3 shaded_base = base.rgb * (
		1.0 - projected_shadow_amount * projected_shadow_strength * 0.35);
	COLOR = vec4(clamp(shaded_base * (1.0 + direct) + highlight, 0.0, 1.0), base.a);
}
