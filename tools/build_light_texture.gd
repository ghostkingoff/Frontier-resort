extends SceneTree

const OUT_RADIAL := "res://art/generated/light_radial.png"
const SIZE := 256


func _initialize() -> void:
	var error := _build_radial()
	quit(0 if error == OK else 1)


func _build_radial() -> int:
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(SIZE, SIZE) * 0.5
	var max_radius := SIZE * 0.5
	for y in range(SIZE):
		for x in range(SIZE):
			var distance := Vector2(
				x + 0.5, y + 0.5).distance_to(center) / max_radius
			var alpha := 0.0
			if distance < 1.0:
				var falloff := 1.0 - distance
				alpha = falloff * falloff
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	var error := _save(image, OUT_RADIAL)
	print("[build_light_texture] %s -> %s" % [
		OUT_RADIAL, error_string(error)])
	return error


func _save(image: Image, path: String) -> int:
	DirAccess.make_dir_recursive_absolute("res://art/generated")
	return image.save_png(path)
