# Cimarron Deal Intelligence — firstmate integration plan

Companion to `FIRSTMATE-EVALUATION.md`, narrowed to Cimarron Deal Intelligence with the constraints
confirmed: the code is on **GitHub**, it's a **solo repo** (you own merges), and cloning it locally and
running agents against it is **your call** (no company policy blocker).

## Recommendation: adopt the full distro, hosted in WSL2

Every objection that would have pushed toward a hand-rolled lighter setup is cleared:

| Objection | Status for Cimarron |
| --- | --- |
| Firstmate is GitHub-only (`gh`, `gh-axi`, PR/merge) | **N/A** — Cimarron is on GitHub, so the shipping flow maps directly. |
| It imposes its own review gate that fights team CI | **N/A** — solo repo; you're the only reviewer, so the "you merge" gate *is* your process, not a competing one. |
| Cloning company code + running agents is a policy risk | **Cleared** — it's your call. |

A tailored lighter setup would mostly reimplement what firstmate already does correctly (worktree
isolation, event-driven supervision, the merge gate). With the three blockers gone, that's wasted
effort. **Go with the real thing.** The only real cost left is one-time host setup.

## The one gate to check before anything else: WSL2 must be available

Firstmate is 65 bash scripts + tmux, macOS/Linux only. On Windows it runs **inside WSL2**, not native
Windows. Company-managed Windows machines sometimes have virtualization or the WSL feature disabled by
IT/group policy. **Confirm WSL2 works on this machine first** — if it's locked down, that's a real
blocker and you'd need IT to enable it (or fall back to the Mac Mini for Cimarron too).

Quick check in PowerShell:

```powershell
wsl --status        # or:  wsl --install -d Ubuntu   (needs admin the first time)
```

If that works, the rest is smooth.

## Setup runbook (run on the Windows machine)

Once WSL2 Ubuntu is up, this is identical to the Mac Mini flow. You do **not** hand-install the
toolchain — firstmate detects and installs it for you, with your approval, on first launch.

1. **Inside WSL2 Ubuntu**, install the basics WSL doesn't ship: `git`, `node`, `tmux`, and the GitHub
   CLI `gh`. (Firstmate's startup will also flag anything missing.)
2. `gh auth login` — authenticate to GitHub from inside WSL.
3. Clone firstmate inside WSL (not on the Windows filesystem — keep it under the Linux home `~/` for
   speed and correct permissions):
   ```sh
   git clone <your firstmate fork> ~/firstmate && cd ~/firstmate
   ```
4. Launch your harness inside it: `claude` (you're already comfortable in Claude Code). It reads
   `AGENTS.md` and takes over as the first mate.
5. On first session it runs its own startup check and prints exactly which tools are missing with
   install commands (`treehouse`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, `lavish-axi`,
   `tasks-axi`, `quota-axi`). **Approve the installs.** This is the "download the skills from that guy"
   step — done for you, in WSL. Note: this baseline toolchain is required regardless of how Cimarron
   ships; the delivery mode only changes the shipping step, not the install set.
6. Tell it to bring Cimarron under management — something like *"add my Cimarron Deal Intelligence repo,
   it's at `<owner>/<repo>`, mode direct-PR"*. It clones Cimarron under `projects/` and records it.

## Cimarron's delivery mode: start `direct-PR`, graduate to `no-mistakes` later

- **`direct-PR` (recommended to start).** The agent implements on a branch, pushes, and opens a PR; you
  review and merge. Simple, fits a solo GitHub repo, and you keep a clean audit trail of every change in
  PRs. No extra pipeline overhead beyond the baseline toolchain.
- **`no-mistakes` (consider once you trust the flow).** Adds a full automated review/test/lint/CI gate
  before the PR reaches you. Strongest guardrails — worth it for a deal-intelligence product you don't
  want quietly broken — but it's the heaviest path and assumes the pipeline is set up per project. Move
  Cimarron to this mode after a couple of weeks of `direct-PR` if you want the extra assurance.
- **`local-only`** doesn't apply — Cimarron is on GitHub and you want the PR trail.

Changing modes later is a one-line registry edit; nothing is locked in.

## What day-to-day interaction looks like

This is the payoff and the answer to "integrate into the Cimarron workflow": you stop opening the repo
to do small things yourself and instead talk to one agent.

- **Investigations (scout):** *"Cimarron's deal-scoring endpoint is returning stale numbers — find out
  why."* → you get a written report, no code change.
- **Changes (ship):** *"Add a filter for deal stage to the pipeline view and open a PR."* → you get a PR
  to review and merge.
- **Parallelism:** even with one project, you can have several tasks running at once (a bug fix + a
  perf investigation + a feature) each in its own isolated worktree — that's where the "don't babysit
  tabs" value shows up on a single repo.
- **Supervision is hands-off:** the background watcher pings you only for decisions, review-ready PRs,
  blockers, or failures. Silence means it's working.

## First move after setup: seed Cimarron's memory file

The highest-leverage onboarding artifact is Cimarron's own `AGENTS.md` (`CLAUDE.md` symlinked to it),
created through the normal delivery path on the first task that touches the repo. It should capture:

- Build / test / run / deploy commands.
- The architecture at a glance (services, data sources, the deal-scoring model, the API surface).
- Sharp edges ("needs env var X", "the scoring job runs on cron Y", "don't touch table Z directly").

That file is what makes the agent competent in Cimarron without you re-explaining it every session. Once
you're set up — or if you give me read access to the Cimarron repo here — I can draft this skeleton for
you to review.

## Summary

1. **Confirm WSL2 is enabled** on the Windows machine — the one real gate.
2. Clone firstmate in WSL2, launch Claude Code, approve the toolchain installs.
3. Add Cimarron as a `direct-PR` GitHub project.
4. Let the first real task seed Cimarron's `AGENTS.md`.
5. From then on, talk to the one agent; graduate Cimarron to `no-mistakes` if/when you want the heavier
   guardrails.
