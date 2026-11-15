#!/usr/bin/env bash
# tools/check_scripts.sh
#
# Compile-check every GDScript we own, headless, without opening the editor.
# This is the A1 evidence ("zero errors and zero warnings from our code") and it catches
# parse errors long before a human presses Play.
#
# addons/zylann.voxel/ is NEVER checked: it is vendored third-party code (hard rule #3).
#
# Usage:
#   GODOT=/path/to/godot tools/check_scripts.sh
# Exit code: 0 if every script compiles clean, 1 otherwise.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

cd "$PROJECT_DIR" || exit 1

mapfile -t SCRIPTS < <(find src tests tools -name '*.gd' -type f | sort)

fail=0
warn=0
echo "Compile-checking ${#SCRIPTS[@]} scripts with: $GODOT"
echo "Project: $PROJECT_DIR"
echo

for s in "${SCRIPTS[@]}"; do
  out="$("$GODOT" --headless --path "$PROJECT_DIR" --check-only --script "res://$s" 2>&1)"
  code=$?
  # --check-only can exit 0 while still printing SCRIPT ERROR, so grep the output too.
  if [[ $code -ne 0 ]] || grep -qE "SCRIPT ERROR|Parse Error|Compile Error" <<<"$out"; then
    echo "FAIL  $s"
    grep -vE "^Godot Engine|^Requested V-Sync|Project FPS" <<<"$out" | sed 's/^/        /'
    fail=$((fail + 1))
  else
    if grep -qE "^WARNING|SCRIPT WARNING" <<<"$out"; then
      echo "WARN  $s"
      grep -E "^WARNING|SCRIPT WARNING" <<<"$out" | sed 's/^/        /'
      warn=$((warn + 1))
    else
      echo "ok    $s"
    fi
  fi
done

echo
echo "SUMMARY: ${#SCRIPTS[@]} scripts, $fail failed, $warn with warnings"
[[ $fail -eq 0 ]]
