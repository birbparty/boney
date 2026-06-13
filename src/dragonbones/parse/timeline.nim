## Parse DragonBones animation timelines from 5.5–5.7 JSON.
##
## Exports raw wire types (RawAnimation and all nested types) so armature.nim
## can include animation: seq[RawAnimation] in RawArmature for a single-pass
## jsony parse. Entry point for callers: parseAnimations(raws).

import std/options
import vmath
import dragonbones/model/model

# ── Private color wire type ───────────────────────────────────────────────────

type
  ## Multipliers 0–100 in JSON; model range 0–1 (divided by 100 on parse).
  ## Offsets –255..255 in JSON and model; identity (0.0) matches zero-default.
  RawTimelineColor* = object
    aM*: Option[float32]
    rM*: Option[float32]
    gM*: Option[float32]
    bM*: Option[float32]
    aO*: float32
    rO*: float32
    gO*: float32
    bO*: float32

# ── Wire keyframe types ───────────────────────────────────────────────────────

type
  ## frame position is accumulated across keyframes (sum of previous durations).
  RawTranslateFrame* = object
    duration*: int
    tweenEasing*: Option[float32]  ## None=linear; NaN=stepped; 0=linear; else=quad
    curve*: seq[float32]           ## absent=empty; len==4→bezier; len>4→sampled
    x*: float32                    ## absent → 0.0
    y*: float32                    ## absent → 0.0

  RawRotateFrame* = object
    duration*: int
    tweenEasing*: Option[float32]
    curve*: seq[float32]
    rotate*: float32               ## degrees; absent → 0.0

  RawScaleFrame* = object
    duration*: int
    tweenEasing*: Option[float32]
    curve*: seq[float32]
    x*: Option[float32]            ## scale X; absent → 1.0 (identity)
    y*: Option[float32]            ## scale Y; absent → 1.0 (identity)

  ## Display index keyframe — no tween (discrete switch).
  RawDisplayFrame* = object
    duration*: int
    value*: int                    ## displayIndex; absent → 0; -1 = DisplayIndexHidden

  RawColorFrame* = object
    duration*: int
    tweenEasing*: Option[float32]
    curve*: seq[float32]
    value*: Option[RawTimelineColor]  ## absent → identity color

  RawFFDFrame* = object
    duration*: int
    tweenEasing*: Option[float32]
    curve*: seq[float32]
    offset*: int                   ## vertex index this deform starts at; absent → 0
    vertices*: seq[float32]        ## flat (x0,y0,x1,y1,...) deform offsets; absent→empty

  RawIKFrame* = object
    duration*: int
    tweenEasing*: Option[float32]
    curve*: seq[float32]
    ## DB exporters write bendPositive as 0/1 integers (not JSON booleans).
    ## A boolean in JSON will cause jsony to raise JsonError for the whole parse.
    ## Confirm with a golden 5.7 fixture (boney-93g) before accepting booleans.
    bendPositive*: Option[int]     ## absent → 1 (true)
    weight*: Option[float32]       ## absent → 1.0

  RawZOrderFrame* = object
    duration*: int
    zOrder*: seq[int]              ## flat pairs: [slotIndex0,offset0,slotIndex1,offset1,...]

# ── Wire timeline types ───────────────────────────────────────────────────────

type
  RawBoneTimeline* = object
    name*: string
    translateFrame*: seq[RawTranslateFrame]
    rotateFrame*:    seq[RawRotateFrame]
    scaleFrame*:     seq[RawScaleFrame]

  RawSlotTimeline* = object
    name*: string
    displayFrame*: seq[RawDisplayFrame]
    colorFrame*:   seq[RawColorFrame]

  RawFFDTimeline* = object
    name*: string     ## skin name
    slot*: string     ## slot name
    display*: string  ## display item name within the slot's skin
    frame*: seq[RawFFDFrame]

  RawZOrder* = object
    frame*: seq[RawZOrderFrame]

  RawIKTimeline* = object
    name*: string
    frame*: seq[RawIKFrame]

# ── Public wire animation type (nested in RawArmature in armature.nim) ────────

type
  RawAnimation* = object
    name*: string
    duration*: int              ## absent → 0 (jsony int default; 0-frame anim is degenerate)
    playTimes*: int             ## absent → 0 (jsony int default; 0 = loop forever)
    fadeInTime*: Option[float32]  ## absent → 0.0 via .get(0.0); Option because 0.0 is meaningful
    bone*: seq[RawBoneTimeline]
    slot*: seq[RawSlotTimeline]
    ffd*: seq[RawFFDTimeline]
    zOrder*: Option[RawZOrder]
    ik*: seq[RawIKTimeline]

# ── Helpers ───────────────────────────────────────────────────────────────────

proc parseTween(tweenEasing: Option[float32], curve: seq[float32]): TweenCurve =
  if curve.len == 4:
    return TweenCurve(kind: tkBezier,
                      p1x: curve[0], p1y: curve[1],
                      p2x: curve[2], p2y: curve[3])
  if curve.len > 4:
    return TweenCurve(kind: tkSampled, samples: curve)
  if tweenEasing.isNone:
    return TweenCurve(kind: tkLinear)
  let e = tweenEasing.get()
  if e != e:   # NaN
    return TweenCurve(kind: tkStepped)
  if e == 0.0'f32:
    return TweenCurve(kind: tkLinear)
  TweenCurve(kind: tkQuad, easing: e)

proc toDbColor(c: RawTimelineColor): DbColor =
  template pct(o: Option[float32]): float32 = o.get(100.0'f32) / 100.0'f32
  DbColor(aM: c.aM.pct, rM: c.rM.pct, gM: c.gM.pct, bM: c.bM.pct,
          aO: c.aO, rO: c.rO, gO: c.gO, bO: c.bO)

# ── Timeline conversion ───────────────────────────────────────────────────────

proc toBoneTimelines(raws: seq[RawBoneTimeline]): seq[Timeline] =
  for raw in raws:
    if raw.translateFrame.len > 0:
      var kfs: seq[BoneTranslateKF]
      var frame = 0
      for r in raw.translateFrame:
        kfs.add(BoneTranslateKF(
          base: KeyframeBase(frame: frame, duration: r.duration,
                             curve: parseTween(r.tweenEasing, r.curve)),
          x: r.x, y: r.y))
        frame += r.duration
      result.add(Timeline(name: raw.name, kind: tlBoneTranslate, translateKFs: kfs))

    if raw.rotateFrame.len > 0:
      var kfs: seq[BoneRotateKF]
      var frame = 0
      for r in raw.rotateFrame:
        kfs.add(BoneRotateKF(
          base: KeyframeBase(frame: frame, duration: r.duration,
                             curve: parseTween(r.tweenEasing, r.curve)),
          rotate: r.rotate))
        frame += r.duration
      result.add(Timeline(name: raw.name, kind: tlBoneRotate, rotateKFs: kfs))

    if raw.scaleFrame.len > 0:
      var kfs: seq[BoneScaleKF]
      var frame = 0
      for r in raw.scaleFrame:
        kfs.add(BoneScaleKF(
          base: KeyframeBase(frame: frame, duration: r.duration,
                             curve: parseTween(r.tweenEasing, r.curve)),
          scX: r.x.get(1.0'f32),
          scY: r.y.get(1.0'f32)))
        frame += r.duration
      result.add(Timeline(name: raw.name, kind: tlBoneScale, scaleKFs: kfs))

proc toSlotTimelines(raws: seq[RawSlotTimeline]): seq[Timeline] =
  for raw in raws:
    if raw.displayFrame.len > 0:
      var kfs: seq[SlotDisplayKF]
      var frame = 0
      for r in raw.displayFrame:
        kfs.add(SlotDisplayKF(
          base: KeyframeBase(frame: frame, duration: r.duration,
                             curve: TweenCurve(kind: tkLinear)),
          displayIndex: r.value))
        frame += r.duration
      result.add(Timeline(name: raw.name, kind: tlSlotDisplay, displayKFs: kfs))

    if raw.colorFrame.len > 0:
      var kfs: seq[SlotColorKF]
      var frame = 0
      for r in raw.colorFrame:
        let color = if r.value.isSome: r.value.get().toDbColor()
                    else: dbColorIdentity()
        kfs.add(SlotColorKF(
          base: KeyframeBase(frame: frame, duration: r.duration,
                             curve: parseTween(r.tweenEasing, r.curve)),
          color: color))
        frame += r.duration
      result.add(Timeline(name: raw.name, kind: tlSlotColor, colorKFs: kfs))

proc toFFDTimelines(raws: seq[RawFFDTimeline]): seq[Timeline] =
  for raw in raws:
    var kfs: seq[FFDKeyframe]
    var frame = 0
    for r in raw.frame:
      assert r.vertices.len mod 2 == 0,
        "FFD vertices must be even-length (x,y pairs); got " & $r.vertices.len
      var verts: seq[Vec2]
      var i = 0
      while i + 1 < r.vertices.len:
        verts.add(vec2(r.vertices[i], r.vertices[i + 1]))
        i += 2
      kfs.add(FFDKeyframe(
        base: KeyframeBase(frame: frame, duration: r.duration,
                           curve: parseTween(r.tweenEasing, r.curve)),
        offset: r.offset,
        vertices: verts))
      frame += r.duration
    result.add(Timeline(name: raw.display, kind: tlFFD,
                        ffdSkinName: raw.name,
                        ffdSlotName: raw.slot,
                        ffdDisplayName: raw.display,
                        ffdKFs: kfs))

proc toZOrderTimeline(raw: RawZOrder): Timeline =
  var kfs: seq[ZOrderKeyframe]
  var frame = 0
  for r in raw.frame:
    var offsets: seq[tuple[slotIndex: int, zOffset: int]]
    assert r.zOrder.len mod 2 == 0,
      "zOrder must be even-length (slotIndex,offset pairs); got " & $r.zOrder.len
    var i = 0
    while i + 1 < r.zOrder.len:
      offsets.add((slotIndex: r.zOrder[i], zOffset: r.zOrder[i + 1]))
      i += 2
    kfs.add(ZOrderKeyframe(
      base: KeyframeBase(frame: frame, duration: r.duration,
                         curve: TweenCurve(kind: tkLinear)),
      slotOffsets: offsets))
    frame += r.duration
  Timeline(name: "", kind: tlZOrder, zOrderKFs: kfs)

proc toIKTimelines(raws: seq[RawIKTimeline]): seq[Timeline] =
  for raw in raws:
    var kfs: seq[IKKeyframe]
    var frame = 0
    for r in raw.frame:
      kfs.add(IKKeyframe(
        base: KeyframeBase(frame: frame, duration: r.duration,
                           curve: parseTween(r.tweenEasing, r.curve)),
        bendPositive: r.bendPositive.get(1) != 0,
        weight: r.weight.get(1.0'f32)))
      frame += r.duration
    result.add(Timeline(name: raw.name, kind: tlIK, ikKFs: kfs))

# ── Public API ────────────────────────────────────────────────────────────────

proc parseAnimations*(raws: seq[RawAnimation]): seq[AnimationData] =
  ## Convert jsony-parsed raw animation data into AnimationData.
  ## Called by parseDragonBones in parse/armature.nim.
  for raw in raws:
    var timelines: seq[Timeline]
    timelines.add(toBoneTimelines(raw.bone))
    timelines.add(toSlotTimelines(raw.slot))
    timelines.add(toFFDTimelines(raw.ffd))
    if raw.zOrder.isSome:
      timelines.add(toZOrderTimeline(raw.zOrder.get()))
    timelines.add(toIKTimelines(raw.ik))
    result.add(AnimationData(
      name: raw.name,
      duration: raw.duration,
      playTimes: raw.playTimes,
      fadeInTime: raw.fadeInTime.get(0.0'f32),
      timelines: timelines))
