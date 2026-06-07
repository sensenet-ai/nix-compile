#!/usr/bin/env bash
# CLI smoke / jank guard: run `nix-compile` in all its forms across a
# good/bad/empty/missing/dir input matrix and assert invariants. Catches the
# rough edges found by dogfooding: crashes, mislabeled/double-prefixed errors,
# and wrong exit codes. Fails (exit 1) on any regression.
#
# Usage (inside `nix develop`):
#   cabal build exe:nix-compile
#   bash tools/clicheck/check.sh "$(cabal list-bin nix-compile)"
set -uo pipefail
BIN="${1:?usage: check.sh <path-to-nix-compile>}"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
printf '{ a = 1; b = 2; }\n'        > "$W/good.nix"
printf '{ = }\n'                    > "$W/bad.nix"
: >                                   "$W/empty.nix"
printf '#!/usr/bin/env bash\necho hi\n' > "$W/good.sh"
mkdir -p "$W/dir"; printf '{ a = 1; }\n' > "$W/dir/x.nix"

pass=0; fail=0
# fail <desc> <reason>
note() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
ok()   { pass=$((pass+1)); }

# expect <desc> <expected-exit> <forbidden-regex> -- <args...>
expect() {
  local desc="$1" want="$2" forbid="$3"; shift 3; [ "$1" = "--" ] && shift
  local out ec; out=$("$BIN" "$@" 2>&1); ec=$?
  # never-acceptable crash/jank markers, anywhere
  if echo "$out" | grep -qiE "INTERNAL ERROR|CallStack|Prelude\.|fromJust|<<loop>>|Parse error: parse error|Parse error: I/O error"; then
    note "$desc" "crash/mislabel marker in output: $(echo "$out" | grep -iE "INTERNAL ERROR|CallStack|Prelude\.|fromJust|<<loop>>|Parse error: (parse|I/O) error" | head -1)"
    return
  fi
  if [ -n "$forbid" ] && echo "$out" | grep -qiE "$forbid"; then
    note "$desc" "forbidden pattern '$forbid' present"; return
  fi
  if [ "$want" != "*" ] && [ "$ec" != "$want" ]; then
    note "$desc" "exit $ec, wanted $want"; return
  fi
  ok
}

expect "help"            0 "" -- --help
expect "noarg"           0 "" --
expect "unknown"         1 "" -- frobnicate x
expect "fmt good"        0 "" -- fmt "$W/good.nix"
expect "fmt bad"         1 "" -- fmt "$W/bad.nix"
expect "fmt missing"     1 "" -- fmt "$W/nope.nix"
expect "fmt dir"         1 "" -- fmt "$W/dir"
expect "infer good"      0 "" -- infer "$W/good.nix"
expect "infer bad"       1 "" -- infer "$W/bad.nix"
expect "infer missing"   1 "" -- infer "$W/nope.nix"
expect "scope good"      0 "" -- scope "$W/good.nix"
expect "scope json"      0 "" -- scope --json "$W/good.nix"
expect "scope dhall"     0 "" -- scope --dhall "$W/good.nix"
expect "scope missing"   1 "" -- scope "$W/nope.nix"
expect "emit good.sh"    0 "" -- emit "$W/good.sh"
expect "emit missing"    1 "" -- emit "$W/nope.sh"
expect "check good.nix"  0 "" -- check "$W/good.nix"
expect "check bad.nix"   1 "" -- check "$W/bad.nix"
expect "check missing"   1 "" -- check "$W/nope.nix"
expect "check good.sh"   0 "" -- check "$W/good.sh"
expect "check dir"       0 "" -- check "$W/dir"

# error-category invariants: missing/dir are I/O errors, not parse errors
mfo=$("$BIN" fmt "$W/nope.nix" 2>&1)
echo "$mfo" | grep -qiE "I/O error" || note "fmt missing label" "expected 'I/O error', got: $mfo"
echo "$mfo" | grep -qiE "I/O error" && ok
dfo=$("$BIN" fmt "$W/dir" 2>&1)
echo "$dfo" | grep -qiE "I/O error" || note "fmt dir label" "expected 'I/O error', got: $dfo"
echo "$dfo" | grep -qiE "I/O error" && ok

echo "CLICHECK: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
