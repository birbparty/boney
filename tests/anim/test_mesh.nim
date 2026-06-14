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

proc wt(boneIdx: int, w: float32, localPos: Vec2): VertexWeight =
  VertexWeight(boneIndex: uint16(boneIdx), weight: w, localPos: localPos)

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

  test "next kf omits vertex: uncovered vertex interpolates toward zero":
    ## next has 1 vertex (offset=0); kf has 2 vertices (offset=0).
    ## Vertex 1 is covered by kf (5,6) but not by next: next value = vec2(0,0)
    ## per DragonBones convention (omitted vertex = zero deformation).
    var buf = newOffsets(2)
    sampleFFDOffsets(@[ffdKF(0, 24, 0, @[vec2(3, 4), vec2(5, 6)]),
                       ffdKF(24, 0, 0, @[vec2(7, 8)])],  # only 1 vertex
                     12.0'f32, buf)
    ## buf[0]: lerp (3,4) → (7,8) at t=0.5 → (5,6)
    check approxEqV(buf[0], vec2(5, 6))
    ## buf[1]: kf=(5,6), next=vec2(0,0); lerp at t=0.5 → (2.5, 3)
    check approxEqV(buf[1], vec2(2.5'f32, 3.0'f32))

  test "differing offsets between keyframes: interpolates by absolute vertex index":
    ## kf covers vertices 0-1 (offset=0), next covers vertices 1-2 (offset=1).
    ## Vertex 0: kf=(2,0), next=vec2(0,0)  → lerp at t=0.5 → (1,0)
    ## Vertex 1: kf=(4,0), next=(0,6)      → lerp at t=0.5 → (2,3)
    ## Vertex 2: kf=vec2(0,0), next=(0,8)  → lerp at t=0.5 → (0,4)
    var buf = newOffsets(3)
    sampleFFDOffsets(@[ffdKF(0, 24, 0, @[vec2(2, 0), vec2(4, 0)]),
                       ffdKF(24, 0, 1, @[vec2(0, 6), vec2(0, 8)])],
                     12.0'f32, buf)
    check approxEqV(buf[0], vec2(1, 0))
    check approxEqV(buf[1], vec2(2, 3))
    check approxEqV(buf[2], vec2(0, 4))

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
    let mesh = skinnedMesh(@[vec2(1, 2)], @[@[wt(0, 1.0'f32, vec2(1, 2))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1), @[boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(1, 2))

  test "single bone weight=1.0, translate (10, 5): vertex translated":
    let mesh = skinnedMesh(@[vec2(1, 2)], @[@[wt(0, 1.0'f32, vec2(1, 2))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(10, 5))], buf2)
    check approxEqV(buf2[0], vec2(11, 7))

  test "single bone with non-identity bind uses stored bone-local position":
    ## Bind pose was translate(20,0), so authored world-bind vertex (30,0)
    ## was parsed to localPos (10,0). Moving the bone to (50,0) yields (60,0).
    let mesh = skinnedMesh(@[vec2(30, 0)], @[@[wt(0, 1.0'f32, vec2(10, 0))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(50, 0))], buf2)
    check approxEqV(buf2[0], vec2(60, 0))

  test "two bones equal weight: vertex is average of both transforms":
    ## Both influences have bind-local origin. Current bones move to (0,100)
    ## and (100,0); weight 0.5 each -> average (50,50).
    let mesh = skinnedMesh(@[vec2(2, 0)],
                            @[@[wt(0, 0.5'f32, vec2(0, 0)),
                                wt(1, 0.5'f32, vec2(0, 0))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(0, 100)),
                         boneWithMatrix(translateMat(100, 0))], buf2)
    check approxEqV(buf2[0], vec2(50, 50))

  test "skinned FFD offsets are ignored until per-influence FFD is supported":
    let mesh = skinnedMesh(@[vec2(0, 0)], @[@[wt(0, 1.0'f32, vec2(0, 0))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, @[vec2(1, 0)],
                       @[boneWithMatrix(translateMat(0, 10))], buf2)
    check approxEqV(buf2[0], vec2(0, 10))

  test "zero-weight contribution: no influence on result":
    let mesh = skinnedMesh(@[vec2(5, 5)], @[@[wt(0, 0.0'f32, vec2(5, 5))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1),
                       @[boneWithMatrix(translateMat(100, 100))], buf2)
    check approxEqV(buf2[0], vec2(0, 0))  # weight=0 → no contribution

  test "out-of-range bone index: contribution silently skipped":
    let mesh = skinnedMesh(@[vec2(3, 4)], @[@[wt(99, 1.0'f32, vec2(3, 4))]])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1), @[boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(0, 0))  # boneIndex 99 >= bones.len (1) → skipped

  test "empty weights for vertex: result is zero":
    let mesh = skinnedMesh(@[vec2(7, 8)], @[newSeq[VertexWeight]()])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, newOffsets(1), @[], buf2)
    check approxEqV(buf2[0], vec2(0, 0))

  test "vertexWeights length defines skinned output count":
    ## Skinned output is driven by parsed weighted vertices, not base vertices.
    let mesh = skinnedMesh(@[vec2(1, 0), vec2(2, 0)],
                            @[@[wt(0, 1.0'f32, vec2(1, 0))]])  # only covers vertex 0
    var buf2 = newBuf(2)
    deformMeshVertices(mesh, newOffsets(2), @[boneWithMatrix(identMat())], buf2)
    check approxEqV(buf2[0], vec2(1, 0))

  test "skinned mesh can deform without base vertices":
    let mesh = MeshData(uvs: @[vec2(0, 0)], vertexWeights: @[
      @[wt(0, 1.0'f32, vec2(10, 0))]
    ])
    var buf2 = newBuf(1)
    deformMeshVertices(mesh, @[], @[boneWithMatrix(translateMat(50, 0))], buf2)
    check approxEqV(buf2[0], vec2(60, 0))

  test "undersized output buffer: doAssert fires":
    let mesh = rigidMesh(@[vec2(1, 2)])
    var buf2: seq[Vec2] = @[]
    expect AssertionDefect:
      deformMeshVertices(mesh, @[], @[], buf2)
