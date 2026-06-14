# Console Cross-Compile Notes

boney targets Nintendo 3DS (`-d:ds3`) and PlayStation Vita (`-d:vita`) via the naylib raylib binding compiled against devkitARM / VitaSDK.

---

## Type-check without SDK (free)

```bash
nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --opt:size src/dragonbones.nim
```

This catches import errors and type mismatches across the platform boundary without requiring the console SDKs. Run it as a CI gate alongside the desktop check.

---

## Build flags used in practice

### 3DS (`-d:ds3`)

```bash
arm-none-eabi-nim c \
  -d:ds3 \
  --mm:arc \
  --define:useMalloc \
  --opt:size \
  --os:linux --cpu:arm \
  ...
```

See `scripts/build_3ds.sh` for the full invocation. Requires devkitARM in `$DEVKITARM`.

### Vita (`-d:vita`)

```bash
arm-none-eabi-nim c \
  -d:vita \
  --mm:arc \
  --define:useMalloc \
  --opt:size \
  --os:linux --cpu:arm \
  ...
```

See `scripts/build_vita.sh`. Requires VitaSDK in `$VITASDK`.

---

## What changes on console

| Feature | Desktop | Console (-d:ds3 / -d:vita) |
|---|---|---|
| Image slot rendering | `rlBegin`/`vertex2f` — exact quad | `DrawTexturePro` — AABB approx for skewed quads |
| Mesh slot rendering | `rlBegin`/`vertex2f` — full deformation | `DrawTexturePro` — bounding-box quad |
| Atlas-rotated sprites | `uvQuad` handles rotation transparently | NOT supported — export atlases with rotation disabled |
| boxy adapter | Available | Compile error (guard at top of file) |

---

## Console-safe adapter rules

1. Do not import the boxy adapter in any console-targeted file.
2. Export DragonBones atlases with **rotation disabled** for console builds.
3. Skew-heavy animations will lose visual accuracy on console; use the desktop naylib path to validate art before shipping.

---

## Memory model

Use `--mm:arc` (Automatic Reference Counting). The core animation pipeline is allocation-free in the steady state when buffers are pre-sized; `--mm:arc` then produces no GC pauses during gameplay.

`--define:useMalloc` routes ARC allocations through the C `malloc` / `free` heap, which is required on embedded targets where Nim's default allocator is unavailable.
