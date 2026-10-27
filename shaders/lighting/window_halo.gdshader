shader_type canvas_item;
render_mode unshaded, blend_add;

uniform float radius_px : hint_range(1.0, 16.0) = 8.0;
uniform vec4 glow_color : source_color = vec4(1.0, 0.74, 0.38, 1.0);
uniform float energy : hint_range(0.0, 2.0) = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float halo = 0.0;
	vec2 step_uv = TEXTURE_PIXEL_SIZE * radius_px;
	for (int i = 0; i < 16; i++) {
		float angle = TAU * float(i) / 16.0;
		vec2 offset = vec2(cos(angle), sin(angle));
		halo += texture(TEXTURE, clamp(UV + offset * step_uv, vec2(0.0), vec2(1.0))).a;
		halo += texture(TEXTURE, clamp(UV + offset * step_uv * 0.5, vec2(0.0), vec2(1.0))).a;
	}
	halo = max(halo / 32.0 - base.a, 0.0) * energy;
	COLOR = vec4(glow_color.rgb * halo, 1.0);
}
