# Takes screenshots of the game from a few fixed spots, for checking the look without a headset.
# Run (needs a display, e.g. xvfb-run on CI):  godot --rendering-driver opengl3 -s res://tools/screenshots.gd
# Pictures are written to shots/ in the project folder.
extends SceneTree

const SETTLE_FRAMES := 40

var main: Node3D
var camera: Camera3D
var shots: Array = []
var shot_index := -1
var wait := 0


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))


func _process(_delta: float) -> bool:
	if shot_index == -1:
		wait += 1
		if wait < 10:
			return false
		_plan_shots()
		shot_index = 0
		_place(shots[0])
		wait = 0
		return false
	wait += 1
	if wait < SETTLE_FRAMES:
		return false
	var image := root.get_texture().get_image()
	var path := "res://shots/%02d_%s.png" % [shot_index, shots[shot_index].name]
	image.save_png(ProjectSettings.globalize_path(path))
	print("saved ", path)
	shot_index += 1
	if shot_index >= shots.size():
		return true
	_place(shots[shot_index])
	wait = 0
	return false


func _place(shot: Dictionary) -> void:
	# the player stands where the camera is too, so the game knows when you are indoors (the fog fades there)
	main.rig.global_position = Vector3(shot.from.x, main.rig.global_position.y, shot.from.z)
	camera.global_position = shot.from
	camera.look_at(shot.to, Vector3.UP)


func _plan_shots() -> void:
	camera = Camera3D.new()
	camera.fov = 75.0
	camera.near = 0.05
	camera.far = 400.0
	root.add_child(camera)
	camera.current = true
	var street: Node3D = main.get_node("Street")
	var lots: Array = street.data.lots
	shots.append({"name": "street_start", "from": Vector3(-70, 1.65, 1.5), "to": Vector3(-40, 1.4, 1.5)})
	shots.append({"name": "street_middle", "from": Vector3(-10, 1.65, -2.5), "to": Vector3(10, 1.2, -8)})
	# the wildest lot: ivy and long grass
	for wild: Dictionary in lots:
		if int(wild.get("overgrowth", 0)) == 2:
			var wv: Dictionary = street.variants[int(wild.variant)]
			var wt := Transform3D(Basis(Vector3.UP, PI if int(wild.side) > 0 else 0.0), Vector3(wild.house.x, 0.0, wild.house.z))
			shots.append({"name": "overgrown", "from": wt * Vector3(float(wv.door_x) + 5.0, 1.65, 8.0), "to": wt * Vector3(float(wv.door_x) - 2.0, 1.2, -2.0)})
			break
	# the first house on the north side: from its front lawn, then inside
	var lot: Dictionary = lots[0]
	var house: Node3D = street.get_node(NodePath(_house_name(street, 0)))
	var variant: Dictionary = street.variants[int(lot.variant)]
	var t := house.global_transform
	var door_x: float = variant.door_x
	var living_dir := 1.0 if variant.mirrored else -1.0          # the living room is on this side of the hall
	shots.append({"name": "house_front", "from": t * Vector3(door_x - 4.0, 1.65, 9.0), "to": t * Vector3(door_x, 2.0, -3.0)})
	# inside: the hall runs back from the front door; the living room and kitchen are on one side, the bedrooms on the other
	var L := living_dir
	shots.append({"name": "hall", "from": t * Vector3(door_x, 1.65, -0.8), "to": t * Vector3(door_x, 1.3, -8.0)})
	shots.append({"name": "living_room", "from": t * Vector3(door_x + L * 4.6, 1.65, -5.6), "to": t * Vector3(door_x + L * 1.0, 1.0, -0.8)})
	shots.append({"name": "kitchen", "from": t * Vector3(door_x + L * 0.2, 1.65, -6.6), "to": t * Vector3(door_x + L * 4.5, 0.9, -10.0)})
	shots.append({"name": "bedroom", "from": t * Vector3(door_x - L * 1.0, 1.65, -0.9), "to": t * Vector3(door_x - L * 6.0, 0.7, -3.0)})


func _house_name(street: Node3D, index: int) -> String:
	var houses := street.find_children("House*", "Node3D", false, false)
	return String(houses[index].name)
