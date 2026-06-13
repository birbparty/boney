import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/atlas/atlas
import dragonbones/anim/sample
import dragonbones/anim/propagate
import dragonbones/boundary
import dragonbones/anim/emit

# ── Test fixtures ─────────────────────────────────────────────────────────────

const EPS = 1e-4'f32

proc approx(a, b: float32): bool = abs(a - b) < EPS
proc approxV(a, b: Vec2): bool = approx(a.x, b.x) and approx(a.y, b.y)

proc mkArm(): ArmatureData =
  ArmatureData(
    name: "test",
    frameRate: 24,
    bones: @[BoneData(name: "root", transform: dbTransformIdentity())],
    slots: @[
      SlotData(name: "slot0", boneName: "root",
               displayIndex: 0, color: dbColorIdentity())])

proc mkSkinImage(name: string): SkinData =
  SkinData(name: "",
    slots: @[SkinSlot(
      slotName: "slot0",
      displays: @[DisplayData(name: name, kind: dkImage,
                               transform: DbTransform(scX: 1.0'f32, scY: 1.0'f32))])])

proc mkAtlas(atlasW, atlasH: int): AtlasData =
  ## 64×32 sprite at atlas position (0, 0), no rotation, no trim.
  AtlasData(
    name:      "tex",
    imagePath: "tex.png",
    width:     atlasW,
    height:    atlasH,
    scale:     1.0'f32,
    subTextures: @[AtlasSubTexture(
      name:        "sprite",
      rotated:     false,
      frameWidth:  64, frameHeight: 32,
      frameX:      0,  frameY:      0,
      atlasX:      0,  atlasY:      0,
      atlasW:      64, atlasH:      32,
      quadVerts:   [vec2(0, 0), vec2(64, 0), vec2(64, 32), vec2(0, 32)],
      quadUVs:     [vec2(0, 0), vec2(0.25'f32, 0), vec2(0.25'f32, 0.5'f32), vec2(0, 0.5'f32)])])

proc mkMeshAtlas(): AtlasData =
  AtlasData(name: "tex", imagePath: "tex.png", width: 128, height: 128, scale: 1.0'f32,
    subTextures: @[AtlasSubTexture(name: "mesh", rotated: false,
      frameWidth: 64, frameHeight: 64, frameX: 0, frameY: 0,
      atlasX: 0, atlasY: 0, atlasW: 64, atlasH: 64,
      quadVerts: [vec2(0, 0), vec2(64, 0), vec2(64, 64), vec2(0, 64)],
      quadUVs:   [vec2(0, 0), vec2(0.5'f32, 0), vec2(0.5'f32, 0.5'f32), vec2(0, 0.5'f32)])])

proc sampleAndPropagateIdentity(armData: ArmatureData): tuple[bones: seq[BoneState], slots: seq[SlotState]] =
  ## Sample empty animation (rest pose) + propagate world transforms.
  var bones = newSeq[BoneState](armData.bones.len)
  var slots = newSeq[SlotState](armData.slots.len)
  let emptyAnim = AnimationData(name: "idle", duration: 24, playTimes: 0)
  sampleAnimation(emptyAnim, armData, 0.0'f32, bones, slots)
  var scratch: seq[DbTransform]
  propagateWorldTransforms(armData, bones, scratch)
  (bones, slots)

const TestHandle = TextureHandle(1)

# ── Identity pose ─────────────────────────────────────────────────────────────

suite "emitDrawCommands — identity pose":

  test "visible image slot produces one dcQuad":
    let arm = mkArm()
    let skin = mkSkinImage("sprite")
    let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var drawOrder = @[0]
    var cmds: seq[DrawCommand]
    var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots,
                     drawOrder, @[], cmds, scratch)
    check cmds.len == 1
    check cmds[0].kind == dcQuad

  test "dcQuad has correct TextureHandle":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds[0].quad.texture == TestHandle

  test "dcQuad srcRect matches atlas pixel sub-rect":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    let sr = cmds[0].quad.srcRect
    check approx(sr.x, 0.0'f32) and approx(sr.y, 0.0'f32)
    check approx(sr.w, 64.0'f32) and approx(sr.h, 32.0'f32)

  test "dcQuad dstQuad TL is at origin for identity bone":
    ## root bone at origin with identity transform → sprite TL at (0, 0)
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check approxV(cmds[0].quad.dstQuad[0], vec2(0.0'f32, 0.0'f32))

  test "dcQuad dstQuad BR matches sprite pixel size":
    ## Identity bone; sprite 64×32 → BR at (64, 32)
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check approxV(cmds[0].quad.dstQuad[2], vec2(64.0'f32, 32.0'f32))

  test "dcQuad uvQuad corners match atlas subtexture UVs":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    ## UV TL = (0, 0); UV TR = (64/256, 0) = (0.25, 0)
    check approxV(cmds[0].quad.uvQuad[0], vec2(0.0'f32, 0.0'f32))
    check approxV(cmds[0].quad.uvQuad[1], vec2(0.25'f32, 0.0'f32))

  test "dcQuad atlasRotated is false for non-rotated sprite":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check not cmds[0].quad.atlasRotated

  test "dcQuad color comes from slot state (rest pose = identity)":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check approx(cmds[0].quad.color.aM, 1.0'f32)
    check approx(cmds[0].quad.color.rM, 1.0'f32)

# ── Hidden / missing slots ────────────────────────────────────────────────────

suite "emitDrawCommands — slot visibility":

  test "displayIndex=-1 skips slot (hidden)":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (_, rawSlots) = sampleAndPropagateIdentity(arm)
    var slots = rawSlots
    slots[0].displayIndex = -1
    var bones = newSeq[BoneState](1)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds.len == 0

  test "displayIndex out of range skips slot":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (_, rawSlots) = sampleAndPropagateIdentity(arm)
    var slots = rawSlots
    slots[0].displayIndex = 99
    var bones = newSeq[BoneState](1)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds.len == 0

  test "display name not in atlas skips slot (no crash)":
    let arm = mkArm(); let skin = mkSkinImage("nonexistent"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds.len == 0

  test "empty drawOrder produces no commands":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[], @[], cmds, scratch)
    check cmds.len == 0

# ── Bone translation propagates to dstQuad ────────────────────────────────────

suite "emitDrawCommands — bone world transform":

  test "bone translated to (100, 50) shifts all quad corners":
    var arm = mkArm()
    arm.bones[0].transform.x = 100.0'f32
    arm.bones[0].transform.y = 50.0'f32
    let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    ## TL should now be at (100, 50)
    check approxV(cmds[0].quad.dstQuad[0], vec2(100.0'f32, 50.0'f32))
    ## BR at (100+64, 50+32)
    check approxV(cmds[0].quad.dstQuad[2], vec2(164.0'f32, 82.0'f32))

  test "bone at 90° rotation: TL→(0,0), TR→(0,64) — sprite rotates CW in world":
    ## root bone rotated 90° CCW: skX=skY=90°
    ## dbTransformToMat3 for skX=skY=90°: cos(90)≈0, sin(90)≈1
    ## col0=[0,1,0], col1=[-1,0,0], col2=[0,0,1]
    ## quadVerts[0]=TL=(0,0) → (0,0); quadVerts[1]=TR=(64,0) → (0,64)
    var arm = mkArm()
    arm.bones[0].transform.skX = 90.0'f32
    arm.bones[0].transform.skY = 90.0'f32
    let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check approxV(cmds[0].quad.dstQuad[0], vec2(0.0'f32, 0.0'f32))
    check approxV(cmds[0].quad.dstQuad[1], vec2(0.0'f32, 64.0'f32))

# ── zOrder propagates ─────────────────────────────────────────────────────────

suite "emitDrawCommands — zOrder":

  test "zOrder equals the index in drawOrder (not slot index)":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    ## drawOrder[0] = slot 0 → zOrder should be 0
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds[0].zOrder == 0

# ── Mesh display ──────────────────────────────────────────────────────────────

suite "emitDrawCommands — mesh display":

  test "dkMesh slot produces dcMesh":
    var arm = mkArm()
    let meshData = MeshData(
      width: 64, height: 64,
      vertices: @[vec2(0, 0), vec2(32, 0), vec2(32, 32)],
      uvs:      @[vec2(0, 0), vec2(0.5'f32, 0), vec2(0.5'f32, 0.5'f32)],
      indices:  @[uint16(0), uint16(1), uint16(2)])
    let skin = SkinData(name: "",
      slots: @[SkinSlot(slotName: "slot0", displays: @[
        DisplayData(name: "mesh", kind: dkMesh, mesh: meshData,
                     transform: DbTransform(scX: 1.0'f32, scY: 1.0'f32))])])
    let atlas = mkMeshAtlas()
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds.len == 1
    check cmds[0].kind == dcMesh

  test "dcMesh vertices length matches mesh vertex count":
    var arm = mkArm()
    let meshData = MeshData(
      width: 64, height: 64,
      vertices: @[vec2(0, 0), vec2(32, 0), vec2(32, 32), vec2(0, 32)],
      uvs:      @[vec2(0, 0), vec2(0.5'f32, 0), vec2(0.5'f32, 0.5'f32), vec2(0, 0.5'f32)],
      indices:  @[uint16(0), uint16(1), uint16(2), uint16(0), uint16(2), uint16(3)])
    let skin = SkinData(name: "",
      slots: @[SkinSlot(slotName: "slot0", displays: @[
        DisplayData(name: "mesh", kind: dkMesh, mesh: meshData,
                     transform: DbTransform(scX: 1.0'f32, scY: 1.0'f32))])])
    let atlas = mkMeshAtlas()
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds[0].mesh.vertices.len == 4

  test "non-skinned mesh vertex (0,0) at identity bone stays at (0,0)":
    var arm = mkArm()
    let meshData = MeshData(
      width: 32, height: 32,
      vertices: @[vec2(0, 0), vec2(32, 0), vec2(32, 32)],
      uvs:      @[vec2(0, 0), vec2(0.5'f32, 0), vec2(0.5'f32, 0.5'f32)],
      indices:  @[uint16(0), uint16(1), uint16(2)])
    let skin = SkinData(name: "",
      slots: @[SkinSlot(slotName: "slot0", displays: @[
        DisplayData(name: "mesh", kind: dkMesh, mesh: meshData,
                     transform: DbTransform(scX: 1.0'f32, scY: 1.0'f32))])])
    let atlas = mkMeshAtlas()
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check approxV(cmds[0].mesh.vertices[0], vec2(0.0'f32, 0.0'f32))
    check approxV(cmds[0].mesh.vertices[1], vec2(32.0'f32, 0.0'f32))

# ── Output reuse ─────────────────────────────────────────────────────────────

suite "emitDrawCommands — output management":

  test "second call clears and refills output":
    let arm = mkArm(); let skin = mkSkinImage("sprite"); let atlas = mkAtlas(256, 64)
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check cmds.len == 1
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[], @[], cmds, scratch)
    check cmds.len == 0

  test "meshScratch auto-grows from empty":
    var arm = mkArm()
    let meshData = MeshData(vertices: @[vec2(0, 0), vec2(1, 0), vec2(1, 1)],
      uvs: @[vec2(0,0), vec2(1,0), vec2(1,1)],
      indices: @[uint16(0), uint16(1), uint16(2)])
    let skin = SkinData(name: "",
      slots: @[SkinSlot(slotName: "slot0", displays: @[
        DisplayData(name: "mesh", kind: dkMesh, mesh: meshData,
                     transform: DbTransform(scX: 1.0'f32, scY: 1.0'f32))])])
    let atlas = mkMeshAtlas()
    let (bones, slots) = sampleAndPropagateIdentity(arm)
    var cmds: seq[DrawCommand]; var scratch: seq[Vec2]
    ## scratch starts empty
    check scratch.len == 0
    emitDrawCommands(arm, skin, atlas, TestHandle, bones, slots, @[0], @[], cmds, scratch)
    check scratch.len >= 3
