## DragonBones model types for boney.
##
## Design contract:
##   *Data types   — immutable, shared across all Armature instances that use the same loaded file.
##                   Owned by DragonBonesData. Do not mutate after parse.
##   Instance types — per-Armature mutable state (BoneState, SlotState, Armature).
##                   Baking mutable pose into *Data would break instance pooling.
##
## All public-API vectors/matrices use vmath types directly.
## bumpy.Rect is used for axis-aligned bounding boxes.
## No bespoke Vec2/Mat2d aliases are defined.
##
## Targeting DragonBones JSON 5.5–5.7 (primary); see docs/dragonbones-format-version.md.

import vmath
import bumpy

# ── Primitive helpers ─────────────────────────────────────────────────────────

type
  BlendMode* = enum
    bmNormal, bmAdd, bmAlpha, bmErase, bmDarken, bmMultiply,
    bmLighten, bmScreen, bmOverlay, bmHardLight, bmDodge, bmBurn

  ## Skew-based affine transform mirroring the DragonBones JSON on-wire format.
  ## x/y: translation; skX/skY: skew in degrees (pure rotation: skX ≈ skY);
  ## scX/scY: scale. skX/skY are independent skew axes, not a single rotation angle,
  ## so a bespoke dbTransformToMat3 helper is needed for matrix chain computation
  ## (no single vmath proc maps DbTransform → Mat3 directly).
  DbTransform* = object
    x*, y*: float32
    skX*, skY*: float32    ## degrees, NOT radians
    scX*, scY*: float32

  ## RGBA color multiplier + additive offset per channel.
  ## Multipliers 0–1 (JSON: 0–100), offsets –255..255 (JSON: –255..255).
  ## Identity: all multipliers 1.0, all offsets 0.0.
  DbColor* = object
    aM*, rM*, gM*, bM*: float32
    aO*, rO*, gO*, bO*: float32

const DisplayIndexHidden* = -1  ## displayIndex sentinel: slot shows nothing

proc dbTransformIdentity*(): DbTransform =
  DbTransform(scX: 1.0, scY: 1.0)

proc dbColorIdentity*(): DbColor =
  DbColor(aM: 1.0, rM: 1.0, gM: 1.0, bM: 1.0)

# ── Tween / curve encoding ────────────────────────────────────────────────────

type
  TweenKind* = enum
    ## Absent field: use the timeline's default tween (typically linear).
    tkLinear
    ## tweenEasing is a finite non-zero float (quad ease).
    tkQuad
    ## Explicit NaN/null sentinel — hold previous value (stepped).
    tkStepped
    ## curve array with exactly 4 floats: cubic bezier control points p1/p2 (0–1).
    tkBezier
    ## curve array with > 4 floats: pre-sampled value sequence (5.5+ form).
    tkSampled

  TweenCurve* = object
    case kind*: TweenKind
    of tkLinear, tkStepped:
      discard
    of tkQuad:
      easing*: float32
    of tkBezier:
      p1x*, p1y*, p2x*, p2y*: float32
    of tkSampled:
      samples*: seq[float32]

# ── Mesh / display types ──────────────────────────────────────────────────────

type
  DisplayKind* = enum
    dkImage, dkMesh, dkArmature, dkBoundingBox

  BoundingBoxShape* = enum
    bbsRectangle, bbsEllipse, bbsPolygon

  ## One (boneIndex, weight) entry for a weighted mesh vertex.
  VertexWeight* = object
    boneIndex*: uint16
    weight*: float32

  ## Mesh display: vertices/UVs/triangles + optional per-vertex bone weights.
  ## vertexWeights[i] holds the weights for vertices[i]; empty seq = non-weighted.
  MeshData* = object
    width*, height*: float32
    vertices*: seq[Vec2]                ## local vertex positions
    uvs*: seq[Vec2]                     ## normalized UV coords (0–1)
    indices*: seq[uint16]               ## triangle index list; len % 3 == 0
    vertexWeights*: seq[seq[VertexWeight]]

  DisplayData* = object
    name*: string
    transform*: DbTransform             ## local offset from slot pivot
    case kind*: DisplayKind
    of dkImage:
      discard
    of dkMesh:
      mesh*: MeshData
    of dkArmature:
      childArmatureName*: string
    of dkBoundingBox:
      bbShape*: BoundingBoxShape
      bbVertices*: seq[Vec2]            ## polygon hull; rect/ellipse use aabb

# ── Skin types ────────────────────────────────────────────────────────────────

type
  SkinSlot* = object
    slotName*: string
    displays*: seq[DisplayData]

  SkinData* = object
    name*: string                       ## "" for the default skin
    slots*: seq[SkinSlot]

# ── Bone / slot data ──────────────────────────────────────────────────────────

type
  BoneData* = object
    name*: string
    parentName*: string                 ## "" for root bones
    length*: float32
    transform*: DbTransform             ## rest-pose transform relative to parent
    inheritTranslation*: bool
    inheritRotation*: bool
    inheritScale*: bool
    inheritReflection*: bool

  SlotData* = object
    name*: string
    boneName*: string                   ## parent bone
    displayIndex*: int                  ## default display (DisplayIndexHidden = hidden)
    blendMode*: BlendMode
    color*: DbColor                     ## default slot color

# ── Constraint data ───────────────────────────────────────────────────────────

type
  IKConstraintData* = object
    name*: string
    order*: int                         ## evaluation order index
    boneName*: string                   ## end-effector bone
    targetName*: string                 ## IK target bone
    bendPositive*: bool
    ## Bones in chain beyond the end-effector: 0 = end-effector only (one bone),
    ## 1 = parent + end-effector (two bones). Mirrors DragonBones `chain` field.
    chain*: int
    weight*: float32                    ## blend weight 0–1

# ── Animation keyframe types ──────────────────────────────────────────────────

type
  ## Fields common to every keyframe type.
  KeyframeBase* = object
    frame*: int                         ## time in frames (integer, 0-based)
    duration*: int                      ## frames this keyframe holds
    curve*: TweenCurve

  BoneTranslateKF* = object
    base*: KeyframeBase
    x*, y*: float32

  BoneRotateKF* = object
    base*: KeyframeBase
    rotate*: float32                    ## degrees

  BoneScaleKF* = object
    base*: KeyframeBase
    scX*, scY*: float32

  SlotDisplayKF* = object
    base*: KeyframeBase
    displayIndex*: int                  ## DisplayIndexHidden hides the slot

  SlotColorKF* = object
    base*: KeyframeBase
    color*: DbColor

  ## FFD keyframe: per-vertex position offsets for mesh deformation.
  ## vertices[i] is an offset for the vertex at index (offset + i).
  FFDKeyframe* = object
    base*: KeyframeBase
    offset*: int
    vertices*: seq[Vec2]

  IKKeyframe* = object
    base*: KeyframeBase
    bendPositive*: bool
    weight*: float32

  ## ZOrder keyframe: sparse reorder deltas by slot array index.
  ## slotIndex is an index into ArmatureData.slots (not a slot name).
  ## parse/ resolves slot names to indices when building this list.
  ZOrderKeyframe* = object
    base*: KeyframeBase
    slotOffsets*: seq[tuple[slotIndex: int, zOffset: int]]

  TimelineKind* = enum
    tlBoneTranslate, tlBoneRotate, tlBoneScale,
    tlSlotDisplay, tlSlotColor,
    tlFFD, tlIK, tlZOrder

  Timeline* = object
    ## Bone/slot/constraint name this timeline controls.
    name*: string
    case kind*: TimelineKind
    of tlBoneTranslate: translateKFs*: seq[BoneTranslateKF]
    of tlBoneRotate:    rotateKFs*:    seq[BoneRotateKF]
    of tlBoneScale:     scaleKFs*:     seq[BoneScaleKF]
    of tlSlotDisplay:   displayKFs*:   seq[SlotDisplayKF]
    of tlSlotColor:     colorKFs*:     seq[SlotColorKF]
    of tlFFD:
      ffdSkinName*:    string
      ffdSlotName*:    string
      ffdDisplayName*: string
      ffdKFs*:         seq[FFDKeyframe]
    of tlIK:            ikKFs*:        seq[IKKeyframe]
    of tlZOrder:        zOrderKFs*:    seq[ZOrderKeyframe]

# ── Animation data ────────────────────────────────────────────────────────────

type
  AnimationData* = object
    name*: string
    duration*: int                      ## total frames
    playTimes*: int                     ## 0 = loop forever
    fadeInTime*: float32
    timelines*: seq[Timeline]

# ── Armature data ─────────────────────────────────────────────────────────────

type
  ArmatureKind* = enum
    akArmature, akMovieClip, akStage

  ArmatureData* = object
    name*: string
    kind*: ArmatureKind
    frameRate*: int
    aabb*: Rect                         ## axis-aligned bounding box (bumpy)
    bones*: seq[BoneData]
    slots*: seq[SlotData]
    skins*: seq[SkinData]               ## skins[0] is typically the default skin
    animations*: seq[AnimationData]
    ikConstraints*: seq[IKConstraintData]
    defaultActions*: seq[string]        ## animation names to auto-play on load

  DragonBonesData* = object
    version*: string                    ## e.g. "5.7.0"
    compatibleVersion*: string          ## e.g. "5.0.0"
    name*: string
    frameRate*: int                     ## fallback when armature omits frameRate
    armatures*: seq[ArmatureData]

# ── Runtime / instance types ──────────────────────────────────────────────────

type
  BoneState* = object
    ## Current pose transform (mutable, per-frame).
    localTransform*: DbTransform
    ## Cached matrices; recomputed each frame when dirty.
    localMatrix*:  Mat3
    worldMatrix*:  Mat3

  SlotState* = object
    displayIndex*: int                  ## DisplayIndexHidden hides the slot
    color*: DbColor
    blendMode*: BlendMode

  AnimationState* = object
    name*: string
    time*: float32                      ## current playback time in seconds
    timeScale*: float32
    weight*: float32                    ## blend weight 0–1
    isPlaying*: bool
    isCompleted*: bool

  ## Live armature instance. References shared ArmatureData (non-owning).
  ## Caller must keep the parent DragonBonesData alive for the Armature's lifetime.
  Armature* = object
    data*: ptr ArmatureData             ## non-owning; do not free separately
    bones*: seq[BoneState]              ## parallel to data.bones
    slots*: seq[SlotState]              ## parallel to data.slots
    activeAnimation*: AnimationState
    needsUpdate*: bool                  ## set true after pose mutation; cleared on update
