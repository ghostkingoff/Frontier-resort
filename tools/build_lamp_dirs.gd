extends SceneTree
## 生成路灯占位素材：把 house.png 里的小灯笼切成 4 个方向帧
## （原样 + 顺时针旋转 90°×3），横向拼成 4 帧图。
## 运行：godot --headless --path . --script res://tools/build_lamp_dirs.gd
## 生成后要导入一次：godot --headless --path . --import
##
## 帧顺序与游戏里的朝向编号一致：0 下、1 左、2 上、3 右。
## 将来有正式四方向素材时，直接替换 art/generated/lamp_dirs.png（或改 data 里的 atlas/rect）即可。

const SRC := "res://art/placeholder/tiles/house.png"
const SRC_RECT := Rect2i(96, 48, 16, 16)
const OUT := "res://art/generated/lamp_dirs.png"


func _init() -> void:
	var src := Image.load_from_file(ProjectSettings.globalize_path(SRC))
	if src == null:
		push_error("[lamp_dirs] 读不到源图：%s" % SRC)
		quit(1)
		return
	var frame := src.get_region(SRC_RECT)
	var sheet := Image.create(SRC_RECT.size.x * 4, SRC_RECT.size.y, false, Image.FORMAT_RGBA8)
	for i in range(4):
		var f := frame.duplicate()
		for _r in range(i):
			f.rotate_90(ClockDirection.CLOCKWISE)
		sheet.blit_rect(f, Rect2i(Vector2i.ZERO, SRC_RECT.size), Vector2i(i * SRC_RECT.size.x, 0))
	var err := sheet.save_png(ProjectSettings.globalize_path(OUT))
	print("[lamp_dirs] %s（%dx%d）→ %s（%s）" % [
		SRC, sheet.get_width(), sheet.get_height(), OUT, error_string(err)])
	quit(0 if err == OK else 1)
