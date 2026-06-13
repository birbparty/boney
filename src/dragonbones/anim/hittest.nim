## Hit-testing against DragonBones bounding-box displays.
##
## Usage (per-frame):
##   let hitSlot = findHit(worldPt, armData, bones, slots)
##   if hitSlot >= 0:
##     echo armData.slots[hitSlot].name  # the named interactive region
##
## findHit walks the caller-supplied draw-order permutation front→back, returning
## the first (topmost-drawn) slot whose active bounding-box display contains
## worldPt. Pass the same drawOrder seq used for rendering so hit order matches
## draw order. Returns -1 when no bounding box is hit.
##
## Lower-level entrypoint:
##   hitTestDisplay(worldPt, display, combinedMat) → bool
## tests a world-space point against a single DisplayData given the bone-world
## * display-local combined transform matrix (as produced by emit.nim).
##
## Coordinate convention: DragonBones Y-axis points downward (same as screen
## space). Polygon winding follows the asset convention; the winding-number
## algorithm used here is winding-agnostic.

import vmath
import dragonbones/model/model
import dragonbones/anim/transform   ## dbTransformToMat3

# ── Primitive hit tests (all in bone-local / display-local space) ─────────────

proc hitTestRect(pt: Vec2, verts: seq[Vec2]): bool {.inline.} =
  ## verts has 4 corners (any order/sign — min/max computed here for robustness).
  if verts.len < 4: return false
  var minX = verts[0].x; var maxX = verts[0].x
  var minY = verts[0].y; var maxY = verts[0].y
  for i in 1 ..< 4:
    if verts[i].x < minX: minX = verts[i].x
    if verts[i].x > maxX: maxX = verts[i].x
    if verts[i].y < minY: minY = verts[i].y
    if verts[i].y > maxY: maxY = verts[i].y
  pt.x >= minX and pt.x <= maxX and pt.y >= minY and pt.y <= maxY

proc hitTestEllipse(pt: Vec2, verts: seq[Vec2]): bool {.inline.} =
  ## verts[0] = (rx, 0), verts[1] = (0, ry) — semi-axis endpoint convention.
  if verts.len < 2: return false
  let rx = verts[0].x
  let ry = verts[1].y
  if abs(rx) < 1e-6'f32 or abs(ry) < 1e-6'f32: return false
  let nx = pt.x / rx
  let ny = pt.y / ry
  ## nx/ny are signed; squaring makes sign irrelevant so negative rx/ry still work.
  nx * nx + ny * ny <= 1.0'f32

proc hitTestPolygon(pt: Vec2, verts: seq[Vec2]): bool =
  ## Winding-number point-in-polygon test.  Works for any winding order.
  ## Boundary semantics: points exactly on an edge may register as in or out
  ## depending on edge direction. Use rect/ellipse for pixel-exact boundaries.
  if verts.len < 3: return false
  var winding = 0
  let n = verts.len
  for i in 0 ..< n:
    let a = verts[i]
    let b = verts[(i + 1) mod n]
    if a.y <= pt.y:
      if b.y > pt.y:
        ## Upward crossing: check if pt is left of edge a→b
        if (b.x - a.x) * (pt.y - a.y) - (pt.x - a.x) * (b.y - a.y) > 0:
          inc winding
    else:
      if b.y <= pt.y:
        ## Downward crossing: check if pt is right of edge a→b
        if (b.x - a.x) * (pt.y - a.y) - (pt.x - a.x) * (b.y - a.y) < 0:
          dec winding
  winding != 0

# ── Public API ────────────────────────────────────────────────────────────────

proc hitTestDisplay*(worldPt: Vec2, display: DisplayData, combinedMat: Mat3): bool =
  ## Test whether worldPt falls inside this bounding-box display.
  ## combinedMat = boneWorld * dbTransformToMat3(display.transform).
  ## Returns false for non-bounding-box display kinds and for degenerate
  ## (zero-area) transforms such as a bone scaled to zero.
  if display.kind != dkBoundingBox: return false
  ## A zero-determinant matrix (zero-scale bone) collapses the region to a
  ## point/line; treat as no hit and avoid divide-by-zero in inverse().
  if abs(determinant(combinedMat)) < 1e-6'f32: return false
  let inv = inverse(combinedMat)
  let hom = inv * vec3(worldPt.x, worldPt.y, 1.0'f32)
  let localPt = vec2(hom.x, hom.y)
  case display.bbShape
  of bbsRectangle: hitTestRect(localPt, display.bbVertices)
  of bbsEllipse:   hitTestEllipse(localPt, display.bbVertices)
  of bbsPolygon:   hitTestPolygon(localPt, display.bbVertices)

proc findHit*(worldPt: Vec2, armData: ArmatureData,
              bones: seq[BoneState], slots: seq[SlotState],
              drawOrder: seq[int],
              skinIdx = 0): int =
  ## Find the topmost-drawn slot whose active bounding-box display contains
  ## worldPt, or -1. Pass the same drawOrder permutation used for rendering
  ## (result of sampleDrawOrder, or a default [0,1,..N-1] when no zOrder
  ## timeline is active). Iterates front→back and returns on first hit.
  ##
  ## Precondition: bones.len == armData.bones.len, slots.len == armData.slots.len.
  doAssert bones.len == armData.bones.len
  doAssert slots.len == armData.slots.len

  if skinIdx < 0 or skinIdx >= armData.skins.len: return -1
  let skin = armData.skins[skinIdx]

  ## Walk front→back: drawOrder[high] is frontmost; first hit = topmost visible.
  for zIdx in countdown(drawOrder.high, 0):
    let si = drawOrder[zIdx]
    if si < 0 or si >= armData.slots.len: continue

    let slotState = slots[si]
    if slotState.displayIndex < 0: continue

    let slotData = armData.slots[si]

    var skinSlotI = -1
    for k in 0 ..< skin.slots.len:
      if skin.slots[k].slotName == slotData.name:
        skinSlotI = k
        break
    if skinSlotI < 0: continue

    let skinSlot = skin.slots[skinSlotI]
    if slotState.displayIndex >= skinSlot.displays.len: continue
    let display = skinSlot.displays[slotState.displayIndex]
    if display.kind != dkBoundingBox: continue

    var boneI = -1
    for k in 0 ..< armData.bones.len:
      if armData.bones[k].name == slotData.boneName:
        boneI = k
        break

    let boneWorld = if boneI >= 0: bones[boneI].worldMatrix else: mat3()
    let dispMat = dbTransformToMat3(display.transform)
    let combinedMat = boneWorld * dispMat

    if hitTestDisplay(worldPt, display, combinedMat):
      return si

  return -1
