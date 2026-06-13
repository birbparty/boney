# Package
version       = "0.1.0"
author        = "Matt Spurlin"
description   = "Pure-Nim DragonBones 2D skeletal animation runtime — render-agnostic core with naylib adapter"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]  # source-only install; no compiled artifacts
# Library package — no `bin` key. Consumers `import dragonbones` (not `import boney`).
# The package is named "boney" (the project) while the importable namespace is
# "dragonbones" (the upstream format name). This is intentional: `nimble install boney`
# then `import dragonbones` is the correct usage pattern.

# Dependencies
requires "nim >= 2.0.0"
requires "vmath >= 2.0.0"
requires "bumpy >= 1.1.0"
requires "jsony >= 1.1.6"

task test, "Run the test suite":
  exec "nim r tests/test_core_purity.nim"
  exec "nim r tests/parse/test_armature.nim"
  exec "nim r tests/parse/test_slot.nim"
  exec "nim r tests/parse/test_timeline.nim"
  exec "nim r tests/anim/test_sample.nim"
  exec "nim r tests/anim/test_propagate.nim"
  exec "nim r tests/anim/test_mesh.nim"
  exec "nim r tests/anim/test_draworder.nim"
  exec "nim r tests/anim/test_blend.nim"
  exec "nim r tests/atlas/test_atlas.nim"
  exec "nim r tests/golden/test_parse_golden.nim"
  exec "nim r tests/sampling/test_golden.nim"
