shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest, repeat_disable;
uniform float exposure = 0.60;

void fragment() {
	vec4 scene = texture(screen_texture, SCREEN_UV);
	COLOR = vec4(scene.rgb * exposure, scene.a);
}
