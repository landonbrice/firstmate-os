#!/usr/bin/env bash
# fm-spend-report.sh - read-only spend report by agent kind, model and trigger class.
#
# Usage:
#   fm-spend-report.sh [--json] [--hours N] [--from YYYY-MM-DDTHH:MM --to YYYY-MM-DDTHH:MM]
#                      [--home DIR] [--projects-dir DIR]
#
# Reads Claude transcripts under ~/.claude/projects and prints calls, raw
# tokens (input + cache writes + cache reads = context, plus output) and list
# dollars per agent kind (primary, secondmate, worker, pipeline) x model x
# trigger class (captain, notification, acknowledgement, forced). Default
# window is the last 24 hours. `--json` prints one fm-spend-report.v1 object,
# the shape the bearings board's optional `spend` field carries.
# Acknowledgement is a notification turn whose final text says "shipshape" in
# under 400 characters. Codex and agy sessions are reported as unmeasured.
# Dollars are Anthropic list prices, not an invoice.
# The pipeline row is only the Claude-transcript slice of the window; durable
# per-task no-mistakes spend across every agent is bin/fm-pipeline-spend.sh's.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac
exec python3 "$SCRIPT_DIR/fm_spend_report.py" "$@"
