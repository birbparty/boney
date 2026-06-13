## Sample keyframe values from animation timelines at a fractional frame position.
##
## Public entry point: sampleAnimation — initialises bone/slot states from the
## armature rest pose, then applies animated deltas from every timeline.
## Callers must call propagateWorldTransforms (propagate.nim) afterwards.

import std/math
import vmath
import dragonbones/model/model

# ── Tween-curve application ───────────────────────────────────────────────────

proc ease32(base, exp: float32): float32 {.inline.} =
  float32(pow(float64(base), float64(exp)))

proc solveBezierY*(p1x, p1y, p2x, p2y, t: float32): float32 =
  ## Given a unit cubic Bezier with control points (p1x,p1y) and (p2x,p2y),
  ## solve for the y value at x=t using binary search on the x parametric.
  ## Control points are in [0,1]×[0,1]; endpoints are fixed at (0,0) and (1,1).
  var lo = 0.0'f32; var hi = 1.0'f32
  for _ in 0..<12:
    let mid = (lo + hi) * 0.5'f32
    let om = 1.0'f32 - mid
    let x = 3.0'f32 * p1x * om * om * mid + 3.0'f32 * p2x * om * mid * mid + mid * mid * mid
    if x < t: lo = mid else: hi = mid
  let u = (lo + hi) * 0.5'f32
  let om = 1.0'f32 - u
  3.0'f32 * p1y * om * om * u + 3.0'f32 * p2y * om * u * u + u * u * u

proc sampleFromCurve(samples: seq[float32], t: float32): float32 =
  ## Linearly interpolate within a pre-sampled easing curve (tkSampled).
  ## samples[0] ≈ 0, samples[^1] ≈ 1; entries are y-values at uniform t intervals.
  if samples.len == 0: return t
  if samples.len == 1: return samples[0]
  let n = samples.len - 1
  let idx = t * float32(n)
  let i = clamp(int(idx), 0, n - 1)
  let frac = idx - float32(i)
  samples[i] + (samples[i + 1] - samples[i]) * frac

proc applyTweenCurve*(curve: TweenCurve, t: float32): float32 =
  ## Map a linear interpolation parameter t ∈ [0,1] through the keyframe's
  ## tween curve, returning the eased t' ∈ [0,1].
  ##
  ## tkStepped returns 0 so the caller always reads the first keyframe's value
  ## (hold until the next keyframe).
  ##
  ## tkQuad formula (power-based): positive easing = ease-in (slow start),
  ## negative easing = ease-out (slow end). May need refinement against
  ## golden 5.7 fixtures (see boney-93g).
  case curve.kind
  of tkLinear:  t
  of tkStepped: 0.0'f32
  of tkQuad:
    let e = curve.easing
    if e == 0.0'f32:
      t
    elif e > 0.0'f32:
      ease32(t, e + 1.0'f32)          # ease-in: t^(e+1), slow start
    else:
      1.0'f32 - ease32(1.0'f32 - t, 1.0'f32 - e)   # ease-out: slow end
  of tkBezier:
    solveBezierY(curve.p1x, curve.p1y, curve.p2x, curve.p2y, t)
  of tkSampled:
    sampleFromCurve(curve.samples, t)

# ── Keyframe lookup ───────────────────────────────────────────────────────────

proc tweenT(frameStart, duration: int, frame: float32): float32 {.inline.} =
  if duration == 0: return 0.0'f32
  clamp((frame - float32(frameStart)) / float32(duration), 0.0'f32, 1.0'f32)

proc lerp32(a, b, t: float32): float32 {.inline.} = a + (b - a) * t

# ── Per-type sampling procs ───────────────────────────────────────────────────

proc sampleBoneTranslate(kfs: seq[BoneTranslateKF], frame: float32): tuple[x, y: float32] =
  if kfs.len == 0: return (0.0'f32, 0.0'f32)
  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    let endFrame = kf.base.frame + kf.base.duration
    if frame < float32(endFrame) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve, tweenT(kf.base.frame, kf.base.duration, frame))
      return (lerp32(kf.x, next.x, t), lerp32(kf.y, next.y, t))
  (kfs[^1].x, kfs[^1].y)

proc sampleBoneRotate(kfs: seq[BoneRotateKF], frame: float32): float32 =
  if kfs.len == 0: return 0.0'f32
  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    if frame < float32(kf.base.frame + kf.base.duration) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve, tweenT(kf.base.frame, kf.base.duration, frame))
      return lerp32(kf.rotate, next.rotate, t)
  kfs[^1].rotate

proc sampleBoneScale(kfs: seq[BoneScaleKF], frame: float32): tuple[scX, scY: float32] =
  if kfs.len == 0: return (1.0'f32, 1.0'f32)
  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    if frame < float32(kf.base.frame + kf.base.duration) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve, tweenT(kf.base.frame, kf.base.duration, frame))
      return (lerp32(kf.scX, next.scX, t), lerp32(kf.scY, next.scY, t))
  (kfs[^1].scX, kfs[^1].scY)

proc sampleSlotDisplay(kfs: seq[SlotDisplayKF], frame: float32): int =
  ## Display index is a discrete step — no interpolation.
  if kfs.len == 0: return DisplayIndexHidden
  result = kfs[0].displayIndex
  for kf in kfs:
    if float32(kf.base.frame) <= frame:
      result = kf.displayIndex
    else:
      break

proc lerpColor(a, b: DbColor, t: float32): DbColor =
  DbColor(
    aM: lerp32(a.aM, b.aM, t), rM: lerp32(a.rM, b.rM, t),
    gM: lerp32(a.gM, b.gM, t), bM: lerp32(a.bM, b.bM, t),
    aO: lerp32(a.aO, b.aO, t), rO: lerp32(a.rO, b.rO, t),
    gO: lerp32(a.gO, b.gO, t), bO: lerp32(a.bO, b.bO, t))

proc sampleSlotColor(kfs: seq[SlotColorKF], frame: float32): DbColor =
  if kfs.len == 0: return dbColorIdentity()
  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    if frame < float32(kf.base.frame + kf.base.duration) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve, tweenT(kf.base.frame, kf.base.duration, frame))
      return lerpColor(kf.color, next.color, t)
  kfs[^1].color

# ── Frame resolution ──────────────────────────────────────────────────────────

proc resolveFrame*(animData: AnimationData, timeSecs: float32, frameRate: int): float32 =
  ## Convert playback time (seconds) to a fractional frame index, applying
  ## loop semantics.  playTimes==0 loops forever; >0 holds at the last frame
  ## after N complete plays.
  let total = float32(animData.duration)
  if total <= 0.0'f32: return 0.0'f32
  let raw = timeSecs * float32(frameRate)
  if animData.playTimes == 0:
    # loop forever: wrap using floor-based modulo (safe for float32)
    return raw - floor(raw / total) * total
  else:
    let maxFrame = total * float32(animData.playTimes)
    return min(raw, maxFrame)

# ── Name lookup helpers ───────────────────────────────────────────────────────

proc findBoneIdx(bones: seq[BoneData], name: string): int =
  for i in 0 ..< bones.len:
    if bones[i].name == name: return i
  -1

proc findSlotIdx(slots: seq[SlotData], name: string): int =
  for i in 0 ..< slots.len:
    if slots[i].name == name: return i
  -1

# ── Public API ────────────────────────────────────────────────────────────────

proc sampleAnimation*(animData: AnimationData, armData: ArmatureData,
                       timeSecs: float32,
                       bones: var seq[BoneState], slots: var seq[SlotState]) =
  ## Sample all bone/slot timelines at timeSecs and write local transforms and
  ## slot state into bones/slots.
  ##
  ## Step 1 of the per-frame update pipeline:
  ##   sampleAnimation → propagateWorldTransforms → render
  ##
  ## Initialises each bone from its ArmatureData rest pose, then applies
  ## animated offsets:
  ##   translate: additive  (world.x = rest.x + anim.x)
  ##   rotate:    additive  (world.skX = rest.skX + anim.rotate; same for skY)
  ##   scale:     multiplicative (world.scX = rest.scX * anim.scX)
  ##
  ## Slots are initialised from SlotData defaults before applying timeline
  ## overrides.  FFD, IK, and zOrder timelines are not handled here (separate
  ## subsystems: boney-o6v, boney-tm6, boney-qyh).

  # Initialise from rest pose
  for i in 0 ..< armData.bones.len:
    bones[i].localTransform = armData.bones[i].transform
  for i in 0 ..< armData.slots.len:
    slots[i].displayIndex = armData.slots[i].displayIndex
    slots[i].color        = armData.slots[i].color
    slots[i].blendMode    = armData.slots[i].blendMode

  let frame = resolveFrame(animData, timeSecs, armData.frameRate)

  for tl in animData.timelines:
    case tl.kind
    of tlBoneTranslate:
      let idx = findBoneIdx(armData.bones, tl.name)
      if idx < 0: continue
      let (dx, dy) = sampleBoneTranslate(tl.translateKFs, frame)
      bones[idx].localTransform.x += dx
      bones[idx].localTransform.y += dy
    of tlBoneRotate:
      let idx = findBoneIdx(armData.bones, tl.name)
      if idx < 0: continue
      let dr = sampleBoneRotate(tl.rotateKFs, frame)
      bones[idx].localTransform.skX += dr
      bones[idx].localTransform.skY += dr
    of tlBoneScale:
      let idx = findBoneIdx(armData.bones, tl.name)
      if idx < 0: continue
      let (dsx, dsy) = sampleBoneScale(tl.scaleKFs, frame)
      bones[idx].localTransform.scX *= dsx
      bones[idx].localTransform.scY *= dsy
    of tlSlotDisplay:
      let idx = findSlotIdx(armData.slots, tl.name)
      if idx < 0: continue
      slots[idx].displayIndex = sampleSlotDisplay(tl.displayKFs, frame)
    of tlSlotColor:
      let idx = findSlotIdx(armData.slots, tl.name)
      if idx < 0: continue
      slots[idx].color = sampleSlotColor(tl.colorKFs, frame)
    else:
      discard  ## FFD, IK, zOrder handled by dedicated subsystems
