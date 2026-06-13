## Draw-order resolution from the DragonBones zOrder timeline.
##
## Entry point: sampleDrawOrder(kfs, frame, numSlots, output)
##
## The zOrder timeline is stepped (not tweened): the active keyframe is the
## last one whose frame index <= current frame. Each keyframe carries a sparse
## list of (slotIndex, zOffset) pairs that shift specific slots from their
## default z-order position. Slots not listed keep their default position
## (slot array index).
##
## Default draw order (empty keyframe or no timeline): slot index = render layer.
## output[0] = index of backmost slot; output[n-1] = index of frontmost slot.
##
## DragonBones convention: slot 0 is rearmost by default; the z-offset system
## shifts relative to that baseline. An offset of +1 on slot 2 moves it one
## layer forward; −1 moves it one layer back.
##
## When two slots end up with the same effective z-value, the lower slot index
## is treated as rearmost (stable sort by slot index as tiebreaker).

import std/algorithm
import dragonbones/model/model

proc sampleDrawOrder*(kfs: seq[ZOrderKeyframe], frame: float32, numSlots: int,
                      output: var seq[int], zVals: var seq[int]) =
  ## Sample the zOrder timeline at `frame` and write the draw-order permutation
  ## to `output`.
  ##
  ## output must have len == numSlots; caller allocates once and reuses.
  ## output[i] = the slot index to render at layer i (layer 0 = backmost).
  ##
  ## zVals is a caller-managed scratch buffer; auto-grown via setLen when too
  ## small. Pre-size to the maximum slot count and pass the same buffer across
  ## all frames for zero heap allocations per frame. Matches the convention used
  ## by propagateWorldTransforms (scratch) and sampleFFDOffsets (output).
  ##
  ## Precondition: kfs must be sorted ascending by base.frame (guaranteed by the
  ## DragonBones parser via accumulated-duration encoding).
  ##
  ## Allocation budget: zero per frame when output and zVals are pre-sized.
  doAssert output.len == numSlots,
    "output must be parallel to armData.slots (got " & $output.len &
    ", need " & $numSlots & ")"

  # Identity permutation: slot i renders at layer i (default order).
  for i in 0 ..< numSlots: output[i] = i

  if kfs.len == 0: return

  # Stepped sampling: last keyframe at or before `frame`.
  var kfIdx = 0
  for i in 0 ..< kfs.len:
    if float32(kfs[i].base.frame) <= frame:
      kfIdx = i
    else:
      break

  let kf = kfs[kfIdx]
  if kf.slotOffsets.len == 0: return

  # Build per-slot effective z-value: default = slot index.
  if zVals.len < numSlots: zVals.setLen(numSlots)
  for i in 0 ..< numSlots: zVals[i] = i
  for so in kf.slotOffsets:
    if so.slotIndex >= 0 and so.slotIndex < numSlots:
      zVals[so.slotIndex] = so.slotIndex + so.zOffset

  # Sort slot indices by effective z-value; ties broken by slot index (stable).
  # Capture via ptr to work around Nim's var-capture restriction under ARC.
  if numSlots > 0:
    let zdata = cast[ptr UncheckedArray[int]](addr zVals[0])
    output.sort(proc(a, b: int): int =
      let d = cmp(zdata[a], zdata[b])
      if d != 0: d else: cmp(a, b))
