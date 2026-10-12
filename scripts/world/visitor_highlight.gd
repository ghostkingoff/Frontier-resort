extends Node2D
## 游客高亮标记：在目标四周画四个橙色中括号，随目标移动、由游客状态面板控制。
## 挂在 world 下、z_index 拉到最高：就算游客躲进建筑或屋顶模式下也要看得见。

const COLOR := Color(1.0, 0.62, 0.15, 0.95)
const HALF := Vector2(21.0, 27.0)    # 括号框的半宽 / 半高（像素）
const ARM := 11.0                    # 每个角的括号臂长
const WIDTH := 3.0

var target: Node2D = null


func set_target(node: Node2D) -> void:
	target = node
	visible = node != null
	if node != null:
		global_position = node.global_position
	queue_redraw()


func clear_target() -> void:
	target = null
	visible = false
	queue_redraw()


func _process(_delta: float) -> void:
	if target == null:
		return
	if not is_instance_valid(target):
		clear_target()
		return
	# 游客可能在建筑内部等其它父节点下，这里始终用全局坐标对齐
	global_position = target.global_position
	queue_redraw()


func _draw() -> void:
	if target == null or not is_instance_valid(target):
		return
	var hw := HALF.x
	var hh := HALF.y
	# 左上
	draw_line(Vector2(-hw, -hh + ARM), Vector2(-hw, -hh), COLOR, WIDTH)
	draw_line(Vector2(-hw, -hh), Vector2(-hw + ARM, -hh), COLOR, WIDTH)
	# 右上
	draw_line(Vector2(hw - ARM, -hh), Vector2(hw, -hh), COLOR, WIDTH)
	draw_line(Vector2(hw, -hh), Vector2(hw, -hh + ARM), COLOR, WIDTH)
	# 左下
	draw_line(Vector2(-hw, hh - ARM), Vector2(-hw, hh), COLOR, WIDTH)
	draw_line(Vector2(-hw, hh), Vector2(-hw + ARM, hh), COLOR, WIDTH)
	# 右下
	draw_line(Vector2(hw - ARM, hh), Vector2(hw, hh), COLOR, WIDTH)
	draw_line(Vector2(hw, hh), Vector2(hw, hh - ARM), COLOR, WIDTH)
