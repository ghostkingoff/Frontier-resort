extends RefCounted
class_name BuildingLightingAsset
## 建筑光照素材定义。
##
## 该定义只描述素材和源坐标，不创建灯光节点。旧 PointLight2D 后端与后续
## SDF/光线步进后端都从同一份定义读取，避免各自重复解释 Aseprite 坐标。

var shape := "rect"
var radius_cells := 2.0
var glow_scale := 1.0
var layer_origin := Vector2i.ZERO
var roof_texture_path := ""
var roof_origin := Vector2i.ZERO
var spill_texture_path := ""
var spill_origin := Vector2i.ZERO
var spill_guides: Array = []
var window_energy_scale := 1.0
var window_halo_radius_px := 8.0
var lamp_energy_scale := 1.0
var lamp_head_radius_px := 8.0
var lamp_color := Color(1.0, 0.82, 0.54)
var lamps: Array = []


static func from_building_data(data: Dictionary) -> BuildingLightingAsset:
	var asset := BuildingLightingAsset.new()
	var layers: Dictionary = data.get("sprite_layers", {})
	asset.shape = str(data.get("light_shape", "rect"))
	asset.radius_cells = float(data.get("light_radius_cells", 2.0))
	asset.glow_scale = float(data.get("light_glow_scale", 1.0))
	asset.layer_origin = _read_origin(layers.get("origin", [0, 0]))
	asset.roof_texture_path = str(layers.get("light_roof", ""))
	asset.roof_origin = _read_origin(layers.get(
		"light_roof_origin", layers.get("light_origin", [
			asset.layer_origin.x, asset.layer_origin.y])))
	asset.spill_texture_path = str(layers.get("light_spill", ""))
	asset.spill_origin = _read_origin(layers.get(
		"light_spill_origin", layers.get("light_origin", [
			asset.layer_origin.x, asset.layer_origin.y])))
	var guides: Array = layers.get("light_spill_guides", [])
	asset.spill_guides = guides.duplicate(true)
	var lighting: Dictionary = layers.get("lighting", {})
	asset.window_energy_scale = float(lighting.get("window_scale", 1.0))
	asset.window_halo_radius_px = float(lighting.get("window_halo_radius_px", 8.0))
	asset.lamp_energy_scale = float(lighting.get("lamp_scale", 1.0))
	asset.lamp_head_radius_px = float(lighting.get("lamp_head_radius_px", 8.0))
	asset.lamp_color = Color.from_string(
		str(lighting.get("lamp_color", "#ffd18a")), Color(1.0, 0.82, 0.54))
	var lamps: Array = lighting.get("lamps", [])
	asset.lamps = lamps.duplicate(true)
	return asset


static func _read_origin(value: Variant) -> Vector2i:
	var values: Array = value if value is Array else [0, 0]
	return Vector2i(
		int(values[0]) if values.size() > 0 else 0,
		int(values[1]) if values.size() > 1 else 0)
