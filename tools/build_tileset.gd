extends SceneTree
## 生成地面用的 TileSet 资源。
## 占位素材是 16×16，正式规格一格 32×32：先把素材最近邻放大 2 倍存成 field_2x.png，
## 再用它生成 TileSet（贴图格子 = 显示格子 = 32×32），避免缩放导致的缝隙。
## 运行：godot --headless --path . --script res://tools/build_tileset.gd

const ATLAS := "res://art/placeholder/tiles/field.png"
const ATLAS_2X := "res://art/generated/field_2x.png"
const OUT := "res://art/generated/ground_tileset.tres"
const TILE_SIZE := Vector2i(32, 32)
const TILES := [Vector2i(3, 0), Vector2i(3, 3), Vector2i(3, 6)]


func _initialize() -> void:
	_ensure_upscaled()
	var tex: Texture2D = load(ATLAS_2X)
	if tex == null:
		push_warning("贴图 %s 尚未导入，请先运行：godot --headless --path . --import，再重新运行本工具。" % ATLAS_2X)
		quit(0)
		return
	var tileset := TileSet.new()
	tileset.tile_size = TILE_SIZE
	var source := TileSetAtlasSource.new()
	source.texture = tex
	source.texture_region_size = TILE_SIZE
	for coords in TILES:
		if not source.has_tile(coords):
			source.create_tile(coords)
	tileset.add_source(source, 0)
	DirAccess.make_dir_recursive_absolute("res://art/generated")
	var err := ResourceSaver.save(tileset, OUT)
	print("[build_tileset] 保存 %s -> %s" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)


func _ensure_upscaled() -> void:
	if FileAccess.file_exists(ATLAS_2X):
		return
	var img: Image = load(ATLAS).get_image()
	if img == null:
		push_error("找不到地面贴图：%s" % ATLAS)
		return
	img.convert(Image.FORMAT_RGBA8)
	img.resize(img.get_width() * 2, img.get_height() * 2, Image.INTERPOLATE_NEAREST)
	DirAccess.make_dir_recursive_absolute("res://art/generated")
	var err := img.save_png(ATLAS_2X)
	print("[build_tileset] 已生成 2 倍贴图 %s（%s）" % [ATLAS_2X, error_string(err)])
