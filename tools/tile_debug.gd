extends Node2D
## 贴图对照工具：把候选地面贴图放大 + 平铺，确认哪一格是纯色、无缝隙。
## 运行：godot --path . res://tools/tile_debug.tscn

const ATLAS := "res://art/placeholder/tiles/field.png"
const CANDIDATES := [
	Vector2i(3, 0), Vector2i(3, 3), Vector2i(4, 3),
	Vector2i(3, 6), Vector2i(4, 6), Vector2i(0, 3), Vector2i(1, 3),
]

var frames := 0


func _ready() -> void:
	var y := 6.0
	for c in CANDIDATES:
		# 左侧：8 倍放大样本
		var big := Sprite2D.new()
		big.texture = load(ATLAS)
		big.region_enabled = true
		big.region_rect = Rect2(c.x * 16, c.y * 16, 16, 16)
		big.centered = false
		big.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		big.scale = Vector2(4, 4)
		big.position = Vector2(6, y)
		add_child(big)
		# 右侧：平铺 14 格，检查有没有缝隙或透明边
		for i in range(14):
			var s := Sprite2D.new()
			s.texture = load(ATLAS)
			s.region_enabled = true
			s.region_rect = Rect2(c.x * 16, c.y * 16, 16, 16)
			s.centered = false
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.scale = Vector2(2, 2)
			s.position = Vector2(90 + i * 32, y + 8)
			add_child(s)
		y += 72.0
	_build_tilemap_comparison()


func _build_tilemap_comparison() -> void:
	# 上半部分：用项目生成的 TileSet 铺一片 (3,3)，看是否和直接贴图一致
	var tileset: TileSet = load("res://art/generated/ground_tileset.tres")
	var layer := TileMapLayer.new()
	layer.tile_set = tileset
	for x in range(24):
		for y in range(5):
			layer.set_cell(Vector2i(x + 30, y), 0, Vector2i(3, 3))
	add_child(layer)
	# 下半部分：直接用 Sprite2D 平铺同一格，作为对照
	for x in range(24):
		var s := Sprite2D.new()
		s.texture = load(ATLAS)
		s.region_enabled = true
		s.region_rect = Rect2(3 * 16, 3 * 16, 16, 16)
		s.centered = false
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.scale = Vector2(2, 2)
		s.position = Vector2((x + 30) * 32, 200)
		add_child(s)


func _process(_delta: float) -> void:
	frames += 1
	if frames == 30:
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png("res://.tmp/tile_debug.png")
		print("[tile_debug] %s" % error_string(err))
	if frames == 60:
		get_tree().quit()
