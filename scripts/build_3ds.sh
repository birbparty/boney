#!/usr/bin/env bash
# Compile-check the boney core for Nintendo 3DS using devkitARM.
#
# Prerequisites:
#   DEVKITPRO — path to devkitPro root (e.g. /opt/devkitpro)
#   DEVKITARM — path to devkitARM toolchain (default: $DEVKITPRO/devkitARM)
#
# What this does:
#   1. Substitutes SDK paths in nim_3ds.cfg to produce a real nim.cfg
#   2. Runs `nim c --compileOnly` (Nim→C + arm-none-eabi-gcc, no link step)
#   3. Restores the original nim.cfg on exit
#
# The link step is intentionally omitted: libctru stub libraries are not
# bundled. A full link check requires the devkitPro portlibs environment.

set -euo pipefail

if [[ -z "${DEVKITPRO:-}" ]]; then
  echo "Error: DEVKITPRO is not set." >&2
  echo "  Install devkitPro from https://devkitpro.org/wiki/Getting_Started" >&2
  exit 1
fi
DEVKITARM="${DEVKITARM:-${DEVKITPRO}/devkitARM}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Backup nim.cfg; restore it on any exit (clean, error, or signal).
cp nim.cfg nim.cfg.bak
trap 'mv nim.cfg.bak nim.cfg' EXIT

sed \
  -e "s|@DEVKITPRO@|${DEVKITPRO}|g" \
  -e "s|@DEVKITARM@|${DEVKITARM}|g" \
  nim_3ds.cfg > nim.cfg

mkdir -p stubs

nim c \
  --compileOnly \
  --hints:off \
  src/dragonbones/anim/sample.nim

echo "3DS compile check passed (Nim→C + arm-none-eabi-gcc, no link)."
