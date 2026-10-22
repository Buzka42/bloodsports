#!/usr/bin/env bash
# Runs every tests/test_*.lua with the shared WoW stub from the elders repo. Usage: tests/run.sh [pattern]
set -u
cd "$(dirname "$0")/.."
export WOW_STUB="${WOW_STUB:-$(cd ../elders && pwd)/tests/wow_stub.lua}"
fail=0
for f in tests/test_*${1:-}*.lua; do
  [ -e "$f" ] || continue
  echo "== $f"
  lua5.1 "$f" || fail=1
done
exit $fail
