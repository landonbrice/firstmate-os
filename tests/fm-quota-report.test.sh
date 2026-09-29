#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-report.sh: quota-axi window/attention join,
# fleet-ledger dispatch aggregation by harness+model, the state/*.meta live
# fallback when the ledger is off, and disclosed gaps.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-quota-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-report)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A quota-axi stub reproducing the shapes verified against the real binary:
# --version for fm_quota_axi_compatible's floor check, --json with one
# provider that has a known scope (claude/all_models), one unmeasurable scope
# (agy/gemini, status unknown), and one auth-needed provider (cursor).
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/config" "$home/data"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.55\n'; exit 0 ;;
  --json)
    cat <<'JSON'
{
  "generatedAt": "2026-09-29T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [{"id": "five_hour", "resetsAt": "2026-09-29T10:00:00Z"}],
      "state": {"status": "fresh", "stale": false},
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 66,
         "runway": {"status": "projected_exhaustion", "limitingWindowId": "five_hour", "projectionConfidence": "established"},
         "selection": {"status": "known", "spendPriority": -0.2}}
      ]}
    },
    {
      "provider": "cursor",
      "windows": [],
      "state": {"status": "auth_required", "stale": false, "error": "Cursor sign-in required"},
      "quotaSemantics": {"status": "unknown", "effectiveAvailability": [
        {"scope": "all_models", "status": "unknown"}
      ]},
      "notSetUp": true
    },
    {
      "provider": "agy",
      "windows": [{"id": "gemini_weekly", "resetsAt": "2026-10-05T00:00:00Z"}],
      "state": {"status": "fresh", "stale": false},
      "quotaSemantics": {"status": "partial", "effectiveAvailability": [
        {"scope": "gemini", "status": "unknown"}
      ]}
    }
  ]
}
JSON
    exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$home"
}

run_report() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$REPORT" "$@"
}

test_windows_and_attention_join() {
  local home json
  home=$(make_home windows)
  json=$(run_report "$home" --json) || fail "report exited non-zero: $json"
  assert_equals "$(jq -r .schema <<<"$json")" fm-quota-report.v1 "schema"
  assert_equals "$(jq -r '.windows[] | select(.provider=="claude") | .percentRemaining' <<<"$json")" 66 "known window carries percentRemaining"
  assert_equals "$(jq -r '.windows[] | select(.provider=="claude") | .resetsAt' <<<"$json")" "2026-09-29T10:00:00Z" "resetsAt is joined from the limiting window id"
  assert_equals "$(jq -r '.windows[] | select(.provider=="claude") | .spendPriority' <<<"$json")" -0.2 "spendPriority passes through"
  assert_equals "$(jq -r '[.attention[] | select(.provider=="cursor" and .kind=="auth_required")] | length' <<<"$json")" 1 "auth-needed provider becomes an attention row"
  assert_equals "$(jq -r '[.attention[] | select(.provider=="agy" and .kind=="unmeasurable")] | length' <<<"$json")" 1 "unknown-status scope becomes an unmeasurable attention row"
  assert_contains "$(jq -r '.dispatch.gaps | join("\n")' <<<"$json")" "providers not set up" "not-set-up providers are disclosed as a gap"
  pass "quota-axi windows and attention rows join correctly"
}

test_dispatch_ledger_aggregation() {
  local home json
  home=$(make_home ledger)
  : > "$home/config/fleet-ledger"
  cat > "$home/state/fleet-ledger.jsonl" <<'EOF'
{"v":1,"ts":1000,"event":"task.dispatched","task":"t1","kind":"ship","project":"webapp","harness":"claude","model":"claude-sonnet-5"}
{"v":1,"ts":1100,"event":"task.pr_ready","task":"t1","pr":"https://github.com/o/r/pull/1"}
{"v":1,"ts":1200,"event":"task.merged","task":"t1","via":"pr","pr":"https://github.com/o/r/pull/1"}
{"v":1,"ts":1210,"event":"task.cleaned_up","task":"t1"}
{"v":1,"ts":2000,"event":"task.dispatched","task":"t2","kind":"ship","project":"webapp","harness":"claude","model":"claude-sonnet-5"}
{"v":1,"ts":2050,"event":"task.status","task":"t2","state":"failed","key":null,"text":"bad"}
{"v":1,"ts":3000,"event":"task.status","task":"orphan1","state":"working","key":null,"text":"pre-ledger task"}
EOF
  json=$(run_report "$home" --json) || fail "report exited non-zero: $json"
  row() { jq -r --arg h "$1" --arg m "$2" --arg f "$3" '[.dispatch.rows[] | select(.harness==$h and .model==$m)][0][$f]' <<<"$json"; }
  assert_equals "$(row claude claude-sonnet-5 dispatched)" 2 "two dispatches for claude/claude-sonnet-5"
  assert_equals "$(row claude claude-sonnet-5 live)" 1 "one still live (no cleaned_up)"
  assert_equals "$(row claude claude-sonnet-5 prs_shipped)" 1 "one merged-via-pr counted"
  assert_equals "$(row claude claude-sonnet-5 failures)" 1 "one failed status counted"
  assert_contains "$(jq -r '.dispatch.gaps | join("\n")' <<<"$json")" "no task.dispatched event" "the orphan status-only task is disclosed as a gap"
  assert_contains "$(jq -r '.dispatch.gaps | join("\n")' <<<"$json")" "relaunches are not separately counted" "the relaunch limitation is disclosed"
  pass "fleet-ledger dispatch stats aggregate by harness and model"
}

test_meta_fallback_when_ledger_disabled() {
  local home json
  home=$(make_home fallback)
  cat > "$home/state/t1.meta" <<'EOF'
harness=codex
model=gpt-5.1-codex
kind=ship
EOF
  json=$(run_report "$home" --json) || fail "report exited non-zero: $json"
  assert_equals "$(jq -r '.dispatch.live_fallback[0].harness' <<<"$json")" codex "meta fallback reports the live harness"
  assert_equals "$(jq -r '.dispatch.live_fallback[0].model' <<<"$json")" gpt-5.1-codex "meta fallback reports the live model"
  assert_contains "$(jq -r '.dispatch.gaps | join("\n")' <<<"$json")" "fleet ledger off" "the fallback source is disclosed as a gap"
  assert_equals "$(jq -r '.dispatch.rows | length' <<<"$json")" 0 "no ledger-derived rows when the ledger is disabled"
  pass "state/*.meta is used as a disclosed live-only fallback when the ledger is off"
}

test_windows_and_attention_join
test_dispatch_ledger_aggregation
test_meta_fallback_when_ledger_disabled
