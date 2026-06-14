## boney boxy example — DragonBones skeletal animation with boxy (desktop-only).
##
## Loads the bundled dragon fixture, plays the "idle" animation, and renders it
## via the boxy adapter. Mesh slots degrade to bounding-box quads (boxy has no
## triangle mesh API). Atlas-rotated sprites are un-rotated at load time.
##
## This file must NOT be compiled for console targets — boxy imports pixie and
## is never console-free.
##
## Dependencies (consumer-supplied, not in boney.nimble):
##   nimble install boxy windy opengl
##
## Build (from repo root):
##   nim r examples/boxy/main.nim
##
## The atlas image is generated at runtime (solid-color placeholder). Replace
## with readImage("dragon_tex.png") once you have the real texture file.

when defined(ds3) or defined(vita):
  {.error: "examples/boxy/main.nim must not be compiled for console targets".}

import std/[os, times]
import windy
import opengl
import boxy          ## also exports pixie (Image, Color, rgba, newImage, ...)
import vmath
import dragonbones/parse/armature
import dragonbones/atlas/atlas
import dragonbones/model/model
import dragonbones/anim/sample
import dragonbones/anim/propagate
import dragonbones/anim/draworder
import dragonbones/anim/emit
import dragonbones/boundary
import dragonbones/adapters/boxy/adapter as boxyAdapter

# ── Paths ──────────────────────────────────────────────────────────────────────

const
  FixtureDir = currentSourcePath().parentDir() / ".." / ".." / "tests" / "fixtures" / "sample"
  SkelPath   = FixtureDir / "dragon_ske.json"
  AtlasPath  = FixtureDir / "dragon_tex.json"

# ── Window constants ───────────────────────────────────────────────────────────

const
  ScreenW = 800
  ScreenH = 600
  Title   = "boney — boxy example"

# ── Placeholder atlas image ────────────────────────────────────────────────────

proc makePlaceholderAtlas(w, h: int): Image =
  ## Solid-colour placeholder so sub-sprites register into boxy without a PNG.
  ## Replace with readImage("dragon_tex.png") once you have the real file.
  ## The rendered skeleton will show as monochrome — that is expected.
  result = newImage(w, h)
  result.fill(rgba(100, 149, 237, 255))  ## cornflower blue

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

  # ── Windy window + OpenGL context ──────────────────────────────────────────
  let window = newWindow(Title, ivec2(ScreenW, ScreenH))
  window.makeContextCurrent()
  loadExtensions()  ## initialise OpenGL function pointers

  # ── Boxy ────────────────────────────────────────────────────────────────────
  let bxy = newBoxy()

  # Register each atlas sub-sprite as a named boxy image (once at load time).
  let atlasImg  = makePlaceholderAtlas(atlasData.width, atlasData.height)
  bxy.addAtlas(atlasData, atlasImg)

  let spriteMap = newBoxySpriteMap(atlasData)
  let atlasHnd  = TextureHandle(1)

  proc lookupSprites(h: TextureHandle): BoxySpriteMap =
    if h == atlasHnd: spriteMap else: nil

  # ── Per-frame animation state ──────────────────────────────────────────────
  var bones       = newSeq[BoneState](armData.bones.len)
  var slots       = newSeq[SlotState](armData.slots.len)
  var scratch:    seq[DbTransform]         ## propagation scratch, auto-grown
  var drawOrd     = newSeq[int](armData.slots.len)
  var zScratch:   seq[int]                 ## drawOrder scratch, auto-grown
  var drawCmds:   seq[DrawCommand]
  var meshScratch: seq[Vec2]
  let emptyFFD:   seq[seq[Vec2]] = @[]     ## no FFD in this fixture

  # Find the zOrder timeline once (absent for simple skeletons — pass empty seq).
  var zOrderKFs: seq[ZOrderKeyframe]
  for tl in animData.timelines:
    if tl.kind == tlZOrder:
      zOrderKFs = tl.zOrderKFs
      break

  let animDurSecs =
    if armData.frameRate > 0:
      float32(animData.duration) / float32(armData.frameRate)
    else: 0.0'f32

  var prevTime  = epochTime()
  var elapsedSecs = 0.0'f32

  # ── Game loop ──────────────────────────────────────────────────────────────
  while not window.closeRequested:
    pollEvents()

    # ── Time delta ────────────────────────────────────────────────────────────
    let now = epochTime()
    let dt  = float32(now - prevTime)
    prevTime = now
    elapsedSecs += dt
    if animDurSecs > 0: elapsedSecs = elapsedSecs mod animDurSecs

    # ── Animate ───────────────────────────────────────────────────────────────
    sampleAnimation(animData, armData, elapsedSecs, bones, slots)
    propagateWorldTransforms(armData, bones, scratch)
    sampleDrawOrder(zOrderKFs,
                    elapsedSecs * float32(armData.frameRate),
                    armData.slots.len, drawOrd, zScratch)
    emitDrawCommands(armData, skin, atlasData, atlasHnd,
                     bones, slots, drawOrd, emptyFFD,
                     drawCmds, meshScratch)

    # ── Render ────────────────────────────────────────────────────────────────
    let sz = window.size
    bxy.beginFrame(sz)

    # Translate skeleton origin to window centre.
    # DragonBones uses Y-down coordinates — no flip needed.
    bxy.saveTransform()
    bxy.translate(vec2(float32(sz.x div 2), float32(sz.y div 2)))
    bxy.renderDrawCommands(drawCmds, lookupSprites)
    bxy.restoreTransform()

    bxy.endFrame()
    window.swapBuffers()

main()
