## Top-down world-transform propagation across the bone hierarchy.
##
## DragonBones bone arrays are guaranteed parent-before-child, so a single
## forward pass computes all world matrices correctly.
##
## Call after sampleAnimation (sample.nim) has written localTransform values.
## Pipeline: sampleAnimation → propagateWorldTransforms → render.

import std/math
import vmath
import dragonbones/model/model
import dragonbones/anim/transform

# ── Helpers ───────────────────────────────────────────────────────────────────

proc decomposeWorld(m: Mat3): DbTransform =
  ## Decode a column-major affine Mat3 back into a world DbTransform.
  ## Mirrors DragonBonesJS Transform.fromMatrix: translation is exact; rotation
  ## and per-axis scale are recovered from the 2×2 linear part. skX/skY in DEGREES.
  ##
  ## vmath column-major: m[col, row]
  ##   col0=[a,b,0]  col1=[c,d,0]  col2=[tx,ty,1]
  ## Point form: x' = a*px + c*py + tx,  y' = b*px + d*py + ty
  let a = m[0, 0]; let b = m[0, 1]
  let c = m[1, 0]; let d = m[1, 1]
  var w: DbTransform
  w.x   = m[2, 0]
  w.y   = m[2, 1]
  w.scX = sqrt(a * a + b * b)
  w.scY = sqrt(c * c + d * d)
  if a * d - b * c < 0.0'f32: w.scY = -w.scY  # fold reflection into scY
  w.skY = arctan2(b, a) / DegToRad
  w.skX = arctan2(-c, d) / DegToRad
  w

proc composeWorld(localMat, parentWorldMat: Mat3,
                  boneData: BoneData, local: DbTransform,
                  parentWorld: DbTransform): Mat3 =
  ## World matrix = parentWorld ∘ local, honouring inheritance flags.
  ## Matches DragonBonesJS Bone._updateGlobalTransformMatrix.
  ##
  ## Default (all-inherit-true): plain matrix product parentWorldMat * localMat.
  ## Non-default: build linear part selectively; translation always goes through
  ## the parent matrix (DragonBones transforms child origin through parent frame
  ## even when rotation/scale is not inherited).

  if boneData.inheritRotation and boneData.inheritScale:
    # Common path: true affine matrix product.
    result = parentWorldMat * localMat
    if not boneData.inheritTranslation:
      result[2, 0] = local.x
      result[2, 1] = local.y
  elif boneData.inheritScale:
    # Inherit scale but not rotation: pre-cancel parent rotation before the
    # matrix product so DragonBones' concat leaves the child at local rotation.
    var adj = local
    adj.skY -= parentWorld.skY
    adj.skX -= parentWorld.skY
    result = parentWorldMat * dbTransformToMat3(adj)
    if not boneData.inheritTranslation:
      result[2, 0] = local.x
      result[2, 1] = local.y
  elif boneData.inheritRotation:
    # Inherit rotation but not scale. Rotation is skY; skX shifts by the same
    # parent rotation to preserve the child's local skew (skX - skY).
    var modT = local
    modT.skY = parentWorld.skY + local.skY
    modT.skX = parentWorld.skY + local.skX
    result = dbTransformToMat3(modT)
    if boneData.inheritTranslation:
      result[2, 0] = parentWorldMat[0,0]*local.x + parentWorldMat[1,0]*local.y +
                     parentWorldMat[2,0]
      result[2, 1] = parentWorldMat[0,1]*local.x + parentWorldMat[1,1]*local.y +
                     parentWorldMat[2,1]
    else:
      result[2, 0] = local.x
      result[2, 1] = local.y
  else:
    # Inherit neither rotation nor scale; only the child's attachment point may
    # move through the parent transform.
    result = localMat
    if boneData.inheritTranslation:
      result[2, 0] = parentWorldMat[0,0]*local.x + parentWorldMat[1,0]*local.y +
                     parentWorldMat[2,0]
      result[2, 1] = parentWorldMat[0,1]*local.x + parentWorldMat[1,1]*local.y +
                     parentWorldMat[2,1]
    else:
      result[2, 0] = local.x
      result[2, 1] = local.y

proc findParentIdx(bones: seq[BoneData], parentName: string): int =
  if parentName.len == 0: return -1
  for i in 0 ..< bones.len:
    if bones[i].name == parentName: return i
  -1

# ── Public API ────────────────────────────────────────────────────────────────

proc propagateWorldTransforms*(armData: ArmatureData, bones: var seq[BoneState],
                                scratch: var seq[DbTransform]) =
  ## Walk bones in parent-first order and compute localMatrix + worldMatrix for
  ## each bone, honouring the four inherit flags from BoneData.
  ##
  ## Requires: bones.len == armData.bones.len and each bones[i].localTransform
  ## already set by sampleAnimation (or manually for static poses).
  ## Requires: armData.bones are in parent-before-child order (DragonBones guarantee).
  ##
  ## scratch holds the world DbTransform per bone for IK (reads .x/.y/.skX).
  ## Pass an empty seq — it grows on the first call; pre-size to the largest
  ## armature you will ever animate and it is never reallocated again.
  ##
  ## Allocation budget: zero heap allocations per frame when scratch is pre-sized
  ## to at least armData.bones.len.
  ##
  ## After this call, bones[i].worldMatrix is ready for skinning / rendering.
  doAssert bones.len == armData.bones.len,
    "bones seq must be parallel to armData.bones (got " & $bones.len &
    ", need " & $armData.bones.len & ")"

  if scratch.len < armData.bones.len:
    scratch.setLen(armData.bones.len)

  for i in 0 ..< armData.bones.len:
    let boneData = armData.bones[i]
    let local    = bones[i].localTransform
    let localMat = dbTransformToMat3(local)

    let parentIdx = findParentIdx(armData.bones, boneData.parentName)
    let worldMat =
      if parentIdx < 0:
        localMat   # root bone: world IS local
      else:
        composeWorld(localMat, bones[parentIdx].worldMatrix, boneData,
                     local, scratch[parentIdx])

    bones[i].localMatrix = localMat
    bones[i].worldMatrix = worldMat
    # Populate scratch with the world DbTransform for IK consumers.
    # Root reuses `local` verbatim to avoid atan2/sqrt round-trip.
    scratch[i] = if parentIdx < 0: local else: decomposeWorld(worldMat)
