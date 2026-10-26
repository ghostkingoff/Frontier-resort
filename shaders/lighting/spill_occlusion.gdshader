shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec2 source_screen_uv = vec2(0.5);
uniform int max_steps : hint_range(4, 32) = 20;
uniform float occlusion_radius : hint_range(0.0, 8.0) = 1.25;

void fragment() {
	// COLOR 已包含默认纹理、CanvasItem modulate 与 self_modulate。
	vec4 light = COLOR;
	if (light.a > 0.001) {
		vec2 source_sdf = screen_uv_to_sdf(source_screen_uv);
		vec2 pixel_sdf = screen_uv_to_sdf(SCREEN_UV);
		bool waiting_for_clearance = texture_sdf(source_sdf) < 0.0;
		float visibility = 1.0;

		for (int i = 0; i < 32; i++) {
			if (i >= max_steps) {
				break;
			}
			float t = float(i + 1) / float(max_steps);
			float distance_to_surface = texture_sdf(mix(source_sdf, pixel_sdf, t));
		if (waiting_for_clearance) {
			// 从窗口和建筑占地内部出发时，先完整穿过自身墙体及其边缘。
			// 只有离开安全距离后遇到的下一面墙才计入遮挡。
			waiting_for_clearance = distance_to_surface <= occlusion_radius;
				continue;
			}
			if (distance_to_surface <= occlusion_radius) {
				visibility = 0.0;
				break;
			}
		}
		light.a *= visibility;
	}

	// Shader 的 blend_add 直接相加 RGB，需自行预乘纹理透明度。
	light.rgb *= light.a;
	COLOR = vec4(light.rgb, 1.0);
}
