## Tests for anim/events.nim — collectEvents fire-once semantics.

import std/unittest
import dragonbones/model/model
import dragonbones/anim/events

# ── Helpers ───────────────────────────────────────────────────────────────────

proc mkAnim(duration, playTimes: int, eventKFs: seq[EventKeyframe] = @[]): AnimationData =
  AnimationData(name: "test", duration: duration, playTimes: playTimes,
                fadeInTime: 0.0'f32, timelines: @[], eventKFs: eventKFs)

proc mkFrameKF(frame: int, name: string): EventKeyframe =
  EventKeyframe(frame: frame,
                frameEvents: @[FrameEventData(name: name)],
                soundEvents: @[], actionEvents: @[])

proc mkSoundKF(frame: int, name: string): EventKeyframe =
  EventKeyframe(frame: frame,
                frameEvents: @[], soundEvents: @[SoundEventData(name: name)],
                actionEvents: @[])

proc mkActionKF(frame: int, animName: string): EventKeyframe =
  EventKeyframe(frame: frame,
                frameEvents: @[], soundEvents: @[],
                actionEvents: @[ActionEventData(name: animName, boneName: "")])

proc frameNames(events: seq[AnimEvent]): seq[string] =
  for e in events:
    if e.kind == ekFrame: result.add(e.frameData.name)

proc soundNames(events: seq[AnimEvent]): seq[string] =
  for e in events:
    if e.kind == ekSound: result.add(e.soundData.name)

proc actionNames(events: seq[AnimEvent]): seq[string] =
  for e in events:
    if e.kind == ekAction: result.add(e.actionData.name)

const fps = 24
const frameDt = 1.0'f32 / float32(fps)  ## one frame in seconds

# ── No events / empty cases ───────────────────────────────────────────────────

suite "collectEvents — empty and no-op cases":

  test "no eventKFs returns empty output":
    let anim = mkAnim(24, 0)
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, -frameDt, 0.0'f32, evts)
    check evts.len == 0

  test "zero-duration animation returns empty":
    let anim = mkAnim(0, 0, @[mkFrameKF(0, "e")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, -frameDt, 0.0'f32, evts)
    check evts.len == 0

  test "currTime <= prevTime returns empty":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "e")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 0.5'f32, 0.3'f32, evts)
    check evts.len == 0

  test "same prevTime and currTime returns empty":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "e")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 5.0'f32 / float32(fps), 5.0'f32 / float32(fps), evts)
    check evts.len == 0

# ── Frame-0 event on first update ─────────────────────────────────────────────

suite "collectEvents — frame-0 semantics":

  test "frame-0 event fires when prevTime is negative (first update pattern)":
    let anim = mkAnim(24, 0, @[mkFrameKF(0, "start")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, -frameDt, 0.0'f32, evts)
    check frameNames(evts) == @["start"]

  test "frame-0 event does NOT fire when prevTime == 0":
    ## prevTime = currTime = 0 means currRaw <= prevRaw, so nothing fires.
    let anim = mkAnim(24, 0, @[mkFrameKF(0, "start")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 0.0'f32, 0.0'f32, evts)
    check evts.len == 0

  test "frame-0 fires exactly once across the (prevTime=-1/fps, currTime=0) step":
    let anim = mkAnim(24, 0, @[mkFrameKF(0, "start"), mkFrameKF(1, "next")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, -frameDt, 0.0'f32, evts)
    check frameNames(evts) == @["start"]  # only frame 0, not frame 1

# ── Mid-animation events ───────────────────────────────────────────────────────

suite "collectEvents — mid-animation events":

  test "event at frame 5 fires when playhead crosses it":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "step")])
    var evts: seq[AnimEvent]
    ## prevRaw = 4, currRaw = 6 → frame 5 in (4, 6]
    collectEvents(anim, fps,
                  4.0'f32 / float32(fps),
                  6.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["step"]

  test "event at frame 5 does not fire when not yet reached":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "step")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  0.0'f32,
                  4.0'f32 / float32(fps), evts)
    check evts.len == 0

  test "event at frame 5 does not fire when already past":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "step")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  5.0'f32 / float32(fps),
                  8.0'f32 / float32(fps), evts)
    check evts.len == 0  ## frame 5 is at prevTime boundary — exclusive lower bound

  test "multiple events fire when playhead crosses all of them":
    let kfs = @[mkFrameKF(3, "a"), mkFrameKF(7, "b"), mkFrameKF(10, "c")]
    let anim = mkAnim(24, 0, kfs)
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  2.0'f32 / float32(fps),
                  10.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["a", "b", "c"]

  test "events outside the window do not fire":
    let kfs = @[mkFrameKF(2, "before"), mkFrameKF(5, "in"), mkFrameKF(10, "after")]
    let anim = mkAnim(24, 0, kfs)
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  2.0'f32 / float32(fps),
                  7.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["in"]  # frame 2 excluded (at prev boundary); frame 10 not reached

# ── Loop semantics (playTimes == 0) ───────────────────────────────────────────

suite "collectEvents — looping animation":

  test "no double-fire at loop boundary: event near end fires once":
    ## Event at frame 23 in a 24-frame loop. Playhead goes from frame 22 to frame 1 of next loop.
    let anim = mkAnim(24, 0, @[mkFrameKF(23, "tail")])
    var evts: seq[AnimEvent]
    ## prevRaw = 22, currRaw = 25 → crosses loop at 24
    collectEvents(anim, fps,
                  22.0'f32 / float32(fps),
                  25.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["tail"]  # fires once, not twice

  test "frame-0 event fires at loop restart":
    ## Event at frame 0. Animation loops from frame 23 to frame 1 of next loop.
    let anim = mkAnim(24, 0, @[mkFrameKF(0, "loopStart")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  22.0'f32 / float32(fps),
                  25.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["loopStart"]  # fires at loop boundary crossing

  test "tail and head events both fire at loop crossing":
    let kfs = @[mkFrameKF(0, "head"), mkFrameKF(23, "tail")]
    let anim = mkAnim(24, 0, kfs)
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  22.0'f32 / float32(fps),
                  25.0'f32 / float32(fps), evts)
    ## tail fires first (it's at end of old loop), head fires second (new loop)
    check frameNames(evts) == @["tail", "head"]

  test "events in the middle of each loop only fire within their respective half-open window":
    let kfs = @[mkFrameKF(5, "mid"), mkFrameKF(18, "late")]
    let anim = mkAnim(24, 0, kfs)
    var evts: seq[AnimEvent]
    ## Window covers frame 20 of loop N to frame 8 of loop N+1
    ## → late(18) NOT in (20, 24], mid(5) IS in (-1, 8]
    collectEvents(anim, fps,
                  20.0'f32 / float32(fps),
                  32.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["mid"]  # "late" missed; "mid" fires in new loop

  test "no-loop crossing: normal window, no special handling":
    let anim = mkAnim(24, 0, @[mkFrameKF(10, "mid")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  8.0'f32 / float32(fps),
                  12.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["mid"]

# ── Finite-play semantics (playTimes > 0) ────────────────────────────────────

suite "collectEvents — finite-play animation":

  test "single-play: event fires normally":
    let anim = mkAnim(24, 1, @[mkFrameKF(10, "e")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps,
                  9.0'f32 / float32(fps),
                  11.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["e"]

  test "single-play: event doesn't fire after animation ends":
    let anim = mkAnim(24, 1, @[mkFrameKF(10, "e")])
    var evts: seq[AnimEvent]
    ## time well past the end (duration=24 frames = 1.0s at 24fps)
    collectEvents(anim, fps, 1.1'f32, 1.5'f32, evts)
    check evts.len == 0

  test "two-play: event fires once per play":
    ## Event at frame 5 in a 24-frame, 2-play animation. Should fire at t=5/24 and t=29/24.
    let anim = mkAnim(24, 2, @[mkFrameKF(5, "e")])
    var evts: seq[AnimEvent]
    ## First firing (play 1, frame 5)
    collectEvents(anim, fps,
                  4.0'f32 / float32(fps),
                  6.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["e"]
    evts.setLen(0)
    ## Second firing (play 2, frame 5 = raw frame 29)
    collectEvents(anim, fps,
                  28.0'f32 / float32(fps),
                  30.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["e"]

  test "frame-0 event fires at start of each play in multi-play":
    let anim = mkAnim(24, 2, @[mkFrameKF(0, "start")])
    var evts: seq[AnimEvent]
    ## First play: prevTime = -1/fps → frame 0 fires
    collectEvents(anim, fps, -frameDt, 0.0'f32, evts)
    check frameNames(evts) == @["start"]
    evts.setLen(0)
    ## Second play boundary: crossing from frame 23 of play 1 to frame 1 of play 2
    collectEvents(anim, fps,
                  22.0'f32 / float32(fps),
                  25.0'f32 / float32(fps), evts)
    check frameNames(evts) == @["start"]

# ── Event type dispatch ────────────────────────────────────────────────────────

suite "collectEvents — event types":

  test "frame events are collected with correct data":
    let kf = EventKeyframe(
      frame: 5,
      frameEvents: @[FrameEventData(name: "hit", boneName: "weapon",
                                     ints: @[42], floats: @[1.5'f32],
                                     strings: @["left"])],
      soundEvents: @[], actionEvents: @[])
    let anim = mkAnim(24, 0, @[kf])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 4.0'f32 / float32(fps), 6.0'f32 / float32(fps), evts)
    check evts.len == 1
    check evts[0].kind == ekFrame
    check evts[0].frameData.name == "hit"
    check evts[0].frameData.boneName == "weapon"
    check evts[0].frameData.ints == @[42]
    check evts[0].frameData.floats == @[1.5'f32]
    check evts[0].frameData.strings == @["left"]

  test "sound events are collected with correct name":
    let anim = mkAnim(24, 0, @[mkSoundKF(3, "swoosh.wav")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 2.0'f32 / float32(fps), 4.0'f32 / float32(fps), evts)
    check evts.len == 1
    check evts[0].kind == ekSound
    check evts[0].soundData.name == "swoosh.wav"

  test "action events are collected with animation name":
    let anim = mkAnim(24, 0, @[mkActionKF(8, "idle")])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 7.0'f32 / float32(fps), 9.0'f32 / float32(fps), evts)
    check evts.len == 1
    check evts[0].kind == ekAction
    check evts[0].actionData.name == "idle"
    check evts[0].actionData.boneName == ""

  test "mixed-type keyframe emits all event types":
    let kf = EventKeyframe(
      frame: 6,
      frameEvents:  @[FrameEventData(name: "fx")],
      soundEvents:  @[SoundEventData(name: "bang.wav")],
      actionEvents: @[ActionEventData(name: "explode", boneName: "")])
    let anim = mkAnim(24, 0, @[kf])
    var evts: seq[AnimEvent]
    collectEvents(anim, fps, 5.0'f32 / float32(fps), 7.0'f32 / float32(fps), evts)
    check evts.len == 3
    check frameNames(evts) == @["fx"]
    check soundNames(evts) == @["bang.wav"]
    check actionNames(evts) == @["explode"]

# ── Output management ─────────────────────────────────────────────────────────

suite "collectEvents — output management":

  test "output is cleared on each call":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "e")])
    var evts = @[AnimEvent(kind: ekFrame, frameData: FrameEventData(name: "stale"))]
    collectEvents(anim, fps, 4.0'f32 / float32(fps), 6.0'f32 / float32(fps), evts)
    check evts.len == 1
    check evts[0].frameData.name == "e"

  test "empty window produces empty output even with stale data":
    let anim = mkAnim(24, 0, @[mkFrameKF(5, "e")])
    var evts = @[AnimEvent(kind: ekFrame, frameData: FrameEventData(name: "stale"))]
    collectEvents(anim, fps, 0.5'f32, 0.3'f32, evts)  ## backwards time
    check evts.len == 0
