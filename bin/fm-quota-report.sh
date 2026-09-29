#!/usr/bin/env bash
# fm-quota-report.sh - quota-axi windows joined with firstmate's own per-model
# dispatch history, across this home and every registered secondmate.
#
# Usage:
#   fm-quota-report.sh [--json] [--home DIR]
#
# --json prints one fm-quota-report.v1 object, the shape the bearings board's
# optional `quota` field carries and the /quota skill renders standalone.
# Default output is a plain table.
#
# QUOTA WINDOWS. Read from `quota-axi --json` (gated by bin/fm-quota-axi-lib.sh's
# version floor and schema validator, exactly as dispatch routing gates it - see
# `quota-axi --help` for the tool's own contract, never memorised here). Each
# provider's quotaSemantics.effectiveAvailability[] entry becomes one window
# row: percent remaining, the limiting raw window's reset time (joined from
# that provider's windows[] by runway.limitingWindowId), runway status, spend
# priority, and projection confidence - the same fields quota-axi's own
# default TOON `quota` table reports, passed through under quota-axi's own
# field names. A provider whose state is not fresh (auth_required, stale,
# unavailable - the tool's own state.status vocabulary) or whose scope status
# is "unknown" becomes an attention row, verbatim from quota-axi's own fields;
# nothing here is reclassified or invented.
#
# DISPATCH STATS. Source: this home's fleet activity ledger
# (docs/fleet-ledger.md), when config/fleet-ledger is present. Ledger events
# are joined by task id: task.dispatched gives harness+model, task.cleaned_up
# (or "still open") bounds run time, task.merged with via=pr counts a shipped
# PR, and task.status with state=failed counts a failure. A relaunch of an
# existing task writes no fresh task.dispatched record (the ledger's own
# contract - docs/fleet-ledger.md), so relaunches are not separately counted;
# that limitation is disclosed once in `dispatch.gaps`, never estimated.
# `tasks-axi add --help` and `tasks-axi done --help` confirm backlog rows
# record no harness or model field, so Done rows are not a usable per-model
# join key and are not read here; bin/fm-spend-report.sh's aggregation is by
# token spend, not dispatch/PR/failure counts, so it is not extended either -
# both were checked before this script was written.
#
# Every registered secondmate home is read the same way
# bin/fm-bearings-snapshot.sh's snapshot reads secondmate state
# (bin/fm-fleet-snapshot.sh's secondmate_current.records is that registry):
# a local home's state/fleet-ledger.jsonl is read directly off disk; a remote
# home's is fetched with `fm-on.sh <id> fm-remote-file.sh get
# state/fleet-ledger.jsonl <max-bytes>` - the same bounded single-file remote
# read fm-fleet-snapshot.sh uses for state/home-summary.json. A home with no
# ledger file (the flag was never turned on, or the fetch failed) contributes
# no dispatch rows and is named in `dispatch.gaps`.
#
# When THIS home's own ledger is off, state/*.meta (harness/model of the
# currently live tasks only, no history) is read as a labelled fallback so the
# panel still shows something live; secondmate homes get no such fallback,
# because their state/*.meta cannot be listed through the remote single-file
# read path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-quota-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

SCHEMA=fm-quota-report.v1
JSON_OUT=0
HOME_ARG=

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT=1 ;;
    --home) shift; HOME_ARG=${1-} ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-quota-report: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

FM_HOME="${HOME_ARG:-${FM_HOME:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

command -v jq >/dev/null 2>&1 || { echo "fm-quota-report: jq is required" >&2; exit 1; }

fail() {
  printf 'fm-quota-report: %s\n' "$*" >&2
  exit 1
}

# --- quota-axi windows + attention -------------------------------------------

command -v quota-axi >/dev/null 2>&1 || fail "quota-axi is not installed"
fm_quota_axi_compatible \
  || fail "quota-axi is missing or older than the required floor $FM_QUOTA_AXI_MIN"

QUOTA_JSON=$(quota-axi --json 2>/dev/null) || fail "quota-axi --json failed"
fm_quota_json_valid <<< "$QUOTA_JSON" || fail "quota-axi --json did not satisfy the compatibility floor's schema"

# shellcheck disable=SC2016  # jq program text, not shell expansion
QUOTA_JOIN_JQ='
  def window_row:
    . as $p
    | $p.quotaSemantics.effectiveAvailability[]? as $ea
    | ($ea.runway.limitingWindowId // ($ea.limitingWindowIds // [] | first)) as $lwid
    | ($p.windows[]? | select(.id == $lwid) | .resetsAt) as $resets
    | {
        provider: $p.provider,
        account: ($p.accountKey // null),
        scope: $ea.scope,
        percentRemaining: ($ea.effectivePercentRemaining // null),
        resetsAt: ($resets // null),
        runway: ($ea.runway.status // "unknown"),
        spendPriority: ($ea.selection.spendPriority // null),
        confidence: ($ea.runway.projectionConfidence // null)
      };
  def attention_rows:
    . as $p
    | (
        (if ($p.state.status // "fresh") != "fresh"
         then [{
                provider: $p.provider,
                account: ($p.accountKey // null),
                scope: "all",
                kind: $p.state.status,
                detail: ($p.state.error // null)
              }]
         else [] end)
        +
        [ $p.quotaSemantics.effectiveAvailability[]?
          | select(.status == "unknown")
          | {
              provider: $p.provider,
              account: ($p.accountKey // null),
              scope: .scope,
              kind: "unmeasurable",
              detail: null
            } ]
      )[];
  {
    windows: [.providers[] | window_row],
    attention: [.providers[] | attention_rows],
    notSetUp: [.providers[] | select(.notSetUp == true) | .provider]
  }
'
QUOTA_PARTS=$(jq -c "$QUOTA_JOIN_JQ" <<< "$QUOTA_JSON") || fail "cannot join quota-axi windows"

# --- dispatch stats: this home's own ledger, then every secondmate ----------

NOW_EPOCH=$(date +%s)
LEDGER_POOL="$FM_ROOT/.quota-report-ledger-pool.$$"
: > "$LEDGER_POOL"
trap 'rm -f "$LEDGER_POOL"' EXIT

HOMES_JSON='[]'
add_home_status() {  # <id> <status>
  HOMES_JSON=$(jq -c --argjson h "$HOMES_JSON" --arg id "$1" --arg status "$2" \
    '$h + [{id:$id,status:$status}]' <<< null)
}

read_home_ledger() {  # <id> <ledger-file>
  local id=$1 file=$2
  if [ -s "$file" ]; then
    jq -c --arg home "$id" '. + {home:$home}' "$file" >> "$LEDGER_POOL" 2>/dev/null || true
    add_home_status "$id" ledger
  else
    add_home_status "$id" no-ledger
  fi
}

if [ -f "$CONFIG/fleet-ledger" ]; then
  read_home_ledger "(main)" "$STATE/fleet-ledger.jsonl"
else
  add_home_status "(main)" ledger-disabled
fi

# Currently-live fallback for this home only, used when this home's own
# ledger is off (secondmate state/*.meta cannot be read through the bounded
# remote single-file path, so no equivalent fallback exists for them).
META_FALLBACK='[]'
if [ ! -f "$CONFIG/fleet-ledger" ] && [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    h=$(fm_meta_get "$meta" harness)
    [ -n "$h" ] || continue
    m=$(fm_meta_get "$meta" model)
    [ "$m" != default ] || m=
    META_FALLBACK=$(jq -c --argjson r "$META_FALLBACK" --arg h "$h" --arg m "$m" \
      '$r + [{harness:$h, model:(if $m == "" then null else $m end)}]' <<< null)
  done
fi

REGISTRY_ERROR=
if [ -x "$SCRIPT_DIR/fm-fleet-snapshot.sh" ]; then
  SNAP=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) || SNAP=
else
  SNAP=
fi
if [ -n "$SNAP" ]; then
  MATES=$(jq -c '.secondmate_current.records // [] | .[] | select(.registered != false) | {id, home, host, remote}' <<< "$SNAP" 2>/dev/null) || MATES=
else
  REGISTRY_ERROR="secondmate registry unavailable: bin/fm-fleet-snapshot.sh --json failed"
  MATES=
fi

if [ -n "$MATES" ]; then
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mid=$(jq -r '.id' <<< "$row")
    mhome=$(jq -r '.home' <<< "$row")
    mremote=$(jq -r '.remote' <<< "$row")
    if [ "$mremote" = true ]; then
      tmp="$FM_ROOT/.quota-report-remote.$$.$mid"
      if "$SCRIPT_DIR/fm-on.sh" "$mid" fm-remote-file.sh get state/fleet-ledger.jsonl 1048576 > "$tmp" 2>/dev/null \
        && [ -s "$tmp" ]; then
        read_home_ledger "$mid" "$tmp"
      else
        add_home_status "$mid" no-ledger
      fi
      rm -f "$tmp"
    else
      read_home_ledger "$mid" "$mhome/state/fleet-ledger.jsonl"
    fi
  done <<< "$MATES"
fi

# shellcheck disable=SC2016  # jq program text, not shell expansion
DISPATCH_JOIN_JQ='
  def task_join:
    group_by(.task) as $by_task
    | [ $by_task[] as $evs
        | ($evs | map(select(.event == "task.dispatched")) | sort_by(.ts) | first) as $d
        | if $d == null then empty else
            {
              task: $evs[0].task,
              home: $d.home,
              harness: $d.harness,
              model: $d.model,
              dispatched_ts: $d.ts,
              cleaned_ts: ($evs | map(select(.event == "task.cleaned_up")) | sort_by(.ts) | last | .ts // null),
              merged_pr: ([$evs[] | select(.event == "task.merged" and .via == "pr")] | length),
              failed: ([$evs[] | select(.event == "task.status" and .state == "failed")] | length)
            }
          end
      ];
  def orphan_count:
    group_by(.task)
    | [ .[] | select([.[] | select(.event == "task.dispatched")] | length == 0) ] | length;
  (task_join) as $tasks
  | (orphan_count) as $orphans
  | {
      rows: (
        $tasks
        | group_by([.harness, .model])
        | map({
            harness: .[0].harness,
            model: .[0].model,
            dispatched: length,
            live: ([.[] | select(.cleaned_ts == null)] | length),
            run_seconds: ([.[] | ((.cleaned_ts // $now) - .dispatched_ts)] | add // 0),
            prs_shipped: ([.[] | .merged_pr] | add),
            failures: ([.[] | .failed] | add)
          })
      ),
      orphan_tasks: $orphans
    }
'
if [ -s "$LEDGER_POOL" ]; then
  DISPATCH_JSON=$(jq -cs --argjson now "$NOW_EPOCH" "$DISPATCH_JOIN_JQ" "$LEDGER_POOL") \
    || fail "cannot join fleet-ledger dispatch records"
else
  DISPATCH_JSON='{"rows":[],"orphan_tasks":0}'
fi

GAPS='[]'
add_gap() { GAPS=$(jq -c --argjson g "$GAPS" --arg m "$1" '$g + [$m]' <<< null); }

while IFS= read -r hs; do
  [ -n "$hs" ] || continue
  id=$(jq -r '.id' <<< "$hs")
  status=$(jq -r '.status' <<< "$hs")
  case "$status" in
    ledger-disabled) add_gap "$id: fleet ledger not enabled (config/fleet-ledger absent); dispatch stats unavailable for this home" ;;
    no-ledger) add_gap "$id: fleet ledger file unreadable or empty; dispatch stats unavailable for this home" ;;
  esac
done <<< "$(jq -c '.[]' <<< "$HOMES_JSON")"

ORPHANS=$(jq -r '.orphan_tasks' <<< "$DISPATCH_JSON")
[ "$ORPHANS" -eq 0 ] || add_gap "$ORPHANS ledger task record(s) with no task.dispatched event (ledger enabled after they started); excluded from per-model stats"
[ "$(jq -r '.rows | length' <<< "$DISPATCH_JSON")" -eq 0 ] || add_gap "failures counts task.status state=failed only; a relaunch of an existing task writes no fresh task.dispatched record (docs/fleet-ledger.md), so relaunches are not separately counted"
[ "$(jq -r 'length' <<< "$META_FALLBACK")" -eq 0 ] || add_gap "(main): fleet ledger off; showing currently-live harness/model from state/*.meta only, no run time, dispatch count, PR, or failure history"
[ -z "$REGISTRY_ERROR" ] || add_gap "$REGISTRY_ERROR"

NOTSETUP=$(jq -r '.notSetUp | join(", ")' <<< "$QUOTA_PARTS")
[ -z "$NOTSETUP" ] || add_gap "providers not set up (omitted from windows): $NOTSETUP"

GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

REPORT=$(jq -cn \
  --arg schema "$SCHEMA" \
  --arg generated "$GENERATED" \
  --argjson windows "$(jq -c '.windows' <<< "$QUOTA_PARTS")" \
  --argjson attention "$(jq -c '.attention' <<< "$QUOTA_PARTS")" \
  --argjson dispatch_rows "$(jq -c '.rows' <<< "$DISPATCH_JSON")" \
  --argjson meta_fallback "$META_FALLBACK" \
  --argjson homes "$HOMES_JSON" \
  --argjson gaps "$GAPS" \
  '{
    schema: $schema,
    generated: $generated,
    windows: $windows,
    attention: $attention,
    dispatch: {
      homes: $homes,
      rows: $dispatch_rows,
      live_fallback: $meta_fallback,
      gaps: $gaps
    }
  }')

if [ "$JSON_OUT" -eq 1 ]; then
  printf '%s\n' "$REPORT"
  exit 0
fi

jq -r '
  "quota " + .generated + " (quota-axi windows joined with firstmate dispatch history)",
  "",
  "windows:",
  (.windows[] | "  " + .provider + " " + .scope + "  " + ((.percentRemaining // "unknown") | tostring) + "% left  runway=" + .runway + "  spendPriority=" + ((.spendPriority // "unknown") | tostring) + "  confidence=" + (.confidence // "unknown") + "  resets=" + (.resetsAt // "unknown")),
  (if (.attention | length) > 0 then "", "attention:" else empty end),
  (.attention[] | "  " + .provider + " " + .scope + "  " + .kind + (if .detail then ": " + .detail else "" end)),
  (if (.dispatch.rows | length) > 0 then "", "dispatch (fleet ledger):" else empty end),
  (.dispatch.rows[] | "  " + .harness + " " + (.model // "(default)") + "  dispatched=" + (.dispatched|tostring) + "  live=" + (.live|tostring) + "  run_hours=" + ((.run_seconds/3600) | (. * 10 | round / 10) | tostring) + "  prs_shipped=" + (.prs_shipped|tostring) + "  failures=" + (.failures|tostring)),
  (if (.dispatch.live_fallback | length) > 0 then "", "live (state/*.meta fallback, no ledger):" else empty end),
  (.dispatch.live_fallback[] | "  " + .harness + " " + (.model // "(default)")),
  (if (.dispatch.gaps | length) > 0 then "", "gaps:" else empty end),
  (.dispatch.gaps[] | "  - " + .)
' <<< "$REPORT"
