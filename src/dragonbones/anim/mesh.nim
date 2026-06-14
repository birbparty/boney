## FFD vertex deformation and bone-weighted linear blend skinning.
##
## Two distinct code paths (per boney-o6v):
##   Rigid FFD:  output[i] = base[i] + interpolated_ffd_offset[i]
##   Skinned:    output[i] = sum_j( w_j * boneJ.worldMatrix * bindLocalPos_j )
##
## Both paths accept pre-allocated output buffers to avoid per-frame allocation
## (boney-d0d). Callers must resize buffers to the deform vertex count once,
## then reuse them each frame.
##
## Pipeline: sampleAnimation → propagateWorldTransforms → deformMeshVertices → render

import vmath
import dragonbones/model/model
import dragonbones/anim/sample  ## for applyTweenCurve

# ── Local helpers ─────────────────────────────────────────────────────────────

proc ffdT(frameStart, duration: int, frame: float32): float32 {.inline.} =
  if duration == 0: return 0.0'f32
  clamp((frame - float32(frameStart)) / float32(duration), 0.0'f32, 1.0'f32)

# ── FFD sampling ──────────────────────────────────────────────────────────────

proc sampleFFDOffsets*(kfs: seq[FFDKeyframe], frame: float32,
                        output: var seq[Vec2]) =
  ## Interpolate FFD keyframes at frame and write the result into output.
  ## output must be pre-allocated to mesh.vertices.len; all entries not covered
  ## by either the active or next keyframe are set to vec2(0, 0).
  ##
  ## Consecutive FFD keyframes may have different offset values (each is sparse).
  ## Interpolation uses absolute vertex indices; vertices not covered by a frame
  ## have zero deformation for that frame (DragonBones convention).
  for i in 0 ..< output.len: output[i] = vec2(0, 0)
  if kfs.len == 0: return

  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    # Covers all frames before their end; the `or i == kfs.len - 1` branch
    # handles the final keyframe as a permanent hold.
    if frame < float32(kf.base.frame + kf.base.duration) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve,
                               ffdT(kf.base.frame, kf.base.duration, frame))
      let kfEnd      = kf.offset + kf.vertices.len
      let nextEnd    = next.offset + next.vertices.len
      let rangeStart = min(kf.offset, next.offset)
      let rangeEnd   = min(max(kfEnd, nextEnd), output.len)
      for absIdx in rangeStart ..< rangeEnd:
        let kfJ   = absIdx - kf.offset
        let nextJ = absIdx - next.offset
        let a = if kfJ >= 0 and kfJ < kf.vertices.len: kf.vertices[kfJ] else: vec2(0, 0)
        let b = if nextJ >= 0 and nextJ < next.vertices.len: next.vertices[nextJ] else: vec2(0, 0)
        output[absIdx] = vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
      return

# ── Mesh deformation ──────────────────────────────────────────────────────────

proc deformMeshVertices*(mesh: MeshData, ffdOffsets: seq[Vec2],
                          bones: seq[BoneState], output: var seq[Vec2]) =
  ## Apply FFD offsets and optional linear blend skinning, writing results into
  ## output. output must be pre-allocated to the mesh vertex count.
  ##
  ## Non-weighted path (empty vertexWeights): output[i] = mesh.vertices[i] + ffdOffsets[i].
  ##
  ## Skinned path: output[i] = sum over vertexWeights[i]:
  ##   weight * (bones[boneIndex].worldMatrix * vec3(localPos, 1)).xy
  ## Bone world matrices must be current (call propagateWorldTransforms first).
  ## Out-of-range bone indices are silently skipped (contributes 0 for that weight).
  ## Vertices with empty or all-out-of-range weight lists collapse to (0, 0).
  ##
  ## Skinned-mesh FFD is not applied here. DragonBones indexes skinned FFD data
  ## per influence, while this API currently receives per-vertex offsets.
  ##
  ## For non-skinned meshes, ffdOffsets should be length mesh.vertices.len;
  ## indices past the end are treated as zero offset.

  let weighted = mesh.vertexWeights.len > 0
  let n = if weighted: mesh.vertexWeights.len else: mesh.vertices.len
  doAssert output.len >= n,
    "output must be pre-allocated to at least the mesh vertex count (got " &
    $output.len & ", need " & $n & ")"

  if not weighted:
    for i in 0 ..< n:
      let v = mesh.vertices[i]
      let o = if i < ffdOffsets.len: ffdOffsets[i] else: vec2(0, 0)
      output[i] = vec2(v.x + o.x, v.y + o.y)
  else:
    for i in 0 ..< n:
      var wx = 0.0'f32; var wy = 0.0'f32
      for wt in mesh.vertexWeights[i]:
        if int(wt.boneIndex) < bones.len:
          let vi = vec3(wt.localPos.x, wt.localPos.y, 1.0'f32)
          let wv = bones[wt.boneIndex].worldMatrix * vi
          wx += wt.weight * wv.x
          wy += wt.weight * wv.y
      output[i] = vec2(wx, wy)
