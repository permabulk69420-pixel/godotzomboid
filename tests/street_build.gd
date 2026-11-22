# Builds the real street (houses, materials, collision) with no screen, to catch mistakes before they reach the headset.
# Run with  godot --headless -s res://tests/street_build.gd   (CI also fails the build on any SCRIPT ERROR in the output)
extends SceneTree

var failures := 0
var street: Node3D
var frames := 0


func _initialize() -> void:
	street = load("res://scripts/street.gd").new(1)
	root.add_child(street)


func _process(_delta: float) -> bool:
	frames += 1
	if frames < 3:
		return false
	var lots: Array = street.data.get("lots", [])
	var houses := street.find_children("House*", "Node3D", false, false)
	check(houses.size() == lots.size() and houses.size() >= 8, "one house per lot (%d houses, %d lots)" % [houses.size(), lots.size()])
	for house: Node3D in houses:
		var meshes := house.find_children("*", "MeshInstance3D", true, false)
		var names: PackedStringArray = []
		for mi: MeshInstance3D in meshes:
			names.append(String(mi.name).to_lower())
			for i in mi.mesh.get_surface_count():
				check(mi.get_surface_override_material(i) != null, "%s/%s surface %d has a material" % [house.name, mi.name, i])
		check("exterior" in names and "interior" in names and "glass" in names, "%s has exterior, interior and glass (%s)" % [house.name, names])
		check(not ("collision_solid" in names), "%s collision meshes were turned into bodies" % house.name)
		var bodies := house.find_children("*", "StaticBody3D", true, false)
		check(bodies.size() >= 2, "%s has solid and walkable collision" % house.name)
	for kind in ["asphalt", "lawn", "footpath", "driveway"]:
		check(street.get_node_or_null("Ground_" + kind) != null, "ground mesh for " + kind)
	# standing in front of the first house, a ray down finds the ground; inside it, a ray finds the floor
	var lot: Dictionary = lots[0]
	var space := street.get_world_3d().direct_space_state
	var inside := Vector3(float(lot.house.x), 2.0, float(lot.house.z) + float(lot.side) * 4.0)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(inside, inside + Vector3.DOWN * 3.0, 2))
	check(not hit.is_empty() and absf(hit.position.y - 0.15) < 0.02, "a house floor is walkable at 0.15 m (got %s)" % [hit.get("position")])
	if failures == 0:
		print("street_build: all good (%d houses)" % houses.size())
	quit(1 if failures > 0 else 0)
	return true


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", what)
