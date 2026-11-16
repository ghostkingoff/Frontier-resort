extends SceneTree
## Generates deterministic seamless grayscale masks for the spring fog layer.
## Run:
##   godot --headless --path . --script res://tools/generate_fog_textures.gd

const OUTPUT_DIR := "res://art/generated/lighting_v2"
const DENSITY_SIZE := 1024
const DEPTH_SIZE := 512


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	var density := _generate_density_texture(DENSITY_SIZE)
	var depth := _generate_depth_texture(DEPTH_SIZE)
	var density_error := density.save_png(OUTPUT_DIR + "/fog_density.png")
	var depth_error := depth.save_png(OUTPUT_DIR + "/fog_depth.png")
	print("[fog-textures] density=%s depth=%s" % [
		error_string(density_error),
		error_string(depth_error),
	])
	quit(0 if density_error == OK and depth_error == OK else 1)


func _generate_density_texture(size: int) -> Image:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var totals := [0.0, 0.0, 0.0]
	for y in range(size):
		var v := float(y) / float(size)
		for x in range(size):
			var u := float(x) / float(size)
			var r := _density_channel(u, v, 3, 1717)
			var g := _density_channel(u, v, 4, 3541)
			var b := _density_channel(u, v, 5, 7127)
			totals[0] += r
			totals[1] += g
			totals[2] += b
			image.set_pixel(x, y, Color(r, g, b, 1.0))
	var pixels := float(size * size)
	print("[fog-textures] density means R=%.3f G=%.3f B=%.3f" % [
		totals[0] / pixels,
		totals[1] / pixels,
		totals[2] / pixels,
	])
	return image


func _generate_depth_texture(size: int) -> Image:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var totals := [0.0, 0.0, 0.0]
	for y in range(size):
		var v := float(y) / float(size)
		for x in range(size):
			var u := float(x) / float(size)
			var r := _depth_channel(u, v, 4409)
			var g := _depth_channel(u, v, 8089)
			var b := _depth_channel(u, v, 12203)
			totals[0] += r
			totals[1] += g
			totals[2] += b
			image.set_pixel(x, y, Color(r, g, b, 1.0))
	var pixels := float(size * size)
	print("[fog-textures] depth means R=%.3f G=%.3f B=%.3f" % [
		totals[0] / pixels,
		totals[1] / pixels,
		totals[2] / pixels,
	])
	return image


func _density_channel(
		u: float,
		v: float,
		base_frequency: int,
		seed: int) -> float:
	var broad := _fbm(u, v, base_frequency, 4, seed, 0.52)
	var medium := _periodic_value_noise(
		u,
		v,
		base_frequency * 3 + 2,
		seed + 301)
	var breakup := _periodic_value_noise(
		u,
		v,
		base_frequency * 7 + 5,
		seed + 907)
	var field := broad * 0.72 + medium * 0.20 + breakup * 0.08
	field = smoothstep(0.30, 0.79, field)
	field *= lerpf(
		0.78,
		1.0,
		_periodic_value_noise(
			u,
			v,
			base_frequency + 2,
			seed + 1301))
	return clampf(field, 0.0, 1.0)


func _depth_channel(u: float, v: float, seed: int) -> float:
	var broad := _fbm(u, v, 2 + posmod(seed, 3), 3, seed, 0.55)
	var ridges := _periodic_value_noise(u, v, 6 + posmod(seed, 5), seed + 223)
	var field := broad * 0.82 + ridges * 0.18
	field = smoothstep(0.18, 0.88, field)
	return lerpf(0.06, 1.0, field)


func _fbm(
		u: float,
		v: float,
		base_frequency: int,
		octaves: int,
		seed: int,
		gain: float) -> float:
	var total := 0.0
	var normalization := 0.0
	var amplitude := 1.0
	var frequency := base_frequency
	for octave in range(octaves):
		total += _periodic_value_noise(
			u,
			v,
			frequency,
			seed + octave * 101) * amplitude
		normalization += amplitude
		frequency *= 2
		amplitude *= gain
	return total / maxf(normalization, 0.0001)


func _periodic_value_noise(
		u: float,
		v: float,
		frequency: int,
		seed: int) -> float:
	var x := u * float(frequency)
	var y := v * float(frequency)
	var x0 := floori(x)
	var y0 := floori(y)
	var tx := x - float(x0)
	var ty := y - float(y0)
	var sx := tx * tx * (3.0 - 2.0 * tx)
	var sy := ty * ty * (3.0 - 2.0 * ty)
	var x1 := posmod(x0 + 1, frequency)
	var y1 := posmod(y0 + 1, frequency)
	x0 = posmod(x0, frequency)
	y0 = posmod(y0, frequency)
	var a := _lattice(x0, y0, seed)
	var b := _lattice(x1, y0, seed)
	var c := _lattice(x0, y1, seed)
	var d := _lattice(x1, y1, seed)
	return lerpf(
		lerpf(a, b, sx),
		lerpf(c, d, sx),
		sy)


func _lattice(x: int, y: int, seed: int) -> float:
	var value: int = x * 374761393 + y * 668265263 + seed * 1442695041
	value = (value ^ (value >> 13)) * 1274126177
	value ^= value >> 16
	return float(value & 0x00FFFFFF) / 16777215.0
