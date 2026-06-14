# naylib Adapter Integration Guide

`src/dragonbones/adapters/naylib/adapter.nim`

---

## What it does

Translates `seq[DrawCommand]` produced by `emitDrawCommands` into raylib draw calls via the naylib Nim binding.

**Desktop path** (default): Uses `rlBegin` / `vertex2f` / `texCoord2f` for per-vertex rendering. Supports arbitrary quad skew and full mesh deformation.

**Console path** (`-d:ds3` or `-d:vita`): Uses `DrawTexturePro`. Image slots render correctly when non-skewed. Mesh slots and skewed quads degrade to an axis-aligned bounding box.

---

## Setup

```nim
import tables
import raylib, rlgl, vmath
import dragonbones/boundary
import dragonbones/model/model
import dragonbones/adapters/naylib/adapter

## Load texture however your app manages assets
let tex       = loadTexture("my_atlas.png")
let atlasHnd  = TextureHandle(1)   ## non-zero uint32 you choose
let texTable  = {atlasHnd: tex}.toTable

proc lookupTex(h: TextureHandle): Texture2D =
  texTable.getOrDefault(h)
```

The lookup proc is the only adapter-specific coupling. You can map multiple atlases by returning different `Texture2D` values per handle.

---

## Per-frame call

```nim
renderDrawCommands(drawCmds, lookupTex)
```

Place this inside `beginDrawing()` / `endDrawing()`. Use rlgl push/pop matrix to apply world-space offsets:

```nim
pushMatrix()
translatef(originX, originY, 0)
renderDrawCommands(drawCmds, lookupTex)
popMatrix()
```

---

## Blend mode mapping

| `model.BlendMode` | raylib `BlendMode` |
|---|---|
| bmNormal, bmAlpha | Alpha |
| bmAdd | Additive |
| bmMultiply | Multiplied |
| bmScreen | AddColors |
| all others | Alpha (fallback) |

---

## Console limitations

- **Mesh slots**: degrade to bounding-box `DrawTexturePro`. Mesh deformation is not reproduced.
- **Skewed image slots**: degrade to AABB. Parallelogram shapes render as rectangles.
- **Atlas-rotated sprites**: naylib's `DrawTexturePro` cannot compose a 90° sprite rotation with a world-space rotation in the same call on console. Export atlases with rotation disabled for console targets.

---

## Multiple armatures

Each armature call is independent. Emit draw commands for each armature separately and render in the order you want:

```nim
emitDrawCommands(armA, ..., drawCmdsA, ...)
emitDrawCommands(armB, ..., drawCmdsB, ...)
renderDrawCommands(drawCmdsA, lookupTex)
renderDrawCommands(drawCmdsB, lookupTex)
```
