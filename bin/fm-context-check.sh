#!/usr/bin/env bash
# Print one `context-high: <id> <tokens> > <threshold>` line when a Claude-harness task's
# live per-call context is over the threshold; print nothing otherwise. Always exits 0.
# Usage: fm-context-check.sh <task-id> [--threshold N]   (default 200000)
# Checked by default only when state/<id>.meta says kind=secondmate; a present
# state/<id>.context-check file opts any other task in. Non-claude harnesses and a
# missing transcript are silent. Measurement reuses claude_context() from
# fm_bridge_snapshot.py. To run it on the watcher's slow poll, write a state/<id>.check.sh
# shim that execs this script by absolute path and bind it with fm-check-register.sh
# (recipe: docs/agent-control.md "Context reset for a long-lived secondmate").
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:-}
THRESHOLD=200000
if [ "${2:-}" = "--threshold" ]; then THRESHOLD=${3:-200000}; fi
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
case "$THRESHOLD" in ''|*[!0-9]*) exit 0 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || exit 0
meta_get() { sed -n "s/^$1=//p" "$META" | head -n 1; }
[ "$(meta_get harness)" = "claude" ] || exit 0
if [ "$(meta_get kind)" != "secondmate" ] && [ ! -f "$STATE/$ID.context-check" ]; then exit 0; fi

python3 - "$SCRIPT_DIR" "$ID" "$THRESHOLD" "$(meta_get worktree)" "$(meta_get home)" <<'PY' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1])
import fm_bridge_snapshot as snap
task_id, threshold = sys.argv[2], int(sys.argv[3])
paths = []
for p in sys.argv[4:]:
    if p and p not in paths:
        paths.append(p)
context, _tokens, _source = snap.claude_context(paths)
if context and context["current_tokens"] > threshold:
    print(f"context-high: {task_id} {context['current_tokens']} > {threshold}")
PY
exit 0
