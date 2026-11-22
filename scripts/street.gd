# One suburban street, generated from a seed: a road with kerbs and footpaths, and a row of lots on each side. Each lot gets one of
# the house variants made by tools/make_houses.py (every one enterable), dressed in its own wall material and colours, with a lawn,
# a driveway to the garage, a fence and a wheelie bin. Street lamps run along the footpaths.
#
# The street is made in two steps on purpose: layout() turns a seed into plain data (where everything goes), and build() turns that data
# into nodes. Later, hand edits can sit on top of the data as a separate layer, so the street can be regenerated without losing them.
#
# Coordinates: x along the road, the road centred on z = 0, lots on both sides. A house's own front faces +z, so houses on the
# south side (z > 0) are turned round to face the road.
class_name Street
extends Node3D

const LENGTH := 150.0           # metres along the road (x), centred on 0
const ROAD_HALF := 4.0          # the road is 8 m wide
const KERB_HEIGHT := 0.12
const PATH_WIDTH := 3.2         # verge (grass strip) plus footpath, kerb to lot boundary
const VERGE := 1.2              # the grass strip between the kerb and the footpath, where the lamps stand
const LOT_DEPTH := 34.0         # from the footpath back to the rear fence
const SOLID_LAYER := 1          # things you bump into
const WALK_LAYER := 2           # things you stand on
const HOUSES_JSON := "res://assets/houses/houses.json"
const INTERIOR_VISIBLE := 32.0  # interiors are only drawn within this distance

const SIDING_COLOURS := [Color(0.95, 0.94, 0.90), Color(0.93, 0.88, 0.72), Color(0.74, 0.80, 0.84), Color(0.72, 0.78, 0.68),
	Color(0.82, 0.76, 0.66), Color(0.70, 0.71, 0.72), Color(0.88, 0.80, 0.78)]
const STUCCO_COLOURS := [Color(0.96, 0.92, 0.82), Color(0.92, 0.85, 0.74), Color(0.95, 0.88, 0.84)]
const ROOF_TINTS := [Color(1, 1, 1), Color(0.72, 0.72, 0.74), Color(0.85, 0.74, 0.64), Color(0.55, 0.55, 0.58)]
const TRIM_COLOURS := [Color(0.93, 0.93, 0.90), Color(0.93, 0.93, 0.90), Color(0.30, 0.30, 0.32), Color(0.85, 0.82, 0.74)]
const DOOR_COLOURS := [Color(0.45, 0.10, 0.08), Color(0.12, 0.18, 0.30), Color(0.15, 0.25, 0.18), Color(0.35, 0.22, 0.12), Color(0.9, 0.9, 0.88)]
const FABRIC_COLOURS := [Color(0.30, 0.34, 0.42), Color(0.45, 0.38, 0.30), Color(0.35, 0.40, 0.32), Color(0.50, 0.30, 0.28)]
const INSIDE_COLOURS := [Color(0.95, 0.94, 0.90), Color(0.92, 0.90, 0.82), Color(0.86, 0.88, 0.86), Color(0.94, 0.90, 0.86)]

var seed_value := 1
var data: Dictionary = {}
var variants: Array = []
var _variant_scenes: Dictionary = {}
var _ground := {}               # material key -> SurfaceTool, so each ground material is one mesh for the whole street


func _init(street_seed: int = 1) -> void:
	seed_value = street_seed


func _ready() -> void:
	variants = load_variants()
	data = layout(seed_value, variants)
	build(data)


static func load_variants() -> Array:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(HOUSES_JSON))
	if parsed is Dictionary and parsed.has("variants"):
		return parsed["variants"]
	push_error("Street: could not read " + HOUSES_JSON)
	return []


# ---- layout: seed -> data ----------------------------------------------------------------------------------------------------------

# Where everything on the street goes, as plain data. The same seed always gives the same street.
static func layout(street_seed: int, house_variants: Array) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = street_seed
	var lots: Array = []
	for side in [-1, 1]:                                  # -1: the north side (negative z), 1: the south side
		var x := -LENGTH * 0.5
		var last_variant := -1
		while true:
			var pick := rng.randi_range(0, house_variants.size() - 1)
			if int(house_variants[pick].id) == last_variant:     # never the same house twice in a row
				pick = (pick + 1) % house_variants.size()
			var variant: Dictionary = house_variants[pick]
			var lot := _make_lot(rng, side, x, variant)
			if lot.x1 > LENGTH * 0.5:
				break
			lots.append(lot)
			last_variant = int(variant.id)
			x = lot.x1
	var lamps: Array = []
	var lamp_x := -LENGTH * 0.5 + 12.0
	var lamp_side := -1
	while lamp_x < LENGTH * 0.5:
		lamps.append(Vector3(lamp_x, KERB_HEIGHT, lamp_side * (ROAD_HALF + VERGE * 0.5)))
		lamp_side = -lamp_side
		lamp_x += 26.0
	return {"seed": street_seed, "lots": lots, "lamps": lamps}


static func _make_lot(rng: RandomNumberGenerator, side: int, x0: float, variant: Dictionary) -> Dictionary:
	var front := ROAD_HALF + PATH_WIDTH                 # the lot's front edge, from the road centre
	var flip := -1.0 if side > 0 else 1.0               # houses on the south side are turned round, which mirrors their x
	var min_x: float = variant.min_x
	var max_x: float = variant.max_x
	var has_garage: bool = variant.garage != null
	var margin_a := rng.randf_range(2.5, 4.0)           # the lot's low-x side
	var margin_b := rng.randf_range(2.5, 4.0)           # the lot's high-x side
	if not has_garage:
		margin_b = rng.randf_range(4.5, 5.5)            # room for a driveway down the side
	var low_local := min_x if flip > 0.0 else -max_x    # the house's low-x edge, relative to its origin, after turning
	var house_x := x0 + margin_a - low_local
	var width := (max_x - min_x) + margin_a + margin_b
	var setback := rng.randf_range(7.0, 9.5)            # lot front edge to the front wall (the porch stands in front of it)
	var house_z := side * (front + setback)
	var drive: Dictionary
	if has_garage:
		var garage: Dictionary = variant.garage
		var gx: float = house_x + flip * float(garage.door_x)
		drive = {"x": gx, "width": 5.6, "length": setback + float(garage.front_y)}
	else:
		drive = {"x": x0 + width - margin_b * 0.5, "width": 3.0, "length": setback + 6.0}
	var wall_kind := "siding"
	var roll := rng.randf()
	if roll > 0.8:
		wall_kind = "brick"
	elif roll > 0.62:
		wall_kind = "stucco"
	var wall_tint: Color = Color.WHITE
	if wall_kind == "siding":
		wall_tint = SIDING_COLOURS[rng.randi_range(0, SIDING_COLOURS.size() - 1)]
	elif wall_kind == "stucco":
		wall_tint = STUCCO_COLOURS[rng.randi_range(0, STUCCO_COLOURS.size() - 1)]
	var bin_side := 1.0 if rng.randf() < 0.5 else -1.0
	return {
		"side": side, "x0": x0, "x1": x0 + width,
		"variant": int(variant.id),
		"house": {"x": house_x, "z": house_z, "flip": flip,
			"x_min": house_x + minf(flip * min_x, flip * max_x), "x_max": house_x + maxf(flip * min_x, flip * max_x)},
		"style": {
			"wall": wall_kind, "wall_tint": wall_tint,
			"roof_tint": ROOF_TINTS[rng.randi_range(0, ROOF_TINTS.size() - 1)],
			"trim": TRIM_COLOURS[rng.randi_range(0, TRIM_COLOURS.size() - 1)],
			"door": DOOR_COLOURS[rng.randi_range(0, DOOR_COLOURS.size() - 1)],
			"fabric": FABRIC_COLOURS[rng.randi_range(0, FABRIC_COLOURS.size() - 1)],
			"inside": INSIDE_COLOURS[rng.randi_range(0, INSIDE_COLOURS.size() - 1)],
		},
		"driveway": drive,
		"bin": Vector3(float(drive.x) + bin_side * (float(drive.width) * 0.5 + 0.7), 0.0, side * (front + 0.8)),
	}


# ---- build: data -> nodes ----------------------------------------------------------------------------------------------------------

func build(street: Dictionary) -> void:
	var front := ROAD_HALF + PATH_WIDTH
	var far := front + LOT_DEPTH
	var half := LENGTH * 0.5 + 60.0                  # the road and ground run on past the last houses, into the fog
	# road, kerbs, verges and footpaths (one mesh per material for the whole street)
	_flat("asphalt", -half, half, -ROAD_HALF, ROAD_HALF, 0.0)
	for side in [-1, 1]:
		var s := float(side)
		var kerb_out := ROAD_HALF + 0.15
		_flat("kerb", -half, half, minf(s * ROAD_HALF, s * kerb_out), maxf(s * ROAD_HALF, s * kerb_out), KERB_HEIGHT)
		_side_face("kerb", -half, half, s * ROAD_HALF, 0.0, KERB_HEIGHT, -s)
		_lawn(-half, half, minf(s * kerb_out, s * (ROAD_HALF + VERGE)), maxf(s * kerb_out, s * (ROAD_HALF + VERGE)), KERB_HEIGHT)
		_flat("footpath", -half, half, minf(s * (ROAD_HALF + VERGE), s * front), maxf(s * (ROAD_HALF + VERGE), s * front), KERB_HEIGHT)
		# the lawns behind the footpath: one big sheet each side (driveways sit just above it), with patchy colour so the tiling hides
		_lawn(-half, half, minf(s * front, s * (far + 40.0)), maxf(s * front, s * (far + 40.0)))
		_side_face("footpath", -half, half, s * front, 0.0, KERB_HEIGHT, s)
		_walk_box(Vector3(0.0, KERB_HEIGHT * 0.5 - 0.25, s * (ROAD_HALF + PATH_WIDTH * 0.5)), Vector3(half * 2.0, KERB_HEIGHT + 0.5, PATH_WIDTH))
	_walk_box(Vector3(0.0, -0.25, 0.0), Vector3(half * 2.0, 0.5, (far + 40.0) * 2.0))
	for lot: Dictionary in street.lots:
		_build_lot(lot, front, far)
	for lamp: Vector3 in street.lamps:
		_build_lamp(lamp)
	_finish_ground()


func _build_lot(lot: Dictionary, front: float, far: float) -> void:
	var side: int = lot.side
	var s := float(side)
	var house_data: Dictionary = lot.house
	var variant: Dictionary = _variant(int(lot.variant))
	var house := _make_house(variant, lot.style)
	house.position = Vector3(house_data.x, 0.0, house_data.z)
	house.rotation.y = PI if side > 0 else 0.0
	house.name = "House%d" % get_child_count()
	add_child(house)
	# the driveway, from the footpath to the garage (or down the side of the house)
	var drive: Dictionary = lot.driveway
	var dx: float = drive.x
	var dw: float = drive.width
	var dl: float = drive.length
	_flat("driveway", dx - dw * 0.5, dx + dw * 0.5, minf(s * front, s * (front + dl)), maxf(s * front, s * (front + dl)), 0.012)
	# a path from the footpath to the front door (or the front of the porch)
	var door_x: float = house_data.x + house_data.flip * float(variant.door_x)
	var path_end := absf(house_data.z) + float(variant.front_y)       # front_y is negative: the porch stands out in front of the wall
	_flat("footpath", door_x - 0.6, door_x + 0.6, minf(s * front, s * path_end), maxf(s * front, s * path_end), 0.01)
	# fences: down the low-x side of the lot from level with the house front, and across the back
	var x0: float = lot.x0
	var x1: float = lot.x1
	var house_front := absf(house_data.z)
	_fence(Vector3(x0, 0.0, s * house_front), Vector3(x0, 0.0, s * far))
	_fence(Vector3(x0, 0.0, s * far), Vector3(x1, 0.0, s * far))
	# the wheelie bin, out by the kerb for collection day
	var bin_pos: Vector3 = lot.bin
	_bin(bin_pos)


func _variant(id: int) -> Dictionary:
	for v: Dictionary in variants:
		if int(v.id) == id:
			return v
	push_error("Street: no house variant %d" % id)
	return variants[0]


# One house: the variant's scene, with its surfaces dressed in this lot's style, its interior hidden from a distance, and its
# collision boxes turned into physics bodies.
func _make_house(variant: Dictionary, style: Dictionary) -> Node3D:
	var path: String = "res://assets/houses/" + String(variant.file)
	if not _variant_scenes.has(path):
		_variant_scenes[path] = load(path)
	var scene: PackedScene = _variant_scenes[path]
	var house: Node3D = scene.instantiate()
	for child in house.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var part := String(mi.name).to_lower()
		if part.begins_with("collision"):
			var body := StaticBody3D.new()
			body.collision_layer = WALK_LAYER if part.contains("walk") else SOLID_LAYER
			body.collision_mask = 0
			var shape := CollisionShape3D.new()
			var concave := ConcavePolygonShape3D.new()
			concave.set_faces(mi.mesh.get_faces())
			shape.shape = concave
			body.add_child(shape)
			body.transform = mi.transform
			mi.get_parent().add_child(body)
			mi.queue_free()
			continue
		for i in mi.mesh.get_surface_count():
			var source := mi.mesh.surface_get_material(i)
			var surface_name := source.resource_name if source != null else ""
			mi.set_surface_override_material(i, Materials.for_house_surface(surface_name.get_slice(".", 0), style))
		if part.begins_with("interior"):
			mi.visibility_range_end = INTERIOR_VISIBLE
			mi.visibility_range_end_margin = 2.0
		elif part.begins_with("glass"):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return house


func _build_lamp(base: Vector3) -> void:
	var pole_mat := Materials.plain(Color(0.30, 0.31, 0.32), 0.5)
	var pole := _box("LampPole", base + Vector3(0.0, 3.5, 0.0), Vector3(0.14, 7.0, 0.14), pole_mat)
	_solid_box(pole, Vector3(0.14, 7.0, 0.14))
	var toward_road := -signf(base.z)
	_box("LampArm", base + Vector3(0.0, 6.95, toward_road * 0.7), Vector3(0.08, 0.08, 1.4), pole_mat)
	var head_mat := Materials.plain(Color(0.9, 0.85, 0.7), 0.4)
	_box("LampHead", base + Vector3(0.0, 6.85, toward_road * 1.3), Vector3(0.28, 0.14, 0.5), head_mat)


func _fence(a: Vector3, b: Vector3) -> void:
	var lo := Vector3(minf(a.x, b.x) - 0.04, 0.0, minf(a.z, b.z) - 0.04)
	var hi := Vector3(maxf(a.x, b.x) + 0.04, 1.8, maxf(a.z, b.z) + 0.04)
	_ground_box("fence", lo, hi)
	var body := StaticBody3D.new()
	body.collision_layer = SOLID_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = hi - lo
	shape.shape = box
	body.add_child(shape)
	body.position = (lo + hi) * 0.5
	add_child(body)


func _bin(at: Vector3) -> void:
	var body_mat := Materials.plain(Color(0.16, 0.30, 0.18), 0.6)
	var lid_mat := Materials.plain(Color(0.55, 0.12, 0.10), 0.6)
	var bin := _box("Bin", at + Vector3(0.0, 0.52, 0.0), Vector3(0.58, 1.0, 0.72), body_mat)
	_solid_box(bin, Vector3(0.58, 1.0, 0.72))
	_box("BinLid", at + Vector3(0.0, 1.05, 0.0), Vector3(0.62, 0.06, 0.76), lid_mat)


# ---- ground meshes: flat pieces with UVs in metres, merged per material ----------------------------------------------------------

func _tool(kind: String) -> SurfaceTool:
	if not _ground.has(kind):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_ground[kind] = st
	return _ground[kind]


func _quad(kind: String, corners: Array, normal: Vector3, uvs: Array) -> void:
	var st := _tool(kind)
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_normal(normal)
		st.set_color(Color.WHITE)
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])


# A flat rectangle facing up at height y, UVs = world x/z in metres.
func _flat(kind: String, x0: float, x1: float, z0: float, z1: float, y: float) -> void:
	var c := [Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)]
	# wound so the face points up (Godot's front faces are clockwise seen from the front)
	_quad(kind, [c[0], c[1], c[2], c[3]], Vector3.UP, [Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])


# Lawn, split into a grid whose corners get slowly varying colours (greener, drier, darker patches), which breaks up the repeating
# grass texture far better than a bigger texture would.
var _lawn_noise: FastNoiseLite


func _lawn(x0: float, x1: float, z0: float, z1: float, y: float = 0.0) -> void:
	if _lawn_noise == null:
		_lawn_noise = FastNoiseLite.new()
		_lawn_noise.seed = seed_value
		_lawn_noise.frequency = 0.045
		_lawn_noise.fractal_octaves = 3
	const CELL := 4.0
	var nx := int(ceil((x1 - x0) / CELL))
	var nz := int(ceil((z1 - z0) / CELL))
	for i in nx:
		for j in nz:
			var ax := x0 + (x1 - x0) * i / nx
			var bx := x0 + (x1 - x0) * (i + 1) / nx
			var az := z0 + (z1 - z0) * j / nz
			var bz := z0 + (z1 - z0) * (j + 1) / nz
			var c := [Vector3(ax, y, az), Vector3(bx, y, az), Vector3(bx, y, bz), Vector3(ax, y, bz)]
			var st := _tool("lawn")
			for k in [0, 1, 2, 0, 2, 3]:
				var p: Vector3 = c[k]
				st.set_normal(Vector3.UP)
				st.set_color(_lawn_colour(p.x, p.z))
				st.set_uv(Vector2(p.x, p.z))
				st.add_vertex(p)


func _lawn_colour(x: float, z: float) -> Color:
	var n := _lawn_noise.get_noise_2d(x, z)                  # about -1..1
	var dry := clampf(_lawn_noise.get_noise_2d(x * 0.6 + 400.0, z * 0.6) * 1.6 + 0.2, 0.0, 1.0)
	var lush := Color(0.82, 0.98, 0.78)
	var parched := Color(1.08, 1.0, 0.74)
	return lush.lerp(parched, dry) * (0.88 + 0.18 * n)


# A vertical strip along x at z, from y0 to y1, facing +z (facing = 1) or -z (facing = -1).
func _side_face(kind: String, x0: float, x1: float, z: float, y0: float, y1: float, facing: float) -> void:
	var c := [Vector3(x0, y1, z), Vector3(x1, y1, z), Vector3(x1, y0, z), Vector3(x0, y0, z)]
	var uv := [Vector2(x0, -y1), Vector2(x1, -y1), Vector2(x1, -y0), Vector2(x0, -y0)]
	if facing > 0.0:
		_quad(kind, c, Vector3(0, 0, 1), uv)
	else:
		_quad(kind, [c[1], c[0], c[3], c[2]], Vector3(0, 0, -1), [uv[1], uv[0], uv[3], uv[2]])


# A box (top and four sides) with UVs in metres.
func _ground_box(kind: String, lo: Vector3, hi: Vector3) -> void:
	_flat(kind, lo.x, hi.x, lo.z, hi.z, hi.y)
	_side_face(kind, lo.x, hi.x, hi.z, lo.y, hi.y, 1.0)
	_side_face(kind, lo.x, hi.x, lo.z, lo.y, hi.y, -1.0)
	var c := [Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, lo.y, lo.z)]
	var uv := [Vector2(lo.z, -hi.y), Vector2(hi.z, -hi.y), Vector2(hi.z, -lo.y), Vector2(lo.z, -lo.y)]
	_quad(kind, c, Vector3(-1, 0, 0), uv)
	c = [Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z)]
	uv = [Vector2(hi.z, -hi.y), Vector2(lo.z, -hi.y), Vector2(lo.z, -lo.y), Vector2(hi.z, -lo.y)]
	_quad(kind, c, Vector3(1, 0, 0), uv)


func _finish_ground() -> void:
	for kind: String in _ground:
		var st: SurfaceTool = _ground[kind]
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.name = "Ground_" + kind
		mi.mesh = st.commit()
		mi.material_override = _ground_material(kind)
		if kind in ["asphalt", "lawn", "footpath", "driveway", "kerb"]:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_ground.clear()


func _ground_material(kind: String) -> Material:
	match kind:
		"kerb":
			return Materials.textured("footpath", Color(0.85, 0.85, 0.82))
		"fence":
			return Materials.textured("siding", Color(0.62, 0.50, 0.38))
	return Materials.textured(kind)


# ---- helpers -----------------------------------------------------------------------------------------------------------------------

var _box_meshes: Dictionary = {}


func _box(node_name: String, center: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
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


func _solid_box(on: Node3D, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = SOLID_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	on.add_child(body)


func _walk_box(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = WALK_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	add_child(body)
