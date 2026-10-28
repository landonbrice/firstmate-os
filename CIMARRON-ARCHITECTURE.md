# Cimarron Deal Intelligence — go-forward architecture and testing

Third companion doc (after `FIRSTMATE-EVALUATION.md` and `CIMARRON-INTEGRATION.md`). This one is the
picture of how the pieces sit together once firstmate is running in WSL2, how they interact on a real
change, and how testing works at every layer.

**Scope boundary:** the first mate that manages Cimarron runs **locally in your WSL2 Ubuntu**, talking
to Claude Code there. The cloud Claude Code session used to produce this evaluation is a separate thing
and is not part of the running architecture below.

## 1. Topology — where everything physically lives

```
Windows host (company machine)
└─ WSL2 · Ubuntu                         the durable Linux home; keep it running while you work
   └─ ~/firstmate/                       the distro — Claude Code runs HERE as the first mate
      ├─ AGENTS.md, bin/, skills/        instructions + tooling (the first mate reads/uses these)
      ├─ data/                           backlog, project registry, briefs, scout reports  (private, on disk)
      ├─ state/                          live fleet signals + the background watcher
      └─ projects/
         └─ cimarron-deal-intelligence/  READ-ONLY clone — the first mate never writes here
                        │
                        │  treehouse cuts a clean, isolated git worktree per task
                        ▼
            per-task worktree  ─────►  crewmate agent in a tmux window  (fm-<taskid>)
                        │                 implements on branch fm/<taskid>, runs Cimarron's tests
                        ▼
                push + open PR (gh)  ─────►  GitHub · <owner>/cimarron-deal-intelligence
                        │                        the PR, plus Cimarron's existing Actions CI
                        ▼
            you review & say "merge it"  ─────►  first mate merges, then tears down the worktree
```

Key properties this buys you:

- **The first mate never touches your Cimarron clone.** It reads it to understand the code; all changes
  happen in disposable worktrees. Your `projects/cimarron-deal-intelligence` checkout stays clean.
- **Every task is isolated.** Two tasks on Cimarron at once = two separate worktrees + two tmux windows;
  they can't step on each other.
- **All state is on disk + in tmux.** Close the laptop, reopen, and the next session reconciles and
  carries on.

## 2. Interaction — the loop on a real change

The whole point is you talk to one agent and it runs this loop for you:

1. **You (chat):** *"Add a deal-stage filter to the pipeline view and open a PR."*
2. **First mate:** resolves that this is Cimarron, classifies it as a *ship* task, writes a brief, and
   spawns a crewmate in a fresh worktree + tmux window.
3. **Crewmate:** creates branch `fm/<taskid>`, implements the change, and **runs Cimarron's own test
   suite in the worktree** as it goes.
4. **Ship (`direct-PR` mode):** crewmate pushes the branch to Cimarron's GitHub `origin` and opens a PR
   with `gh`. Cimarron's existing GitHub Actions CI runs on that PR.
5. **First mate → you:** "PR ready for review — <full URL> — here's a one-paragraph summary." It
   surfaces the diff (via `fm-review-diff.sh`) so you don't have to go digging.
6. **You:** review, say *"merge it."*
7. **First mate:** merges via `gh`, confirms the merge, and tears down the worktree + window.

For *scout* tasks (investigations, audits, "why is X happening") the loop ends at step 3 with a written
report in `data/<taskid>/report.md` that the first mate relays to you — no branch, no PR.

The background watcher runs this whole time at zero token cost and only pings you at the decision points
(PR ready, a blocker, a question the brief didn't answer, a failure). Silence means it's working.

## 3. How testing works — two distinct layers

### Layer A — testing that the *setup itself* works (do this once, before real work)

Prove the machinery end-to-end with throwaway work before you trust it with anything that matters. Run
these in order; each proves one more piece:

1. **Bootstrap health.** Launch the first mate. Its startup check should be clean — no missing tools,
   GitHub authenticated. Fix anything it flags before going further.
2. **Read sanity.** Add Cimarron as a project, then ask *"describe how Cimarron is structured."* If it
   reads the repo and gives an accurate summary, the clone + registry are good.
3. **Scout smoke test.** Ask a trivial investigation: *"summarize how Cimarron's test suite is laid
   out."* Getting a report back proves dispatch → worktree → supervision → report.
4. **Ship smoke test.** Ask for a trivially safe change with no real risk — e.g., *"fix a typo in the
   README"* or *"add a clarifying comment to <file>."* Watch it go worktree → branch → PR → your merge →
   teardown. This proves the **entire ship loop** without touching anything that can break.
5. Only after 1–4 are green, hand it real Cimarron work.

### Layer B — how every Cimarron change gets tested from then on

Testing rides along with the delivery mode you chose (`direct-PR` to start):

- **In the worktree (always):** the crewmate runs Cimarron's own tests as part of implementing. For this
  to work well, Cimarron's `AGENTS.md` must record the exact test/build/run commands (see §4) — that's
  what tells the agent how to test *this* repo.
- **On the PR (GitHub CI):** whatever Actions/checks Cimarron already has run on the PR automatically.
  The first mate reports their status to you and won't present a red PR as ready.
- **Your review (the gate):** in `direct-PR` mode you are the final check — you review the diff and
  merge. Nothing lands without you.
- **If you later switch Cimarron to `no-mistakes` mode:** an automated review → test → lint → CI
  pipeline runs *before* the PR reaches you and attaches its evidence, adding a formal gate on top of
  the above. That's the upgrade path when you want more assurance than "agent ran the tests + I
  reviewed."

The net: a Cimarron change is tested in three places before it's yours to merge — in the worktree, on
GitHub CI, and by you — with an optional fourth (the `no-mistakes` pipeline) when you want it.

## 4. The one dependency to fill: Cimarron's `AGENTS.md`

Layer B's in-worktree testing is only as good as the commands the agent knows. The first real artifact
to create is Cimarron's `AGENTS.md` capturing:

- **Test:** the exact command(s) to run the suite (unit, integration, whatever exists), and how to run a
  single test.
- **Build / run:** how to build and run the app locally.
- **Deploy:** how a change reaches production (so the agent doesn't guess).
- **Architecture + sharp edges:** services, data sources, the deal-scoring model, the API surface, and
  any "don't do X" landmines.
- **Existing CI:** what GitHub Actions already run on PRs (so the agent knows what the PR gate covers).

Until I can see the Cimarron repo, the stack, test commands, and existing CI in §1–§3 are placeholders.
Give me read access to the repo and I'll draft this `AGENTS.md` skeleton for your review; otherwise it
gets seeded on the first real task.

## 5. Summary

- **Topology:** Windows → WSL2 → `~/firstmate` (first mate) → read-only `projects/cimarron…` clone →
  disposable per-task worktrees + tmux windows → GitHub PRs.
- **Interaction:** you chat one agent; it dispatches isolated crewmates, supervises hands-off, and brings
  you PRs or reports to approve.
- **Testing:** first prove the setup with staged smoke tests (health → read → scout → trivial ship);
  then every change is tested in the worktree + on GitHub CI + by your review, with `no-mistakes` as the
  heavier optional gate.
- **Next artifact:** Cimarron's `AGENTS.md` — the file that makes all of the above competent in *your*
  repo specifically.
