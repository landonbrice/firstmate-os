#!/usr/bin/env bash
# tests/fm-classify-turnend-quiet.test.sh - a bare .turn-ended ping whose task's
# .status log did not move this poll (no *.status file in the same wake batch)
# and whose current line is not captain-relevant must not wake the primary by
# itself, while a status change, a captain-relevant line, or a mixed batch
# always still surfaces. bin/fm-classify-lib.sh's signal_turnend_status_quiet
# owns the rule; bin/fm-watch.sh applies it only when
# signal_secondmate_echoes_only and signal_self_maintenance_done_only did not
# already absorb the batch. The watcher-level absorb and triage-log line are
# driven end to end in tests/fm-watch-triage.test.sh
# (test_turn_ended_repeated_status_absorbed and its never-absorb siblings).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-turnend-quiet-tests)

test_bare_turnend_over_non_relevant_status_absorbable() {
  local dir state
  dir="$TMP_ROOT/quiet"; state="$dir/state"; mkdir -p "$state"
  printf 'working: upstream merge on branch, 15 conflicted files, resolving\n' > "$state/task.status"
  : > "$state/task.turn-ended"
  signal_turnend_status_quiet "$state/task.turn-ended" \
    || fail "a bare turn-end over an unchanged working: status was not absorbable"
  printf 'paused [at=1]: full test suite running, resumes on exit\n' > "$state/other.status"
  : > "$state/other.turn-ended"
  signal_turnend_status_quiet "$state/other.turn-ended" \
    || fail "a bare turn-end over an unchanged paused: status was not absorbable"
  pass "a bare turn-end ping over an unchanged non-captain-relevant status is absorbable"
}

test_bare_turnend_over_captain_relevant_status_surfaces() {
  local dir state line
  dir="$TMP_ROOT/relevant"; state="$dir/state"; mkdir -p "$state"
  for line in \
      'done: finished, nothing else pending' \
      'needs-decision: pick A or B' \
      'blocked: need access' \
      'failed: crashed on step 3'; do
    printf '%s\n' "$line" > "$state/task.status"
    : > "$state/task.turn-ended"
    ! signal_turnend_status_quiet "$state/task.turn-ended" \
      || fail "a bare turn-end over a captain-relevant status was absorbable: $line"
  done
  pass "a bare turn-end over a captain-relevant status always surfaces"
}

test_turnend_quiet_never_absorbs_a_mixed_batch() {
  local dir state
  dir="$TMP_ROOT/mixed"; state="$dir/state"; mkdir -p "$state"
  printf 'working: still resolving\n' > "$state/task.status"
  : > "$state/task.turn-ended"
  ! signal_turnend_status_quiet "$state/task.status" "$state/task.turn-ended" \
    || fail "a batch that also carries the *.status file was absorbable"
  pass "signal_turnend_status_quiet never absorbs a batch that includes a *.status file"
}

test_turnend_quiet_surfaces_when_status_missing_or_unreadable() {
  local dir state
  dir="$TMP_ROOT/missing"; state="$dir/state"; mkdir -p "$state"
  : > "$state/orphan.turn-ended"
  ! signal_turnend_status_quiet "$state/orphan.turn-ended" \
    || fail "a turn-end with no paired status log was absorbable"
  ! signal_turnend_status_quiet \
    || fail "an empty batch was absorbable"
  pass "a turn-end with no resolvable status log, and an empty batch, always surface"
}

test_bare_turnend_over_non_relevant_status_absorbable
test_bare_turnend_over_captain_relevant_status_surfaces
test_turnend_quiet_never_absorbs_a_mixed_batch
test_turnend_quiet_surfaces_when_status_missing_or_unreadable
