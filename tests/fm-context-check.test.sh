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

# --- the primary (--primary / --clear-primary) ---------------------------------
#
# make_primary <name> <tokens> <captain-minutes-ago|none> <start-minutes-ago>:
# fixture home whose session lock names pid 4242, a stub `claude` whose
# `agents --json` maps that pid to a background session, and a transcript
# started <start> minutes ago with one captain message <captain> minutes ago.
make_primary() {
  local name=$1 tokens=$2 captain=$3 start=$4 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/fakehome" "$home/wt" "$home/bin"
  printf '4242\n' > "$home/state/.lock"
  printf 'sid-one\n' > "$home/sid"
  printf 'background\n' > "$home/kind"
  printf 'idle\n' > "$home/status"
  cat > "$home/bin/claude" <<STUB
#!/usr/bin/env bash
case "\$1" in
  agents)
    printf '[{"pid":4242,"id":"bg42","kind":"%s","sessionId":"%s","cwd":"%s","status":"%s"}]\n' \
      "\$(cat "$home/kind")" "\$(cat "$home/sid")" "$home/wt" "\$(cat "$home/status")"
    ;;
  attach)
    while IFS= read -r line; do
      line=\${line%\$'\r'}
      printf '%s\n' "\$line" >> "$home/typed"
      [ "\$line" = /clear ] && printf 'sid-two\n' > "$home/sid"
    done
    ;;
esac
STUB
  chmod +x "$home/bin/claude"
  write_transcript "$home" sid-one "$tokens" "$captain" "$start"
  printf '%s\n' "$home"
}

# write_transcript <home> <sid> <tokens> <captain-minutes-ago|none> <start-minutes-ago> [doorbell-minutes-ago doorbell-text]
write_transcript() {
  local home=$1 dir
  dir="$home/fakehome/.claude/projects/$(printf '%s/wt' "$home" | sed 's#[/.]#-#g')"
  mkdir -p "$dir"
  python3 - "$dir/$2.jsonl" "$3" "$4" "$5" "${6:-}" "${7:-}" <<'PY'
import datetime, json, sys
path, tokens, captain, start, bell_ago, bell = sys.argv[1:7]
now = datetime.datetime.now(datetime.timezone.utc)
ts = lambda m: (now - datetime.timedelta(minutes=float(m))).strftime("%Y-%m-%dT%H:%M:%S.000Z")
rows = [{"type": "attachment", "timestamp": ts(start)}]
if captain != "none":
    rows.append({"type": "user", "origin": {"kind": "human"}, "timestamp": ts(captain), "message": {"role": "user", "content": "captain words"}})
if bell:
    rows.append({"type": "user", "origin": {"kind": "human"}, "timestamp": ts(bell_ago), "message": {"role": "user", "content": bell}})
rows.append({"type": "user", "timestamp": ts(0.5), "message": {"role": "user", "content": "<task-notification>watcher</task-notification>"}})
rows.append({"type": "assistant", "timestamp": ts(0.4), "message": {"role": "assistant", "model": "m", "usage": {"input_tokens": 1, "cache_read_input_tokens": int(tokens) - 1, "cache_creation_input_tokens": 0, "output_tokens": 5}}})
with open(path, "w") as handle:
    handle.writelines(json.dumps(r) + "\n" for r in rows)
PY
}

run_primary() {
  local home=$1
  shift
  PATH="$home/bin:$PATH" HOME="$home/fakehome" FM_HOME="$home" "$CHECK" "$@"
}

FIRE_PREFIX='main-context-high: 250000 > 200000, captain quiet 45m.'

home=$(make_primary pfire 250000 45 120)
out=$(run_primary "$home" --primary) || fail "--primary nonzero exit"
assert_contains "$out" "$FIRE_PREFIX" "over threshold with a quiet captain should fire"
assert_contains "$out" "--clear-primary" "the line names the clear step"
assert_grep 'fired=' "$home/state/.primary-context-reset" "a fired line is recorded"
assert_equals "$(run_primary "$home" --primary)" "" "a fired line must not repeat inside the refire window"
pass "primary: fires once over threshold after a quiet captain"

home=$(make_primary punder 200000 45 120)
assert_equals "$(run_primary "$home" --primary)" "" "exactly at threshold must be silent"
assert_contains "$(run_primary "$home" --primary --threshold 199999)" "main-context-high: 200000 > 199999" "custom threshold"
pass "primary: threshold boundary"

home=$(make_primary pquiet29 250000 29 120)
assert_equals "$(run_primary "$home" --primary)" "" "a captain message 29 minutes ago must hold the reset"
home=$(make_primary pquiet31 250000 31 120)
assert_contains "$(run_primary "$home" --primary)" "captain quiet 31m" "31 quiet minutes clears the 30-minute gate"
home=$(make_primary pquiet60 250000 31 120)
assert_equals "$(run_primary "$home" --primary --quiet-minutes 60)" "" "custom quiet window"
pass "primary: 30-minute captain quiet gate"

home=$(make_primary pbell 250000 45 120)
bell=$(printf 'resume\n' | FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-operational-input.sh" record session-start) \
  || fail "could not write an operational record"
write_transcript "$home" sid-one 250000 45 120 2 "$bell"
assert_contains "$(run_primary "$home" --primary)" "$FIRE_PREFIX" "a verified doorbell is not a captain message"
home=$(make_primary pfake 250000 45 120)
write_transcript "$home" sid-one 250000 45 120 2 ": Firstmate operational input waiting: read '$home/state/operational-inbox/none.msg' and handle its contents as Firstmate operational input."
assert_equals "$(run_primary "$home" --primary)" "" "a doorbell with no record behind it counts as the captain"
home=$(make_primary pnone 250000 none 45)
assert_contains "$(run_primary "$home" --primary)" "$FIRE_PREFIX" "no captain message measures from session start"
home=$(make_primary pfresh 250000 none 5)
assert_equals "$(run_primary "$home" --primary)" "" "a session started 5 minutes ago is not quiet"
pass "primary: captain detection ignores doorbells and falls back to session start"

home=$(make_primary pafk 250000 45 120)
printf 'away\n' > "$home/state/.afk"
assert_equals "$(run_primary "$home" --primary)" "" "away or quiet mode must refuse"
home=$(make_primary pcontract 250000 45 120)
: > "$home/state/.afk-contract"
assert_equals "$(run_primary "$home" --primary)" "" "a pending away contract must refuse"
home=$(make_primary pqueue 250000 45 120)
printf 'row\n' > "$home/state/.wake-queue"
assert_equals "$(run_primary "$home" --primary)" "" "an unacknowledged wake must refuse"
home=$(make_primary pinteractive 250000 45 120)
printf 'interactive\n' > "$home/kind"
assert_equals "$(run_primary "$home" --primary)" "" "a non-background primary is unsupported and silent"
home=$(make_primary pnolock 250000 45 120)
rm "$home/state/.lock"
assert_equals "$(run_primary "$home" --primary)" "" "no session lock is silent"
pass "primary: refusal cases are silent"

home=$(make_primary pclearnofire 250000 45 120)
out=$(run_primary "$home" --clear-primary) && fail "--clear-primary without a fired line must fail"
assert_contains "$out" "refused: no main-context-high line fired" "clear needs a fired line"
home=$(make_primary pclearafk 250000 45 120)
run_primary "$home" --primary >/dev/null
printf 'quiet\n' > "$home/state/.afk"
out=$(run_primary "$home" --clear-primary) && fail "--clear-primary in away mode must fail"
assert_contains "$out" "refused: away or quiet mode is active" "clear refuses in away mode"
pass "primary: clear refusals"

# wait_log <home> <pattern>: the detached clearer's outcome line.
wait_log() {
  for _ in $(seq 1 100); do
    grep -q "$2" "$1/state/.primary-context-reset.log" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "clearer log never matched '$2': $(cat "$1/state/.primary-context-reset.log" 2>/dev/null)"
}

home=$(make_primary pclear 250000 45 120)
run_primary "$home" --primary >/dev/null
out=$(FM_PRIMARY_CLEAR_SETTLE=0.3 FM_PRIMARY_CLEAR_POLL=0.1 run_primary "$home" --clear-primary) \
  || fail "--clear-primary should schedule: $out"
assert_contains "$out" "scheduled: clearing bg42 once idle" "clear schedules a detached clearer"
wait_log "$home" 'cleared: bg42 sid-one -> sid-two'
assert_equals "$(head -n 1 "$home/typed")" "/clear" "the clearer types /clear first"
bell=$(sed -n 2p "$home/typed")
assert_contains "$bell" ": Firstmate operational input waiting: read '" "then a resume doorbell"
assert_equals "$(printf '%s' "$bell" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" "session-start" "the doorbell is record-backed"
assert_grep 'cleared_to=sid-two' "$home/state/.primary-context-reset" "the rotation is recorded"
pass "primary: clear types /clear then a record-backed doorbell and records the rotation"

home=$(make_primary pbusy 250000 45 120)
run_primary "$home" --primary >/dev/null
printf 'busy\n' > "$home/status"
FM_PRIMARY_CLEAR_WAIT=1 FM_PRIMARY_CLEAR_POLL=0.1 run_primary "$home" --clear-primary >/dev/null \
  || fail "clear should schedule while busy"
wait_log "$home" 'refused: session is busy'
assert_absent "$home/typed" "nothing may be typed into a busy session"
pass "primary: the clearer never types into a busy session"
