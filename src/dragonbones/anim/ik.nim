## IK constraint solver for DragonBones 2D skeletal animation.
##
## Call order per frame:
##   sampleAnimation → propagateWorldTransforms(worldT) →
##   applyIKConstraints(animData, armData, frame, bones, worldT)
##
## applyIKConstraints reads world positions from worldT[], modifies only the
## skX/skY (rotation) fields in bones[i].localTransform, then calls
## propagateWorldTransforms internally so that bones[i].worldMatrix and worldT[]
## reflect the IK-solved pose.
##
## Constraints are processed in ascending IKConstraintData.order.
## The IK animation timeline (tlIK) overrides the constraint's static weight and
## bendPositive values; when no timeline is present the static data values are used.
##
## One-bone IK (chain=0): rotates the end-effector so its tip points at the
## target bone's world origin. Weight blends between rest rotation and IK rotation.
##
## Two-bone IK (chain=1): applies the law of cosines to rotate the parent bone
## and child bone so the child's tip reaches the target. bendPositive controls
## which of the two triangle solutions is used. Weight blends both rotations.

import std/[math, algorithm]
import vmath
import dragonbones/model/model
import dragonbones/anim/transform     ## DegToRad
import dragonbones/anim/sample        ## applyTweenCurve
import dragonbones/anim/propagate     ## propagateWorldTransforms

const RadToDeg = float32(180.0 / PI)

# ── IK timeline sampling ──────────────────────────────────────────────────────

proc ikTweenT(frameStart, duration: int, frame: float32): float32 {.inline.} =
  if duration == 0: return 0.0'f32
  clamp((frame - float32(frameStart)) / float32(duration), 0.0'f32, 1.0'f32)

proc sampleIKKeyframes(kfs: seq[IKKeyframe], frame: float32): tuple[weight: float32, bendPositive: bool] =
  ## Step bendPositive, linearly interpolate weight, respecting tween curves.
  if kfs.len == 0: return (1.0'f32, true)
  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    if frame < float32(kf.base.frame + kf.base.duration) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve, ikTweenT(kf.base.frame, kf.base.duration, frame))
      return (kf.weight + (next.weight - kf.weight) * t, kf.bendPositive)
  (kfs[^1].weight, kfs[^1].bendPositive)

proc getIKParams(animData: AnimationData, constraintName: string, frame: float32,
                  staticWeight: float32, staticBend: bool): tuple[weight: float32, bendPositive: bool] =
  ## Look up tlIK timeline for constraintName; fall back to IKConstraintData values.
  for tl in animData.timelines:
    if tl.kind == tlIK and tl.name == constraintName:
      return sampleIKKeyframes(tl.ikKFs, frame)
  (staticWeight, staticBend)

# ── Bone index lookup ─────────────────────────────────────────────────────────

proc ikFindBone(bones: seq[BoneData], name: string): int {.inline.} =
  for i in 0 ..< bones.len:
    if bones[i].name == name: return i
  -1

# ── One-bone IK ───────────────────────────────────────────────────────────────

proc solveOneBone(armData: ArmatureData, ei, ti: int, weight: float32,
                   bones: var seq[BoneState], worldT: seq[DbTransform]) =
  if ei < 0 or ti < 0: return

  let ex = worldT[ei].x; let ey = worldT[ei].y
  let tx = worldT[ti].x; let ty = worldT[ti].y

  let worldRotDeg = arctan2(ty - ey, tx - ex) * RadToDeg

  let parentName = armData.bones[ei].parentName
  let pi = ikFindBone(armData.bones, parentName)
  let parentWorldRot = if pi >= 0: worldT[pi].skX else: 0.0'f32
  let newLocalRot = worldRotDeg - parentWorldRot

  let blended = bones[ei].localTransform.skX +
                (newLocalRot - bones[ei].localTransform.skX) * weight
  bones[ei].localTransform.skX = blended
  bones[ei].localTransform.skY = blended

# ── Two-bone IK ───────────────────────────────────────────────────────────────

proc solveTwoBone(armData: ArmatureData, ei, pi, ti: int,
                   bendPositive: bool, weight: float32,
                   bones: var seq[BoneState], worldT: seq[DbTransform]) =
  if ei < 0 or pi < 0 or ti < 0: return

  let ax = worldT[pi].x; let ay = worldT[pi].y  ## parent bone origin (world)
  let tx = worldT[ti].x; let ty = worldT[ti].y  ## IK target position (world)

  let lenA = armData.bones[pi].length  ## upper limb length
  let lenB = armData.bones[ei].length  ## lower limb length

  let dx = tx - ax; let dy = ty - ay
  var d = sqrt(dx * dx + dy * dy)
  d = clamp(d, abs(lenA - lenB), lenA + lenB)  ## clamp to reachable range

  ## Law of cosines: angle at parent bone between P→T and P→E.
  let cosAlpha = clamp((lenA * lenA + d * d - lenB * lenB) / (2.0'f32 * lenA * d),
                        -1.0'f32, 1.0'f32)
  let alpha = arccos(cosAlpha)

  let theta = arctan2(dy, dx)  ## direction from parent origin to target

  ## bendSign: positive bend bends "clockwise" (negative alpha offset in standard coords)
  let bendSign = if bendPositive: -1.0'f32 else: 1.0'f32
  let newParentWorldRotRad = theta + bendSign * alpha
  let newParentWorldRotDeg = newParentWorldRotRad * RadToDeg

  ## Parent local rotation
  let grandParentName = armData.bones[pi].parentName
  let gpi = ikFindBone(armData.bones, grandParentName)
  let grandParentWorldRot = if gpi >= 0: worldT[gpi].skX else: 0.0'f32
  let newParentLocalRot = newParentWorldRotDeg - grandParentWorldRot

  let blendedParentLocalRot = bones[pi].localTransform.skX +
                               (newParentLocalRot - bones[pi].localTransform.skX) * weight
  bones[pi].localTransform.skX = blendedParentLocalRot
  bones[pi].localTransform.skY = blendedParentLocalRot

  ## Child origin from blended parent rotation (consistent with post-propagation pose)
  let blendedParentWorldRot = (grandParentWorldRot + blendedParentLocalRot) * DegToRad
  let bx = ax + lenA * cos(blendedParentWorldRot)
  let by = ay + lenA * sin(blendedParentWorldRot)

  ## Rotate child to point from its new origin toward target
  let childWorldRotDeg = arctan2(ty - by, tx - bx) * RadToDeg
  let blendedParentWorldRotDeg = (grandParentWorldRot + blendedParentLocalRot)
  let newChildLocalRot = childWorldRotDeg - blendedParentWorldRotDeg

  let blendedChildLocalRot = bones[ei].localTransform.skX +
                              (newChildLocalRot - bones[ei].localTransform.skX) * weight
  bones[ei].localTransform.skX = blendedChildLocalRot
  bones[ei].localTransform.skY = blendedChildLocalRot

# ── Public API ────────────────────────────────────────────────────────────────

proc applyIKConstraints*(animData: AnimationData, armData: ArmatureData,
                          frame: float32,
                          bones: var seq[BoneState],
                          worldT: var seq[DbTransform]) =
  ## Solve all IK constraints and update bones' local rotations.
  ##
  ## Precondition: worldT must have been populated by propagateWorldTransforms.
  ## After this call worldT and bones[i].worldMatrix are updated to reflect IK.
  if armData.ikConstraints.len == 0: return

  var sorted = armData.ikConstraints
  sorted.sort do (a, b: IKConstraintData) -> int: cmp(a.order, b.order)

  for c in sorted:
    let (weight, bendPositive) = getIKParams(animData, c.name, frame, c.weight, c.bendPositive)
    if weight <= 0.0'f32: continue

    let ei = ikFindBone(armData.bones, c.boneName)
    let ti = ikFindBone(armData.bones, c.targetName)
    if c.chain == 0:
      solveOneBone(armData, ei, ti, weight, bones, worldT)
    else:
      let chainParentIdx = ikFindBone(armData.bones, armData.bones[ei].parentName)
      solveTwoBone(armData, ei, chainParentIdx, ti, bendPositive, weight, bones, worldT)

  propagateWorldTransforms(armData, bones, worldT)
