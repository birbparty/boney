## Tests for anim/hittest.nim — bounding-box hit detection.

import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/anim/transform
import dragonbones/anim/propagate
import dragonbones/anim/sample
import dragonbones/anim/hittest

# ── Helpers ───────────────────────────────────────────────────────────────────

proc mkBone(name, parent: string, x, y: float32): BoneData =
  BoneData(name: name, parentName: parent, length: 50,
           transform: DbTransform(x: x, y: y, scX: 1'f32, scY: 1'f32),
           inheritTranslation: true, inheritRotation: true,
           inheritScale: true, inheritReflection: true)

proc rectDisplay(w, h: float32, tx = 0'f32, ty = 0'f32): DisplayData =
  let w2 = w / 2'f32; let h2 = h / 2'f32
  DisplayData(name: "bb", kind: dkBoundingBox, bbShape: bbsRectangle,
              transform: DbTransform(x: tx, y: ty, scX: 1'f32, scY: 1'f32),
              bbVertices: @[vec2(-w2, -h2), vec2(w2, -h2),
                             vec2(w2, h2),  vec2(-w2, h2)])

proc ellipseDisplay(rx, ry: float32, tx = 0'f32, ty = 0'f32): DisplayData =
  DisplayData(name: "bb", kind: dkBoundingBox, bbShape: bbsEllipse,
              transform: DbTransform(x: tx, y: ty, scX: 1'f32, scY: 1'f32),
              bbVertices: @[vec2(rx, 0'f32), vec2(0'f32, ry)])

proc polygonDisplay(verts: seq[Vec2], tx = 0'f32, ty = 0'f32): DisplayData =
  DisplayData(name: "bb", kind: dkBoundingBox, bbShape: bbsPolygon,
              transform: DbTransform(x: tx, y: ty, scX: 1'f32, scY: 1'f32),
              bbVertices: verts)

proc defaultOrder(n: int): seq[int] =
  result = newSeq[int](n)
  for i in 0 ..< n: result[i] = i

## Build a minimal ArmatureData with one bone, one slot with a single bounding-box
## display in the default skin, and a matching BoneState + SlotState.
proc mkHitArm(bone: BoneData, disp: DisplayData,
              slotName = "slot0"): (ArmatureData, seq[BoneState], seq[SlotState]) =
  let arm = ArmatureData(
    name: "T", frameRate: 24,
    bones: @[bone],
    slots: @[SlotData(name: slotName, boneName: bone.name, displayIndex: 0)],
    skins: @[SkinData(name: "", slots: @[
      SkinSlot(slotName: slotName, displays: @[disp])])],
    animations: @[],
    ikConstraints: @[],
    defaultActions: @[]
  )
  var bones = newSeq[BoneState](1)
  var slots = @[SlotState(displayIndex: 0, color: dbColorIdentity())]
  var worldT = newSeq[DbTransform](1)
  let emptyAnim = AnimationData(name: "idle", duration: 24, playTimes: 0)
  sampleAnimation(emptyAnim, arm, 0'f32, bones, slots)
  propagateWorldTransforms(arm, bones, worldT)
  (arm, bones, slots)

# ── hitTestDisplay — rectangle ────────────────────────────────────────────────

suite "hitTestDisplay — rectangle":

  test "center of rectangle is a hit":
    let disp = rectDisplay(100, 80)
    check hitTestDisplay(vec2(0, 0), disp, mat3())

  test "point inside rectangle is a hit":
    let disp = rectDisplay(100, 80)
    check hitTestDisplay(vec2(30, 20), disp, mat3())

  test "point at positive corner edge is a hit":
    let disp = rectDisplay(100, 80)
    check hitTestDisplay(vec2(50, 40), disp, mat3())

  test "point outside rectangle (x) is a miss":
    let disp = rectDisplay(100, 80)
    check not hitTestDisplay(vec2(60, 0), disp, mat3())

  test "point outside rectangle (y) is a miss":
    let disp = rectDisplay(100, 80)
    check not hitTestDisplay(vec2(0, 50), disp, mat3())

  test "rectangle with display offset: point in world accounts for offset":
    ## Display offset (tx=50, ty=0): local rect centered at world (50,0).
    ## World point (50,0) → local (0,0) → hit.
    let disp = rectDisplay(40, 40, tx = 50)
    let combined = mat3() * dbTransformToMat3(disp.transform)
    check hitTestDisplay(vec2(50, 0), disp, combined)

  test "rectangle with display offset: original world origin is a miss":
    let disp = rectDisplay(40, 40, tx = 50)
    let combined = mat3() * dbTransformToMat3(disp.transform)
    check not hitTestDisplay(vec2(0, 0), disp, combined)

# ── hitTestDisplay — ellipse ──────────────────────────────────────────────────

suite "hitTestDisplay — ellipse":

  test "center is inside ellipse":
    let disp = ellipseDisplay(50, 30)
    check hitTestDisplay(vec2(0, 0), disp, mat3())

  test "point on ellipse boundary is inside":
    ## (rx, 0) is exactly on the boundary: (50/50)² + 0 = 1.
    let disp = ellipseDisplay(50, 30)
    check hitTestDisplay(vec2(50, 0), disp, mat3())

  test "point just outside ellipse x-axis is a miss":
    let disp = ellipseDisplay(50, 30)
    check not hitTestDisplay(vec2(51, 0), disp, mat3())

  test "corner at (rx, ry) is outside ellipse (√2 > 1)":
    let disp = ellipseDisplay(50, 30)
    check not hitTestDisplay(vec2(50, 30), disp, mat3())

  test "diagonal point inside ellipse":
    ## (25,15): (25/50)²+(15/30)² = 0.25+0.25 = 0.5 ≤ 1 → inside
    let disp = ellipseDisplay(50, 30)
    check hitTestDisplay(vec2(25, 15), disp, mat3())

# ── hitTestDisplay — polygon ──────────────────────────────────────────────────

suite "hitTestDisplay — polygon":

  test "center of triangle is inside":
    let tri = @[vec2(0, -50), vec2(50, 50), vec2(-50, 50)]
    let disp = polygonDisplay(tri)
    check hitTestDisplay(vec2(0, 10), disp, mat3())

  test "point outside triangle is a miss":
    let tri = @[vec2(0, -50), vec2(50, 50), vec2(-50, 50)]
    let disp = polygonDisplay(tri)
    check not hitTestDisplay(vec2(0, -60), disp, mat3())

  test "point inside convex quadrilateral":
    ## Diamond: vertices at (0,-50) (50,0) (0,50) (-50,0).
    let quad = @[vec2(0,-50), vec2(50,0), vec2(0,50), vec2(-50,0)]
    let disp = polygonDisplay(quad)
    check hitTestDisplay(vec2(0, 0), disp, mat3())

  test "corner of diamond (outside) is a miss":
    let quad = @[vec2(0,-50), vec2(50,0), vec2(0,50), vec2(-50,0)]
    let disp = polygonDisplay(quad)
    check not hitTestDisplay(vec2(40, 40), disp, mat3())

  test "polygon with fewer than 3 vertices returns false":
    let disp = polygonDisplay(@[vec2(0,0), vec2(10,0)])
    check not hitTestDisplay(vec2(5, 0), disp, mat3())

# ── hitTestDisplay — non-bounding-box kinds ───────────────────────────────────

suite "hitTestDisplay — non-bounding-box display":

  test "dkImage display always returns false":
    let disp = DisplayData(name: "img", kind: dkImage,
                            transform: DbTransform(scX: 1'f32, scY: 1'f32))
    check not hitTestDisplay(vec2(0, 0), disp, mat3())

# ── findHit — full armature traversal ────────────────────────────────────────

suite "findHit":

  test "no hit when point is outside all bounding boxes":
    let bone = mkBone("root", "", 0, 0)
    let disp = rectDisplay(50, 50)
    let (arm, bones, slots) = mkHitArm(bone, disp)
    check findHit(vec2(100, 100), arm, bones, slots, defaultOrder(arm.slots.len)) == -1

  test "hit when point is inside rectangle bounding box":
    let bone = mkBone("root", "", 0, 0)
    let disp = rectDisplay(50, 50)
    let (arm, bones, slots) = mkHitArm(bone, disp)
    check findHit(vec2(10, 10), arm, bones, slots, defaultOrder(arm.slots.len)) == 0

  test "bone at world offset shifts the bounding box":
    ## Bone at (100,0): rect 50×50 covers world (75..125, -25..25).
    let bone = mkBone("root", "", 100, 0)
    let disp = rectDisplay(50, 50)
    let (arm, bones, slots) = mkHitArm(bone, disp)
    check findHit(vec2(100, 0), arm, bones, slots, defaultOrder(arm.slots.len)) == 0
    check findHit(vec2(0, 0), arm, bones, slots, defaultOrder(arm.slots.len)) == -1

  test "hidden slot (displayIndex=-1) is never hit":
    let bone = mkBone("root", "", 0, 0)
    let disp = rectDisplay(200, 200)
    var (arm, bones, slots) = mkHitArm(bone, disp)
    slots[0].displayIndex = -1
    check findHit(vec2(0, 0), arm, bones, slots, defaultOrder(arm.slots.len)) == -1

  test "non-bounding-box display is never returned as a hit":
    let arm = ArmatureData(
      name: "T", frameRate: 24,
      bones: @[mkBone("root", "", 0, 0)],
      slots: @[SlotData(name: "s", boneName: "root", displayIndex: 0)],
      skins: @[SkinData(name: "", slots: @[
        SkinSlot(slotName: "s", displays: @[
          DisplayData(name: "img", kind: dkImage,
                      transform: DbTransform(scX: 1'f32, scY: 1'f32))])])],
      animations: @[], ikConstraints: @[], defaultActions: @[]
    )
    var bones = newSeq[BoneState](1)
    var slots = @[SlotState(displayIndex: 0, color: dbColorIdentity())]
    var worldT = newSeq[DbTransform](1)
    let ea = AnimationData(name: "idle", duration: 24, playTimes: 0)
    sampleAnimation(ea, arm, 0'f32, bones, slots)
    propagateWorldTransforms(arm, bones, worldT)
    check findHit(vec2(0, 0), arm, bones, slots, @[0]) == -1

  test "findHit returns frontmost hit (highest drawOrder layer)":
    ## Two overlapping bounding boxes. Default order [0,1]: slot 1 = front → returns 1.
    let arm = ArmatureData(
      name: "T", frameRate: 24,
      bones: @[mkBone("root", "", 0, 0)],
      slots: @[SlotData(name: "back", boneName: "root", displayIndex: 0),
               SlotData(name: "front", boneName: "root", displayIndex: 0)],
      skins: @[SkinData(name: "", slots: @[
        SkinSlot(slotName: "back",  displays: @[rectDisplay(100, 100)]),
        SkinSlot(slotName: "front", displays: @[rectDisplay(100, 100)])])],
      animations: @[], ikConstraints: @[], defaultActions: @[]
    )
    var bones = newSeq[BoneState](1)
    var slots = @[SlotState(displayIndex: 0, color: dbColorIdentity()),
                  SlotState(displayIndex: 0, color: dbColorIdentity())]
    var worldT = newSeq[DbTransform](1)
    let ea = AnimationData(name: "idle", duration: 24, playTimes: 0)
    sampleAnimation(ea, arm, 0'f32, bones, slots)
    propagateWorldTransforms(arm, bones, worldT)
    check findHit(vec2(0, 0), arm, bones, slots, @[0, 1]) == 1  ## slot 1 = front
    ## Reversed drawOrder: now slot 0 is in front → returns 0.
    check findHit(vec2(0, 0), arm, bones, slots, @[1, 0]) == 0

  test "invalid skinIdx returns -1":
    let bone = mkBone("root", "", 0, 0)
    let disp = rectDisplay(100, 100)
    let (arm, bones, slots) = mkHitArm(bone, disp)
    check findHit(vec2(0, 0), arm, bones, slots, defaultOrder(arm.slots.len), skinIdx = 99) == -1

# ── hitTestDisplay — rotation and degenerate transforms ───────────────────────

suite "hitTestDisplay — rotation and degenerate transforms":

  test "90-degree rotation: world point maps through inverse correctly":
    ## Unrotated rect is 100 wide × 20 tall (half-extents ±50 x, ±10 y).
    ## After 90° rotation it becomes 20 wide × 100 tall.
    ## World point (0, 40) is inside the rotated box; (40, 0) is outside it.
    let disp = rectDisplay(100, 20)
    let rot = dbTransformToMat3(DbTransform(skX: 90'f32, skY: 90'f32,
                                             scX: 1'f32, scY: 1'f32))
    check hitTestDisplay(vec2(0, 40), disp, rot)
    check not hitTestDisplay(vec2(40, 0), disp, rot)

  test "zero-scale (singular) transform never hits and does not crash":
    ## scX=0 collapses the box to a line; determinant=0 → return false without
    ## calling inverse() or producing NaN comparisons.
    let disp = rectDisplay(100, 100)
    let degenerate = dbTransformToMat3(DbTransform(scX: 0'f32, scY: 0'f32))
    check not hitTestDisplay(vec2(0, 0), disp, degenerate)
    check not hitTestDisplay(vec2(50, 50), disp, degenerate)
