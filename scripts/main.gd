# The test street: you stand at one end of a generated suburban street at golden hour and can walk around it, and into any house.
# In a headset (OpenXR, Quest) you have hands on the controllers; the left stick walks (click it in to sprint, until you let the stick
# go) and the right stick turns. A performance readout sits on your left wrist like a watch; click both sticks to hide or show it.
# On a flat screen the camera stands where you would: WASD walks (Shift sprints), Q/E or the arrow keys turn.
extends Node3D

const REFRESH_RATE := 72.0          # SpaceWarp needs a display rate it can evenly halve (72 Hz display / 36 fps render)
const RENDER_SCALE := 1.0           # headset render resolution as a multiple of the Quest's recommended size, per eye
const MOVE_SPEED := 1.6             # m/s walking
const SPRINT_SPEED := 3.6           # m/s sprinting
const TURN_SPEED := deg_to_rad(110.0)
const STICK_DEADZONE := 0.2
const BODY_RADIUS := 0.28           # your body, for bumping into houses, fences and bins
const BODY_HEIGHT := 1.6
const BODY_LIFT := 0.3              # it floats this far off the floor, so kerbs, steps and porches do not stop you
const STEP_REACH := 0.45            # how far above your feet the floor is looked for (just over a step)
const STEP_DROP := 0.8              # and how far below
const EYE_HEIGHT := 1.62            # flat-screen camera height
const STREET_SEED := 1
const FOG_OUTSIDE := 0.004          # fog density outdoors; it fades to nothing when you are inside a house (it hazed the rooms)
const START := Vector3(-70.0, 0.0, 1.5)    # the west end of the street, on the road, facing east along it

var vr := false
var rig: Node3D
var camera: Camera3D
var left_controller: XRController3D
var right_controller: XRController3D
var body: CharacterBody3D
var street: Street
var space_warp: Object = null       # OpenXRFbSpaceWarpExtension singleton, if the runtime and build support it
var overlay: Label3D
var overlay_timer := 0.0
var overlay_combo_held := false
var hands: VrHands
var sprinting := false
var sprint_click_held := false
var sprint_moved := false
var occlusion_button_held := false
var environment: Environment
var indoors := false


func _ready() -> void:
	vr = _start_xr()
	_build_environment()
	street = Street.new(STREET_SEED)
	street.name = "Street"
	add_child(street)

	if vr:
		rig = XROrigin3D.new()
		camera = XRCamera3D.new()
		left_controller = _make_controller(&"left_hand")
		right_controller = _make_controller(&"right_hand")
		rig.add_child(left_controller)
		rig.add_child(right_controller)
	else:
		rig = Node3D.new()
		camera = Camera3D.new()
		camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	rig.name = "Rig"
	rig.position = START
	rig.rotation.y = -PI * 0.5
	add_child(rig)
	camera.name = "Camera"
	camera.fov = 72.0
	camera.near = 0.05
	camera.far = 400.0
	camera.current = true
	rig.add_child(camera)
	if vr:
		hands = VrHands.new({"left": left_controller, "right": right_controller})
	overlay = _make_overlay()
	if vr:
		# on the left wrist, facing up off the back of the hand, like a watch
		overlay.position = Vector3(0.0, 0.03, 0.11)
		overlay.rotation = Vector3(deg_to_rad(-70.0), 0.0, 0.0)
		left_controller.add_child(overlay)
	else:
		overlay.position = Vector3(-0.35, 0.2, -0.7)
		camera.add_child(overlay)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	# your body: a capsule that only looks at solid things and is moved by hand in _slide()
	body = CharacterBody3D.new()
	body.name = "Body"
	body.collision_layer = 0
	body.collision_mask = Street.SOLID_LAYER
	body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HEIGHT
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	body.add_child(shape)
	add_child(body)

	if vr and Engine.has_singleton("OpenXRFbSpaceWarpExtension"):
		# Application SpaceWarp: the runtime renders real frames at half rate and fills in the rest. It needs the play space to hold
		# still between frames, so locomote() tells it to skip a frame whenever you walk or turn.
		space_warp = Engine.get_singleton("OpenXRFbSpaceWarpExtension")
		if space_warp.has_method("set_space_warp_enabled"):
			space_warp.set_space_warp_enabled(true)
		else:
			space_warp = null
	print("Godot Zomboid ready%s" % (" · headset" if vr else ""))


func _process(delta: float) -> void:
	var dt := minf(delta, 0.05)
	var move := Vector2.ZERO
	var turn := 0.0
	if vr:
		var both_sticks_clicked := left_controller.is_button_pressed("primary_click") and right_controller.is_button_pressed("primary_click")
		if both_sticks_clicked and not overlay_combo_held:
			overlay.visible = not overlay.visible
		overlay_combo_held = both_sticks_clicked
		move = stick_value(left_controller.get_vector2("primary"))
		turn = stick_value(right_controller.get_vector2("primary")).x
		# sprint: click the left stick in; it lasts until you let the stick go back to the middle
		var clicked := left_controller.is_button_pressed("primary_click")
		if clicked and not sprint_click_held and not both_sticks_clicked:
			sprinting = true
			sprint_moved = false
		sprint_click_held = clicked
		if move.length() > 0.3:
			sprint_moved = true
		elif move.length() < 0.1 and sprint_moved:
			sprinting = false                 # the stick came back to the middle after running
		hands.update(dt)
		# B (right controller) switches occlusion culling on and off, to compare on the wrist readout
		var b := right_controller.is_button_pressed("by_button")
		if b and not occlusion_button_held:
			get_viewport().use_occlusion_culling = not get_viewport().use_occlusion_culling
		occlusion_button_held = b
	else:
		move = Vector2(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
		turn = float(Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_LEFT))
		sprinting = Input.is_key_pressed(KEY_SHIFT)
	locomote(move, turn, dt)
	var fog_target := 0.0 if indoors else FOG_OUTSIDE
	environment.fog_density = move_toward(environment.fog_density, fog_target, FOG_OUTSIDE * dt * 1.5)
	overlay_timer -= delta
	if overlay.visible and overlay_timer <= 0.0:
		overlay_timer = 0.5
		overlay.text = _overlay_text()


# A thumbstick reading with its dead zone taken out (so it rests at exactly zero and ramps up from there).
static func stick_value(raw: Vector2) -> Vector2:
	var length := raw.length()
	if length < STICK_DEADZONE:
		return Vector2.ZERO
	return raw / length * minf(1.0, (length - STICK_DEADZONE) / (1.0 - STICK_DEADZONE))


# Walk (move.y forward, move.x right, relative to where you are looking) and turn (+ is right). Turning pivots on your head.
func locomote(move: Vector2, turn: float, dt: float) -> void:
	if absf(turn) > 0.001 or move.length() > 0.001:
		_skip_space_warp_frame()
	if absf(turn) > 0.001:
		var angle := -turn * TURN_SPEED * dt
		var pivot := camera.global_position
		rig.global_position = pivot + (rig.global_position - pivot).rotated(Vector3.UP, angle)
		rig.rotate_y(angle)
	if move.length() > 0.001:
		var forward := -camera.global_basis.z
		forward.y = 0.0
		var right := camera.global_basis.x
		right.y = 0.0
		var heading := (forward.normalized() * move.y + right.normalized() * move.x) if forward.length() > 0.01 else Vector3.ZERO
		rig.global_position += _slide(heading * (SPRINT_SPEED if sprinting else MOVE_SPEED) * dt)
	_follow_ground(dt)


# Your height follows whatever floor is under your head: the road, footpaths, porches and house floors (the walkable layer).
func _follow_ground(dt: float) -> void:
	var from := Vector3(camera.global_position.x, rig.global_position.y + STEP_REACH, camera.global_position.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, -(STEP_REACH + STEP_DROP), 0.0), Street.WALK_LAYER)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	indoors = hit.collider is Node and (hit.collider as Node).is_in_group("house_floor")
	var ground: float = hit.position.y
	if absf(ground - rig.global_position.y) > 0.0005:
		rig.global_position.y = lerpf(rig.global_position.y, ground, 1.0 - exp(-14.0 * dt))


# Moves your body through the street's solid things and returns how far it really got, sliding along walls instead of sticking.
func _slide(motion: Vector3) -> Vector3:
	body.global_position = Vector3(camera.global_position.x, rig.global_position.y + BODY_LIFT + BODY_HEIGHT * 0.5, camera.global_position.z)
	var start := body.global_position
	for i in 3:
		var hit := body.move_and_collide(motion)
		if hit == null:
			break
		motion = hit.get_remainder().slide(hit.get_normal())
		motion.y = 0.0
		if motion.length() < 0.0005:
			break
	return body.global_position - start


func _skip_space_warp_frame() -> void:
	if space_warp != null and space_warp.has_method("skip_space_warp_frame"):
		space_warp.skip_space_warp_frame()


# ---- light and air ----------------------------------------------------------------------------------------------------------------

# Golden hour: a low warm sun, a soft sky, and a warm haze that swallows the far end of the street.
func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.30, 0.47, 0.72)
	sky_material.sky_horizon_color = Color(0.86, 0.78, 0.68)
	sky_material.ground_horizon_color = Color(0.60, 0.56, 0.50)
	sky_material.ground_bottom_color = Color(0.30, 0.28, 0.25)
	sky_material.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# ambient light: half from the sky, half a neutral warm grey. Pure sky light tints surfaces by which way they face (floors blue
	# from the sky above, ceilings brown from the ground below), which looked wrong indoors.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.5
	env.ambient_light_color = Color(0.78, 0.76, 0.72)
	env.ambient_light_energy = 1.0
	# no sky reflections: indoors they turned every floor blue (nothing tells the renderer the sky is hidden), and they cost on the Quest
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.82, 0.76, 0.68)
	env.fog_density = FOG_OUTSIDE
	env.fog_sky_affect = 0.1
	environment = env
	var world := WorldEnvironment.new()
	world.name = "Environment"
	world.environment = env
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.86, 0.70)
	sun.light_energy = 1.3
	sun.rotation_degrees = Vector3(-14.0, -120.0, 0.0)   # low in the sky, behind you and to the side as you look down the street
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(sun)


# ---- headset ----------------------------------------------------------------------------------------------------------------------

static func _make_overlay() -> Label3D:
	var label := Label3D.new()
	label.name = "Overlay"
	label.pixel_size = 0.0002
	label.font_size = 30
	label.outline_size = 10
	label.no_depth_test = true
	label.render_priority = 10
	label.modulate = Color(0.75, 1.0, 0.75)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.double_sided = false
	return label


var _fps_history: Array[float] = []


func _overlay_text() -> String:
	var lines: PackedStringArray = []
	var fps := Engine.get_frames_per_second()
	_fps_history.append(fps)
	if _fps_history.size() > 20:                  # the last 10 seconds (it updates twice a second)
		_fps_history.pop_front()
	lines.append("FPS %d   (low %d over 10 s)" % [fps, _fps_history.min()])
	var xr := XRServer.find_interface("OpenXR")
	if vr and xr != null and xr.is_initialized():
		var warp := "on" if space_warp != null else "off"
		lines.append("Display %.0f Hz   SpaceWarp %s" % [float(xr.get("display_refresh_rate")), warp])
		var eye := xr.get_render_target_size()
		lines.append("Eye %d x %d   foveation %d" % [eye.x, eye.y, int(xr.get("foveation_level"))])
	var rid := get_viewport().get_viewport_rid()
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	lines.append("CPU %.1f ms  GPU %.1f ms  game %.1f ms" % [cpu, gpu, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	lines.append("Draw calls %d   objects %d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
	lines.append("Triangles %dk   occlusion %s (B)" % [int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000),
		"on" if get_viewport().use_occlusion_culling else "off"])
	lines.append("%s%s  at %.0f, %.0f" % ["indoors" if indoors else "outdoors", "  sprint" if sprinting else "", rig.global_position.x, rig.global_position.z])
	return "\n".join(lines)


# Starts OpenXR if there is a headset to talk to. Returns false (and plays on a flat screen) if there is not.
func _start_xr() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null:
		return false
	if not xr.is_initialized() and not xr.initialize():
		return false
	get_viewport().use_xr = true
	xr.set("render_target_size_multiplier", RENDER_SCALE)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # the headset sets the pace
	if xr.has_method("get_available_display_refresh_rates"):
		var rates = xr.call("get_available_display_refresh_rates")
		if rates is Array and REFRESH_RATE in rates:
			xr.set("display_refresh_rate", REFRESH_RATE)
	return true


static func _make_controller(tracker: StringName) -> XRController3D:
	var controller := XRController3D.new()
	controller.tracker = tracker
	controller.pose = &"grip"
	controller.name = String(tracker)
	return controller
