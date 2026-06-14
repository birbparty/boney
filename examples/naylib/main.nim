## boney naylib example — DragonBones skeletal animation picker.
##
## Scans ResourceDir for compatible DragonBones example sets (those with a
## single *_ske.json + *_tex.json + *_tex.png triple) and lets you browse
## them with arrow keys. Loads real PNG textures from the DragonBonesJS demo
## resource directory.
##
## Controls:
##   Left / Right  -- cycle example sets
##   Up   / Down   -- cycle animations within the current armature
##   ESC           -- quit
##
## Build (from repo root):
##   nim r examples/naylib/main.nim
##
## Override the resource directory at compile time:
##   nim r -d:ResourceDir=/path/to/resources examples/naylib/main.nim
##
## Or pass the directory as a runtime argument:
##   ./main /path/to/resources

import std/[os, algorithm, strutils]
import raylib, rlgl, vmath
import dragonbones/parse/armature
import dragonbones/atlas/atlas
import dragonbones/model/model
import dragonbones/anim/[sample, propagate, draworder, emit]
import dragonbones/boundary
import dragonbones/adapters/naylib/adapter

const
  ScreenW = 800'i32
  ScreenH = 600'i32
  Title   = "boney naylib example picker"

const DefaultResourceDir {.strdefine.} =
  "/Users/punk1290/git/DragonBonesJS/Pixi/Demos/resource"

# ── Example-set discovery ──────────────────────────────────────────────────────

type ExampleSet = object
  name:    string   ## directory name (used as display label)
  skeFile: string
  texFile: string
  pngFile: string

proc scanExamples(dir: string): seq[ExampleSet] =
  ## Scan one level deep for dirs containing exactly one *_ske.json,
  ## one *_tex.json, and one *_tex.png. Excludes effect (2 tex), shizuku
  ## (no tex.json), and you_xin suits (2 levels deep).
  for kind, path in walkDir(dir):
    if kind != pcDir: continue
    var skes, texs, pngs: seq[string]
    for fkind, f in walkDir(path):
      if fkind != pcFile: continue
      if   f.endsWith("_ske.json"): skes.add(f)
      elif f.endsWith("_tex.json"): texs.add(f)
      elif f.endsWith("_tex.png"):  pngs.add(f)
    if skes.len == 1 and texs.len == 1 and pngs.len == 1:
      result.add ExampleSet(name:    lastPathPart(path),
                            skeFile: skes[0],
                            texFile: texs[0],
                            pngFile: pngs[0])
  result.sort(proc(a, b: ExampleSet): int = cmp(a.name, b.name))

# ── Loaded-armature state ──────────────────────────────────────────────────────

## Texture2D is move-only (naylib v26 RAII — =dup is .error).
## Box it on the heap so the lookup closure can return a stable ptr.
type TexBox = ref object
  v: Texture2D

type LoadedSet = object
  dbData:    DragonBonesData
  atlasData: AtlasData
  box:       TexBox
  armIdx:    int   ## which armature in dbData.armatures
  animIdx:   int   ## which animation in the current armature

## Zero-cost templates avoid the lent-return borrow-checker complexity.
template arm(ls: LoadedSet): ArmatureData  = ls.dbData.armatures[ls.armIdx]
template anim(ls: LoadedSet): AnimationData = ls.arm.animations[ls.animIdx]

proc pickArmIdx(data: DragonBonesData, preferName: string): int =
  ## Match by armature name → directory name; fallback to most bones.
  var bestIdx = 0; var bestBones = -1
  for i, a in data.armatures:
    if a.name == preferName: return i
    if a.bones.len > bestBones:
      bestBones = a.bones.len
      bestIdx   = i
  bestIdx

proc loadSet(es: ExampleSet): LoadedSet =
  result.dbData    = parseDragonBones(readFile(es.skeFile))
  result.atlasData = parseAtlas(readFile(es.texFile))
  doAssert result.dbData.armatures.len > 0, "no armatures in " & es.name
  result.armIdx  = pickArmIdx(result.dbData, es.name)
  result.animIdx = 0
  ## Resolve PNG: try imagePath from atlas JSON first, fallback to scanned name.
  let pngPath   = parentDir(es.texFile) / result.atlasData.imagePath
  let finalPath = if fileExists(pngPath): pngPath else: es.pngFile
  result.box = TexBox(v: loadTexture(finalPath))

proc extractZOrderKFs(ad: AnimationData): seq[ZOrderKeyframe] =
  for tl in ad.timelines:
    if tl.kind == tlZOrder: return tl.zOrderKFs

# ── Main ───────────────────────────────────────────────────────────────────────

proc main() =
  let resourceDir = if paramCount() > 0: paramStr(1) else: DefaultResourceDir
  let examples    = scanExamples(resourceDir)
  if examples.len == 0:
    echo "No compatible DragonBones examples found in: ", resourceDir
    echo "Expected: subdirectories with *_ske.json + *_tex.json + *_tex.png"
    quit(1)

  echo "Found ", examples.len, " example sets"

  initWindow(ScreenW, ScreenH, Title)
  setTargetFPS(60)

  var exIdx = 0
  var cur   = loadSet(examples[exIdx])

  # The closure captures `cur` by reference (var). Each frame it takes
  # addr(cur.box.v) fresh, so swapping cur on example switch is safe.
  proc lookupTex(h: TextureHandle): ptr Texture2D =
    addr(cur.box.v)

  # ── Per-frame animation buffers (resized on example switch) ───────────────
  var bones:       seq[BoneState]
  var slots:       seq[SlotState]
  var scratch:     seq[DbTransform]
  var drawOrd:     seq[int]
  var zScratch:    seq[int]
  var drawCmds:    seq[DrawCommand]
  var meshScratch: seq[Vec2]
  let emptyFFD:    seq[seq[Vec2]] = @[]

  var zOrderKFs:   seq[ZOrderKeyframe]
  var elapsedSecs  = 0.0'f32
  var animDurSecs  = 0.0'f32

  # Rendering params (recomputed on example switch)
  var cx, cy, scale: float32

  proc applySet() =
    let a = cur.arm
    doAssert a.skins.len > 0, "armature has no skins: " & a.name
    doAssert a.animations.len > 0, "armature has no animations: " & a.name
    bones       = newSeq[BoneState](a.bones.len)
    slots       = newSeq[SlotState](a.slots.len)
    drawOrd     = newSeq[int](a.slots.len)
    zOrderKFs   = extractZOrderKFs(cur.anim)
    elapsedSecs = 0
    animDurSecs = if a.frameRate > 0:
                    float32(cur.anim.duration) / float32(a.frameRate)
                  else: 0.0'f32
    ## aabb uses bumpy.Rect fields: x, y, w, h (NOT width/height)
    let maxDim = max(a.aabb.w, a.aabb.h)
    scale = if maxDim > 0: min(1.0'f32, float32(ScreenH - 100) / maxDim)
            else: 1.0'f32
    cx = float32(ScreenW div 2) - (a.aabb.x + a.aabb.w / 2) * scale
    cy = float32(ScreenH div 2) - (a.aabb.y + a.aabb.h / 2) * scale
    echo examples[exIdx].name, " | arm: ", a.name,
         " | bones: ", a.bones.len, " | slots: ", a.slots.len,
         " | anims: ", a.animations.len

  applySet()

  # ── Game loop ──────────────────────────────────────────────────────────────
  while not windowShouldClose():

    # ── Input ─────────────────────────────────────────────────────────────────
    var switched = false
    if isKeyPressed(KeyboardKey.Right):
      exIdx = (exIdx + 1) mod examples.len
      cur   = loadSet(examples[exIdx])
      switched = true
    elif isKeyPressed(KeyboardKey.Left):
      exIdx = (exIdx - 1 + examples.len) mod examples.len
      cur   = loadSet(examples[exIdx])
      switched = true

    if switched:
      applySet()
    else:
      var animSwitched = false
      if isKeyPressed(KeyboardKey.Up):
        cur.animIdx  = (cur.animIdx + 1) mod cur.arm.animations.len
        animSwitched = true
      elif isKeyPressed(KeyboardKey.Down):
        cur.animIdx  = (cur.animIdx - 1 + cur.arm.animations.len) mod
                        cur.arm.animations.len
        animSwitched = true
      if animSwitched:
        zOrderKFs   = extractZOrderKFs(cur.anim)
        elapsedSecs = 0
        animDurSecs = if cur.arm.frameRate > 0:
                        float32(cur.anim.duration) / float32(cur.arm.frameRate)
                      else: 0.0'f32

    # ── Animate ───────────────────────────────────────────────────────────────
    let dt = getFrameTime()
    elapsedSecs += dt
    if animDurSecs > 0: elapsedSecs = elapsedSecs mod animDurSecs

    let a    = cur.arm
    let anim = cur.anim

    sampleAnimation(anim, a, elapsedSecs, bones, slots)
    propagateWorldTransforms(a, bones, scratch)
    sampleDrawOrder(zOrderKFs,
                    elapsedSecs * float32(a.frameRate),
                    a.slots.len, drawOrd, zScratch)
    emitDrawCommands(a, a.skins[0], cur.atlasData, TextureHandle(1),
                     bones, slots, drawOrd, emptyFFD, drawCmds, meshScratch)

    # ── Render ────────────────────────────────────────────────────────────────
    beginDrawing()
    clearBackground(DARKGRAY)

    pushMatrix()
    translatef(cx, cy, 0)
    scalef(scale, scale, 1)
    renderDrawCommands(drawCmds, lookupTex)
    popMatrix()

    drawFPS(10, 10)
    drawText(examples[exIdx].name & " [" & $(exIdx + 1) & "/" &
             $examples.len & "] Left/Right",
             10, 30, 18, RAYWHITE)
    drawText(anim.name & " [" & $(cur.animIdx + 1) & "/" &
             $a.animations.len & "] Up/Down",
             10, 52, 18, RAYWHITE)
    drawText("Bones: " & $a.bones.len & "  Slots: " & $a.slots.len,
             10, 74, 16, LIGHTGRAY)

    endDrawing()

  closeWindow()

main()
