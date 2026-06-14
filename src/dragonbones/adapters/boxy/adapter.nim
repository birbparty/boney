## Boxy adapter for boney DrawCommands.
##
## Desktop-only: boxy imports pixie and is never console-free.
## Do NOT compile this for -d:ds3 or -d:vita.
##
## Mesh slots degrade to a world-space bounding-box draw using the
## UV-derived sub-region (no full mesh fidelity — boxy has no triangle mesh API).
##
## Setup (once at load time):
##   let spriteMap = newBoxySpriteMap(atlasData)
##   addAtlas(bxy, atlasData, atlasImage)       # add per-sprite keys to boxy
##   # lookup proc: maps TextureHandle → BoxySpriteMap (one per atlas)
##   let lookup = proc(h: TextureHandle): BoxySpriteMap = spriteMap
##
## Per-frame render:
##   var cmds: seq[DrawCommand]
##   # ... emitDrawCommands into cmds ...
##   renderDrawCommands(bxy, cmds, lookup)
##
## Blend modes beyond NormalBlend are rendered via pushLayer/popLayer (expensive).
## Prefer NormalBlend in animations targeting boxy.

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
  BoxySpriteMap* = ref object
    ## Maps atlas pixel sub-rectangles to boxy image keys.
    ## Created by newBoxySpriteMap; passed to renderDrawCommands via the lookup proc.
    atlasW*, atlasH*: int
    rectToKey: Table[tuple[x, y, w, h: int], string]

proc newBoxySpriteMap*(atlasData: AtlasData): BoxySpriteMap =
  ## Build a BoxySpriteMap from a parsed AtlasData.
  ## Use addAtlas to register the actual images into boxy.
  result = BoxySpriteMap(atlasW: atlasData.width, atlasH: atlasData.height)
  for sub in atlasData.subTextures:
    result.rectToKey[(sub.atlasX, sub.atlasY, sub.atlasW, sub.atlasH)] = sub.name

proc spriteKey(m: BoxySpriteMap, srcRect: Rect): string {.inline.} =
  m.rectToKey.getOrDefault(
    (int(srcRect.x), int(srcRect.y), int(srcRect.w), int(srcRect.h)), "")

proc spriteKeyFromUV(m: BoxySpriteMap, uvMin, uvMax: Vec2): string {.inline.} =
  ## Derive the boxy key for a mesh UV bounding box (used for mesh degradation).
  let x = int(uvMin.x * float32(m.atlasW))
  let y = int(uvMin.y * float32(m.atlasH))
  let w = max(1, int((uvMax.x - uvMin.x) * float32(m.atlasW)))
  let h = max(1, int((uvMax.y - uvMin.y) * float32(m.atlasH)))
  m.rectToKey.getOrDefault((x, y, w, h), "")

proc addAtlas*(bxy: Boxy, atlasData: AtlasData, atlasImg: Image) =
  ## Register all sub-sprites from a DragonBones atlas into boxy.
  ## Each sub-sprite is keyed by its subtexture name (sub.name).
  ## Atlas-rotated sprites (stored 90° CW) are un-rotated to display orientation.
  for sub in atlasData.subTextures:
    var subImg = atlasImg.subImage(sub.atlasX, sub.atlasY, sub.atlasW, sub.atlasH)
    if sub.rotated:
      # Stored 90° CW in atlas → rotate 270° CW (= 90° CCW) to restore display orientation.
      subImg.rotate90()
      subImg.rotate90()
      subImg.rotate90()
    bxy.addImage(sub.name, subImg)

# ── Color + blend mode conversion ──────────────────────────────────────────────

proc toBoxyColor(c: model.DbColor): Color {.inline.} =
  ## Convert a DragonBones DbColor (multiplier + additive offset) to boxy/chroma Color.
  ## Identity DbColor (all multipliers=1, offsets=0) → white (1,1,1,1).
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
  of bmAdd, bmErase:    pixie.NormalBlend  # no direct boxy equivalent

# ── Quad decomposition ─────────────────────────────────────────────────────────

proc decomposeQuad(dstQuad: array[4, Vec2]):
    tuple[tl: Vec2, angle, worldW, worldH: float32] {.inline.} =
  ## Extract TL world-space position, rotation angle (radians), and world dimensions
  ## from a DrawQuad's dstQuad corners (order: TL=0, TR=1, BR=2, BL=3).
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

proc renderQuad(bxy: Boxy, q: DrawQuad, m: BoxySpriteMap) =
  let key = m.spriteKey(q.srcRect)
  if key.len == 0 or not bxy.contains(key): return
  let (tl, angle, worldW, worldH) = decomposeQuad(q.dstQuad)
  drawSprite(bxy, key, tl, angle, worldW, worldH,
             toBoxyColor(q.color), toBoxyBlend(q.blendMode))

proc renderMesh(bxy: Boxy, m_cmd: DrawMesh, m: BoxySpriteMap) =
  ## Degrade a mesh slot to its world-space bounding box.
  ## Uses the UV bounding box to find the sub-sprite key via BoxySpriteMap.
  if m_cmd.vertices.len == 0 or m_cmd.uvs.len == 0: return

  var minX = m_cmd.vertices[0].x; var maxX = minX
  var minY = m_cmd.vertices[0].y; var maxY = minY
  for v in m_cmd.vertices:
    if v.x < minX: minX = v.x
    if v.x > maxX: maxX = v.x
    if v.y < minY: minY = v.y
    if v.y > maxY: maxY = v.y

  var minU = m_cmd.uvs[0].x; var maxU = minU
  var minV = m_cmd.uvs[0].y; var maxV = minV
  for uv in m_cmd.uvs:
    if uv.x < minU: minU = uv.x
    if uv.x > maxU: maxU = uv.x
    if uv.y < minV: minV = uv.y
    if uv.y > maxV: maxV = uv.y

  let key = m.spriteKeyFromUV(vec2(minU, minV), vec2(maxU, maxV))
  if key.len == 0 or not bxy.contains(key): return

  let worldW = maxX - minX
  let worldH = maxY - minY
  if worldW <= 0'f32 or worldH <= 0'f32: return

  drawSprite(bxy, key, vec2(minX, minY), 0'f32, worldW, worldH,
             toBoxyColor(m_cmd.color), toBoxyBlend(m_cmd.blendMode))

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
      let m = lookup(cmd.quad.texture)
      if m != nil: renderQuad(bxy, cmd.quad, m)
    of dcMesh:
      let m = lookup(cmd.mesh.texture)
      if m != nil: renderMesh(bxy, cmd.mesh, m)
