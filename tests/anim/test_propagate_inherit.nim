import std/[math, unittest]
import vmath
import dragonbones/model/model
import dragonbones/anim/transform
import dragonbones/anim/propagate

var propagateScratch: seq[DbTransform]

const Eps = 1e-4'f32

proc approxEq(a, b: float32): bool = abs(a - b) < Eps

proc bone(name, parent: string, t: DbTransform,
           inhTr = true, inhRo = true, inhSc = true, inhRe = true): BoneData =
  BoneData(name: name, parentName: parent, length: 0.0'f32, transform: t,
           inheritTranslation: inhTr, inheritRotation: inhRo,
           inheritScale: inhSc, inheritReflection: inhRe)

proc arm(bones: seq[BoneData]): ArmatureData =
  ArmatureData(name: "A", frameRate: 24, bones: bones)

proc boneStates(transforms: seq[DbTransform]): seq[BoneState] =
  for t in transforms:
    result.add(BoneState(localTransform: t))

proc decompose(m: Mat3): DbTransform =
  let a = m[0, 0]
  let b = m[0, 1]
  let c = m[1, 0]
  let d = m[1, 1]
  result.x = m[2, 0]
  result.y = m[2, 1]
  result.scX = sqrt(a * a + b * b)
  result.scY = sqrt(c * c + d * d)
  if a * d - b * c < 0.0'f32:
    result.scY = -result.scY
  result.skY = arctan2(b, a) / DegToRad
  result.skX = arctan2(-c, d) / DegToRad

suite "propagate - tier-2 inherit flags":

  test "inheritScale without inheritRotation keeps local rotation with uniform parent scale":
    let parentT = DbTransform(skX: 30.0'f32, skY: 30.0'f32,
                               scX: 2.0'f32, scY: 2.0'f32)
    let childT = DbTransform(skX: 0.0'f32, skY: 0.0'f32,
                              scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhRo = false, inhSc = true)])
    var bs = boneStates(@[parentT, childT])

    propagateWorldTransforms(a, bs, propagateScratch)

    let world = decompose(bs[1].worldMatrix)
    check approxEq(world.scX, 2.0'f32)
    check approxEq(world.scY, 2.0'f32)
    check approxEq(world.skY, 0.0'f32)
    check approxEq(world.skX, 0.0'f32)

  test "inheritRotation without inheritScale uses parent rotation, not parent skew":
    let parentT = DbTransform(skX: 45.0'f32, skY: 30.0'f32,
                               scX: 2.0'f32, scY: 1.0'f32)
    let childT = DbTransform(skX: 15.0'f32, skY: 10.0'f32,
                              scX: 0.5'f32, scY: 0.5'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhRo = true, inhSc = false)])
    var bs = boneStates(@[parentT, childT])

    propagateWorldTransforms(a, bs, propagateScratch)

    let world = decompose(bs[1].worldMatrix)
    check approxEq(world.skY, 40.0'f32)
    check approxEq(world.skX, 45.0'f32)
    check approxEq(world.scX, 0.5'f32)
    check approxEq(world.scY, 0.5'f32)

  test "without rotation or scale inheritance only translation goes through parent":
    let parentT = DbTransform(x: 100.0'f32, y: 50.0'f32,
                               skX: 30.0'f32, skY: 30.0'f32,
                               scX: 2.0'f32, scY: 3.0'f32)
    let childT = DbTransform(x: 10.0'f32, y: 0.0'f32,
                              skX: 5.0'f32, skY: 7.0'f32,
                              scX: 0.75'f32, scY: 1.25'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhRo = false, inhSc = false)])
    var bs = boneStates(@[parentT, childT])

    propagateWorldTransforms(a, bs, propagateScratch)

    let world = decompose(bs[1].worldMatrix)
    let expectedPos = bs[0].worldMatrix * vec3(10.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(world.scX, childT.scX)
    check approxEq(world.scY, childT.scY)
    check approxEq(world.skY, childT.skY)
    check approxEq(world.skX, childT.skX)
    check approxEq(world.x, expectedPos.x)
    check approxEq(world.y, expectedPos.y)

  test "disabled inheritTranslation keeps local child origin":
    let parentT = DbTransform(x: 100.0'f32, y: 50.0'f32,
                               skX: 30.0'f32, skY: 30.0'f32,
                               scX: 2.0'f32, scY: 2.0'f32)
    let childT = DbTransform(x: 50.0'f32, y: 7.0'f32,
                              skX: 0.0'f32, skY: 0.0'f32,
                              scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhTr = false,
           inhRo = false, inhSc = true)])
    var bs = boneStates(@[parentT, childT])

    propagateWorldTransforms(a, bs, propagateScratch)

    check approxEq(bs[1].worldMatrix[2, 0], 50.0'f32)
    check approxEq(bs[1].worldMatrix[2, 1], 7.0'f32)
