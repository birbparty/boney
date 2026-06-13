## Frame-accurate event collection for DragonBones animations.
##
## Call order per frame:
##   sampleAnimation → propagateWorldTransforms → collectEvents → dispatch
##
## Fire-once semantics: an event at frame F fires when the playhead crosses F,
## i.e., the half-open interval (prevFrame, currFrame] contains F. A frame is
## "crossed" the first time the playhead reaches it — not every update while in
## that frame.
##
## Loop boundary (playTimes == 0): when the playhead wraps from near-end back to
## 0, events in (prevFrame, duration] fire (tail of the old loop), then events
## in (-1, currFrame] fire (head of the new loop). No event is skipped or
## double-fired across the wrap point.
##
## Starting condition: pass prevTimeSecs = -(1 / frameRate) on the first call so
## that events at frame 0 fire on the initial update. After each call, advance
## prevTimeSecs = currTimeSecs.
##
## For finite animations (playTimes > 0), the caller should stop advancing time
## once the animation completes (time >= duration * playTimes / frameRate).

import std/math
import dragonbones/model/model

proc fireInRange(eventKFs: seq[EventKeyframe],
                  fromFrame, toFrame: float32,
                  output: var seq[AnimEvent]) {.inline.} =
  ## Emit events where fromFrame < kf.frame <= toFrame (exclusive–inclusive).
  for kf in eventKFs:
    let f = float32(kf.frame)
    if f > fromFrame and f <= toFrame:
      for e in kf.frameEvents:
        output.add AnimEvent(kind: ekFrame, frameData: e)
      for s in kf.soundEvents:
        output.add AnimEvent(kind: ekSound, soundData: s)
      for a in kf.actionEvents:
        output.add AnimEvent(kind: ekAction, actionData: a)

proc collectEvents*(
    animData:     AnimationData,
    frameRate:    int,
    prevTimeSecs: float32,
    currTimeSecs: float32,
    output:       var seq[AnimEvent]) =
  ## Collect all AnimEvents fired in the interval (prevTimeSecs, currTimeSecs].
  ##
  ## output is cleared before writing. Events are appended in timeline order.
  output.setLen(0)
  if animData.eventKFs.len == 0: return

  let duration = float32(animData.duration)
  if duration <= 0.0'f32: return

  let rate     = float32(frameRate)
  let prevRaw  = prevTimeSecs * rate   ## raw frame position; may be negative
  let currRaw  = currTimeSecs * rate

  if currRaw <= prevRaw: return  ## time not advancing

  if animData.playTimes == 0:
    ## Looping animation.
    if prevRaw < 0.0'f32:
      ## Initial start: prevRaw is the "before frame 0" sentinel.
      ## Fire events from the beginning up to currWrap (no loop crossing).
      let currLoopN = floor(currRaw / duration)
      let currWrap  = currRaw - currLoopN * duration
      fireInRange(animData.eventKFs, -1.0'f32, currWrap, output)
    else:
      let prevLoopN = floor(prevRaw / duration)
      let currLoopN = floor(currRaw / duration)
      let prevWrap  = prevRaw - prevLoopN * duration
      let currWrap  = currRaw - currLoopN * duration
      if currLoopN > prevLoopN:
        ## Loop boundary crossed: fire tail of old loop, then head of new loop.
        ## If multiple loops fit in dt, we fire once (fire-once-per-update guarantee).
        fireInRange(animData.eventKFs, prevWrap, duration, output)
        fireInRange(animData.eventKFs, -1.0'f32, currWrap, output)
      else:
        fireInRange(animData.eventKFs, prevWrap, currWrap, output)

  else:
    ## Finite animation (playTimes > 0): clamp to valid range.
    let maxRaw = duration * float32(animData.playTimes)
    let currClamped = min(currRaw, maxRaw)
    if prevRaw < 0.0'f32:
      ## Initial start: fire from beginning to currClamped within first play.
      let currLoopN = min(floor(currClamped / duration),
                          float32(animData.playTimes - 1))
      let currWrap  = currClamped - currLoopN * duration
      fireInRange(animData.eventKFs, -1.0'f32, currWrap, output)
    else:
      let prevClamped = min(prevRaw, maxRaw)
      if currClamped <= prevClamped: return
      let prevLoopN = floor(prevClamped / duration)
      ## Cap loop index at (playTimes - 1) to avoid wrapping past the last play.
      let currLoopN = min(floor(currClamped / duration),
                          float32(animData.playTimes - 1))
      let prevWrap  = prevClamped - prevLoopN * duration
      let currWrap  = currClamped - currLoopN * duration
      if currLoopN > prevLoopN:
        fireInRange(animData.eventKFs, prevWrap, duration, output)
        fireInRange(animData.eventKFs, -1.0'f32, currWrap, output)
      else:
        fireInRange(animData.eventKFs, prevWrap, currWrap, output)
