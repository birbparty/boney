import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/parse/armature

# ── Helpers ────────────────────────────────────────────────────────────────────

proc minimalFile(armatures = "[]"): string =
  """{"version":"5.7.0","compatibleVersion":"5.0.0","name":"Dragon","frameRate":24,"armature":""" &
  armatures & "}"

proc oneAnim(animBody: string): string =
  ## Wraps an animation JSON body into a full parseable file.
  minimalFile(
    """[{"type":"Armature","name":"A","frameRate":24,"bone":[],"slot":[],"ik":[],""" &
    """"animation":[""" & animBody & """]}]""")

proc anim0(name = "anim", duration = 24, playTimes = 0, extraFields = "",
           bone = "[]", slot = "[]", ffd = "[]", ik = "[]"): string =
  ## Minimal animation object with configurable sub-arrays.
  var body = """{"name":"""" & name & """","duration":""" & $duration &
             ""","playTimes":""" & $playTimes
  if extraFields.len > 0: body &= "," & extraFields
  body &= ""","bone":""" & bone &
          ""","slot":""" & slot &
          ""","ffd":""" & ffd &
          ""","ik":""" & ik & "}"
  body

# ── Animation-level fields ─────────────────────────────────────────────────────

suite "timeline parser — animation fields":

  test "name duration playTimes":
    let anim = oneAnim(anim0("walk", 30, 1)).parseDragonBones()
              .armatures[0].animations[0]
    check anim.name      == "walk"
    check anim.duration  == 30
    check anim.playTimes == 1

  test "playTimes 0 means loop forever":
    let anim = oneAnim(anim0(playTimes = 0)).parseDragonBones()
              .armatures[0].animations[0]
    check anim.playTimes == 0

  test "fadeInTime present":
    let anim = oneAnim(anim0(extraFields = """"fadeInTime":0.3""")).parseDragonBones()
              .armatures[0].animations[0]
    check anim.fadeInTime == 0.3'f32

  test "fadeInTime absent defaults to 0.0":
    let anim = oneAnim(anim0()).parseDragonBones()
              .armatures[0].animations[0]
    check anim.fadeInTime == 0.0'f32

  test "empty animation has no timelines":
    let anim = oneAnim(anim0()).parseDragonBones()
              .armatures[0].animations[0]
    check anim.timelines.len == 0

  test "multiple animations in one armature":
    let json = minimalFile(
      """[{"type":"Armature","name":"A","frameRate":24,"bone":[],"slot":[],"ik":[],""" &
      """"animation":[""" & anim0("idle") & "," & anim0("walk") & """]}]""")
    let arms = json.parseDragonBones().armatures[0]
    check arms.animations.len == 2
    check arms.animations[0].name == "idle"
    check arms.animations[1].name == "walk"

# ── Bone timeline: rotateFrame ─────────────────────────────────────────────────

suite "timeline parser — bone rotate":

  test "single bone rotate keyframe":
    let boneJson = """[{"name":"root","rotateFrame":[{"duration":24,"tweenEasing":0,"rotate":90}]}]"""
    let tl = oneAnim(anim0(bone = boneJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0]
    check tl.kind == tlBoneRotate
    check tl.name == "root"
    check tl.rotateKFs.len == 1
    check tl.rotateKFs[0].base.frame    == 0
    check tl.rotateKFs[0].base.duration == 24
    check tl.rotateKFs[0].rotate        == 90.0'f32

  test "fixture sample: rotate 0→90 over 24 frames":
    ## Matches the animation in tests/fixtures/sample/dragon_ske.json.
    let boneJson = """[{"name":"root","rotateFrame":[
      {"duration":24,"tweenEasing":0,"rotate":0},
      {"duration":0,"rotate":90}]}]"""
    let kfs = oneAnim(anim0(duration = 24, bone = boneJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].rotateKFs
    check kfs.len == 2
    check kfs[0].base.frame == 0
    check kfs[0].rotate     == 0.0'f32
    check kfs[1].base.frame == 24   ## accumulated: 0 + 24
    check kfs[1].rotate     == 90.0'f32

  test "frame positions accumulated from durations":
    let boneJson = """[{"name":"b","rotateFrame":[
      {"duration":6,"tweenEasing":0,"rotate":0},
      {"duration":6,"tweenEasing":0,"rotate":30},
      {"duration":12,"tweenEasing":0,"rotate":60},
      {"duration":0,"rotate":90}]}]"""
    let kfs = oneAnim(anim0(bone = boneJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].rotateKFs
    check kfs[0].base.frame == 0
    check kfs[1].base.frame == 6
    check kfs[2].base.frame == 12
    check kfs[3].base.frame == 24

  test "rotate absent defaults to 0.0":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":12}]}]"""
    let kf = oneAnim(anim0(bone = boneJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].rotateKFs[0]
    check kf.rotate == 0.0'f32

# ── Bone timeline: translateFrame ─────────────────────────────────────────────

suite "timeline parser — bone translate":

  test "translate keyframe x y":
    let boneJson = """[{"name":"arm","translateFrame":[
      {"duration":12,"tweenEasing":0,"x":10.0,"y":-5.0},
      {"duration":0,"x":0,"y":0}]}]"""
    let kfs = oneAnim(anim0(bone = boneJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].translateKFs
    check kfs.len == 2
    check kfs[0].x == 10.0'f32
    check kfs[0].y == -5.0'f32
    check kfs[1].base.frame == 12

  test "translate x y absent defaults to 0.0":
    let boneJson = """[{"name":"b","translateFrame":[{"duration":8}]}]"""
    let kf = oneAnim(anim0(bone = boneJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].translateKFs[0]
    check kf.x == 0.0'f32
    check kf.y == 0.0'f32

# ── Bone timeline: scaleFrame ─────────────────────────────────────────────────

suite "timeline parser — bone scale":

  test "scale keyframe x y":
    let boneJson = """[{"name":"b","scaleFrame":[
      {"duration":12,"tweenEasing":0,"x":2.0,"y":0.5},
      {"duration":0}]}]"""
    let kfs = oneAnim(anim0(bone = boneJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].scaleKFs
    check kfs[0].scX == 2.0'f32
    check kfs[0].scY == 0.5'f32

  test "scale x y absent defaults to 1.0 (identity)":
    let boneJson = """[{"name":"b","scaleFrame":[{"duration":12}]}]"""
    let kf = oneAnim(anim0(bone = boneJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].scaleKFs[0]
    check kf.scX == 1.0'f32
    check kf.scY == 1.0'f32

# ── Multiple bone timelines from one bone entry ───────────────────────────────

suite "timeline parser — multiple timelines per bone":

  test "bone with translate rotate scale produces three timelines":
    let boneJson = """[{"name":"root",
      "translateFrame":[{"duration":0,"x":1,"y":2}],
      "rotateFrame":[{"duration":0,"rotate":45}],
      "scaleFrame":[{"duration":0,"x":2,"y":2}]}]"""
    let timelines = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                    .armatures[0].animations[0].timelines
    check timelines.len == 3
    var kinds: set[TimelineKind]
    for tl in timelines: kinds.incl(tl.kind)
    check tlBoneTranslate in kinds
    check tlBoneRotate    in kinds
    check tlBoneScale     in kinds

# ── Tween curve encoding ───────────────────────────────────────────────────────

suite "timeline parser — tween curves":

  test "tweenEasing 0 → tkLinear":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":12,"tweenEasing":0,"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind == tkLinear

  test "tweenEasing absent → tkLinear":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":0,"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind == tkLinear

  test "tweenEasing null → tkLinear (absent/null indistinguishable via jsony Option)":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":12,"tweenEasing":null,"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind == tkLinear

  test "tweenEasing NaN → tkStepped":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":12,"tweenEasing":NaN,"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind == tkStepped

  test "tweenEasing non-zero finite → tkQuad with easing value":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":12,"tweenEasing":0.5,"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind   == tkQuad
    check curve.easing == 0.5'f32

  test "tweenEasing negative quad (ease out)":
    let boneJson = """[{"name":"b","rotateFrame":[{"duration":12,"tweenEasing":-0.5,"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind   == tkQuad
    check curve.easing == -0.5'f32

  test "curve 4 floats → tkBezier control points":
    let boneJson = """[{"name":"b","rotateFrame":[
      {"duration":12,"curve":[0.25,0.1,0.75,0.9],"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind == tkBezier
    check curve.p1x  == 0.25'f32
    check curve.p1y  == 0.1'f32
    check curve.p2x  == 0.75'f32
    check curve.p2y  == 0.9'f32

  test "curve more than 4 floats → tkSampled":
    let boneJson = """[{"name":"b","rotateFrame":[
      {"duration":12,"curve":[0.0,0.1,0.3,0.6,0.8,1.0],"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind        == tkSampled
    check curve.samples.len == 6
    check curve.samples[0]  == 0.0'f32
    check curve.samples[5]  == 1.0'f32

  test "curve overrides tweenEasing when both present":
    let boneJson = """[{"name":"b","rotateFrame":[
      {"duration":12,"tweenEasing":0.5,"curve":[0.1,0.2,0.8,0.9],"rotate":0}]}]"""
    let curve = oneAnim(anim0(bone = boneJson)).parseDragonBones()
                .armatures[0].animations[0].timelines[0].rotateKFs[0].base.curve
    check curve.kind == tkBezier  ## curve wins over tweenEasing

# ── Slot timeline: displayFrame ───────────────────────────────────────────────

suite "timeline parser — slot display":

  test "display keyframe value":
    let slotJson = """[{"name":"weapon","displayFrame":[
      {"duration":12,"value":1},
      {"duration":12,"value":2},
      {"duration":0,"value":0}]}]"""
    let kfs = oneAnim(anim0(slot = slotJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].displayKFs
    check kfs.len == 3
    check kfs[0].displayIndex == 1
    check kfs[1].displayIndex == 2
    check kfs[2].displayIndex == 0

  test "display value absent defaults to 0":
    let slotJson = """[{"name":"s","displayFrame":[{"duration":12}]}]"""
    let kf = oneAnim(anim0(slot = slotJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].displayKFs[0]
    check kf.displayIndex == 0

  test "display value -1 is DisplayIndexHidden":
    let slotJson = """[{"name":"s","displayFrame":[{"duration":12,"value":-1}]}]"""
    let kf = oneAnim(anim0(slot = slotJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].displayKFs[0]
    check kf.displayIndex == DisplayIndexHidden

  test "display frame accumulation":
    let slotJson = """[{"name":"s","displayFrame":[
      {"duration":8,"value":0},
      {"duration":8,"value":1},
      {"duration":0,"value":0}]}]"""
    let kfs = oneAnim(anim0(slot = slotJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].displayKFs
    check kfs[0].base.frame == 0
    check kfs[1].base.frame == 8
    check kfs[2].base.frame == 16

# ── Slot timeline: colorFrame ─────────────────────────────────────────────────

suite "timeline parser — slot color":

  test "color keyframe multipliers divided by 100":
    let slotJson = """[{"name":"s","colorFrame":[
      {"duration":12,"tweenEasing":0,
       "value":{"aM":50,"rM":100,"gM":75,"bM":25,"aO":0,"rO":10,"gO":0,"bO":-5}},
      {"duration":0,"value":{"aM":100,"rM":100,"gM":100,"bM":100}}]}]"""
    let kfs = oneAnim(anim0(slot = slotJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].colorKFs
    check kfs.len == 2
    check kfs[0].color.aM == 0.5'f32
    check kfs[0].color.rM == 1.0'f32
    check kfs[0].color.gM == 0.75'f32
    check kfs[0].color.bM == 0.25'f32
    check kfs[0].color.rO == 10.0'f32
    check kfs[0].color.bO == -5.0'f32

  test "color value absent → identity color":
    let slotJson = """[{"name":"s","colorFrame":[{"duration":12,"tweenEasing":0}]}]"""
    let kf = oneAnim(anim0(slot = slotJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].colorKFs[0]
    check kf.color.aM == 1.0'f32
    check kf.color.rM == 1.0'f32
    check kf.color.gM == 1.0'f32
    check kf.color.bM == 1.0'f32
    check kf.color.aO == 0.0'f32

  test "color multiplier absent defaults to 1.0 (100/100)":
    let slotJson = """[{"name":"s","colorFrame":[{"duration":0,"value":{"aO":0}}]}]"""
    let kf = oneAnim(anim0(slot = slotJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].colorKFs[0]
    check kf.color.aM == 1.0'f32
    check kf.color.rM == 1.0'f32

# ── IK timeline ───────────────────────────────────────────────────────────────

suite "timeline parser — IK":

  test "ik keyframe all fields":
    let ikJson = """[{"name":"armIK","frame":[
      {"duration":12,"tweenEasing":0,"bendPositive":1,"weight":0.8},
      {"duration":0,"bendPositive":0,"weight":0.5}]}]"""
    let kfs = oneAnim(anim0(ik = ikJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].ikKFs
    check kfs.len == 2
    check kfs[0].bendPositive == true
    check kfs[0].weight       == 0.8'f32
    check kfs[1].bendPositive == false
    check kfs[1].weight       == 0.5'f32

  test "ik bendPositive absent defaults to true":
    let ikJson = """[{"name":"ik","frame":[{"duration":12}]}]"""
    let kf = oneAnim(anim0(ik = ikJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].ikKFs[0]
    check kf.bendPositive == true

  test "ik weight absent defaults to 1.0":
    let ikJson = """[{"name":"ik","frame":[{"duration":12}]}]"""
    let kf = oneAnim(anim0(ik = ikJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].ikKFs[0]
    check kf.weight == 1.0'f32

  test "ik frame accumulation":
    let ikJson = """[{"name":"ik","frame":[
      {"duration":8},{"duration":8},{"duration":0}]}]"""
    let kfs = oneAnim(anim0(ik = ikJson)).parseDragonBones()
              .armatures[0].animations[0].timelines[0].ikKFs
    check kfs[0].base.frame == 0
    check kfs[1].base.frame == 8
    check kfs[2].base.frame == 16

  test "ik timeline name matches JSON name":
    let ikJson = """[{"name":"legIK","frame":[{"duration":0}]}]"""
    let tl = oneAnim(anim0(ik = ikJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0]
    check tl.kind == tlIK
    check tl.name == "legIK"

# ── FFD timeline ──────────────────────────────────────────────────────────────

suite "timeline parser — FFD":

  test "ffd keyframe vertex deform offsets":
    let ffdJson = """[{"name":"default","slot":"arm_slot","display":"arm_mesh","frame":[
      {"duration":12,"tweenEasing":0,"offset":0,"vertices":[1.0,2.0,3.0,4.0]},
      {"duration":0,"vertices":[]}]}]"""
    let tl = oneAnim(anim0(ffd = ffdJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0]
    check tl.kind          == tlFFD
    check tl.ffdSkinName   == "default"
    check tl.ffdSlotName   == "arm_slot"
    check tl.ffdDisplayName == "arm_mesh"
    check tl.ffdKFs.len    == 2
    let kf0 = tl.ffdKFs[0]
    check kf0.offset       == 0
    check kf0.vertices.len == 2  ## 4 floats → 2 Vec2
    check kf0.vertices[0].x == 1.0'f32
    check kf0.vertices[0].y == 2.0'f32
    check kf0.vertices[1].x == 3.0'f32
    check kf0.vertices[1].y == 4.0'f32

  test "ffd vertex offset field":
    let ffdJson = """[{"name":"skin","slot":"s","display":"d","frame":[
      {"duration":12,"offset":4,"vertices":[0.5,0.5]}]}]"""
    let kf = oneAnim(anim0(ffd = ffdJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].ffdKFs[0]
    check kf.offset == 4

  test "ffd vertices absent → empty":
    let ffdJson = """[{"name":"s","slot":"sl","display":"d","frame":[{"duration":0}]}]"""
    let kf = oneAnim(anim0(ffd = ffdJson)).parseDragonBones()
             .armatures[0].animations[0].timelines[0].ffdKFs[0]
    check kf.vertices.len == 0

# ── ZOrder timeline ───────────────────────────────────────────────────────────

suite "timeline parser — zOrder":

  test "zorder keyframe slot offset pairs":
    let zOrderJson = """{"frame":[
      {"duration":12,"zOrder":[0,1,2,-1]},
      {"duration":0,"zOrder":[]}]}"""
    let json = minimalFile(
      """[{"type":"Armature","name":"A","frameRate":24,"bone":[],"slot":[],"ik":[],""" &
      """"animation":[{"name":"a","duration":12,"playTimes":0,""" &
      """"bone":[],"slot":[],"ffd":[],"ik":[],"zOrder":""" & zOrderJson & """}]}]""")
    let timelines = json.parseDragonBones().armatures[0].animations[0].timelines
    check timelines.len == 1
    let tl = timelines[0]
    check tl.kind == tlZOrder
    check tl.zOrderKFs.len == 2
    let kf0 = tl.zOrderKFs[0]
    check kf0.slotOffsets.len == 2
    check kf0.slotOffsets[0].slotIndex == 0
    check kf0.slotOffsets[0].zOffset   == 1
    check kf0.slotOffsets[1].slotIndex == 2
    check kf0.slotOffsets[1].zOffset   == -1

  test "zorder absent produces no zorder timeline":
    let json = minimalFile(
      """[{"type":"Armature","name":"A","frameRate":24,"bone":[],"slot":[],"ik":[],""" &
      """"animation":[""" & anim0() & """]}]""")
    let timelines = json.parseDragonBones().armatures[0].animations[0].timelines
    var hasZOrder = false
    for tl in timelines:
      if tl.kind == tlZOrder: hasZOrder = true
    check hasZOrder == false

  test "zorder frame accumulation":
    let zOrderJson = """{"frame":[
      {"duration":6,"zOrder":[0,1]},
      {"duration":6,"zOrder":[0,-1]},
      {"duration":0,"zOrder":[]}]}"""
    let json = minimalFile(
      """[{"type":"Armature","name":"A","frameRate":24,"bone":[],"slot":[],"ik":[],""" &
      """"animation":[{"name":"a","duration":12,"playTimes":0,""" &
      """"bone":[],"slot":[],"ffd":[],"ik":[],"zOrder":""" & zOrderJson & """}]}]""")
    let kfs = json.parseDragonBones().armatures[0].animations[0].timelines[0].zOrderKFs
    check kfs[0].base.frame == 0
    check kfs[1].base.frame == 6
    check kfs[2].base.frame == 12

# ── Mixed timelines ───────────────────────────────────────────────────────────

suite "timeline parser — mixed timelines":

  test "animation with bone slot ik timelines":
    let boneJson = """[{"name":"root","rotateFrame":[{"duration":0,"rotate":0}]}]"""
    let slotJson = """[{"name":"s","displayFrame":[{"duration":0,"value":1}]}]"""
    let ikJson   = """[{"name":"ik1","frame":[{"duration":0}]}]"""
    let timelines = oneAnim(anim0(bone = boneJson, slot = slotJson, ik = ikJson))
                    .parseDragonBones().armatures[0].animations[0].timelines
    check timelines.len == 3
    var kinds: set[TimelineKind]
    for tl in timelines: kinds.incl(tl.kind)
    check tlBoneRotate   in kinds
    check tlSlotDisplay  in kinds
    check tlIK           in kinds
