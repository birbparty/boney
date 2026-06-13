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
  ## Inheritance semantics (matching DragonBones 5.x runtime):
  ##   - rotation: world.skX/skY = parentWorld.skX/skY + local.skX/skY
  ##   - scale: world.scX/scY = parentWorld.scX/scY * local.scX/scY
  ##   - translation: world.x/y = parent_matrix * local.x/y + parent.x/y
  ##
  ## inheritReflection: prevents negative-scale "flips" from propagating.
  ## When the parent has negative scale and inheritReflection is false, the
  ## child's effective parent scale is treated as 1.0 for the scale component.
  ## This is a known TODO for full correctness with reflected skeletons.

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

proc propagateWorldTransforms*(armData: ArmatureData, bones: var seq[BoneState]) =
  ## Walk bones in parent-first order and compute localMatrix + worldMatrix for
  ## each bone, honouring the four inherit flags from BoneData.
  ##
  ## Requires: bones.len == armData.bones.len and each bones[i].localTransform
  ## already set by sampleAnimation (or manually for static poses).
  ##
  ## After this call, bones[i].worldMatrix is ready for skinning / rendering.

  # Accumulate world DbTransforms in a parallel array so children can reference
  # their parent's world components without matrix decomposition.
  var worldTs = newSeq[DbTransform](armData.bones.len)

  for i in 0 ..< armData.bones.len:
    let boneData = armData.bones[i]
    let local    = bones[i].localTransform

    let parentIdx = findParentIdx(armData.bones, boneData.parentName)
    let worldT =
      if parentIdx < 0:
        local   # root bone: world IS local
      else:
        computeWorldTransform(local, boneData, worldTs[parentIdx])

    worldTs[i]           = worldT
    bones[i].localMatrix = dbTransformToMat3(local)
    bones[i].worldMatrix = dbTransformToMat3(worldT)
