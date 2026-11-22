# The game's material library: the tiling Poly Haven materials in assets/materials (albedo, normal, packed AO/roughness/metal),
# tiled at their real-world size, plus a few plain painted ones. Everything is multiplied by the mesh's vertex colours, which is
# where the baked shading lives (see tools/make_houses.py). One material per (kind, tint), shared by everything that uses it, since
# fewer materials means fewer draw calls on the Quest.
#
# All meshes that use these have UVs in metres (1 UV unit = 1 m along the surface), so a material's tile size alone sets its scale.
class_name Materials
extends RefCounted

const ROOT := "res://assets/materials/"
const TILE_OVERRIDE := {"siding": 2.6, "lawn": 3.5}   # siding: ~12 cm boards; lawn: larger so the repeat is less obvious

static var _info: Dictionary = {}
static var _cache: Dictionary = {}


static func _load_info() -> void:
	if not _info.is_empty():
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "materials.json"))
	if parsed is Dictionary:
		_info = parsed
	else:
		push_error("Materials: could not read materials.json")


static func has_texture(kind: String) -> bool:
	_load_info()
	return _info.has(kind)


# A textured material, tinted (white = the photo's own colour).
static func textured(kind: String, tint: Color = Color.WHITE) -> StandardMaterial3D:
	var key := "%s/%s" % [kind, tint.to_html()]
	if _cache.has(key):
		return _cache[key]
	_load_info()
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.vertex_color_use_as_albedo = true
	m.albedo_color = tint
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if _info.has(kind):
		var size: Array = _info[kind]["size_m"]
		var tile_x: float = TILE_OVERRIDE.get(kind, float(size[0]))
		var tile_y: float = TILE_OVERRIDE.get(kind, float(size[1]))
		m.uv1_scale = Vector3(1.0 / tile_x, 1.0 / tile_y, 1.0)
		m.albedo_texture = load(ROOT + kind + "/albedo.jpg")
		m.normal_enabled = true
		m.normal_texture = load(ROOT + kind + "/normal.jpg")
		m.roughness_texture = load(ROOT + kind + "/orm.jpg")
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		m.roughness = 1.0
	else:
		push_warning("Materials: no textures for '%s'" % kind)
	_cache[key] = m
	return m


# A plain painted or plastic surface: one colour, still shaded by the baked vertex colours.
static func plain(colour: Color, roughness: float = 0.7, double_sided: bool = false) -> StandardMaterial3D:
	var key := "plain/%s/%.2f/%s" % [colour.to_html(), roughness, double_sided]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.vertex_color_use_as_albedo = true
	m.albedo_color = colour
	m.roughness = roughness
	if double_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cache[key] = m
	return m


static func glass() -> StandardMaterial3D:
	if _cache.has("glass"):
		return _cache["glass"]
	var m := StandardMaterial3D.new()
	m.resource_name = "glass"
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.10, 0.13, 0.15, 0.45)
	m.roughness = 0.05
	m.metallic_specular = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cache["glass"] = m
	return m


# The material for one surface of a house, by the name it was given in Blender, for a house dressed in `style`
# ({wall, wall_tint, roof_tint, trim, inside}).
static func for_house_surface(surface: String, style: Dictionary) -> Material:
	match surface:
		"ext_wall":
			return textured(style.wall, style.wall_tint)
		"roof":
			return textured("shingles", style.roof_tint)
		"trim":
			return plain(style.trim, 0.6)
		"glass":
			return glass()
		"int_wall":
			return textured("plaster", style.inside)
		"ceiling":
			return textured("plaster", Color(0.95, 0.95, 0.93))
		"floor_wood":
			return textured("wood_floor")
		"floor_tiles":
			return textured("tiles")
		"porch":
			return textured("footpath")
		"garage_door":
			return plain(style.trim.darkened(0.05), 0.5)
		"door":
			return plain(style.door, 0.5, true)
		"fabric":
			return plain(style.fabric, 0.95)
		"furn_wood":
			return textured("wood_floor", Color(0.62, 0.48, 0.38))
		"appliance":
			return plain(Color(0.88, 0.88, 0.86), 0.3)
		"counter":
			return plain(Color(0.55, 0.53, 0.50), 0.4)
	push_warning("Materials: unknown house surface '%s'" % surface)
	return plain(Color.MAGENTA)
