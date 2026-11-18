uniform sampler2D cloud_shadow_texture : filter_linear, repeat_enable;

uniform float cloud_shadow_time = 0.0;
uniform float cloud_shadow_active : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_shadow_strength : hint_range(0.0, 1.0) = 1.0;
uniform float cloud_shadow_threshold : hint_range(0.0, 1.0) = 0.54;
uniform float cloud_shadow_softness : hint_range(0.001, 0.5) = 0.24;
uniform float cloud_shadow_width_px = 120.0;
uniform float cloud_shadow_length_px = 900.0;
uniform vec2 cloud_shadow_drift_px = vec2(10.0, 4.0);


float sample_world_cloud_transmission(
		vec2 world_position,
		vec3 sun_screen) {
	if (cloud_shadow_active <= 0.0001) {
		return 1.0;
	}
	vec2 light_direction = normalize(
		-sun_screen.xy + vec2(0.0001, 0.0));
	vec2 perpendicular = vec2(
		-light_direction.y,
		light_direction.x);
	vec2 cloud_position = world_position
		- cloud_shadow_drift_px * cloud_shadow_time;
	vec2 cloud_uv = vec2(
		dot(cloud_position, perpendicular)
			/ max(cloud_shadow_width_px, 1.0),
		dot(cloud_position, light_direction)
			/ max(cloud_shadow_length_px, 1.0));
	float cloud_primary = texture(
		cloud_shadow_texture,
		cloud_uv + vec2(cloud_shadow_time * 0.012, 0.0)).r;
	float cloud_secondary = texture(
		cloud_shadow_texture,
		cloud_uv * vec2(1.63, 0.71)
			+ vec2(-cloud_shadow_time * 0.007,
				cloud_shadow_time * 0.004)).g;
	float cloud_noise = cloud_primary * 0.68 + cloud_secondary * 0.32;
	float cloud_mask = smoothstep(
		cloud_shadow_threshold,
		min(cloud_shadow_threshold + cloud_shadow_softness, 1.0),
		cloud_noise);
	float transmission = 1.0 - cloud_mask * cloud_shadow_strength;
	return mix(1.0, transmission, clamp(cloud_shadow_active, 0.0, 1.0));
}
