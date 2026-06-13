#!/bin/bash
# Project: boney — pure-Nim DragonBones 2D skeletal-animation runtime
# Generated: 2026-06-12
#
# Render-agnostic core (vmath/bumpy) + naylib adapter (shipped) + boxy adapter
# (desktop-only example). Cross-compiles for 3DS/Vita; core-purity enforced by a
# fitness test. This script builds the full Beads task graph with dependency edges
# encoding the load-bearing order:
#
#   math + jsony-spike + version-pin
#       -> freeze model/instance types -> render-agnostic boundary
#       -> parsers (armature/bone, slot/skin/color, display/mesh, timelines, atlas)
#       -> anim core (sampling + world-transform propagation = ONE serialized bead)
#       -> {FFD/skinned mesh, draw-order/zOrder, IK, events/actions, crossfade/blend}
#       -> adapters (naylib shipped, boxy desktop-only)
#       -> example apps -> tests/oracle -> console-purity CI gate

set -euo pipefail

# Initialize beads if needed
if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating boney task graph..."

# ============================================================================
# Phase 0: Setup & front-loaded risk spikes (run before any fan-out)
# ============================================================================

SETUP_PKG=$(bd create "Scaffold nimble package + root nim.cfg + console cfgs" \
  -d "Create boney.nimble (srcDir=src, nim>=2.0.0, requires vmath, bumpy). Root nim.cfg with --path:\"src\" so per-file LSP resolves src/dragonbones/** imports. Add nim_3ds.cfg / nim_vita.cfg mirroring boxy/clckr (3DS ARMv6K hard-float via devkitARM; Vita ARMv7 via VitaSDK -Wl,-q). Compile flags: --mm:arc --define:useMalloc for console parity. Layout: src/dragonbones.nim entrypoint + src/dragonbones/{model,parse,atlas,anim,adapters}/. File surface: boney.nimble, nim.cfg, nim_3ds.cfg, nim_vita.cfg, src/dragonbones.nim." \
  -p 0 -l setup -t task --silent)

BUILD_SCRIPTS=$(bd create "Add scripts/build_3ds.sh + scripts/build_vita.sh (non-nimble console build)" \
  -d "nimble build resolves desktop-only deps; console targets must call nim compile / a build script directly. Mirror boxy/clckr scripts/build_*.sh conventions. 3DS: devkitARM, --cpu:arm, -d:ds3, --opt:size. Vita: VitaSDK, -Wl,-q. These wrap nim compile of the core for real link checks (optional, SDK-gated CI job). File surface: scripts/build_3ds.sh, scripts/build_vita.sh." \
  -p 1 -l setup -t task --silent)
bd dep add $BUILD_SCRIPTS $SETUP_PKG

PURITY_TEST=$(bd create "Add tests/test_core_purity.nim allowlist fitness fn" \
  -d "Mirror clckr's tests/game/test_core_purity.nim. Fail-closed import allowlist for the core: {vmath, bumpy, std/*, dragonbones core modules}. jsony added to the allowlist ONLY if SPIKE_JSONY clears it. Walk src/dragonbones/** (excluding adapters/boxy) and assert no import escapes the allowlist. This is the machine-checked no-backend-deps invariant. File surface: tests/test_core_purity.nim." \
  -p 0 -l setup -t task --silent)
bd dep add $PURITY_TEST $SETUP_PKG

SPIKE_JSONY=$(bd create "Spike: confirm jsony cross-compiles for 3DS (-d:ds3) and Vita" \
  -d "jsony is the preferred fast/low-alloc parser BUT is NOT on clckr's core-purity allowlist and is unverified on ARMv6K/Vita. Pure-Nim/no-C-deps does NOT equal console-safe — clckr enforces an allowlist, not a C-dependency check. Outcome (a): prove jsony cross-compiles for 3DS + Vita and add it to boney's purity allowlist. Outcome (b): fall back to a hand-rolled tokenizing parser (larger, unplanned scope) and reshape the parsing phase. BLOCKS all parser tasks. Record the decision in prompts/docs/. File surface: spike branch / prompts/docs/jsony-console-spike.md." \
  -p 0 -l spike -t task --silent)
bd dep add $SPIKE_JSONY $SETUP_PKG

VERSION_PIN=$(bd create "Pin DragonBones data-format version range (JSON exports only)" \
  -d "Golden files and curve/easing encodings differ across DragonBones 4.x/5.x (version/compatibleVersion, bone transform layout, frameRate/isGlobal, tween-curve encoding). Decide the supported version range so the parser targets ONE schema generation. Binary .dbbin is OUT OF SCOPE unless added explicitly. Document the pinned range + which export tool version produced the golden files. Blocks parser + golden tasks. File surface: prompts/docs/dragonbones-format-version.md." \
  -p 0 -l docs -t task --silent)
bd dep add $VERSION_PIN $SETUP_PKG

# ============================================================================
# Phase 1: Frozen types + boundary contract (serialized — blocks all fan-out)
# ============================================================================

FREEZE_TYPES=$(bd create "Freeze model + instance types (vmath/bumpy); immutable-vs-instance contract" \
  -d "Define EVERY shared *Data struct (ArmatureData, BoneData, SlotData, SkinData, DisplayData, MeshData, TimelineData, IKData, AnimationData) AND the per-instance runtime/pose types (Armature, Bone, Slot). Use vmath/bumpy types directly in public API — NO bespoke internal Vec2/Mat2d. Decide which fields are shared/pooled across instances (immutable *Data) vs per-instance mutable runtime/pose state; baking mutable fields into immutable structs breaks instance pooling and the allocation goal. Hard dependency of EVERY parser/anim/adapter bead. Serialized — do not edit src/dragonbones/model/** concurrently. File surface: src/dragonbones/model/**." \
  -p 0 -l core -t task --silent)
bd dep add $FREEZE_TYPES $SETUP_PKG
bd dep add $FREEZE_TYPES $VERSION_PIN

BOUNDARY=$(bd create "Specify render-agnostic boundary: opaque texture handles + mesh-on-console degradation" \
  -d "Core takes atlas METADATA + an OPAQUE texture handle (Texture2D for naylib; boxy Image/atlas key for boxy) — never raw PNG bytes. PNG decode/upload lives in the adapter (raylib LoadTexture from romfs:/ / app0: on console; pixie on boxy desktop). Convenience loader signature = (skeleton JSON, atlas JSON, already-decoded texture handle). Core emits backend-neutral transformed draw data: slot quads + deformed mesh vertex buffers + atlas UVs. Define the mesh-on-console degradation policy: console raylib binding exposes only DrawTexturePro, no DrawMesh/rlVertex — so console mesh slots degrade to a bounding quad unless the binding is extended. State chosen behavior per target. File surface: src/dragonbones/boundary.nim (or doc) + prompts/docs/render-agnostic-boundary.md." \
  -p 0 -l core -t task --silent)
bd dep add $BOUNDARY $FREEZE_TYPES

# ============================================================================
# Phase 2: Parsing (parallel after FREEZE_TYPES; all gated by jsony spike)
# ============================================================================

PARSE_ARMATURE=$(bd create "Parse armature/bone incl. transform-inheritance flags + IK constraints" \
  -d "Parse armature + bone hierarchy. CRITICAL: capture transform-inheritance flags inheritTranslation/inheritRotation/inheritScale/inheritReflection — world transforms are wrong for many armatures if ignored. Parse ik arrays (bendPositive, weight, chain, target). Honor frameRate/isGlobal per the pinned version. File surface: src/dragonbones/parse/armature.nim, tests/parse/test_armature.nim." \
  -p 0 -l parse -t task --silent)
bd dep add $PARSE_ARMATURE $FREEZE_TYPES
bd dep add $PARSE_ARMATURE $SPIKE_JSONY

PARSE_SLOT=$(bd create "Parse slot/skin/displayData (image, mesh, boundingBox, armatureDisplay)" \
  -d "Parse slots + skins + skin-swapping. displayData variants: image, mesh (vertices/uvs/triangles), boundingBox (rectangle/ellipse/polygon for hit-testing — load-bearing for clckr), armatureDisplay (nested/child armature ref). Distinguish rigid mesh vs skinned mesh (weights + bone-bound vertices) at parse time so the deform path can branch later. File surface: src/dragonbones/parse/slot.nim, tests/parse/test_slot.nim." \
  -p 0 -l parse -t task --silent)
bd dep add $PARSE_SLOT $FREEZE_TYPES
bd dep add $PARSE_SLOT $SPIKE_JSONY

PARSE_TIMELINE=$(bd create "Parse animation timelines (bone/slot/color/displayIndex/ffd/zOrder/ik) + tween-curve encoding" \
  -d "Parse all timeline types: bone (translate/rotate/scale), slot colorTimeline + displayIndex timeline, ffd/mesh-deform, zOrder/draw-order, ik. Pin curve encoding for the target version: scalar tweenEasing ease vs sampled curve:[...] control points. Capture tweenEasing sentinels: null/NaN=stepped/no-tween, 0=linear, (0,1]/[-1,0)=quad ease in/out. Keep keyframe values in FRAMES (convert to seconds at sampling time via armature frameRate). Record playTimes/duration. File surface: src/dragonbones/parse/timeline.nim, tests/parse/test_timeline.nim." \
  -p 0 -l parse -t task --silent)
bd dep add $PARSE_TIMELINE $FREEZE_TYPES
bd dep add $PARSE_TIMELINE $SPIKE_JSONY

PARSE_ATLAS=$(bd create "Parse texture-atlas JSON: rotated/trim/scale subtexture->slot UV math" \
  -d "Map named subtextures with FULL atlas math: rotated (90 deg CW) flag, frameX/frameY/frameWidth/frameHeight trim offsets, atlas scale. Getting this loose is a classic silent-misrender bug. Emit UV rects + quad geometry (accounting for trim) per subtexture. No pixel decode here — metadata only. File surface: src/dragonbones/atlas/**, tests/atlas/test_atlas.nim." \
  -p 1 -l atlas -t task --silent)
bd dep add $PARSE_ATLAS $FREEZE_TYPES
bd dep add $PARSE_ATLAS $SPIKE_JSONY

# ============================================================================
# Phase 3: Animation core (sampling + propagation = ONE serialized bead)
# ============================================================================

ANIM_CORE=$(bd create "Transform resolution + timeline sampling + top-down world-transform propagation" \
  -d "ONE serialized bead — tightly coupled, shares src/dragonbones/anim/**. DO NOT shard by the 750-line rule (guarantees anim/** collisions + inconsistent sampling/propagation-order assumptions). Sample all local bone/slot timelines (linear + bezier/tween per tweenEasing sentinels), apply transform-inheritance flags, then run a SINGLE top-down pass in bone-hierarchy order AFTER all sampling and BEFORE any slot/mesh reads world matrices (prevents parent-lag artifacts). Handle frames<->seconds at frameRate. Define loop/edge behavior at the last keyframe for looping vs non-looping (playTimes/duration interaction). File surface: src/dragonbones/anim/{sample,transform,propagate}.nim." \
  -p 0 -l anim -t task --silent)
bd dep add $ANIM_CORE $PARSE_ARMATURE
bd dep add $ANIM_CORE $PARSE_TIMELINE

# ---- Parallel after ANIM_CORE (each its own file surface) ----

ANIM_MESH=$(bd create "FFD vertex deform + bone-weighted skinned mesh (distinct paths)" \
  -d "Real correctness fork, not one bullet. Rigid FFD: apply per-frame vertex offsets to base mesh verts. Skinned mesh: weighted blend of vertex positions across bound bones' WORLD matrices (weights + bone indices). Reuse vertex buffers — no per-frame seq churn. Emits deformed mesh vertex buffers + UVs for the adapter. File surface: src/dragonbones/anim/mesh.nim, tests/anim/test_mesh.nim." \
  -p 0 -l anim -t task --silent)
bd dep add $ANIM_MESH $ANIM_CORE
bd dep add $ANIM_MESH $PARSE_SLOT

ANIM_DRAWORDER=$(bd create "Draw-order / zOrder timeline + slot color/alpha + displayIndex timeline" \
  -d "Apply zOrder timeline changes to slot draw order; apply colorTimeline (color/alpha) and displayIndex timeline (display swap) to per-instance slot state. Not just static draw order — these are timelined. File surface: src/dragonbones/anim/draworder.nim, tests/anim/test_draworder.nim." \
  -p 1 -l anim -t task --silent)
bd dep add $ANIM_DRAWORDER $ANIM_CORE
bd dep add $ANIM_DRAWORDER $PARSE_SLOT

ANIM_IK=$(bd create "IK constraint solver + IK animation timeline" \
  -d "Solve ik constraints (bendPositive, weight, single + 2-bone chains) during the world-transform pass; apply the ik animation timeline (animated weight/bendPositive). Commonly present in real assets; omitting silently mis-poses. Integrates with ANIM_CORE's propagation ordering. File surface: src/dragonbones/anim/ik.nim, tests/anim/test_ik.nim." \
  -p 1 -l anim -t task --silent)
bd dep add $ANIM_IK $ANIM_CORE

ANIM_EVENTS=$(bd create "Frame/sound events + actions (self + child armature) fire-once/loop semantics" \
  -d "Frame events, sound events, and actions/defaultActions. Fire-once-per-crossing semantics + correct loop-boundary behavior (no double-fire / no-skip at wrap). defaultActions auto-play animations on self AND child armatures. Nested/child armatures (armatureDisplay) need recursive world-transform + time-scale propagation. File surface: src/dragonbones/anim/events.nim, tests/anim/test_events.nim." \
  -p 1 -l anim -t task --silent)
bd dep add $ANIM_EVENTS $ANIM_CORE
bd dep add $ANIM_EVENTS $PARSE_SLOT

ANIM_BLEND=$(bd create "Animation state machine: crossfade fade-in/out + layered/additive blend math" \
  -d "Crossfade fade-in/out between animations is REQUIRED (consumers need clean transitions) — not a stretch. Specify the fade-weight math explicitly (do not improvise). additive vs override layered animations + per-bone blend accumulation may be STAGED but the fade math must be specified. File surface: src/dragonbones/anim/blend.nim, tests/anim/test_blend.nim." \
  -p 1 -l anim -t task --silent)
bd dep add $ANIM_BLEND $ANIM_CORE

ANIM_HITTEST=$(bd create "boundingBox hit-testing API (rectangle/ellipse/polygon) in world space" \
  -d "Expose hit-test against boundingBox displays transformed to world space — plausibly load-bearing for clckr (an idle clicker). Point-in-rect/ellipse/polygon after world transform. File surface: src/dragonbones/anim/hittest.nim, tests/anim/test_hittest.nim." \
  -p 2 -l anim -t task --silent)
bd dep add $ANIM_HITTEST $ANIM_CORE
bd dep add $ANIM_HITTEST $PARSE_SLOT

# ============================================================================
# Phase 4: Adapters
# ============================================================================

ADAPT_NAYLIB=$(bd create "naylib/raylib adapter (shipped): DrawTexturePro quads; mesh = desktop rlVertex, console-degraded" \
  -d "Shipped out of the box. Plain image slots -> DrawTexturePro (the only draw primitive clckr's console raylib binding exposes). Deformed meshes: desktop uses rlBegin/rlVertex or DrawMesh; CONSOLE degrades mesh slots to a bounding quad because raylib_console.nim binds no DrawMesh/rlVertex (see CONSOLE_MESH for the optional binding extension). State chosen behavior explicitly per target. Consumes core's transformed draw data + opaque Texture2D handle. File surface: src/dragonbones/adapters/naylib/**." \
  -p 0 -l adapter-naylib -t task --silent)
bd dep add $ADAPT_NAYLIB $ANIM_MESH
bd dep add $ADAPT_NAYLIB $ANIM_DRAWORDER
bd dep add $ADAPT_NAYLIB $PARSE_ATLAS
bd dep add $ADAPT_NAYLIB $BOUNDARY

CONSOLE_MESH=$(bd create "(Optional) Extend clckr console raylib binding with immediate-mode/mesh primitive" \
  -d "Real, non-trivial work touching clckr binding conventions. Add a DrawMesh/rlVertex-style immediate-mode primitive to raylib_console.nim so the naylib adapter can render deformed meshes on console instead of degrading to a bounding quad. Coordinate with clckr binding owners. Optional — naylib adapter ships with bounding-quad degradation if this is not done. File surface: clckr raylib_console binding (external repo) + naylib adapter mesh path." \
  -p 3 -l adapter-naylib -t task --silent)
bd dep add $CONSOLE_MESH $ADAPT_NAYLIB

ADAPT_BOXY=$(bd create "boxy adapter (optional, DESKTOP-ONLY, excluded from console + purity allowlist)" \
  -d "Optional/example. boxy imports pixie in BOTH desktop and ds3 branches (src/boxy.nim) — never pixie-free, must NEVER compile for 3DS/Vita and is excluded from the core-purity allowlist. boxy's public draw API is quad/atlas-key based (drawImage/drawUvRect/drawRect) with NO public arbitrary-triangle mesh draw — so deformed mesh slots render as bounding quads (or skip FFD). Do NOT promise full mesh fidelity through boxy. Takes boxy Image/atlas key as the opaque handle. File surface: src/dragonbones/adapters/boxy/**." \
  -p 2 -l adapter-boxy -t task --silent)
bd dep add $ADAPT_BOXY $ANIM_MESH
bd dep add $ADAPT_BOXY $ANIM_DRAWORDER
bd dep add $ADAPT_BOXY $PARSE_ATLAS
bd dep add $ADAPT_BOXY $BOUNDARY

# ============================================================================
# Phase 5: Oracle, tests, examples, performance, docs, CI
# ============================================================================

ORACLE=$(bd create "DragonBonesJS Node harness: emit reference transforms at fixed times for checked-in sample" \
  -d "Built BEFORE any sampling test and depended on by all of them. Node + DragonBonesJS harness that loads a checked-in sample asset and emits reference bone/slot world transforms at fixed times (frames). Output is the oracle for deterministic sampling tests. Specify frames<->seconds conversion at the sample's frameRate. File surface: tools/oracle/** (Node/DragonBonesJS), tests/fixtures/sample/**." \
  -p 0 -l testing -t task --silent)
bd dep add $ORACLE $SETUP_PKG
bd dep add $ORACLE $VERSION_PIN

GOLDEN_TESTS=$(bd create "Golden-file parsing tests against checked-in real DragonBones exports" \
  -d "Check in real DragonBones JSON exports (version pinned by VERSION_PIN) + assert parsed model structure matches expected golden snapshots. Covers armature/bone/slot/skin/timeline/atlas parse correctness. File surface: tests/golden/**, tests/fixtures/**." \
  -p 1 -l testing -t task --silent)
bd dep add $GOLDEN_TESTS $PARSE_ARMATURE
bd dep add $GOLDEN_TESTS $PARSE_SLOT
bd dep add $GOLDEN_TESTS $PARSE_TIMELINE
bd dep add $GOLDEN_TESTS $PARSE_ATLAS

TEST_SAMPLING=$(bd create "Deterministic animation-sampling tests w/ epsilon tolerance + frames<->seconds" \
  -d "Compare boney's sampled bone/slot transforms against the ORACLE reference at fixed times. State a float tolerance/epsilon (host-vs-ARM float divergence is real). Verify frames<->seconds conversion at frameRate. ACCEPTANCE CRITERIA (concrete): NaN guards on degenerate transforms; empty/zero-frame timelines produce identity/last-pose not crash; missing subtextures handled; version-skew assets rejected or warned. Not a vague checklist line. File surface: tests/sampling/**." \
  -p 0 -l testing -t task --silent)
bd dep add $TEST_SAMPLING $ANIM_CORE
bd dep add $TEST_SAMPLING $ORACLE

PERF_AUDIT=$(bd create "Allocation audit: per-frame buffer reuse, no seq churn, tied to console build" \
  -d "Audit per-frame allocations in sampling + mesh deform + propagation. Reuse vertex/transform buffers; avoid per-frame seq allocation. Verify under --mm:arc --define:useMalloc. Tie the measurement to the console build profile (--opt:size). Document the allocation budget. File surface: tests/perf/**, src/dragonbones/anim/** (buffer reuse touch-ups)." \
  -p 1 -l testing -t task --silent)
bd dep add $PERF_AUDIT $ANIM_CORE
bd dep add $PERF_AUDIT $ANIM_MESH

EXAMPLE_NAYLIB=$(bd create "Example app: render sample animation via naylib adapter (desktop + console-degraded mesh)" \
  -d "Standalone example loading the checked-in sample and playing an animation through the naylib adapter. Show desktop mesh fidelity + console bounding-quad degradation path. Doubles as a smoke test. File surface: examples/naylib/**." \
  -p 2 -l adapter-naylib -t task --silent)
bd dep add $EXAMPLE_NAYLIB $ADAPT_NAYLIB

EXAMPLE_BOXY=$(bd create "Example app: render sample animation via boxy adapter (desktop-only)" \
  -d "Standalone DESKTOP-ONLY example playing the sample through the boxy adapter (bounding-quad meshes). Never built for ARM. File surface: examples/boxy/**." \
  -p 3 -l adapter-boxy -t task --silent)
bd dep add $EXAMPLE_BOXY $ADAPT_BOXY

DOCS_API=$(bd create "README + API docs: usage for boxy and clckr consumers; format/adapter/console notes" \
  -d "README with quickstart for both consumers (load skeleton+atlas+texture handle, create armature instance, step animation, draw via adapter). Populate prompts/docs/: render-agnostic boundary, DragonBones format field map (armature/bone/slot/skin/timeline/ffd), naylib + boxy adapter integration guides, 3DS/Vita cross-compile notes mirroring boxy/clckr. File surface: README.md, prompts/docs/**." \
  -p 2 -l docs -t task --silent)
bd dep add $DOCS_API $ADAPT_NAYLIB
bd dep add $DOCS_API $BOUNDARY

CI_PURITY=$(bd create "CI gate: core-purity test + SDK-free nim check --cpu:arm --mm:arc --define:useMalloc --opt:size" \
  -d "PRIMARY invariant gate (no SDK needed): run tests/test_core_purity.nim + nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --opt:size over the core. This catches backend-dep leaks + ARM compile breaks without devkitARM/VitaSDK. Add full devkit/Vita link as an OPTIONAL, separately-gated job (so neither target rots). Do not make 'build for at least one console target' the only gate. File surface: .github/workflows/**." \
  -p 1 -l deploy -t task --silent)
bd dep add $CI_PURITY $PURITY_TEST
bd dep add $CI_PURITY $BUILD_SCRIPTS

CI_TESTS=$(bd create "CI: run unit/golden/sampling/perf test suites on desktop" \
  -d "Desktop CI job running nimble test: parse unit tests, golden parsing tests, deterministic sampling tests (with oracle artifact), allocation/perf checks. Gates merges. File surface: .github/workflows/**." \
  -p 1 -l deploy -t task --silent)
bd dep add $CI_TESTS $GOLDEN_TESTS
bd dep add $CI_TESTS $TEST_SAMPLING

echo ""
echo "Bead graph created. Inspect with:"
echo "  bd ready     # unblocked tasks (should show setup + spikes)"
echo "  bd dep tree  # full dependency DAG"
echo "  bd graph     # dependency graph"
