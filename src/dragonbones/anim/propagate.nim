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

# ── Inheritance helpers ───────────────────────────────────────────────────────

proc computeWorldTransform(local: DbTransform, boneData: BoneData,
                            parentWorld: DbTransform): DbTransform =
  ## Apply BoneData inheritance flags to derive the world DbTransform from
  ## the parent's world DbTransform and the child's local DbTransform.
  ##
  ## Accumulation is intentionally in DbTransform space — additive angles,
  ## multiplicative scales — matching DragonBones Bone._updateGlobalTransformMatrix.
  ## This is NOT a true parent*child affine compose: under non-uniform parent scale
  ## the 2×2 linear part diverges from a true matrix product. This matches DragonBones
  ## reference output, so do not "fix" it to a matrix compose.
  ##
  ## inheritReflection: not yet honoured (boney-xxx). When a parent has negative
  ## scX or scY (reflected skeleton), the child incorrectly inherits the reflection.
  ## Non-reflected skeletons are not affected.

  var w: DbTransform

  # Rotation and scale
  if boneData.inheritRotation and boneData.inheritScale:
    w.skX = parentWorld.skX + local.skX
    w.skY = parentWorld.skY + local.skY
    w.scX = parentWorld.scX * local.scX
    w.scY = parentWorld.scY * local.scY
  elif boneData.inheritRotation:
    w.skX = parentWorld.skX + local.skX
    w.skY = parentWorld.skY + local.skY
    w.scX = local.scX
    w.scY = local.scY
  elif boneData.inheritScale:
    w.skX = local.skX
    w.skY = local.skY
    w.scX = parentWorld.scX * local.scX
    w.scY = parentWorld.scY * local.scY
  else:
    w.skX = local.skX
    w.skY = local.skY
    w.scX = local.scX
    w.scY = local.scY

  # Translation
  if boneData.inheritTranslation:
    let cosSkY = cos(parentWorld.skY * DegToRad)
    let sinSkY = sin(parentWorld.skY * DegToRad)
    let cosSkX = cos(parentWorld.skX * DegToRad)
    let sinSkX = sin(parentWorld.skX * DegToRad)
    # Apply parent's 2×2 rotation/scale sub-matrix to the child's local position,
    # then offset by the parent's world position.
    w.x = parentWorld.x +
          parentWorld.scX * cosSkY * local.x - parentWorld.scY * sinSkX * local.y
    w.y = parentWorld.y +
          parentWorld.scX * sinSkY * local.x + parentWorld.scY * cosSkX * local.y
  else:
    w.x = local.x
    w.y = local.y

  w

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
  ## scratch is a caller-managed work buffer used to accumulate world DbTransforms
  ## during the propagation pass. Initialise it once (newSeq[DbTransform](arm.bones.len))
  ## and reuse it every frame — this proc calls setLen if it is too small, so it
  ## is safe to pass an empty seq; it grows on first call and stays stable thereafter.
  ##
  ## Allocation budget: zero heap allocations per frame when scratch is pre-sized
  ## to armData.bones.len. sampleAnimation and deformMeshVertices are also zero-alloc
  ## when their var-output buffers are pre-allocated. The full animation pipeline
  ## (sampleAnimation → propagateWorldTransforms → sampleFFDOffsets → deformMeshVertices)
  ## is allocation-free in the steady state.
  ##
  ## After this call, bones[i].worldMatrix is ready for skinning / rendering.
  doAssert bones.len == armData.bones.len,
    "bones seq must be parallel to armData.bones (got " & $bones.len &
    ", need " & $armData.bones.len & ")"

  # Grow scratch if needed; no-op (and no allocation) when already large enough.
  if scratch.len < armData.bones.len:
    scratch.setLen(armData.bones.len)

  for i in 0 ..< armData.bones.len:
    let boneData = armData.bones[i]
    let local    = bones[i].localTransform

    let parentIdx = findParentIdx(armData.bones, boneData.parentName)
    let worldT =
      if parentIdx < 0:
        local   # root bone: world IS local
      else:
        computeWorldTransform(local, boneData, scratch[parentIdx])

    scratch[i]           = worldT
    bones[i].localMatrix = dbTransformToMat3(local)
    bones[i].worldMatrix = dbTransformToMat3(worldT)
