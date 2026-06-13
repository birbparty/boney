import std/unittest
import dragonbones/model/model
import dragonbones/anim/sample

# ── Helpers ───────────────────────────────────────────────────────────────────

const Eps = 1e-4'f32

proc kfBase(frame, duration: int, curve = TweenCurve(kind: tkLinear)): KeyframeBase =
  KeyframeBase(frame: frame, duration: duration, curve: curve)

proc translateKF(frame, dur: int, x, y: float32,
                  curve = TweenCurve(kind: tkLinear)): BoneTranslateKF =
  BoneTranslateKF(base: kfBase(frame, dur, curve), x: x, y: y)

proc rotateKF(frame, dur: int, r: float32,
               curve = TweenCurve(kind: tkLinear)): BoneRotateKF =
  BoneRotateKF(base: kfBase(frame, dur, curve), rotate: r)

proc scaleKF(frame, dur: int, sx, sy: float32,
              curve = TweenCurve(kind: tkLinear)): BoneScaleKF =
  BoneScaleKF(base: kfBase(frame, dur, curve), scX: sx, scY: sy)

proc displayKF(frame, dur, idx: int): SlotDisplayKF =
  SlotDisplayKF(base: kfBase(frame, dur), displayIndex: idx)

proc colorKF(frame, dur: int, c: DbColor,
              curve = TweenCurve(kind: tkLinear)): SlotColorKF =
  SlotColorKF(base: kfBase(frame, dur, curve), color: c)

proc makeArmData(boneNames: seq[string] = @["root"],
                 slotNames: seq[string] = @[]): ArmatureData =
  var bones: seq[BoneData]
  for n in boneNames:
    bones.add(BoneData(name: n, transform: dbTransformIdentity(),
                       inheritTranslation: true, inheritRotation: true,
                       inheritScale: true, inheritReflection: true))
  var slots: seq[SlotData]
  for n in slotNames:
    slots.add(SlotData(name: n, boneName: "root", color: dbColorIdentity()))
  ArmatureData(name: "A", frameRate: 24, bones: bones, slots: slots)

proc makeAnimData(timelines: seq[Timeline] = @[], duration = 24,
                   playTimes = 0): AnimationData =
  AnimationData(name: "anim", duration: duration, playTimes: playTimes,
                timelines: timelines)

proc makeBones(count = 1): seq[BoneState] =
  newSeq[BoneState](count)

proc makeSlots(count = 0): seq[SlotState] =
  newSeq[SlotState](count)

# ── TweenCurve application ────────────────────────────────────────────────────

suite "sample — applyTweenCurve":

  test "linear: t passes through unchanged":
    let c = TweenCurve(kind: tkLinear)
    check abs(applyTweenCurve(c, 0.0'f32)) < Eps
    check abs(applyTweenCurve(c, 0.5'f32) - 0.5'f32) < Eps
    check abs(applyTweenCurve(c, 1.0'f32) - 1.0'f32) < Eps

  test "stepped: always returns 0 (holds first keyframe)":
    let c = TweenCurve(kind: tkStepped)
    check applyTweenCurve(c, 0.0'f32) == 0.0'f32
    check applyTweenCurve(c, 0.5'f32) == 0.0'f32
    check applyTweenCurve(c, 0.99'f32) == 0.0'f32

  test "quad e=0 is linear":
    let c = TweenCurve(kind: tkQuad, easing: 0.0'f32)
    check abs(applyTweenCurve(c, 0.5'f32) - 0.5'f32) < Eps

  test "quad e>0 is ease-in (t=0.5 < 0.5)":
    let c = TweenCurve(kind: tkQuad, easing: 1.0'f32)
    let result = applyTweenCurve(c, 0.5'f32)
    check result < 0.5'f32   # slow start means we're below linear at midpoint
    check result > 0.0'f32

  test "quad e<0 is ease-out (t=0.5 > 0.5)":
    let c = TweenCurve(kind: tkQuad, easing: -1.0'f32)
    let result = applyTweenCurve(c, 0.5'f32)
    check result > 0.5'f32   # fast start means we're above linear at midpoint
    check result < 1.0'f32

  test "quad endpoints are always 0 and 1":
    for e in [-2.0'f32, -1.0'f32, 0.0'f32, 1.0'f32, 2.0'f32]:
      let c = TweenCurve(kind: tkQuad, easing: e)
      check abs(applyTweenCurve(c, 0.0'f32)) < Eps
      check abs(applyTweenCurve(c, 1.0'f32) - 1.0'f32) < Eps

  test "bezier identity control points gives linear":
    # (p1x=0.333, p1y=0.333, p2x=0.667, p2y=0.667) ≈ linear
    let c = TweenCurve(kind: tkBezier, p1x: 0.333'f32, p1y: 0.333'f32,
                        p2x: 0.667'f32, p2y: 0.667'f32)
    check abs(applyTweenCurve(c, 0.5'f32) - 0.5'f32) < 0.01'f32

  test "bezier endpoints are always 0 and 1":
    let c = TweenCurve(kind: tkBezier, p1x: 0.25'f32, p1y: 0.1'f32,
                        p2x: 0.25'f32, p2y: 1.0'f32)
    check abs(applyTweenCurve(c, 0.0'f32)) < Eps
    check abs(applyTweenCurve(c, 1.0'f32) - 1.0'f32) < Eps

  test "sampled empty falls back to linear":
    let c = TweenCurve(kind: tkSampled, samples: @[])
    check abs(applyTweenCurve(c, 0.5'f32) - 0.5'f32) < Eps

  test "sampled [0,0.5,1] at t=0.5 gives 0.5":
    let c = TweenCurve(kind: tkSampled, samples: @[0.0'f32, 0.5'f32, 1.0'f32])
    check abs(applyTweenCurve(c, 0.5'f32) - 0.5'f32) < Eps

  test "sampled endpoints":
    let c = TweenCurve(kind: tkSampled, samples: @[0.0'f32, 0.25'f32, 0.75'f32, 1.0'f32])
    check abs(applyTweenCurve(c, 0.0'f32)) < Eps
    check abs(applyTweenCurve(c, 1.0'f32) - 1.0'f32) < Eps

# ── Frame resolution ──────────────────────────────────────────────────────────

suite "sample — resolveFrame":

  test "zero time gives frame 0":
    let anim = makeAnimData(duration = 24, playTimes = 0)
    check abs(resolveFrame(anim, 0.0'f32, 24)) < Eps

  test "one second at 24fps gives frame 24 then loops to 0":
    ## duration=24, playTimes=0: at exactly t=1s (frame=24), wraps to 0
    let anim = makeAnimData(duration = 24, playTimes = 0)
    check abs(resolveFrame(anim, 1.0'f32, 24)) < Eps

  test "0.5s at 24fps gives frame 12":
    let anim = makeAnimData(duration = 24, playTimes = 0)
    check abs(resolveFrame(anim, 0.5'f32, 24) - 12.0'f32) < Eps

  test "non-looping holds at last frame":
    ## playTimes=1: after one full play (t≥1s at 24fps over 24 frames), hold at frame 24
    let anim = makeAnimData(duration = 24, playTimes = 1)
    check abs(resolveFrame(anim, 2.0'f32, 24) - 24.0'f32) < Eps

  test "looping past second iteration wraps back":
    let anim = makeAnimData(duration = 24, playTimes = 0)
    ## 1.5s * 24fps = 36 frames; 36 mod 24 = 12
    check abs(resolveFrame(anim, 1.5'f32, 24) - 12.0'f32) < Eps

# ── Bone translate sampling ───────────────────────────────────────────────────

suite "sample — bone translate":

  test "no keyframes: zero offset":
    let arm = makeArmData()
    let anim = makeAnimData()
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.x) < Eps
    check abs(bs[0].localTransform.y) < Eps

  test "single translate keyframe: constant value at any time":
    let tl = Timeline(name: "root", kind: tlBoneTranslate,
                       translateKFs: @[translateKF(0, 24, 10.0'f32, 5.0'f32)])
    let arm = makeArmData()
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.5'f32, bs, ss)
    check abs(bs[0].localTransform.x - 10.0'f32) < Eps

  test "two keyframes linear: midpoint is interpolated":
    ## kf0 at frame 0 x=0, kf1 at frame 24 x=100; at t=0.5s (frame 12) x≈50
    let tl = Timeline(name: "root", kind: tlBoneTranslate,
                       translateKFs: @[
                         translateKF(0, 24, 0.0'f32, 0.0'f32),
                         translateKF(24, 0, 100.0'f32, 0.0'f32)])
    let arm = makeArmData()
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.5'f32, bs, ss)
    check abs(bs[0].localTransform.x - 50.0'f32) < 0.5'f32

  test "translate is additive on rest pose":
    ## rest pose has x=5; translate timeline adds 10 → world x=15
    var arm = makeArmData()
    arm.bones[0].transform.x = 5.0'f32
    let tl = Timeline(name: "root", kind: tlBoneTranslate,
                       translateKFs: @[translateKF(0, 24, 10.0'f32, 0.0'f32)])
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.x - 15.0'f32) < Eps

  test "stepped curve holds first keyframe value":
    let stepped = TweenCurve(kind: tkStepped)
    let tl = Timeline(name: "root", kind: tlBoneTranslate,
                       translateKFs: @[
                         translateKF(0, 12, 0.0'f32, 0.0'f32, stepped),
                         translateKF(12, 12, 100.0'f32, 0.0'f32)])
    let arm = makeArmData()
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.25'f32, bs, ss)  # t=6 frames, in first stepped kf
    check abs(bs[0].localTransform.x) < Eps  # held at 0

# ── Bone rotate sampling ──────────────────────────────────────────────────────

suite "sample — bone rotate":

  test "rotate is additive on rest pose":
    var arm = makeArmData()
    arm.bones[0].transform.skX = 30.0'f32
    arm.bones[0].transform.skY = 30.0'f32
    let tl = Timeline(name: "root", kind: tlBoneRotate,
                       rotateKFs: @[rotateKF(0, 24, 60.0'f32)])
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.skX - 90.0'f32) < Eps
    check abs(bs[0].localTransform.skY - 90.0'f32) < Eps

  test "rotate applies equally to skX and skY":
    let tl = Timeline(name: "root", kind: tlBoneRotate,
                       rotateKFs: @[rotateKF(0, 24, 45.0'f32)])
    let arm = makeArmData()
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.skX - bs[0].localTransform.skY) < Eps

  test "rotate interpolated at midpoint":
    let tl = Timeline(name: "root", kind: tlBoneRotate,
                       rotateKFs: @[
                         rotateKF(0, 24, 0.0'f32),
                         rotateKF(24, 0, 90.0'f32)])
    let arm = makeArmData()
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.5'f32, bs, ss)  # frame 12 of 24
    check abs(bs[0].localTransform.skX - 45.0'f32) < 0.5'f32

# ── Bone scale sampling ───────────────────────────────────────────────────────

suite "sample — bone scale":

  test "scale is multiplicative on rest pose":
    var arm = makeArmData()
    arm.bones[0].transform.scX = 2.0'f32
    arm.bones[0].transform.scY = 3.0'f32
    let tl = Timeline(name: "root", kind: tlBoneScale,
                       scaleKFs: @[scaleKF(0, 24, 0.5'f32, 2.0'f32)])
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.scX - 1.0'f32) < Eps   # 2 * 0.5 = 1
    check abs(bs[0].localTransform.scY - 6.0'f32) < Eps   # 3 * 2.0 = 6

  test "scale identity keyframe (1,1) leaves rest pose unchanged":
    var arm = makeArmData()
    arm.bones[0].transform.scX = 2.5'f32
    arm.bones[0].transform.scY = 0.5'f32
    let tl = Timeline(name: "root", kind: tlBoneScale,
                       scaleKFs: @[scaleKF(0, 24, 1.0'f32, 1.0'f32)])
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.scX - 2.5'f32) < Eps
    check abs(bs[0].localTransform.scY - 0.5'f32) < Eps

# ── Slot display sampling ─────────────────────────────────────────────────────

suite "sample — slot display":

  test "display index steps discretely":
    let tl = Timeline(name: "s0", kind: tlSlotDisplay,
                       displayKFs: @[displayKF(0, 12, 0), displayKF(12, 12, 1)])
    let arm = makeArmData(slotNames = @["s0"])
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots(1)
    sampleAnimation(anim, arm, 0.25'f32, bs, ss)   # frame 6: still kf0
    check ss[0].displayIndex == 0
    sampleAnimation(anim, arm, 0.6'f32, bs, ss)    # frame 14.4: kf1
    check ss[0].displayIndex == 1

  test "slot initialised from armature default when no timeline":
    var arm = makeArmData(slotNames = @["s0"])
    arm.slots[0].displayIndex = 3
    let anim = makeAnimData()
    var bs = makeBones(); var ss = makeSlots(1)
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check ss[0].displayIndex == 3

# ── Slot color sampling ───────────────────────────────────────────────────────

suite "sample — slot color":

  test "color lerps at midpoint":
    let c0 = DbColor(aM: 1.0'f32, rM: 0.0'f32, gM: 0.0'f32, bM: 0.0'f32,
                     aO: 0.0'f32, rO: 0.0'f32, gO: 0.0'f32, bO: 0.0'f32)
    let c1 = DbColor(aM: 1.0'f32, rM: 1.0'f32, gM: 0.0'f32, bM: 0.0'f32,
                     aO: 0.0'f32, rO: 0.0'f32, gO: 0.0'f32, bO: 0.0'f32)
    let tl = Timeline(name: "s0", kind: tlSlotColor,
                       colorKFs: @[colorKF(0, 24, c0), colorKF(24, 0, c1)])
    let arm = makeArmData(slotNames = @["s0"])
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots(1)
    sampleAnimation(anim, arm, 0.5'f32, bs, ss)  # frame 12 of 24
    check abs(ss[0].color.rM - 0.5'f32) < 0.01'f32

# ── Rest pose when no timelines ───────────────────────────────────────────────

suite "sample — rest pose initialisation":

  test "no timelines: bone at rest pose":
    var arm = makeArmData()
    arm.bones[0].transform = DbTransform(x: 7.0'f32, y: 3.0'f32,
                                          skX: 15.0'f32, skY: 15.0'f32,
                                          scX: 2.0'f32, scY: 0.5'f32)
    let anim = makeAnimData()
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.5'f32, bs, ss)
    let t = bs[0].localTransform
    check abs(t.x   - 7.0'f32)  < Eps
    check abs(t.y   - 3.0'f32)  < Eps
    check abs(t.skX - 15.0'f32) < Eps
    check abs(t.scX - 2.0'f32)  < Eps
    check abs(t.scY - 0.5'f32)  < Eps

  test "unknown bone name in timeline is silently ignored":
    let tl = Timeline(name: "nonexistent", kind: tlBoneTranslate,
                       translateKFs: @[translateKF(0, 24, 999.0'f32, 0.0'f32)])
    let arm = makeArmData()
    let anim = makeAnimData(timelines = @[tl])
    var bs = makeBones(); var ss = makeSlots()
    sampleAnimation(anim, arm, 0.0'f32, bs, ss)
    check abs(bs[0].localTransform.x) < Eps   # root unchanged
