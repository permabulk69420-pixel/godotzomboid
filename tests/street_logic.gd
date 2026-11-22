# Checks the street layout without a headset: run with  godot --headless -s res://tests/street_logic.gd
# The same seed must give the same street, lots must not overlap, houses must sit inside their lots, set back from the footpath,
# and every driveway must stay clear of the house (or lead straight to its garage).
extends SceneTree

const StreetScript := preload("res://scripts/street.gd")

var failures := 0


func _init() -> void:
	var variants: Array = StreetScript.load_variants()
	check(variants.size() >= 6, "the house variants were loaded (%d)" % variants.size())
	for v: Dictionary in variants:
		check(ResourceLoader.exists("res://assets/houses/" + String(v.file)), "house %s exists" % v.file)
	var a: Dictionary = StreetScript.layout(1, variants)
	var b: Dictionary = StreetScript.layout(1, variants)
	var c: Dictionary = StreetScript.layout(2, variants)
	check(var_to_str(a) == var_to_str(b), "same seed gives the same street")
	check(var_to_str(a) != var_to_str(c), "a different seed gives a different street")
	var front: float = StreetScript.ROAD_HALF + StreetScript.PATH_WIDTH
	for street: Dictionary in [a, c]:
		check(street.lots.size() >= 8, "seed %d has at least 8 lots (got %d)" % [street.seed, street.lots.size()])
		check(street.lamps.size() >= 3, "seed %d has street lamps" % street.seed)
		for lot: Dictionary in street.lots:
			var variant: Dictionary = variants[int(lot.variant)]
			var house: Dictionary = lot.house
			var x0: float = lot.x0
			var x1: float = lot.x1
			check(float(house.x_min) >= x0 + 2.0 and float(house.x_max) <= x1 - 2.0, "house fits its lot (%.1f..%.1f in %.1f..%.1f)" % [house.x_min, house.x_max, x0, x1])
			var wall_front := absf(float(house.z))
			check(wall_front + float(variant.front_y) > front + 3.0, "house (and porch) set back from the footpath")
			check(wall_front + float(variant.back_y) < front + StreetScript.LOT_DEPTH - 2.0, "house is in front of the back fence")
			var drive: Dictionary = lot.driveway
			var d0: float = float(drive.x) - float(drive.width) * 0.5
			var d1: float = float(drive.x) + float(drive.width) * 0.5
			check(d0 >= x0 and d1 <= x1, "driveway is inside the lot")
			if variant.garage == null:
				var clear: bool = d0 >= float(house.x_max) or d1 <= float(house.x_min)
				check(clear, "driveway runs beside the house, not through it")
			else:
				check(is_equal_approx(float(drive.length), wall_front - front + float(variant.garage.front_y)), "driveway reaches the garage door")
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
