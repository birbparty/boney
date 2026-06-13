# boney oracle

Headless DragonBones world-transform oracle for deterministic sampling tests.

## Purpose

Computes bone world transforms at fixed animation frames using a minimal,
spec-faithful JS implementation of the DragonBones 5.5–5.7 transform math.
The output (`expected.json`) is the golden reference for `boney-dnc` tests.

## Usage

```sh
# Re-generate expected.json (only needed when the sample or oracle changes):
node emit.js > expected.json

# Custom sample/animation:
node emit.js \
  --asset ../../tests/fixtures/sample/dragon_ske.json \
  --armature Dragon \
  --animation idle \
  --frames 0,6,12,18,24
```

## Sample asset

`tests/fixtures/sample/dragon_ske.json` — DragonBones 5.7.0 file with:
- Armature "Dragon", frameRate 24
- Bone "root" at origin
- Bone "arm" (child of root) at (50, 0) in parent space
- Animation "idle" (24 frames): root rotates 0→90° linear over 24 frames

## Transform convention

Output `x/y/rotation/scaleX/scaleY` are the decomposed world transform:
- `x`, `y` — world position (tx, ty of world matrix)
- `rotation` — world rotation in degrees (atan2(b, a) * 180/π)
- `scaleX` — world scale along X (√(a²+b²))
- `scaleY` — world scale along Y (√(c²+d²))
- `matrix` — raw 2-D affine: [a, b, c, d, tx, ty]

Epsilon tolerance for Nim float32 tests: 0.001 (< 1/10th pixel for typical
320×240 3DS screen).

## Known limitations

- Only implements linear tweens (tweenEasing: 0). Step and bezier curve
  tweens will be added alongside boney-56w animation parsing.
- No mesh/IK/slot transforms — bones only.
- No partial inheritance (assumes all inherit flags true).
