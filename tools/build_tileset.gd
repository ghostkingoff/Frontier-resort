extends SceneTree
## 生成地面用的 TileSet 资源。
## 占位素材是 16×16，正式规格一格 32×32：先把素材最近邻放大 2 倍存成 field_2x.png，
## 再用它生成 TileSet（贴图格子 = 显示格子 = 32×32），避免缩放导致的缝隙。
## 运行：godot --headless --path . --script res://tools/build_tileset.gd

const ATLAS := "res://art/placeholder/tiles/field.png"
const ATLAS_2X := "res://art/generated/field_2x.png"
const DENSE_GRASS_2X := "res://art/placeholders/tiles/ninja_dense_grass_2x.png"
const STONE_TILE_2X := "res://art/placeholders/tiles/ninja_stone_tile_2x.png"
const WASTELAND_2X := "res://art/placeholders/tiles/ninja_wasteland_2x.png"
const OUT := "res://art/generated/ground_tileset.tres"
const TILE_SIZE := Vector2i(32, 32)
const SOURCE_TILES := [
	[ATLAS_2X, [Vector2i(3, 0), Vector2i(3, 3), Vector2i(3, 6)]],
	[DENSE_GRASS_2X, [Vector2i.ZERO]],
	[STONE_TILE_2X, [Vector2i.ZERO]],
	[WASTELAND_2X, [Vector2i.ZERO]],
]


func _initialize() -> void:
	_ensure_upscaled()
	var tileset := TileSet.new()
	tileset.tile_size = TILE_SIZE
	for source_id in range(SOURCE_TILES.size()):
		var source_spec: Array = SOURCE_TILES[source_id]
		var texture_path := str(source_spec[0])
		var tex: Texture2D = load(texture_path)
		if tex == null:
			push_warning("贴图 %s 尚未导入，请先运行：godot --headless --path . --import，再重新运行本工具。" % texture_path)
			quit(0)
			return
		var source := TileSetAtlasSource.new()
		source.texture = tex
		source.texture_region_size = TILE_SIZE
		for coords in source_spec[1]:
			if not source.has_tile(coords):
				source.create_tile(coords)
		tileset.add_source(source, source_id)
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
