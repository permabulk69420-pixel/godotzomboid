# Checks the street layout without a headset: run with  godot --headless -s res://tests/street_logic.gd
# The same seed must give the same street, lots must not overlap, and houses must sit inside their lots, clear of the footpath.
extends SceneTree

const StreetScript := preload("res://scripts/street.gd")

var failures := 0


func _init() -> void:
	var a: Dictionary = StreetScript.layout(1)
	var b: Dictionary = StreetScript.layout(1)
	var c: Dictionary = StreetScript.layout(2)
	check(var_to_str(a) == var_to_str(b), "same seed gives the same street")
	check(var_to_str(a) != var_to_str(c), "a different seed gives a different street")
	for street: Dictionary in [a, c]:
		check(street.lots.size() >= 8, "seed %d has at least 8 lots (got %d)" % [street.seed, street.lots.size()])
		check(street.lamps.size() >= 3, "seed %d has street lamps" % street.seed)
		var front: float = StreetScript.ROAD_HALF + StreetScript.PATH_WIDTH
		for lot: Dictionary in street.lots:
			var house: Dictionary = lot.house
			var center: Vector3 = house.center
			var size: Vector3 = house.size
			var x0: float = lot.x0
			var x1: float = lot.x1
			check(center.x - size.x * 0.5 >= x0 and center.x + size.x * 0.5 <= x1, "house fits its lot along the street (%.1f..%.1f)" % [x0, x1])
			check(absf(center.z) - size.z * 0.5 > front + 3.0, "house is set back from the footpath")
			check(absf(center.z) + size.z * 0.5 < front + StreetScript.LOT_DEPTH, "house is in front of the back fence")
			var drive: Dictionary = lot.driveway
			var drive_x: float = drive.x
			var drive_w: float = drive.width
			var apart := absf(drive_x - center.x) >= (drive_w + size.x) * 0.5
			check(apart, "driveway runs beside the house, not through it")
		for side in [-1, 1]:
			var last := -INF
			for lot: Dictionary in street.lots:
				if lot.side != side:
					continue
				check(float(lot.x0) >= last - 0.001, "lots on side %d do not overlap" % side)
				last = lot.x1
	if failures == 0:
		print("street_logic: all good")
	quit(1 if failures > 0 else 0)


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", what)
