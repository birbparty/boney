# Follow-up Plan: Tier-2 Inherit Flags + Skinned Mesh LBS

Two independent follow-up items from the scattered-parts fix session.
Each has its own file with detailed design.

## Items

| # | File | Area | Priority |
|---|------|------|----------|
| 1 | `01-tier2-inherit-flags.md` | `propagate.nim` — non-default inherit flag paths | P2 (rare in practice) |
| 2 | `02-skinned-mesh-lbs.md` | `model.nim` / `slot.nim` / `mesh.nim` — bind-inverse LBS | P1 (silently wrong for meshes) |

## Context

The prior session fixed two bugs:
- **Matrix product propagation** (`propagate.nim` commit `096aebf`): replaced angle
  accumulation with `parentWorldMat * localMat`, matching DragonBonesJS `concat()`.
  All 13 propagation tests pass. Mechas now assemble correctly.
- **Display pivot centering** (`atlas.nim` commit `d70ebb1`): quadVerts were in
  TL-at-origin space; DragonBones default pivot is 0.5,0.5 of the untrimmed frame.

What remains:
- The non-default inherit flag branches (`!inheritRotation`, `!inheritScale`) in
  `propagate.nim` are implemented with a simplified approximation that diverges for
  skewed/non-uniform-scale parents (the tests pass because they test simple cases).
- Skinned mesh LBS in `mesh.nim` omits the bind-pose inverse matrix, so skinned
  meshes animate incorrectly (not triggered yet — all mecha displays are images).

## Source files touched

- `src/dragonbones/model/model.nim` — `MeshData`, `VertexWeight`
- `src/dragonbones/parse/slot.nim` — `parseVertexWeights`, `bonePose` extraction
- `src/dragonbones/anim/mesh.nim` — `deformMeshVertices`
- `src/dragonbones/anim/propagate.nim` — `composeWorld` non-default branches
- `tests/anim/` — new propagation tests for non-default flags
- `tests/anim/` — new mesh skinning tests with bind-inverse
