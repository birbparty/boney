## Naylib/raylib adapter for boney DrawCommands.
##
## Render path selection:
##   Desktop (default): rlBegin/rlVertex for both quads and meshes.
##     Uses precomputed uvQuad for correct atlas-rotation handling.
##   Console (-d:ds3 or -d:vita): DrawTexturePro for quads (rotated-rect only;
##     export atlases with rotation disabled for console targets).
##     Mesh slots degrade to a bounding-box DrawTexturePro.
##
## Usage:
##   var cmds: seq[DrawCommand]
##   var scratch: seq[Vec2]
##   # ... emitDrawCommands into cmds ...
##   renderDrawCommands(cmds, textures)
##
## textures maps each TextureHandle to a naylib Texture2D. Use a seq or table
## depending on how many textures you manage.

import std/math
import vmath
import raylib
import rlgl
import dragonbones/boundary

# ── Color conversion ──────────────────────────────────────────────────────────

proc toRaylibColor(c: DbColor): Color {.inline.} =
  Color(
    r: uint8(clamp(c.rM * 255.0'f32 + c.rO, 0.0'f32, 255.0'f32)),
    g: uint8(clamp(c.gM * 255.0'f32 + c.gO, 0.0'f32, 255.0'f32)),
    b: uint8(clamp(c.bM * 255.0'f32 + c.bO, 0.0'f32, 255.0'f32)),
    a: uint8(clamp(c.aM * 255.0'f32 + c.aO, 0.0'f32, 255.0'f32)))

proc toRaylibBlendMode(bm: BlendMode): raylib.BlendMode {.inline.} =
  case bm
  of bmNormal:   raylib.BlendMode.Alpha
  of bmAdd:      raylib.BlendMode.Additive
  of bmMultiply: raylib.BlendMode.Multiplied
  of bmScreen:   raylib.BlendMode.AddColors
  else:          raylib.BlendMode.Alpha

# ── Desktop path (rlVertex) ───────────────────────────────────────────────────

when not (defined(ds3) or defined(vita)):

  proc renderQuadDesktop(q: DrawQuad, tex: Texture2D) =
    ## Render a DrawQuad via rlVertex (2 CW triangles: TL,TR,BR and TL,BR,BL).
    ## Corner order: [0]=TL [1]=TR [2]=BR [3]=BL, matching AtlasSubTexture.quadVerts.
    let tint = toRaylibColor(q.color)
    enableTexture(tex.id)
    rlBegin(DrawMode.Triangles)
    color4ub(tint.r, tint.g, tint.b, tint.a)
    # Triangle 1: TL(0), TR(1), BR(2)
    texCoord2f(q.uvQuad[0].x, q.uvQuad[0].y); vertex2f(q.dstQuad[0].x, q.dstQuad[0].y)
    texCoord2f(q.uvQuad[1].x, q.uvQuad[1].y); vertex2f(q.dstQuad[1].x, q.dstQuad[1].y)
    texCoord2f(q.uvQuad[2].x, q.uvQuad[2].y); vertex2f(q.dstQuad[2].x, q.dstQuad[2].y)
    # Triangle 2: TL(0), BR(2), BL(3)
    texCoord2f(q.uvQuad[0].x, q.uvQuad[0].y); vertex2f(q.dstQuad[0].x, q.dstQuad[0].y)
    texCoord2f(q.uvQuad[2].x, q.uvQuad[2].y); vertex2f(q.dstQuad[2].x, q.dstQuad[2].y)
    texCoord2f(q.uvQuad[3].x, q.uvQuad[3].y); vertex2f(q.dstQuad[3].x, q.dstQuad[3].y)
    rlEnd()
    disableTexture()

  proc renderMeshDesktop(m: DrawMesh, tex: Texture2D) =
    ## Render a DrawMesh via rlVertex (arbitrary triangle soup).
    let tint = toRaylibColor(m.color)
    enableTexture(tex.id)
    rlBegin(DrawMode.Triangles)
    color4ub(tint.r, tint.g, tint.b, tint.a)
    var ti = 0
    while ti + 2 < m.indices.len:
      let ia = m.indices[ti].int
      let ib = m.indices[ti + 1].int
      let ic = m.indices[ti + 2].int
      if ia < m.vertices.len and ib < m.vertices.len and ic < m.vertices.len:
        texCoord2f(m.uvs[ia].x, m.uvs[ia].y); vertex2f(m.vertices[ia].x, m.vertices[ia].y)
        texCoord2f(m.uvs[ib].x, m.uvs[ib].y); vertex2f(m.vertices[ib].x, m.vertices[ib].y)
        texCoord2f(m.uvs[ic].x, m.uvs[ic].y); vertex2f(m.vertices[ic].x, m.vertices[ic].y)
      ti += 3
    rlEnd()
    disableTexture()

# ── Console path (DrawTexturePro) ─────────────────────────────────────────────

else:  # ds3 or vita

  proc quadBounds(q: array[4, Vec2]): tuple[x, y, w, h, angle: float32] =
    ## Extract DrawTexturePro-compatible (x, y, width, height, rotation°) from
    ## a quad's TL and TR corners. This assumes no skew in the world transform.
    ## For rotated-atlas sprites, add 90° to the returned angle separately.
    let tl = q[0]; let tr = q[1]
    let dx = tr.x - tl.x; let dy = tr.y - tl.y
    let w  = sqrt(dx * dx + dy * dy)
    let bl = q[3]
    let dxH = bl.x - tl.x; let dyH = bl.y - tl.y
    let h   = sqrt(dxH * dxH + dyH * dyH)
    let angle = arctan2(dy, dx) * (180.0'f32 / PI)
    (x: tl.x, y: tl.y, w: w, h: h, angle: angle)

  proc renderQuadConsole(q: DrawQuad, tex: Texture2D) =
    let tint = toRaylibColor(q.color)
    let (px, py, pw, ph, baseAngle) = quadBounds(q.dstQuad)
    let extraRot = if q.atlasRotated: 90.0'f32 else: 0.0'f32
    let src = Rectangle(x: q.srcRect.x, y: q.srcRect.y,
                         width: q.srcRect.w, height: q.srcRect.h)
    let dst = Rectangle(x: px, y: py, width: pw, height: ph)
    drawTexture(tex, src, dst, Vector2(x: 0, y: 0), baseAngle + extraRot, tint)

  proc renderMeshConsole(m: DrawMesh, tex: Texture2D) =
    ## Console mesh degradation: render the world-space bounding box as a quad.
    if m.vertices.len == 0: return
    var minX = m.vertices[0].x; var maxX = minX
    var minY = m.vertices[0].y; var maxY = minY
    for v in m.vertices:
      if v.x < minX: minX = v.x
      if v.x > maxX: maxX = v.x
      if v.y < minY: minY = v.y
      if v.y > maxY: maxY = v.y
    let tint = toRaylibColor(m.color)
    let src = Rectangle(x: 0, y: 0,
                         width: float32(tex.width), height: float32(tex.height))
    let dst = Rectangle(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    drawTexture(tex, src, dst, Vector2(x: 0, y: 0), 0.0'f32, tint)

# ── Public API ────────────────────────────────────────────────────────────────

proc resolveTexture*(cmds: seq[DrawCommand], lookup: proc(h: TextureHandle): Texture2D): seq[Texture2D] =
  ## Pre-resolve TextureHandles to Texture2D objects for renderDrawCommands.
  result = newSeq[Texture2D](cmds.len)
  for i, cmd in cmds:
    case cmd.kind
    of dcQuad: result[i] = lookup(cmd.quad.texture)
    of dcMesh: result[i] = lookup(cmd.mesh.texture)

proc renderDrawCommands*(cmds: seq[DrawCommand],
                          lookup: proc(h: TextureHandle): Texture2D) =
  ## Render all DrawCommands in order (back→front as produced by emitDrawCommands).
  ## lookup: maps a TextureHandle to a naylib Texture2D.
  for cmd in cmds:
    case cmd.kind
    of dcQuad:
      let tex = lookup(cmd.quad.texture)
      let bm = toRaylibBlendMode(cmd.quad.blendMode)
      blendMode(bm):
        when not (defined(ds3) or defined(vita)):
          renderQuadDesktop(cmd.quad, tex)
        else:
          renderQuadConsole(cmd.quad, tex)
    of dcMesh:
      let tex = lookup(cmd.mesh.texture)
      let bm = toRaylibBlendMode(cmd.mesh.blendMode)
      blendMode(bm):
        when not (defined(ds3) or defined(vita)):
          renderMeshDesktop(cmd.mesh, tex)
        else:
          renderMeshConsole(cmd.mesh, tex)
