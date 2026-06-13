## FFD vertex deformation and bone-weighted linear blend skinning.
##
## Two distinct code paths (per boney-o6v):
##   Rigid FFD:  output[i] = base[i] + interpolated_ffd_offset[i]
##   Skinned:    output[i] = sum_j( w_j * boneJ.worldMatrix * (base[i] + ffd_i) )
##
## Both paths accept pre-allocated output buffers to avoid per-frame allocation
## (boney-d0d). Callers must resize buffers to mesh.vertices.len once, then
## reuse them each frame.
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
  ## by a keyframe's offset range are set to zero(Vec2).
  for i in 0 ..< output.len: output[i] = vec2(0, 0)
  if kfs.len == 0: return

  for i in 0 ..< kfs.len:
    let kf = kfs[i]
    if frame < float32(kf.base.frame + kf.base.duration) or i == kfs.len - 1:
      let next = if i + 1 < kfs.len: kfs[i + 1] else: kf
      let t = applyTweenCurve(kf.base.curve,
                               ffdT(kf.base.frame, kf.base.duration, frame))
      let count = min(kf.vertices.len, max(0, output.len - kf.offset))
      for j in 0 ..< count:
        let a = kf.vertices[j]
        let b = if j < next.vertices.len: next.vertices[j] else: a
        output[kf.offset + j] = vec2(a.x + (b.x - a.x) * t,
                                      a.y + (b.y - a.y) * t)
      return

# ── Mesh deformation ──────────────────────────────────────────────────────────

proc deformMeshVertices*(mesh: MeshData, ffdOffsets: seq[Vec2],
                          bones: seq[BoneState], output: var seq[Vec2]) =
  ## Apply FFD offsets and optional linear blend skinning, writing results into
  ## output. output must be pre-allocated to mesh.vertices.len.
  ##
  ## Non-weighted path: output[i] = mesh.vertices[i] + ffdOffsets[i].
  ##
  ## Skinned path: output[i] = sum over vertexWeights[i]:
  ##   weight * (bones[boneIndex].worldMatrix * vec3(v + ffd, 1)).xy
  ## Bone world matrices must be current (call propagateWorldTransforms first).
  ## Out-of-range bone indices are silently skipped (contributes 0 for that weight).
  ##
  ## ffdOffsets should be length mesh.vertices.len; indices past the end are
  ## treated as zero offset (no FFD contribution for that vertex).

  let n = mesh.vertices.len
  doAssert output.len >= n,
    "output must be pre-allocated to at least mesh.vertices.len (got " &
    $output.len & ", need " & $n & ")"

  if mesh.vertexWeights.len == 0:
    for i in 0 ..< n:
      let v = mesh.vertices[i]
      let o = if i < ffdOffsets.len: ffdOffsets[i] else: vec2(0, 0)
      output[i] = vec2(v.x + o.x, v.y + o.y)
  else:
    for i in 0 ..< n:
      let v = mesh.vertices[i]
      let o = if i < ffdOffsets.len: ffdOffsets[i] else: vec2(0, 0)
      let vi = vec3(v.x + o.x, v.y + o.y, 1.0'f32)
      var wx = 0.0'f32; var wy = 0.0'f32
      if i < mesh.vertexWeights.len:
        for wt in mesh.vertexWeights[i]:
          if int(wt.boneIndex) < bones.len:
            let wv = bones[wt.boneIndex].worldMatrix * vi
            wx += wt.weight * wv.x
            wy += wt.weight * wv.y
      output[i] = vec2(wx, wy)
