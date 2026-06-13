# Project Planning with Beads

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary setup, implementation, testing, and documentation tasks. Go beyond the basics - consider edge cases, error handling, security considerations, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

## Project Information

### Links to Relevant Documentation
- **DragonBones data format spec** — the JSON skeleton + texture-atlas schema. Reference: DragonBones/DragonBonesJS data format docs (https://github.com/DragonBones/DragonBonesJS) and the format reference under its `Demo`/`docs` (armature, bone, slot, skin, animation, timeline, ffd/mesh, displayData definitions).
- **Existing runtime ports** — use as implementation guides for the runtime math and timeline semantics:
  - DragonBonesJS (TypeScript reference runtime) — canonical animation/state-machine behavior.
  - DragonBones C++ / Cocos2d-x runtime — low-level, allocation-conscious reference closer to what a Nim/console port needs.
  - Spine-style skeletal runtimes — for cross-checking bezier curve sampling and mesh deformation conventions.

### Project Description
A **pure-Nim runtime library for DragonBones** (2D skeletal animation) that the birbparty Nim projects `~/git/boxy` (2D GPU rendering) and `~/git/birbparty/clckr` (idle clicker on naylib/raylib) can both consume. The library parses DragonBones skeleton JSON + texture-atlas JSON + PNG, builds an armature/bone/slot/skin model, and drives runtime animation (timeline sampling, bone transforms, slot draw order, mesh/FFD deformation). The core is **render-agnostic** — it emits backend-neutral transformed draw data (slot quads/meshes with transforms and atlas UVs) that any renderer can draw — and the library ships a **naylib/raylib adapter out of the box**, with a boxy adapter provided as an optional/example module.

### Technical Stack
- **Language:** Pure Nim (`nim >= 2.0.0`), matching boxy/clckr toolchain (Nim 2.2.x), `--mm:arc --define:useMalloc` for console parity.
- **Math (COMMITTED, not a fork):** use `vmath` + `bumpy` for all core vector/matrix types. Both are on clckr's proven core-purity allowlist and compile under `-d:ds3`/Vita today — they are confirmed console-safe, so the core's public types expose `vmath`/`bumpy` types directly. Do **not** introduce a bespoke internal `Vec2`/`Mat2d`; a third math type that must stay value-compatible with both consumers is a maintenance trap and a transform-bug source. (Reviewer-confirmed: allowlist = `{bumpy, vmath, std/*, core modules}`.)
- **JSON parsing (UNRESOLVED — gated by a front-loaded risk spike):** `jsony` is the preferred parser for speed/low-allocation, **but jsony is NOT on clckr's core-purity allowlist** and is unverified on ARMv6K/Vita. A spike task (see "Risk Spikes" below) must either (a) prove jsony cross-compiles for 3DS + Vita and add it to boney's own purity allowlist, or (b) fall back to a hand-rolled tokenizing parser (larger, unplanned scope). Do not assume "pure Nim / no C deps" equals "console-safe / allowlisted" — clckr enforces an allowlist, not a C-dependency check.
- **Architecture:** render-agnostic core package + thin adapter modules.
  - `dragonbones` (core) — parse + model + animation state + per-frame transformed output (transformed slot quads and **deformed mesh vertex buffers** + atlas UVs). Zero rendering/IO-backend deps; **never decodes or owns pixels** (see image-handle rule below).
  - `dragonbones/adapters/naylib` — shipped out of the box. Plain image slots map to `DrawTexturePro` (the only draw primitive clckr's console raylib binding exposes). **Deformed meshes (mesh display + FFD/skinned weights) have no console-viable draw primitive today** — `raylib_console.nim` binds no `DrawMesh`/`rlVertex`. So on console the adapter degrades mesh slots to a bounding quad **unless** a separate task extends the console binding with an immediate-mode/mesh primitive (real, non-trivial work touching clckr binding conventions). On desktop naylib, meshes use `rlBegin/rlVertex` or `DrawMesh`. State the chosen behavior explicitly per target.
  - `dragonbones/adapters/boxy` — optional/example, **desktop-only and excluded from console builds and from the core-purity allowlist**. boxy imports `pixie` in *both* its desktop and `ds3` branches (`src/boxy.nim`), so this adapter is never pixie-free and must never be compiled for 3DS/Vita. boxy's public draw API is quad/atlas-key based (`drawImage`/`drawUvRect`/`drawRect`) with **no public arbitrary-triangle mesh draw** — so the boxy adapter renders deformed mesh slots as bounding quads (or skips FFD) unless a new boxy mesh primitive is added. Call this out; do not promise full mesh fidelity through boxy.
- **Image/texture ownership (render-agnostic boundary rule):** the core takes atlas **metadata** + an **opaque texture handle** (`Texture2D` for naylib, boxy `Image`/atlas key for boxy) — never raw PNG bytes. PNG decode/upload lives in the **adapter** layer (raylib `LoadTexture` from `romfs:/`/`app0:` on console; pixie on boxy desktop). The convenience loader therefore takes (skeleton JSON, atlas JSON, already-decoded texture handle), not an image file, or it re-introduces the backend dependency the architecture forbids.
- **Build/layout:** standard nimble package, `srcDir = "src"`, root `nim.cfg` with `--path:"src"` for LSP, plus `nim_3ds.cfg`/`nim_vita.cfg` mirroring boxy/clckr. Ship boney's **own** `tests/test_core_purity.nim` mirroring clckr's allowlist fitness function (allowlist = `{vmath, bumpy, std/*, dragonbones core modules}`, + `jsony` only if the spike clears it) so the no-backend-deps invariant is machine-checked.

### Specific Requirements

> **Pin the DragonBones data-format version range up front.** Golden files and curve/easing encodings differ across DragonBones 4.x/5.x (`version`/`compatibleVersion`, bone `transform` layout, `frameRate`/`isGlobal`, tween-curve encoding). Target JSON exports only (the binary `.dbbin` format is out of scope unless added explicitly) and state the supported `version` range so the parser targets one schema generation, not a guessed one.

- **Console targets (3DS / Vita):** the **core must cross-compile for the same ARM console targets** boxy and clckr support. Core = allowlisted imports only (`vmath`/`bumpy`/`std/*` + core), low/no per-frame heap allocation. Provide `nim_3ds.cfg` / `nim_vita.cfg` and a build-script path consistent with boxy/clckr — do **not** rely on `nimble build` for console targets (it resolves desktop-only deps); call `nim compile`/the build script directly per those repos' notes. The console build differs by target (3DS ARMv6K hard-float via `devkitARM`/`scripts/build_3ds.sh`; Vita ARMv7 via VitaSDK with `-Wl,-q`), and both need an SDK CI may not have — so the **primary, SDK-free invariant gate is the core-purity test + `nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --opt:size`**, with a full devkit/Vita link as an optional, separately-gated job. Do not specify "build for at least one console target" as the only gate — that is unmeasurable and lets the other target rot.
- **Full animation features (each is a known footgun if guessed — spec the behavior, do not just label it):**
  - **Bone hierarchy** with explicit **transform-inheritance flags** (`inheritTranslation`/`inheritRotation`/`inheritScale`/`inheritReflection`) — world transforms are wrong for many real armatures if these are ignored.
  - **World-transform propagation invariant:** a single top-down pass in bone-hierarchy order, run **after** all local timelines are sampled and **before** slots/meshes read world matrices. State this ordering explicitly so an agent does not interleave per-bone sampling and propagation (parent-lag artifacts).
  - **IK constraints** (`ik` arrays, `bendPositive`/`weight`) and the **IK animation timeline** — commonly present in real assets; omitting them silently mis-poses.
  - **Slots/skins/skin-swapping**, plus the **slot color/alpha timeline** (`colorTimeline`) and the **`displayIndex` timeline** — not just draw-order.
  - **Draw-order / `zOrder` timeline** changes.
  - **Timeline interpolation:** linear **and** bezier/tween curves. Pin the curve encoding for the target version (scalar `tweenEasing` ease vs sampled `curve: [...]` control points) and the **`tweenEasing` sentinels** (`null`/`NaN` = stepped/no-tween, `0` = linear, `(0,1]`/`[-1,0)` = quad ease in/out). Define loop/edge behavior at the last keyframe for looping vs non-looping (`playTimes`/`duration` interaction).
  - **Mesh display vs FFD vs skinned mesh:** distinguish *rigid* FFD vertex deformation from **bone-weighted skinned meshes** (`weights` + bone-bound vertices) — they need a different vertex-skinning path reading bone world matrices. This is a real correctness fork, not one bullet.
  - **`boundingBox` display type** (rectangle/ellipse/polygon) for hit-testing — plausibly load-bearing for clckr (an idle *clicker*).
  - **Nested/child armatures** (`armatureDisplay`) with recursive world-transform + time-scale propagation, and the **default actions / `actions` / `defaultActions`** that auto-play animations on self and child armatures.
  - **Events:** frame events, sound events, and **actions** with fire-once-per-crossing and loop-boundary semantics.
  - **Animation state machine — crossfade is not a stretch.** Fade-in/out crossfade between animations is required (consumers need clean transitions); additive vs override **layered** animations and per-bone blend accumulation may be staged but the fade-weight math must be specified, not improvised.
- **Asset / atlas pipeline:** parse DragonBones texture-atlas JSON, mapping named subtextures with the full **`rotated` (90° CW) + `frameX/frameY/frameWidth/frameHeight` trim offsets + atlas `scale`** UV/quad math (a classic silent-misrender bug if done loosely). The convenience loader takes (skeleton JSON, atlas JSON, **opaque texture handle**) — never raw image bytes (see image-ownership rule). Enforce a **clear immutable-vs-instance type contract** decided in the frozen-types task: which fields live on shared `ArmatureData`/`*Data` (pooled across instances) vs the per-instance `Armature`/`Bone`/`Slot` runtime/pose state. Baking mutable runtime fields into "immutable" parsed structs breaks instance pooling and the allocation goal.
- **Performance + tests:**
  - Low per-frame allocation — reuse vertex/transform buffers, avoid per-frame `seq` churn; an allocation-audit task tied to the console build.
  - **Golden-file parsing tests** against checked-in real DragonBones exports (version pinned above).
  - **Deterministic animation-sampling tests** require a stated **oracle**: a Node/**DragonBonesJS** harness that emits reference bone/slot transforms at fixed times for a checked-in sample, produced **before** any sampling test and depended on by all of them. Specify a **float tolerance/epsilon** (host-vs-ARM float divergence is real) and the **frames↔seconds** conversion (DragonBones keyframes are in frames at the armature `frameRate`). "Assert known transforms" with no oracle and no tolerance is not a measurable criterion.
  - **Concrete acceptance criteria** on the sampling bead: NaN guards, empty/zero-frame timelines, missing subtextures, version skew — not a vague cross-cutting checklist line.
  - Example apps rendering the same animation through **both** the naylib adapter (desktop + console-degraded mesh) and the boxy adapter (desktop-only).

### Architecture Decisions & Risk Spikes (resolve at the very front, before parallel fan-out)
1. **jsony console spike** — confirm `jsony` compiles for 3DS (`-d:ds3`) and Vita; if not, switch the parsing phase to a hand-rolled tokenizer (reshapes parsing scope). Blocks all parser tasks.
2. **Freeze model + math types** — one serialized bead defining every `*Data`/runtime struct (using `vmath`/`bumpy`) and the immutable-vs-instance contract. Hard dependency of every parser, animation, and adapter task. Prevents concurrent edits to shared `src/dragonbones/model/**`.
3. **Render-agnostic boundary contract** — nail down opaque-texture-handle ownership and the mesh-on-console degradation policy before adapters start.
4. **Oracle harness** — DragonBonesJS reference-transform generator, before any animation-sampling test.

### Load-bearing dependency order (the task graph MUST encode this as `bd dep` edges, not just priorities)
`math (vmath/bumpy) + jsony-spike` → **freeze model/instance types** → parsers (armature/bone, slot/skin/color, display/mesh, timelines, atlas) → **transform resolution + timeline sampling + world-transform propagation (ONE serialized bead — tightly coupled, shares `anim/**`, do not shard across parallel agents)** → {FFD/skinned-mesh deform, draw-order/zOrder, IK, events/actions, crossfade/blend} → adapters (naylib shipped, boxy desktop-only) → example apps → console-purity CI gate. Animation sampling+propagation stays a single reservation; splitting it by the 750-line rule guarantees `anim/**` collisions and inconsistent sampling/propagation-order assumptions.

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

> **Note:** the skeleton below is Nim-shaped on purpose. Do NOT emit web-framework beads/labels (`ui`, `auth`, Vite/React/Tailwind) — this is a pure-Nim render library. Anchor on nimble package + `nim.cfg`/console cfgs + core-purity test.

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
# Phase 0: Setup & front-loaded risk spikes
# ========================================

SETUP_PKG=$(bd create "Scaffold nimble package: srcDir=src, root nim.cfg (--path:src), nim_3ds.cfg, nim_vita.cfg" -p 0 --label setup --silent)

PURITY_TEST=$(bd create "Add tests/test_core_purity.nim allowlist fitness fn {vmath,bumpy,std/*,core}" \
  -d "Mirror clckr's tests/game/test_core_purity.nim. Fail-closed allowlist; jsony added only if SPIKE_JSONY clears it." \
  -p 0 --label setup --silent)
bd dep add $PURITY_TEST $SETUP_PKG

SPIKE_JSONY=$(bd create "Spike: confirm jsony cross-compiles for 3DS (-d:ds3) and Vita; else plan hand-rolled parser" \
  -d "jsony is NOT on clckr's core-purity allowlist and is unverified on ARMv6K/Vita. If it fails, parsing phase switches to a hand-rolled tokenizer (larger scope). Blocks all parser tasks." \
  -p 0 --label spike --silent)
bd dep add $SPIKE_JSONY $SETUP_PKG

# ========================================
# Phase 1: Frozen types (serialized — blocks all fan-out)
# ========================================

FREEZE_TYPES=$(bd create "Freeze model + instance types using vmath/bumpy; immutable-vs-instance contract" \
  -d "Define every *Data struct (ArmatureData/BoneData/SlotData/SkinData/DisplayData/MeshData/TimelineData) and the per-instance runtime/pose types. Decide which fields are shared/pooled vs per-instance. Hard dep of EVERY parser/anim/adapter bead. File surface: src/dragonbones/model/**." \
  -p 0 --label core --silent)
bd dep add $FREEZE_TYPES $SETUP_PKG

BOUNDARY=$(bd create "Specify render-agnostic boundary: opaque texture handles, mesh-on-console degradation policy" -p 0 --label core --silent)
bd dep add $BOUNDARY $FREEZE_TYPES

# ========================================
# Phase 2: Parsing (parallel after FREEZE_TYPES; gated by jsony spike)
# ========================================

PARSE_ARMATURE=$(bd create "Parse armature/bone incl. transform-inheritance flags + IK constraints" -p 0 --label parse --silent)
bd dep add $PARSE_ARMATURE $FREEZE_TYPES
bd dep add $PARSE_ARMATURE $SPIKE_JSONY

PARSE_SLOT=$(bd create "Parse slot/skin/displayData (image, mesh, boundingBox, armatureDisplay)" -p 0 --label parse --silent)
bd dep add $PARSE_SLOT $FREEZE_TYPES
bd dep add $PARSE_SLOT $SPIKE_JSONY

PARSE_TIMELINE=$(bd create "Parse animation timelines incl. bone/slot/ffd/zOrder/ik + tween-curve encoding" -p 0 --label parse --silent)
bd dep add $PARSE_TIMELINE $FREEZE_TYPES
bd dep add $PARSE_TIMELINE $SPIKE_JSONY

PARSE_ATLAS=$(bd create "Parse texture-atlas JSON: rotated/trim/scale subtexture->slot mapping math" -p 1 --label atlas --silent)
bd dep add $PARSE_ATLAS $FREEZE_TYPES
bd dep add $PARSE_ATLAS $SPIKE_JSONY

# ========================================
# Phase 3: Animation core (sampling + propagation = ONE serialized bead)
# ========================================

ANIM_CORE=$(bd create "Transform resolution + timeline sampling + top-down world-transform propagation" \
  -d "ONE serialized bead — tightly coupled, shares src/dragonbones/anim/**. Linear+bezier interp, tweenEasing sentinels, loop/edge behavior. Single top-down pass AFTER sampling, BEFORE slot/mesh read. Do NOT shard by the 750-line rule." \
  -p 0 --label anim --silent)
bd dep add $ANIM_CORE $PARSE_ARMATURE
bd dep add $ANIM_CORE $PARSE_TIMELINE

# Parallel after ANIM_CORE
ANIM_MESH=$(bd create "FFD vertex deform + bone-weighted skinned mesh (distinct paths)" -p 0 --label anim --silent)
bd dep add $ANIM_MESH $ANIM_CORE
bd dep add $ANIM_MESH $PARSE_SLOT

ANIM_EVENTS=$(bd create "Frame/sound events + actions (self + child armature) fire-once/loop semantics" -p 1 --label anim --silent)
bd dep add $ANIM_EVENTS $ANIM_CORE

ANIM_BLEND=$(bd create "Animation state machine: crossfade fade-in/out + layered/additive blend math" -p 1 --label anim --silent)
bd dep add $ANIM_BLEND $ANIM_CORE

# ========================================
# Phase 4: Adapters
# ========================================

ADAPT_NAYLIB=$(bd create "naylib/raylib adapter (shipped): DrawTexturePro quads; mesh = desktop rlVertex, console-degraded" -p 0 --label adapter-naylib --silent)
bd dep add $ADAPT_NAYLIB $ANIM_MESH
bd dep add $ADAPT_NAYLIB $PARSE_ATLAS
bd dep add $ADAPT_NAYLIB $BOUNDARY

ADAPT_BOXY=$(bd create "boxy adapter (optional, DESKTOP-ONLY, excluded from console + purity allowlist)" -p 2 --label adapter-boxy --silent)
bd dep add $ADAPT_BOXY $ANIM_MESH
bd dep add $ADAPT_BOXY $PARSE_ATLAS
bd dep add $ADAPT_BOXY $BOUNDARY

# ========================================
# Phase 5: Tests, oracle, examples, CI
# ========================================

ORACLE=$(bd create "DragonBonesJS Node harness: emit reference transforms at fixed times for checked-in sample" -p 0 --label testing --silent)
bd dep add $ORACLE $SETUP_PKG

TEST_SAMPLING=$(bd create "Deterministic animation-sampling tests w/ epsilon tolerance + frames<->seconds" -p 0 --label testing --silent)
bd dep add $TEST_SAMPLING $ANIM_CORE
bd dep add $TEST_SAMPLING $ORACLE

CI_PURITY=$(bd create "CI gate: core-purity test + nim check --cpu:arm --mm:arc --define:useMalloc (SDK-free)" -p 1 --label deploy --silent)
bd dep add $CI_PURITY $PURITY_TEST

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
Use `--label` to group beads by phase (Nim render-library labels — NOT web labels):
- `setup` - nimble package, nim.cfg/console cfgs, purity test
- `spike` - front-loaded risk spikes (jsony console, etc.)
- `core` - frozen types, math, render-agnostic boundary
- `parse` - DragonBones JSON parsing by structure
- `atlas` - texture-atlas pipeline
- `anim` - animation runtime (sampling, deform, events, blend)
- `adapter-naylib` / `adapter-boxy` - backend adapters
- `testing` - oracle harness, golden + sampling tests
- `docs` - format notes, integration guides
- `deploy` - CI / console-purity gate

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
# Frozen types:    src/dragonbones/model/** (FREEZE FIRST — serialized, blocks all below)
# Parsing:         src/dragonbones/parse/**, tests/parse/**
# Animation core:  src/dragonbones/anim/** (sampling+propagation = ONE reservation, don't shard)
# naylib adapter:  src/dragonbones/adapters/naylib/**, examples/naylib/**
# boxy adapter:    src/dragonbones/adapters/boxy/**, examples/boxy/**  (DESKTOP-ONLY, never built for ARM)
# Atlas pipeline:  src/dragonbones/atlas/**, tests/atlas/**
# Oracle + tests:  tools/oracle/** (Node/DragonBonesJS), tests/sampling/**, tests/golden/**
# Purity/CI:       tests/test_core_purity.nim, nim_3ds.cfg, nim_vita.cfg, scripts/build_*.sh, .github/**
```

This helps agents claim appropriate file surfaces when they start work.

---

## Context Documentation

Place any important context in `prompts/docs/` for agents to reference. This includes:
- Architecture decisions (render-agnostic core boundary; what may/may not depend on a backend)
- DragonBones format notes (armature/bone/slot/skin/timeline/ffd field map)
- naylib + boxy adapter integration guides
- Console cross-compilation notes (3DS/Vita), mirroring boxy/clckr conventions

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beads.sh && ./setup-beads.sh`
2. **Check ready work**: `bd ready` should show initial setup tasks

---

## Completeness Checklist

Ensure your task graph includes:

- [ ] Setup: nimble package, root `nim.cfg` (`--path:src`), `nim_3ds.cfg`/`nim_vita.cfg`, boney's own `tests/test_core_purity.nim` allowlist fitness fn
- [ ] **Front-loaded spikes:** jsony-console-compile spike (blocks parsers); these run before fan-out
- [ ] **Frozen types bead** (serialized): all `*Data`/instance structs on `vmath`/`bumpy`, immutable-vs-instance contract — hard dep of every parser/anim/adapter bead
- [ ] Render-agnostic boundary contract: opaque texture handles (no raw pixels in core), mesh-on-console degradation policy
- [ ] Parsing by DragonBones structure: armature/bone **+ inheritance flags + IK**, slot/skin **+ color/displayIndex timeline + boundingBox + armatureDisplay**, display/mesh **(FFD vs skinned weights)**, timelines **+ tween-curve encoding + tweenEasing sentinels**, atlas **(rotated/trim/scale math)**
- [ ] Animation core as **one serialized bead** (sampling + top-down world-transform propagation order); then parallel FFD/skinned-mesh, zOrder, events/actions, crossfade/blend
- [ ] naylib adapter (shipped, console mesh-degradation stated) + boxy adapter (**desktop-only, excluded from console + purity allowlist**) + example app per backend
- [ ] Atlas loader taking decoded texture handle (not image bytes); immutable-data vs per-instance-state separation enforced by type contract
- [ ] Error/edge cases as **concrete acceptance criteria on the sampling bead** (missing subtextures, version skew, empty/zero-frame timelines, NaN guards)
- [ ] **Oracle harness** (DragonBonesJS) before any sampling test; golden parsing tests (format version pinned); sampling tests with **epsilon tolerance + frames↔seconds**
- [ ] Performance work (buffer reuse, allocation audit) tied to the console build
- [ ] API docs / README with usage for both consumers; `prompts/docs/` format + adapter + console notes
- [ ] CI gate = **core-purity test + SDK-free `nim check --cpu:arm --mm:arc --define:useMalloc`** (primary), with full devkit/Vita link as an optional separately-gated job
- [ ] **Explicit `bd dep` edges encoding the DAG** (math/spike → freeze types → parsers → anim core → {deform/events/blend} → adapters → examples → CI), not just priorities
