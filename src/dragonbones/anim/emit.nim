## Frame emit: convert sampled animation state into DrawCommands.
##
## Call order per frame:
##   sampleAnimation → propagateWorldTransforms → emitDrawCommands
##
## Each visible slot produces either a DrawQuad (dkImage) or DrawMesh (dkMesh).
## Armature and bounding-box displays are skipped. Slots with displayIndex < 0
## (DisplayIndexHidden) are skipped.
##
## The atlasData.subTextures lookup is O(n) per visible slot. For large
## armatures, build a precomputed name→index map at load time.
##
## Allocation budget: meshScratch auto-grows per mesh slot and is reused; one
## seq[Vec2](n) is allocated per visible mesh slot per frame for worldVerts
## (owned by the DrawMesh in output). The armature slot-state seq passed in as
## `slots` must have len >= armData.slots.len.

import vmath
import bumpy
import dragonbones/model/model
import dragonbones/atlas/atlas
import dragonbones/anim/mesh
import dragonbones/anim/transform
import ../boundary

proc transformPoint(m: Mat3, p: Vec2): Vec2 {.inline.} =
  let r = m * vec3(p.x, p.y, 1.0'f32)
  vec2(r.x, r.y)

proc findBone(armData: ArmatureData, name: string): int =
  for i in 0 ..< armData.bones.len:
    if armData.bones[i].name == name: return i
  -1

proc findSkinSlot(skin: SkinData, slotName: string): int =
  for i in 0 ..< skin.slots.len:
    if skin.slots[i].slotName == slotName: return i
  -1

proc findSubTex(atlasData: AtlasData, displayName: string): int =
  for i in 0 ..< atlasData.subTextures.len:
    if atlasData.subTextures[i].name == displayName: return i
  -1

proc emitDrawCommands*(
    armData:     ArmatureData,
    skin:        SkinData,
    atlasData:   AtlasData,
    handle:      TextureHandle,
    bones:       seq[BoneState],
    slots:       seq[SlotState],
    drawOrder:   seq[int],
    ffdOffsets:  seq[seq[Vec2]],   ## [slotIdx] → per-vertex FFD; empty seq = no FFD
    output:      var seq[DrawCommand],
    meshScratch: var seq[Vec2]) =  ## caller-managed scratch for mesh deform; auto-grown
  ## Emit one DrawCommand per visible slot, in draw-order.
  ##
  ## drawOrder is a permutation of slot indices (back→front). Slots absent from
  ## drawOrder are not emitted. Typically pass the result of sampleDrawOrder.
  output.setLen(0)

  for zIdx in 0 ..< drawOrder.len:
    let si = drawOrder[zIdx]
    if si < 0 or si >= armData.slots.len or si >= slots.len: continue
    let slotState = slots[si]
    if slotState.displayIndex < 0: continue

    let slotData = armData.slots[si]
    let skinSlotI = findSkinSlot(skin, slotData.name)
    if skinSlotI < 0: continue
    let skinSlot = skin.slots[skinSlotI]
    if slotState.displayIndex >= skinSlot.displays.len: continue
    let display = skinSlot.displays[slotState.displayIndex]

    let boneI = findBone(armData, slotData.boneName)
    let boneWorld = if boneI >= 0: bones[boneI].worldMatrix else: mat3()  # mat3() = identity in vmath
    let dispMat = dbTransformToMat3(display.transform)
    let combinedMat = boneWorld * dispMat

    case display.kind
    of dkImage:
      let subI = findSubTex(atlasData, display.name)
      if subI < 0: continue
      let sub = atlasData.subTextures[subI]

      var dstQuad: array[4, Vec2]
      for j in 0 ..< 4:
        dstQuad[j] = transformPoint(combinedMat, sub.quadVerts[j])

      output.add DrawCommand(
        zOrder: zIdx,
        kind:   dcQuad,
        quad:   DrawQuad(
          texture:      handle,
          srcRect:      rect(float32(sub.atlasX), float32(sub.atlasY),
                             float32(sub.atlasW), float32(sub.atlasH)),
          uvQuad:       sub.quadUVs,
          dstQuad:      dstQuad,
          atlasRotated: sub.rotated,
          color:        slotState.color,
          blendMode:    slotState.blendMode))

    of dkMesh:
      let meshData = display.mesh
      let n =
        if meshData.vertexWeights.len > 0: meshData.vertexWeights.len
        else: meshData.vertices.len
      if n == 0: continue
      if meshScratch.len < n: meshScratch.setLen(n)
      let ffd = if si < ffdOffsets.len: ffdOffsets[si] else: newSeq[Vec2]()
      deformMeshVertices(meshData, ffd, bones, meshScratch)

      var worldVerts = newSeq[Vec2](n)
      if meshData.vertexWeights.len == 0:
        # Non-skinned: deformMeshVertices returns local-space positions; apply slot transform.
        for i in 0 ..< n:
          worldVerts[i] = transformPoint(combinedMat, meshScratch[i])
      else:
        # Skinned: deformMeshVertices already returns world-space positions.
        for i in 0 ..< n:
          worldVerts[i] = meshScratch[i]

      output.add DrawCommand(
        zOrder: zIdx,
        kind:   dcMesh,
        mesh:   DrawMesh(
          texture:   handle,
          vertices:  worldVerts,
          uvs:       meshData.uvs,
          indices:   meshData.indices,
          color:     slotState.color,
          blendMode: slotState.blendMode))

    else:
      discard  # dkArmature / dkBoundingBox: not rendered by the core emit step
