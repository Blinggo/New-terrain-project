#!/usr/bin/env bash
# tools/run_tests.sh - M00 / T10 headless test entry point for Linux/macOS/WSL.
#
# Usage:
#   ./tools/run_tests.sh                     # full headless suite (smoke + determinism + gen perf)
#   ./tools/run_tests.sh --skip-perf         # skip the generation benchmark while iterating
#   ./tools/run_tests.sh --with-runtime      # ALSO run the windowed runtime benchmark (needs a display)
#   GODOT=/path/to/godot ./tools/run_tests.sh
#
# Exit code: 0 = everything PASSed (BLOCKED is allowed), 1 = at least one FAIL,
#            2 = could not find a Godot binary.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(dirname "$HERE")"

# Godot executable: $GODOT overrides, then a few well-known locations.
CANDIDATES=(
  "${GODOT:-}"
  "$HOME/.local/godot/godot4"
  "/usr/local/bin/godot"
  "/usr/bin/godot"
  "$(command -v godot 2>/dev/null || true)"
  "$(command -v godot4 2>/dev/null || true)"
)
GODOT_BIN=""
for c in "${CANDIDATES[@]}"; do
  if [ -n "$c" ] && [ -x "$c" ]; then GODOT_BIN="$c"; break; fi
done
if [ -z "$GODOT_BIN" ]; then
  echo "run_tests.sh: no Godot binary found. Set GODOT=/path/to/godot (4.7.x with the Voxel Tools GDExtension)." >&2
  exit 2
fi

echo "run_tests.sh: project=$PROJECT godot=$GODOT_BIN"
echo "run_tests.sh: args=$*"

# The project must have been imported once so the extension and the class_name cache exist.
if [ ! -f "$PROJECT/.godot/extension_list.cfg" ]; then
  echo "run_tests.sh: importing project first (creates .godot/, loads the extension)..."
  "$GODOT_BIN" --headless --path "$PROJECT" --import >/dev/null 2>&1 || true
fi

"$GODOT_BIN" --headless --path "$PROJECT" --script res://tools/run_tests.gd -- "$@"
CODE=$?
echo "run_tests.sh: exit code $CODE"
exit $CODE
