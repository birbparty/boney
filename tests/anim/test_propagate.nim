import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/anim/transform
import dragonbones/anim/propagate

# Module-level scratch buffer reused across all tests (zero-alloc after first use).
# Carry-over between tests is harmless: propagate overwrites every live slot before reading.
var propagateScratch: seq[DbTransform]

# ── Helpers ───────────────────────────────────────────────────────────────────

const Eps = 1e-4'f32

proc approxEq(a, b: float32): bool = abs(a - b) < Eps

proc bone(name, parent: string, t: DbTransform,
           inhTr = true, inhRo = true, inhSc = true, inhRe = true): BoneData =
  BoneData(name: name, parentName: parent, length: 0.0'f32, transform: t,
           inheritTranslation: inhTr, inheritRotation: inhRo,
           inheritScale: inhSc, inheritReflection: inhRe)

proc boneI(name, parent: string): BoneData =
  bone(name, parent, dbTransformIdentity())

proc arm(bones: seq[BoneData]): ArmatureData =
  ArmatureData(name: "A", frameRate: 24, bones: bones)

proc boneStates(transforms: seq[DbTransform]): seq[BoneState] =
  for t in transforms:
    result.add(BoneState(localTransform: t))

# ── dbTransformToMat3 ─────────────────────────────────────────────────────────

suite "transform — dbTransformToMat3":

  test "identity transform: maps unit vectors to themselves":
    let m = dbTransformToMat3(dbTransformIdentity())
    let vx = m * vec3(1.0'f32, 0.0'f32, 0.0'f32)
    let vy = m * vec3(0.0'f32, 1.0'f32, 0.0'f32)
    check approxEq(vx.x, 1.0'f32)
    check approxEq(vx.y, 0.0'f32)
    check approxEq(vy.x, 0.0'f32)
    check approxEq(vy.y, 1.0'f32)

  test "pure translation: origin maps to (tx, ty)":
    let m = dbTransformToMat3(DbTransform(x: 5.0'f32, y: -3.0'f32,
                                           scX: 1.0'f32, scY: 1.0'f32))
    let v = m * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 5.0'f32)
    check approxEq(v.y, -3.0'f32)

  test "90-degree rotation: (1,0) → (0,1)":
    let m = dbTransformToMat3(DbTransform(skX: 90.0'f32, skY: 90.0'f32,
                                           scX: 1.0'f32, scY: 1.0'f32))
    let v = m * vec3(1.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 0.0'f32)
    check approxEq(v.y, 1.0'f32)

  test "uniform scale: doubles vector length":
    let m = dbTransformToMat3(DbTransform(scX: 2.0'f32, scY: 2.0'f32))
    let v = m * vec3(3.0'f32, 4.0'f32, 1.0'f32)
    check approxEq(v.x, 6.0'f32)
    check approxEq(v.y, 8.0'f32)

  test "non-uniform scale":
    let m = dbTransformToMat3(DbTransform(scX: 3.0'f32, scY: 0.5'f32))
    let v = m * vec3(1.0'f32, 1.0'f32, 1.0'f32)
    check approxEq(v.x, 3.0'f32)
    check approxEq(v.y, 0.5'f32)

  test "translate + rotation composes correctly":
    ## 90° rotation then translate (10,0): point (1,0) → (0,1) → (10,1)
    let m = dbTransformToMat3(DbTransform(x: 10.0'f32, y: 0.0'f32,
                                           skX: 90.0'f32, skY: 90.0'f32,
                                           scX: 1.0'f32, scY: 1.0'f32))
    let v = m * vec3(1.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 10.0'f32)
    check approxEq(v.y, 1.0'f32)

# ── Root bone (no parent) ─────────────────────────────────────────────────────

suite "propagate — root bone":

  test "single root bone: world transform equals local":
    let a = arm(@[boneI("root", "")])
    let t = DbTransform(x: 5.0'f32, y: 3.0'f32,
                         skX: 45.0'f32, skY: 45.0'f32,
                         scX: 2.0'f32, scY: 0.5'f32)
    var bs = boneStates(@[t])
    propagateWorldTransforms(a, bs, propagateScratch)
    ## world matrix and local matrix must transform test points identically
    let w = bs[0].worldMatrix
    let l = bs[0].localMatrix
    block:
      let wv = w * vec3(1.0'f32, 0.0'f32, 0.0'f32)
      let lv = l * vec3(1.0'f32, 0.0'f32, 0.0'f32)
      check approxEq(wv.x, lv.x); check approxEq(wv.y, lv.y)
    block:
      let wv = w * vec3(0.0'f32, 0.0'f32, 1.0'f32)
      let lv = l * vec3(0.0'f32, 0.0'f32, 1.0'f32)
      check approxEq(wv.x, lv.x); check approxEq(wv.y, lv.y)

  test "root localMatrix also set":
    let a = arm(@[boneI("root", "")])
    var bs = boneStates(@[DbTransform(x: 1.0'f32, y: 2.0'f32, scX: 1.0'f32, scY: 1.0'f32)])
    propagateWorldTransforms(a, bs, propagateScratch)
    let v = bs[0].localMatrix * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 1.0'f32)
    check approxEq(v.y, 2.0'f32)

# ── Full inheritance ──────────────────────────────────────────────────────────

suite "propagate — full inheritance":

  test "child at origin with parent translated: child world = parent position":
    let a = arm(@[
      bone("root", "", DbTransform(x: 10.0'f32, y: 0.0'f32, scX: 1.0'f32, scY: 1.0'f32)),
      boneI("child", "root")])
    var bs = boneStates(@[
      DbTransform(x: 10.0'f32, y: 0.0'f32, scX: 1.0'f32, scY: 1.0'f32),
      dbTransformIdentity()])
    propagateWorldTransforms(a, bs, propagateScratch)
    ## child world translation = parent.x + 0*cos(0) - 0*sin(0) = 10
    let v = bs[1].worldMatrix * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 10.0'f32)
    check approxEq(v.y, 0.0'f32)

  test "parent 90° rotation propagates to child: child axis rotated":
    ## Parent at origin, rotated 90°.  Child is 5 units along local X.
    ## After inheritance, child world position is 5 units along world Y.
    let parentT = DbTransform(skX: 90.0'f32, skY: 90.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let childT  = DbTransform(x: 5.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[bone("root", "", parentT), boneI("child", "root")])
    var bs = boneStates(@[parentT, childT])
    propagateWorldTransforms(a, bs, propagateScratch)
    let v = bs[1].worldMatrix * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 0.0'f32)
    check approxEq(v.y, 5.0'f32)

  test "parent scale propagates to child":
    let parentT = DbTransform(scX: 2.0'f32, scY: 2.0'f32)
    let childT  = DbTransform(x: 1.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[bone("root", "", parentT), boneI("child", "root")])
    var bs = boneStates(@[parentT, childT])
    propagateWorldTransforms(a, bs, propagateScratch)
    ## child local x=1; parent scX=2 → child world x=2
    let v = bs[1].worldMatrix * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 2.0'f32)

  test "three-bone chain: world matrices are composed correctly":
    ## root → mid → leaf, each offset by 10 on X, all identity rotation/scale
    let t10 = DbTransform(x: 10.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[bone("root", "", t10),
                   bone("mid", "root", t10),
                   bone("leaf", "mid", t10)])
    var bs = boneStates(@[t10, t10, t10])
    propagateWorldTransforms(a, bs, propagateScratch)
    let v = bs[2].worldMatrix * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 30.0'f32)

# ── Inheritance flags ─────────────────────────────────────────────────────────

suite "propagate — inheritance flags":

  test "!inheritTranslation: child world pos = child local pos":
    let parentT = DbTransform(x: 50.0'f32, y: 50.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let childT  = DbTransform(x: 3.0'f32, y: 4.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhTr = false)])
    var bs = boneStates(@[parentT, childT])
    propagateWorldTransforms(a, bs, propagateScratch)
    let v = bs[1].worldMatrix * vec3(0.0'f32, 0.0'f32, 1.0'f32)
    check approxEq(v.x, 3.0'f32)
    check approxEq(v.y, 4.0'f32)

  test "!inheritRotation: child world rotation = child local rotation only":
    let parentT = DbTransform(skX: 90.0'f32, skY: 90.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let childT  = DbTransform(skX: 0.0'f32, skY: 0.0'f32, scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhRo = false)])
    var bs = boneStates(@[parentT, childT])
    propagateWorldTransforms(a, bs, propagateScratch)
    ## child world rotation = 0° (its local), not 90° from parent
    ## Check: (1,0,1) maps to ~(1,0) not (0,1)
    let v = bs[1].worldMatrix * vec3(1.0'f32, 0.0'f32, 0.0'f32)
    check approxEq(v.x, 1.0'f32)
    check abs(v.y) < Eps

  test "!inheritScale: child world scale = child local scale only":
    let parentT = DbTransform(scX: 3.0'f32, scY: 3.0'f32)
    let childT  = DbTransform(scX: 2.0'f32, scY: 2.0'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhSc = false)])
    var bs = boneStates(@[parentT, childT])
    propagateWorldTransforms(a, bs, propagateScratch)
    ## child scale should be 2 (its own), not 6 (3*2)
    let v = bs[1].worldMatrix * vec3(1.0'f32, 0.0'f32, 0.0'f32)
    check approxEq(v.x, 2.0'f32)

  test "!inheritRotation and !inheritScale: child fully independent":
    let parentT = DbTransform(skX: 45.0'f32, skY: 45.0'f32,
                               scX: 5.0'f32, scY: 5.0'f32)
    let childT  = DbTransform(scX: 1.0'f32, scY: 1.0'f32)
    let a = arm(@[
      bone("root", "", parentT),
      bone("child", "root", childT, inhRo = false, inhSc = false)])
    var bs = boneStates(@[parentT, childT])
    propagateWorldTransforms(a, bs, propagateScratch)
    ## child should behave like an identity relative to parent position
    let v = bs[1].worldMatrix * vec3(1.0'f32, 0.0'f32, 0.0'f32)
    check approxEq(v.x, 1.0'f32)
    check abs(v.y) < Eps
