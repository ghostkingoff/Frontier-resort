extends SceneTree
## 生成灯光纹理：
##   - 径向（中心亮）  art/generated/light_radial.png   —— 备用，圆形范围的光源
##   - 矩形（平顶+渐变）art/generated/light_rect.png     —— 建筑灯光用
##
## 运行：godot --headless --path . --script res://tools/build_light_texture.gd
## 注意：生成后必须让 Godot 导入一次（godot --headless --path . --import），
##       否则 load() 会拿到 null，PointLight2D 缺纹理时完全不发光。
##
## 为什么要矩形平顶纹理（而不是径向）：
##   建筑是矩形，用径向光会中间一个亮团、四角偏暗，看起来像地板把光挡住了。
##   矩形纹理让「内部均匀、只有外圈渐变」，正好符合建筑形状。

const OUT_RADIAL := "res://art/generated/light_radial.png"
const OUT_RECT := "res://art/generated/light_rect.png"
const SIZE := 256
const BAND := 32.0      # 径向纹理不需要，保留给径向用
# 矩形纹理：平顶区 : 渐变带 = 1 : 1。
# 这样使用方可以「把平顶区缩放到建筑占地、渐变带正好等于外扩的那 1 格」，
# 于是只有建筑周围那一圈是渐变，建筑内部完全均匀。
const RECT_SIZE := 256
# 平顶区 : 渐变带 = 1 : 0.5（平顶 128px，每边渐变 64px）。
# 取 0.5 的原因：使用方要把「平顶区」对到建筑占地、「渐变带」对到外扩的那 1 格。
# 若取 1:1，渐变带会厚达占地的一半（4×4 建筑 = 2 格），光斑比建筑大好几圈。
# 0.5 时 4×4 建筑的外圈正好 1 格（32px），与设计一致。
# 约束：平顶区宽 = RECT_SIZE - 2*RECT_BAND 必须 > 0，否则平顶区消失、中心反而最暗。
const RECT_BAND := 64.0


func _initialize() -> void:
	var err_r := _build_radial()
	var err_c := _build_rect()
	quit(0 if err_r == OK and err_c == OK else 1)


func _build_radial() -> int:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(SIZE, SIZE) * 0.5
	var max_r := SIZE * 0.5
	for y in range(SIZE):
		for x in range(SIZE):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center) / max_r
			var a := 0.0
			if d < 1.0:
				var falloff := 1.0 - d
				a = falloff * falloff
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	var err := _save(img, OUT_RADIAL)
	print("[build_light_texture] 径向 %s -> %s" % [OUT_RADIAL, error_string(err)])
	return err


func _build_rect() -> int:
	# 平顶区 : 渐变带 = 1 : 1（平顶宽 = 2*RECT_BAND），使用方把平顶区对到建筑占地，
	# 渐变带就正好是外扩的那一圈。
	# 注意：内区半宽 = RECT_SIZE/2 - RECT_BAND 必须 > 0，否则平顶区消失、
	# 中心反而变成最暗（曾经把 BAND 设成 SIZE/2 就踩了这个坑）。
	var img := Image.create(RECT_SIZE, RECT_SIZE, false, Image.FORMAT_RGBA8)
	var half := Vector2(RECT_SIZE, RECT_SIZE) * 0.5
	var inner := half - Vector2(RECT_BAND, RECT_BAND)      # 平顶区的半尺寸
	for y in range(RECT_SIZE):
		for x in range(RECT_SIZE):
			var p := Vector2(x + 0.5, y + 0.5)
			var d := p - half
			# 到矩形「内区」的距离：两轴都超出内区才算在外
			var ox := maxf(absf(d.x) - inner.x, 0.0)
			var oy := maxf(absf(d.y) - inner.y, 0.0)
			var outside := sqrt(ox * ox + oy * oy)
			var a := 1.0 if outside <= 0.0 else clampf(1.0 - outside / RECT_BAND, 0.0, 1.0)
			# 平顶用 smoothstep 收尾，避免出现硬边
			a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	var err := _save(img, OUT_RECT)
	print("[build_light_texture] 矩形 %s -> %s（平顶 %d px : 渐变 %d px = 1:0.5）" % [
		OUT_RECT, error_string(err), int(inner.x * 2), int(RECT_BAND)])
	return err


func _save(img: Image, path: String) -> int:
	DirAccess.make_dir_recursive_absolute("res://art/generated")
	return img.save_png(path)
