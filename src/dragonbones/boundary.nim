## Render-agnostic adapter boundary for boney.
##
## The core produces DrawCommands; adapters consume them. The core never
## dereferences TextureHandle — that is the adapter's concern.
## See docs/render-agnostic-boundary.md for the full design rationale.

import vmath
import bumpy
import dragonbones/model/model

type
  ## Opaque GPU-resource identifier issued by the adapter at load time.
  ## At frame emit time, the anim module resolves the handle from the atlas
  ## binding and copies it into DrawCommands. The core never dereferences it.
  ## NullTextureHandle is the invalid sentinel.
  TextureHandle* = distinct uint32

const NullTextureHandle* = TextureHandle(0)

proc `==`*(a, b: TextureHandle): bool {.borrow.}
proc isValid*(h: TextureHandle): bool = h != NullTextureHandle

type
  ## Draw command for an image slot or a mesh slot degraded to a bounding quad.
  ##
  ## Corner order: TL, TR, BR, BL (clockwise, matching AtlasSubTexture.quadVerts).
  ## Triangle decomposition: (0,1,2) and (0,2,3).
  ##
  ## srcRect: raw atlas pixel sub-rectangle for DrawTexturePro (console path).
  ## uvQuad:  normalized UVs matching dstQuad corners — use for rlVertex (desktop).
  ##          Already accounts for atlas sprite rotation.
  ## atlasRotated: true when the sprite is stored 90° CW in the atlas; the
  ##          console DrawTexturePro path must add 90° to the dest rotation to
  ##          compensate (or avoid rotated atlases on console targets).
  DrawQuad* = object
    texture*:      TextureHandle
    srcRect*:      Rect             ## atlas sub-rectangle in PIXELS
    uvQuad*:       array[4, Vec2]   ## normalized UV coords, order matches dstQuad
    dstQuad*:      array[4, Vec2]   ## world-space corners: TL, TR, BR, BL
    atlasRotated*: bool             ## true → sprite is 90° CW in atlas
    color*: DbColor
    blendMode*: BlendMode

  ## Draw command for a deformable mesh slot.
  ## On console targets (-d:ds3 / -d:vita) the adapter degrades to a DrawQuad
  ## over the vertices bounding box — the core always emits dcMesh regardless.
  DrawMesh* = object
    texture*: TextureHandle
    vertices*: seq[Vec2]          ## deformed world-space vertex positions
    uvs*: seq[Vec2]               ## atlas UV coords, NORMALIZED 0–1 (not pixels)
    indices*: seq[uint16]
    color*: DbColor
    blendMode*: BlendMode

  DrawCommandKind* = enum dcQuad, dcMesh

  ## One per visible slot per frame, sorted ascending by zOrder (back → front).
  DrawCommand* = object
    zOrder*: int
    case kind*: DrawCommandKind
    of dcQuad: quad*: DrawQuad
    of dcMesh: mesh*: DrawMesh
