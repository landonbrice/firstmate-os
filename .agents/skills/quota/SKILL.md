---
name: quota
description: >-
  Show a moment-in-time view of quota-axi's provider windows beside firstmate's own per-harness/model dispatch history (workers dispatched, currently live, run time, PRs shipped, failures).
  Use when the captain invokes /quota or asks for quota status, usage status, model usage, windows left, or how much quota is left.
user-invocable: true
metadata:
  internal: true
---

# quota

`/quota` is the standalone view of the Quota panel that `/bearings lavish` also carries.
Both surfaces are backed by `bin/fm-quota-report.sh --json` (its header owns the join contract: quota-axi's provider windows and attention rows, joined with firstmate's own fleet-activity-ledger dispatch history per harness and model, with every gap disclosed rather than estimated) and the same `quota` field of the `fm-bearings-board.v1` payload (`bin/fm-bearings-board.sh`'s header owns that field's validation and `.agents/skills/bearings/assets/board-template.html` owns its rendering).

## What it does

1. **Reuse the board, never a second one.** The Quota panel lives on the one stable bearings board (`bin/fm-bearings-board.sh path`) and its one Lavish session, exactly as `/bearings lavish` uses it. `/quota` rebuilds that same board in place through the same `bin/fm-bearings-board.sh build` path; it never creates a second board, a second Lavish session, or a second process-event listener. Because a rebuild replaces the whole payload, compose the full board the same way `/bearings lavish` does: gather `snapshot=$(bin/fm-bearings-snapshot.sh --json)` and follow the `bearings` skill's "Lavish board mode" section for Captain's Call, Underway, Recently Landed, and Charted Next, so a `/quota` invocation can never blank out fleet state the captain relies on elsewhere on the board. Also include the optional `spend` field the same way that section does, so a `/quota` rebuild never drops it either.
2. **Add the quota field.** Include the optional `quota` field by embedding the output of `bin/fm-quota-report.sh --json` verbatim; omit it when that command fails (the same fail-open contract `spend` uses).
3. **Run `build` once.** Follow `bin/fm-bearings-board.sh`'s serve-first sequence exactly as the `bearings` skill's Lavish board mode does: publish, establish and verify the Lavish session, bind, then arm.
4. **Reply with the quota view, not the full fleet digest.** The chat reply is short: a compact text rendering of `bin/fm-quota-report.sh`'s own windows/attention/dispatch tables (its default non-`--json` table output is exactly this), plus the board URL from `build`'s output with `#bb-quota-section` appended so the captain lands on the panel directly. Do not also render the full Underway/Landed/Charted digest `/bearings` and `/bearings lavish` render; that stays those commands' output.

## Handling a board wake

A `/quota`-built board answers through the exact same channel as a `/bearings lavish`-built one, because it is the same board and the same Lavish session.
Follow the `bearings` skill's "Handling a board wake" section unchanged; nothing here adds a second wake path.
