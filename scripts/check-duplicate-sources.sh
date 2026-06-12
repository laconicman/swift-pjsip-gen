#!/usr/bin/env bash
# check-duplicate-sources.sh — guard byte-equality of source files that are deliberately
# duplicated across SwiftPM target boundaries (e.g. a .plugin target that cannot import
# the library code its executable tool also uses).
#
# Usage:
#   Pairs mode:   check-duplicate-sources.sh path/A.swift:other/A.swift [more pairs...]
#   Common mode:  check-duplicate-sources.sh --common DIR_A DIR_B
#                 (compares every same-named *.swift file present in both directories,
#                  non-recursive)
#
# Exit 0 when all duplicates are identical; exit 1 listing every drifted pair.
set -euo pipefail

fail=0

hash_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

compare() {
  local a="$1" b="$2"
  if [[ ! -f "$a" || ! -f "$b" ]]; then
    echo "MISSING  $a <-> $b (one side absent)"; fail=1; return
  fi
  if [[ "$(hash_of "$a")" != "$(hash_of "$b")" ]]; then
    echo "DRIFTED  $a <-> $b"
    diff -u "$a" "$b" | head -20 || true
    fail=1
  else
    echo "OK       $a == $b"
  fi
}

if [[ "${1:-}" == "--common" ]]; then
  dir_a="${2:?usage: --common DIR_A DIR_B}"; dir_b="${3:?usage: --common DIR_A DIR_B}"
  found=0
  for f in "$dir_a"/*.swift; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    if [[ -f "$dir_b/$name" ]]; then compare "$f" "$dir_b/$name"; found=1; fi
  done
  [[ $found -eq 1 ]] || { echo "No same-named .swift files in both dirs — nothing guarded."; exit 1; }
else
  [[ $# -ge 1 ]] || { grep '^#' "$0" | head -12; exit 2; }
  for pair in "$@"; do compare "${pair%%:*}" "${pair##*:}"; done
fi

if [[ $fail -ne 0 ]]; then
  echo
  echo "Duplicated sources have drifted. Sync them (copy the intended version to both"
  echo "locations) — they are duplicated because SwiftPM plugins cannot import library targets."
  exit 1
fi
