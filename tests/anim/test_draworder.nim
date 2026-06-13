import std/unittest
import dragonbones/model/model
import dragonbones/anim/draworder

# ── Helpers ───────────────────────────────────────────────────────────────────

proc zKF(frame, duration: int,
          offsets: seq[tuple[slotIndex, zOffset: int]] = @[]): ZOrderKeyframe =
  ZOrderKeyframe(
    base: KeyframeBase(frame: frame, duration: duration),
    slotOffsets: offsets)

proc newOrder(n: int): seq[int] =
  result = newSeq[int](n)

# ── Empty / no-op cases ───────────────────────────────────────────────────────

suite "sampleDrawOrder — empty / no-op":

  test "empty keyframe list: identity order":
    var buf = newOrder(3)
    sampleDrawOrder(@[], 0.0'f32, 3, buf)
    check buf == @[0, 1, 2]

  test "zero slots: no panic":
    var buf = newOrder(0)
    sampleDrawOrder(@[], 0.0'f32, 0, buf)
    check buf.len == 0

  test "single keyframe empty slotOffsets: identity order":
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[])], 12.0'f32, 3, buf)
    check buf == @[0, 1, 2]

# ── Single keyframe with offsets ──────────────────────────────────────────────

suite "sampleDrawOrder — single keyframe":

  test "slot 0 +1 offset: ties with slot 1 at z=1; tiebreak by index keeps [0,1,2]":
    ## zVals: [1,1,2]. Tiebreak lower index first: slot0<slot1. Result: [0,1,2].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(0, 1)])], 0.0'f32, 3, buf)
    check buf == @[0, 1, 2]

  test "slot 2 -1 offset: ties with slot 1 at z=1; tiebreak keeps [0,1,2]":
    ## zVals: [0,1,1]. Tie at z=1: slot1(idx=1)<slot2(idx=2). Result: [0,1,2].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(2, -1)])], 0.0'f32, 3, buf)
    check buf == @[0, 1, 2]

  test "slot 0 +2 offset: slot 0 jumps to front":
    ## zVals: [2,1,2]. Sorted: slot1(z=1), z=2 tie slot0(idx=0)<slot2(idx=2). Result: [1,0,2].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(0, 2)])], 0.0'f32, 3, buf)
    check buf == @[1, 0, 2]

  test "slot 1 -1 offset: slot 1 ties with slot 0 at z=0; tiebreak keeps [0,1,2]":
    ## zVals: [0,0,2]. Tie at z=0: slot0<slot1. Result: [0,1,2].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(1, -1)])], 0.0'f32, 3, buf)
    check buf == @[0, 1, 2]

  test "two offsets: slot 0 and slot 2 fully swap positions":
    ## slot0→z=2, slot2→z=0, slot1→z=1. Result: [2,1,0].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(0, 2), (2, -2)])], 0.0'f32, 3, buf)
    check buf == @[2, 1, 0]

  test "four-slot rig: middle two swap":
    ## slot1→z=2, slot2→z=1. zVals: [0,2,1,3]. Result: [0,2,1,3].
    var buf = newOrder(4)
    sampleDrawOrder(@[zKF(0, 24, @[(1, 1), (2, -1)])], 0.0'f32, 4, buf)
    check buf == @[0, 2, 1, 3]

# ── Stepped sampling across multiple keyframes ─────────────────────────────────

suite "sampleDrawOrder — stepped sampling":

  test "frame before first keyframe applies first keyframe (same as sampleSlotDisplay)":
    ## kfIdx initializes to 0 and only advances when kfs[i].frame <= frame.
    ## If kfs[0].frame=6 and frame=0, 6<=0 is false, kfIdx stays 0 → kfs[0] applies.
    ## Matches the DragonBones convention: first keyframe is the baseline state.
    var buf = newOrder(3)
    let kfs = @[zKF(6, 6, @[(0, 2), (2, -2)])]
    sampleDrawOrder(kfs, 0.0'f32, 3, buf)
    check buf == @[2, 1, 0]

  test "frame at exact keyframe: uses that keyframe":
    var buf = newOrder(3)
    let kfs = @[zKF(0, 12, @[(0, 2), (2, -2)]),
                zKF(12, 12, @[]),
                zKF(24, 0, @[])]
    sampleDrawOrder(kfs, 12.0'f32, 3, buf)
    check buf == @[0, 1, 2]

  test "frame between keyframes: holds earlier keyframe (stepped, no interpolation)":
    var buf = newOrder(3)
    let kfs = @[zKF(0, 12, @[(0, 2), (2, -2)]),
                zKF(12, 12, @[])]
    sampleDrawOrder(kfs, 6.0'f32, 3, buf)
    check buf == @[2, 1, 0]

  test "frame past last keyframe: holds last keyframe":
    var buf = newOrder(3)
    let kfs = @[zKF(0, 12, @[]),
                zKF(12, 0, @[(0, 2), (2, -2)])]
    sampleDrawOrder(kfs, 99.0'f32, 3, buf)
    check buf == @[2, 1, 0]

# ── Guard / boundary conditions ───────────────────────────────────────────────

suite "sampleDrawOrder — guards":

  test "out-of-range slotIndex silently skipped":
    ## slot 5 is ignored (numSlots=3); slot 2 gets z=0. zVals: [0,1,0].
    ## Tie at z=0: slot0(idx=0)<slot2(idx=2). Result: [0,2,1].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(5, 2), (2, -2)])], 0.0'f32, 3, buf)
    check buf == @[0, 2, 1]

  test "negative effective z-value: still sorts correctly (rearmost)":
    ## slot0→z=-1. zVals: [-1,1,2]. Result: [0,1,2].
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(0, -1)])], 0.0'f32, 3, buf)
    check buf == @[0, 1, 2]

  test "undersized output: doAssert fires":
    var buf = newOrder(2)
    expect AssertionDefect:
      sampleDrawOrder(@[], 0.0'f32, 3, buf)

  test "output reuse: second call overwrites first result":
    var buf = newOrder(3)
    sampleDrawOrder(@[zKF(0, 24, @[(0, 2), (2, -2)])], 0.0'f32, 3, buf)
    check buf == @[2, 1, 0]
    sampleDrawOrder(@[], 0.0'f32, 3, buf)
    check buf == @[0, 1, 2]
