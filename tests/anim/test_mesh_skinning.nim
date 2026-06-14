import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/anim/mesh

const Eps = 1e-4'f32

proc approxEq(a, b: float32): bool = abs(a - b) < Eps
proc approxEqV(a, b: Vec2): bool = approxEq(a.x, b.x) and approxEq(a.y, b.y)

proc translateMat(tx, ty: float32): Mat3 = mat3(1,0,0, 0,1,0, tx,ty,1)

proc boneWithMatrix(m: Mat3): BoneState =
  BoneState(worldMatrix: m)

proc wt(boneIdx: int, w: float32, localPos: Vec2): VertexWeight =
  VertexWeight(boneIndex: uint16(boneIdx), weight: w, localPos: localPos)

suite "skinned mesh LBS":

  test "non-skinned vertices pass through with FFD":
    let mesh = MeshData(vertices: @[vec2(10, 0)])
    var output = newSeq[Vec2](1)
    deformMeshVertices(mesh, @[vec2(5, 2)], @[], output)
    check approxEqV(output[0], vec2(15, 2))

  test "single bone identity bind moves by current bone matrix":
    let mesh = MeshData(vertices: @[vec2(10, 0)], vertexWeights: @[
      @[wt(0, 1.0'f32, vec2(10, 0))]
    ])
    var output = newSeq[Vec2](1)
    deformMeshVertices(mesh, @[], @[boneWithMatrix(translateMat(50, 0))], output)
    check approxEqV(output[0], vec2(60, 0))

  test "single bone non-identity bind uses parsed bone-local position":
    ## Authored bind-space vertex was (30,0), bind bone was translate(20,0),
    ## so parse-time bind compensation stores localPos (10,0).
    let mesh = MeshData(vertices: @[vec2(30, 0)], vertexWeights: @[
      @[wt(0, 1.0'f32, vec2(10, 0))]
    ])
    var output = newSeq[Vec2](1)
    deformMeshVertices(mesh, @[], @[boneWithMatrix(translateMat(50, 0))], output)
    check approxEqV(output[0], vec2(60, 0))

  test "two-bone blend averages current bone transforms":
    let mesh = MeshData(vertices: @[vec2(0, 0)], vertexWeights: @[
      @[wt(0, 0.5'f32, vec2(0, 0)),
        wt(1, 0.5'f32, vec2(0, 0))]
    ])
    var output = newSeq[Vec2](1)
    deformMeshVertices(mesh, @[],
                       @[boneWithMatrix(translateMat(0, 100)),
                         boneWithMatrix(translateMat(100, 0))],
                       output)
    check approxEqV(output[0], vec2(50, 50))

  test "skinned mesh does not require base vertices at render time":
    let mesh = MeshData(uvs: @[vec2(0, 0)], vertexWeights: @[
      @[wt(0, 1.0'f32, vec2(10, 0))]
    ])
    var output = newSeq[Vec2](1)
    deformMeshVertices(mesh, @[], @[boneWithMatrix(translateMat(50, 0))], output)
    check approxEqV(output[0], vec2(60, 0))

  test "skinned per-vertex FFD is ignored until per-influence FFD is modeled":
    let mesh = MeshData(vertices: @[vec2(0, 0)], vertexWeights: @[
      @[wt(0, 1.0'f32, vec2(0, 0))]
    ])
    var output = newSeq[Vec2](1)
    deformMeshVertices(mesh, @[vec2(100, 0)],
                       @[boneWithMatrix(translateMat(0, 10))], output)
    check approxEqV(output[0], vec2(0, 10))
