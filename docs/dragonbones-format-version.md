# DragonBones Data Format — Pinned Version Range

> **Verification status:** Technical claims marked ⚠️ require confirmation
> against a DragonBonesJS 5.7.0 golden fixture (boney-93g) before being
> treated as normative. Claims marked ✅ are based on the DragonBonesJS
> TypeScript reference implementation. All others are structural/field-presence
> facts confirmed from published format docs.

## Decision

**boney targets DragonBones JSON format version 5.7.x (`"version": "5.7.0"`),
with read-compatible support (accept-with-warning) for 5.5.0 through 5.7.x as
primary, and best-effort (no golden files required) for 5.0.0–5.4.x.**

Binary `.dbbin` format is **out of scope** for this library. JSON only.

---

## Version Landscape

DragonBones has gone through two major format generations and several minor
revisions. boney pins to the 5.x generation.

### 4.x (not supported)

- `version` field absent or `"4.x.x"`
- Bone transforms stored differently (no `inheritTranslation`/`inheritRotation`
  flags — all inheritance was implicit; `isGlobal` per-bone was used instead)
- No `compatibleVersion` field
- `frameRate` is per-animation, not per-armature
- Simpler tween encoding (no sampled curves)
- No formal IK constraint schema
- No mesh/FFD weight data

boney does **not** support 4.x. The format delta is too large to serve with a
single code path cleanly, and all major consumers (clckr, boxy targets) export
from recent DragonBones Editor / DragonBones Pro.

### 5.0 – 5.4.x (best-effort, no golden files required)

- `version` field present: `"5.0.0"`, `"5.1.0"`, etc.
- `compatibleVersion` added (reader minimum)
- `frameRate` moved to armature level
- Bone transform inheritance flags introduced (`inheritTranslation`,
  `inheritRotation`, `inheritScale`, `inheritReflection`); `isGlobal` removed
- Mesh display + FFD weight data added (but vertex format still evolving)
- IK constraint schema stabilized at 5.0
- boney **may** handle these with minor version-guard branches, but they are
  best-effort and golden files are not required for them

### 5.5.x – 5.7.x (PRIMARY TARGET)

- Stable, widely exported by DragonBones Editor 5.5 + 5.6 + 5.7
- `version`: `"5.5.0"`, `"5.6.0"`, `"5.7.0"`
- `compatibleVersion`: typically `"5.0.0"` (meaning: requires a 5.0+ reader)
- Vertex/UV layout for mesh slots stabilized
- Tween-curve encoding stabilized (see below)
- `zOrder` timeline added at 5.5
- `defaultActions` for child armature auto-play added at 5.5 ⚠️ verify version
- This is the format version produced by DragonBones Editor bundled with current
  Unity/Cocos2d-x SDKs and available as a standalone tool

### 5.8.x – 5.9.x (not tested)

- May work with the 5.7 parser if `compatibleVersion` indicates 5.0 compatibility
- Not a primary target; not covered by golden files

---

## Tween-Curve Encoding (version-sensitive, partially unverified)

This is the primary portability hazard across 5.x versions. The `tweenEasing`
and `curve` fields are **mutually exclusive** at the keyframe level: a keyframe
has either `tweenEasing` OR `curve`, not both.

### `tweenEasing` field

| On-wire form | Meaning |
|---|---|
| field **absent** from keyframe | ⚠️ Timeline-type-dependent default — typically **linear** for bone/slot timelines; verify against DragonBonesJS runtime |
| field present as JSON `null` or NaN sentinel | **Stepped/no-tween** (hold previous value) |
| `0` | Linear interpolation ✅ |
| Finite non-zero float | Quad ease ⚠️ verify exact sign/magnitude semantics |

> **Implementation note:** "absent" and the explicit NaN/null sentinel are
> **not the same**. Absent typically means "use the timeline's default tween
> (usually linear)." The explicit NaN/null sentinel is what DragonBones exporters
> emit to signal "no tween / hold." Modeling absent as stepped will play tweened
> animations as hard steps — a silent visual defect on-device.

### `curve` field (when `tweenEasing` is absent)

When a keyframe carries a `curve` array, it replaces `tweenEasing` entirely:

| Array form | Meaning |
|---|---|
| Exactly 4 floats `[p1x, p1y, p2x, p2y]` | Bezier control points (cubic, normalized 0–1) ⚠️ verify |
| More than 4 floats | Pre-sampled value sequence (5.5+ sampled form) ⚠️ verify |

> **Disambiguation note:** the length-4 = bezier / length-> 4 = sampled rule is
> the convention used by DragonBonesJS. It assumes DragonBones never exports a
> 2-sample pre-sampled sequence (which would be 4 values and ambiguous). Confirm
> this boundary against a real 5.7.0 fixture before finalizing the parser branch
> condition.

Keyframe time is stored in **frames** (integer), not seconds. Convert to seconds
at sampling time: `timeSeconds = frame / armature.frameRate`. Guard against
`frameRate == 0`.

---

## Version Detection at Runtime

The parser SHALL:

1. Read the top-level `version` string using semver-aware comparison (parse
   to (major, minor, patch) integers — do NOT use string comparison, as
   `"5.7.10"` would compare less than `"5.7.9"` lexically).
2. Check `compatibleVersion` if present. This field means "requires a reader
   that supports at least this version." Warn if `compatibleVersion` is greater
   than `"5.7.0"` (our own ceiling), since we may be missing format features.
   Normal 5.5–5.7 exports set `compatibleVersion: "5.0.0"` — do NOT warn on that.
3. Detect 4.x by presence of `compatibleVersion` (4.x files have none) AND
   absence of an armature-level `frameRate` (reliable structural markers). Do
   NOT use absence of `inheritTranslation` alone — 5.x omits it at its default
   value, so it can be absent in valid 5.x files.
4. Accept files with `version` in `5.5.0`–`5.7.x` as **primary support**.
5. Accept files with `version` in `5.0.0`–`5.4.x` as **best-effort** (log
   an info message; attempt parse; golden file coverage not guaranteed).
6. Accept files with `version` in `5.8.0`–`5.x.y` with a warning (best-effort;
   `compatibleVersion` check in step 2 provides additional safety).
7. Reject 4.x explicitly with a clear error message.

---

## Version-Sensitive Fields Summary

| Field / Feature | 4.x | 5.0–5.4 | 5.5+ |
|---|---|---|---|
| `version` field | absent | present | present |
| `compatibleVersion` | absent | present | present |
| `frameRate` scope | per-animation | per-armature | per-armature |
| `isGlobal` (bone-level) | yes | removed | removed |
| Bone inheritance flags | no | yes | yes |
| IK constraints | no | yes | yes |
| Mesh/FFD weight data | partial | yes | yes (stable) |
| `zOrder` timeline | no | no | yes |
| `defaultActions` | no | no | yes ⚠️ verify |
| Sampled curve arrays | no | no | yes |

> `isGlobal` (per-bone flag selecting global vs local transform space) was
> present in 4.x but removed in 5.0. Since boney targets 5.x only, `isGlobal`
> is not a field to model — but the 4.x rejection path should handle files that
> have it gracefully (don't crash; error out with version-unsupported).

---

## Export Tool Recommendation

Produce golden test fixtures with **DragonBones Editor 5.6.x or 5.7.x**,
exporting to JSON with:
- Export format: **Data (JSON)**
- Version: **5.7**
- Binary: **disabled**

The DragonBonesJS repository (`DragonBones/DragonBonesJS`) ships sample JSON
files at 5.7.0 — use these as golden fixture sources. Pin the specific commit
hash in `tests/fixtures/README.md` when golden files are checked in (required
before ⚠️ verification items above are marked ✅).

---

## Out of Scope

- Binary `.dbbin` format (no human-readable diff, no DragonBonesJS harness support)
- DragonBones 4.x import
- DragonBones 5.9+ features (connected bones, path constraints) — addable later
- Texture atlas packing format (tracked separately under boney-080)

---

## Decision Record

**Why primary = 5.5–5.7 not 5.0–5.7?** 5.5 is when the `zOrder` and
`defaultActions` features used by clckr were stabilized. 5.0–5.4 files are
structurally compatible but we cannot guarantee correct rendering without golden
files covering that range.

**Why 5.7 not 5.9?** 5.7 is the last stable version shipped with the widely-used
editor. 5.9 adds features (connected bones, path constraints) not needed by
clckr/boxy. Supporting 5.7 first is the minimum viable scope; 5.9 extensions
can be added incrementally.

**Why not binary `.dbbin`?** The JSON format is human-readable, diffable, and
required for the DragonBonesJS Node harness golden-file approach. Console parity
is met by keeping JSON parsing pure-Nim; `.dbbin` would add a binary decoding
layer with no console-portability benefit for our use case.

**Related issues:**
- `boney-b0y`: This document (driving issue)
- `boney-93g`: DragonBonesJS Node harness (needed to verify ⚠️ items above)
- `boney-met`: Freeze model types (depends on this version pin)
- `boney-782`: jsony cross-compile spike (parallel — unrelated to format version)
