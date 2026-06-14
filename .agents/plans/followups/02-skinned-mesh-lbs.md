# Plan: Skinned Mesh Linear Blend Skinning (parse-time bind transform)

Files: `model.nim`, `slot.nim`, `mesh.nim`

## ⚠️ RESEARCH GATE — verify format before implementing

Two independent Opus reviewers disagreed on the DragonBones skinned-mesh format.
**Do not implement until the format claim below is confirmed.**

### The dispute

**Reviewer 1** assumed `weights[]` stores `[count, localIdx, w, localIdx, w, ...]` (2 floats per
influence), and the bind inverse should be applied at render time. This leads to a
`VertexWeight.bindLocalIdx` + `MeshData.bindInverses` approach (the original plan).

**Reviewer 2** found (`PixiSlot.ts:287-315`, `ObjectDataParser.ts:1838-1855`) that DragonBones
applies the bind inverse at **parse time** and stores pre-transformed per-influence bone-local
positions INLINE in the data. The render formula is simply `Σ w * (worldMat * vBoneLocal)`.
If true, the weights array has 4 floats per influence (`localIdx, w, x, y`), not 2.

### How to verify

1. Pick any skinned DragonBones asset (e.g. `you_xin` from the PixiJS demo resource directory,
   which uses cloth mesh skinning). Open the `_ske.json` and find a skin slot with `"weights"`.
2. Count the floats: for vertex 0, the first value is `numInfluences`. If the next
   `numInfluences * 2` floats are `localIdx, w` pairs with the stream then advancing to the
   next vertex, it is the 2-float format (Reviewer 1). If the stream has
   `localIdx, w, x, y` groups (4 floats per influence), it is the 4-float format (Reviewer 2).
3. Also check `ObjectDataParser.ts` around line 1838 for `_helpMatrixB.invert()` and the
   per-influence x,y storage — if present, this confirms parse-time bind-inverse.

---

## The bug (confirmed regardless of format)

Current `deformMeshVertices` skinned path (`mesh.nim:89-101`):
```nim
let wv = bones[wt.boneIndex].worldMatrix * vi   # vi = mesh.vertices[i] + FFD
wx += wt.weight * wv.x
wy += wt.weight * wv.y
```

This treats `mesh.vertices[i]` as the position to transform by the current world matrix.
Moving any bone away from its bind pose will give wrong positions because there is no
compensation for the delta from bind pose. This is wrong under BOTH format interpretations.

---

## Plan A — if format is 2-float per influence (Reviewer 1's model)

The bind inverse belongs at render time. This requires storing bind matrices.

### A1. `model.nim` — add `bindInverses` to `MeshData` and `bindLocalIdx` to `VertexWeight`

```nim
VertexWeight* = object
    boneIndex*:   uint16     ## global bone index (into ArmatureData.bones)
    weight*:      float32
    bindLocalIdx*: uint16    ## index into MeshData.bindInverses

MeshData* = object
    ...existing fields...
    vertexWeights*: seq[seq[VertexWeight]]
    bindInverses*:  seq[Mat3]  ## bindInverses[localIdx] = inverse of bone's bind-pose worldMat
```

`VertexWeight` is constructed in `slot.nim:111` and in `tests/anim/test_mesh.nim:26`.
Adding `bindLocalIdx` is source-compatible (zero-defaults to index 0) but the test helper
`proc wt(boneIdx, w)` will silently use index 0 for all influences. The test must be
updated to construct `VertexWeight(boneIndex:..., weight:..., bindLocalIdx:...)` explicitly.

### A2. `slot.nim` — extract and invert bind matrices in `parseVertexWeights`

```nim
proc parseVertexWeights(weights, bonePose: seq[float32], vertexCount: int):
    tuple[wts: seq[seq[VertexWeight]], invs: seq[Mat3]] =
  if weights.len == 0: return (@[], @[])
  let boneCount = bonePose.len div BonePoseStride
  var invs = newSeq[Mat3](boneCount)
  for bi in 0 ..< boneCount:
    let o = bi * BonePoseStride
    # bonePose layout: [globalBoneIdx, a, b, c, d, tx, ty]
    # vmath mat3 col-major: col0=[a,b,0], col1=[c,d,0], col2=[tx,ty,1]
    let bindMat = mat3(bonePose[o+1], bonePose[o+2], 0.0'f32,
                       bonePose[o+3], bonePose[o+4], 0.0'f32,
                       bonePose[o+5], bonePose[o+6], 1.0'f32)
    # Guard against degenerate bind matrix (singular = bone with zero scale at bind time).
    invs[bi] = if abs(determinant(bindMat)) > 1e-6'f32: inverse(bindMat)
               else: mat3()   # identity fallback; vertex stays at origin for this influence
  var wts = newSeq[seq[VertexWeight]](vertexCount)
  var i = 0
  for v in 0 ..< vertexCount:
    if i >= weights.len: break
    let count = int(weights[i]); inc i
    wts[v] = newSeq[VertexWeight](count)
    var written = 0
    for _ in 0 ..< count:
      if i + 1 >= weights.len: break
      let localIdx = int(weights[i]); let w = weights[i+1]; inc i, 2
      if localIdx < 0 or localIdx >= boneCount: continue
      let globalIdx = uint16(int(bonePose[localIdx * BonePoseStride]))
      wts[v][written] = VertexWeight(boneIndex: globalIdx, weight: w,
                                     bindLocalIdx: uint16(localIdx))
      inc written
    wts[v].setLen(written)
  (wts, invs)
```

Update caller `toDisplayData` (`slot.nim:150`):
```nim
let (wts, invs) = parseVertexWeights(d.weights, d.bonePose, vertexCount)
DisplayData(..., mesh: MeshData(..., vertexWeights: wts, bindInverses: invs))
```

### A3. `mesh.nim` — apply bind-inverse then world matrix

```nim
for wt in mesh.vertexWeights[i]:
  if int(wt.boneIndex) < bones.len:
    let localV =
      if mesh.bindInverses.len > 0 and int(wt.bindLocalIdx) < mesh.bindInverses.len:
        mesh.bindInverses[int(wt.bindLocalIdx)] * vi
      else:
        vi  # fallback (non-skinned or missing bonePose); warn in debug builds
    let wv = bones[wt.boneIndex].worldMatrix * localV
    wx += wt.weight * wv.x
    wy += wt.weight * wv.y
```

Note: the fallback `localV = vi` preserves the old wrong behavior. It should only
trigger for assets that lack `bonePose` data entirely. Add a `{.warning.}` or `echo`
in debug builds to catch this.

---

## Plan B — if format is 4-float per influence (Reviewer 2's model)

The per-influence bone-local positions are stored inline in the weights stream as
`[count, localIdx, weight, x, y, localIdx, weight, x, y, ...]`. The bind inverse was
applied at parse time by the original DragonBones exporter.

### B1. `model.nim` — add `localPos` to `VertexWeight`; remove `mesh.vertices` dependency for skinned

```nim
VertexWeight* = object
    boneIndex*: uint16
    weight*:    float32
    localPos*:  Vec2      ## pre-transformed bone-local position (only set for skinned meshes)
```

`MeshData` unchanged — no `bindInverses` needed.

### B2. `slot.nim` — read the extra x,y per influence

```nim
for _ in 0 ..< count:
    if i + 3 >= weights.len: break
    let localIdx = int(weights[i]); let w = weights[i+1]
    let x = weights[i+2]; let y = weights[i+3]; inc i, 4   # ← 4 floats per influence
    if localIdx < 0 or localIdx >= boneCount: continue
    let globalIdx = uint16(int(bonePose[localIdx * BonePoseStride]))
    wts[v][written] = VertexWeight(boneIndex: globalIdx, weight: w,
                                   localPos: vec2(x, y))
    inc written
```

### B3. `mesh.nim` — render using stored bone-local position directly

```nim
for wt in mesh.vertexWeights[i]:
    if int(wt.boneIndex) < bones.len:
        # FFD in plan B: DragonBones adds FFD offsets to bone-local coords
        # (PixiSlot.ts advances iF inside the bone loop — one FFD offset per influence).
        # For now, apply no FFD for skinned meshes until the FFD index layout is verified.
        let posV = vec3(wt.localPos.x, wt.localPos.y, 1.0'f32)
        let wv = bones[wt.boneIndex].worldMatrix * posV
        wx += wt.weight * wv.x
        wy += wt.weight * wv.y
```

### B4. FFD on skinned meshes (deferred)

Per Reviewer 2 (`PixiSlot.ts:303-307`): FFD offsets for skinned meshes are indexed per
influence (one offset per (vertex, bone) pair), not per vertex. This means the current
`ffdOffsets` seq (indexed per vertex) is the wrong shape for skinned-mesh FFD. Defer FFD
on skinned meshes until the index layout is confirmed; document the limitation.

---

## Tests (apply to whichever plan)

File: `tests/anim/test_mesh_skinning.nim` (new file). Register in `boney.nimble`.

1. **Non-skinned pass-through**: empty `vertexWeights` — output = input + FFD, unchanged.
2. **Single bone, identity bind (Plan A) or explicit bone-local (Plan B)**: bone at (0,0) at bind,
   moves to (50, 0). Vertex at world (10, 0) in bind → bone-local (10, 0).
   After move: world output = (60, 0).
3. **Genuine non-identity bind (Plan A only)**: bind matrix = translate(20, 0).
   A vertex authored at world-bind (30, 0) is bone-local (10, 0). Bone moves to (50, 0).
   Output: (60, 0). This exercises the bind-inverse; an identity-bind test would pass even
   with the old buggy code.
4. **Two-bone blend**: 50/50 between bone A at (0, 100) and bone B at (100, 0).
   Vertex at world-bind (0, 0) in bind → bone-local (0, 0) for both.
   Output ≈ (50, 50).
5. **Graceful fallback (Plan A)**: empty `bindInverses` seq — no crash; output uses vi as-is.
6. **Degenerate bind matrix (Plan A)**: det ≈ 0 → `inverse` skipped; identity used. No crash,
   no NaN/Inf in output.

---

## vmath API note

- `inverse(Mat3): Mat3` exists in vmath (confirmed at `vmath.nim:1242`).
- `determinant(Mat3): float32` exists at `vmath.nim:1198`.
- No `inv()` alias — use `inverse()` throughout.
