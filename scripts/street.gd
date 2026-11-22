# One suburban street, generated from a seed: a road with kerbs and footpaths, a row of lots on each side, and on each lot a house, a
# driveway, a lawn and a wheelie bin, with street lamps along the footpath. Greybox for now: plain boxes and colours, to judge scale and
# layout in the headset before any real art goes in.
#
# The street is made in two steps on purpose: layout() turns a seed into plain data (where everything goes), and build() turns that data
# into meshes. Later, hand edits can sit on top of the data as a separate layer, so the street can be regenerated without losing them.
class_name Street
extends Node3D

const LENGTH := 96.0            # metres along the road (x), centred on 0
const ROAD_HALF := 3.5          # the road is 7 m wide, centred on z = 0
const KERB_HEIGHT := 0.12
const PATH_WIDTH := 2.0         # footpath beside each kerb
const LOT_DEPTH := 22.0         # from the footpath back to the rear fence
const LOT_MIN := 13.0           # lot frontage range
const LOT_MAX := 18.0
const LAMP_SPACING := 24.0
const SOLID_LAYER := 1          # things you bump into

var seed_value := 1
var data: Dictionary = {}


func _init(street_seed: int = 1) -> void:
	seed_value = street_seed


func _ready() -> void:
	data = layout(seed_value)
	build(data)


# ---- layout: seed -> data ----------------------------------------------------------------------------------------------------------

# Where everything on the street goes, as plain data. The same seed always gives the same street.
# Each lot: {side, x0, x1, house: {center, size, roof_height, colour}, driveway: {x, width}, bin: position}
static func layout(street_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = street_seed
	var lots: Array = []
	for side in [-1, 1]:                                   # -1: the north side (negative z), 1: the south side
		var x := -LENGTH * 0.5
		while true:
			var width := rng.randf_range(LOT_MIN, LOT_MAX)
			if x + width > LENGTH * 0.5:
				break
			lots.append(_make_lot(rng, side, x, x + width))
			x += width
	var lamps: Array = []
	var lamp_x := -LENGTH * 0.5 + LAMP_SPACING * 0.5
	var lamp_side := -1
	while lamp_x < LENGTH * 0.5:
		lamps.append(Vector3(lamp_x, 0.0, lamp_side * (ROAD_HALF + 0.4)))
		lamp_side = -lamp_side
		lamp_x += LAMP_SPACING
	return {"seed": street_seed, "lots": lots, "lamps": lamps}


static func _make_lot(rng: RandomNumberGenerator, side: int, x0: float, x1: float) -> Dictionary:
	var front := ROAD_HALF + PATH_WIDTH                  # where the lot starts, measured from the road centre
	var width := x1 - x0
	var house_w := minf(rng.randf_range(8.0, 11.0), width - 4.5)      # leaves room for the driveway down one side
	var house_d := rng.randf_range(8.0, 10.0)
	var setback := rng.randf_range(5.0, 7.5)             # front lawn depth
	var drive_on_left := rng.randf() < 0.5
	var drive_w := 3.0
	var house_x := x0 + 0.75 + house_w * 0.5 if not drive_on_left else x1 - 0.75 - house_w * 0.5
	var drive_x := x1 - 0.5 - drive_w * 0.5 if not drive_on_left else x0 + 0.5 + drive_w * 0.5
	var house_z := side * (front + setback + house_d * 0.5)
	var palette: Array = [Color(0.86, 0.82, 0.72), Color(0.72, 0.62, 0.52), Color(0.80, 0.78, 0.70), Color(0.62, 0.66, 0.62),
		Color(0.85, 0.74, 0.62), Color(0.70, 0.72, 0.76)]
	var bin_x := drive_x + (drive_w * 0.5 + 0.5) * (1.0 if drive_on_left else -1.0)
	return {
		"side": side, "x0": x0, "x1": x1,
		"house": {
			"center": Vector3(house_x, 0.0, house_z),
			"size": Vector3(house_w, rng.randf_range(2.8, 3.2), house_d),
			"roof_height": rng.randf_range(1.6, 2.4),
			"colour": palette[rng.randi_range(0, palette.size() - 1)],
		},
		"driveway": {"x": drive_x, "width": drive_w},
		"bin": Vector3(bin_x, 0.0, side * (front + 0.6)),
		"bin_out": rng.randf() < 0.6,                     # some bins are out on the kerb, the rest by the house
	}


# ---- build: data -> meshes ---------------------------------------------------------------------------------------------------------

func build(street: Dictionary) -> void:
	var front := ROAD_HALF + PATH_WIDTH
	var far := front + LOT_DEPTH
	# the ground everything sits on, a little wider than the street so its edge is lost in the fog
	_box("Ground", Vector3(0.0, -0.05, 0.0), Vector3(LENGTH + 80.0, 0.1, far * 2.0 + 80.0), _mat(Color(0.33, 0.40, 0.24), 1.0))
	_box("Road", Vector3(0.0, 0.0, 0.0), Vector3(LENGTH + 80.0, 0.02, ROAD_HALF * 2.0), _mat(Color(0.20, 0.20, 0.21), 0.95))
	for side in [-1, 1]:
		_box("Kerb", Vector3(0.0, KERB_HEIGHT * 0.5, side * (ROAD_HALF + 0.1)), Vector3(LENGTH + 80.0, KERB_HEIGHT, 0.2), _mat(Color(0.55, 0.55, 0.52), 0.9))
		_box("Footpath", Vector3(0.0, KERB_HEIGHT * 0.5, side * (ROAD_HALF + 0.2 + (PATH_WIDTH - 0.2) * 0.5)),
			Vector3(LENGTH + 80.0, KERB_HEIGHT, PATH_WIDTH - 0.2), _mat(Color(0.62, 0.61, 0.57), 0.9))
	for lot: Dictionary in street.lots:
		_build_lot(lot, front, far)
	for lamp: Vector3 in street.lamps:
		_build_lamp(lamp)


func _build_lot(lot: Dictionary, front: float, far: float) -> void:
	var side: int = lot.side
	var house: Dictionary = lot.house
	var center: Vector3 = house.center
	var size: Vector3 = house.size
	var roof_h: float = house.roof_height
	var walls := _box("House", center + Vector3(0.0, size.y * 0.5, 0.0), size, _mat(house.colour, 0.85))
	_make_solid(walls, size)
	# a gable roof, ridge running along the street, overhanging the walls a little
	var roof := MeshInstance3D.new()
	roof.name = "Roof"
	var prism := PrismMesh.new()
	prism.size = Vector3(size.z + 0.8, roof_h, size.x + 0.8)
	roof.mesh = prism
	roof.material_override = _mat(Color(0.36, 0.24, 0.20), 0.8)
	roof.position = center + Vector3(0.0, size.y + roof_h * 0.5, 0.0)
	roof.rotation.y = PI * 0.5
	add_child(roof)
	# a front door, facing the street
	_box("Door", center + Vector3(0.0, 1.0, -side * (size.z * 0.5 + 0.02)), Vector3(0.95, 2.0, 0.06), _mat(Color(0.30, 0.18, 0.12), 0.7))
	# the driveway, from the footpath up to beside the house
	var drive: Dictionary = lot.driveway
	var drive_len: float = absf(center.z) + size.z * 0.5 - front
	_box("Driveway", Vector3(drive.x, 0.015, side * (front + drive_len * 0.5)), Vector3(drive.width, 0.03, drive_len), _mat(Color(0.50, 0.49, 0.46), 0.95))
	# a low fence along the back and between lots
	var fence_mat := _mat(Color(0.45, 0.36, 0.26), 0.9)
	var x0: float = lot.x0
	var x1: float = lot.x1
	var back := _box("Fence", Vector3((x0 + x1) * 0.5, 0.9, side * far), Vector3(x1 - x0, 1.8, 0.08), fence_mat)
	_make_solid(back, Vector3(x1 - x0, 1.8, 0.08))
	var depth_from := absf(center.z) - size.z * 0.5            # side fences start level with the front of the house
	var side_len := far - depth_from
	var side_fence := _box("Fence", Vector3(x0, 0.9, side * (depth_from + side_len * 0.5)), Vector3(0.08, 1.8, side_len), fence_mat)
	_make_solid(side_fence, Vector3(0.08, 1.8, side_len))
	# the wheelie bin: out on the kerb, or back beside the house
	var bin_pos: Vector3 = lot.bin
	var floor_y := KERB_HEIGHT                              # standing on the footpath
	if not lot.bin_out:
		bin_pos.z = side * (absf(center.z) - size.z * 0.5 - 0.6)     # just in front of the house
		floor_y = 0.0
	var bin := _box("Bin", bin_pos + Vector3(0.0, floor_y + 0.5, 0.0), Vector3(0.58, 1.0, 0.72), _mat(Color(0.16, 0.30, 0.18), 0.6))
	_make_solid(bin, Vector3(0.58, 1.0, 0.72))
	_box("BinLid", bin_pos + Vector3(0.0, floor_y + 1.03, 0.0), Vector3(0.62, 0.06, 0.76), _mat(Color(0.55, 0.12, 0.10), 0.6))


func _build_lamp(base: Vector3) -> void:
	var pole_mat := _mat(Color(0.30, 0.31, 0.32), 0.5)
	var pole := _box("LampPole", base + Vector3(0.0, KERB_HEIGHT + 3.5, 0.0), Vector3(0.12, 7.0, 0.12), pole_mat)
	_make_solid(pole, Vector3(0.12, 7.0, 0.12))
	var toward_road := -signf(base.z)
	_box("LampArm", base + Vector3(0.0, KERB_HEIGHT + 6.95, toward_road * 0.6), Vector3(0.08, 0.08, 1.2), pole_mat)
	var head_mat := _mat(Color(0.9, 0.85, 0.7), 0.4)
	head_mat.emission_enabled = true
	head_mat.emission = Color(1.0, 0.85, 0.6)
	head_mat.emission_energy_multiplier = 0.6
	_box("LampHead", base + Vector3(0.0, KERB_HEIGHT + 6.85, toward_road * 1.15), Vector3(0.25, 0.12, 0.45), head_mat)


# ---- helpers -----------------------------------------------------------------------------------------------------------------------

var _materials: Dictionary = {}


# One material per colour, shared by everything of that colour (fewer materials is cheaper on the Quest).
func _mat(colour: Color, roughness: float) -> StandardMaterial3D:
	var key := "%s/%.2f" % [colour.to_html(), roughness]
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = colour
		m.roughness = roughness
		_materials[key] = m
	return _materials[key]


var _box_meshes: Dictionary = {}


func _box(node_name: String, center: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var key := "%.3f,%.3f,%.3f" % [size.x, size.y, size.z]
	if not _box_meshes.has(key):
		var mesh := BoxMesh.new()
		mesh.size = size
		_box_meshes[key] = mesh
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = _box_meshes[key]
	instance.material_override = material
	instance.position = center
	add_child(instance)
	return instance


func _make_solid(on: Node3D, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = SOLID_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	on.add_child(body)
