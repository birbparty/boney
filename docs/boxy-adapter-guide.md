# boxy Adapter Integration Guide

`src/dragonbones/adapters/boxy/adapter.nim`

---

## Overview

Desktop-only adapter for the [boxy](https://github.com/treeform/boxy) GPU renderer. boxy internally manages its own atlas and does not expose sub-region drawing of user images, so the adapter registers each DragonBones sub-sprite as a separate named boxy image at load time.

**Guard**: This adapter must not be compiled for console targets. The file contains:
```nim
when defined(ds3) or defined(vita):
  {.error: "dragonbones/adapters/boxy must not be compiled for console targets"}
```

boxy is an **optional consumer-supplied dependency** — do not add it to `boney.nimble`.

---

## Setup

```nim
import boxy                   ## also exports pixie
import dragonbones/atlas/atlas
import dragonbones/boundary
import dragonbones/adapters/boxy/adapter

let bxy       = newBoxy()
let atlasData = parseAtlas(readFile("hero_tex.json"))
let atlasImg  = readImage("hero_tex.png")   ## pixie Image

## Register sub-sprites into boxy (once per atlas, at load time)
bxy.addAtlas(atlasData, atlasImg)

## Build the sprite map for the lookup proc
let spriteMap = newBoxySpriteMap(atlasData)
let atlasHnd  = TextureHandle(1)

proc lookupSprites(h: TextureHandle): BoxySpriteMap =
  if h == atlasHnd: spriteMap else: nil
```

### Multiple atlases

Keys are bare sub-texture names from the DragonBones atlas JSON. If two atlases share a sub-texture name, they will collide in boxy. Prefix sub-texture names at export time to avoid this.

---

## Per-frame call

```nim
## Inside your boxy frame callback:
bxy.renderDrawCommands(drawCmds, lookupSprites)
```

---

## Mesh slot degradation

boxy has no triangle mesh API. Mesh slots are approximated as a world-space bounding box of all mesh vertices. The enclosing sub-sprite is found via a UV-bounding-box containment search (`spriteKeyFromUV`). If no sprite contains the UV bbox, the slot is silently skipped.

---

## Blend modes

Non-Normal blend modes use `pushLayer()` / `popLayer()` — one offscreen composite per slot. This is expensive; prefer `bmNormal` in animations targeting boxy.

| `model.BlendMode` | `pixie.BlendMode` | Notes |
|---|---|---|
| bmNormal, bmAlpha | NormalBlend | — |
| bmMultiply | MultiplyBlend | — |
| bmScreen | ScreenBlend | — |
| bmOverlay | OverlayBlend | — |
| bmHardLight | HardLightBlend | — |
| bmDarken | DarkenBlend | — |
| bmLighten | LightenBlend | — |
| bmDodge | ColorDodgeBlend | — |
| bmBurn | ColorBurnBlend | — |
| bmAdd | ScreenBlend | Approximation — not true additive |
| bmErase | NormalBlend | No boxy equivalent |

---

## Skew limitation

`decomposeQuad` extracts only translation, rotation, and per-axis scale from the quad's TL/TR/BL corners. Skew and shear (DragonBones `skX`/`skY`) are silently dropped — skewed slots render as rotated rectangles. The naylib desktop path renders exact quads via `rlVertex` and does not have this limitation.

---

## Atlas rotation

Sprites stored rotated 90° CW in the atlas (DragonBones `rotated: true`) are un-rotated in `addAtlas` via 3× `rotate90()` (270° CW = 90° CCW). pixie exposes only CW rotation.

---

## DbColor formula

`channel = clamp(M + O/255, 0, 1)` — matches the naylib adapter's `uint8(clamp(M*255 + O, 0, 255)) / 255` algebraically.
