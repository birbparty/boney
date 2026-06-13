import std/unittest
import dragonbones/model/model
import dragonbones/anim/blend

# ── Helpers ───────────────────────────────────────────────────────────────────

const EPS = 1e-5'f32

proc approx(a, b: float32): bool = abs(a - b) < EPS

proc kfBase(frame, dur: int, curve = TweenCurve(kind: tkLinear)): KeyframeBase =
  KeyframeBase(frame: frame, duration: dur, curve: curve)

proc rotKF(frame, dur: int, r: float32): BoneRotateKF =
  BoneRotateKF(base: kfBase(frame, dur), rotate: r)

proc txKF(frame, dur: int, x, y: float32): BoneTranslateKF =
  BoneTranslateKF(base: kfBase(frame, dur), x: x, y: y)

proc scKF(frame, dur: int, sx, sy: float32): BoneScaleKF =
  BoneScaleKF(base: kfBase(frame, dur), scX: sx, scY: sy)

proc colorKF(frame, dur: int, c: DbColor): SlotColorKF =
  SlotColorKF(base: kfBase(frame, dur), color: c)

proc dispKF(frame, dur, idx: int): SlotDisplayKF =
  SlotDisplayKF(base: kfBase(frame, dur), displayIndex: idx)

proc mkArmature(numBones, numSlots: int): ArmatureData =
  result.frameRate = 24
  result.name = "test"
  for i in 0 ..< numBones:
    result.bones.add(BoneData(name: "bone" & $i,
                               transform: dbTransformIdentity()))
  for i in 0 ..< numSlots:
    result.slots.add(SlotData(name: "slot" & $i, boneName: "bone0",
                               color: dbColorIdentity()))

proc mkRotAnim(rotateDeg: float32): AnimationData =
  ## Single constant-delta keyframe on bone0: always returns rotateDeg,
  ## independent of playback time. Good for blend-weight tests.
  AnimationData(
    name: "rot", duration: 24, playTimes: 0,
    timelines: @[Timeline(
      name: "bone0", kind: tlBoneRotate,
      rotateKFs: @[rotKF(0, 24, rotateDeg)])])

proc mkRotAnimInterp(endDeg: float32): AnimationData =
  ## Two-KF animation: bone0 rotates from 0°→endDeg over 24 frames.
  ## At frame F, delta = lerp(0, endDeg, F/24). Use for time-sampling tests.
  AnimationData(
    name: "interp", duration: 24, playTimes: 0,
    timelines: @[Timeline(
      name: "bone0", kind: tlBoneRotate,
      rotateKFs: @[rotKF(0, 24, 0.0'f32), rotKF(24, 0, endDeg)])])

proc newBones(n: int): seq[BoneState] = newSeq[BoneState](n)
proc newSlots(n: int): seq[SlotState] = newSeq[SlotState](n)

# ── Weight boundary values ────────────────────────────────────────────────────

suite "crossfadeAnimations — weight boundary values":

  test "weight=0 → pure animA":
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(30.0'f32), 0.0'f32,
      mkRotAnim(90.0'f32), 0.0'f32,
      0.0'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 30.0'f32)

  test "weight=1 → pure animB":
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(30.0'f32), 0.0'f32,
      mkRotAnim(90.0'f32), 0.0'f32,
      1.0'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 90.0'f32)

  test "weight=0 identity anims: bone at rest pose":
    let arm = mkArmature(2, 0)
    var bones = newBones(2); var slots = newSlots(0)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(0.0'f32), 0.0'f32,
      mkRotAnim(0.0'f32), 0.0'f32,
      0.0'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 0.0'f32)
    check approx(bones[0].localTransform.scX, 1.0'f32)

# ── Lerp math: rotation, translation, scale ───────────────────────────────────

suite "crossfadeAnimations — lerp math":

  test "rotation: weight=0.5 gives midpoint angle":
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(0.0'f32), 0.0'f32,
      mkRotAnim(90.0'f32), 0.0'f32,
      0.5'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 45.0'f32)

  test "rotation: weight=0.25 gives 25% blend":
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(0.0'f32), 0.0'f32,
      mkRotAnim(80.0'f32), 0.0'f32,
      0.25'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 20.0'f32)

  test "translation: x lerped from 10 to 30 at weight=0.5":
    let arm = mkArmature(1, 0)
    let animA = AnimationData(name: "A", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "bone0", kind: tlBoneTranslate,
        translateKFs: @[txKF(0, 24, 10.0'f32, 0.0'f32)])])
    let animB = AnimationData(name: "B", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "bone0", kind: tlBoneTranslate,
        translateKFs: @[txKF(0, 24, 30.0'f32, 0.0'f32)])])
    var bones = newBones(1); var slots = newSlots(0)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm, animA, 0.0'f32, animB, 0.0'f32,
                        0.5'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.x, 20.0'f32)

  test "scale: weight=0.5 lerps between post-rest-multiply scale values":
    ## arm rest scX=1.0; animA kf scX=2.0 → effective 1*2=2; animB kf scX=4.0
    ## → effective 1*4=4. lerp(2, 4, 0.5) = 3.0.
    let arm = mkArmature(1, 0)
    let animA = AnimationData(name: "A", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "bone0", kind: tlBoneScale,
        scaleKFs: @[scKF(0, 24, 2.0'f32, 1.0'f32)])])
    let animB = AnimationData(name: "B", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "bone0", kind: tlBoneScale,
        scaleKFs: @[scKF(0, 24, 4.0'f32, 1.0'f32)])])
    var bones = newBones(1); var slots = newSlots(0)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm, animA, 0.0'f32, animB, 0.0'f32,
                        0.5'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.scX, 3.0'f32)

# ── Slot blending ─────────────────────────────────────────────────────────────

suite "crossfadeAnimations — slot blending":

  test "color: weight=0.5 lerps alpha multiplier":
    let arm = mkArmature(1, 1)
    let animA = AnimationData(name: "A", duration: 24)
    let animB = AnimationData(name: "B", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "slot0", kind: tlSlotColor,
        colorKFs: @[colorKF(0, 24,
          DbColor(aM: 0.0'f32, rM: 1.0'f32, gM: 1.0'f32, bM: 1.0'f32))])])
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm, animA, 0.0'f32, animB, 0.0'f32,
                        0.5'f32, bones, slots, sb, ss)
    check approx(slots[0].color.aM, 0.5'f32)  ## lerp(1.0, 0.0, 0.5)
    check approx(slots[0].color.rM, 1.0'f32)  ## no change

  test "displayIndex: weight<0.5 keeps animA index":
    let arm = mkArmature(1, 1)
    let animA = AnimationData(name: "A", duration: 24)
    let animB = AnimationData(name: "B", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "slot0", kind: tlSlotDisplay,
        displayKFs: @[dispKF(0, 24, 2)])])
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm, animA, 0.0'f32, animB, 0.0'f32,
                        0.4'f32, bones, slots, sb, ss)
    check slots[0].displayIndex == 0  ## animA's index (rest pose default)

  test "displayIndex: weight>=0.5 takes animB index":
    let arm = mkArmature(1, 1)
    let animA = AnimationData(name: "A", duration: 24)
    let animB = AnimationData(name: "B", duration: 24, playTimes: 0,
      timelines: @[Timeline(name: "slot0", kind: tlSlotDisplay,
        displayKFs: @[dispKF(0, 24, 2)])])
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm, animA, 0.0'f32, animB, 0.0'f32,
                        0.5'f32, bones, slots, sb, ss)
    check slots[0].displayIndex == 2  ## animB's index

# ── Independent times ─────────────────────────────────────────────────────────

suite "crossfadeAnimations — independent times":

  test "each animation sampled at its own time":
    ## animA: two-KF 0→90° over 24 frames. At timeA=0.5s (frame 12) → 45°.
    ## animB: constant 0°. weight=0 → pure A at 45°.
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnimInterp(90.0'f32), 0.5'f32,
      mkRotAnim(0.0'f32),        0.0'f32,
      0.0'f32, bones, slots, sb, ss)
    ## frame=0.5*24=12, tween 12/24=0.5, rotate: lerp(0,90,0.5)=45
    check approx(bones[0].localTransform.skX, 45.0'f32)

  test "blend of two mid-frame samples":
    ## animA at frame 12 = 45°; animB at frame 18 = 67.5°. lerp(45,67.5,0.5)=56.25.
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnimInterp(90.0'f32), 0.5'f32,
      mkRotAnimInterp(90.0'f32), 0.75'f32,
      0.5'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 56.25'f32)

# ── Scratch buffer management ─────────────────────────────────────────────────

suite "crossfadeAnimations — scratch management":

  test "empty scratch buffers auto-grow":
    let arm = mkArmature(3, 2)
    var bones = newBones(3); var slots = newSlots(2)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(30.0'f32), 0.0'f32,
      mkRotAnim(60.0'f32), 0.0'f32,
      0.5'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 45.0'f32)
    check sb.len >= 3
    check ss.len >= 2

  test "pre-sized scratch buffers are not reallocated":
    let arm = mkArmature(2, 1)
    var bones = newBones(2); var slots = newSlots(1)
    var sb = newBones(2);    var ss = newSlots(1)
    let pBefore = addr sb[0]
    crossfadeAnimations(arm,
      mkRotAnim(10.0'f32), 0.0'f32,
      mkRotAnim(50.0'f32), 0.0'f32,
      0.5'f32, bones, slots, sb, ss)
    let pAfter = addr sb[0]
    check approx(bones[0].localTransform.skX, 30.0'f32)
    check pBefore == pAfter

  test "output reuse: second call overwrites first result":
    let arm = mkArmature(1, 1)
    var bones = newBones(1); var slots = newSlots(1)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    crossfadeAnimations(arm,
      mkRotAnim(20.0'f32), 0.0'f32,
      mkRotAnim(60.0'f32), 0.0'f32,
      0.5'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 40.0'f32)
    crossfadeAnimations(arm,
      mkRotAnim(20.0'f32), 0.0'f32,
      mkRotAnim(60.0'f32), 0.0'f32,
      1.0'f32, bones, slots, sb, ss)
    check approx(bones[0].localTransform.skX, 60.0'f32)

  test "undersized bones output: doAssert fires":
    let arm = mkArmature(3, 0)
    var bones = newBones(2)  ## wrong size
    var slots = newSlots(0)
    var sb: seq[BoneState]; var ss: seq[SlotState]
    expect AssertionDefect:
      crossfadeAnimations(arm,
        mkRotAnim(0.0'f32), 0.0'f32,
        mkRotAnim(0.0'f32), 0.0'f32,
        0.5'f32, bones, slots, sb, ss)
