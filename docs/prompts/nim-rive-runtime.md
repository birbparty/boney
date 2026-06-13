# Project Planning with Beads

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary setup, implementation, testing, and documentation tasks. Go beyond the basics - consider edge cases, error handling, security considerations, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

## Project Information

### Links to Relevant Documentation

**Primary in-repo reference (READ FIRST):** `docs/reference/rive-runtime-reference.md` — a compiled,
source-cited implementation reference covering the `.riv` format, core object model, renderer
abstraction, runtime lifecycle, phased scope, and the boxy/clckr integration seams. Every uncertain
symbol is flagged with ⚠️ "verify against `include/rive/` before coding."

**Canonical upstream sources:**
- Rive low-level C++ runtime (MIT, canonical truth): https://github.com/rive-app/rive-runtime
- `.riv` binary format spec: https://help.rive.app/runtimes/advanced_topics/format · https://rive.app/docs/runtimes/advanced-topic/format
- Core definitions (type/property keys, the schema source of truth): `dev/defs/*.json` — https://github.com/rive-app/rive-runtime/tree/main/dev/defs
- Renderer/Factory seam: `include/rive/renderer.hpp`, `include/rive/factory.hpp`, `include/rive/command_path.hpp`
- No-op renderer (scaffolding start): https://github.com/rive-app/rive-runtime/tree/main/utils
- Low-level API usage / lifecycle: https://rive.app/docs/runtimes/web/low-level-api-usage
- State machines: https://rive.app/docs/runtimes/state-machines
- DeepWiki architecture synthesis: https://deepwiki.com/rive-app/rive-runtime
- **Best reimplementation reference:** pre-0.14 `rive-flutter` (pure-Dart core): https://github.com/rive-app/rive-flutter ; non-GC idioms: https://github.com/rive-app/rive-rs
- `.riv` inspection / parser-validation tool: https://github.com/rive-app/rive-code-generator-wip

**Integration target repos:**
- boxy (OpenGL atlas/quad renderer, Nim): `~/git/boxy` — main API `src/boxy.nim`, backend interface `src/boxy/backends/backend_interface.nim`
- clckr (raylib clicker game, Nim): `~/git/birbparty/clckr` — render seam `src/game/render.nim`, platform/raylib edge `src/game/platform.nim` + `src/game/raylib_api.nim`, core-purity guard `tests/game/test_core_purity.nim`

### Project Description

Build a from-scratch **Rive animation runtime in Nim** ("boney") that loads `.riv` files, advances
animations and state machines, and renders through pluggable 2D backends. The runtime is split into a
**renderer-agnostic, dependency-light core** (binary loader → core object model → scene-graph dependency
solver → linear-animation + state-machine engine, emitting draw commands against an abstract
`Renderer`/`Factory` seam) plus **two thin render adapters**: one for **boxy** (OpenGL atlas/quad on
Pixie) and one for **clckr**'s **raylib** (naylib) render seam.

The work is **MVP-first**: get vector-animation playback working end-to-end against a headless/no-op
renderer, then a real backend, before layering on state machines, raster assets, text, constraints, and
data binding. Both integration targets also build for **3DS and Vita**, so the core must stay tiny,
allocation-conscious, and free of heavy native dependencies (no HarfBuzz/libpng in the core path). A hard
constraint from clckr: its portable game core forbids importing boxy (enforced by a purity test), so the
Rive runtime core must be importable without *either* renderer.

### Technical Stack

- **Language:** Nim 2.x; **build:** nimble with `srcDir = "src"` set explicitly in the `.nimble` file.
  Add a root `nim.cfg` with `--path:"src"` (so the editor LSP resolves intra-package imports the same way
  nimble's build does) AND `--mm:orc` so editor and build agree on the memory model.
- **Memory / lifetime model (foundational decision — settle before any resource type is written):** use
  Nim **ARC/ORC** (`--mm:orc`), not the default refc GC. The scene graph has parent/child references that
  form **cycles** → plain ARC would leak, so **ORC** (cycle collector) or explicit cycle-breaking is required.
  The Rive `rcp<T>` smart pointer maps to Nim `ref object` under ORC. This decision drives every
  Factory-minted resource signature and the per-frame allocation discipline — make it an ADR-style task that
  blocks the renderer-abstraction work, and confirm boxy / naylib / `raylib_console` already build under the
  same `--mm` setting (clckr ships to 3DS, so it likely does — verify).
- **Core (zero mandatory third-party deps):** custom little-endian binary reader (LEB128 varuints),
  generated/hand-ported type-key + property-key + 2-bit-backing-type tables, scene graph with a
  topologically-sorted dirty/update solver, linear-animation engine (hold/linear/cubic-bezier easing,
  loop/pingPong/work-area), state-machine engine (Bool/Number/Trigger inputs, transitions, layers, blend
  states). Math via lightweight Mat2D/Vec2D/AABB (may reuse `vmath` if it stays portable).
- **Renderer abstraction:** Nim mirror of `rive::Renderer` (8 pure-virtual ops) + `Factory` +
  `RenderPath`/`RenderPaint`/`RenderImage`/`RenderBuffer`/`RenderShader`. A no-op backend ships first for
  headless tests; a software/tessellation path triangulates fills (nonZero/evenOdd) and strokes.
- **Backend adapters (premise is NOT yet proven — see Specific Requirements):** boxy and clckr both
  currently lack a confirmed arbitrary-triangle/mesh primitive on their **console (3DS/Vita)** targets, and
  boxy's raw-GL escape hatch is desktop-only. So each adapter has two routes that must be chosen per platform:
  (a) **tessellated triangles** — desktop only, and on boxy requires either authoring raw GL in the adapter or
  adding a `drawMesh` capability to boxy itself; (b) **CPU-rasterize Rive frames to an image → upload as a
  texture** (boxy `addImage` / raylib `DrawTexture`), which is the **console baseline**. The clckr/raylib
  adapter must be importable without boxy, and **boney's core must be importable without either adapter** to
  satisfy clckr's core-purity allowlist.
- **Targets:** desktop (macOS/Linux/Windows) first; 3DS (citro3d/GLSL ES 1.00) and Vita (vitaGL) as
  constraints the core must not violate. Deferred heavy deps (HarfBuzz/SheenBidi for text; libpng/jpeg/webp
  for raster decode) live behind optional modules / the `Factory.decode*` seam, never in the core.
- **Testing (layered oracle — no single tool validates everything):**
  - **Fixture acquisition is a prerequisite, not an afterthought.** `.riv` is a custom binary you cannot
    hand-author; the Rive editor is the only producer. Add an early high-priority task to author a small set
    of vector-only `.riv` files (single rotating rect; gradient fill; clipped shape; a state-machine one) and
    commit them under `tests/fixtures/` with provenance/license notes. This task **blocks every test task.**
  - **Loader layer:** diff parsed object/input/animation **names + counts** against `rive-code-generator-wip`
    JSON (NOTE: that tool is an experimental C++ binary that extracts *metadata only* — names/artboards/SM
    inputs/animations — NOT per-frame transforms or geometry; fall back to editor JSON export if it won't build).
  - **Animation layer:** port a handful of cases from **rive-flutter ≤0.13.x** (the pure-Dart reference) and
    assert numeric transform/opacity values frame-by-frame within an epsilon — this is the only GC'd reference
    with hand-written math you can cross-check.
  - **Scene-graph/advance layer:** the **no-op backend is the determinism oracle** — advance N frames against
    a fixed dt sequence and hash the emitted draw-command stream; zero display dependency, cheapest high-value
    test, belongs in Phase 1.
  - **Render layer:** **golden-image** comparison — render to an offscreen FBO (EGL) or the CPU-raster path,
    emit a PNG, diff against a checked-in reference with per-pixel tolerance + diff-artifact upload. ("Visually
    confirmed" is not automatable; replace it with golden-image diffs.)
  - Plus: round-trip parser tests; loader fuzzing (random truncation/bit-flip of valid fixtures — Nim has no
    built-in fuzzer, so this needs its own harness task).

### Specific Requirements

- **Strict core/renderer separation.** The core must compile and run with the no-op backend and must NOT
  import boxy, raylib, or any GPU/native lib. Add a purity test mirroring clckr's
  `test_core_purity.nim` that fails if the core imports a backend.
- **Wire-format correctness is load-bearing.** Type keys, property keys, the 2-bit ToC backing-type codes
  (0=uint/bool, 1=string, 2=float, 3=color), and the `BlendMode` enum (NON-contiguous values) are wire
  format — verify every value against `include/rive/` / `dev/defs/` headers before coding it; do not infer
  from patterns. Resolve the ⚠️-flagged uncertainties in the reference doc (ToC bit-packing stride;
  `field_types` filenames; `loopValue`/`interpolationType` enum values; `onDependencySolve`/
  `m_DependencyOrder`/`getBool` spellings) as their own grounding tasks before dependent work.
- **Forward/backward compatibility from day one.** The loader MUST skip unknown type keys and unknown
  property keys using the ToC backing type (forward compat), and fall back to `initialValueRuntime`
  defaults for missing properties (backward compat). Target format major version **7**; reject mismatched
  majors with a clear error. Fuzz/garbage-input tests must not crash the loader.
- **MVP-first, phased delivery.** Phase boundaries: (1) vector playback no-SM → (2) state machines →
  (3) raster assets/meshes → (4) text → (5) constraints/clipping/nested artboards → (6) data binding/
  events/audio/scripting (likely out of scope). Each phase ends with a runnable demo + tests.
- **Resource discipline for 3DS/Vita.** No per-frame heap churn in the hot path; pre-size buffers; cap
  tessellation cost; keep the core's static footprint small. Document any allocation in the advance/draw loop.
- **Licensing hygiene.** MIT. If any code is ported directly from rive-runtime, retain the Rive MIT notice;
  prefer clean-room-from-spec where practical. Do not use Rive branding in a way implying official endorsement.
- **Verification bar.** "Builds" is not "works": each backend adapter must render a known `.riv` fixture and
  be visually/empirically confirmed, not just compiled. Keep clckr's core-purity test green throughout.

---

## Your Task

Analyze this project and create a comprehensive **Beads task graph** using the `bd` CLI. Beads provides dependency-aware, conflict-free task management for multi-agent execution.

---

<critical_constraint>
Your ONLY output is a bash shell script. Do NOT use `bd add` — the correct command to create a bead is `bd create`. Use `bd dep add` for dependencies. Do not implement anything yourself.
</critical_constraint>

## Output Format

Generate a shell script that creates the full task graph. The script should:

1. **Initialize Beads** (if not already initialized)
2. **Create all beads** with appropriate priorities
3. **Establish dependencies** between beads
4. **Add labels** for phase grouping

### Example Output

```bash
#!/bin/bash
# Project: boney
# Generated: 2026-06-12

set -e

# Initialize beads if needed
if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating project beads..."

# ========================================
# Phase 1: Project Setup & Infrastructure
# ========================================

SETUP_VITE=$(bd create "Initialize project with Vite + React + TypeScript" -p 0 --label setup --silent)

SETUP_LINT=$(bd create "Configure ESLint, Prettier, and TypeScript strict mode" -p 1 --label setup --silent)
bd dep add $SETUP_LINT $SETUP_VITE

SETUP_TAILWIND=$(bd create "Set up Tailwind CSS with design system tokens" -p 1 --label setup --silent)
bd dep add $SETUP_TAILWIND $SETUP_VITE

SETUP_TESTING=$(bd create "Configure testing framework (Vitest + Testing Library)" -p 1 --label setup --silent)
bd dep add $SETUP_TESTING $SETUP_LINT

# ========================================
# Phase 2: Core Architecture
# ========================================

API_CLIENT=$(bd create "Implement API client with error handling and retries" -p 0 --label core --silent)
bd dep add $API_CLIENT $SETUP_VITE

STATE_MGMT=$(bd create "Set up global state management (Zustand/Jotai)" -p 0 --label core --silent)
bd dep add $STATE_MGMT $SETUP_VITE

AUTH_CONTEXT=$(bd create "Create authentication context and hooks" -p 0 --label core --silent)
bd dep add $AUTH_CONTEXT $STATE_MGMT
bd dep add $AUTH_CONTEXT $API_CLIENT

# ... continue for all phases ...

echo ""
echo "Bead graph created! View with:"
echo "  bd ready              # List unblocked tasks"
```

---

## Bead Creation Guidelines

### Priority Levels
- `-p 0` = Critical (blocking other work)
- `-p 1` = High (important but not blocking)
- `-p 2` = Medium (standard work)
- `-p 3` = Low (nice to have)

### Labels (Phase Grouping)
Use `--label` to group beads by phase:
- `setup` - Project initialization
- `core` - Core architecture
- `auth` - Authentication/authorization
- `ui` - UI components
- `feature-{name}` - Feature-specific work
- `testing` - Test coverage
- `docs` - Documentation
- `deploy` - Deployment/CI

### Dependency Rules
1. Never create cycles
2. Every bead should have a clear dependency chain back to setup tasks
3. Use `bd dep add CHILD PARENT` (child depends on parent completing first)
4. Parallel work should share a common ancestor, not depend on each other

### Task Granularity
- Each bead should be completable in **under 750 lines of code**
- Tasks should be atomic enough for one agent to complete without coordination
- If a task requires multiple file areas, consider splitting by file area

---

## File Reservation Planning

For each major work area, note the file patterns that will need exclusive reservation:

```bash
# Example reservation notes (add as bead descriptions)
# Binary loader / format:  src/boney/io/**, tests/io/**
# Core object model:       src/boney/core/**, src/boney/generated/**, tests/core/**
# Scene graph / solver:    src/boney/scene/**, tests/scene/**
# Animation engine:        src/boney/animation/**, tests/animation/**
# State machine engine:    src/boney/statemachine/**, tests/statemachine/**
# Renderer abstraction:    src/boney/render/**, tests/render/**
# boxy adapter:            src/boney/backends/boxy/**, tests/backends/boxy/**
# raylib adapter:          src/boney/backends/raylib/**, tests/backends/raylib/**
```

This helps agents claim appropriate file surfaces when they start work.

---

## Context Documentation

Place any important context in `prompts/docs/` for agents to reference. This includes:
- Architecture decisions
- API documentation
- Design system specs
- External service integration guides

(Note: this project already has a primary reference at `docs/reference/rive-runtime-reference.md` — point agents there first.)

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beads.sh && ./setup-beads.sh`
2. **Check ready work**: `bd ready` should show initial setup tasks

---

## Completeness Checklist

Ensure your task graph includes:

- [ ] All setup and configuration tasks
- [ ] Core architecture and shared utilities
- [ ] Feature implementation tasks (broken into small units)
- [ ] Error handling and edge cases
- [ ] Unit and integration tests for each feature
- [ ] API documentation
- [ ] Security considerations (input validation, auth checks)
- [ ] Performance considerations where relevant
- [ ] CI/CD and deployment tasks
- [ ] Clear dependency chains with no cycles
