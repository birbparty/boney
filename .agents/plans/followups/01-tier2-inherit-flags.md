# Plan: Tier-2 Inherit Flags (propagate.nim)

File: `src/dragonbones/anim/propagate.nim`

## Current state

`composeWorld` has two paths:

```nim
if boneData.inheritRotation and boneData.inheritScale:
    result = parentWorldMat * localMat          # ← correct matrix product (Tier 1)
    if not boneData.inheritTranslation:
        result[2, 0] = local.x; result[2, 1] = local.y
else:
    var modT = local
    if boneData.inheritRotation:                # inheritRotation=T, inheritScale=F
        modT.skX = parentWorld.skX + local.skX  # ← BUG: should use parentWorld.skY
        modT.skY = parentWorld.skY + local.skY
    elif boneData.inheritScale:                 # inheritRotation=F, inheritScale=T
        modT.scX = parentWorld.scX * local.scX  # ← BUG: scale multiply in DbTransform space
        modT.scY = parentWorld.scY * local.scY  #         diverges under non-uniform parent
    result = dbTransformToMat3(modT)
    if boneData.inheritTranslation:
        result[2, 0] = parentWorldMat[0,0]*local.x + parentWorldMat[1,0]*local.y + parentWorldMat[2,0]
        result[2, 1] = parentWorldMat[0,1]*local.x + parentWorldMat[1,1]*local.y + parentWorldMat[2,1]
    else:
        result[2, 0] = local.x; result[2, 1] = local.y
```

## Reference: DragonBonesJS Bone.ts `_updateGlobalTransformMatrix`

DragonBones treats `inheritScale` and `inheritRotation` flags by splitting into
four sub-cases, all using `global.toMatrix(m); m.concat(parentMatrix)` (matrix
product) where possible:

### Case A — inheritScale=true, inheritRotation=false (lines 200–237)

```ts
// Adjust local rotation to CANCEL the parent rotation that will be added
// by the matrix product, so the net world rotation = local rotation.
rotation = global.rotation - parent.global.rotation;
// (with sign flips for flipX/flipY, rare)
global.rotation = rotation;

global.toMatrix(globalTransformMatrix);
globalTransformMatrix.concat(parentMatrix);   // ← matrix product

if (boneData.inheritTranslation) {
    global.x = globalTransformMatrix.tx;
    global.y = globalTransformMatrix.ty;
} else {
    globalTransformMatrix.tx = global.x;
    globalTransformMatrix.ty = global.y;
}
```

In boney terms (`rotation` = `skY`, `skew` = `skX − skY`):
- Pre-subtract parent's rotation from local: `adjSkY = local.skY - parentWorld.skY`
- `skew` (= `skX − skY`) stays fixed, so `adjSkX = local.skX - parentWorld.skY`
- Build `adjLocalMat = dbTransformToMat3(DbTransform{..., skX: adjSkX, skY: adjSkY, scX: local.scX, scY: local.scY})`
- `result = parentWorldMat * adjLocalMat`
- Translation: from matrix result if `inheritTranslation`, else override with `local.x/y`

Net effect: `worldScale = parentScale * localScale`, `worldRotation = localRotation`.
This is correct because the parent's rotation added by `concat` cancels the pre-subtraction.

### Case B — inheritScale=false, inheritRotation=true (lines 239–299)

```ts
// Translation goes through parent matrix (if inheritTranslation)
global.x = parentMatrix.a * x + parentMatrix.c * y + parentMatrix.tx;
global.y = parentMatrix.b * x + parentMatrix.d * y + parentMatrix.ty;

// Rotation: add parent world rotation
rotation = global.rotation + parent.global.rotation;
// (negative determinant and reflection flags: rare edge cases)
global.rotation = rotation;

global.toMatrix(globalTransformMatrix);   // NO matrix product
```

In boney terms:
- Translation: `result_tx = parentWorldMat * vec3(local.x, local.y, 1)` (if inheritTranslation)
- `worldSkY = local.skY + parentWorld.skY`
- `skew` (= `skX − skY`) stays fixed:
  `worldSkX = worldSkY + (local.skX − local.skY) = parentWorld.skY + local.skX`
- `worldScX = local.scX`, `worldScY = local.scY` (no scale inheritance)
- Build result directly from (`worldSkX`, `worldSkY`, `worldScX`, `worldScY`, translated position)

Current code uses `modT.skX = parentWorld.skX + local.skX` — wrong for skewed parents
where `parentWorld.skX ≠ parentWorld.skY`. Should be `parentWorld.skY + local.skX`.

### Case C — inheritScale=false, inheritRotation=false

No rotation or scale inheritance. Translation goes through parent if `inheritTranslation`.
Current code (`modT = local`, translate through parent) is approximately correct for
no-flip case. `inheritReflection` (rare, cosmetic) is not handled.

## Proposed changes to `composeWorld`

```nim
proc composeWorld(localMat, parentWorldMat: Mat3,
                  boneData: BoneData, local: DbTransform,
                  parentWorld: DbTransform): Mat3 =
  if boneData.inheritRotation and boneData.inheritScale:
    # Case default: full matrix product (Tier 1 — unchanged)
    result = parentWorldMat * localMat
    if not boneData.inheritTranslation:
      result[2, 0] = local.x; result[2, 1] = local.y

  elif boneData.inheritScale:
    # Case A: inherit scale but NOT rotation.
    # Pre-cancel parent rotation so matrix product gives worldRotation = localRotation.
    # skew (skX - skY) is preserved; only skY/skX shift by -parentWorld.skY.
    var adj = local
    adj.skY -= parentWorld.skY
    adj.skX -= parentWorld.skY   # keeps skew = skX - skY constant
    let adjMat = dbTransformToMat3(adj)
    result = parentWorldMat * adjMat
    if not boneData.inheritTranslation:
      result[2, 0] = local.x; result[2, 1] = local.y

  elif boneData.inheritRotation:
    # Case B: inherit rotation but NOT scale.
    # worldRotation = localRotation + parentRotation (rotation = skY)
    # worldSkew (skX-skY) = localSkew → worldSkX = parentWorld.skY + local.skX
    var modT = local
    modT.skY = parentWorld.skY + local.skY
    modT.skX = parentWorld.skY + local.skX   # FIX: was parentWorld.skX + local.skX
    # scX/scY stay local
    result = dbTransformToMat3(modT)
    if boneData.inheritTranslation:
      result[2, 0] = parentWorldMat[0,0]*local.x + parentWorldMat[1,0]*local.y + parentWorldMat[2,0]
      result[2, 1] = parentWorldMat[0,1]*local.x + parentWorldMat[1,1]*local.y + parentWorldMat[2,1]
    else:
      result[2, 0] = local.x; result[2, 1] = local.y

  else:
    # Case C: no rotation, no scale inheritance.
    # Use local rotation + scale; translation may go through parent matrix.
    result = localMat
    if boneData.inheritTranslation:
      result[2, 0] = parentWorldMat[0,0]*local.x + parentWorldMat[1,0]*local.y + parentWorldMat[2,0]
      result[2, 1] = parentWorldMat[0,1]*local.x + parentWorldMat[1,1]*local.y + parentWorldMat[2,1]
    else:
      result[2, 0] = local.x; result[2, 1] = local.y
    # Note: inheritReflection not implemented (rare, cosmetic). File a bead if needed.
```

Note: The ordering of `elif` branches is inverted from current code because
DragonBones checks `inheritScale` first in the non-default path.

## New tests to write

File: `tests/anim/test_propagate_inherit.nim` (new file, separate from existing propagation tests)

IMPORTANT: Must also add `exec "nim r tests/anim/test_propagate_inherit.nim"` to `boney.nimble`'s
test task — new test files are not discovered automatically; they must be registered explicitly.

Test cases:

1. **Case A, uniform parent** (`inheritScale=T, inheritRotation=F`): parent scX=2, scY=2 (uniform),
   skY=30deg, skX=30deg; child localSkY=0, localScX=1, localScY=1.
   Assert: world scale ≈ 2 (inherited), world rotation ≈ 0° (not parent's 30°).
   NOTE: Use a **uniform-scale parent**. Under non-uniform scale (scX≠scY), the matrix product
   does NOT cleanly decouple rotation from scale — this is an inherent DragonBones limitation,
   not a boney bug. The code faithfully mirrors Bone.ts; the test must assert the matrix product
   result, not the idealized decoupled outcome.

2. **Case B** (`inheritScale=F, inheritRotation=T`): parent skY=30deg, skX=45deg (skewed),
   scX=2, scY=1; child localSkY=10deg, localSkX=15deg, scX=0.5, scY=0.5.
   Assert: worldSkY = 40° (10+30), worldSkX = 45° (parentWorld.skY + local.skX = 30+15),
   worldScX = local.scX = 0.5 (scale NOT inherited).
   NOTE: `worldSkX = parentWorld.skY + local.skX`, NOT `parentWorld.skX + local.skX`.
   This is the key fix; a skewed parent (skX≠skY) is required to exercise it.

3. **Case C** (`inheritScale=F, inheritRotation=F`): parent at world (100, 50), some rotation/scale.
   Child at local (10, 0). Assert: worldScX = local.scX, worldSkY = local.skY,
   world translation = parentWorldMat * vec3(10, 0, 1).xy (when inheritTranslation=true).

4. **!inheritTranslation**: any case, child with inheritTranslation=false, local.x=50.
   Assert: worldMat[2,0] = 50 (world origin at child's local position, not parent-transformed).

## Out of scope / deferred

- `inheritReflection`: cosmetic flag that flips the child when parent has negative determinant.
  File a separate bead.
- **Case B under negative-determinant parent** (parent scaleX < 0 or mirrored armature):
  Bone.ts:262-271 applies an extra `rotation -= 2*rotation` and `skew += π` in this case.
  This is NOT the `inheritReflection` flag — it triggers whenever the parent has a negative
  2D determinant (e.g., scaleX < 0). This affects Case B (inheritRotation=T, inheritScale=F)
  and is more common than pure `inheritReflection`. Deferred — file a bead explicitly for
  "Case B negative-determinant parent" rather than lumping it with inheritReflection.
- `flipX`/`flipY` sign adjustments in Case A: Armature-level flip, not currently supported.
  Deferred.
- `Surface` parent bones: boney has no `Surface` type; these fall through to plain `BoneData`.
  Assets with Surface parents will assemble with silently wrong geometry. File a bead to
  detect `type: "surface"` at parse time and warn.
