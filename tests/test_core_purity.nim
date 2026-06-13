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
## Exclusions:
##   - src/dragonbones/adapters/boxy/  — desktop-only, imports pixie, never pure
##   - jsony — NOT on the allowlist until boney-782 (jsony cross-compile spike) clears it
##
## Adapted from birbparty/clckr tests/game/test_core_purity.nim.

const
  ## The core module namespace. Add a new core subdirectory here; it may then
  ## be imported by other core modules. A core file importing
  ## `dragonbones/<x>` where <x> is NOT listed fails the build, forcing a
  ## conscious allowlist edit when wiring in a new core subsystem.
  coreModules = ["model", "parse", "atlas", "anim"]

proc isAllowed(m: string): bool =
  ## A core module may import only: bumpy, vmath, any std/* module, or another
  ## core module (dragonbones/<coreModule> or dragonbones/<coreModule>/*).
  ## Everything else — naylib, boxy, opengl, pixie, chroma, libctru, citro3d,
  ## jsony (until the console spike clears it), any future renderer — is forbidden.
  if m == "bumpy" or m == "vmath": return true
  if m.startsWith("std/"): return true
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
  ## Normalize one import item to module refs: handles `mod as alias` and the
  ## bracket form `root/[a, b]` -> root/a, root/b.
  var part = part0.strip()
  let ap = part.find(" as ")
  if ap >= 0: part = part[0 ..< ap].strip()
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

proc isAdapterBoxy(path: string): bool =
  ## The boxy adapter is desktop-only (imports pixie) and explicitly excluded
  ## from core-purity checks. Match by path prefix.
  path.replace('\\', '/').contains("dragonbones/adapters/boxy")

let srcDir = currentSourcePath().parentDir / ".." / "src" / "dragonbones"

suite "core purity":
  test "allowlist behaves correctly":
    check isAllowed("bumpy")
    check isAllowed("vmath")
    check isAllowed("std/strutils")
    check isAllowed("std/os")
    check isAllowed("dragonbones/model")
    check isAllowed("dragonbones/anim")
    check isAllowed("dragonbones/model/types")    # sub-path of core module
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

  test "commented-out imports are not scanned as live code":
    let src = "import bumpy\n#[ import naylib ]#\nimport dragonbones/model\n# import boxy\n"
    var mods: seq[string]
    for stmt in src.importStatements():
      mods.add stmt.importsOf()
    check "bumpy" in mods
    check "dragonbones/model" in mods
    check "naylib" notin mods
    check "boxy" notin mods

  test "core dragonbones modules import only bumpy/vmath/std/core":
    var coreFiles: seq[string]
    for f in walkDirRec(srcDir, yieldFilter = {pcFile}):
      if f.endsWith(".nim") and not isAdapterBoxy(f):
        coreFiles.add f
    # Pass trivially when no core .nim files exist yet (scaffold phase).
    # Each file added to src/dragonbones/** (outside adapters/boxy) is checked.
    for path in coreFiles:
      let bad = violations(path)
      if bad.len > 0:
        checkpoint(path.extractFilename & " imports disallowed: " & bad.join(", "))
      check bad.len == 0
