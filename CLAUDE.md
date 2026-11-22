# Godot Zomboid — notes for Claude

## What this is
A Project Zomboid–style survival game for **Meta Quest 3**, played in VR first person, made in **Godot 4.7** (GL Compatibility
renderer). Setting: a suburban town some years after an outbreak, overgrown (I Am Legend feel). Quiet, beautiful days; frightening
nights. Every house should eventually be enterable and lootable.

Kane cares a lot about it **looking beautiful on the Quest 3**. Beauty comes from art direction, lighting, fog, colour and
consistency, not raw polygon counts. A locked frame rate counts as part of looking good.

## How we work
- Kane has **no PC**. Pipeline: Claude writes code and assets → push to `main` → GitHub Actions builds the APK
  (`.github/workflows/build-quest.yml`) → it is published on the `quest-latest` release → Kane installs it and reports back.
  Batch several changes per build and tell Kane exactly what to look at in each one.
- Claude's workspace has no GPU, so Godot's own lightmap baker can't be used. Instead `tools/make_houses.py` bakes shading with
  Blender (`pip install bpy`, Cycles on CPU) into **vertex colours** (near AO x sky visibility), which every material multiplies in.
  Surfaces are gridded (~0.35 m) so the shading has vertices to live on. Check results by rendering previews in Blender
  (`--preview` writes /tmp/house_<n>.png) and reading the images.
- Godot binaries can't be downloaded in Claude's workspace (GitHub release assets are blocked), so Godot only runs in CI.
  Check results with `gh run list` / `gh run view --log-failed`.
- Scenes are built in code (like Kane's other Quest projects); `scenes/main.tscn` only holds `scripts/main.gd`.
- Logic tests live in `tests/*.gd` and run in CI before the export (`godot --headless -s res://tests/<name>.gd`, exit code 1 on failure).
- No README files.

## Design decisions so far
- **Town generation:** seed → plain data (`layout()`) → meshes (`build()`). Hand edits will go in a separate override layer on top of the
  generated data, so regenerating never loses them.
- **Modular kits**, not unique whole houses: matching pieces with consistent scale, texel density and materials.
  AI-made or unique models only for landmarks.
- **Props by rules** (bins at driveways, lamps along footpaths, room-based loot later).
- **Streaming in chunks** from the start once the town grows past one street; repeated props via MultiMesh, shared materials.
- **Open question: day/night vs baked lighting.** Options: real-time sun + baked AO only; blend a few baked lighting states;
  or fixed time per area or session. Test before committing.
- **Overgrowth is expensive** (alpha overdraw on Quest): use mostly mesh foliage and vines, and grass cards only where the player looks.

## Assets
- **Materials:** `tools/fetch_materials.py` downloads CC0 Poly Haven materials (2K: albedo, normal, packed AO/rough/metal) into
  `assets/materials/<name>/` with real-world sizes in `materials.json`. `scripts/materials.gd` builds shared Godot materials from them.
  All meshes use **UVs in metres**, so a material's tile size alone sets its scale. 2K for things seen up close, 1K for small/far.
- **Houses:** `tools/make_houses.py` generates 8 single-storey, fully enterable house variants (living, hall, kitchen, 2 bedrooms,
  bath, furniture blocks, optional garage/porch, side- or front-gabled, mirrored) as `assets/houses/house_<n>.glb` +
  `houses.json`. Objects: exterior, interior (hidden beyond ~32 m), glass, collision_solid (layer 1), collision_walk (layer 2).
  The street picks a variant per lot and dresses it (siding/brick/stucco, colours) via `Materials.for_house_surface()`.
- Look: generic American suburb (GTA-like): siding, brick, stucco, shingle roofs, garages to the street, open lawns.

## Current state
- `scripts/street.gd`: one 150 m street, textured road/kerbs/verges/footpaths/lawns (merged into one mesh per material),
  ~12+ generated houses with driveways, door paths, fences, bins, street lamps. Golden-hour sky, sun and fog in `scripts/main.gd`.
- Player: left stick walks, right turns; the body slides along solid things and its height follows the walkable layer (steps, porches).
- Next: tune look and performance from Kane's feedback; two-storey variants with stairs; overgrowth/foliage test; day/night decision.
