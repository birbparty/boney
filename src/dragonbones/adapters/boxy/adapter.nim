## Boxy adapter for boney DrawCommands.
##
## Desktop-only: boxy imports pixie and is never console-free.
## Do NOT compile this for -d:ds3 or -d:vita.
## boxy is an optional consumer-supplied dependency — do NOT add it to boney.nimble.
##
## Mesh slots degrade to a world-space bounding-box draw (boxy has no triangle
## mesh API). The UV bounding box of a mesh is used to find the enclosing
## sub-sprite via containment search; if no sprite contains the bbox the slot
## is silently skipped.
##
## Skew/shear in dstQuad is NOT reproduced — decomposeQuad extracts only
## translation, uniform rotation, and per-axis scale from the TL/TR/BL corners.
## DR animations that rely on skew will render as rotated rectangles.
##
## Setup (once at load time):
##   let atlasImg = readImage("atlas.png")       # pixie Image
##   let spriteMap = newBoxySpriteMap(atlasData)
##   addAtlas(bxy, atlasData, atlasImg)           # skips out-of-bounds sub-rects
##   # NOTE: bare sub.name keys are used; prefix them to avoid collision across
##   # multiple atlases (addAtlas does not namespace keys).
##   let lookup = proc(h: TextureHandle): BoxySpriteMap = spriteMap
##
## Per-frame render:
##   var cmds: seq[DrawCommand]
##   # ... emitDrawCommands into cmds ...
##   renderDrawCommands(bxy, cmds, lookup)
##
## Blend modes beyond NormalBlend are rendered via pushLayer/popLayer (expensive).
## Prefer NormalBlend in animations targeting boxy. bmAdd approximates ScreenBlend.
## bmErase has no boxy equivalent and falls back to NormalBlend.

when defined(ds3) or defined(vita):
  {.error: "dragonbones/adapters/boxy must not be compiled for console targets; boxy requires pixie which is never console-free.".}

import std/math
import std/tables
import vmath
import boxy          ## also exports pixie (Image, BlendMode, subImage, rotate90)
import dragonbones/boundary
import dragonbones/model/model
import dragonbones/atlas/atlas

# ── BoxySpriteMap ──────────────────────────────────────────────────────────────

type
  SpriteRect = tuple[x, y, w, h: int, name: string]

  BoxySpriteMap* = ref object
    ## Maps atlas pixel sub-rectangles to boxy image keys.
    ## Created by newBoxySpriteMap; passed to renderDrawCommands via the lookup proc.
    atlasW*, atlasH*: int
    rectToKey: Table[tuple[x, y, w, h: int], string]
    rects: seq[SpriteRect]  ## ordered list for mesh containment search

proc newBoxySpriteMap*(atlasData: AtlasData): BoxySpriteMap =
  ## Build a BoxySpriteMap from a parsed AtlasData.
  ## Use addAtlas to register the actual images into boxy.
  result = BoxySpriteMap(atlasW: atlasData.width, atlasH: atlasData.height)
  for sub in atlasData.subTextures:
    result.rectToKey[(sub.atlasX, sub.atlasY, sub.atlasW, sub.atlasH)] = sub.name
    result.rects.add((sub.atlasX, sub.atlasY, sub.atlasW, sub.atlasH, sub.name))

proc spriteKey(m: BoxySpriteMap, srcRect: Rect): string {.inline.} =
  ## Exact-integer lookup for DrawQuad (srcRect comes directly from AtlasSubTexture).
  m.rectToKey.getOrDefault(
    (int(srcRect.x), int(srcRect.y), int(srcRect.w), int(srcRect.h)), "")

proc spriteKeyFromUV(m: BoxySpriteMap, uvMin, uvMax: Vec2): string =
  ## Find the sub-sprite whose atlas rect CONTAINS the mesh UV bounding box.
  ## Mesh UVs cover only a sub-region of the sprite's atlas rect, so an exact-size
  ## match would virtually never succeed. Containment search with 0.5 px tolerance
  ## handles float32 rounding without false matches between adjacent sprites.
  let pxMinX = uvMin.x * float32(m.atlasW)
  let pxMinY = uvMin.y * float32(m.atlasH)
  let pxMaxX = uvMax.x * float32(m.atlasW)
  let pxMaxY = uvMax.y * float32(m.atlasH)
  for r in m.rects:
    if pxMinX >= float32(r.x) - 0.5'f32 and
       pxMinY >= float32(r.y) - 0.5'f32 and
       pxMaxX <= float32(r.x + r.w) + 0.5'f32 and
       pxMaxY <= float32(r.y + r.h) + 0.5'f32:
      return r.name
  return ""

proc addAtlas*(bxy: Boxy, atlasData: AtlasData, atlasImg: Image) =
  ## Register all sub-sprites from a DragonBones atlas into boxy.
  ## Each sub-sprite is keyed by its subtexture name (sub.name).
  ## Sub-rects that exceed atlasImg bounds are skipped (pixie.subImage would raise).
  ## Atlas-rotated sprites (stored 90° CW) are un-rotated to display orientation
  ## via 3× rotate90 (270° CW = 90° CCW; pixie exposes only CW rotation).
  for sub in atlasData.subTextures:
    if sub.atlasX < 0 or sub.atlasY < 0 or
       sub.atlasX + sub.atlasW > atlasImg.width or
       sub.atlasY + sub.atlasH > atlasImg.height:
      continue  # skip; avoid PixieError on mismatched atlas PNG vs JSON
    var subImg = atlasImg.subImage(sub.atlasX, sub.atlasY, sub.atlasW, sub.atlasH)
    if sub.rotated:
      subImg.rotate90()
      subImg.rotate90()
      subImg.rotate90()
    bxy.addImage(sub.name, subImg)

# ── Color + blend mode conversion ──────────────────────────────────────────────

proc toBoxyColor(c: model.DbColor): Color {.inline.} =
  ## Convert a DragonBones DbColor (multiplier + additive offset) to boxy/chroma Color.
  ## Formula: channel = clamp(M + O/255, 0, 1), matching the naylib adapter's
  ## uint8(clamp(M*255 + O, 0, 255)) / 255 — algebraically equivalent.
  color(
    clamp(c.rM + c.rO / 255.0'f32, 0.0'f32, 1.0'f32),
    clamp(c.gM + c.gO / 255.0'f32, 0.0'f32, 1.0'f32),
    clamp(c.bM + c.bO / 255.0'f32, 0.0'f32, 1.0'f32),
    clamp(c.aM + c.aO / 255.0'f32, 0.0'f32, 1.0'f32))

proc toBoxyBlend(bm: model.BlendMode): pixie.BlendMode {.inline.} =
  case bm
  of bmNormal, bmAlpha: pixie.NormalBlend
  of bmMultiply:        pixie.MultiplyBlend
  of bmScreen:          pixie.ScreenBlend
  of bmOverlay:         pixie.OverlayBlend
  of bmHardLight:       pixie.HardLightBlend
  of bmDarken:          pixie.DarkenBlend
  of bmLighten:         pixie.LightenBlend
  of bmDodge:           pixie.ColorDodgeBlend
  of bmBurn:            pixie.ColorBurnBlend
  of bmAdd:             pixie.ScreenBlend  ## closest pixie approximation; not exact additive
  of bmErase:           pixie.NormalBlend  ## no boxy equivalent; falls back to Normal

# ── Quad decomposition ─────────────────────────────────────────────────────────

proc decomposeQuad(dstQuad: array[4, Vec2]):
    tuple[tl: Vec2, angle, worldW, worldH: float32] {.inline.} =
  ## Extract TL world-space position, rotation angle (radians), and world dimensions
  ## from a DrawQuad's dstQuad corners (order: TL=0, TR=1, BR=2, BL=3).
  ##
  ## Limitation: only translation, rotation, and per-axis scale are reproduced.
  ## Skew/shear (DragonBones skX/skY) and flips (negative scale) present in dstQuad
  ## are silently dropped — skewed quads render as rotated rectangles.
  ## DR=2 (BR) is unused; skew information lives in the TL/TR/BL triangle only.
  let tl = dstQuad[0]; let tr = dstQuad[1]; let bl = dstQuad[3]
  let dx = tr.x - tl.x; let dy = tr.y - tl.y
  let dxH = bl.x - tl.x; let dyH = bl.y - tl.y
  (tl:     tl,
   angle:  arctan2(dy, dx),
   worldW: sqrt(dx * dx + dy * dy),
   worldH: sqrt(dxH * dxH + dyH * dyH))

# ── Render helpers ─────────────────────────────────────────────────────────────

proc drawSprite(bxy: Boxy, key: string,
                tl: Vec2, angle, worldW, worldH: float32,
                tint: Color, blendMode: pixie.BlendMode) =
  if worldW <= 0'f32 or worldH <= 0'f32: return
  let imgSize = bxy.getImageSize(key)
  if imgSize.x <= 0 or imgSize.y <= 0: return
  let scX = worldW / float32(imgSize.x)
  let scY = worldH / float32(imgSize.y)
  let isNormal = blendMode == pixie.NormalBlend
  if not isNormal: bxy.pushLayer()
  bxy.saveTransform()
  bxy.translate(tl)
  bxy.rotate(angle)
  bxy.scale(vec2(scX, scY))
  bxy.drawImage(key, vec2(0'f32, 0'f32), tint)
  bxy.restoreTransform()
  if not isNormal: bxy.popLayer(color(1'f32, 1'f32, 1'f32, 1'f32), blendMode)

proc renderQuad(bxy: Boxy, q: DrawQuad, sprites: BoxySpriteMap) =
  let key = sprites.spriteKey(q.srcRect)
  if key.len == 0 or not bxy.contains(key): return
  let (tl, angle, worldW, worldH) = decomposeQuad(q.dstQuad)
  drawSprite(bxy, key, tl, angle, worldW, worldH,
             toBoxyColor(q.color), toBoxyBlend(q.blendMode))

proc renderMesh(bxy: Boxy, meshCmd: DrawMesh, sprites: BoxySpriteMap) =
  ## Degrade a mesh slot to its world-space bounding box.
  ## Finds the enclosing sub-sprite via UV containment search.
  if meshCmd.vertices.len == 0 or meshCmd.uvs.len == 0: return

  var minX = meshCmd.vertices[0].x; var maxX = minX
  var minY = meshCmd.vertices[0].y; var maxY = minY
  for v in meshCmd.vertices:
    if v.x < minX: minX = v.x
    if v.x > maxX: maxX = v.x
    if v.y < minY: minY = v.y
    if v.y > maxY: maxY = v.y

  var minU = meshCmd.uvs[0].x; var maxU = minU
  var minV = meshCmd.uvs[0].y; var maxV = minV
  for uv in meshCmd.uvs:
    if uv.x < minU: minU = uv.x
    if uv.x > maxU: maxU = uv.x
    if uv.y < minV: minV = uv.y
    if uv.y > maxV: maxV = uv.y

  let key = sprites.spriteKeyFromUV(vec2(minU, minV), vec2(maxU, maxV))
  if key.len == 0 or not bxy.contains(key): return

  drawSprite(bxy, key, vec2(minX, minY), 0'f32, maxX - minX, maxY - minY,
             toBoxyColor(meshCmd.color), toBoxyBlend(meshCmd.blendMode))

# ── Public API ─────────────────────────────────────────────────────────────────

proc renderDrawCommands*(bxy: Boxy, cmds: seq[DrawCommand],
                          lookup: proc(h: TextureHandle): BoxySpriteMap) =
  ## Render all DrawCommands in order (back→front as produced by emitDrawCommands).
  ##
  ## lookup: maps a TextureHandle to the BoxySpriteMap for that atlas.
  ## Create a BoxySpriteMap with newBoxySpriteMap(atlasData) and register sprites
  ## into boxy with addAtlas(bxy, atlasData, atlasImage) before the first frame.
  for cmd in cmds:
    case cmd.kind
    of dcQuad:
      let sprites = lookup(cmd.quad.texture)
      if sprites != nil: renderQuad(bxy, cmd.quad, sprites)
    of dcMesh:
      let sprites = lookup(cmd.mesh.texture)
      if sprites != nil: renderMesh(bxy, cmd.mesh, sprites)
