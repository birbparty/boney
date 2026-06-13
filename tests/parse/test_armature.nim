import std/unittest
import dragonbones/model/model
import dragonbones/parse/armature

# ── Helpers ────────────────────────────────────────────────────────────────────

proc minimalFile(armatures = "[]"): string =
  ## Minimal valid DragonBones JSON with configurable armature array.
  """{"version":"5.7.0","compatibleVersion":"5.0.0","name":"Dragon","frameRate":24,"armature":""" &
  armatures & "}"

proc oneArmature(extraFields = "", bones = "[]", slots = "[]",
                 ik = "[]"): string =
  ## Armature JSON fragment with configurable sub-arrays.
  let body = """{"type":"Armature","frameRate":30,"name":"Hero"""" &
             (if extraFields.len > 0: "," & extraFields else: "") &
             ""","bone":""" & bones &
             ""","slot":""" & slots &
             ""","ik":""" & ik & "}"
  minimalFile("[" & body & "]")

# ── Version / top-level fields ─────────────────────────────────────────────────

suite "armature parser — top-level":

  test "version and name fields":
    let data = minimalFile().parseDragonBones()
    check data.version == "5.7.0"
    check data.compatibleVersion == "5.0.0"
    check data.name == "Dragon"
    check data.frameRate == 24

  test "empty armature list":
    check minimalFile().parseDragonBones().armatures.len == 0

# ── Armature-level fields ──────────────────────────────────────────────────────

suite "armature parser — armature":

  test "basic armature fields":
    let data = oneArmature().parseDragonBones()
    check data.armatures.len == 1
    let arm = data.armatures[0]
    check arm.name == "Hero"
    check arm.kind == akArmature
    check arm.frameRate == 30

  test "armature type MovieClip":
    let json = minimalFile(
      """[{"type":"MovieClip","frameRate":24,"name":"Clip","bone":[],"slot":[],"ik":[]}]""")
    check json.parseDragonBones().armatures[0].kind == akMovieClip

  test "armature type Stage":
    let json = minimalFile(
      """[{"type":"Stage","frameRate":24,"name":"S","bone":[],"slot":[],"ik":[]}]""")
    check json.parseDragonBones().armatures[0].kind == akStage

  test "frameRate inherits from top-level when armature omits it":
    ## frameRate absent → 0 from jsony → caller falls back to file-level 24.
    let json = minimalFile(
      """[{"type":"Armature","name":"A","bone":[],"slot":[],"ik":[]}]""")
    check json.parseDragonBones().armatures[0].frameRate == 24

  test "armature frameRate overrides top-level":
    check oneArmature().parseDragonBones().armatures[0].frameRate == 30

  test "aabb parsed correctly":
    let json = oneArmature(
      extraFields = """"aabb":{"x":-10,"y":-20,"width":200,"height":100}""")
    let arm = json.parseDragonBones().armatures[0]
    check arm.aabb.x == -10.0'f32
    check arm.aabb.y == -20.0'f32
    check arm.aabb.w == 200.0'f32
    check arm.aabb.h == 100.0'f32

  test "aabb absent yields zero Rect":
    let arm = oneArmature().parseDragonBones().armatures[0]
    check arm.aabb.x == 0.0'f32
    check arm.aabb.w == 0.0'f32

# ── Bone parsing ───────────────────────────────────────────────────────────────

suite "armature parser — bones":

  test "root bone (no parent)":
    let json = oneArmature(bones = """[{"name":"root","length":0}]""")
    let bone = json.parseDragonBones().armatures[0].bones[0]
    check bone.name == "root"
    check bone.parentName == ""

  test "child bone carries parent name":
    let json = oneArmature(bones = """
      [{"name":"root","length":0},
       {"name":"arm","parent":"root","length":50}]""")
    let bones = json.parseDragonBones().armatures[0].bones
    check bones[1].name == "arm"
    check bones[1].parentName == "root"

  test "bone length":
    let json = oneArmature(bones = """[{"name":"b","length":75.5}]""")
    let bone = json.parseDragonBones().armatures[0].bones[0]
    check bone.length == 75.5'f32

  test "inherit flags default to true when absent":
    let json = oneArmature(bones = """[{"name":"b"}]""")
    let bone = json.parseDragonBones().armatures[0].bones[0]
    check bone.inheritTranslation == true
    check bone.inheritRotation    == true
    check bone.inheritScale       == true
    check bone.inheritReflection  == true

  test "inherit flags explicit 0 sets false":
    let json = oneArmature(bones = """
      [{"name":"b","inheritTranslation":0,"inheritRotation":0,
        "inheritScale":0,"inheritReflection":0}]""")
    let bone = json.parseDragonBones().armatures[0].bones[0]
    check bone.inheritTranslation == false
    check bone.inheritRotation    == false
    check bone.inheritScale       == false
    check bone.inheritReflection  == false

  test "inherit flags explicit 1 stays true":
    let json = oneArmature(bones = """
      [{"name":"b","inheritTranslation":1,"inheritScale":1}]""")
    let bone = json.parseDragonBones().armatures[0].bones[0]
    check bone.inheritTranslation == true
    check bone.inheritScale       == true

  test "transform absent yields identity":
    let json = oneArmature(bones = """[{"name":"b"}]""")
    let t = json.parseDragonBones().armatures[0].bones[0].transform
    check t.x   == 0.0'f32
    check t.y   == 0.0'f32
    check t.skX == 0.0'f32
    check t.skY == 0.0'f32
    check t.scX == 1.0'f32
    check t.scY == 1.0'f32

  test "transform scX/scY absent defaults to 1.0":
    ## scX/scY omitted from JSON — must not default to 0 (Nim's float default).
    let json = oneArmature(bones = """
      [{"name":"b","transform":{"x":5,"y":10,"skX":45,"skY":45}}]""")
    let t = json.parseDragonBones().armatures[0].bones[0].transform
    check t.x   == 5.0'f32
    check t.y   == 10.0'f32
    check t.skX == 45.0'f32
    check t.skY == 45.0'f32
    check t.scX == 1.0'f32  ## was absent — must NOT be 0
    check t.scY == 1.0'f32

  test "transform explicit scale values":
    let json = oneArmature(bones = """
      [{"name":"b","transform":{"x":0,"y":0,"scX":2.0,"scY":0.5}}]""")
    let t = json.parseDragonBones().armatures[0].bones[0].transform
    check t.scX == 2.0'f32
    check t.scY == 0.5'f32

  test "transform explicit zero scale is preserved":
    ## scX: 0 in JSON means truly zero scale (degenerate, not identity).
    let json = oneArmature(bones = """
      [{"name":"b","transform":{"scX":0.0,"scY":0.0}}]""")
    let t = json.parseDragonBones().armatures[0].bones[0].transform
    check t.scX == 0.0'f32
    check t.scY == 0.0'f32

# ── Slot parsing ───────────────────────────────────────────────────────────────

suite "armature parser — slots":

  test "slot name and parent bone":
    let json = oneArmature(
      bones  = """[{"name":"root"}]""",
      slots  = """[{"name":"weapon_slot","parent":"root"}]""")
    let slot = json.parseDragonBones().armatures[0].slots[0]
    check slot.name     == "weapon_slot"
    check slot.boneName == "root"

  test "slot displayIndex":
    let json = oneArmature(slots = """[{"name":"s","parent":"b","displayIndex":2}]""")
    check json.parseDragonBones().armatures[0].slots[0].displayIndex == 2

  test "slot displayIndex absent defaults to 0":
    let json = oneArmature(slots = """[{"name":"s","parent":"b"}]""")
    check json.parseDragonBones().armatures[0].slots[0].displayIndex == 0

  test "slot blendMode normal":
    let json = oneArmature(slots = """[{"name":"s","parent":"b","blendMode":"normal"}]""")
    check json.parseDragonBones().armatures[0].slots[0].blendMode == bmNormal

  test "slot blendMode add":
    let json = oneArmature(slots = """[{"name":"s","parent":"b","blendMode":"add"}]""")
    check json.parseDragonBones().armatures[0].slots[0].blendMode == bmAdd

  test "slot blendMode absent defaults to normal":
    let json = oneArmature(slots = """[{"name":"s","parent":"b"}]""")
    check json.parseDragonBones().armatures[0].slots[0].blendMode == bmNormal

  test "slot color identity when absent":
    let json = oneArmature(slots = """[{"name":"s","parent":"b"}]""")
    let c = json.parseDragonBones().armatures[0].slots[0].color
    check c.aM == 1.0'f32
    check c.rM == 1.0'f32
    check c.gM == 1.0'f32
    check c.bM == 1.0'f32
    check c.aO == 0.0'f32

  test "slot color multipliers divided by 100":
    let json = oneArmature(slots = """
      [{"name":"s","parent":"b",
        "color":{"aM":50,"rM":100,"gM":75,"bM":25,"aO":0,"rO":0,"gO":0,"bO":0}}]""")
    let c = json.parseDragonBones().armatures[0].slots[0].color
    check c.aM == 0.5'f32
    check c.rM == 1.0'f32
    check c.gM == 0.75'f32
    check c.bM == 0.25'f32

# ── IK constraint parsing ──────────────────────────────────────────────────────

suite "armature parser — IK constraints":

  test "IK all fields explicit":
    let json = oneArmature(ik = """
      [{"name":"armIK","order":2,"bone":"arm_end","target":"ik_target",
        "bendPositive":1,"chain":1,"weight":0.8}]""")
    let ik = json.parseDragonBones().armatures[0].ikConstraints[0]
    check ik.name         == "armIK"
    check ik.order        == 2
    check ik.boneName     == "arm_end"
    check ik.targetName   == "ik_target"
    check ik.bendPositive == true
    check ik.chain        == 1
    check ik.weight       == 0.8'f32

  test "IK bendPositive absent defaults to true":
    let json = oneArmature(ik = """
      [{"name":"ik","order":0,"bone":"b","target":"t","chain":0}]""")
    check json.parseDragonBones().armatures[0].ikConstraints[0].bendPositive == true

  test "IK bendPositive 0 is false":
    let json = oneArmature(ik = """
      [{"name":"ik","order":0,"bone":"b","target":"t","bendPositive":0}]""")
    check json.parseDragonBones().armatures[0].ikConstraints[0].bendPositive == false

  test "IK weight absent defaults to 1.0":
    let json = oneArmature(ik = """
      [{"name":"ik","order":0,"bone":"b","target":"t"}]""")
    check json.parseDragonBones().armatures[0].ikConstraints[0].weight == 1.0'f32

  test "IK chain 0 means end-effector only":
    let json = oneArmature(ik = """
      [{"name":"ik","order":0,"bone":"b","target":"t","chain":0}]""")
    check json.parseDragonBones().armatures[0].ikConstraints[0].chain == 0

  test "IK chain 1 means two bones":
    let json = oneArmature(ik = """
      [{"name":"ik","order":0,"bone":"b","target":"t","chain":1}]""")
    check json.parseDragonBones().armatures[0].ikConstraints[0].chain == 1

  test "multiple IK constraints":
    let json = oneArmature(ik = """
      [{"name":"ik1","order":0,"bone":"b1","target":"t1"},
       {"name":"ik2","order":1,"bone":"b2","target":"t2"}]""")
    let iks = json.parseDragonBones().armatures[0].ikConstraints
    check iks.len == 2
    check iks[0].name == "ik1"
    check iks[1].name == "ik2"

# ── Multiple armatures ─────────────────────────────────────────────────────────

suite "armature parser — multiple armatures":

  test "two armatures in one file":
    let json = minimalFile("""
      [{"type":"Armature","name":"Hero","frameRate":24,"bone":[],"slot":[],"ik":[]},
       {"type":"Armature","name":"Enemy","frameRate":30,"bone":[],"slot":[],"ik":[]}]""")
    let data = json.parseDragonBones()
    check data.armatures.len == 2
    check data.armatures[0].name == "Hero"
    check data.armatures[1].name == "Enemy"
    check data.armatures[1].frameRate == 30

  test "skins and animations are empty (pending boney-706 and boney-56w)":
    let data = oneArmature().parseDragonBones()
    check data.armatures[0].skins.len == 0
    check data.armatures[0].animations.len == 0
