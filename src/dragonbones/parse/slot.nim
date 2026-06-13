## Parse DragonBones skin / display data from JSON 5.5–5.7.
##
## Exports raw wire types (RawSkin, RawSkinSlot, RawDisplayItem) so that
## parse/armature.nim can include them in RawArmature for a single-pass jsony parse.
## Entry point for callers: parseSkins(raw).

import std/[options, sequtils]
import vmath
import dragonbones/model/model

# ── Private helpers ────────────────────────────────────────────────────────────

type
  ## Exported so that armature.nim can call fromJson(RawFile) without a
  ## 'type not accessible' error — SlotRawTransform is nested inside
  ## RawDisplayItem.transform which armature.nim's jsony expansion must visit.
  SlotRawTransform* = object
    x*: float32
    y*: float32
    skX*: float32
    skY*: float32
    scX*: Option[float32]   ## absent → 1.0 (identity scale)
    scY*: Option[float32]   ## absent → 1.0 (identity scale)

proc toDbTransform(r: Option[SlotRawTransform]): DbTransform =
  if r.isNone: return dbTransformIdentity()
  let t = r.get()
  DbTransform(x: t.x, y: t.y, skX: t.skX, skY: t.skY,
              scX: t.scX.get(1.0'f32), scY: t.scY.get(1.0'f32))

# ── Public raw wire types (used by armature.nim inside RawArmature) ────────────

type
  ## Flat raw display item: one struct covers all display types since jsony
  ## requires concrete types. Discriminate on `displayType` during conversion.
  RawDisplayItem* = object
    displayType*: string               ## JSON "type" renamed via renameHook
    name*: string
    transform*: Option[SlotRawTransform]
    ## Mesh / bounding-box shared fields
    width*: float32
    height*: float32
    ## Mesh vertex data (flat float pairs: x0,y0,x1,y1,...)
    vertices*: seq[float32]
    uvs*: seq[float32]                 ## normalized 0–1 flat pairs
    triangles*: seq[int]               ## triangle index list
    ## Skinned-mesh weight data (packed: count,boneLocalIdx,w,boneLocalIdx,w,...)
    weights*: seq[float32]
    ## Bone pose matrices: [globalBoneIdx, a, b, c, d, tx, ty, ...] per bone
    bonePose*: seq[float32]
    ## Bounding-box sub-shape: "rectangle" | "ellipse" | "polygon"
    subType*: string

  RawSkinSlot* = object
    name*: string
    display*: seq[RawDisplayItem]

  RawSkin* = object
    name*: string
    slot*: seq[RawSkinSlot]

# ── jsony hooks ────────────────────────────────────────────────────────────────

proc renameHook*(v: var RawDisplayItem, fieldName: var string) =
  ## Map JSON "type" → "displayType" to avoid the Nim keyword clash.
  if fieldName == "type": fieldName = "displayType"

# ── Conversion helpers (private) ───────────────────────────────────────────────

proc pairsToVec2(flat: seq[float32]): seq[Vec2] =
  let n = flat.len div 2
  result = newSeq[Vec2](n)
  for i in 0 ..< n:
    result[i] = vec2(flat[i * 2], flat[i * 2 + 1])

proc parseVertexWeights(weights: seq[float32], bonePose: seq[float32],
                        vertexCount: int): seq[seq[VertexWeight]] =
  ## Unpack DragonBones packed weight array into per-vertex VertexWeight lists.
  ## weights[] encoding per vertex: [numInfluences, localIdx, w, localIdx, w, ...]
  ## bonePose[] encoding: [globalBoneIdx, a, b, c, d, tx, ty, ...] (7 floats each)
  ## Returns empty seq for non-skinned meshes (weights.len == 0).
  if weights.len == 0: return @[]
  result = newSeq[seq[VertexWeight]](vertexCount)
  var i = 0
  for v in 0 ..< vertexCount:
    if i >= weights.len: break
    let count = int(weights[i])
    inc i
    result[v] = newSeq[VertexWeight](count)
    for j in 0 ..< count:
      if i + 1 >= weights.len: break
      let localIdx = int(weights[i])
      let w = weights[i + 1]
      inc i, 2
      ## globalBoneIdx is the 0-based index into ArmatureData.bones
      let globalIdx = uint16(int(bonePose[localIdx * 7]))
      result[v][j] = VertexWeight(boneIndex: globalIdx, weight: w)

proc toBoundingBoxVerts(d: RawDisplayItem, shape: BoundingBoxShape): seq[Vec2] =
  case shape
  of bbsPolygon:
    d.vertices.pairsToVec2()
  of bbsRectangle:
    ## 4 corners in CCW order from center; hit-test uses these for AABB.
    let w2 = d.width / 2.0'f32
    let h2 = d.height / 2.0'f32
    @[vec2(-w2, -h2), vec2(w2, -h2), vec2(w2, h2), vec2(-w2, h2)]
  of bbsEllipse:
    ## Semi-axis endpoints: [Vec2(rx,0), Vec2(0,ry)].
    @[vec2(d.width / 2.0'f32, 0.0'f32), vec2(0.0'f32, d.height / 2.0'f32)]

proc toDisplayData(d: RawDisplayItem): DisplayData =
  let kind = case d.displayType
    of "mesh":        dkMesh
    of "armature":    dkArmature
    of "boundingBox": dkBoundingBox
    else:             dkImage   ## "image", absent, and unknown types → image

  let transform = d.transform.toDbTransform()

  case kind
  of dkImage:
    DisplayData(name: d.name, transform: transform, kind: dkImage)
  of dkMesh:
    let verts = d.vertices.pairsToVec2()
    let uvs = d.uvs.pairsToVec2()
    let indices = d.triangles.mapIt(uint16(it))
    let wts = parseVertexWeights(d.weights, d.bonePose, verts.len)
    DisplayData(name: d.name, transform: transform, kind: dkMesh,
                mesh: MeshData(width: d.width, height: d.height,
                               vertices: verts, uvs: uvs, indices: indices,
                               vertexWeights: wts))
  of dkArmature:
    ## For armature displays, the `name` field IS the child armature name.
    DisplayData(name: d.name, transform: transform, kind: dkArmature,
                childArmatureName: d.name)
  of dkBoundingBox:
    let shape = case d.subType
      of "ellipse": bbsEllipse
      of "polygon": bbsPolygon
      else:         bbsRectangle  ## "rectangle" and absent default to rectangle
    DisplayData(name: d.name, transform: transform, kind: dkBoundingBox,
                bbShape: shape, bbVertices: d.toBoundingBoxVerts(shape))

# ── Public API ─────────────────────────────────────────────────────────────────

proc parseSkins*(raw: openArray[RawSkin]): seq[SkinData] =
  ## Convert jsony-parsed raw skin data into model SkinData.
  ## Called by parseDragonBones in parse/armature.nim.
  result = newSeq[SkinData](raw.len)
  for i, s in raw:
    var slots = newSeq[SkinSlot](s.slot.len)
    for j, sl in s.slot:
      slots[j] = SkinSlot(slotName: sl.name,
                          displays: sl.display.mapIt(it.toDisplayData()))
    result[i] = SkinData(name: s.name, slots: slots)
