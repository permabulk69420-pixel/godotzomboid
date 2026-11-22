# The VR hands (brought over from Kane's Humansandbox project): a skinned hand model on each controller, posed from how far the
# trigger and grip are squeezed. Grip curls the hand, trigger pinches, both make a fist.
class_name VrHands
extends RefCounted

const GRIP_ROTATION := {"left": PI / 2.0, "right": -PI / 2.0}   # the hand meshes are authored with fingers along -Z and palms along -Y
const HAND_PITCH := deg_to_rad(-45.0)                             # the hand is lowered this much (about the controller's X axis), so a level grip takes a level wrist
const DEADZONE := 0.08


class HandState:
	var handedness := ""
	var controller: XRController3D
	var anchor: Node3D              # the hand model's own offset on the controller
	var model: HandModel
	var pointing := false           # the hand points instead of following the trigger and grip

	func squeeze() -> float:
		return controller.get_float("grip")

	func trigger() -> float:
		return controller.get_float("trigger")


var states: Array[HandState] = []


# Puts a hand on each controller that exists (controllers: { "left": node, "right": node }).
func _init(controllers: Dictionary) -> void:
	for handedness in ["left", "right"]:
		var controller: XRController3D = controllers.get(handedness)
		if controller == null:
			continue
		var model := HandModel.create(handedness)
		if model == null:
			push_warning("VrHands: no hand model for " + handedness)
			continue
		var s := HandState.new()
		s.handedness = handedness
		s.controller = controller
		s.model = model
		s.anchor = Node3D.new()
		s.anchor.name = "%s-hand" % handedness
		s.anchor.basis = Basis(Vector3.RIGHT, HAND_PITCH) * Basis(Vector3.BACK, GRIP_ROTATION[handedness])
		# The controller's grip pose is where a held thing sits in the palm: put the hand model's own grip socket there (the mesh origin
		# is at the wrist, about 7 cm behind it).
		s.anchor.position = -(s.anchor.basis * model.skeleton.get_bone_global_rest(model.grip_bone).origin)
		s.anchor.add_child(model.root)
		controller.add_child(s.anchor)
		states.append(s)


func update(_dt: float) -> void:
	for s in states:
		var trigger := s.trigger()
		var squeeze := s.squeeze()
		if s.pointing:
			s.model.set_pose("Point", 1.0)
		elif squeeze > DEADZONE and trigger > DEADZONE:
			s.model.set_pose("Fist", maxf(trigger, squeeze))
		elif squeeze > DEADZONE:
			s.model.set_pose("Grip", squeeze)
		elif trigger > DEADZONE:
			s.model.set_pose("Pinch", trigger)
		else:
			s.model.set_pose("Open", 0.0)
