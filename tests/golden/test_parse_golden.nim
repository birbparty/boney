## Golden-file parsing tests against checked-in real DragonBones exports.
##
## Fixture: tests/fixtures/sample/ — oracle_sample rig (Dragon armature, v5.7.0)
##   dragon_ske.json  — skeleton: armature/bone/slot/skin/animation data
##   dragon_tex.json  — texture atlas: subtexture UV and quad geometry
##
## These tests pin the full structural parse of both files so any regression in
## any parse layer (armature, slot, skin, timeline, atlas) breaks immediately.
## Values are derived directly from the fixture files — no approximation.
##
## VERSION_PIN: "5.7.0" / "5.0.0" — both files must match these DragonBones
## versions. If a new fixture is checked in at a different version, update the
## VERSION_MAJOR/VERSION_FULL constants below.

import std/[unittest, os]
import vmath
import dragonbones/model/model
import dragonbones/parse/armature
import dragonbones/atlas/atlas

const Eps = 1e-5'f32

proc approxEq(a, b: float32): bool = abs(a - b) < Eps
proc approxEqV(a, b: Vec2): bool = approxEq(a.x, b.x) and approxEq(a.y, b.y)

let fixDir = currentSourcePath().parentDir() / ".." / "fixtures" / "sample"

# Parse once; reuse across all suites.
let gSke = parseDragonBones(readFile(fixDir / "dragon_ske.json"))
let gTex = parseAtlas(readFile(fixDir / "dragon_tex.json"))

proc findRotateTL(anim: AnimationData, boneName: string): Timeline =
  for tl in anim.timelines:
    if tl.name == boneName and tl.kind == tlBoneRotate:
      return tl
  doAssert false, "rotate timeline for " & boneName & " not found"

# ── Version gate ──────────────────────────────────────────────────────────────

suite "golden — version pin":

  test "skeleton version is 5.7.0":
    check gSke.version == "5.7.0"

  test "skeleton compatibleVersion is 5.0.0":
    check gSke.compatibleVersion == "5.0.0"

  test "atlas name matches skeleton name (same rig)":
    check gTex.name == gSke.name

# ── Skeleton top-level ────────────────────────────────────────────────────────

suite "golden — skeleton top-level":

  test "name is oracle_sample":
    check gSke.name == "oracle_sample"

  test "frameRate is 24":
    check gSke.frameRate == 24

  test "exactly one armature":
    check gSke.armatures.len == 1

# ── Armature structure ────────────────────────────────────────────────────────

suite "golden — armature structure":

  let arm = gSke.armatures[0]

  test "armature name is Dragon":
    check arm.name == "Dragon"

  test "armature frameRate is 24":
    check arm.frameRate == 24

  test "exactly 2 bones":
    check arm.bones.len == 2

  test "bone[0] is root (no parent)":
    check arm.bones[0].name == "root"
    check arm.bones[0].parentName == ""

  test "bone[1] is arm (parent=root)":
    check arm.bones[1].name == "arm"
    check arm.bones[1].parentName == "root"

  test "arm bone length is 50":
    check approxEq(arm.bones[1].length, 50.0'f32)

  test "arm bone rest-pose x is 50":
    check approxEq(arm.bones[1].transform.x, 50.0'f32)

  test "arm bone rest-pose y is 0":
    check approxEq(arm.bones[1].transform.y, 0.0'f32)

  test "exactly 2 slots":
    check arm.slots.len == 2

  test "slot[0] is root_slot parented to root":
    check arm.slots[0].name == "root_slot"
    check arm.slots[0].boneName == "root"

  test "slot[1] is arm_slot parented to arm":
    check arm.slots[1].name == "arm_slot"
    check arm.slots[1].boneName == "arm"

# ── Skin / display data ───────────────────────────────────────────────────────

suite "golden — skin and display data":

  let arm = gSke.armatures[0]

  test "exactly one skin":
    check arm.skins.len == 1

  test "default skin name is empty string":
    check arm.skins[0].name == ""

  test "default skin has 2 slot entries":
    check arm.skins[0].slots.len == 2

  test "skin slot[0] is root_slot with one display":
    check arm.skins[0].slots[0].slotName == "root_slot"
    check arm.skins[0].slots[0].displays.len == 1

  test "root_slot display is image type":
    check arm.skins[0].slots[0].displays[0].kind == dkImage

  test "root_slot image name is root_img":
    check arm.skins[0].slots[0].displays[0].name == "root_img"

  test "skin slot[1] is arm_slot with one display":
    check arm.skins[0].slots[1].slotName == "arm_slot"
    check arm.skins[0].slots[1].displays.len == 1

  test "arm_slot display is image type":
    check arm.skins[0].slots[1].displays[0].kind == dkImage

  test "arm_slot image name is arm_img":
    check arm.skins[0].slots[1].displays[0].name == "arm_img"

# ── Animation timeline structure ──────────────────────────────────────────────

suite "golden — animation structure":

  let arm = gSke.armatures[0]

  test "exactly one animation":
    check arm.animations.len == 1

  test "animation name is idle":
    check arm.animations[0].name == "idle"

  test "animation duration is 24 frames":
    check arm.animations[0].duration == 24

  test "animation playTimes is 0 (loop forever)":
    check arm.animations[0].playTimes == 0

  test "animation has at least one timeline":
    check arm.animations[0].timelines.len >= 1

  test "root bone has a rotate timeline":
    let idle = arm.animations[0]
    var found = false
    for tl in idle.timelines:
      if tl.name == "root" and tl.kind == tlBoneRotate:
        found = true
        break
    check found

  test "root rotate timeline has 2 keyframes (start + end hold)":
    let tl = findRotateTL(arm.animations[0], "root")
    check tl.rotateKFs.len == 2

  test "root rotate kf[0]: frame=0, rotate=0, linear tween":
    let tl = findRotateTL(arm.animations[0], "root")
    check tl.rotateKFs[0].base.frame == 0
    check approxEq(tl.rotateKFs[0].rotate, 0.0'f32)
    check tl.rotateKFs[0].base.curve.kind == tkLinear

  test "root rotate kf[1]: frame=24, rotate=90":
    let tl = findRotateTL(arm.animations[0], "root")
    check tl.rotateKFs[1].base.frame == 24
    check approxEq(tl.rotateKFs[1].rotate, 90.0'f32)

# ── Atlas top-level ───────────────────────────────────────────────────────────

suite "golden — atlas top-level":

  test "atlas imagePath is oracle_sample.png":
    check gTex.imagePath == "oracle_sample.png"

  test "atlas dimensions are 256x128":
    check gTex.width == 256
    check gTex.height == 128

  test "atlas scale is 1.0":
    check approxEq(gTex.scale, 1.0'f32)

  test "atlas has exactly 2 subtextures":
    check gTex.subTextures.len == 2

# ── Atlas subtexture: root_img (non-rotated, no trim) ─────────────────────────

suite "golden — atlas root_img (non-rotated, no trim)":

  var sub: AtlasSubTexture
  for s in gTex.subTextures:
    if s.name == "root_img": sub = s; break

  test "name is root_img":
    check sub.name == "root_img"

  test "not rotated":
    check not sub.rotated

  test "frameWidth/Height = visible dims (64x32)":
    check sub.frameWidth == 64
    check sub.frameHeight == 32

  test "frameX/Y = 0 (no trim)":
    check sub.frameX == 0
    check sub.frameY == 0

  test "UV TL is (0/256, 0/128) = (0, 0)":
    check approxEqV(sub.quadUVs[0], vec2(0.0'f32, 0.0'f32))

  test "UV TR is (64/256, 0/128)":
    check approxEqV(sub.quadUVs[1], vec2(64.0'f32/256, 0.0'f32))

  test "UV BR is (64/256, 32/128)":
    check approxEqV(sub.quadUVs[2], vec2(64.0'f32/256, 32.0'f32/128))

  test "UV BL is (0/256, 32/128)":
    check approxEqV(sub.quadUVs[3], vec2(0.0'f32, 32.0'f32/128))

  test "quad TL is (0, 0)":
    check approxEqV(sub.quadVerts[0], vec2(0, 0))

  test "quad BR is (64, 32)":
    check approxEqV(sub.quadVerts[2], vec2(64, 32))

# ── Atlas subtexture: arm_img (rotated, trimmed) ──────────────────────────────

suite "golden — atlas arm_img (rotated, trimmed)":

  var sub: AtlasSubTexture
  for s in gTex.subTextures:
    if s.name == "arm_img": sub = s; break

  test "name is arm_img":
    check sub.name == "arm_img"

  test "rotated is true":
    check sub.rotated

  test "frameX=-2, frameY=-1 (trim stored verbatim)":
    check sub.frameX == -2
    check sub.frameY == -1

  test "frameWidth=54, frameHeight=52 (from JSON)":
    check sub.frameWidth == 54
    check sub.frameHeight == 52

  # Rotated: atlas w=32,h=50 → visW=50 (original width), visH=32
  test "quad TL is (−frameX, −frameY) = (2, 1)":
    check approxEqV(sub.quadVerts[0], vec2(2, 1))

  test "quad BR is (2+visW, 1+visH) = (52, 33)  [visW=50, visH=32]":
    check approxEqV(sub.quadVerts[2], vec2(52, 33))

  # UV: x=64, y=0, w=32, h=50 → u0=64/256=0.25, v0=0, u1=96/256=0.375, v1=50/128
  test "UV TL (sprite TL → atlas BL): (u0, v1) = (0.25, 50/128)":
    check approxEqV(sub.quadUVs[0], vec2(64.0'f32/256, 50.0'f32/128))

  test "UV TR (sprite TR → atlas TL): (u0, v0) = (0.25, 0)":
    check approxEqV(sub.quadUVs[1], vec2(64.0'f32/256, 0.0'f32))

  test "UV BR (sprite BR → atlas TR): (u1, v0) = (0.375, 0)":
    check approxEqV(sub.quadUVs[2], vec2(96.0'f32/256, 0.0'f32))

  test "UV BL (sprite BL → atlas BR): (u1, v1) = (0.375, 50/128)":
    check approxEqV(sub.quadUVs[3], vec2(96.0'f32/256, 50.0'f32/128))

# ── Cross-validation: skeleton ↔ atlas ───────────────────────────────────────

suite "golden — cross-validation: skeleton skin display names in atlas":

  test "all default-skin image display names resolve to atlas subtextures":
    let arm = gSke.armatures[0]
    var atlasNames: seq[string]
    for s in gTex.subTextures:
      atlasNames.add s.name
    for skin in arm.skins:
      if skin.name != "": continue    # only check default skin
      for slot in skin.slots:
        for disp in slot.displays:
          if disp.kind == dkImage:
            check disp.name in atlasNames
