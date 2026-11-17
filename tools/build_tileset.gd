extends SceneTree
## 生成春季世界使用的地面 TileSet。
## 每个地面类型固定一个 source id，避免换图后地图存档里的格子串图。
## 运行：godot --headless --path . --script res://tools/build_tileset.gd

const OUT := "res://art/generated/spring_ground_tileset.tres"
const TILE_SIZE := Vector2i(32, 32)
const SOURCE_TILES: Array[String] = [
	"res://art/characters/ground/grass_wild/color.png",
	"res://art/characters/ground/tiles/stone_color.png",
	"res://art/placeholders/tiles/ninja_dense_grass_2x.png",
	"res://art/characters/ground/grass_trimmed/color.png",
	"res://art/placeholders/tiles/ninja_wasteland_2x.png",
]


func _initialize() -> void:
	var tileset := TileSet.new()
	tileset.tile_size = TILE_SIZE
	for source_id in range(SOURCE_TILES.size()):
		var texture_path := SOURCE_TILES[source_id]
		if not ResourceLoader.exists(texture_path):
			push_error("贴图 %s 尚未导入，请先运行 Godot 导入。" % texture_path)
			quit(1)
			return
		var tex: Texture2D = load(texture_path)
		var source := TileSetAtlasSource.new()
		source.texture = tex
		source.texture_region_size = TILE_SIZE
		source.create_tile(Vector2i.ZERO)
		tileset.add_source(source, source_id)
	DirAccess.make_dir_recursive_absolute("res://art/generated")
	var err := ResourceSaver.save(tileset, OUT)
	print("[build_tileset] 保存 %s -> %s" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)
