import std/unittest
import vmath
import dragonbones/atlas/atlas

const Eps = 1e-5'f32

proc approxEq(a, b: float32): bool = abs(a - b) < Eps
proc approxEqV(a, b: Vec2): bool = approxEq(a.x, b.x) and approxEq(a.y, b.y)

# ── Helpers ───────────────────────────────────────────────────────────────────

proc findSub(d: AtlasData, name: string): AtlasSubTexture =
  for s in d.subTextures:
    if s.name == name: return s
  doAssert false, "subtexture not found: " & name

const atlasW = 512.0'f32
const atlasH = 256.0'f32

## Minimal atlas JSON used across most suites.
const baseAtlas = """
{
  "name": "Dragon",
  "imagePath": "Dragon.png",
  "width": 512, "height": 256,
  "scale": 1,
  "SubTexture": [
    { "name": "body",   "x": 0,   "y": 0,   "width": 128, "height": 64 },
    { "name": "arm",    "x": 128, "y": 0,   "width": 64,  "height": 96,
      "frameX": -4, "frameY": -2, "frameWidth": 72, "frameHeight": 100 },
    { "name": "leg_r",  "x": 0,   "y": 64,  "width": 48,  "height": 80,
      "rotated": true },
    { "name": "head",   "x": 192, "y": 0,   "width": 96,  "height": 48,
      "rotated": true,
      "frameX": -3, "frameY": -1, "frameWidth": 54, "frameHeight": 100 }
  ]
}
"""

## Atlas with scale = 0.5 (half-resolution atlas).
const scaledAtlas = """
{
  "name": "DragonHD",
  "imagePath": "DragonHD.png",
  "width": 256, "height": 128,
  "scale": 0.5,
  "SubTexture": [
    { "name": "body", "x": 0, "y": 0, "width": 64, "height": 32 }
  ]
}
"""

# ── parseAtlas — top-level fields ─────────────────────────────────────────────

suite "parseAtlas — top-level fields":

  test "name and imagePath parsed correctly":
    let d = parseAtlas(baseAtlas)
    check d.name == "Dragon"
    check d.imagePath == "Dragon.png"

  test "width and height parsed":
    let d = parseAtlas(baseAtlas)
    check d.width == 512
    check d.height == 256

  test "scale = 1 parsed as 1.0":
    let d = parseAtlas(baseAtlas)
    check approxEq(d.scale, 1.0'f32)

  test "scale = 0.5 parsed correctly":
    let d = parseAtlas(scaledAtlas)
    check approxEq(d.scale, 0.5'f32)

  test "absent scale defaults to 1.0":
    let j = """{"name":"A","imagePath":"A.png","width":64,"height":64,"SubTexture":[]}"""
    let d = parseAtlas(j)
    check approxEq(d.scale, 1.0'f32)

  test "subTextures count":
    let d = parseAtlas(baseAtlas)
    check d.subTextures.len == 4

# ── Non-rotated subtexture, no trim ──────────────────────────────────────────

suite "parseAtlas — non-rotated, no trim":

  test "rotated flag is false":
    let d = parseAtlas(baseAtlas)
    check not findSub(d, "body").rotated

  test "frameWidth/Height defaults to atlas pixel dims":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check s.frameWidth  == 128
    check s.frameHeight == 64

  test "frameX/Y default to zero (no trim)":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check s.frameX == 0
    check s.frameY == 0

  test "UV TL at (x/W, y/H)":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check approxEqV(s.quadUVs[0], vec2(0.0'f32 / atlasW, 0.0'f32 / atlasH))

  test "UV TR at ((x+w)/W, y/H)":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check approxEqV(s.quadUVs[1], vec2(128.0'f32 / atlasW, 0.0'f32 / atlasH))

  test "UV BR at ((x+w)/W, (y+h)/H)":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check approxEqV(s.quadUVs[2], vec2(128.0'f32 / atlasW, 64.0'f32 / atlasH))

  test "UV BL at (x/W, (y+h)/H)":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check approxEqV(s.quadUVs[3], vec2(0.0'f32 / atlasW, 64.0'f32 / atlasH))

  test "quad TL at (0, 0) with no trim":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check approxEqV(s.quadVerts[0], vec2(0, 0))

  test "quad BR at (visW, visH) with no trim":
    let s = findSub(parseAtlas(baseAtlas), "body")
    check approxEqV(s.quadVerts[2], vec2(128, 64))

# ── Non-rotated subtexture, with trim ────────────────────────────────────────

suite "parseAtlas — non-rotated, with trim":

  test "frameX/Y stored as provided":
    let s = findSub(parseAtlas(baseAtlas), "arm")
    check s.frameX == -4
    check s.frameY == -2

  test "frameWidth/Height stored as provided":
    let s = findSub(parseAtlas(baseAtlas), "arm")
    check s.frameWidth  == 72
    check s.frameHeight == 100

  test "quad TL offset by −frameX, −frameY":
    ## arm: frameX=−4 → visible content starts at x=4 in frame space
    let s = findSub(parseAtlas(baseAtlas), "arm")
    check approxEqV(s.quadVerts[0], vec2(4, 2))

  test "quad TR = (−frameX + visW, −frameY)":
    let s = findSub(parseAtlas(baseAtlas), "arm")
    check approxEqV(s.quadVerts[1], vec2(4 + 64, 2))

  test "quad BL = (−frameX, −frameY + visH)":
    let s = findSub(parseAtlas(baseAtlas), "arm")
    check approxEqV(s.quadVerts[3], vec2(4, 2 + 96))

  test "UV TL: x=128, y=0 → (128/512, 0/256)":
    let s = findSub(parseAtlas(baseAtlas), "arm")
    check approxEqV(s.quadUVs[0], vec2(128.0'f32/512, 0.0'f32/256))

# ── Rotated subtexture, no trim ───────────────────────────────────────────────

suite "parseAtlas — rotated, no trim":

  test "rotated flag is true":
    check findSub(parseAtlas(baseAtlas), "leg_r").rotated

  test "frameWidth = atlas height (original sprite width after de-rotation)":
    ## atlas w=48, h=80; after de-rotation: original w=80 (atlas h), h=48 (atlas w)
    let s = findSub(parseAtlas(baseAtlas), "leg_r")
    check s.frameWidth  == 80
    check s.frameHeight == 48

  test "quad spans original sprite dimensions (visW=h=80, visH=w=48)":
    let s = findSub(parseAtlas(baseAtlas), "leg_r")
    check approxEqV(s.quadVerts[0], vec2(0, 0))   ## TL
    check approxEqV(s.quadVerts[2], vec2(80, 48))  ## BR

  test "UV TL: sprite TL → atlas BL (u0, v1)":
    ## leg_r: x=0, y=64, w=48, h=80 → u0=0/512, v0=64/256, u1=48/512, v1=144/256
    let s = findSub(parseAtlas(baseAtlas), "leg_r")
    let u0 = 0.0'f32/512; let v1 = 144.0'f32/256
    check approxEqV(s.quadUVs[0], vec2(u0, v1))   ## TL → atlas BL

  test "UV TR: sprite TR → atlas TL (u0, v0)":
    let s = findSub(parseAtlas(baseAtlas), "leg_r")
    let u0 = 0.0'f32/512; let v0 = 64.0'f32/256
    check approxEqV(s.quadUVs[1], vec2(u0, v0))

  test "UV BR: sprite BR → atlas TR (u1, v0)":
    let s = findSub(parseAtlas(baseAtlas), "leg_r")
    let u1 = 48.0'f32/512; let v0 = 64.0'f32/256
    check approxEqV(s.quadUVs[2], vec2(u1, v0))

  test "UV BL: sprite BL → atlas BR (u1, v1)":
    let s = findSub(parseAtlas(baseAtlas), "leg_r")
    let u1 = 48.0'f32/512; let v1 = 144.0'f32/256
    check approxEqV(s.quadUVs[3], vec2(u1, v1))

# ── Rotated subtexture, with trim ─────────────────────────────────────────────

suite "parseAtlas — rotated, with trim":

  test "frameX/Y/Width/Height from JSON override computed defaults":
    ## head: x=192, y=0, w=96, h=48, rotated; frameX=-3, frameY=-1, fW=54, fH=100
    let s = findSub(parseAtlas(baseAtlas), "head")
    check s.frameX      == -3
    check s.frameY      == -1
    check s.frameWidth  == 54
    check s.frameHeight == 100

  test "quad TL at (−frameX, −frameY) = (3, 1)":
    let s = findSub(parseAtlas(baseAtlas), "head")
    check approxEqV(s.quadVerts[0], vec2(3, 1))

  test "quad BR at (3+visW, 1+visH): rotated → visW=h=48, visH=w=96":
    ## visW = atlas h = 48, visH = atlas w = 96
    let s = findSub(parseAtlas(baseAtlas), "head")
    check approxEqV(s.quadVerts[2], vec2(3 + 48, 1 + 96))
