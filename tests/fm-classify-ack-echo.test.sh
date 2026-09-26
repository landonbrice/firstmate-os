#!/usr/bin/env bash
# tests/fm-classify-ack-echo.test.sh - a secondmate status line that only
# acknowledges the parent's own instruction must not wake the primary, while
# every milestone still does. bin/fm-classify-lib.sh's status_line_is_ack_echo
# owns the rule; signal_secondmate_echoes_only applies it to the span a watcher
# signal classifies, and status_line_is_unread_surface keeps an absorbed echo
# readable at the next drain. The watcher-level absorb, triage-log line, and
# drain presentation are driven end to end in tests/fm-watch-triage.test.sh.
#
# The replay case feeds a secondmate parent log, one append at a time, through
# the watcher's signal decision with and without the echo rule, on an idle mate
# that shows no busy evidence (the case the audit measured). The fixture mirrors
# a real 788-line parent log from 2026-09-25 by class: every line keeps its
# state prefix, key shape (reserved prefixes intact, slugs hashed consistently),
# correlation-token shape, order, URL presence, and legacy captain-token or
# prefix match, and every line keeps its echo, URL, and captain-relevance
# classification, while all project prose, identifiers, URLs, and names are
# synthetic placeholders.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-ack-echo-tests)
REPLAY_FIXTURE="$ROOT/tests/fixtures/secondmate-status/cim-signal-2026-09-25.status"
CORR=0123456789abcdef

test_ack_echo_shapes() {
  local line
  for line in \
      "resolved [key=send-now]: answered: Captain pressed Send Now; confirm the row and tear the worker down" \
      "resolved [key=captain-hold-cim-signal-cadence-1]: captain hold cim-signal-cadence: answered" \
      "resolved [key=captain-hold-cim-signal-cadence-2]: captain hold cim-signal-cadence: released" \
      "resolved [key=pending-reply-$CORR]: pending-reply-resolved: task=mate pending-reply-id=$CORR via=status" \
      "working [key=merge-dup]: corr=$CORR same as the previous message, already done: PR 538 merged" \
      "working [key=opt]: corr=$CORR same decision as my previous message, already done" \
      "working [key=send]: corr=$CORR option 1 relayed to the worker: queue-only send exactly once" \
      "working [corr=$CORR]: taken: worker is running the one live daily now" \
      "working corr=$CORR: understood, no manual drain; filed in my backlog" \
      "working: [key=cadence] cadence taken, miss-chasing stopped" \
      "working [key=a] [at=1790000000]: ruling recorded on the item (option c)" \
      "resolved [key=k]: corr=$CORR housekeeping noted, nothing to do" \
      "resolved [key=send-daily]: noted"; do
    status_line_is_ack_echo "$line" || fail "acknowledgement echo not recognized: $line"
  done
  pass "answered, hold, pending-reply, same-as-previous, and short acknowledgement leads are echoes"
}

test_milestones_are_never_echoes() {
  local line
  for line in \
      "done [key=send]: corr=$CORR relayed and sent" \
      "needs-decision [key=k]: corr=$CORR noted: pick A or B" \
      "blocked [key=k]: recorded: need access" \
      "failed [at=1]: received a crash" \
      "paused [key=k]: noted, waiting on CI" \
      "note: recorded for the parent" \
      "captain-held [key=k]: noted" \
      "shrug: noted" \
      "working [key=pr]: corr=$CORR relayed: PR https://github.com/o/r/pull/9 opened" \
      "resolved [key=k]: answered: merge https://github.com/o/r/pull/9 now" \
      "working [key=daily]: corr=$CORR noted: TODAY'S DAILY IS READY for approval" \
      "working [key=q]: corr=$CORR received; the captain must press Approve before 18:00Z" \
      "working [key=q]: corr=$CORR taken: the worker failed its check" \
      "working [key=q]: corr=$CORR recorded, one question for you?" \
      "working [key=q]: corr=$CORR recorded: FINDING before merge, the migration drops a stage" \
      "working [key=q]: corr=$CORR received; row queued but not yet delivered" \
      "working [key=q]: corr=$CORR audit-first answer recorded against the learning-harness item in this home" \
      "working [key=q]: corr=$CORR phase 3 split cost measured on flash, 11 of 14 emails" \
      "working: step 2 of 5" \
      "resolved [key=k]: token blocker settled by option 1, daily sent" \
      "resolved [key=k]: corr=$CORR answered" \
      "resolved [key=k]: captain hold item: answered, and a new wrinkle" \
      "working [key=k]: corr=$CORR" \
      "a continuation line that was recorded"; do
    ! status_line_is_ack_echo "$line" || fail "milestone or fact classified as an echo: $line"
  done
  pass "terminal verbs, URLs, asks, failures, shouting, long leads, and continuation prose are never echoes"
}

test_span_absorbs_only_all_echo_secondmate_spans() {
  local dir state
  dir="$TMP_ROOT/span"; state="$dir/state"; mkdir -p "$state"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'kind=ship\n' > "$state/crew.meta"
  printf 'working [key=a]: corr=%s option 1 relayed to the worker\nresolved [key=b]: answered: go\n' "$CORR" > "$state/mate.status"
  signal_secondmate_echoes_only "$state/mate.status" \
    || fail "an all-echo secondmate span was not absorbable"
  printf 'done [key=a]: sent\n' >> "$state/mate.status"
  ! signal_secondmate_echoes_only "$state/mate.status" \
    || fail "a secondmate span with a done: line was absorbable"
  printf 'working [key=a]: corr=%s option 1 relayed\ncontinuation prose that carries a fact\n' "$CORR" > "$state/mate.status"
  ! signal_secondmate_echoes_only "$state/mate.status" \
    || fail "a multi-line append was absorbable"
  printf 'working [key=a]: corr=%s option 1 relayed\n' "$CORR" > "$state/crew.status"
  ! signal_secondmate_echoes_only "$state/crew.status" \
    || fail "the echo rule leaked onto an ordinary crewmate log"
  printf 'working [key=a]: corr=%s option 1 relayed\n' "$CORR" > "$state/mate.status"
  : > "$state/mate.turn-ended"
  ! signal_secondmate_echoes_only "$state/mate.status" "$state/mate.turn-ended" \
    || fail "a batch with a turn-end marker was absorbable"
  ! signal_secondmate_echoes_only \
    || fail "an empty batch was absorbable"
  : > "$state/empty.status"; printf 'kind=secondmate\n' > "$state/empty.meta"
  ! signal_secondmate_echoes_only "$state/empty.status" \
    || fail "an empty span was absorbable"
  pass "only a secondmate log whose whole new span is echoes is absorbable"
}

test_unread_surface_admits_secondmate_echoes_only() {
  local echo_line="working [key=a]: corr=$CORR option 1 relayed to the worker"
  status_line_is_unread_surface "$echo_line" secondmate \
    || fail "a secondmate echo is not presented as unread status"
  ! status_line_is_unread_surface "$echo_line" ship \
    || fail "an ordinary crewmate's echo joined the unread status surface"
  ! status_line_is_unread_surface "$echo_line" \
    || fail "a kind-less echo joined the unread status surface"
  status_line_is_unread_surface 'note: still presented' ship \
    || fail "a note: line lost its unread presentation"
  pass "the unread status surface adds secondmate echoes without widening other kinds"
}

# The watcher's signal decision for one append on an idle mate: today's rule
# (captain-relevant span, else provably-working absorb) and the same rule with
# the echo absorb in front, as bin/fm-watch.sh applies them.
replay_wakes() {  # <status-file> <start> <with-echo-rule 0|1> -> 0 wake, 1 absorb
  # shellcheck disable=SC2034 # record is assigned by name inside the span reader.
  local f=$1 start=$2 with_echo=$3 record needs=0 rc
  FM_REPLAY_SEEN=$start
  status_span_first_actionable_record "$f" "$start" record needs
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$needs" -ne 1 ] && [ "$with_echo" -eq 1 ] \
    && signal_secondmate_echoes_only "$f"; then
    return 1
  fi
  [ "$rc" -eq 0 ] || [ "$needs" -eq 1 ] && return 0
  signal_crew_provably_working "$f" && return 1
  return 0
}

# The classified position the watcher would hold: the size before this append.
fm_wake_signal_seen_size() {  # <state> <file>
  printf '%s' "${FM_REPLAY_SEEN:-0}"
}

test_replay_real_secondmate_log() {
  local dir state f fixture=${FM_ECHO_REPLAY_FIXTURE:-$REPLAY_FIXTURE}
  local line append='' start today=0 new=0 appends=0 must=0 must_missed=0 discretionary=0 absorbed=0 verb
  [ -r "$fixture" ] || fail "replay fixture missing: $fixture"
  dir="$TMP_ROOT/replay"; state="$dir/state"; mkdir -p "$state"
  printf 'kind=secondmate\n' > "$state/cim-signal.meta"
  printf '#!/usr/bin/env bash\nprintf "state: unknown · source: none · idle\\n"\n' > "$dir/crew-state.sh"
  chmod +x "$dir/crew-state.sh"
  export FM_CREW_STATE_BIN="$dir/crew-state.sh"
  f="$state/cim-signal.status"; : > "$f"
  replay_one() {
    [ -n "$append" ] || return 0
    start=$(wc -c < "$f"); start=${start//[[:space:]]/}
    printf '%s' "$append" >> "$f"
    appends=$((appends + 1))
    replay_wakes "$f" "$start" 0 && today=$((today + 1))
    status_line_verb "${append%%$'\n'*}" verb
    if replay_wakes "$f" "$start" 1; then
      new=$((new + 1))
    else
      absorbed=$((absorbed + 1))
    fi
    case "$verb:$append" in
      done:*|needs-decision:*|blocked:*|failed:*|*://*)
        must=$((must + 1))
        replay_wakes "$f" "$start" 1 || { must_missed=$((must_missed + 1)); printf 'swallowed: %s\n' "${append:0:160}" >&2; }
        ;;
      *) discretionary=$((discretionary + 1)) ;;
    esac
  }
  while IFS= read -r line || [ -n "$line" ]; do
    # A line that opens with a status prefix starts a new append; anything else
    # is continuation prose written by the same multi-line append.
    if [ -n "$append" ] && [[ "$line" =~ ^[a-z][a-z-]*(\ \[[^]]*\]|\ corr=[0-9a-f]{16})*: ]]; then
      replay_one
      append=''
    fi
    append="${append}${line}"$'\n'
  done < "$fixture"
  replay_one
  printf '# replay: %d appends; today %d wakes, with echo rule %d (%d absorbed); %d milestone appends, %d discretionary\n' \
    "$appends" "$today" "$new" "$absorbed" "$must" "$discretionary"
  [ "$today" -eq "$appends" ] || fail "an idle mate's appends did not all wake under today's rule ($today of $appends)"
  [ "$must_missed" -eq 0 ] || fail "$must_missed milestone appends were absorbed"
  [ $((absorbed * 100)) -ge $((discretionary * 40)) ] \
    || fail "echo rule absorbed $absorbed of $discretionary discretionary wakes, under 40%"
  pass "replay of a secondmate log mirroring a real one: every milestone still wakes and at least 40% of discretionary wakes are absorbed ($absorbed of $discretionary; $new of $appends appends still wake)"
}

test_ack_echo_shapes
test_milestones_are_never_echoes
test_span_absorbs_only_all_echo_secondmate_spans
test_unread_surface_admits_secondmate_echoes_only
test_replay_real_secondmate_log
