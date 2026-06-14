## DragonBones texture atlas parsing: UV rects and quad geometry per subtexture.
##
## Entry point: parseAtlas(json) → AtlasData
##
## Per-subtexture output (precomputed at parse time, zero cost per frame):
##   uv: normalized [0,1] atlas texture coordinates for the visible region
##   quad: 4-corner sprite-local vertices + UVs accounting for trim and rotation
##
## The `rotated` flag is true when the sprite was packed 90° CW in the atlas.
## UV corners in `quad.uvs` already account for the rotation so renderers can
## sample the atlas directly without per-frame de-rotation logic.
##
## Coordinate conventions:
##   UV: (0,0) = top-left of atlas, (1,1) = bottom-right
##   Quad verts: origin at the DragonBones default pivot (0.5, 0.5 of the original
##     untrimmed frame = frame center). This aligns with the bone attachment point.
##     Visible content occupies [−pivX, −pivX+visW] × [−pivY, −pivY+visH] where
##     pivX = 0.5*frameWidth + frameX, pivY = 0.5*frameHeight + frameY.

import std/options
import std/math
import vmath
import jsony

# ── Wire types (private) ──────────────────────────────────────────────────────

type
  RawSubTexture = object
    name: string
    x: float32
    y: float32
    width: float32
    height: float32
    rotated: bool            ## absent → false (bool zero-default is correct)
    frameX: float32          ## absent → 0.0 (no left/top trim)
    frameY: float32          ## absent → 0.0
    frameWidth: float32      ## absent → 0.0 (signal: use atlas dims as frame)
    frameHeight: float32     ## absent → 0.0

  RawAtlas = object
    name: string
    imagePath: string
    width: float32
    height: float32
    scale: Option[float32]   ## absent → 1.0 (no atlas scaling)
    subTexture: seq[RawSubTexture]

proc renameHook(v: var RawAtlas, fieldName: var string) =
  ## Map JSON "SubTexture" (capital S) → "subTexture".
  if fieldName == "SubTexture": fieldName = "subTexture"

# ── Public types ──────────────────────────────────────────────────────────────

type
  AtlasSubTexture* = object
    name*: string
    ## True when the sprite was packed rotated 90° CW in the atlas.
    rotated*: bool
    ## Original (untrimmed) frame dimensions in sprite-local pixels.
    frameWidth*, frameHeight*: int
    ## Pixel offset of the visible region within the original frame
    ## (typically negative: frameX=−5 means 5 px trimmed from the left).
    frameX*, frameY*: int
    ## Raw atlas sub-rectangle in pixels (the actual region in the texture atlas).
    ## For rotated sprites, atlasW/atlasH are swapped relative to the displayed
    ## sprite dimensions. Use this with DrawTexturePro's source parameter.
    atlasX*, atlasY*, atlasW*, atlasH*: int
    ## 4-corner sprite quad in sprite-local space and atlas UV space.
    ## Ordered: TL, TR, BR, BL (clockwise). UVs already account for rotation.
    quadVerts*: array[4, Vec2]
    quadUVs*:   array[4, Vec2]

  AtlasData* = object
    name*: string
    imagePath*: string
    width*, height*: int
    scale*: float32
    subTextures*: seq[AtlasSubTexture]

# ── UV and quad computation ───────────────────────────────────────────────────

proc buildSubTexture(raw: RawSubTexture, atlasW, atlasH: float32): AtlasSubTexture =
  let rotated = raw.rotated
  let px = raw.x; let py = raw.y
  let pw = raw.width; let ph = raw.height

  ## Visible region dimensions in original (unrotated) sprite space:
  ##   rotated=false: visW = pw, visH = ph
  ##   rotated=true:  sprite was 90° CW → atlas pw = original visH, ph = original visW
  let visW = if rotated: ph else: pw
  let visH = if rotated: pw else: ph

  ## Frame dimensions: provided by JSON or fall back to visible size (no trim).
  ## round() instead of int() guards against sub-pixel frame offsets in scaled exports.
  let fW = if raw.frameWidth  > 0: round(raw.frameWidth).int  else: round(visW).int
  let fH = if raw.frameHeight > 0: round(raw.frameHeight).int else: round(visH).int
  let fX = round(raw.frameX).int   ## typically ≤ 0; −fX = left trim amount
  let fY = round(raw.frameY).int   ## typically ≤ 0; −fY = top trim amount

  ## Normalized UV coords of the subtexture region in the atlas.
  let u0 = px / atlasW;          let v0 = py / atlasH
  let u1 = (px + pw) / atlasW;   let v1 = (py + ph) / atlasH

  ## Quad vertices in sprite-local space centered on the DragonBones default pivot
  ## (0.5, 0.5 of the original untrimmed frame = frame center at local origin).
  ## pivot in visible-texture space: pivX = 0.5*frameWidth + frameX
  ## (frameX ≤ 0 = left trim, so pivX < 0.5*frameWidth).
  let pivX = float32(fW) * 0.5'f32 + float32(fX)
  let pivY = float32(fH) * 0.5'f32 + float32(fY)
  let qx0 = -pivX;        let qy0 = -pivY
  let qx1 = -pivX + visW; let qy1 = -pivY + visH

  let vTL = vec2(qx0, qy0); let vTR = vec2(qx1, qy0)
  let vBR = vec2(qx1, qy1); let vBL = vec2(qx0, qy1)

  ## UV assignment:
  ## Non-rotated: straightforward rect mapping (TL→TL, TR→TR, BR→BR, BL→BL).
  ## Rotated (90° CW in atlas): sprite TL → atlas BL, TR → TL, BR → TR, BL → BR.
  let (uvTL, uvTR, uvBR, uvBL) =
    if not rotated:
      (vec2(u0, v0), vec2(u1, v0), vec2(u1, v1), vec2(u0, v1))
    else:
      (vec2(u0, v1), vec2(u0, v0), vec2(u1, v0), vec2(u1, v1))

  AtlasSubTexture(
    name:        raw.name,
    rotated:     rotated,
    frameWidth:  fW, frameHeight: fH,
    frameX:      fX, frameY:      fY,
    atlasX:      round(px).int, atlasY: round(py).int,
    atlasW:      round(pw).int, atlasH: round(ph).int,
    quadVerts:   [vTL, vTR, vBR, vBL],
    quadUVs:     [uvTL, uvTR, uvBR, uvBL])

# ── Public API ────────────────────────────────────────────────────────────────

proc parseAtlas*(json: string): AtlasData =
  ## Parse a DragonBones 5.x texture atlas JSON string into AtlasData.
  ## UV and quad geometry are precomputed for every subtexture.
  ## When the root width/height fields are absent (DragonBones 5.5 variant),
  ## atlas dimensions are inferred from the maximum subtexture extent.
  let raw = json.fromJson(RawAtlas)
  let scale = raw.scale.get(1.0'f32)
  var aW = raw.width; var aH = raw.height
  if aW == 0 or aH == 0:
    for s in raw.subTexture:
      aW = max(aW, s.x + s.width)
      aH = max(aH, s.y + s.height)
  doAssert aW > 0 and aH > 0,
    "atlas width/height must be > 0 (got " & $aW & " × " & $aH & ")"
  var subs: seq[AtlasSubTexture]
  for s in raw.subTexture:
    subs.add buildSubTexture(s, aW, aH)
  AtlasData(name: raw.name, imagePath: raw.imagePath,
            width: round(aW).int, height: round(aH).int,
            scale: scale, subTextures: subs)
