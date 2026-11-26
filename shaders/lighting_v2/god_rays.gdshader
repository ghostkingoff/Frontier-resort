shader_type canvas_item;
render_mode unshaded, blend_add;

#include "res://shaders/lighting_v2/ground_projection.gdshaderinc"

uniform sampler2D noise_texture : filter_linear, repeat_enable;
uniform vec2 camera_origin_px = vec2(0.0);
uniform vec2 visible_world_size_px = vec2(1920.0, 1080.0);
uniform vec2 cloud_shadow_offset_px = vec2(0.0);
uniform float cloud_shadow_world_scale = 1200.0;
uniform float cloud_shadow_y_compression : hint_range(1.0, 2.5) = 1.414214;
uniform float cloud_hole_size = 3.0;
uniform float cloud_hole_amount : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sun_screen_direction = vec3(0.0, 0.0, 1.0);
uniform vec3 beam_color : source_color = vec3(1.0, 0.92, 0.72);
uniform float sun_energy : hint_range(0.0, 4.0) = 0.0;
uniform float spot_energy_scale : hint_range(0.0, 1.0) = 1.0;
uniform float beam_visibility : hint_range(0.0, 1.0) = 0.0;
uniform float layer_alpha : hint_range(0.001, 0.2) = 0.055;
uniform float spot_fade_start_px = 24.0;
uniform float spot_fade_end_px = 160.0;
uniform float bottom_fade_start : hint_range(0.0, 1.0) = 0.78;

const int RAY_MARCH_STEPS = 36;
const float MARCH_EXTINCTION = 3.0;
const float MARCH_SCATTERING = 64.0;
const float MARCH_ENERGY_GAIN = 2.0;
const float MIN_BEAM_ENERGY = 0.18;

float cloud_hole_at(vec2 world_position) {
	vec2 cloud_uv = project_ground_position(
		world_position + cloud_shadow_offset_px,
		cloud_shadow_y_compression)
		/ max(cloud_shadow_world_scale, 64.0);
	vec2 hole_uv = cloud_uv
		* (1.4 / max(cloud_hole_size, 0.25))
		+ vec2(0.61, 0.27);
	float noise_value = texture(noise_texture, hole_uv).b;
	float threshold = mix(
		0.88,
		0.58,
		clamp(cloud_hole_amount, 0.0, 1.0));
	return smoothstep(threshold - 0.08, threshold + 0.08, noise_value);
}

void fragment() {
	vec2 world_position = camera_origin_px
		+ (SCREEN_UV - vec2(0.5)) * visible_world_size_px;
	float horizontal = length(sun_screen_direction.xy);
	float direction_gate = smoothstep(0.01, 0.12, horizontal);
	if (direction_gate <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		vec2 sun_axis = sun_screen_direction.xy
			/ max(horizontal, 0.0001);
		vec2 half_view = visible_world_size_px * 0.5;
		vec2 relative_world = world_position - camera_origin_px;
		float distance_x = 100000.0;
		float distance_y = 100000.0;
		if (abs(sun_axis.x) > 0.0001) {
			float target_x = sun_axis.x > 0.0
				? half_view.x
				: -half_view.x;
			distance_x = max(
				(target_x - relative_world.x) / sun_axis.x,
				0.0);
		}
		if (abs(sun_axis.y) > 0.0001) {
			float target_y = sun_axis.y > 0.0
				? half_view.y
				: -half_view.y;
			distance_y = max(
				(target_y - relative_world.y) / sun_axis.y,
				0.0);
		}
		float max_distance = max(min(distance_x, distance_y), 1.0);
		float step_world = max_distance / float(RAY_MARCH_STEPS);
		float normalized_step = step_world
			/ max(cloud_shadow_world_scale, 64.0);
		float dither = fract(
			52.9829189
			* fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		float transmittance = 1.0;
		float scattered_light = 0.0;
		float beam_presence = 0.0;
		float source_weight = 0.0;
		float weighted_source_y = 0.0;
		for (int sample_index = 0;
				sample_index < RAY_MARCH_STEPS;
				sample_index++) {
			float t = (float(sample_index) + dither)
				/ float(RAY_MARCH_STEPS);
			float distance = max_distance * t;
			vec2 sample_world = world_position + sun_axis * distance;
			float opening = cloud_hole_at(sample_world);
			float cloud_density = 1.0 - opening;
			float distance_fade = smoothstep(
				spot_fade_start_px,
				max(
					spot_fade_end_px,
					spot_fade_start_px + 0.001),
				distance);
			float sample_scatter = transmittance
				* opening
				* normalized_step
				* MARCH_SCATTERING
				* distance_fade;
			float opening_coverage = opening * distance_fade;
			scattered_light += sample_scatter;
			beam_presence = max(beam_presence, opening_coverage);
			vec2 sample_uv = vec2(0.5)
				+ (sample_world - camera_origin_px)
					/ visible_world_size_px;
			source_weight += opening_coverage;
			weighted_source_y += sample_uv.y * opening_coverage;
			transmittance *= exp(
				-cloud_density
				* normalized_step
				* MARCH_EXTINCTION);
		}
		float ray_energy = max(
			1.0 - exp(-scattered_light * MARCH_ENERGY_GAIN),
			beam_presence * MIN_BEAM_ENERGY);
		float source_screen_y = source_weight > 0.00001
			? weighted_source_y / source_weight
			: 1.0;
		float spot_height_ratio = clamp(
			(1.0 - source_screen_y) / 0.5,
			0.0,
			1.0);
		float available_layers = 1.0 + spot_height_ratio * 7.0;
		float spot_energy = clamp(
			ray_energy * spot_energy_scale,
			0.0,
			1.0);
		float desired_layers = min(
			spot_energy * 8.0,
			available_layers);
		float stacked_layers = 0.0;
		for (int layer_index = 0; layer_index < 8; layer_index++) {
			float layer_t = float(layer_index) / 7.0;
			float layer_bottom = mix(1.0, 0.5, layer_t);
			float layer_coverage = 1.0 - smoothstep(
				layer_bottom,
				layer_bottom + 0.025,
				SCREEN_UV.y);
			float layer_weight = clamp(
				desired_layers - float(layer_index),
				0.0,
				1.0);
			stacked_layers += layer_coverage * layer_weight;
		}
		float bottom_fade = 1.0 - smoothstep(
			bottom_fade_start,
			1.0,
			SCREEN_UV.y);
		float light = smoothstep(0.01, 0.42, sun_energy);
		float amount = stacked_layers
			* layer_alpha
			* bottom_fade
			* direction_gate
			* beam_visibility
			* light;
		vec3 color = beam_color * mix(0.65, 1.0, amount);
		COLOR = vec4(color * amount, amount);
	}
}
