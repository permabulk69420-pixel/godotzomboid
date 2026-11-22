# Counts draw calls from a few places on the street, with occlusion culling on and off, to check what culling saves.
# Run (needs a display):  xvfb-run -a godot --rendering-driver opengl3 -s res://tools/measure_draw_calls.gd
extends SceneTree

var main: Node3D
var camera: Camera3D
var spots: Array = []
var index := 0
var occlusion := true
var frames := 0
var results: PackedStringArray = []


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if spots.is_empty():
		if frames < 10:
			return false
		_plan()
		_place()
		return false
	if frames < 90:                  # occlusion keeps things visible for a few frames after they are hidden (anti-flicker): let it settle
		return false
	var rid := root.get_viewport_rid()
	var seen := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var shadow := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var tris := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	results.append("%-22s occlusion %-3s  camera draw calls %4d   shadow draw calls %4d   camera triangles %4dk" % [spots[index].name,
		"on" if occlusion else "off", seen, shadow, tris / 1000])
	if occlusion:
		occlusion = false
	else:
		occlusion = true
		index += 1
		if index >= spots.size():
			for line in results:
				print(line)
			return true
	_place()
	return false


func _place() -> void:
	root.use_occlusion_culling = occlusion
	var spot: Dictionary = spots[index]
	main.rig.global_position = Vector3(spot.from.x, main.rig.global_position.y, spot.from.z)
	camera.global_position = spot.from
	camera.look_at(spot.to, Vector3.UP)
	frames = 0


func _plan() -> void:
	camera = Camera3D.new()
	camera.fov = 90.0
	camera.far = 400.0
	root.add_child(camera)
	camera.current = true
	var street: Node3D = main.get_node("Street")
	var lot: Dictionary = street.data.lots[1]
	var variant: Dictionary = street.variants[int(lot.variant)]
	var t := Transform3D(Basis(Vector3.UP, PI if int(lot.side) > 0 else 0.0), Vector3(lot.house.x, 0.0, lot.house.z))
	var door_x: float = variant.door_x
	spots = [
		{"name": "street start", "from": Vector3(-70, 1.65, 1.5), "to": Vector3(-40, 1.4, 1.5)},
		{"name": "street middle", "from": Vector3(0, 1.65, 0), "to": Vector3(30, 1.4, 0)},
		{"name": "looking at houses", "from": Vector3(0, 1.65, 0), "to": Vector3(0, 1.4, -30)},
		{"name": "inside, hall", "from": t * Vector3(door_x, 1.65, -1.5), "to": t * Vector3(door_x, 1.4, -8.0)},
		{"name": "inside, to the window", "from": t * Vector3(door_x, 1.65, -3.0), "to": t * Vector3(door_x, 1.4, 5.0)},
		{"name": "back yard", "from": t * Vector3(0.0, 1.65, -float(variant.depth) - 5.0), "to": t * Vector3(0.0, 1.4, 10.0)},
	]
