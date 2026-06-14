## boney naylib example — DragonBones skeletal animation with raylib.
##
## Loads the bundled oracle_sample fixture, plays the "idle" animation, and
## renders it via the naylib adapter.
##
## Rendering path selection:
##   Desktop (default): rlBegin/rlVertex for quads and deformed meshes.
##   Console  (-d:ds3 or -d:vita): DrawTexturePro for quads; meshes degrade to
##   a bounding-box quad sampling the UV sub-region.
##
## Build:
##   nim r --path:../../src examples/naylib/main.nim
##
## The texture is generated at runtime (solid checkerboard) so no PNG asset is
## required. Swap in your own texture by replacing the genImageChecked block.

import std/[os, tables]
import raylib
import rlgl
import vmath
import dragonbones/parse/armature
import dragonbones/atlas/atlas
import dragonbones/model/model
import dragonbones/anim/sample
import dragonbones/anim/propagate
import dragonbones/anim/draworder
import dragonbones/anim/emit
import dragonbones/boundary
import dragonbones/adapters/naylib/adapter

# ── Paths ──────────────────────────────────────────────────────────────────────

const
  FixtureDir = currentSourcePath().parentDir() / ".." / ".." / "tests" / "fixtures" / "sample"
  SkelPath   = FixtureDir / "dragon_ske.json"
  AtlasPath  = FixtureDir / "dragon_tex.json"

# ── Window constants ───────────────────────────────────────────────────────────

const
  ScreenW  = 800'i32
  ScreenH  = 600'i32
  Title    = "boney — naylib example"
  CenterX  = ScreenW div 2   ## skeleton root at screen centre
  CenterY  = ScreenH div 2

# ── Main ───────────────────────────────────────────────────────────────────────

proc main() =
  # ── Parse data ──────────────────────────────────────────────────────────────
  let dbData    = parseDragonBones(readFile(SkelPath))
  let atlasData = parseAtlas(readFile(AtlasPath))

  doAssert dbData.armatures.len > 0, "skeleton JSON has no armatures"
  let armData = dbData.armatures[0]          ## "Dragon"
  let skin    = armData.skins[0]             ## default skin

  # Pick "idle" animation; fall back to the first one.
  var animIdx = 0
  for i, anim in armData.animations:
    if anim.name == "idle": animIdx = i; break
  let animData = armData.animations[animIdx]

  echo "Armature:  ", armData.name
  echo "Animation: ", animData.name, " (", animData.duration, " frames @ ",
       armData.frameRate, " fps)"
  echo "Bones:     ", armData.bones.len
  echo "Slots:     ", armData.slots.len

  # ── Raylib window ──────────────────────────────────────────────────────────
  initWindow(ScreenW, ScreenH, Title)
  setTargetFPS(60)

  # ── Texture ────────────────────────────────────────────────────────────────
  # Checkerboard placeholder — no real atlas PNG required.
  # Replace with loadImage("oracle_sample.png") once you have the file.
  let numX = max(1'i32, int32(atlasData.width) div 16)
  let numY = max(1'i32, int32(atlasData.height) div 16)
  let img  = genImageChecked(int32(atlasData.width), int32(atlasData.height),
                              numX, numY, LIGHTGRAY, GRAY)
  let tex  = loadTextureFromImage(img)
  ## img is a stack value; no unload call needed (naylib does not export it).

  # One TextureHandle for the whole atlas; the adapter maps it to a Texture2D.
  let atlasHandle = TextureHandle(1)
  let textures    = {atlasHandle: tex}.toTable

  proc lookupTex(h: TextureHandle): Texture2D =
    textures.getOrDefault(h)

  # ── Per-frame animation state ──────────────────────────────────────────────
  var bones       = newSeq[BoneState](armData.bones.len)
  var slots       = newSeq[SlotState](armData.slots.len)
  var scratch:    seq[DbTransform]         ## propagation scratch, auto-grown
  var drawOrd     = newSeq[int](armData.slots.len)
  var zScratch:   seq[int]                 ## drawOrder scratch, auto-grown
  var drawCmds:   seq[DrawCommand]
  var meshScratch: seq[Vec2]
  let emptyFFD:   seq[seq[Vec2]] = @[]     ## no FFD in this fixture

  # Find the zOrder timeline if present (absent for simple skeletons).
  var zOrderKFs: seq[ZOrderKeyframe]
  for tl in animData.timelines:
    if tl.kind == tlZOrder:
      zOrderKFs = tl.zOrderKFs
      break

  var elapsedSecs = 0.0'f32
  let animDurSecs = float32(animData.duration) / float32(armData.frameRate)

  # ── Game loop ──────────────────────────────────────────────────────────────
  while not windowShouldClose():
    let dt = getFrameTime()
    elapsedSecs += dt
    if animDurSecs > 0: elapsedSecs = elapsedSecs mod animDurSecs

    # ── Update ────────────────────────────────────────────────────────────────
    sampleAnimation(animData, armData, elapsedSecs, bones, slots)
    propagateWorldTransforms(armData, bones, scratch)
    sampleDrawOrder(zOrderKFs,
                    elapsedSecs * float32(armData.frameRate),
                    armData.slots.len, drawOrd, zScratch)
    emitDrawCommands(armData, skin, atlasData, atlasHandle,
                     bones, slots, drawOrd, emptyFFD,
                     drawCmds, meshScratch)

    # ── Render ────────────────────────────────────────────────────────────────
    beginDrawing()
    clearBackground(DARKGRAY)

    # Push a translation so skeleton origin maps to screen centre.
    # DragonBones uses screen-space coordinates (Y-down), same as raylib.
    pushMatrix()
    translatef(float32(CenterX), float32(CenterY), 0'f32)
    renderDrawCommands(drawCmds, lookupTex)
    popMatrix()

    drawFPS(10, 10)
    drawText("boney naylib — " & animData.name, 10, 30, 18, RAYWHITE)
    endDrawing()

  # ── Cleanup ────────────────────────────────────────────────────────────────
  closeWindow()

main()
