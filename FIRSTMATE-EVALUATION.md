# Firstmate evaluation — adapting it as a project-managing agent for Cimarron Deal Intelligence and baseball

**Question asked:** Is this repo the right way to get to a workflow where I mostly talk to a single
project-managing agent, and how do I point it at my other projects (Cimarron Deal Intelligence,
baseball)?

**Short answer:** Yes — the model this repo implements *is* exactly "talk to one agent, it runs the
work for you across several projects." It is the most complete implementation of that idea I've seen.
The catch is that it is heavyweight and opinionated, and it assumes a long-lived machine to run on.
For two personal projects you have a real choice between adopting the whole distro or lifting the
handful of ideas that actually carry the value. Both paths are laid out below.

---

## 1. What this repo actually is

Firstmate is not an app, a model, or a plugin. It is an **agent distro**: a directory of instructions
(`AGENTS.md`), skills, helper scripts (`bin/`), and on-disk state conventions that, when you launch a
coding agent (Claude Code, Grok, Pi, Codex, or OpenCode) *inside the directory*, turns that agent into
a fleet manager — the "first mate." You are the "captain."

The core loop:

- **You talk to one agent.** You never juggle terminals. You send requests, decisions, and "merge it."
- **It delegates every project change to a disposable worker** ("crewmate") running in its own visible
  session (a tmux window by default) and its own clean git worktree, so parallel work on one repo never
  collides.
- **It supervises the fleet with a zero-token background watcher** that wakes the manager only when
  something is actionable, and hands you back finished PRs, approved local merges, or investigation
  reports.
- **It is read-only over your projects.** The manager itself never edits your code; workers do, and
  nothing lands without your merge approval (unless you explicitly opt a project into autonomy).

Two task shapes:

- **Ship** — produce a change (ends in a PR or an approved local merge).
- **Scout** — investigate / plan / reproduce a bug / audit (ends in a written report, never a PR).

Three per-project delivery modes let you dial rigor:

| Mode | What happens | Good for |
| --- | --- | --- |
| `no-mistakes` | Full validation pipeline → PR → your merge. Highest assurance. | A product you care about breaking. |
| `direct-PR` | Push + open a PR, no pipeline → your merge. | Normal solo work with review. |
| `local-only` | Local branch, no remote/PR; manager shows you the diff, you approve, it fast-forwards local `main`. | Experiments, private repos, throwaway. |

An optional `+yolo` flag per project lets the manager approve routine merges itself (destructive /
irreversible / security-sensitive things still escalate to you).

**Optional layers you can ignore at first:** persistent "secondmates" (domain sub-managers for large
fleets), dispatch profiles (route certain tasks to certain models/harnesses), and "X mode" (answer your
public `@myfirstmate` mentions). None of these are needed for two projects.

---

## 2. How well it fits your stated goal

Your goal — *"interact mostly with a project-managing agent"* — is literally this repo's thesis
("Talk to one agent. Ship with a crew."). On fit alone it is a bullseye:

- **Multi-project is native.** Cimarron and baseball become two flat clones under `projects/` with one
  registry line each. You address either one just by describing the work; the manager resolves which
  project you mean.
- **Low babysitting.** The event-driven watcher means you are not watching progress bars — you get
  pinged only for decisions, blockers, review-ready work, or failures.
- **Restart-proof.** All state is on disk + in the session backend. Kill the session, the next one
  reconciles and carries on.
- **Safety rails you'd otherwise have to invent.** Read-only-over-projects, isolated worktrees, and a
  hard merge-approval gate are exactly the guardrails that make "let an agent run my projects" tolerable.

So the *interaction model* is right. The open question is not fit — it's **cost**.

---

## 3. The real cost of adopting the whole distro

Be honest with yourself about three things before committing to the full distro:

### 3a. It wants a durable host — this environment is the wrong place to run it long-term
Firstmate assumes a **long-lived home**: a machine where tmux and the agent stay running so the watcher
can sleep on the fleet and workers can keep going between your messages. The remote/web session you're
reading this in is **ephemeral** — the container is reclaimed after inactivity. That's fine for
*evaluating* the repo (what we're doing now), but the actual first-mate should live on:

- your Mac or Linux laptop/desktop, or
- a small always-on VM you keep tmux + the harness running in.

This is the single biggest practical decision. Don't stand up the fleet here and expect it to persist.

### 3b. A non-trivial toolchain, some of it custom
The manager checks its toolchain at every session start and offers to install what's missing. The
**universal** required set (from `docs/configuration.md`):

- `node`, `git`, `gh` (with `gh auth login`)
- `tmux` + `treehouse` (the worktree pool) for the default backend
- `no-mistakes` (the validation pipeline, v1.31.2+)
- `gh-axi`, `chrome-devtools-axi`, `lavish-axi` (GitHub / browser / rich-review helpers)
- `tasks-axi` (backlog), `quota-axi` (dispatch quota)

Several of these (`treehouse`, `no-mistakes`, the `*-axi` family) are the author's own tools installed
via `npm -g` or a curl script — not things you already have. Expect ~30–45 minutes of one-time install
+ auth before the first real dispatch. The manager walks you through it and won't install anything
without your yes, but it is real setup.

### 3c. It's opinionated and large
`AGENTS.md` is ~93KB of policy. You don't have to read it — the agent does — but adopting the distro
means adopting its whole worldview (task ids, briefs, worktrees, teardown, project modes, the merge
gate). That rigidity is a feature when you want guardrails and a tax when you just want to move fast on
a hobby repo.

---

## 4. Two honest paths

### Path A — Adopt firstmate as-is
Best if you want the full guardrails, expect to run 2+ tasks in parallel regularly, and are willing to
keep a durable host running. You get everything in sections 1–2 with zero custom building; you just
onboard your projects (section 5).

### Path B — Distill "a process like this" (what you literally asked for)
Best if the full toolchain + durable-host requirement is more than you want for two personal projects.
The *ideas* that carry ~80% of the value, without the distro:

1. **One entry-point agent per machine, projects side by side.** Keep both repos checked out and talk
   to Claude Code (or your harness) as the single front door.
2. **A per-project `CLAUDE.md`/`AGENTS.md`** capturing build/test/release mechanics and conventions —
   this is the highest-leverage, lowest-cost idea here and worth doing *regardless* of which path you
   pick. It's what makes an agent competent in a repo without re-explaining every session.
3. **Worktree isolation for parallel work** — `git worktree add` per task instead of the full treehouse
   pool.
4. **A merge gate you enforce by habit** — the agent opens PRs, you merge. (This is just discipline; no
   tool needed.)
5. **A lightweight backlog file** the agent maintains (`data/backlog.md`-style), instead of `tasks-axi`.

Path B gives you the "talk to one PM agent across my projects" feel with tools you already have. It
loses the automatic multi-crew supervision, the restart-proof reconciliation, and the validation
pipeline — which matter a lot at fleet scale and much less for two repos worked one-or-two-tasks at a
time.

**My recommendation:** Start on **Path B for a week** using the two projects, keeping the per-project
memory files and the merge-gate habit. If you find yourself wanting three things running at once and
resenting the babysitting, graduate to **Path A** — the onboarding below is the same either way, and
nothing you do in Path B is wasted.

---

## 5. Concrete onboarding plan for Cimarron Deal Intelligence and baseball

This is written for Path A (full distro) but every step maps cleanly onto Path B.

### Step 0 — Pick and prepare the host
Decide where the first mate lives (laptop or always-on VM). Clone this repo there and launch your
harness inside it. On first launch it runs its own session-start check and tells you exactly which tools
are missing with install commands. Approve the installs. Authenticate `gh`.

### Step 1 — Bring the two projects under management
For each project, the manager clones it flat under `projects/` and records one registry line. Concretely
you'll tell it something like *"add my Cimarron Deal Intelligence repo, it's at `<owner>/<repo>`"* and
*"add baseball, it's at `<owner>/<repo>`"*. Under the hood that's:

```sh
git clone <cimarron-url> projects/cimarron-deal-intelligence
git clone <baseball-url>  projects/baseball
```

plus a `data/projects.md` line per project. You don't run these by hand — you ask the manager, it does
the clone and registry write.

### Step 2 — Choose a delivery mode per project
This is the main decision you owe up front (see the table in section 1). A sensible default:

- **Cimarron Deal Intelligence** — if this is a real product with users/data you don't want broken,
  `no-mistakes` (full pipeline, you merge). If it's earlier-stage, `direct-PR`.
- **baseball** — if it's a personal/experimental project, `direct-PR` (simple, you still review) or
  `local-only` (no remote needed at all). Pick `local-only` only if you don't want it on GitHub.

You can change a mode later; it's just the registry line.

### Step 3 — Seed each project's memory (do this even on Path B)
The first time real work touches a project, have the agent create that project's `AGENTS.md` with the
build/test/run commands, architecture notes, and any sharp edges ("needs X to compile," "deploys via
Y"). This is the single highest-value onboarding artifact — it's what makes the agent competent in
Cimarron vs. baseball without you re-explaining each session.

### Step 4 — Start delegating
From then on you just talk: *"Cimarron's deal-scoring endpoint is returning stale data, find out why"*
(a scout task → report), or *"add a box-score parser to baseball and open a PR"* (a ship task → PR).
The manager resolves the project, spawns a worker in its own worktree, supervises it, and brings you the
report or the PR. You say "merge it" when you're happy.

### Step 5 — Only later: consider a secondmate
If one project grows enough that it deserves a persistent domain supervisor (e.g., a dedicated
Cimarron manager with its own backlog), you can promote it to a "secondmate." For two projects this is
premature — skip it until the queue for one project is consistently deep.

---

## 6. Decisions you owe before we execute

1. **Host** — where will the first mate actually run day-to-day? (Not this ephemeral environment.)
2. **Where the projects live** — GitHub `owner/repo` for Cimarron Deal Intelligence and for baseball
   (or local paths, or "they need creating").
3. **Rigor per project** — `no-mistakes` / `direct-PR` / `local-only` for each (section 5, Step 2).
4. **Path A vs. Path B** — full distro now, or distilled process first with an upgrade path.

Answer those four and onboarding is mechanical from there.

---

## 7. Bottom line

- The interaction model you want is **exactly** what this repo delivers — this is not a stretch fit.
- The cost is a **durable host + a custom-ish toolchain + an opinionated worldview**, which is
  proportionate at fleet scale and a bit heavy for two solo projects.
- **Recommended:** adopt the *ideas* immediately (per-project memory files, worktree isolation, a
  strict merge gate, one front-door agent), run that way for a week, and graduate to the full distro the
  moment you feel the babysitting pain that firstmate is built to remove. Onboarding Cimarron and
  baseball is the same first move either way.
