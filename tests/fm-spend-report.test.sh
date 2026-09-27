#!/usr/bin/env bash
# Behavior tests for bin/fm-spend-report.sh: per agent kind x model x trigger
# aggregation, dedup of resumed transcripts, window filtering, list pricing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-spend-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-spend-report)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

HOME_DIR="$TMP_ROOT/fmhome"
PROJECTS="$TMP_ROOT/projects"
mkdir -p "$HOME_DIR/data" "$PROJECTS"
printf -- '- mate - charter (home: %s/mate-home; scope: x)\n' "$TMP_ROOT" > "$HOME_DIR/data/secondmates.md"

# Fixture transcripts. Fable 5.1 usage: 100 input, 1000 1h cache write, 10000
# cache read, 50 output -> $10/MTok in, 2x write, 0.025x read, $50/MTok out:
# (100*10 + 1000*20 + 10000*0.25 + 50*50)/1e6 = 0.026.
python3 - "$PROJECTS" "$HOME_DIR" "$TMP_ROOT" <<'PY'
import json, os, re, sys
projects, home, tmp = sys.argv[1:4]
enc = lambda p: re.sub(r"[^A-Za-z0-9-]", "-", p)
def usage(): return {"input_tokens": 100, "cache_read_input_tokens": 10000, "cache_creation_input_tokens": 1000,
                     "cache_creation": {"ephemeral_1h_input_tokens": 1000}, "output_tokens": 50}
def user(uuid, ts, text, meta=False):
    return {"type": "user", "uuid": uuid, "timestamp": ts, "isMeta": meta, "message": {"role": "user", "content": text}}
def asst(mid, ts, text, model="claude-fable-5-1"):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": model, "usage": usage(), "content": [{"type": "text", "text": text}]}}
def write(dirname, name, recs):
    d = os.path.join(projects, dirname); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w") as f:
        for r in recs: f.write(json.dumps(r) + "\n")
T = "2026-09-25T10:00:00Z"
primary = [
    user("u1", T, "hello captain"), asst("m1", T, "ok"),
    user("u2", T, "<task-notification>done</task-notification>"), asst("m2", T, "PR https://x/1 is ready"),
    user("u3", T, "<task-notification>done</task-notification>"), asst("m3", T, "shipshape"),
    user("u4", T, "Stop hook feedback: keep going", meta=True), asst("m4", T, "continuing"),
    user("u5", "2026-09-20T10:00:00Z", "old captain message"), asst("m5", "2026-09-20T10:00:00Z", "old"),
]
write(enc(home), "a.jsonl", primary)
# A resumed session copies history: the same uuids/ids must not count twice.
write(enc(home), "b.jsonl", primary[:2] + [user("u6", T, "later"), asst("m6", T, "later reply", "claude-opus-5-5")])
write(enc(tmp + "/mate-home"), "c.jsonl", [user("s1", T, "<task-notification>x</task-notification>"), asst("s2", T, "relay")])
write("-Users-x--treehouse-proj-1-proj", "d.jsonl", [user("w1", T, "brief"), asst("w2", T, "work", "claude-sonnet-5")])
write("-Users-x-unrelated-project", "e.jsonl", [user("z1", T, "not fleet"), asst("z2", T, "ignored")])
PY

JSON=$("$REPORT" --json --home "$HOME_DIR" --projects-dir "$PROJECTS" --from 2026-09-25T00:00 --to 2026-09-26T00:00) \
  || fail "report exited non-zero"

row() {  # <kind> <model> <trigger> <field>
  printf '%s' "$JSON" | jq -r --arg k "$1" --arg m "$2" --arg t "$3" --arg f "$4" \
    '[.rows[] | select(.kind==$k and .model==$m and .trigger==$t)][0][$f] // "absent"'
}

assert_equals "$(printf '%s' "$JSON" | jq -r .schema)" fm-spend-report.v1 "schema"
assert_equals "$(row primary claude-fable-5-1 captain calls)" 1 "captain calls (resumed copy deduped, old turn windowed out)"
assert_equals "$(row primary claude-fable-5-1 notification calls)" 1 "notification calls"
assert_equals "$(row primary claude-fable-5-1 acknowledgement calls)" 1 "shipshape notification is an acknowledgement"
assert_equals "$(row primary claude-fable-5-1 forced calls)" 1 "stop-hook feedback is forced"
assert_equals "$(row primary claude-opus-5-5 captain calls)" 1 "a second model gets its own row"
assert_equals "$(row primary claude-fable-5-1 captain context_tokens)" 11100 "context = input + writes + reads"
assert_equals "$(row primary claude-fable-5-1 captain usd)" 0.03 "list dollars (0.026 rounded)"
assert_equals "$(row secondmate claude-fable-5-1 notification calls)" 1 "secondmate home from data/secondmates.md"
assert_equals "$(row worker claude-sonnet-5 captain calls)" 1 "treehouse dir is a worker"
assert_equals "$(printf '%s' "$JSON" | jq '[.rows[] | select(.kind != "primary" and .kind != "secondmate" and .kind != "worker")] | length')" 0 "unrelated projects are excluded"
assert_equals "$(printf '%s' "$JSON" | jq -r '.unmeasured | keys | join(",")')" agy,codex "codex and agy reported unmeasured"
assert_contains "$("$REPORT" --home "$HOME_DIR" --projects-dir "$PROJECTS" --from 2026-09-25T00:00 --to 2026-09-26T00:00)" "codex: unmeasured" "table names unmeasured harnesses"
pass "spend report aggregates by kind, model and trigger"
