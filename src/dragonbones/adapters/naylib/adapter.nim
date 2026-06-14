## Naylib/raylib adapter for boney DrawCommands.
##
## Render path selection:
##   Desktop (default): rlBegin(RL_QUADS)/rlVertex for both quads and meshes.
##     Uses setTexture (rlSetTexture) to bind into the rlgl batch renderer.
##     RL_QUADS is mandatory — the rlgl batch silently drops RL_TRIANGLES
##     geometry (mesh triangles are emitted as degenerate quads).
##     uvQuad handles atlas rotation transparently.
##   Console (-d:ds3 or -d:vita): DrawTexturePro for quads; mesh slots degrade
##     to a bounding-box DrawTexturePro sampling only the mesh's UV sub-region.
##     Atlas-rotated sprites (atlasRotated=true) are NOT supported on console —
##     export texture atlases with rotation disabled for console builds.
##
## Usage:
##   var cmds: seq[DrawCommand]
##   var scratch: seq[Vec2]
##   # ... emitDrawCommands into cmds ...
##   renderDrawCommands(cmds, proc(h: TextureHandle): Texture2D = myTextures[h.int])

import vmath
import raylib
import rlgl
import dragonbones/boundary
import dragonbones/model/model

# ── Color conversion ──────────────────────────────────────────────────────────

proc toRaylibColor(c: DbColor): Color {.inline.} =
  Color(
    r: uint8(clamp(c.rM * 255.0'f32 + c.rO, 0.0'f32, 255.0'f32)),
    g: uint8(clamp(c.gM * 255.0'f32 + c.gO, 0.0'f32, 255.0'f32)),
    b: uint8(clamp(c.bM * 255.0'f32 + c.bO, 0.0'f32, 255.0'f32)),
    a: uint8(clamp(c.aM * 255.0'f32 + c.aO, 0.0'f32, 255.0'f32)))

proc toRaylibBlendMode(bm: model.BlendMode): raylib.BlendMode {.inline.} =
  case bm
  of bmNormal:   raylib.BlendMode.Alpha
  of bmAdd:      raylib.BlendMode.Additive
  of bmMultiply: raylib.BlendMode.Multiplied
  of bmScreen:   raylib.BlendMode.AddColors
  else:          raylib.BlendMode.Alpha

# ── Desktop path (rlVertex) ───────────────────────────────────────────────────

when not (defined(ds3) or defined(vita)):

  proc renderQuadDesktop(q: DrawQuad, tex: ptr Texture2D) =
    ## Render a DrawQuad via rlVertex as a single RL_QUADS primitive (4 verts).
    ##
    ## IMPORTANT: rlgl's default render batch only rasterizes RL_QUADS for
    ## textured geometry — it builds an element/index buffer (glDrawElements,
    ## 6 indices per 4 verts) sized for quads. RL_TRIANGLES geometry submitted
    ## through the same batch is silently dropped (no visible pixels), which is
    ## why every raylib texture helper (DrawTexturePro etc.) feeds RL_QUADS.
    ## Submit corners in TL → BL → BR → TR winding to match that index layout.
    ##
    ## Corner order in q: [0]=TL [1]=TR [2]=BR [3]=BL, matching
    ## AtlasSubTexture.quadVerts. uvQuad handles atlas rotation transparently.
    let tint = toRaylibColor(q.color)
    setTexture(tex.id)  # rlSetTexture — registers texture with the rlgl batch renderer
    rlBegin(DrawMode.Quads)
    color4ub(tint.r, tint.g, tint.b, tint.a)
    texCoord2f(q.uvQuad[0].x, q.uvQuad[0].y); vertex2f(q.dstQuad[0].x, q.dstQuad[0].y)  # TL
    texCoord2f(q.uvQuad[3].x, q.uvQuad[3].y); vertex2f(q.dstQuad[3].x, q.dstQuad[3].y)  # BL
    texCoord2f(q.uvQuad[2].x, q.uvQuad[2].y); vertex2f(q.dstQuad[2].x, q.dstQuad[2].y)  # BR
    texCoord2f(q.uvQuad[1].x, q.uvQuad[1].y); vertex2f(q.dstQuad[1].x, q.dstQuad[1].y)  # TR
    rlEnd()
    setTexture(0)

  proc renderMeshDesktop(m: DrawMesh, tex: ptr Texture2D) =
    ## Render a DrawMesh (arbitrary indexed triangle soup) via rlVertex.
    ##
    ## rlgl's default batch only rasterizes RL_QUADS (see renderQuadDesktop),
    ## so each source triangle is emitted as a degenerate quad. rlgl's quad
    ## index buffer maps the 4 verts to triangles (0,1,2) and (0,2,3); the
    ## 4th vert duplicates the 3rd, so the second triangle is degenerate
    ## (zero area) and only the real triangle rasterizes.
    ##
    ## Culling: raylib's default batch leaves GL_CULL_FACE enabled, and a
    ## DragonBones mesh's natural triangle winding faces away from the camera
    ## (verified empirically — natural-order triangles render zero pixels with
    ## culling on, full coverage with it off). Rather than reverse the winding
    ## (which would silently drop any triangle of the opposite winding in a
    ## mixed-winding mesh), disable backface culling for the mesh draw so it is
    ## winding-agnostic, then restore the default afterward.
    if m.uvs.len < m.vertices.len: return  # mismatched parallel arrays — skip safely
    let tint = toRaylibColor(m.color)
    setTexture(tex.id)  # rlSetTexture — registers texture with the rlgl batch renderer
    disableBackfaceCulling()
    rlBegin(DrawMode.Quads)
    color4ub(tint.r, tint.g, tint.b, tint.a)
    var ti = 0
    while ti + 2 < m.indices.len:
      let ia = m.indices[ti].int
      let ib = m.indices[ti + 1].int
      let ic = m.indices[ti + 2].int
      if ia < m.vertices.len and ib < m.vertices.len and ic < m.vertices.len and
         ia < m.uvs.len and ib < m.uvs.len and ic < m.uvs.len:
        # Natural winding (ia, ib, ic) + 4th vert duplicating the last.
        texCoord2f(m.uvs[ia].x, m.uvs[ia].y); vertex2f(m.vertices[ia].x, m.vertices[ia].y)
        texCoord2f(m.uvs[ib].x, m.uvs[ib].y); vertex2f(m.vertices[ib].x, m.vertices[ib].y)
        texCoord2f(m.uvs[ic].x, m.uvs[ic].y); vertex2f(m.vertices[ic].x, m.vertices[ic].y)
        texCoord2f(m.uvs[ic].x, m.uvs[ic].y); vertex2f(m.vertices[ic].x, m.vertices[ic].y)
      ti += 3
    rlEnd()
    # Flush the mesh batch while culling is still disabled, then restore the
    # default so it doesn't leak into subsequent draws (the batch only applies
    # cull state at flush time).
    drawRenderBatchActive()
    enableBackfaceCulling()
    setTexture(0)

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

  proc renderQuadConsole(q: DrawQuad, tex: ptr Texture2D) =
    # Atlas-rotated sprites require swapping src dims and fixing the rotation pivot,
    # which DrawTexturePro (origin=(0,0)) cannot do correctly. Enforce non-rotation
    # so the constraint is caught at dev time. Export atlases with rotation disabled
    # for console targets (-d:ds3, -d:vita).
    doAssert not q.atlasRotated, "atlasRotated sprites not supported on console; disable atlas packing rotation on export"
    let tint = toRaylibColor(q.color)
    let (px, py, pw, ph, baseAngle) = quadBounds(q.dstQuad)
    let src = Rectangle(x: q.srcRect.x, y: q.srcRect.y,
                         width: q.srcRect.w, height: q.srcRect.h)
    let dst = Rectangle(x: px, y: py, width: pw, height: ph)
    drawTexture(tex[], src, dst, Vector2(x: 0, y: 0), baseAngle, tint)

  proc renderMeshConsole(m: DrawMesh, tex: ptr Texture2D) =
    ## Console mesh degradation: render the world-space bounding box as a quad,
    ## sampling only the UV sub-region that the mesh actually covers in the atlas.
    if m.vertices.len == 0 or m.uvs.len == 0: return
    var minX = m.vertices[0].x; var maxX = minX
    var minY = m.vertices[0].y; var maxY = minY
    for v in m.vertices:
      if v.x < minX: minX = v.x
      if v.x > maxX: maxX = v.x
      if v.y < minY: minY = v.y
      if v.y > maxY: maxY = v.y
    var minU = m.uvs[0].x; var maxU = minU
    var minV = m.uvs[0].y; var maxV = minV
    for uv in m.uvs:
      if uv.x < minU: minU = uv.x
      if uv.x > maxU: maxU = uv.x
      if uv.y < minV: minV = uv.y
      if uv.y > maxV: maxV = uv.y
    let tw = float32(tex.width)
    let th = float32(tex.height)
    let tint = toRaylibColor(m.color)
    let src = Rectangle(x: minU * tw, y: minV * th,
                         width: (maxU - minU) * tw, height: (maxV - minV) * th)
    let dst = Rectangle(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    drawTexture(tex[], src, dst, Vector2(x: 0, y: 0), 0.0'f32, tint)

# ── Public API ────────────────────────────────────────────────────────────────

proc renderDrawCommands*(cmds: seq[DrawCommand],
                          lookup: proc(h: TextureHandle): ptr Texture2D) =
  ## Render all DrawCommands in order (back→front as produced by emitDrawCommands).
  ## lookup: maps a TextureHandle to a borrowed ptr Texture2D (nil → skip command).
  for cmd in cmds:
    case cmd.kind
    of dcQuad:
      let tex = lookup(cmd.quad.texture)
      if tex == nil: continue
      let bm = toRaylibBlendMode(cmd.quad.blendMode)
      blendMode(bm):
        when not (defined(ds3) or defined(vita)):
          renderQuadDesktop(cmd.quad, tex)
        else:
          renderQuadConsole(cmd.quad, tex)
    of dcMesh:
      let tex = lookup(cmd.mesh.texture)
      if tex == nil: continue
      let bm = toRaylibBlendMode(cmd.mesh.blendMode)
      blendMode(bm):
        when not (defined(ds3) or defined(vita)):
          renderMeshDesktop(cmd.mesh, tex)
        else:
          renderMeshConsole(cmd.mesh, tex)
