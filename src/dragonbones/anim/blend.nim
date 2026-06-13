## Animation blending for DragonBones rigs.
##
## Two blend modes are defined; only crossfade is implemented here:
##
## CROSSFADE (implemented):
##   Interpolates between two independently-sampled animation states.
##   weight=0 → pure animA; weight=1 → pure animB.
##
##   Per-field math:
##     translate  x, y    : lerp(a, b, w)
##     rotate  skX, skY   : shortest-arc lerp (delta clamped to [-180°,180°]
##                          before scaling), so blending always takes the short
##                          path around the circle
##     scale   scX, scY   : lerp(a, b, w)  — linear scale lerp (sufficient for
##                          short fades; log-space is more correct for large
##                          scale ratios but adds cost and is rarely needed)
##     slot color (all)   : lerp(a, b, w) per channel
##     slot displayIndex  : step at w >= 0.5 (pick B's index when majority B)
##     slot blendMode     : step at w >= 0.5 (same rule)
##
## ADDITIVE (math specified here; implementation STAGED):
##   Applies a "layer" animation on top of a base state with a scalar weight.
##   The base is sampleAnimation output; the additive layer uses its own time.
##
##   Per-field math:
##     translate  x, y    : base.x + layer.x * w
##     rotate  skX, skY   : base.skX + layer.skX * w
##     scale   scX, scY   : base.scX * lerp(1.0, layer_delta.scX, w)
##                          where layer_delta.scX is the scale DELTA above the
##                          layer bone's rest pose (caller must strip rest before
##                          passing; if layer rest.scX=1.0 this is already the
##                          sampleAnimation output); lerp(1,x,w) = 1+(x-1)*w
##     slot color mult    : base.aM * lerp(1.0, layer.aM, w) per channel
##     slot color offset  : base.aO + layer.aO * w per channel
##     slot displayIndex  : unchanged (additive layers do not override display)
##     slot blendMode     : unchanged (same)
##
##   Additive implementation: see boney-bp0 follow-up (not in this file yet).

import dragonbones/model/model
import dragonbones/anim/sample

proc lerp32(a, b, t: float32): float32 {.inline.} = a + (b - a) * t

proc lerpDeg(a, b, t: float32): float32 {.inline.} =
  ## Shortest-arc lerp between two angles in degrees.
  ## Wraps the delta to [-180, 180] before interpolating to always take the
  ## short way around (e.g. 350°→10° at t=0.5 gives 0°, not 180°).
  var d = b - a
  if d > 180.0'f32: d -= 360.0'f32
  elif d < -180.0'f32: d += 360.0'f32
  a + d * t

proc blendTransform(a, b: DbTransform, w: float32): DbTransform {.inline.} =
  DbTransform(
    x:   lerp32(a.x,   b.x,   w),
    y:   lerp32(a.y,   b.y,   w),
    skX: lerpDeg(a.skX, b.skX, w),
    skY: lerpDeg(a.skY, b.skY, w),
    scX: lerp32(a.scX, b.scX, w),
    scY: lerp32(a.scY, b.scY, w))

proc blendColor(a, b: DbColor, w: float32): DbColor {.inline.} =
  DbColor(
    aM: lerp32(a.aM, b.aM, w), rM: lerp32(a.rM, b.rM, w),
    gM: lerp32(a.gM, b.gM, w), bM: lerp32(a.bM, b.bM, w),
    aO: lerp32(a.aO, b.aO, w), rO: lerp32(a.rO, b.rO, w),
    gO: lerp32(a.gO, b.gO, w), bO: lerp32(a.bO, b.bO, w))

proc crossfadeAnimations*(
    armData:      ArmatureData,
    animA:        AnimationData, timeA: float32,
    animB:        AnimationData, timeB: float32,
    weight:       float32,
    bones:        var seq[BoneState],
    slots:        var seq[SlotState],
    scratchBones: var seq[BoneState],
    scratchSlots: var seq[SlotState]) =
  ## Blend two animations at their respective times into `bones`/`slots`.
  ##
  ## weight=0 → pure animA; weight=1 → pure animB; values between crossfade.
  ##
  ## `bones`/`slots` must be parallel to armData.bones/slots (caller allocates
  ## once and reuses across frames). `scratchBones`/`scratchSlots` are
  ## caller-managed scratch; auto-grown via setLen when too small.
  ##
  ## Allocation budget: zero per frame when all four seqs are pre-sized.
  ##
  ## `weight` is clamped to [0, 1] — out-of-range values do not extrapolate.
  ##
  ## On return, `bones[i].localMatrix` and `worldMatrix` are stale; call
  ## propagateWorldTransforms to recompute the world hierarchy.
  doAssert bones.len == armData.bones.len,
    "bones must be parallel to armData.bones"
  doAssert slots.len == armData.slots.len,
    "slots must be parallel to armData.slots"

  let w = clamp(weight, 0.0'f32, 1.0'f32)
  let n = armData.bones.len
  let m = armData.slots.len
  if scratchBones.len < n: scratchBones.setLen(n)
  if scratchSlots.len < m: scratchSlots.setLen(m)

  # Sample animA into scratch; animB directly into output.
  sampleAnimation(animA, armData, timeA, scratchBones, scratchSlots)
  sampleAnimation(animB, armData, timeB, bones, slots)

  # Blend output = lerp(scratch[A], output[B], w)
  for i in 0 ..< n:
    bones[i].localTransform = blendTransform(
      scratchBones[i].localTransform, bones[i].localTransform, w)

  for i in 0 ..< m:
    slots[i].color = blendColor(scratchSlots[i].color, slots[i].color, w)
    # Discrete slot fields step at the midpoint.
    if w < 0.5'f32:
      slots[i].displayIndex = scratchSlots[i].displayIndex
      slots[i].blendMode    = scratchSlots[i].blendMode
