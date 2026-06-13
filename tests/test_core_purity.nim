import std/[unittest, os, strutils]

## Architectural fitness function: the boney DragonBones core must stay
## render-agnostic so all targets (desktop, 3DS -d:ds3, Vita -d:vita) share
## one tested core. This test fails the build if a core module imports anything
## outside the allowlist {bumpy, vmath, std/*, other core modules}.
##
## It is an ALLOWLIST (fail-closed), not a denylist: an unknown future backend,
## an accidental `import dragonbones/adapters/naylib` from a core module, and a
## newly-added core module are ALL caught by default — only a deliberate edit to
## `coreModules` opts a dependency in.
##
## Scanned surface:
##   - src/dragonbones.nim          (public aggregator / re-export facade)
##   - src/dragonbones/{model,parse,atlas,anim}/**/*.nim  (core subsystems)
##
## Excluded:
##   - src/dragonbones/adapters/**  — adapters import their backends by design
##   - jsony — NOT on the allowlist until boney-782 (jsony cross-compile spike) clears it
##
## Intra-package import policy:
##   Bare/relative imports (./foo, ../bar/baz) are ALLOWED — they can only refer
##   to other files within the core source tree. Fully-qualified
##   `dragonbones/model/types` imports are also allowed.
##   To add jsony to the allowlist after boney-782 clears it, add `"jsony"` to
##   the `namedAllowlist` set in `isAllowed`.
##
## Adapted from birbparty/clckr tests/game/test_core_purity.nim.

const
  ## The core module namespace. Add a new core subdirectory here; it may then
  ## be imported by other core modules. A core file importing
  ## `dragonbones/<x>` where <x> is NOT listed fails the build, forcing a
  ## conscious allowlist edit when wiring in a new core subsystem.
  coreModules = ["model", "parse", "atlas", "anim"]

proc isAllowed(m: string): bool =
  ## A core module may import: bumpy, vmath, any std/* module, another
  ## core module (dragonbones/<coreModule> or sub-paths), or a bare/relative
  ## import (./foo, ../bar/baz — always intra-package).
  ## Everything else — naylib, boxy, opengl, pixie, chroma, libctru, citro3d,
  ## jsony (until boney-782 clears it), any future renderer — is forbidden.
  # Named allowlist
  if m == "bumpy" or m == "vmath": return true
  # std/* standard library
  if m.startsWith("std/"): return true
  # Bare/relative imports: always intra-package (can only reference other files
  # within src/dragonbones/ or its subdirectories)
  if m.startsWith("./") or m.startsWith("../"): return true
  # Qualified core module: dragonbones/model, dragonbones/model/types, etc.
  if m.startsWith("dragonbones/"):
    let rest = m[len("dragonbones/") .. ^1]
    # Direct core module: dragonbones/model
    if rest in coreModules: return true
    # Sub-path of a core module: dragonbones/model/types, etc.
    let slash = rest.find('/')
    if slash >= 0 and rest[0 ..< slash] in coreModules: return true
  false

proc stripBlockComments(s: string): string =
  ## Drop Nim `#[ ... ]#` block comments (nesting-aware) so a commented-out
  ## import inside a block is not scanned as live code. Newlines are preserved.
  result = newStringOfCap(s.len)
  var i = 0
  var depth = 0
  while i < s.len:
    if i + 1 < s.len and s[i] == '#' and s[i+1] == '[':
      inc depth; inc i, 2
    elif depth > 0 and i + 1 < s.len and s[i] == ']' and s[i+1] == '#':
      dec depth; inc i, 2
    elif depth > 0:
      if s[i] == '\n': result.add '\n'
      inc i
    else:
      result.add s[i]; inc i

iterator importStatements(src: string): string =
  ## Yield each import/from/include statement, de-commented (line `#` and block
  ## `#[ ]#`) with bracket / trailing-comma continuations merged into one line.
  ## Limitation: imports preceded by other code on the same line (e.g.
  ## `discard 1; import foo`) are not detected — this is an acceptable limitation
  ## for a core-purity check; such style is not idiomatic in Nim library code.
  let clean = stripBlockComments(src)
  var buf = ""
  var bracket = 0
  for raw in clean.splitLines():
    let h = raw.find('#')
    let code = (if h >= 0: raw[0 ..< h] else: raw).strip()
    if buf.len == 0:
      if not (code.startsWith("import ") or code.startsWith("from ") or
              code.startsWith("include ")):
        continue
      buf = code
    else:
      if code.len == 0: continue
      buf.add ' ' & code
    bracket += code.count('[') - code.count(']')
    if buf.endsWith(",") or bracket > 0:
      continue
    yield buf
    buf = ""
    bracket = 0
  if buf.len > 0: yield buf

proc splitTopLevel(s: string): seq[string] =
  ## Split on commas NOT inside `[ ]`, so `std/[os, strutils]` stays one item.
  var depth = 0
  var cur = ""
  for c in s:
    case c
    of '[': inc depth; cur.add c
    of ']': dec depth; cur.add c
    of ',':
      if depth == 0: (result.add cur; cur = "")
      else: cur.add c
    else: cur.add c
  if cur.strip().len > 0: result.add cur

proc refsOf(part0: string): seq[string] =
  ## Normalize one import item to module refs: handles `mod as alias`,
  ## `mod except symbol`, and the bracket form `root/[a, b]` -> root/a, root/b.
  var part = part0.strip()
  # Strip `except ...` clause: `import bumpy except foo` -> `bumpy`
  let ep = part.find(" except ")
  if ep >= 0: part = part[0 ..< ep].strip()
  # Strip `as alias`: `import boxy as gfx` -> `boxy`
  let ap = part.find(" as ")
  if ap >= 0: part = part[0 ..< ap].strip()
  # Bracket form: `std/[os, strutils]` -> `std/os`, `std/strutils`
  let bi = part.find('[')
  if bi >= 0:
    let root = part[0 ..< bi]
    let inner = part[bi+1 .. ^1].replace("]", "")
    for sub in inner.split(','):
      let s2 = sub.strip()
      if s2.len > 0: result.add root & s2
  elif part.len > 0:
    result.add part

proc importsOf(stmt: string): seq[string] =
  ## All module refs introduced by one import/from/include statement.
  var s = stmt
  if s.startsWith("include "): s = s[len("include ") .. ^1]
  elif s.startsWith("from "):
    s = s[len("from ") .. ^1]
    let ip = s.find(" import ")
    if ip >= 0: s = s[0 ..< ip]
  elif s.startsWith("import "): s = s[len("import ") .. ^1]
  for part in s.splitTopLevel():
    result.add part.refsOf()

proc violations(path: string): seq[string] =
  ## Disallowed module refs imported by the file at `path` (deduped).
  for stmt in readFile(path).importStatements():
    for m in stmt.importsOf():
      if not m.isAllowed and m notin result:
        result.add m

# Build the set of files to check. Core dirs only (adapters import their
# backends by design and are excluded). Also scan the top-level aggregator.
let coreBase = (currentSourcePath().parentDir / ".." / "src" / "dragonbones").normalizedPath
doAssert dirExists(coreBase), "core source dir not found: " & coreBase

var coreFiles: seq[string]
# Top-level public aggregator
let topLevel = (coreBase / ".." / "dragonbones.nim").normalizedPath
if fileExists(topLevel):
  coreFiles.add topLevel
# Core subsystem directories only (excludes adapters/)
for sub in coreModules:
  let subDir = coreBase / sub
  if dirExists(subDir):
    for f in walkDirRec(subDir, yieldFilter = {pcFile}):
      if f.endsWith(".nim"):
        coreFiles.add f

suite "core purity":
  test "allowlist behaves correctly":
    # Named allowed libs
    check isAllowed("bumpy")
    check isAllowed("vmath")
    # std/*
    check isAllowed("std/strutils")
    check isAllowed("std/os")
    # Core modules (qualified)
    check isAllowed("dragonbones/model")
    check isAllowed("dragonbones/anim")
    check isAllowed("dragonbones/model/types")    # sub-path of core module
    # Relative/bare intra-package imports (always in-core)
    check isAllowed("./types")
    check isAllowed("../atlas/atlas")
    # Forbidden
    check not isAllowed("naylib")
    check not isAllowed("boxy")
    check not isAllowed("jsony")                  # blocked until boney-782 clears it
    check not isAllowed("chroma")
    check not isAllowed("dragonbones/adapters/naylib")  # adapter is not core
    check not isAllowed("dragonbones/adapters/boxy")

  test "import parser handles all Nim import forms":
    check "naylib" in importsOf("import naylib, boxy")
    check "boxy" in importsOf("import naylib, boxy")
    check "boxy/something" in importsOf("import boxy/something")
    check "naylib" in importsOf("from naylib import Texture2D")
    check "boxy" in importsOf("import boxy as gfx")
    check "std/os" in importsOf("import std/[os, strutils]")
    check "std/strutils" in importsOf("import std/[os, strutils]")
    check "vmath" in importsOf("import vmath")
    check "bumpy" in importsOf("import bumpy")
    # `except` clause must not produce a false positive
    check "bumpy" in importsOf("import bumpy except foo")
    check importsOf("import bumpy except foo") == @["bumpy"]
    # `include` statements are treated as imports
    check "dragonbones/model" in importsOf("include dragonbones/model")

  test "commented-out imports are not scanned as live code":
    let src = "import bumpy\n#[ import naylib ]#\nimport dragonbones/model\n# import boxy\n"
    var mods: seq[string]
    for stmt in src.importStatements():
      mods.add stmt.importsOf()
    check "bumpy" in mods
    check "dragonbones/model" in mods
    check "naylib" notin mods
    check "boxy" notin mods

  test "violations() detects forbidden imports":
    # Synthetic violation: a core file that imports naylib
    let tmpFile = getTempDir() / "fake_core_module.nim"
    writeFile(tmpFile, "import bumpy\nimport naylib\n")
    let bad = violations(tmpFile)
    check "naylib" in bad
    check "bumpy" notin bad
    removeFile(tmpFile)

  test "core dragonbones modules import only bumpy/vmath/std/core":
    if coreFiles.len == 0:
      checkpoint("WARNING: no core .nim files yet — purity unenforced (scaffold phase)")
      skip()
    for path in coreFiles:
      let bad = violations(path)
      if bad.len > 0:
        checkpoint(path.extractFilename & " imports disallowed: " & bad.join(", "))
      check bad.len == 0
