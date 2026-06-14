# boney

Render-agnostic Nim runtime for [DragonBones](https://dragonbones.github.io/) 2D skeletal animation.

The core parses DragonBones JSON (skeleton + atlas), samples animations, and emits a `seq[DrawCommand]` each frame. An adapter translates those commands to a specific renderer. No renderer is baked into the core.

**Supported renderers:**
- **naylib** (`src/dragonbones/adapters/naylib/`) — raylib via naylib; desktop + Nintendo 3DS + PS Vita
- **boxy** (`src/dragonbones/adapters/boxy/`) — desktop-only GPU renderer (optional dep)

---

## Quickstart

### naylib (raylib)

```nim
import tables
import raylib, rlgl, vmath
import dragonbones/parse/armature
import dragonbones/atlas/atlas
import dragonbones/model/model
import dragonbones/anim/[sample, propagate, draworder, emit]
import dragonbones/boundary
import dragonbones/adapters/naylib/adapter

## 1. Parse skeleton + atlas
let dbData    = parseDragonBones(readFile("hero_ske.json"))
let atlasData = parseAtlas(readFile("hero_tex.json"))
let armData   = dbData.armatures[0]
let animData  = armData.animations[0]   ## or search by name

## 2. Load atlas texture via raylib
let tex        = loadTexture("hero_tex.png")
let atlasHnd   = TextureHandle(1)       ## any non-zero uint32 you choose
let texLookup  = {atlasHnd: tex}.toTable
proc lookupTex(h: TextureHandle): Texture2D = texLookup.getOrDefault(h)

## 3. Allocate per-frame buffers (reuse across frames — zero alloc in steady state)
var bones       = newSeq[BoneState](armData.bones.len)
var slots       = newSeq[SlotState](armData.slots.len)
var scratch:    seq[DbTransform]
var drawOrd     = newSeq[int](armData.slots.len)
var zScratch:   seq[int]
var drawCmds:   seq[DrawCommand]
var meshScratch: seq[Vec2]
var elapsed     = 0.0'f32
let duration    = float32(animData.duration) / float32(armData.frameRate)

## 4. Find zOrder timeline once (absent for simple skeletons — pass empty seq)
var zOrderKFs: seq[ZOrderKeyframe]
for tl in animData.timelines:
  if tl.kind == tlZOrder:
    zOrderKFs = tl.zOrderKFs
    break

const screenW = 800; const screenH = 600   ## window dimensions
initWindow(screenW, screenH, "boney")

## 5. Game loop
while not windowShouldClose():
  elapsed = (elapsed + getFrameTime()) mod duration

  ## Animate
  sampleAnimation(animData, armData, elapsed, bones, slots)
  propagateWorldTransforms(armData, bones, scratch)
  sampleDrawOrder(zOrderKFs, elapsed * float32(armData.frameRate),
                  armData.slots.len, drawOrd, zScratch)
  emitDrawCommands(armData, armData.skins[0], atlasData, atlasHnd,
                   bones, slots, drawOrd, @[], drawCmds, meshScratch)

  ## Render
  beginDrawing()
  clearBackground(RAYWHITE)
  ## Offset skeleton origin to screen center (800×600 window)
  pushMatrix(); translatef(float32(screenW div 2), float32(screenH div 2), 0)
  renderDrawCommands(drawCmds, lookupTex)
  popMatrix()
  endDrawing()
```

See `examples/naylib/main.nim` for a complete runnable example using the bundled test fixture.

### boxy (desktop-only)

```nim
import boxy, pixie               ## boxy also exports pixie
import dragonbones/atlas/atlas
import dragonbones/boundary
import dragonbones/adapters/boxy/adapter

let bxy       = newBoxy()
let atlasImg  = readImage("hero_tex.png")
let atlasData = parseAtlas(readFile("hero_tex.json"))

## Register sub-sprites into boxy (once at load time)
bxy.addAtlas(atlasData, atlasImg)

let spriteMap = newBoxySpriteMap(atlasData)
let atlasHnd  = TextureHandle(1)
proc lookupSprites(h: TextureHandle): BoxySpriteMap = spriteMap

## Per-frame render (inside boxy frame callback)
bxy.renderDrawCommands(drawCmds, lookupSprites)
```

The boxy adapter must **not** be compiled for console targets. Use the guard at the top of the file (`when defined(ds3) or defined(vita): {.error.}`).

---

## Per-frame pipeline

```
sampleAnimation        -- sample timelines, write local transforms to bones/slots
propagateWorldTransforms -- compute worldMatrix for each bone
sampleDrawOrder        -- compute back-to-front slot permutation
emitDrawCommands       -- produce seq[DrawCommand] in draw order
renderDrawCommands     -- adapter renders commands to screen
```

All five steps are allocation-free once buffers are pre-sized. Reuse the same `seq` values across frames.

---

## DrawCommand format

Two shapes:

| Field | Type | Notes |
|---|---|---|
| `DrawQuad.srcRect` | `Rect` (pixels) | Atlas sub-rect — pass to `DrawTexturePro` source |
| `DrawQuad.uvQuad` | `array[4, Vec2]` | Normalized UVs, corner order TL/TR/BR/BL — pass to `rlVertex` |
| `DrawQuad.dstQuad` | `array[4, Vec2]` | World-space corners, same order |
| `DrawQuad.atlasRotated` | `bool` | Sprite stored 90° CW in atlas |
| `DrawQuad.color` | `DbColor` | Multiplier × M (0–1) + additive offset O (−255..255) |
| `DrawQuad.blendMode` | `BlendMode` | See below |
| `DrawMesh.vertices` | `seq[Vec2]` | Deformed world-space positions |
| `DrawMesh.uvs` | `seq[Vec2]` | Normalized 0–1 (NOT pixels) |
| `DrawMesh.indices` | `seq[uint16]` | Triangle list (triplets) |

`DbColor` formula: `channel = clamp(M + O/255, 0, 1)`.

**Blend modes:** `bmNormal`, `bmAdd`, `bmAlpha`, `bmErase`, `bmDarken`, `bmMultiply`, `bmLighten`, `bmScreen`, `bmOverlay`, `bmHardLight`, `bmDodge`, `bmBurn`.

---

## Console cross-compile

boney's core has no OS or renderer dependencies — it checks out on ARM as-is.

```bash
## Type-check only (no SDK required)
nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --opt:size src/dragonbones.nim

## Full 3DS build (requires devkitARM)
scripts/build_3ds.sh

## Full Vita build (requires VitaSDK)
scripts/build_vita.sh
```

Console compile flags must NOT include the boxy adapter. The naylib adapter selects `DrawTexturePro` automatically when `-d:ds3` or `-d:vita` is defined; mesh slots degrade to a bounding-box quad.

---

## Adapter integration guide

### Writing a new adapter

An adapter is a plain Nim file that:

1. Imports `dragonbones/boundary` (for `DrawCommand`, `TextureHandle`, etc.) and `dragonbones/model/model` (for `DbColor`, `BlendMode`)
2. Defines a `renderDrawCommands*(cmds: seq[DrawCommand], lookup: proc(h: TextureHandle): YourTexType)` proc
3. Iterates over `cmds`, switches on `cmd.kind` (`dcQuad` / `dcMesh`), and translates each to your renderer's calls

No changes to the core are required. The lookup proc is the only adapter-specific coupling.

### Texture handle convention

Issue handles from a counter or a table at load time:

```nim
var nextHandle = 1u32
proc loadAtlas(path: string): TextureHandle =
  let tex = yourRenderer.loadTexture(path)
  result = TextureHandle(nextHandle)
  handles[result] = tex
  inc nextHandle
```

`TextureHandle(0)` is the invalid sentinel (`NullTextureHandle`). Skip any slot whose handle is zero.

---

## Further reading

- [`docs/drawcommand-format.md`](docs/drawcommand-format.md) — full DrawCommand / DbColor / BlendMode reference
- [`docs/naylib-adapter-guide.md`](docs/naylib-adapter-guide.md) — naylib setup, blend modes, console limits
- [`docs/boxy-adapter-guide.md`](docs/boxy-adapter-guide.md) — boxy setup, mesh degradation, skew limitation
- [`docs/console-cross-compile.md`](docs/console-cross-compile.md) — 3DS/Vita build flags, memory model, what changes on console

---

## Build gates

`boney` is a library — `nimble build` errors by design (no binary entry point). Use:

```bash
nim check src/dragonbones.nim           ## compile-check the entry module
nimble test                             ## run the test suite
nimble check                            ## validate package + deps
nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --opt:size src/dragonbones.nim
```
