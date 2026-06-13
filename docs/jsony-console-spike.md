# jsony Console Cross-Compile Spike — boney-782

**Outcome: A — jsony is approved. Add to parse module dependency and purity allowlist.**

---

## What was tested

**jsony 1.1.6** (`b28964a`) — fast, low-allocation Nim JSON parser by treeform.

Test: `nim check` against the jsony entry point with each of boney's three
compilation targets and the ARC + useMalloc flags that console builds require.

```bash
JSONY=~/.nimble/pkgs2/jsony-1.1.6-.../jsony.nim

# Host
nim check $JSONY

# 3DS (ARMv6K hard-float, -d:ds3)
nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --define:ds3 --opt:size $JSONY

# Vita (ARMv7, -d:vita)
nim check --os:linux --cpu:arm --mm:arc --define:useMalloc --define:vita --opt:size $JSONY
```

## Results

| Target | Result | Lines processed | Peak mem |
|---|---|---|---|
| Host (macOS/amd64) | ✅ SuccessX | 53 878 | 74 MiB |
| ARM 3DS (`-d:ds3`) | ✅ SuccessX | 51 742 | 74 MiB |
| ARM Vita (`-d:vita`) | ✅ SuccessX | 51 742 | 74 MiB |

## Why this works

jsony is **pure Nim**: no `{.importc.}`, no `{.header: ...}`, no `dynlib`,
no `{.emit.}`, no C source files. Its only imports are from `std/`:

```
import jsony/objvar, std/json, std/options, std/parseutils, std/sets,
       std/strutils, std/tables, std/unicode
```

All of those standard library modules compile cleanly with `--mm:arc` and
`--define:useMalloc` because Nim's standard library is itself console-safe
under ARC — the allocation model change is transparent.

## Decision

**Outcome A.** jsony is allowed for use in boney's core parse module.

Updated in this commit:
- `tests/test_core_purity.nim` — jsony added to `isAllowed`; the
  "blocked until boney-782" note is removed
- `boney.nimble` — jsony added as a package dependency

## Version pin

**jsony 1.1.6** is the version tested and approved. If jsony is upgraded, the
cross-compile spike should be re-run before landing the bump.

## What this does NOT prove

- Link-time behavior on actual devkitARM / VitaSDK (no SDK available on CI
  host) — `nim check` confirms the Nim/C transpilation is clean, not that the
  produced C compiles with the vendor toolchain. The console cfgs handle
  toolchain substitution via the `@TOKEN@` placeholders.
- Thread safety (irrelevant — boney is single-threaded).
- Binary size impact on 3DS (32 MiB ROM limit) — measure at link time once
  the first 3DS binary is built.

---

*Spike performed on Nim 2.2.10, jsony 1.1.6-b28964a, 2026-06-12.*
