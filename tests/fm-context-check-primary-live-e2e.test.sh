#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for `fm-context-check.sh --primary` and
# `--clear-primary`. Every signal those modes read is emitted by Claude Code:
# the `claude agents --json` fields that map the session-lock pid to a
# background session, the transcript's usage and origin.kind=human records, and
# the sessionId rotation that `/clear` typed through `claude attach` produces.
# This starts one disposable haiku background session in this worktree (which
# must already be a trusted Claude workspace), points an isolated FM state
# directory's lock at it, and proves each signal end to end, then stops and
# removes that session. No live fleet home or session is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRIMARY_CLEAR_LIVE_E2E claude python3

CHECK="$ROOT/bin/fm-context-check.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-primary-clear-live)
mkdir -p "$LAB/state"
BG_ID=

cleanup() {
  [ -z "$BG_ID" ] && return 0
  claude stop "$BG_ID" >/dev/null 2>&1
  claude rm "$BG_ID" >/dev/null 2>&1
}
trap cleanup EXIT

vfail() { fail "$1 [claude $CLAUDE_VERSION]"; }

# agent_field <field>: one field of the disposable session's agents entry.
agent_field() {
  claude agents --json | python3 -c 'import json,sys
for e in json.load(sys.stdin):
    if e.get("id") == sys.argv[1]:
        print(e.get(sys.argv[2], ""))' "$BG_ID" "$1"
}

run_check() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" "$CHECK" "$@"
}

out=$(cd "$ROOT" && claude --bg --model claude-haiku-4-5 --setting-sources user \
  --settings "{\"claudeMdExcludes\":[\"$ROOT/CLAUDE.md\",\"$ROOT/AGENTS.md\"]}" \
  "Reply with the single word ok." < /dev/null 2>&1)
BG_ID=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f]*\)$/\1/p' | head -n 1)
[ -n "$BG_ID" ] || vfail "claude --bg did not print a backgrounded id (is $ROOT a trusted workspace?): $out"

for _ in $(seq 1 60); do
  [ "$(agent_field status)" = idle ] && [ -n "$(agent_field sessionId)" ] && break
  sleep 2
done
[ "$(agent_field status)" = idle ] || vfail "background session $BG_ID never reported status idle"
[ "$(agent_field kind)" = background ] || vfail "claude agents --json does not report kind=background for $BG_ID"
agent_field pid > "$LAB/state/.lock"
OLD_SID=$(agent_field sessionId)
pass "claude agents --json maps the lock pid to an idle background session"

assert_equals "" "$(run_check --primary --threshold 1 --quiet-minutes 5)" \
  "the --bg prompt must count as a captain message (origin.kind=human) and hold the reset"
out=$(run_check --primary --threshold 1 --quiet-minutes 0)
assert_contains "$out" "main-context-high: " "a measured transcript over threshold should fire [claude $CLAUDE_VERSION]"
pass "the check measures the session and reads the captain's typed prompt"

out=$(FM_PRIMARY_CLEAR_WAIT=120 run_check --clear-primary --quiet-minutes 0) || vfail "clear refused: $out"
for _ in $(seq 1 120); do
  grep -q '^.* \(cleared\|failed\|refused\):' "$LAB/state/.primary-context-reset.log" 2>/dev/null && break
  sleep 1
done
log=$(cat "$LAB/state/.primary-context-reset.log" 2>/dev/null)
assert_contains "$log" "cleared: $BG_ID $OLD_SID -> " "typing /clear through claude attach should rotate the sessionId [claude $CLAUDE_VERSION]"
NEW_SID=$(agent_field sessionId)
assert_not_equals "$OLD_SID" "$NEW_SID" "the session id must rotate"
pass "/clear typed through claude attach rotates the session"

NEW_LOG="$HOME/.claude/projects/$(printf '%s' "$ROOT" | sed 's#[/.]#-#g')/$NEW_SID.jsonl"
for _ in $(seq 1 30); do
  grep -q 'Firstmate operational input waiting' "$NEW_LOG" 2>/dev/null && break
  sleep 1
done
bell=$(python3 - "$NEW_LOG" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    o = json.loads(line)
    c = (o.get("message") or {}).get("content")
    if o.get("type") == "user" and isinstance(c, str) and "Firstmate operational input waiting" in c:
        print(json.dumps(o.get("origin")))
        print(c.strip())
        break
PY
)
assert_equals '{"kind": "human"}' "$(printf '%s\n' "$bell" | head -n 1)" \
  "a doorbell typed through attach is recorded as origin.kind=human, which the check must exclude [claude $CLAUDE_VERSION]"
bell_text=$(printf '%s\n' "$bell" | sed -n 2p)
assert_equals session-start "$(printf '%s' "$bell_text" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" \
  "the typed doorbell must verify as a record-backed session-start input: $bell_text"
pass "the resume doorbell reaches the fresh conversation and verifies as Firstmate input"
