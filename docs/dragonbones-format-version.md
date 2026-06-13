# DragonBones Data Format — Pinned Version Range

## Decision

**boney targets DragonBones JSON format version 5.7.x (`"version": "5.7.0"`),
with read-compatible support for 5.5.0 through 5.7.x.**

Binary `.dbbin` format is **out of scope** for this library. JSON only.

---

## Version Landscape

DragonBones has gone through two major format generations and several minor
revisions. boney pins to the 5.x generation.

### 4.x (not supported)

- `version` field absent or `"4.x.x"`
- Bone transforms stored differently (no `inheritTranslation`/`inheritRotation`
  flags — all inheritance was implicit)
- No `compatibleVersion` field
- `frameRate` is per-animation, not per-armature
- Simpler tween encoding (no sampled curves)
- No formal IK constraint schema
- No mesh/FFD weight data

boney does **not** support 4.x. The format delta is too large to serve with a
single code path cleanly, and all major consumers (clckr, boxy targets) export
from recent DragonBones Editor / DragonBones Pro.

### 5.0 – 5.4.x

- `version` field present: `"5.0.0"`, `"5.1.0"`, etc.
- `compatibleVersion` added (reader minimum)
- `frameRate` moved to armature level
- Bone transform inheritance flags introduced (`inheritTranslation`,
  `inheritRotation`, `inheritScale`, `inheritReflection`)
- Mesh display + FFD weight data added (but vertex format still evolving)
- IK constraint schema stabilized at 5.0
- boney **may** handle these with minor version-guard branches, but they are
  not the primary target and golden files are not required for them

### 5.5.x – 5.7.x (TARGET)

- Stable, widely exported by DragonBones Editor 5.5 + 5.6 + 5.7
- `version`: `"5.5.0"`, `"5.6.0"`, `"5.7.0"`
- `compatibleVersion`: typically `"5.0.0"` (all 5.x readers can open)
- Vertex/UV layout for mesh slots stabilized
- Tween-curve encoding stabilized (see below)
- `zOrder` timeline added at 5.5
- `defaultActions` for child armature auto-play added at 5.5
- This is the format version produced by DragonBones Editor bundled with current
  Unity/Cocos2d-x SDKs and available as a standalone tool

### 5.8.x – 5.9.x (not tested)

- May work with the 5.7 parser if the `compatibleVersion` is `"5.0.0"`
- Not a primary target; not covered by golden files

---

## Tween-Curve Encoding (version-sensitive)

This is the primary portability hazard across 5.x versions. ALL of these forms
exist in the wild and must be handled:

| `tweenEasing` value | Meaning |
|---|---|
| `null` (absent) | Stepped/no-tween (hold previous value) |
| `NaN` / literal `null` JSON | Same as absent — stepped |
| `0` | Linear interpolation |
| Finite non-zero float | Quad ease: positive = ease-in, negative = ease-out |
| `curve: [p1x,p1y,p2x,p2y]` | Bezier (4 control points, NOT `tweenEasing`) |

Sampled curve form (5.5+): `curve: [v0, v1, v2, ...]` (more than 4 values) is a
pre-sampled sequence. Readers must distinguish sampled (> 4 values) from bezier
(exactly 4 values) by array length.

Keyframe time is stored in **frames** (integer), not seconds. Convert to seconds
at sampling time: `timeSeconds = frame / armature.frameRate`.

---

## Version Detection at Runtime

The parser SHALL:

1. Read the top-level `version` string.
2. Check `compatibleVersion` if present — if it is greater than `"5.0.0"` we
   cannot guarantee compatibility; log a warning but attempt parse.
3. Reject if `version` is absent AND file structure looks like 4.x (no
   `compatibleVersion` field, no `inheritTranslation` in first bone).
4. Accept anything with `version` in `["5.0.0"…"5.7.9"]` as primary support.
5. Accept higher 5.x with a warning (best-effort).
6. Reject 4.x explicitly with a clear error message.

---

## Version-Sensitive Fields Summary

| Field / Feature | 4.x | 5.0 | 5.5+ |
|---|---|---|---|
| `version` field | absent | present | present |
| `compatibleVersion` | absent | present | present |
| `frameRate` scope | per-animation | per-armature | per-armature |
| Bone inheritance flags | no | yes | yes |
| IK constraints | no | yes | yes |
| Mesh/FFD weight data | partial | yes | yes (stable) |
| `zOrder` timeline | no | no | yes |
| `defaultActions` | no | no | yes |
| Sampled curve arrays | no | no | yes |

---

## Export Tool Recommendation

Produce golden test fixtures with **DragonBones Editor 5.6.x or 5.7.x**,
exporting to JSON with:
- Export format: **Data (JSON)**
- Version: **5.7**
- Binary: **disabled**

The DragonBonesJS repository (`DragonBones/DragonBonesJS`) ships sample JSON
files at 5.7.0 — use these as golden fixture sources. Pin the specific commit
hash in `tests/fixtures/README.md` when golden files are checked in.

---

## Decision Record

**Why 5.7 not 5.9?** 5.7 is the last stable version shipped with the widely-used
editor. 5.9 adds features (connected bones, path constraints) not needed by
clckr/boxy. Supporting 5.7 first is the minimum viable scope; 5.9 extensions
can be added incrementally.

**Why not binary `.dbbin`?** The JSON format is human-readable, diffable, and
required for the DragonBonesJS Node harness golden-file approach. Console parity
is met by keeping JSON parsing pure-Nim; `.dbbin` would add a binary decoding
layer with no console-portability benefit for our use case.

**Related issues:**
- `boney-93g`: DragonBonesJS Node harness (depends on this version pin)
- `boney-met`: Freeze model types (depends on this to know which fields to model)
- `boney-782`: jsony cross-compile spike (parallel — unrelated to format version)
