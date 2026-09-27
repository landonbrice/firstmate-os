#!/usr/bin/env bash
# Context-reset checks for long-lived Claude sessions.
#
# Usage: fm-context-check.sh <task-id> [--threshold N]
#        fm-context-check.sh --primary [--threshold N] [--quiet-minutes M]
#        fm-context-check.sh --clear-primary [--quiet-minutes M]
#
# <task-id>: print one `context-high: <id> <tokens> > <threshold>` line when a
# Claude-harness task's live per-call context is over the threshold (default
# 200000); print nothing otherwise. Always exits 0.
# Checked by default only when state/<id>.meta says kind=secondmate; a present
# state/<id>.context-check file opts any other task in. Non-claude harnesses and a
# missing transcript are silent.
#
# --primary: the same measurement for this home's own firstmate session, which
# must be a Claude Code background session (`claude --bg`): the anchor pid on
# line 1 of state/.lock is matched to `claude agents --json`, whose sessionId
# names the transcript. Prints one `main-context-high: ...` line only when the
# context is over the threshold AND the last captain message (a transcript
# record with origin.kind=human that is not a Firstmate operational doorbell,
# or the session's start when there is none) is at least M minutes old
# (default 30) AND no away/quiet marker (state/.afk, state/.afk-contract) is
# present AND the wake queue is empty AND no earlier line fired within
# FM_PRIMARY_RESET_REFIRE seconds (default 3600). Silent otherwise; exits 0.
#
# --clear-primary: run by the primary only after /stow reports reset-safe in
# answer to a main-context-high line. Refuses (exit 1, one `refused:` line)
# without a main-context-high line fired in the last 2 hours, or when the gates
# above fail now. Otherwise forks a detached clearer and exits 0 at once so the
# primary can end its turn. The clearer waits up to FM_PRIMARY_CLEAR_WAIT
# seconds (default 900) for the session to be idle with every gate still
# passing, then attaches to it with `claude attach` on a private pty, types
# /clear, confirms the sessionId rotated, and types a record-backed
# session-start doorbell so the fresh conversation takes one turn and re-arms
# supervision. Its outcome is appended to state/.primary-context-reset.log.
#
# Measurement reuses claude_session_context() from fm_bridge_snapshot.py.
# To run either check on the watcher's slow poll, write a state/<id>.check.sh
# shim that execs this script by absolute path and bind it with
# fm-check-register.sh (recipes: docs/agent-control.md "Context reset for a
# long-lived secondmate" and "Context reset for the primary").
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:-}
[ "$#" -gt 0 ] && shift
THRESHOLD=200000
QUIET_MINUTES=30
while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold) THRESHOLD=${2:-}; shift 2 || shift ;;
    --quiet-minutes) QUIET_MINUTES=${2:-}; shift 2 || shift ;;
    *) shift ;;
  esac
done
case "$THRESHOLD" in ''|*[!0-9]*) exit 0 ;; esac
case "$QUIET_MINUTES" in ''|*[!0-9]*) exit 0 ;; esac

case "$ID" in
  --primary|--clear-primary)
    exec python3 - "$SCRIPT_DIR" "$STATE" "${ID#--}" "$THRESHOLD" "$QUIET_MINUTES" <<'PY'
import datetime, json, os, select, signal, subprocess, sys, time

sys.path.insert(0, sys.argv[1])
import fm_bridge_snapshot as snap

SCRIPT_DIR, STATE, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
THRESHOLD, QUIET = int(sys.argv[4]), int(sys.argv[5]) * 60
CLAUDE = os.environ.get("FM_CLAUDE_BIN", "claude")
RECORD = os.path.join(STATE, ".primary-context-reset")
LOG = RECORD + ".log"
REFIRE = int(os.environ.get("FM_PRIMARY_RESET_REFIRE", "3600"))
FIRED_VALID = 7200
OPINPUT = os.path.join(SCRIPT_DIR, "fm-operational-input.sh")
DOORBELL_PREFIX = ": Firstmate operational input waiting: read '"


class Refused(Exception):
    pass


def record_read():
    out = {}
    try:
        for line in open(RECORD):
            key, _, value = line.strip().partition("=")
            out[key] = value
    except OSError:
        pass
    return out


def record_write(**fields):
    data = record_read()
    data.update({k: str(v) for k, v in fields.items()})
    tmp = RECORD + ".tmp"
    with open(tmp, "w") as handle:
        handle.writelines(f"{k}={v}\n" for k, v in data.items())
    os.replace(tmp, RECORD)


def primary_session():
    """The `claude agents --json` entry for the pid on line 1 of state/.lock."""
    try:
        pid = int(open(os.path.join(STATE, ".lock")).readline().strip())
    except (OSError, ValueError):
        raise Refused("no session lock pid")
    try:
        agents = json.loads(subprocess.run([CLAUDE, "agents", "--json"], capture_output=True, text=True, timeout=20).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        raise Refused("claude agents --json unreadable")
    for entry in agents if isinstance(agents, list) else []:
        if isinstance(entry, dict) and entry.get("pid") == pid:
            if entry.get("kind") != "background":
                raise Refused(f"primary pid {pid} is not a Claude background session")
            if not all(entry.get(k) for k in ("id", "sessionId", "cwd", "status")):
                raise Refused(f"claude agents entry for pid {pid} lacks id/sessionId/cwd/status")
            return entry
    raise Refused(f"no Claude session with pid {pid}")


def transcript(entry):
    return str(snap.claude_dir_for_path(entry["cwd"]) / (entry["sessionId"] + ".jsonl"))


def parse_ts(value):
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def is_doorbell(text):
    if text.startswith("⁣"):
        return True
    if not text.startswith(DOORBELL_PREFIX):
        return False
    return subprocess.run([OPINPUT, "doorbell-kind"], input=text, capture_output=True, text=True).returncode == 0


def last_captain_at(path):
    """Newest captain-typed message time, or the session's first record time."""
    first, typed = None, []
    try:
        handle = open(path, errors="replace")
    except OSError:
        raise Refused("primary transcript unreadable")
    with handle:
        for line in handle:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(obj.get("timestamp")) if isinstance(obj, dict) else None
            if ts is None:
                continue
            first = ts if first is None else first
            origin = obj.get("origin")
            if obj.get("type") != "user" or not isinstance(origin, dict) or origin.get("kind") != "human":
                continue
            content = (obj.get("message") or {}).get("content")
            if isinstance(content, list):
                content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
            typed.append((ts, str(content or "").strip()))
    for ts, text in reversed(typed):
        if not is_doorbell(text):
            return ts
    if first is None:
        raise Refused("primary transcript has no timestamped records")
    return first


def gates(entry, now):
    """Raise Refused unless away mode is off, no wake is queued, and the captain is quiet."""
    for marker in (".afk", ".afk-contract"):
        if os.path.lexists(os.path.join(STATE, marker)):
            raise Refused(f"away or quiet mode is active (state/{marker})")
    try:
        if os.path.getsize(os.path.join(STATE, ".wake-queue")) > 0:
            raise Refused("wakes are queued and unacknowledged")
    except OSError:
        pass
    quiet_for = now - last_captain_at(transcript(entry))
    if quiet_for < QUIET:
        raise Refused(f"captain spoke {int(quiet_for // 60)}m ago (< {QUIET // 60}m)")
    return quiet_for


def check():
    now = time.time()
    entry = primary_session()
    found = snap.claude_session_context(transcript(entry))
    if not found or found[0]["current_tokens"] <= THRESHOLD:
        return
    fired = record_read().get("fired", "")
    if fired.isdigit() and now - int(fired) < REFIRE:
        return
    quiet_for = gates(entry, now)
    record_write(fired=int(now), fired_tokens=found[0]["current_tokens"])
    print(f"main-context-high: {found[0]['current_tokens']} > {THRESHOLD}, captain quiet {int(quiet_for // 60)}m."
          " If no captain decision is open in this conversation, run /stow; when its receipt says reset-safe,"
          " run bin/fm-context-check.sh --clear-primary and end the turn"
          " (docs/agent-control.md \"Context reset for the primary\").")


def log(line):
    with open(LOG, "a") as handle:
        handle.write(f"{datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {line}\n")


def attach_and_type(entry, texts, settle):
    """Type each text plus Enter into the session through a private `claude attach` pty."""
    import fcntl, pty, struct, termios
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(CLAUDE, [CLAUDE, "attach", entry["id"]])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    os.read(fd, 65536)
                except OSError:
                    return

    try:
        pump(settle)
        for text in texts:
            if callable(text):
                text = text()
                if text is None:
                    break
            os.write(fd, text.encode())
            pump(1)
            os.write(fd, b"\r")
            pump(settle)
    finally:
        for sig in (signal.SIGHUP, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            pump(0.5)
        os.waitpid(pid, 0)
        os.close(fd)


def clear_worker(entry):
    wait = int(os.environ.get("FM_PRIMARY_CLEAR_WAIT", "900"))
    poll = float(os.environ.get("FM_PRIMARY_CLEAR_POLL", "5"))
    settle = float(os.environ.get("FM_PRIMARY_CLEAR_SETTLE", "4"))
    deadline = time.time() + wait
    reason = "timed out"
    while time.time() < deadline:
        try:
            entry = primary_session()
            gates(entry, time.time())
            if entry["status"] != "idle":
                raise Refused(f"session is {entry['status']}")
        except Refused as exc:
            reason = str(exc)
            time.sleep(poll)
            continue
        old = entry["sessionId"]

        def doorbell():
            for _ in range(int(max(settle, 1) * 5)):
                try:
                    if primary_session()["sessionId"] != old:
                        break
                except Refused:
                    pass
                time.sleep(0.2)
            else:
                return None
            body = ("Automatic context reset: /stow ran and the conversation was cleared after the captain was quiet."
                    " The session-start digest above holds the durable state; resume supervision from it.")
            env = dict(os.environ, FM_STATE_OVERRIDE=STATE)
            done = subprocess.run([OPINPUT, "record", "session-start"], input=body, capture_output=True, text=True, env=env)
            return done.stdout.strip() or None

        attach_and_type(entry, ["/clear", doorbell], settle)
        try:
            new = primary_session()["sessionId"]
        except Refused as exc:
            new = f"unknown ({exc})"
        if new == old:
            log(f"failed: /clear did not rotate session {old}")
            return 1
        record_write(cleared=int(time.time()), cleared_from=old, cleared_to=new)
        log(f"cleared: {entry['id']} {old} -> {new}")
        return 0
    log(f"refused: {reason}")
    return 1


def clear():
    now = time.time()
    fired = record_read().get("fired", "")
    if not fired.isdigit() or now - int(fired) > FIRED_VALID:
        raise Refused("no main-context-high line fired in the last 2 hours")
    entry = primary_session()
    gates(entry, now)
    if os.fork():
        print(f"scheduled: clearing {entry['id']} once idle; outcome in {LOG}")
        return 0
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    os._exit(clear_worker(entry))


try:
    if MODE == "primary":
        check()
        sys.exit(0)
    sys.exit(clear())
except Refused as exc:
    if MODE == "primary":
        sys.exit(0)
    print(f"refused: {exc}")
    sys.exit(1)
except Exception:
    if MODE == "primary":
        sys.exit(0)
    raise
PY
    ;;
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

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
