## Parse DragonBones armature, bone, slot, and IK data from a 5.5–5.7 JSON string.
##
## Entry point: parseDragonBones(json) → DragonBonesData
## Skins are populated by boney-706; animation timelines by boney-56w.

import std/[options, sequtils]
import jsony
import bumpy
import dragonbones/model/model

# ── Wire types (private, mirror DragonBones JSON structure) ───────────────────

type
  RawTransform = object
    x: float32
    y: float32
    skX: float32
    skY: float32
    scX: Option[float32]   ## absent → 1.0 (identity scale)
    scY: Option[float32]   ## absent → 1.0 (identity scale)

  RawAabb = object
    x: float32
    y: float32
    width: float32         ## JSON "width" maps to Rect.w
    height: float32        ## JSON "height" maps to Rect.h

  RawColor = object
    ## Multipliers 0–100 in JSON; model range is 0–1 (divided by 100 on parse).
    ## Offsets –255..255 in JSON and model.
    aM: Option[float32]
    rM: Option[float32]
    gM: Option[float32]
    bM: Option[float32]
    aO: float32
    rO: float32
    gO: float32
    bO: float32

  RawBone = object
    name: string
    parent: string                ## JSON "parent" → BoneData.parentName; "" for root
    length: float32
    transform: Option[RawTransform]
    inheritTranslation: Option[int]  ## absent → 1 (true)
    inheritRotation: Option[int]     ## absent → 1 (true)
    inheritScale: Option[int]        ## absent → 1 (true)
    inheritReflection: Option[int]   ## absent → 1 (true)

  RawSlot = object
    name: string
    parent: string                ## JSON "parent" → SlotData.boneName
    displayIndex: int             ## absent → 0
    blendMode: Option[string]     ## absent → "normal"
    color: Option[RawColor]       ## absent → identity color

  RawIK = object
    name: string
    order: int
    bone: string                  ## JSON "bone" → IKConstraintData.boneName
    target: string                ## JSON "target" → IKConstraintData.targetName
    bendPositive: Option[int]     ## absent → 1 (true)
    chain: int                    ## absent → 0 (end-effector only)
    weight: Option[float32]       ## absent → 1.0

  RawArmature = object
    armatureType: string          ## JSON "type", renamed via renameHook; absent → "Armature"
    frameRate: int                ## absent → 0; caller inherits from top-level
    name: string
    aabb: Option[RawAabb]
    bone: seq[RawBone]
    slot: seq[RawSlot]
    ik: seq[RawIK]
    ## isGlobal (DragonBones 4.x armature flag) is intentionally ignored;
    ## 5.x files omit it and use per-bone inherit* flags instead.

  RawFile = object
    version: string
    compatibleVersion: string
    name: string
    frameRate: int
    armature: seq[RawArmature]

# ── jsony hooks ────────────────────────────────────────────────────────────────

proc renameHook*(v: var RawArmature, fieldName: var string) =
  ## Map JSON "type" → "armatureType" to avoid the Nim keyword clash.
  if fieldName == "type": fieldName = "armatureType"

# ── Conversion helpers ─────────────────────────────────────────────────────────

proc toDbTransform(r: Option[RawTransform]): DbTransform =
  if r.isNone: return dbTransformIdentity()
  let t = r.get()
  DbTransform(x: t.x, y: t.y, skX: t.skX, skY: t.skY,
              scX: t.scX.get(1.0'f32), scY: t.scY.get(1.0'f32))

proc toRect(r: RawAabb): Rect =
  Rect(x: r.x, y: r.y, w: r.width, h: r.height)

proc toDbColor(c: Option[RawColor]): DbColor =
  if c.isNone: return dbColorIdentity()
  let r = c.get()
  DbColor(aM: r.aM.get(100.0'f32) / 100.0'f32,
          rM: r.rM.get(100.0'f32) / 100.0'f32,
          gM: r.gM.get(100.0'f32) / 100.0'f32,
          bM: r.bM.get(100.0'f32) / 100.0'f32,
          aO: r.aO, rO: r.rO, gO: r.gO, bO: r.bO)

proc toBlendMode(s: Option[string]): BlendMode =
  if s.isNone: return bmNormal
  case s.get()
  of "add":        bmAdd
  of "alpha":      bmAlpha
  of "erase":      bmErase
  of "darken":     bmDarken
  of "multiply":   bmMultiply
  of "lighten":    bmLighten
  of "screen":     bmScreen
  of "overlay":    bmOverlay
  of "hard_light": bmHardLight
  of "dodge":      bmDodge
  of "burn":       bmBurn
  else:            bmNormal

proc toArmatureKind(s: string): ArmatureKind =
  case s
  of "MovieClip": akMovieClip
  of "Stage":     akStage
  else:           akArmature

proc toBoneData(r: RawBone): BoneData =
  BoneData(name: r.name,
           parentName: r.parent,
           length: r.length,
           transform: r.transform.toDbTransform(),
           inheritTranslation: r.inheritTranslation.get(1) != 0,
           inheritRotation:    r.inheritRotation.get(1) != 0,
           inheritScale:       r.inheritScale.get(1) != 0,
           inheritReflection:  r.inheritReflection.get(1) != 0)

proc toSlotData(r: RawSlot): SlotData =
  SlotData(name: r.name,
           boneName: r.parent,
           displayIndex: r.displayIndex,
           blendMode: r.blendMode.toBlendMode(),
           color: r.color.toDbColor())

proc toIKConstraintData(r: RawIK): IKConstraintData =
  IKConstraintData(name: r.name,
                   order: r.order,
                   boneName: r.bone,
                   targetName: r.target,
                   bendPositive: r.bendPositive.get(1) != 0,
                   chain: r.chain,
                   weight: r.weight.get(1.0'f32))

proc toArmatureData(r: RawArmature, topFrameRate: int): ArmatureData =
  ## frameRate: armature's own value takes priority; falls back to file-level.
  let fr = if r.frameRate > 0: r.frameRate else: topFrameRate
  ArmatureData(name: r.name,
               kind: r.armatureType.toArmatureKind(),
               frameRate: fr,
               aabb: (if r.aabb.isSome: r.aabb.get().toRect() else: Rect()),
               bones: r.bone.mapIt(it.toBoneData()),
               slots: r.slot.mapIt(it.toSlotData()),
               skins: @[],        ## populated by boney-706
               animations: @[],   ## populated by boney-56w
               ikConstraints: r.ik.mapIt(it.toIKConstraintData()),
               defaultActions: @[])

# ── Public API ─────────────────────────────────────────────────────────────────

proc parseDragonBones*(json: string): DragonBonesData =
  ## Parse a DragonBones 5.5–5.7 _ske.json string into DragonBonesData.
  ## Skins (boney-706) and animation timelines (boney-56w) are not yet populated.
  let raw = json.fromJson(RawFile)
  DragonBonesData(version: raw.version,
                  compatibleVersion: raw.compatibleVersion,
                  name: raw.name,
                  frameRate: raw.frameRate,
                  armatures: raw.armature.mapIt(it.toArmatureData(raw.frameRate)))
