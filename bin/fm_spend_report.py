#!/usr/bin/env python3
"""Spend report over Claude transcripts, by agent kind x model x trigger class.

Read-only. Tokens are the API `usage` fields in Claude Code session transcripts
(`<projects>/<dir>/*.jsonl` plus `*/subagents/*.jsonl`), de-duplicated by
message id and user-message uuid so a resumed session's copied history is
counted once. Dollars are Anthropic list prices, a like-for-like weight and not
an invoice. A turn is attributed to the window by its opening timestamp.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import sys

SCHEMA = "fm-spend-report.v1"

# model -> (input $/MTok, output $/MTok, cache-read multiplier). Source:
# https://platform.claude.com/docs/en/about-claude/pricing. Cache writes cost
# 1.25x (5m) or 2x (1h) input.
PRICE = {
    "claude-fable-5-1": (10, 50, 0.025),
    "claude-fable-5": (10, 50, 0.1),
    "claude-opus-5-5": (4, 20, 0.05),
    "claude-opus-5": (5, 25, 0.1),
    "claude-sonnet-5": (2, 10, 0.1),
    "claude-haiku-4-5-20251001": (1, 5, 0.1),
    "claude-haiku-4-5": (1, 5, 0.1),
}
TRIGGERS = ("captain", "notification", "acknowledgement", "forced")


def encode_dir(path: str) -> str:
    """Claude Code's project-directory name for a working directory."""
    return re.sub(r"[^A-Za-z0-9-]", "-", path)


def call_cost(model, usage):
    """Return (context tokens, output tokens, usd) or None for an unpriced model."""
    price = PRICE.get(model)
    if price is None:
        return None
    inp, outp, read_mult = price
    cc = usage.get("cache_creation") or {}
    w1 = int(cc.get("ephemeral_1h_input_tokens") or 0)
    w5 = int(cc.get("ephemeral_5m_input_tokens") or 0)
    total_w = int(usage.get("cache_creation_input_tokens") or 0)
    if w1 + w5 < total_w:
        w5 += total_w - (w1 + w5)
    i = int(usage.get("input_tokens") or 0)
    cr = int(usage.get("cache_read_input_tokens") or 0)
    o = int(usage.get("output_tokens") or 0)
    usd = (i * inp + w5 * inp * 1.25 + w1 * inp * 2 + cr * inp * read_mult + o * outp) / 1e6
    return i + w5 + w1 + cr, o, usd


def message_text(content):
    if isinstance(content, list):
        return " ".join(x.get("text", "") for x in content if isinstance(x, dict))
    return str(content)


def classify(text, is_meta):
    """Trigger class of a user message, or None for a non-turn record."""
    if is_meta:
        return "forced" if text.startswith("Stop hook feedback") else None
    t = text.lstrip()
    if "Stop hook feedback" in t[:200]:
        return "notification"
    if t.startswith("<task-notification>"):
        return "notification"
    if "FIRSTMATE_OP" in t[:80] or t.startswith("⁣") or "Firstmate instruction waiting" in t[:200]:
        return "notification"
    return "captain"


def is_acknowledgement(last_text):
    """A notification turn that only acknowledged: 'shipshape' and under 400 chars."""
    return "shipshape" in last_text and len(last_text) < 400


def parse_turns(files):
    seen = set()
    out = []
    for path in sorted(files, key=os.path.getmtime):
        cur = None
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                m = d.get("message")
                if not isinstance(m, dict):
                    continue
                ts = d.get("timestamp", "")
                if d.get("type") == "user":
                    c = m.get("content")
                    if isinstance(c, list) and any(
                        isinstance(x, dict) and x.get("type") == "tool_result" for x in c
                    ):
                        continue
                    trigger = classify(message_text(c), d.get("isMeta"))
                    if trigger is None:
                        continue
                    key = d.get("uuid")
                    if key in seen:
                        cur = None
                        continue
                    seen.add(key)
                    cur = {"ts": ts, "trigger": trigger, "last_text": "", "calls": []}
                    out.append(cur)
                elif d.get("type") == "assistant" and cur is not None:
                    for x in m.get("content") or []:
                        if isinstance(x, dict) and x.get("type") == "text":
                            cur["last_text"] = x.get("text", "")
                    mid = m.get("id")
                    if mid in seen or not m.get("usage"):
                        continue
                    seen.add(mid)
                    c = call_cost(m.get("model"), m["usage"])
                    if c:
                        cur["calls"].append((m.get("model"),) + c)
    return out


def agent_kind(dirname, home_dir, mate_dirs):
    if dirname == home_dir:
        return "primary"
    if dirname in mate_dirs:
        return "secondmate"
    if "-no-mistakes-" in dirname:
        return "pipeline"
    if "-treehouse-" in dirname:
        return "worker"
    return None


def secondmate_dirs(home):
    """Encoded project dirs of every secondmate home named in data/secondmates.md."""
    dirs = set()
    try:
        text = open(os.path.join(home, "data", "secondmates.md"), encoding="utf-8").read()
    except OSError:
        return dirs
    for m in re.finditer(r"\(home: ([^;)]+)", text):
        dirs.add(encode_dir(m.group(1).strip()))
    return dirs


def transcript_files(pdir):
    return glob.glob(pdir + "/*.jsonl") + glob.glob(pdir + "/*/subagents/*.jsonl")


def unmeasured_counts(lo, hi):
    """Codex and agy transcripts carry cumulative per-session counters, so report them unmeasured."""
    found = {}
    for name, pattern in (("codex", "~/.codex/sessions/**/*.jsonl"), ("agy", "~/.gemini/antigravity/**/*.pb")):
        n = 0
        for p in glob.glob(os.path.expanduser(pattern), recursive=True):
            try:
                mt = dt.datetime.fromtimestamp(os.path.getmtime(p), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            except OSError:
                continue
            if lo <= mt <= hi:
                n += 1
        found[name] = n
    return found


def build_report(projects, home, lo, hi):
    home_dir = encode_dir(home)
    mates = secondmate_dirs(home)
    rows = collections.OrderedDict()
    for pdir in sorted(glob.glob(os.path.join(projects, "*"))):
        kind = agent_kind(os.path.basename(pdir), home_dir, mates)
        if kind is None:
            continue
        for turn in parse_turns(transcript_files(pdir)):
            if not (lo <= turn["ts"] <= hi):
                continue
            trig = turn["trigger"]
            if trig == "notification" and is_acknowledgement(turn["last_text"]):
                trig = "acknowledgement"
            for model, ctx, out, usd in turn["calls"]:
                r = rows.setdefault(
                    (kind, model, trig),
                    {"kind": kind, "model": model, "trigger": trig, "turns": 0, "calls": 0, "context_tokens": 0, "output_tokens": 0, "usd": 0.0},
                )
                r["calls"] += 1
                r["context_tokens"] += ctx
                r["output_tokens"] += out
                r["usd"] += usd
            for model in {c[0] for c in turn["calls"]}:
                rows[(kind, model, trig)]["turns"] += 1
    for r in rows.values():
        r["usd"] = round(r["usd"], 2)
    ordered = sorted(rows.values(), key=lambda r: (r["kind"], r["model"], TRIGGERS.index(r["trigger"])))
    totals = {k: sum(r[k] for r in ordered) for k in ("calls", "context_tokens", "output_tokens")}
    totals["usd"] = round(sum(r["usd"] for r in ordered), 2)
    return {
        "schema": SCHEMA,
        "window": {"from": lo, "to": hi},
        "rows": ordered,
        "totals": totals,
        "unmeasured": unmeasured_counts(lo, hi),
    }


def fmt_table(rep):
    lines = [f"spend {rep['window']['from']} .. {rep['window']['to']}  (list price, not an invoice)"]
    lines.append(f"{'kind':<10} {'model':<16} {'trigger':<16} {'calls':>6} {'context tok':>14} {'output tok':>11} {'usd':>9}")
    for r in rep["rows"]:
        lines.append(
            f"{r['kind']:<10} {r['model']:<16} {r['trigger']:<16} {r['calls']:>6} "
            f"{r['context_tokens']:>14,} {r['output_tokens']:>11,} {r['usd']:>9,.2f}"
        )
    t = rep["totals"]
    lines.append(f"{'TOTAL':<10} {'':<16} {'':<16} {t['calls']:>6} {t['context_tokens']:>14,} {t['output_tokens']:>11,} {t['usd']:>9,.2f}")
    for name, n in rep["unmeasured"].items():
        lines.append(f"{name}: unmeasured ({n} transcript files in window; counters are cumulative per session)")
    return "\n".join(lines)


def iso(value):
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M").strftime("%Y-%m-%dT%H:%M")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--home", default=os.environ.get("FM_HOME") or os.getcwd())
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--from", dest="lo", help="window start, UTC YYYY-MM-DDTHH:MM")
    ap.add_argument("--to", dest="hi", help="window end, UTC YYYY-MM-DDTHH:MM")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    hi = iso(a.hi) if a.hi else now.strftime("%Y-%m-%dT%H:%M")
    lo = iso(a.lo) if a.lo else (now - dt.timedelta(hours=a.hours)).strftime("%Y-%m-%dT%H:%M")
    rep = build_report(a.projects_dir, os.path.abspath(a.home), lo, hi)
    print(json.dumps(rep) if a.json else fmt_table(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
