import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/anim/mesh

const Eps = 1e-4'f32

# ── Helpers ───────────────────────────────────────────────────────────────────

proc approxEq(a, b: float32): bool = abs(a - b) < Eps
proc approxEqV(a, b: Vec2): bool = approxEq(a.x, b.x) and approxEq(a.y, b.y)

proc boneWithMatrix(m: Mat3): BoneState =
  BoneState(worldMatrix: m)

proc identMat(): Mat3 = mat3(1,0,0, 0,1,0, 0,0,1)
proc translateMat(tx, ty: float32): Mat3 = mat3(1,0,0, 0,1,0, tx,ty,1)

proc ffdKF(frame, duration, offset: int, verts: seq[Vec2]): FFDKeyframe =
  FFDKeyframe(base: KeyframeBase(frame: frame, duration: duration),
              offset: offset, vertices: verts)

proc rigidMesh(verts: seq[Vec2]): MeshData = MeshData(vertices: verts)

proc wt(boneIdx: int, w: float32): VertexWeight =
  VertexWeight(boneIndex: uint16(boneIdx), weight: w)

proc skinnedMesh(verts: seq[Vec2], wts: seq[seq[VertexWeight]]): MeshData =
  MeshData(vertices: verts, vertexWeights: wts)

proc newOffsets(n: int): seq[Vec2] = newSeq[Vec2](n)
proc newBuf(n: int): seq[Vec2] = newSeq[Vec2](n)

# ── sampleFFDOffsets ──────────────────────────────────────────────────────────

suite "sampleFFDOffsets — empty":

  test "empty keyframes: all entries remain zero":
    var buf = newOffsets(4)
    sampleFFDOffsets(@[], 6.0'f32, buf)
    for v in buf: check approxEqV(v, vec2(0, 0))

  test "vertexCount zero: no panic":
    var buf: seq[Vec2] = @[]
    sampleFFDOffsets(@[], 0.0'f32, buf)
    check buf.len == 0

suite "sampleFFDOffsets — single keyframe":

  test "applies offset at specified vertex range":
    var buf = newOffsets(4)
    sampleFFDOffsets(@[ffdKF(0, 0, 1, @[vec2(2, 3)])], 0.0'f32, buf)
    check approxEqV(buf[0], vec2(0, 0))
    check approxEqV(buf[1], vec2(2, 3))
    check approxEqV(buf[2], vec2(0, 0))
    check approxEqV(buf[3], vec2(0, 0))

  test "frame past last keyframe: holds last kf value":
    var buf = newOffsets(1)
    sampleFFDOffsets(@[ffdKF(0, 0, 0, @[vec2(5, 7)])], 99.0'f32, buf)
    check approxEqV(buf[0], vec2(5, 7))

  test "offset range clamped to buffer length":
    var buf = newOffsets(2)
    sampleFFDOffsets(@[ffdKF(0, 0, 1, @[vec2(9, 9), vec2(8, 8)])], 0.0'f32, buf)
    ## offset=1 → fills buf[1]; buf[2] is out of range and skipped
    check approxEqV(buf[1], vec2(9, 9))

suite "sampleFFDOffsets — interpolation":

  test "two keyframes at t=0.5: linearly interpolates":
    var buf = newOffsets(1)
    sampleFFDOffsets(@[ffdKF(0, 24, 0, @[vec2(0, 0)]),
                       ffdKF(24, 0, 0, @[vec2(4, 8)])],
                     12.0'f32, buf)
    check approxEqV(buf[0], vec2(2, 4))

  test "at frame 0 (start of kf0): offset = kf0 value":
    var buf = newOffsets(1)
    sampleFFDOffsets(@[ffdKF(0, 24, 0, @[vec2(1, 2)]),
                       ffdKF(24, 0, 0, @[vec2(5, 6)])],
                     0.0'f32, buf)
    check approxEqV(buf[0], vec2(1, 2))

  test "next kf omits vertex: previous value held (no snap to zero)":
    ## next has fewer vertices than current — use current value as fallback
    var buf = newOffsets(2)
    sampleFFDOffsets(@[ffdKF(0, 24, 0, @[vec2(3, 4), vec2(5, 6)]),
                       ffdKF(24, 0, 0, @[vec2(7, 8)])],  # only 1 vertex
                     12.0'f32, buf)
    ## buf[0]: lerp (3,4) → (7,8) at t=0.5 → (5,6)
    check approxEqV(buf[0], vec2(5, 6))
    ## buf[1]: next has no entry for j=1 → fallback = kf.vertices[1] = (5,6); lerp to self = (5,6)
    check approxEqV(buf[1], vec2(5, 6))

# ── deformMeshVertices — rigid (non-weighted) ─────────────────────────────────

suite "deformMeshVertices — rigid":

  test "no FFD offsets: vertices pass through unchanged":
    let mesh = rigidMesh(@[vec2(1, 2), vec2(3, 4)])
    var buf2 = newBuf(2)
    deformMeshVertices(mesh, newOffsets(2), @[], buf2)
    check approxEqV(buf2[0], vec2(1, 2))
    check approxEqV(buf2[1], vec2(3, 4))

  test "FFD offsets applied element-wise":
    let mesh = rigidMesh(@[vec2(0, 0), vec2(10, 0)])
    var buf2 = newBuf(2)
    deformMeshVertices(mesh, @[vec2(1, 2), vec2(-3, 4)], @[], buf2)
    check approxEqV(buf2[0], vec2(1, 2))
    check approxEqV(buf2[1], vec2(7, 4))

  test "negative offsets work":
    let mesh = rigidMesh(@[vec2(5, 5)])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, @[vec2(-5, -5)], @[], buf2)
    check approxEqV(buf2[0], vec2(0, 0))

  test "shorter ffdOffsets: excess vertices use zero offset":
    let mesh = rigidMesh(@[vec2(1, 2), vec2(3, 4)])
    var buf2 = newBuf(2)
    deformMeshVertices(mesh, @[vec2(1, 0)], @[], buf2)  # only 1 offset for 2 verts
    check approxEqV(buf2[0], vec2(2, 2))
    check approxEqV(buf2[1], vec2(3, 4))  # no offset → unchanged

# ── deformMeshVertices — skinned ──────────────────────────────────────────────

suite "deformMeshVertices — skinned":

  test "single bone weight=1.0, identity world: vertex unchanged":
    let mesh = skinnedMesh(@[vec2(1, 2)], @[@[wt(0, 1.0'f32)]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1), @[boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(1, 2))

  test "single bone weight=1.0, translate (10, 5): vertex translated":
    let mesh = skinnedMesh(@[vec2(1, 2)], @[@[wt(0, 1.0'f32)]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(10, 5))], buf2)
    check approxEqV(buf2[0], vec2(11, 7))

  test "two bones equal weight: vertex is average of both transforms":
    ## bone0 translates by (0, 4): maps (2,0) → (2,4)
    ## bone1 is identity: maps (2,0) → (2,0)
    ## weight 0.5 each → average (2, 2)
    let mesh = skinnedMesh(@[vec2(2, 0)],
                            @[@[wt(0, 0.5'f32), wt(1, 0.5'f32)]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(0, 4)),
                         boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(2, 2))

  test "skinned + FFD: FFD offset applied before skinning":
    ## vertex (0,0) + ffd (1,0) → (1,0); bone translates by (0,10) → (1,10)
    let mesh = skinnedMesh(@[vec2(0, 0)], @[@[wt(0, 1.0'f32)]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, @[vec2(1, 0)],
                       @[boneWithMatrix(translateMat(0, 10))], buf2)
    check approxEqV(buf2[0], vec2(1, 10))

  test "zero-weight contribution: no influence on result":
    let mesh = skinnedMesh(@[vec2(5, 5)], @[@[wt(0, 0.0'f32)]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(100, 100))], buf2)
    check approxEqV(buf2[0], vec2(0, 0))  # weight=0 → no contribution

  test "out-of-range bone index: contribution silently skipped":
    let mesh = skinnedMesh(@[vec2(3, 4)], @[@[wt(99, 1.0'f32)]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1), @[boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(0, 0))  # boneIndex 99 >= bones.len (1) → skipped

  test "empty weights for vertex: result is zero":
    let mesh = skinnedMesh(@[vec2(7, 8)], @[newSeq[VertexWeight]()])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1), @[], buf2)
    check approxEqV(buf2[0], vec2(0, 0))

  test "vertexWeights shorter than vertices: extra verts get zero":
    ## mesh has 2 vertices but only 1 weight entry — second vertex has no weights
    let mesh = skinnedMesh(@[vec2(1, 0), vec2(2, 0)],
                            @[@[wt(0, 1.0'f32)]])  # only covers vertex 0
    var buf2 = newBuf(2)
    deformMeshVertices(mesh, newOffsets(2), @[boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(1, 0))
    check approxEqV(buf2[1], vec2(0, 0))  # no weights → zero
