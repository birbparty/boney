import std/unittest
import vmath
import dragonbones/model/model
import dragonbones/parse/armature
import dragonbones/parse/slot

# ── Helpers ────────────────────────────────────────────────────────────────────

proc withSkin(skinJson: string): string =
  ## Minimal DragonBones JSON with one armature containing the given skin array.
  """{"version":"5.7.0","compatibleVersion":"5.0.0","name":"Dragon","frameRate":24,""" &
  """"armature":[{"type":"Armature","name":"Hero","frameRate":30,""" &
  """"bone":[],"slot":[],"ik":[],"skin":""" & skinJson & "}]}"

proc arm(json: string): ArmatureData =
  json.parseDragonBones().armatures[0]

proc oneSkin(slotJson: string, skinName = ""): string =
  ## One-skin JSON with a single slot containing the given display array.
  withSkin("""[{"name":"""" & skinName & """","slot":[""" & slotJson & "]}]")

proc oneSlot(displays: string, slotName = "body"): string =
  """{"name":"""" & slotName & """","display":""" & displays & "}"

# ── No skins ───────────────────────────────────────────────────────────────────

suite "slot/skin parser — empty":

  test "armature with no skin key has empty skins":
    let json = """{"version":"5.7.0","compatibleVersion":"5.0.0","name":"D",
      "frameRate":24,"armature":[{"type":"Armature","name":"A",
      "frameRate":24,"bone":[],"slot":[],"ik":[]}]}"""
    check json.parseDragonBones().armatures[0].skins.len == 0

  test "empty skin array":
    check withSkin("[]").arm().skins.len == 0

# ── Skin structure ─────────────────────────────────────────────────────────────

suite "slot/skin parser — structure":

  test "skin name preserved":
    let json = withSkin("""[{"name":"default","slot":[]}]""")
    check json.arm().skins[0].name == "default"

  test "empty-string skin name (default DragonBones convention)":
    let json = withSkin("""[{"name":"","slot":[]}]""")
    check json.arm().skins[0].name == ""

  test "multiple skins":
    let json = withSkin("""[{"name":"default","slot":[]},{"name":"alt","slot":[]}]""")
    let skins = json.arm().skins
    check skins.len == 2
    check skins[0].name == "default"
    check skins[1].name == "alt"

  test "skin slot name preserved":
    let json = oneSkin(oneSlot("[]", slotName = "weapon_slot"))
    check json.arm().skins[0].slots[0].slotName == "weapon_slot"

  test "empty display list":
    let json = oneSkin(oneSlot("[]"))
    check json.arm().skins[0].slots[0].displays.len == 0

# ── Image display ──────────────────────────────────────────────────────────────

suite "slot/skin parser — image display":

  test "image type parses as dkImage":
    let d = oneSkin(oneSlot("""[{"type":"image","name":"body_tex"}]""")).arm()
              .skins[0].slots[0].displays[0]
    check d.kind == dkImage
    check d.name == "body_tex"

  test "absent type defaults to dkImage (lenient)":
    let d = oneSkin(oneSlot("""[{"name":"sprite"}]""")).arm()
              .skins[0].slots[0].displays[0]
    check d.kind == dkImage

  test "unknown type defaults to dkImage (lenient)":
    let d = oneSkin(oneSlot("""[{"type":"video","name":"something"}]""")).arm()
              .skins[0].slots[0].displays[0]
    check d.kind == dkImage

  test "image transform absent yields identity":
    let t = oneSkin(oneSlot("""[{"type":"image","name":"tex"}]""")).arm()
              .skins[0].slots[0].displays[0].transform
    check t.x   == 0.0'f32
    check t.y   == 0.0'f32
    check t.scX == 1.0'f32
    check t.scY == 1.0'f32

  test "image transform explicit values":
    let d = oneSkin(oneSlot(
      """[{"type":"image","name":"t","transform":{"x":10,"y":-5,"scX":2.0,"scY":0.5}}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.transform.x   == 10.0'f32
    check d.transform.y   == -5.0'f32
    check d.transform.scX == 2.0'f32
    check d.transform.scY == 0.5'f32

  test "transform scX/scY absent default to 1.0 (not Nim's 0.0 default)":
    let t = oneSkin(oneSlot(
      """[{"type":"image","name":"t","transform":{"x":1,"y":2}}]"""
    )).arm().skins[0].slots[0].displays[0].transform
    check t.scX == 1.0'f32
    check t.scY == 1.0'f32

# ── Mesh display ───────────────────────────────────────────────────────────────

suite "slot/skin parser — mesh display":

  test "mesh type parses as dkMesh":
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"body_mesh","width":200,"height":100,
          "vertices":[0,0,100,0,100,50,0,50],
          "uvs":[0,0,1,0,1,0.5,0,0.5],
          "triangles":[0,1,2,0,2,3]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.kind == dkMesh
    check d.name == "body_mesh"

  test "mesh width and height":
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":200,"height":100,
          "vertices":[],"uvs":[],"triangles":[]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.mesh.width  == 200.0'f32
    check d.mesh.height == 100.0'f32

  test "mesh vertices parsed as Vec2 pairs":
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[10,20,30,40],"uvs":[0,0,1,1],"triangles":[0,1,0]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.mesh.vertices.len == 2
    check d.mesh.vertices[0].x == 10.0'f32
    check d.mesh.vertices[0].y == 20.0'f32
    check d.mesh.vertices[1].x == 30.0'f32
    check d.mesh.vertices[1].y == 40.0'f32

  test "mesh UVs parsed as Vec2 pairs":
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[0,0,1,0],"uvs":[0.0,0.0,1.0,0.5],"triangles":[0,1,0]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.mesh.uvs[0].x == 0.0'f32
    check d.mesh.uvs[1].x == 1.0'f32
    check d.mesh.uvs[1].y == 0.5'f32

  test "mesh triangles as uint16 indices":
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[0,0,1,0,0,1],"uvs":[0,0,1,0,0,1],"triangles":[0,1,2]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.mesh.indices == @[0'u16, 1'u16, 2'u16]

  test "non-skinned mesh has empty vertexWeights":
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[0,0,1,0],"uvs":[0,0,1,0],"triangles":[0,1,0]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.mesh.vertexWeights.len == 0

  test "skinned mesh weight unpacking":
    ## 2 vertices: v0 has 1 influence (bone 0, w=1.0), v1 has 2 (bone 0 w=0.5, bone 1 w=0.5).
    ## bonePose: localIdx 0 → global 3; localIdx 1 → global 7.
    ## weights: [1,  0, 1.0,   2,  0, 0.5, 1, 0.5]
    ## bonePose: [3, 1,0,0,1,0,0,  7, 1,0,0,1,0,0]  (7 floats each)
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[0,0,1,0],
          "uvs":[0,0,1,0],
          "triangles":[0,1,0],
          "weights":[1,0,1.0, 2,0,0.5,1,0.5],
          "bonePose":[3,1,0,0,1,0,0, 7,1,0,0,1,0,0]}]"""
    )).arm().skins[0].slots[0].displays[0]
    let wts = d.mesh.vertexWeights
    check wts.len == 2
    # vertex 0: one influence, global bone index 3
    check wts[0].len == 1
    check wts[0][0].boneIndex == 3'u16
    check wts[0][0].weight    == 1.0'f32
    # vertex 1: two influences — global 3 and 7
    check wts[1].len == 2
    check wts[1][0].boneIndex == 3'u16
    check wts[1][0].weight    == 0.5'f32
    check wts[1][1].boneIndex == 7'u16
    check wts[1][1].weight    == 0.5'f32

  test "weighted mesh with empty vertices uses UV count for vertexCount":
    ## Real DragonBones weighted meshes may omit vertex positions (geometry
    ## comes from bone transforms). Vertex count must come from UVs, not vertices.
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[],
          "uvs":[0,0,1,0],
          "triangles":[0,1,0],
          "weights":[1,0,1.0, 1,0,0.8],
          "bonePose":[5,1,0,0,1,0,0]}]"""
    )).arm().skins[0].slots[0].displays[0]
    ## vertexCount should be 2 (from uvs.len div 2), not 0 (from vertices.len div 2)
    check d.mesh.vertexWeights.len == 2
    check d.mesh.vertexWeights[0][0].boneIndex == 5'u16
    check d.mesh.vertexWeights[0][0].weight    == 1.0'f32
    check d.mesh.vertexWeights[1][0].boneIndex == 5'u16
    check d.mesh.vertexWeights[1][0].weight    == 0.8'f32

  test "out-of-range localIdx in bonePose is silently dropped (no IndexDefect)":
    ## localIdx=99 is out of bounds for a bonePose with 1 entry (index 0 only).
    ## The malformed influence must be dropped, not panic.
    let d = oneSkin(oneSlot(
      """[{"type":"mesh","name":"m","width":0,"height":0,
          "vertices":[0,0],
          "uvs":[0,0],
          "triangles":[0,0,0],
          "weights":[2, 0,0.5, 99,0.5],
          "bonePose":[1,1,0,0,1,0,0]}]"""
    )).arm().skins[0].slots[0].displays[0]
    ## localIdx=0 is valid (global bone 1, w=0.5); localIdx=99 is invalid and dropped.
    check d.mesh.vertexWeights[0].len == 1
    check d.mesh.vertexWeights[0][0].boneIndex == 1'u16
    check d.mesh.vertexWeights[0][0].weight    == 0.5'f32

# ── Armature display ───────────────────────────────────────────────────────────

suite "slot/skin parser — armature display":

  test "armature type parses as dkArmature":
    let d = oneSkin(oneSlot(
      """[{"type":"armature","name":"ChildArm"}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.kind == dkArmature
    check d.childArmatureName == "ChildArm"

  test "armature display name IS the child armature name":
    let d = oneSkin(oneSlot(
      """[{"type":"armature","name":"Sword"}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.name == "Sword"
    check d.childArmatureName == "Sword"

# ── BoundingBox display ────────────────────────────────────────────────────────

suite "slot/skin parser — bounding box display":

  test "boundingBox rectangle has 4 corner vertices":
    let d = oneSkin(oneSlot(
      """[{"type":"boundingBox","name":"bb","subType":"rectangle","width":80,"height":40}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.kind    == dkBoundingBox
    check d.bbShape == bbsRectangle
    check d.bbVertices.len == 4

  test "rectangle corners at ±w/2, ±h/2":
    let d = oneSkin(oneSlot(
      """[{"type":"boundingBox","name":"bb","subType":"rectangle","width":80,"height":40}]"""
    )).arm().skins[0].slots[0].displays[0]
    ## Expect corners [-40,-20], [40,-20], [40,20], [-40,20] (CCW from top-left)
    check d.bbVertices[0].x == -40.0'f32
    check d.bbVertices[0].y == -20.0'f32
    check d.bbVertices[1].x ==  40.0'f32
    check d.bbVertices[2].x ==  40.0'f32
    check d.bbVertices[2].y ==  20.0'f32

  test "rectangle absent subType defaults to rectangle":
    let d = oneSkin(oneSlot(
      """[{"type":"boundingBox","name":"bb","width":10,"height":10}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.bbShape == bbsRectangle

  test "boundingBox ellipse has 2 semi-axis Vec2s":
    let d = oneSkin(oneSlot(
      """[{"type":"boundingBox","name":"bb","subType":"ellipse","width":60,"height":40}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.kind    == dkBoundingBox
    check d.bbShape == bbsEllipse
    check d.bbVertices.len == 2
    check d.bbVertices[0].x == 30.0'f32  ## rx = width/2
    check d.bbVertices[0].y ==  0.0'f32
    check d.bbVertices[1].x ==  0.0'f32
    check d.bbVertices[1].y == 20.0'f32  ## ry = height/2

  test "boundingBox polygon uses vertices from JSON":
    let d = oneSkin(oneSlot(
      """[{"type":"boundingBox","name":"bb","subType":"polygon",
          "vertices":[0,0,50,0,25,50]}]"""
    )).arm().skins[0].slots[0].displays[0]
    check d.kind    == dkBoundingBox
    check d.bbShape == bbsPolygon
    check d.bbVertices.len == 3
    check d.bbVertices[0].x ==  0.0'f32
    check d.bbVertices[1].x == 50.0'f32
    check d.bbVertices[2].x == 25.0'f32
    check d.bbVertices[2].y == 50.0'f32

# ── Multiple displays per slot ─────────────────────────────────────────────────

suite "slot/skin parser — multiple displays":

  test "multiple display items in one slot":
    let json = oneSkin(oneSlot(
      """[{"type":"image","name":"frame0"},{"type":"image","name":"frame1"},
         {"type":"image","name":"frame2"}]"""
    ))
    let displays = json.arm().skins[0].slots[0].displays
    check displays.len == 3
    check displays[0].name == "frame0"
    check displays[2].name == "frame2"

  test "mixed display types in one slot":
    let json = oneSkin(oneSlot(
      """[{"type":"image","name":"sprite"},{"type":"mesh","name":"hair_mesh",
          "width":100,"height":100,"vertices":[],"uvs":[],"triangles":[]}]"""
    ))
    let displays = json.arm().skins[0].slots[0].displays
    check displays[0].kind == dkImage
    check displays[1].kind == dkMesh

# ── parseSkins direct unit tests ───────────────────────────────────────────────

suite "parseSkins — direct":

  test "empty input returns empty seq":
    check parseSkins(@[]).len == 0

  test "one empty skin":
    let raw = @[RawSkin(name: "default", slot: @[])]
    let skins = parseSkins(raw)
    check skins.len == 1
    check skins[0].name == "default"
    check skins[0].slots.len == 0
