## Tests for anim/ik.nim — IK constraint solver.

import std/unittest
import std/math
import vmath
import dragonbones/model/model
import dragonbones/anim/sample
import dragonbones/anim/propagate
import dragonbones/anim/ik

# ── Helpers ───────────────────────────────────────────────────────────────────

proc mkBone(name, parent: string, x, y, length: float32): BoneData =
  BoneData(name: name, parentName: parent, length: length,
           transform: DbTransform(x: x, y: y, scX: 1.0'f32, scY: 1.0'f32),
           inheritTranslation: true, inheritRotation: true,
           inheritScale: true, inheritReflection: true)

proc mkIK(name, boneName, targetName: string, chain, order: int,
           bendPositive = true, weight = 1.0'f32): IKConstraintData =
  IKConstraintData(name: name, boneName: boneName, targetName: targetName,
                   chain: chain, order: order, bendPositive: bendPositive, weight: weight)

proc mkArm(bones: seq[BoneData], iks: seq[IKConstraintData] = @[]): ArmatureData =
  ArmatureData(name: "Test", frameRate: 24, bones: bones, slots: @[], skins: @[],
               animations: @[], ikConstraints: iks, defaultActions: @[])

proc emptyAnim(): AnimationData =
  AnimationData(name: "idle", duration: 24, playTimes: 0)

proc setupPose(armData: ArmatureData): (seq[BoneState], seq[SlotState], seq[DbTransform]) =
  ## Run sampleAnimation + propagateWorldTransforms to establish initial pose.
  var bones = newSeq[BoneState](armData.bones.len)
  var slots = newSeq[SlotState](0)
  var worldT = newSeq[DbTransform](armData.bones.len)
  sampleAnimation(emptyAnim(), armData, 0.0'f32, bones, slots)
  propagateWorldTransforms(armData, bones, worldT)
  (bones, slots, worldT)

const Eps = 0.5'f32  ## tolerance for floating-point IK positions

proc boneWorldPos(worldT: seq[DbTransform], idx: int): Vec2 =
  vec2(worldT[idx].x, worldT[idx].y)

proc boneTip(worldT: seq[DbTransform], boneData: seq[BoneData], idx: int): Vec2 =
  let rotRad = worldT[idx].skX * float32(PI / 180.0)
  vec2(worldT[idx].x + boneData[idx].length * cos(rotRad),
       worldT[idx].y + boneData[idx].length * sin(rotRad))

# ── No-op cases ───────────────────────────────────────────────────────────────

suite "applyIKConstraints — no-op cases":

  test "no constraints: bones unchanged":
    ## Bone A facing right, no IK. Rotation should stay 0.
    let arm = mkArm(@[mkBone("a", "", 0, 0, 100)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check abs(bones[0].localTransform.skX) < Eps

  test "weight=0: bones unchanged":
    let bones_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let arm = mkArm(bones_arr, @[mkIK("ik", "a", "t", 0, 0, weight = 0.0'f32)])
    var (bones, slots, worldT) = setupPose(arm)
    let origRot = bones[0].localTransform.skX
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check abs(bones[0].localTransform.skX - origRot) < Eps

# ── One-bone IK ───────────────────────────────────────────────────────────────

suite "applyIKConstraints — one-bone IK":

  test "arm facing right, target directly above: rotates to 90 deg":
    ## Bone A at (0,0) facing right (skX=0), target at (0,100).
    ## Expected: A points upward (world rot ~90°).
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "a", "t", 0, 0)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check abs(worldT[0].skX - 90.0'f32) < Eps

  test "one-bone IK: tip reaches target position":
    ## After IK, bone A's tip should be near target origin (0, 100).
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "a", "t", 0, 0)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    let tip = boneTip(worldT, arm.bones, 0)
    check abs(tip.x - 0.0'f32) < Eps
    check abs(tip.y - 100.0'f32) < Eps

  test "one-bone IK: target to the right, already facing right — no change":
    ## Bone at (0,0) facing right, target at (100,0) — already aligned.
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 100, 0, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "a", "t", 0, 0)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check abs(worldT[0].skX - 0.0'f32) < Eps

  test "one-bone IK weight=0.5: partial rotation":
    ## Bone facing right, target directly above. Half weight → ~45° rotation.
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "a", "t", 0, 0, weight = 0.5'f32)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check worldT[0].skX > 40.0'f32 and worldT[0].skX < 50.0'f32

  test "one-bone IK: child bone with parent":
    ## Parent at (0,0), child at (100,0), target at (100,100).
    ## Child should rotate to face (100,100) from (100,0): 90° world, 90° local.
    let bone_arr = @[mkBone("parent", "", 0, 0, 100),
                     mkBone("child", "parent", 100, 0, 80),
                     mkBone("target", "", 100, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "child", "target", 0, 0)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    ## child's world position unchanged (translation is from parent origin only)
    check abs(worldT[1].x - 100.0'f32) < Eps
    check abs(worldT[1].y - 0.0'f32) < Eps
    ## child's world rotation should now be 90°
    check abs(worldT[1].skX - 90.0'f32) < Eps
    ## child tip should be at target (100, 100) ← (100,0) + 80*(0,1)
    let tip = boneTip(worldT, arm.bones, 1)
    check abs(tip.x - 100.0'f32) < Eps
    check abs(tip.y - 80.0'f32) < Eps  ## child length=80, target y=100, from y=0 → tip at y=80

# ── Two-bone IK ───────────────────────────────────────────────────────────────

suite "applyIKConstraints — two-bone IK":

  test "two-bone IK: tip reaches target":
    ## Shoulder at (0,0) len=100, elbow at (100,0) len=100 (local x=100).
    ## Target at (100,100). Both bend solutions should place tip at (100,100).
    let bone_arr = @[mkBone("shoulder", "", 0, 0, 100),
                     mkBone("elbow", "shoulder", 100, 0, 100),
                     mkBone("target", "", 100, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "elbow", "target", 1, 0, bendPositive = false)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    let tip = boneTip(worldT, arm.bones, 1)
    check abs(tip.x - 100.0'f32) < Eps
    check abs(tip.y - 100.0'f32) < Eps

  test "two-bone IK: bendPositive=false gives different elbow than true":
    ## Same bones + target; the two bend solutions give different shoulder angles.
    let bone_arr = @[mkBone("shoulder", "", 0, 0, 100),
                     mkBone("elbow", "shoulder", 100, 0, 100),
                     mkBone("target", "", 100, 100, 0)]
    let arm_neg = mkArm(bone_arr, @[mkIK("ik", "elbow", "target", 1, 0, bendPositive = false)])
    let arm_pos = mkArm(bone_arr, @[mkIK("ik", "elbow", "target", 1, 0, bendPositive = true)])
    var (bonesNeg, slotsNeg, worldNeg) = setupPose(arm_neg)
    var (bonesPos, slotsPos, worldPos) = setupPose(arm_pos)
    applyIKConstraints(emptyAnim(), arm_neg, 0.0'f32, bonesNeg, worldNeg)
    applyIKConstraints(emptyAnim(), arm_pos, 0.0'f32, bonesPos, worldPos)
    ## Shoulder angles should differ (one above, one below)
    check abs(worldNeg[0].skX - worldPos[0].skX) > 10.0'f32
    ## But both tips reach (100, 100)
    let tipNeg = boneTip(worldNeg, arm_neg.bones, 1)
    let tipPos = boneTip(worldPos, arm_pos.bones, 1)
    check abs(tipNeg.x - 100.0'f32) < Eps
    check abs(tipNeg.y - 100.0'f32) < Eps
    check abs(tipPos.x - 100.0'f32) < Eps
    check abs(tipPos.y - 100.0'f32) < Eps

  test "two-bone IK: out of reach clamps to full extension":
    ## Target at (250,0), but shoulder len=100 + elbow len=80 = 180 max.
    ## Should extend fully toward target (both pointing right: rot ≈ 0°).
    let bone_arr = @[mkBone("shoulder", "", 0, 0, 100),
                     mkBone("elbow", "shoulder", 100, 0, 80),
                     mkBone("target", "", 250, 0, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "elbow", "target", 1, 0, bendPositive = false)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    ## shoulder faces right (0°), elbow also faces right (0° relative to shoulder)
    check abs(worldT[0].skX - 0.0'f32) < Eps
    check abs(worldT[1].skX - 0.0'f32) < Eps

  test "two-bone IK weight=0: bones unchanged":
    let bone_arr = @[mkBone("shoulder", "", 0, 0, 100),
                     mkBone("elbow", "shoulder", 100, 0, 100),
                     mkBone("target", "", 100, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "elbow", "target", 1, 0,
                                     bendPositive = false, weight = 0.0'f32)])
    var (bones, slots, worldT) = setupPose(arm)
    let origSh = bones[0].localTransform.skX
    let origEl = bones[1].localTransform.skX
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check abs(bones[0].localTransform.skX - origSh) < Eps
    check abs(bones[1].localTransform.skX - origEl) < Eps

  test "two-bone IK weight=0.5: partial reach":
    ## Partial weight — elbow tip should be between rest and full IK target.
    let bone_arr = @[mkBone("shoulder", "", 0, 0, 100),
                     mkBone("elbow", "shoulder", 100, 0, 100),
                     mkBone("target", "", 100, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "elbow", "target", 1, 0,
                                     bendPositive = false, weight = 0.5'f32)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    ## shoulder should rotate somewhat (more than 0, less than full IK)
    let shoulderRot = worldT[0].skX
    check shoulderRot > 5.0'f32 and shoulderRot < 80.0'f32

# ── IK animation timeline ─────────────────────────────────────────────────────

suite "applyIKConstraints — IK timeline override":

  test "IK timeline weight=0.0 overrides static weight=1.0":
    ## Constraint has weight=1, but timeline keyframe says weight=0 at frame 0.
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let ik = mkIK("myIK", "a", "t", 0, 0, weight = 1.0'f32)
    let kf = IKKeyframe(base: KeyframeBase(frame: 0, duration: 24,
                                            curve: TweenCurve(kind: tkLinear)),
                         bendPositive: true, weight: 0.0'f32)
    let animWithIK = AnimationData(name: "idle", duration: 24, playTimes: 0,
                                    timelines: @[Timeline(name: "myIK", kind: tlIK,
                                                           ikKFs: @[kf])])
    let arm = mkArm(bone_arr, @[ik])
    var (bones, slots, worldT) = setupPose(arm)
    let origRot = bones[0].localTransform.skX
    applyIKConstraints(animWithIK, arm, 0.0'f32, bones, worldT)
    check abs(bones[0].localTransform.skX - origRot) < Eps

  test "IK timeline weight=1.0 produces full IK solve":
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let ik = mkIK("myIK", "a", "t", 0, 0, weight = 0.0'f32)  ## static says 0
    let kf = IKKeyframe(base: KeyframeBase(frame: 0, duration: 24,
                                            curve: TweenCurve(kind: tkLinear)),
                         bendPositive: true, weight: 1.0'f32)  ## timeline says 1
    let animWithIK = AnimationData(name: "idle", duration: 24, playTimes: 0,
                                    timelines: @[Timeline(name: "myIK", kind: tlIK,
                                                           ikKFs: @[kf])])
    let arm = mkArm(bone_arr, @[ik])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(animWithIK, arm, 0.0'f32, bones, worldT)
    check abs(worldT[0].skX - 90.0'f32) < Eps

# ── Constraint ordering ───────────────────────────────────────────────────────

suite "applyIKConstraints — ordering":

  test "higher-order constraint processes last":
    ## Two independent constraints; ordering must not affect final result
    ## when constraints don't interact.
    let bone_arr = @[mkBone("a", "", 0, 0, 100),
                     mkBone("ta", "", 0, 100, 0),
                     mkBone("b", "", 200, 0, 100),
                     mkBone("tb", "", 200, 100, 0)]
    let iks = @[mkIK("ik_a", "a", "ta", 0, 1),   ## order 1 processes second
                mkIK("ik_b", "b", "tb", 0, 0)]    ## order 0 processes first
    let arm = mkArm(bone_arr, iks)
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    check abs(worldT[0].skX - 90.0'f32) < Eps  ## a points up
    check abs(worldT[2].skX - 90.0'f32) < Eps  ## b also points up

# ── worldMatrix is updated ────────────────────────────────────────────────────

suite "applyIKConstraints — worldMatrix updated":

  test "bones[i].worldMatrix reflects IK after call":
    let bone_arr = @[mkBone("a", "", 0, 0, 100), mkBone("t", "", 0, 100, 0)]
    let arm = mkArm(bone_arr, @[mkIK("ik", "a", "t", 0, 0)])
    var (bones, slots, worldT) = setupPose(arm)
    applyIKConstraints(emptyAnim(), arm, 0.0'f32, bones, worldT)
    ## After IK, worldMatrix should be a rotation matrix for ~90 degrees.
    ## Col0.x = scX * cos(skY) ≈ 1 * cos(90°) ≈ 0.
    let m00 = bones[0].worldMatrix[0][0]  ## col-major: col0.x
    check abs(m00) < 0.1'f32              ## cos(90°) ≈ 0
