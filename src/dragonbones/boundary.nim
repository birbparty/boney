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
  ## The core copies handles from DisplayData into DrawCommands each frame.
  ## TextureHandle(0) is the null/invalid sentinel.
  TextureHandle* = distinct uint32

  ## Draw command for an image slot or a mesh slot degraded to a bounding quad.
  ## dstQuad corners are in world space, counter-clockwise: TL, BL, BR, TR.
  DrawQuad* = object
    texture*: TextureHandle
    srcRect*: Rect                ## atlas sub-rectangle in pixels
    dstQuad*: array[4, Vec2]      ## world-space corners
    color*: DbColor
    blendMode*: BlendMode

  ## Draw command for a deformable mesh slot.
  ## On console targets (-d:ds3 / -d:vita) the adapter degrades to a DrawQuad
  ## over the vertices bounding box — the core always emits dcMesh regardless.
  DrawMesh* = object
    texture*: TextureHandle
    vertices*: seq[Vec2]          ## deformed world-space vertex positions
    uvs*: seq[Vec2]               ## atlas UV coordinates (static after parse)
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
