#!/usr/bin/env bash
# Behavior tests for fm-context-check.sh: threshold boundary, missing transcript,
# non-claude harness, and the per-task opt-in file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-context-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-check)

# make_home <name> <kind> <harness> <tokens|none>: fixture home with meta and an
# optional Claude transcript whose last assistant call totals <tokens> of context.
make_home() {
  local name=$1 kind=$2 harness=$3 tokens=$4 home dir
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/fakehome"
  printf 'harness=%s\nkind=%s\nworktree=%s/wt\nhome=%s/wt\n' "$harness" "$kind" "$home" "$home" > "$home/state/t1.meta"
  if [ "$tokens" != none ]; then
    dir="$home/fakehome/.claude/projects/$(printf '%s/wt' "$home" | sed 's#[/.]#-#g')"
    mkdir -p "$dir"
    printf '{"message":{"role":"assistant","model":"m","usage":{"input_tokens":1,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":5}},"timestamp":"2026-09-25T00:00:00Z"}\n' "$((tokens - 1))" > "$dir/s.jsonl"
  fi
  printf '%s\n' "$home"
}

run_check() {
  local home=$1
  shift
  HOME="$home/fakehome" FM_HOME="$home" "$CHECK" t1 "$@"
}

home=$(make_home over secondmate claude 200001)
out=$(run_check "$home") || fail "nonzero exit"
assert_equals "$out" "context-high: t1 200001 > 200000" "over threshold should print one line"
home=$(make_home at secondmate claude 200000)
assert_equals "$(run_check "$home")" "" "exactly at threshold must be silent"
assert_equals "$(run_check "$home" --threshold 199999)" "context-high: t1 200000 > 199999" "custom threshold"
pass "threshold boundary"

home=$(make_home notx secondmate claude none)
run_check "$home" >/dev/null || fail "missing transcript must exit 0"
assert_equals "$(run_check "$home")" "" "missing transcript must be silent"
pass "missing transcript is silent"

home=$(make_home codex secondmate codex 900000)
assert_equals "$(run_check "$home")" "" "non-claude harness must be silent"
pass "non-claude harness is silent"

home=$(make_home ship ship claude 900000)
assert_equals "$(run_check "$home")" "" "non-secondmate is skipped by default"
touch "$home/state/t1.context-check"
assert_equals "$(run_check "$home")" "context-high: t1 900000 > 200000" "opt-in file enables the check"
pass "opt-in file"
