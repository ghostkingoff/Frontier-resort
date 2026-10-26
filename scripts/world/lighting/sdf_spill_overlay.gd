extends Sprite2D
## 为素材扩散光提供逐帧屏幕坐标，让着色器从窗口向像素做 SDF 可见性步进。

var light_material: ShaderMaterial


func enable_sdf_occlusion(shader: Shader) -> void:
	light_material = ShaderMaterial.new()
	light_material.shader = shader
	material = light_material
	set_process(true)


func _process(_delta: float) -> void:
	if light_material == null or not is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var source_screen := get_global_transform_with_canvas() * Vector2.ZERO
	light_material.set_shader_parameter(
		"source_screen_uv", source_screen / viewport_size)
