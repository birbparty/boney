#!/usr/bin/env bash
# Compile-check the boney core for Sony PS Vita using VitaSDK.
#
# Prerequisites:
#   VITASDK — path to VitaSDK root (e.g. /usr/local/vitasdk)
#
# What this does:
#   1. Substitutes SDK paths in nim_vita.cfg to produce a real nim.cfg
#   2. Runs `nim c --compileOnly` (Nim→C + arm-vita-eabi-gcc, no link step)
#   3. Restores the original nim.cfg via `git checkout` on exit
#
# The link step is intentionally omitted: the -Wl,-q flag and SCE stub
# libraries require vita-elf-create and the full VitaSDK portlibs.
# vita-elf-create MUST see -Wl,-q in a full link; it is present in
# nim_vita.cfg for when a full link check is run.

set -euo pipefail

if [[ -z "${VITASDK:-}" ]]; then
  echo "Error: VITASDK is not set." >&2
  echo "  Install VitaSDK from https://vitasdk.org" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Restore nim.cfg to the tracked version on any exit (clean, error, or signal).
# Using git checkout avoids a .bak file and is safe on re-run after SIGKILL.
trap 'git checkout -- nim.cfg' EXIT

sed \
  -e "s|@VITASDK@|${VITASDK}|g" \
  nim_vita.cfg > nim.cfg.tmp && mv -f nim.cfg.tmp nim.cfg

# stubs/ is git-tracked (.gitkeep) but mkdir -p is harmless and explicit.
mkdir -p stubs

nim c \
  --compileOnly \
  --hints:off \
  --nimcache:nimcache/vita \
  src/dragonbones/anim/sample.nim

echo "Vita compile check passed (Nim→C + arm-vita-eabi-gcc, no link)."
