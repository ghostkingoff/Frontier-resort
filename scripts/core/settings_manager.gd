extends Node
## 全局设置：音量、窗口模式。保存在 user://settings.cfg

signal settings_changed

const CONFIG_PATH := "user://settings.cfg"
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"

var master_volume := 0.8
var music_volume := 0.6
var sfx_volume := 0.8
var fullscreen := false


func _ready() -> void:
	_ensure_buses()
	load_settings()
	apply()


func _exit_tree() -> void:
	# 退出时把音乐播放器彻底释放，避免 Godot 在退出时报“资源仍在使用”
	var player := get_node_or_null("Music")
	if player:
		player.stop()
		player.stream = null


func _ensure_buses() -> void:
	for bus_name in [BUS_MUSIC, BUS_SFX]:
		if AudioServer.get_bus_index(bus_name) != -1:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")


func apply() -> void:
	_set_bus_volume("Master", master_volume)
	_set_bus_volume(BUS_MUSIC, music_volume)
	_set_bus_volume(BUS_SFX, sfx_volume)
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
	settings_changed.emit()


func _set_bus_volume(bus_name: String, value: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	AudioServer.set_bus_mute(idx, value <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(value, 0.001)))


func set_master(value: float) -> void:
	master_volume = clampf(value, 0.0, 1.0)
	apply()
	save_settings()


func set_music(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)
	apply()
	save_settings()


func set_sfx(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)
	apply()
	save_settings()


func set_fullscreen(value: bool) -> void:
	fullscreen = value
	apply()
	save_settings()


func play_click() -> void:
	play_sfx("res://art/placeholder/audio/success1.wav", -6.0)


func play_sfx(path: String, volume_db: float = 0.0) -> void:
	if not ResourceLoader.exists(path):
		return
	var player := AudioStreamPlayer.new()
	player.stream = load(path)
	player.bus = BUS_SFX
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func play_music(path: String) -> void:
	if not ResourceLoader.exists(path):
		return
	var existing := get_node_or_null("Music")
	if existing and existing.stream and existing.stream.resource_path == path and existing.playing:
		return
	if existing:
		existing.queue_free()
	var player := AudioStreamPlayer.new()
	player.name = "Music"
	player.stream = load(path)
	player.bus = BUS_MUSIC
	player.volume_db = -4.0
	add_child(player)
	player.play()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.save(CONFIG_PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	master_volume = float(cfg.get_value("audio", "master", master_volume))
	music_volume = float(cfg.get_value("audio", "music", music_volume))
	sfx_volume = float(cfg.get_value("audio", "sfx", sfx_volume))
	fullscreen = bool(cfg.get_value("video", "fullscreen", fullscreen))
