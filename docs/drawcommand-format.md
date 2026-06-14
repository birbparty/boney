# DrawCommand Format Reference

Produced by `emitDrawCommands` in `src/dragonbones/anim/emit.nim`. Types defined in `src/dragonbones/boundary.nim`.

---

## TextureHandle

```nim
type TextureHandle* = distinct uint32
const NullTextureHandle* = TextureHandle(0)
proc isValid*(h: TextureHandle): bool = h != NullTextureHandle
```

Opaque GPU-resource identifier. The core never dereferences it — the adapter issues handles at load time and resolves them at render time via a lookup proc.

---

## DrawCommand

```nim
DrawCommandKind* = enum dcQuad, dcMesh

DrawCommand* = object
  zOrder*: int
  case kind*: DrawCommandKind
  of dcQuad: quad*: DrawQuad
  of dcMesh: mesh*: DrawMesh
```

Commands are emitted back-to-front (ascending `zOrder`). Render them in the order given; do not sort.

---

## DrawQuad

For image slots (non-mesh displays).

```nim
DrawQuad* = object
  texture*:      TextureHandle
  srcRect*:      Rect               ## atlas sub-rect in PIXELS
  uvQuad*:       array[4, Vec2]     ## normalized UVs, corner order TL/TR/BR/BL
  dstQuad*:      array[4, Vec2]     ## world-space corners, same order
  atlasRotated*: bool               ## sprite stored 90° CW in atlas
  color*:        DbColor
  blendMode*:    BlendMode
```

### Corner order

Index 0 = TL, 1 = TR, 2 = BR, 3 = BL (clockwise).

### srcRect vs uvQuad

| Field | Unit | Use for |
|---|---|---|
| `srcRect` | Atlas pixels | `DrawTexturePro` source rectangle (console path) |
| `uvQuad` | Normalized 0–1 | `texCoord2f` / vertex shader UVs (desktop rlVertex path) |

`uvQuad` already accounts for atlas sprite rotation (`atlasRotated`). The console path using `DrawTexturePro` must add 90° to the destination rotation when `atlasRotated` is true.

---

## DrawMesh

For deformable mesh slots.

```nim
DrawMesh* = object
  texture*:   TextureHandle
  vertices*:  seq[Vec2]     ## deformed world-space positions
  uvs*:       seq[Vec2]     ## normalized 0–1 (NOT pixels)
  indices*:   seq[uint16]   ## triangle list; each triplet is one triangle
  color*:     DbColor
  blendMode*: BlendMode
```

`vertices[i]` and `uvs[i]` are parallel arrays. Indices reference both.

---

## DbColor

```nim
DbColor* = object
  rM*, gM*, bM*, aM*: float32   ## multiplier, 0–1 (identity = 1)
  rO*, gO*, bO*, aO*: float32   ## additive offset, −255..255 (identity = 0)
```

**Final channel formula**: `clamp(M + O/255, 0, 1)`

Identity color: `DbColor(rM:1, gM:1, bM:1, aM:1)` — all offsets zero.

---

## BlendMode

```nim
BlendMode* = enum
  bmNormal, bmAdd, bmAlpha, bmErase, bmDarken, bmMultiply,
  bmLighten, bmScreen, bmOverlay, bmHardLight, bmDodge, bmBurn
```

See the adapter guides for renderer-specific mapping.

---

## Adapter contract

An adapter receives `seq[DrawCommand]` and a lookup proc:

```nim
proc renderDrawCommands*(
  cmds:   seq[DrawCommand],
  lookup: proc(h: TextureHandle): YourTexType
) =
  for cmd in cmds:
    case cmd.kind
    of dcQuad:
      let tex = lookup(cmd.quad.texture)
      ## render cmd.quad
    of dcMesh:
      let tex = lookup(cmd.mesh.texture)
      ## render cmd.mesh
```

If `lookup` returns a nil/invalid value, skip that command silently.
