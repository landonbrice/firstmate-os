#!/usr/bin/env bash
# tests/fm-watch-triage-fork.test.sh - this fork's own wake-triage regressions for
# bin/fm-watch.sh: secondmate acknowledgement and self-maintenance absorbs, quiet
# turn-end pings, the silent-idle backstop, and the bounds on repeat stale alarms
# for terminal status lines, delivered PRs under an armed merge poll, and declared
# waits. They live apart from tests/fm-watch-triage.test.sh so that upstream-owned
# suite stays mergeable and each script fits one 30-minute CI job; the watcher
# helpers below are copies of that suite's, kept identical.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# fm_pr_poll_prepare/fm_pr_poll_publish_prepared arm a genuine merge poll for a
# delivered worker, the same artifacts bin/fm-pr-check.sh publishes.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-fork-tests)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" &
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Stop an owned watcher. TERM must end it through its EXIT cleanup, so one still
# alive after the file's standard 100-tick budget fails the case here, with the
# process evidence wait_for_exit prints, instead of an unbounded wait hanging
# the whole suite until the CI job timeout.
reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

test_secondmate_ack_echo_absorbed_then_milestone_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-ack-echo); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'working [key=send]: corr=0123456789abcdef option 1 relayed to the worker: queue-only send\n' > "$state/mate.status"
  # An idle mate has no busy evidence, so only the echo rule can absorb this.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced an idle secondmate's acknowledgement echo: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "an acknowledgement echo printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "an acknowledgement echo enqueued a durable wake"; }
  grep -F "absorbed acknowledgement echo signal: $state/mate.status" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the absorbed echo left no triage-log line: $(cat "$state/.watch-triage.log" 2>/dev/null)"; }
  # A milestone from the same idle mate still wakes on the next append.
  printf 'done [key=send]: daily sent to 9 recipients\n' >> "$state/mate.status"
  wait_for_exit "$pid" 100 || fail "watcher absorbed a secondmate done: after absorbing its echo"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate done"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced done failed"
  sed -n '/^UNREAD STATUS/,$p' "$drain_out" | grep -F 'mate working [key=send]: corr=0123456789abcdef option 1 relayed' >/dev/null \
    || fail "the absorbed echo was not presented in the drain's UNREAD STATUS section: $(cat "$drain_out")"
  pass "an idle secondmate's acknowledgement echo is absorbed with a triage line, its later done: wakes, and the drain still presents the echo"
}

test_secondmate_self_maintenance_done_absorbed_then_real_done_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-self-maintenance); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'done [key=stow]: corr=0123456789abcdef stow pass 4 complete\n' > "$state/mate.status"
  # An idle mate has no busy evidence, so only the self-maintenance rule can
  # absorb this done: line (done is never an ack echo by design).
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced an idle secondmate's stow receipt: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a self-maintenance receipt printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a self-maintenance receipt enqueued a durable wake"; }
  grep -F "absorbed self-maintenance receipt signal: $state/mate.status" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the absorbed receipt left no triage-log line: $(cat "$state/.watch-triage.log" 2>/dev/null)"; }
  # A real deliverable from the same idle mate still wakes on the next append.
  printf 'done [key=send]: daily sent to 9 recipients\n' >> "$state/mate.status"
  wait_for_exit "$pid" 100 || fail "watcher absorbed a secondmate done: after absorbing its stow receipt"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate done"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced done failed"
  sed -n '/^UNREAD STATUS/,$p' "$drain_out" | grep -F 'mate done [key=stow]: corr=0123456789abcdef stow pass 4 complete' >/dev/null \
    || fail "the absorbed receipt was not presented in the drain's UNREAD STATUS section: $(cat "$drain_out")"
  pass "an idle secondmate's stow-pass receipt is absorbed with a triage line, its later real done: wakes, and the drain still presents the receipt"
}

test_turn_ended_repeated_status_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-repeated-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'working: upstream merge on branch, 15 conflicted files, resolving\n' > "$state/task.status"
  # Prime the status baseline BEFORE the turn-end file exists and the watcher
  # starts, so the first poll's batch is the bare turn-end alone - exactly the
  # "status provably did not move this poll" shape signal_turnend_status_quiet
  # requires - rather than a mixed first-sight batch of both files.
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the status baseline"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the ordinary provably-working absorb
  # cannot save this bare ping, only signal_turnend_status_quiet can - the
  # status log did not move (only the turn-end file changed this poll) and its
  # last line is an ordinary working: note, never captain-relevant.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced a bare turn-end over an unchanged working: status: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a repeated-status turn-end printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a repeated-status turn-end enqueued a durable wake"; }
  grep -F "absorbed repeated identical status signal: $state/task.turn-ended" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the absorbed turn-end left no triage-log line: $(cat "$state/.watch-triage.log" 2>/dev/null)"; }
  reap "$pid"
  pass "a bare turn-end ping over an unchanged non-captain-relevant status is absorbed with a triage line"
}

test_turn_ended_terminal_status_never_absorbed_as_repeated() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-terminal-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'done: finished, nothing else pending\n' > "$state/task.status"
  # Same baseline priming as the repeated-status case above, so this pins the
  # never-absorb boundary on the identical bare-turn-end-only batch shape.
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the status baseline"
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "watcher absorbed a bare turn-end over a terminal done: status (should always surface)"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced terminal turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null \
    || fail "surfaced terminal turn-end was not queued"
  pass "a bare turn-end ping over an unchanged terminal (done:) status always surfaces, never absorbed as repeated"
}

# --- silent-idle backstop: a plain wall-clock idle-duration check, independent
#     of the hash-stability cascade above (bin/fm-watch.sh's silent_idle_check) --
# The 2026-08-29 silent-done strand: two agents finished only through chat or an
# interactive pane menu, never wrote a done:/failed:/needs-decision:/blocked:
# status line, and sat idle for 15 days before an unrelated Bridge snapshot check
# caught them. This backstop fires once a window has been observed idle for
# FM_SILENT_IDLE_SECS with no terminal status line, using a distinct "silent-idle"
# reason so it is never confused with a possible-wedge escalation.
test_silent_idle_backstop_surfaces_a_terminal_status_gap() {
  local dir state fakebin out drain_out capture_file window key sig pid
  dir=$(make_case silent-idle-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-silent"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/silent.meta"
  # Non-terminal status: the worker never wrote a captain-relevant verb.
  printf 'working: implementing\n' > "$state/silent.status"
  sig=$(seen_sig "$state/silent.status"); printf '%s' "$sig" > "$state/.seen-silent_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_SILENT_IDLE_SECS=1 FM_STALE_ESCALATE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || fail "watcher did not surface a silent-idle backstop wake within the bound"
  grep -F "stale: $window (silent-idle" "$out" >/dev/null \
    || fail "watcher did not print the distinct silent-idle wake: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a silent-idle wake was mislabeled a wedge"
  [ -e "$state/.silent-idle-surfaced-$key" ] || fail "silent-idle surfaced marker was not recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the silent-idle wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "silent-idle wake was not queued"
  pass "silent-idle backstop: a live worker idle past FM_SILENT_IDLE_SECS with no terminal status line surfaces once, distinctly labeled"
}

test_silent_idle_backstop_suppressed_by_declared_pause() {
  local dir state fakebin out capture_file window sig pid key
  dir=$(make_case silent-idle-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-silent-paused"
  printf 'idle prompt, waiting' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/silentpaused.meta"
  printf 'paused: waiting on an upstream release\n' > "$state/silentpaused.status"
  sig=$(seen_sig "$state/silentpaused.status"); printf '%s' "$sig" > "$state/.seen-silentpaused_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_SILENT_IDLE_SECS=1 FM_STALE_ESCALATE_SECS=999999 FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40
  if grep -F "silent-idle" "$out" >/dev/null; then
    fail "a declared paused: line should suppress the silent-idle backstop: $(cat "$out")"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_absent "$state/.silent-idle-surfaced-$key" "a declared pause should never let the silent-idle timer arm"
  pass "silent-idle backstop: a declared paused: line suppresses it exactly like the ordinary stale cadence"
}

# --- terminal stale for a DELIVERED ship worker ------------------------------
#
# The measured 2026-09-23 shape: a ship worker reported `done: PR <url>`, its PR
# is open and under this watcher's own armed merge poll, and it cannot be torn
# down because its worktree still holds the PR branch. It therefore sits idle at
# its prompt for as long as the review takes, and every turn end redraws its
# pane into a new hash. `done:` is captain-relevant, so each new hash re-entered
# the terminal stale path and alarmed again: measured at one stale wake per turn
# end, each costing a supervision turn that concludes the worker is still
# finished.
#
# Drive real turn ends, acknowledging each wake exactly as a supervision turn
# does, and count. The two cases differ in ONE condition - whether the task's
# merge poll is armed - so the flood and the bound are the same worker read two
# ways, and the unarmed case keeps this from passing vacuously.

# One turn end: the pane redraws, the watcher runs until it surfaces something
# or has completed two whole poll cycles on the new hash, then the handling turn
# acknowledges whatever was queued. Echoes the number of stale wakes queued for
# <window> by this turn end.
drive_turn_end() {  # <dir> <state> <fakebin> <capture> <window> <content> [env...]
  local dir=$1 state=$2 fakebin=$3 capture=$4 window=$5 content=$6
  shift 6
  local pid wakes
  printf '%s\n' "$content" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=14400 FM_STALE_ESCALATE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" >> "$dir/watch.out" 2>&1 &
  pid=$!
  if ! wait_for_exit "$pid" 60; then
    wait_poll_cycle "$state" "$pid" 60 || true
    reap "$pid"
  fi
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  ack_stopped_cycle "$state" >/dev/null 2>&1 || true
  printf '%s' "$wakes"
}

# Build a delivered-and-idle ship worker. Echoes "<dir> <state> <fakebin>".
make_delivered_worker() {  # <name> <window> <pr-url>
  local name=$1 window=$2 url=$3 dir state fakebin statusf
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  statusf="$state/ship.status"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\npr=%s\n' "$window" "$url" \
    > "$state/ship.meta"
  printf 'working: opening the PR\ndone: PR %s\n' "$url" > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-ship_status"
  printf '%s\n' "$dir" "$state" "$fakebin"
}

test_delivered_pr_stale_flood_is_bounded_by_the_armed_merge_poll() {
  local url window dir state fakebin key total round wakes
  url="https://github.com/o/r/pull/12"
  window="test:fm-ship"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · idle at its prompt'

  # No merge poll armed: the first sight still alarms, exactly once.
  # shellcheck disable=SC2046 # three fields, deliberately word-split
  set -- $(make_delivered_worker delivered-unarmed "$window" "$url")
  dir=$1; state=$2; fakebin=$3
  total=0; round=1
  while [ "$round" -le 3 ]; do
    wakes=$(drive_turn_end "$dir" "$state" "$fakebin" "$dir/pane.txt" "$window" \
      "idle at its prompt, turn $round")
    total=$(( total + wakes ))
    round=$((round + 1))
  done
  [ "$total" -eq 1 ] \
    || fail "a delivered worker with no armed merge poll raised $total stale wakes across 3 turn ends, want exactly one (the cue to tear down or arm)"

  # The claim: the same worker, with its merge poll armed for that exact PR.
  # shellcheck disable=SC2046 # three fields, deliberately word-split
  set -- $(make_delivered_worker delivered-armed "$window" "$url")
  dir=$1; state=$2; fakebin=$3
  fm_pr_poll_prepare "$state" ship github "$url" github.com o/r 12 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "could not prepare the task's merge poll"
  fm_pr_poll_publish_prepared || fail "could not publish the task's merge poll"
  [ -e "$state/ship.pr-poll-registration" ] || fail "the merge poll left no registration record"

  total=0; round=1
  while [ "$round" -le 3 ]; do
    wakes=$(drive_turn_end "$dir" "$state" "$fakebin" "$dir/pane.txt" "$window" \
      "idle at its prompt, turn $round")
    total=$(( total + wakes ))
    round=$((round + 1))
  done
  [ "$total" -le 1 ] \
    || fail "a delivery under an armed merge poll still raised $total stale wakes across 3 turn ends"
  [ -e "$state/.paused-resurfaced-$key" ] \
    || fail "the delivery bound did not record the shared re-surface throttle, so nothing re-checks it"
  grep -F 'merge-watch:' "$state/.paused-resurfaced-$key" >/dev/null \
    || fail "the throttle was not bound to this delivery's own scope: $(cat "$state/.paused-resurfaced-$key")"
  unset FM_FAKE_CREW_STATE
  pass "a delivered PR under an armed merge poll stops re-alarming on every turn end, and is still re-checked on the shared cadence"
}

# Build a worker whose status log is the given lines (one per argument), with the
# task's merge poll armed for <pr-url> only when <armed> is yes.
make_replay_worker() {  # <name> <window> <pr-url> <armed yes|no> <status-line>...
  local name=$1 window=$2 url=$3 armed=$4 dir state fakebin statusf
  shift 4
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  statusf="$state/ship.status"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\npr=%s\n' "$window" "$url" \
    > "$state/ship.meta"
  printf '%s\n' "$@" > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-ship_status"
  if [ "$armed" = yes ]; then
    fm_pr_poll_prepare "$state" ship github "$url" github.com o/r "${url##*/}" "$ROOT/bin/fm-pr-poll.sh" \
      || fail "could not prepare the task's merge poll"
    fm_pr_poll_publish_prepared || fail "could not publish the task's merge poll"
  fi
  printf '%s\n' "$dir" "$state" "$fakebin"
}

# Stale wakes raised across <n> turn ends of pane churn for a replay worker.
replay_turn_ends() {  # <dir> <state> <fakebin> <window> <n>
  local dir=$1 state=$2 fakebin=$3 window=$4 n=$5 total=0 round=1
  while [ "$round" -le "$n" ]; do
    total=$(( total + $(drive_turn_end "$dir" "$state" "$fakebin" "$dir/pane.txt" "$window" \
      "idle at its prompt, turn $round") ))
    round=$((round + 1))
  done
  printf '%s' "$total"
}

# Replays of the 2026-09-25/26 false alarms. The status lines are the real events
# recorded in data/<id>/timeline.json for each task (the live state files were
# torn down): fm-bridge-timeout ended on a `done: PR <url> (...)` line with no
# merge poll armed, and fm-mate-context-reset went `working: PR <url> open, CI
# pending` then `done: PR <url>` while its PR sat under review.
test_terminal_last_line_alarms_once_then_stays_quiet() {
  local window="test:fm-ship" key url17 url16 dir state fakebin total
  key=$(printf '%s' "$window" | tr ':/.' '___')
  url17="https://github.com/o/r/pull/17"
  url16="https://github.com/o/r/pull/16"
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · idle at its prompt'

  # fm-bridge-timeout: done with a PR URL, no poll armed - fires once.
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-bridge "$window" "$url17" no \
    "done [at=1790400000]: PR $url17 (fleet 8s budget + stale_since cache; local tests pass; fork shows no CI checks yet)")
  dir=$1; state=$2; fakebin=$3
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 4)
  [ "$total" -eq 1 ] || fail "fm-bridge-timeout replay raised $total stale wakes across 4 turn ends, want exactly 1"

  # fm-mate-context-reset: working+PR then done, poll armed - fires at most once.
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-reset "$window" "$url16" yes \
    "working [at=1790400000]: PR $url16 open, CI pending" \
    "done [at=1790400100]: PR $url16")
  dir=$1; state=$2; fakebin=$3
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 4)
  [ "$total" -le 1 ] || fail "fm-mate-context-reset replay raised $total stale wakes across 4 turn ends, want at most 1"

  # done without a PR URL, and failed: the same once-only rule.
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-nopr "$window" "$url17" no "done [at=1790400000]: refactor finished")
  dir=$1; state=$2; fakebin=$3
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 3)
  [ "$total" -eq 1 ] || fail "a done line without a PR raised $total stale wakes, want exactly 1"
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-failed "$window" "$url17" no "failed [at=1790400000]: build broke")
  dir=$1; state=$2; fakebin=$3
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 3)
  [ "$total" -eq 1 ] || fail "a failed line raised $total stale wakes, want exactly 1"

  # A NEW non-terminal line followed by a new terminal line is a new sighting.
  printf 'working [at=1790400200]: re-opened for review feedback\n' >> "$state/ship.status"
  printf 'failed [at=1790400300]: build broke again\n' >> "$state/ship.status"
  printf '%s' "$(seen_sig "$state/ship.status")" > "$state/.seen-ship_status"
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 3)
  [ "$total" -eq 1 ] || fail "a new terminal line after a new working line raised $total stale wakes, want exactly 1"
  unset FM_FAKE_CREW_STATE
  pass "a worker whose last line is done:/failed: alarms once per line and never again on pane churn"
}

test_working_pr_line_under_armed_poll_is_bounded() {
  local window="test:fm-ship" url dir state fakebin total old
  url="https://github.com/o/r/pull/16"
  old=$(( $(date +%s) - 1000 ))
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · idle at its prompt'

  # Control: the same working line with no poll armed still floods, so the
  # bounded case cannot pass vacuously. Age the status beyond the upstream
  # unknown-alive progress window so that independent bound does not absorb the
  # replay this fork test uses to isolate the merge-poll contract.
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-ci-unarmed "$window" "$url" no "working [at=1790400000]: PR $url open, CI pending")
  dir=$1; state=$2; fakebin=$3
  set_mtime "$old" "$state/ship.status"
  printf '%s' "$(seen_sig "$state/ship.status")" > "$state/.seen-ship_status"
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 3)
  [ "$total" -ge 3 ] || fail "an unarmed working PR line raised $total stale wakes across 3 turn ends, so the bounded case proves nothing"

  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-ci-armed "$window" "$url" yes "working [at=1790400000]: PR $url open, CI pending")
  dir=$1; state=$2; fakebin=$3
  set_mtime "$old" "$state/ship.status"
  printf '%s' "$(seen_sig "$state/ship.status")" > "$state/.seen-ship_status"
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 4)
  [ "$total" -le 1 ] || fail "a working PR line under an armed poll raised $total stale wakes across 4 turn ends, want at most 1"

  # A poll armed for a DIFFERENT PR does not bound it.
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-ci-other "$window" "$url" yes "working [at=1790400000]: PR https://github.com/o/r/pull/99 open, CI pending")
  dir=$1; state=$2; fakebin=$3
  set_mtime "$old" "$state/ship.status"
  printf '%s' "$(seen_sig "$state/ship.status")" > "$state/.seen-ship_status"
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 3)
  [ "$total" -ge 3 ] || fail "a working line naming another PR was bounded by this task's poll ($total wakes)"
  unset FM_FAKE_CREW_STATE
  pass "a working line naming a PR is bounded once the merge poll is armed for that same PR"
}

test_wedged_worker_without_terminal_line_still_alarms() {
  local window="test:fm-ship" dir state fakebin total
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · idle at its prompt'
  # A wedged worker has written nothing recently: age the status beyond the
  # upstream unknown-alive progress window, which otherwise bounds this replay.
  # shellcheck disable=SC2046
  set -- $(make_replay_worker replay-wedged "$window" "https://github.com/o/r/pull/5" yes "working [at=1790400000]: implementing the change")
  dir=$1; state=$2; fakebin=$3
  set_mtime "$(( $(date +%s) - 1000 ))" "$state/ship.status"
  printf '%s' "$(seen_sig "$state/ship.status")" > "$state/.seen-ship_status"
  total=$(replay_turn_ends "$dir" "$state" "$fakebin" "$window" 3)
  [ "$total" -ge 3 ] || fail "an idle worker with no terminal line raised only $total stale wakes across 3 turn ends"
  unset FM_FAKE_CREW_STATE
  pass "an idle worker with no terminal line and no PR in its last line still alarms"
}

# The same drive, for the two DECLARED waits. These were already bounded by the
# re-surface throttle before the delivery bound existed; this pins that, so a
# later change to the terminal path cannot quietly cost a parked worker its
# cadence.
test_declared_waits_are_not_realarmed_by_turn_ends() {
  local spec name last crew window dir state fakebin statusf total round wakes
  window="test:fm-parked"
  for spec in \
    'parked-paused|paused: waiting on the lavish review poll|state: paused · source: status-log · waiting on the lavish review poll' \
    'parked-captain-held|captain-held [key=route]: tracked by task-route|state: stopped · source: pane · idle at its prompt'
  do
    name=${spec%%|*}
    last=${spec#*|}; last=${last%%|*}
    crew=${spec##*|}
    dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
    statusf="$state/parked.status"
    printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/parked.meta"
    printf '%s\n' "$last" > "$statusf"
    printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-parked_status"
    export FM_FAKE_CREW_STATE="$crew"

    total=0; round=1
    while [ "$round" -le 3 ]; do
      wakes=$(drive_turn_end "$dir" "$state" "$fakebin" "$dir/pane.txt" "$window" \
        "idle, parked, turn $round")
      total=$(( total + wakes ))
      round=$((round + 1))
    done
    unset FM_FAKE_CREW_STATE
    [ "$total" -le 1 ] \
      || fail "$name: a declared wait raised $total stale wakes across 3 turn ends"
  done
  pass "a declared paused: or captain-held: wait is surfaced once and not re-alarmed by later turn ends"
}

test_secondmate_ack_echo_absorbed_then_milestone_surfaced
test_secondmate_self_maintenance_done_absorbed_then_real_done_surfaced
test_turn_ended_repeated_status_absorbed
test_turn_ended_terminal_status_never_absorbed_as_repeated
test_silent_idle_backstop_surfaces_a_terminal_status_gap
test_silent_idle_backstop_suppressed_by_declared_pause
test_delivered_pr_stale_flood_is_bounded_by_the_armed_merge_poll
test_terminal_last_line_alarms_once_then_stays_quiet
test_working_pr_line_under_armed_poll_is_bounded
test_wedged_worker_without_terminal_line_still_alarms
test_declared_waits_are_not_realarmed_by_turn_ends
