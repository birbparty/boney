# Render-Agnostic Boundary — boney adapter interface

> **Status:** Spec finalized. Types live in `src/dragonbones/boundary.nim`.
> Related: boney-82k (this issue), boney-nkp (naylib adapter), boney-ck0 (boxy adapter).

---

## Design goal

The boney core is render-agnostic: it parses DragonBones data and produces
**render-neutral draw commands** per frame. An adapter translates those commands
to a specific renderer (naylib/raylib, boxy, or any future backend).

The boundary between core and adapter is defined by two things:

1. An **opaque texture handle** (`TextureHandle`) — the core stores and emits
   these but never dereferences them; the adapter owns the backing storage.
2. **Draw commands** — one per visible slot per frame, describing what to draw
   and where in world space.

---

## Texture handles

```nim
type TextureHandle* = distinct uint32
```

The adapter calls a loader (e.g. `LoadTexture` for raylib, `boxy.addImage` for
boxy) and gets back a handle. It stores that handle in the `DisplayData` for
image and mesh slots at load time. The core reads the handle out of
`DisplayData` and copies it into each `DrawCommand` each frame. The adapter
reads the handle back at render time and uses it to look up the actual GPU
resource.

`TextureHandle(0)` is the null/invalid sentinel. The core must never emit a
`DrawCommand` with a null handle (validate at load time; skip or warn at
render time).

---

## Draw commands

Two draw command shapes are needed — one for quads (image slots) and one for
meshes. The adapter may support only quads (see console degradation below).

```nim
DrawQuad* = object     # image slot or mesh-degraded-to-quad
  texture*: TextureHandle
  srcRect*: Rect       # atlas sub-rectangle (pixels), used as UV source
  dstQuad*: array[4, Vec2]  # world-space corners, CCW: TL, BL, BR, TR
  color*: DbColor
  blendMode*: BlendMode

DrawMesh* = object     # deformable mesh slot (desktop-only)
  texture*: TextureHandle
  vertices*: seq[Vec2] # deformed world-space vertex positions (frame output)
  uvs*: seq[Vec2]      # atlas UV coordinates (static after parse)
  indices*: seq[uint16]
  color*: DbColor
  blendMode*: BlendMode

DrawCommandKind* = enum dcQuad, dcMesh

DrawCommand* = object
  zOrder*: int         # slot z-order (ascending = back to front)
  case kind*: DrawCommandKind
  of dcQuad: quad*: DrawQuad
  of dcMesh: mesh*: DrawMesh
```

The anim module populates a `seq[DrawCommand]` each frame, sorted by `zOrder`.
The adapter iterates this seq and issues GPU calls.

---

## Mesh degradation on console

`DrawTexturePro` (raylib/naylib) can draw a source rectangle to an arbitrary
destination quad — enough for image slots and skin-weighted quads.

For mesh slots, the 3DS and Vita raylib binding does **not** expose
`DrawMesh`/`rlVertex`. The chosen degradation policy:

| Platform | Mesh slot behavior |
|---|---|
| Desktop (naylib) | `DrawMesh` via `rlVertex` → full deformation |
| 3DS / Vita (`-d:ds3` / `-d:vita`) | `DrawTexturePro` to bounding quad → no per-vertex deformation |

The adapter is responsible for the `when defined(ds3) or defined(vita)` branch.
The core always emits a `dcMesh` command; the adapter decides whether to
render it as a mesh or degrade to a bounding quad.

**Why core always emits dcMesh and lets the adapter degrade:**
- Simpler core: no compile-time branching in the animation pipeline
- Future-proof: a console adapter with rlVertex support (or a custom mesh path)
  can opt in without touching core
- The degraded quad is computed from `DrawMesh.vertices` bounding box — no
  extra data required

---

## Loader interface (convenience)

The canonical loader signature accepted by all adapters:

```nim
proc loadArmature*(
  skeletonJson: string,          ## path to _ske.json
  atlasJson: string,             ## path to _tex.json
  loadTexture: proc(path: string): TextureHandle,
): DragonBonesData
```

`loadTexture` is an adapter-supplied callback. The core calls it once per atlas
entry, caches the handles in the relevant `DisplayData` records, and never
touches the texture again. On console, `path` is a ROM path (e.g.
`romfs:/textures/hero.png`); on desktop it may be a filesystem path. The
adapter is free to use a texture cache and deduplicate.

---

## What the core does NOT do

- Decode PNG/JPEG/other image formats
- Upload textures to the GPU
- Know about specific renderer resource handles (`Texture2D`, raylib `Image`,
  boxy image key)
- Draw anything — the core only produces `DrawCommand` values

---

## File surface

| File | Purpose |
|---|---|
| `src/dragonbones/boundary.nim` | `TextureHandle`, `DrawCommand`, `DrawQuad`, `DrawMesh` types |
| `src/dragonbones/adapters/naylib/naylib.nim` | naylib/raylib adapter (boney-nkp) |
| `src/dragonbones/adapters/boxy/boxy.nim` | boxy adapter (boney-ck0, desktop-only) |

`boundary.nim` imports only `vmath`, `bumpy`, and `dragonbones/model` — it is
part of the core and subject to the core purity check.
