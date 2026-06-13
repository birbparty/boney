# Render-Agnostic Boundary — boney adapter interface

> **Status:** Spec finalized. Types live in `src/dragonbones/boundary.nim`.
> Related: boney-82k (this issue), boney-nkp (naylib adapter), boney-ck0 (boxy adapter).
> Atlas binding (resolving texture names to handles) is specified in boney-080.

---

## Design goal

The boney core is render-agnostic: it parses DragonBones data and produces
**render-neutral draw commands** per frame. An adapter translates those commands
to a specific renderer (naylib/raylib, boxy, or any future backend).

The boundary between core and adapter is defined by two things:

1. An **opaque texture handle** (`TextureHandle`) — the adapter issues these at
   load time; the core never dereferences them.
2. **Draw commands** — one per visible slot per frame, describing what to draw
   and where in world space.

---

## Texture handle lifecycle

```nim
type TextureHandle* = distinct uint32  # in src/dragonbones/boundary.nim

const NullTextureHandle* = TextureHandle(0)
proc isValid*(h: TextureHandle): bool = h != NullTextureHandle
proc `==`*(a, b: TextureHandle): bool {.borrow.}
```

`TextureHandle` does **not** live in the DragonBones model types (`DragonBonesData`,
`DisplayData`, etc.). The model is shared across all instances and all adapters;
baking one adapter's GPU handles into it would break that contract.

Instead, handles live in an **atlas binding** (specified by boney-080), a
per-load structure that maps atlas sub-texture names to `(TextureHandle, Rect)`.
When the animation system emits a draw command, it resolves the handle from the
atlas binding using the `DisplayData.name` field, then copies it into the
`DrawCommand`. The adapter provides the binding when creating an armature
instance — it is not stored in `DragonBonesData`.

`TextureHandle(0)` / `NullTextureHandle` is the invalid sentinel. The core must
skip any slot whose resolved handle is not valid.

---

## Draw commands

Two draw command shapes are needed: quads for image slots and meshes for mesh slots.

```nim
DrawQuad* = object
  texture*: TextureHandle
  srcRect*: Rect               # atlas sub-rectangle in PIXELS
  dstQuad*: array[4, Vec2]     # world-space corners, CCW: TL, BL, BR, TR
  color*: DbColor
  blendMode*: BlendMode

DrawMesh* = object
  texture*: TextureHandle
  vertices*: seq[Vec2]         # deformed world-space vertex positions
  uvs*: seq[Vec2]              # atlas UV coords, NORMALIZED 0–1 (NOT pixels)
  indices*: seq[uint16]
  color*: DbColor
  blendMode*: BlendMode

DrawCommandKind* = enum dcQuad, dcMesh

DrawCommand* = object
  zOrder*: int                 # ascending = back to front
  case kind*: DrawCommandKind
  of dcQuad: quad*: DrawQuad
  of dcMesh: mesh*: DrawMesh
```

> **UV unit asymmetry**: `DrawQuad.srcRect` is in atlas PIXELS (input to
> `DrawTexturePro`'s source rect). `DrawMesh.uvs` are normalized 0–1 (input to
> vertex shaders / `rlVertex` UV). Adapters must not double-normalize either.

The anim module populates a `seq[DrawCommand]` each frame, sorted by `zOrder`.

---

## Console degradation policy

### What `DrawTexturePro` actually supports

`DrawTexturePro(texture, source, dest, origin, rotation, tint)` draws a source
**rectangle** to a destination **rectangle** with a rotation and origin offset.
It does NOT support an arbitrary 4-corner quad — for that you need `rlVertex`.

Implications:
- **Mesh slots**: always need `rlVertex` for per-vertex deformation. The core
  always emits `dcMesh`; the adapter chooses whether to use `rlVertex` or degrade.
- **Skewed image slots** (`skX ≠ skY` in the bone/slot transform): the true
  world-space shape is a parallelogram, not a rectangle. Rendering requires
  `rlVertex` for correct output.

On 3DS and Vita, the naylib binding exposes `DrawTexturePro` but not `rlVertex`
in its initial form. The chosen degradation policy:

| Slot type | Desktop (naylib) | 3DS / Vita (`-d:ds3` / `-d:vita`) |
|---|---|---|
| Image (non-skewed) | `DrawTexturePro` — correct ✅ | `DrawTexturePro` — correct ✅ |
| Image (skewed) | `rlVertex` for exact quad | AABB approx → visible skew error ⚠️ |
| Mesh | `rlVertex` → full deformation | AABB approx → bounding quad ⚠️ |

The adapter computes the AABB from `DrawMesh.vertices` (or `DrawQuad.dstQuad`)
for the console degradation path. Both degraded cases use the same mechanism:
convert 4 world-space corners to an axis-aligned bounding rect, then call
`DrawTexturePro`. Rotated (non-skewed) slots remain pixel-exact.

### Why core always emits dcMesh

- Simpler core: no compile-time branching in the animation pipeline
- Future-proof: a console adapter with `rlVertex` support opts in without
  touching core
- The bounding-quad approximation requires no extra data from the core

---

## Loader interface (adapter-layer, not core)

The `loadArmature` convenience function lives in each adapter package (not in
`src/dragonbones/`), because loading requires renderer-specific calls. The
typical signature:

```nim
# In the adapter package (e.g. naylib adapter)
proc loadArmature*(
  skeletonJson: string,           ## path to _ske.json
  atlasJson: string,              ## path to _tex.json
  loadTexture: proc(path: string): TextureHandle,
): tuple[data: DragonBonesData, atlas: AtlasBinding]
```

`DragonBonesData` is returned unmodified (no handles stored in it). The atlas
binding (defined in boney-080) is a separate per-load structure that maps
sub-texture names to `(TextureHandle, Rect)`. Multiple adapters can load the
same `DragonBonesData` independently, each with their own `AtlasBinding`.

---

## What the core does NOT do

- Decode PNG/JPEG/other image formats
- Upload textures to the GPU
- Store `TextureHandle` values inside `DragonBonesData` or `DisplayData`
- Draw anything — the core only produces `DrawCommand` values

---

## File surface

| File | Purpose |
|---|---|
| `src/dragonbones/boundary.nim` | `TextureHandle`, `DrawCommand`, `DrawQuad`, `DrawMesh` types |
| `src/dragonbones/adapters/naylib/naylib.nim` | naylib/raylib adapter (boney-nkp) |
| `src/dragonbones/adapters/boxy/boxy.nim` | boxy adapter (boney-ck0, desktop-only) |

`boundary.nim` imports only `vmath`, `bumpy`, and `dragonbones/model` — it is
part of the core and **is** subject to the core purity check (scanned by
`tests/test_core_purity.nim` via the flat-file walk added in this iteration).
