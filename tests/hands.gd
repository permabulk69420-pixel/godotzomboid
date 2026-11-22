# Loads both VR hands on stand-in controllers (no headset needed) and poses them, to catch a broken hand model or script.
# Run with  godot --headless -s res://tests/hands.gd
extends SceneTree

var failures := 0


func _initialize() -> void:
	var left := XRController3D.new()
	var right := XRController3D.new()
	root.add_child(left)
	root.add_child(right)
	var hands := VrHands.new({"left": left, "right": right})
	check(hands.states.size() == 2, "both hands loaded (%d)" % hands.states.size())
	for s in hands.states:
		check(s.model.grip_bone >= 0, "%s hand has its grip bone" % s.handedness)
		check(s.model.clips.has("Grip") and s.model.clips.has("Fist") and s.model.clips.has("Open"), "%s hand has its poses" % s.handedness)
		check(s.anchor.get_parent() == s.controller, "%s hand is on its controller" % s.handedness)
		for finger in HandModel.FINGERS:
			check(not s.model.finger_bones[finger].is_empty(), "%s hand has %s bones" % [s.handedness, finger])
	hands.update(0.016)
	if failures == 0:
		print("hands: all good")
	quit(1 if failures > 0 else 0)


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", what)
