#!/usr/bin/env python3
"""Navigation metrics (docs/shipping.md, Navigation): how agents find their way around nixos-config, from the owner's
Claude Code main-session transcripts (~/.claude/projects/*/*.jsonl) of the last 24 h, as one Prometheus textfile.
Counts only: no prompt, command, file content or path leaves the process; the only labels are role, quantile and
section, and for guests worker and reason. The classification is the retro's (nixos-config#535, navcost.py), trimmed
to what the metrics need.

A role (coordinator, worker) with fewer than MIN_SAMPLE repo navigation calls in the window gets its sample size and
nothing else: a thin day is absent, not a swing (24 calls once read as a 21 % miss ratio). A section that fails
leaves its series out and keeps its previous success timestamp. Exits 0 whenever it could write the file.

With --worker, the same series for dev-environment guests instead, each with a `worker` label from the host's own
argv, never from a transcript: `<state-dir>/<name>/home/.claude/projects/*/*.jsonl`, which the guest controls. No
link is followed and nothing but a regular file is opened (guest_transcripts); a file over FILE_MAX bytes, past
FILES_MAX in a run, or a line over LINE_MAX is not read; each guest gets an equal share of the run deadline.

Usage: nav-metrics.py --out FILE [--projects DIR] [--hours 24]
       nav-metrics.py --out FILE --state-dir DIR --home GUEST_HOME --worker NAME [--worker NAME ...] [--hours 24]
       nav-metrics.py --list   (the metric names it can emit, one per line: the build-time check reads them)"""
import argparse
import json
import os
import re
import shlex
import stat
import sys
import time
from datetime import datetime

METRICS = {
    "agent_nav_collector_success_timestamp_seconds": "Unix time a section last collected without error.",
    "agent_nav_collector_section_failed": "1 when the section failed this run (an error or the run deadline), else 0.",
    "agent_nav_repo_nav_calls": "Navigation calls on a nixos-config checkout that got a result in the window: the sample size, always written.",
    "agent_nav_stretches": "Repo stretches in the window: prompts whose tool calls navigated the repo or changed a file in it.",
    "agent_nav_calls_before_first_edit": "Navigation calls before the first Edit/Write of a repo stretch (or its end), by quantile.",
    "agent_nav_topdirs_before_first_edit": "Distinct top-level repo directories navigated before the first Edit/Write of a repo stretch, by quantile.",
    "agent_nav_repo_miss_ratio": "Share of repo navigation calls whose result was an error, empty, no match or no such file.",
    "agent_nav_repo_reads": "Reads of repo files (Read, cat, head, tail, sed -n) in the window.",
    "agent_nav_repeat_read_ratio": "Share of repo file reads that read a file the same session already read in the window.",
    "agent_nav_collector_skipped": "A guest's transcripts not read this run: refused (a link, FIFO or other non-regular file on the path), too_large (over FILE_MAX bytes) or too_many (past FILES_MAX).",
}
ROLES = ("coordinator", "worker")
SECTIONS = ("scan", "stretches", "misses", "rereads")
MIN_SAMPLE = 50  # repo navigation calls; the retro's minimum before a day's ratios stop swinging
DEADLINE = time.monotonic() + 240  # the unit's TimeoutStartSec is above this
# guests only, from the owner's transcripts: 107 written in his busiest day, the largest 119 MB, the longest line 660 KB
FILES_MAX = 256
FILE_MAX = 256 * 1024 * 1024
LINE_MAX = 2 * 1024 * 1024  # a line is decoded and parsed whole: this keeps the worst one within the unit's MemoryMax
SKIPS = ("refused", "too_large", "too_many")
WORKER_RE = re.compile(r"[a-z][a-z0-9-]{0,10}")
HOME = os.path.expanduser("~")
CHANGE_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
NAV_CMDS = {"grep", "rg", "ugrep", "egrep", "fgrep", "find", "fd", "ls", "tree", "cat", "head", "tail"}
GREPS = {"grep", "rg", "ugrep", "egrep", "fgrep", "git-grep"}
READS = {"cat", "head", "tail", "sed"}
BUILD_RE = re.compile(
    r"^(nix\s+(build|flake\s+check|eval|develop|run|shell|path-info|store)|nix-build|nix-instantiate|"
    r"nixos-rebuild|home-manager|devenv|just|cargo|deploy|statix|deadnix|nixfmt|treefmt|prek|"
    r"pre-commit|pytest|make|npm|sdlc-status|nix-audit|factum|shellcheck|ruff|flock|nix-unit|nix-fast-build|"
    r"systemd-analyze\s+verify|(?:python3?|bash|sh)\s+(?:-\S+\s+)*\S*tests?[/_-]\S*)\b"
)
WRAPPERS = {"sudo", "env", "nice", "command", "time", "exec", "xargs", "stdbuf", "nohup", "systemd-run"}
VALUE_FLAGS = {
    "grep": {"-A", "-B", "-C", "-m", "-e", "-f", "-d", "-D", "--max-count"},
    "rg": {"-A", "-B", "-C", "-m", "-e", "-f", "-g", "-t", "-T", "--glob", "--type", "--max-count", "-M"},
    "head": {"-n", "-c"},
    "tail": {"-n", "-c"},
    "ls": {"-I", "--ignore"},
    "tree": {"-L", "-I", "-P"},
    "fd": {"-e", "-t", "-d", "-E", "--type", "--extension", "--max-depth", "--exclude"},
    "sed": {"-e", "-f"},
}
REV_RE = re.compile(r"^(?:origin|upstream)/|\.\.|^HEAD|^[0-9a-f]{7,40}$")
# a nixos-config checkout: */nixos-config, or a worktree under ~/.cache/wt or ~/wt (some are other repos' or scratch
# dirs; the retro counted them as checkouts too)
def repo_re(home):
    return re.compile(r"(?:/nixos-config|^" + re.escape(home) + r"/(?:\.cache/)?wt/[^/\s'\"]+)(?:/(.*))?$")


REPO_RE = repo_re(HOME)
HEREDOC_RE = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
# lines that cannot hold a tool call, its result, a prompt or the session's name are not parsed
# a run reads the day's transcripts through the page cache, which the unit's cgroup is charged for: hundreds of MB on
# a busy day against a 48M MemoryMax. Reading drops each file's pages behind it, every DROP_EVERY bytes and at the end,
# so the cgroup's peak stays at the process's own few MB, flat in the transcripts' size
DROP_EVERY = 8 * 1024 * 1024
WANTED = ('"tool_use"', '"tool_result"', '"origin"', '"agentName"')


class Out:
    def __init__(self, **labels):
        self.lines, self.labels = {}, labels

    def add(self, name, value, **labels):
        assert name in METRICS, f"{name} is not in METRICS"
        labels = {**self.labels, **labels}
        lab = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
        self.lines.setdefault(name, []).append(f"{name}{{{lab}}} {value:.15g}" if lab else f"{name} {value:.15g}")

    def text(self):
        body = []
        for name, rows in self.lines.items():
            body += [f"# HELP {name} {METRICS[name]}", f"# TYPE {name} gauge", *rows]
        return "\n".join(body) + "\n"


def quantile(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def repo_rel(path, cwd=None):
    """Repo-relative path for a path inside a nixos-config checkout ("." for its root), else None."""
    if not path or not isinstance(path, str):
        return None
    p = path.strip().strip("'\"")
    if p.startswith("~"):
        p = HOME + p[1:]
    if "$" in p:
        return None
    if not p.startswith("/") and cwd:
        p = os.path.join(cwd, p)
    p = os.path.normpath(p) if p.startswith("/") else p
    m = REPO_RE.search(p)
    if not m:
        return None
    if m.group(1) is None and "." in os.path.basename(m.group(0)):
        return None  # a file directly in ~/.cache/wt (a log, a bundle), not a checkout
    return m.group(1) or "."


def topdir(rel):
    if rel in (None, "."):
        return None
    if "/" in rel:
        return rel.split("/", 1)[0]
    return "<root>" if ("." in rel or rel.lower() in ("justfile", "makefile", "license")) else rel


def strip_heredocs(cmd):
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        out.append(lines[i])
        delims = HEREDOC_RE.findall(lines[i])
        i += 1
        for d in delims:
            while i < len(lines) and lines[i].strip() != d:
                i += 1
            i += 1
    return "\n".join(out)


def split_segments(text):
    """Split a shell command on ; && || | newline ( ) $( ` & outside quotes -> [(segment, after_pipe)]."""
    segs, buf, q, prev, i, n = [], [], None, None, 0, len(text)

    def flush(op):
        nonlocal prev
        seg = "".join(buf).strip()
        if seg:
            segs.append((seg, prev == "|"))
        buf.clear()
        prev = op

    while i < n:
        ch = text[i]
        if q:
            if ch == "\\" and q == '"' and i + 1 < n:
                buf.append(text[i:i + 2])
                i += 2
                continue
            if ch == q:
                q = None
            buf.append(ch)
        elif ch == "\\" and i + 1 < n:
            buf.append(text[i:i + 2])
            i += 2
            continue
        elif ch in "'\"":
            q = ch
            buf.append(ch)
        elif text.startswith("&&", i) or text.startswith("||", i):
            flush(text[i:i + 2])
            i += 2
            continue
        elif text.startswith("$(", i):
            flush("$(")
            i += 2
            continue
        elif ch == "|" or ch in ";\n()`":
            flush(ch)
        elif ch == "&" and not (i + 1 < n and text[i + 1] == ">") and not (buf and buf[-1] in "<>"):
            flush("&")
        else:
            buf.append(ch)
        i += 1
    flush(None)
    return segs


def tokens(seg):
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        return seg.split()


def strip_prefix(tok):
    while tok:
        t = tok[0]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in WRAPPERS or t in ("{", "!", "then", "do", "else", "if", "while"):
            tok = tok[1:]
        elif t == "timeout":
            tok = tok[1:]
            while tok and (tok[0].startswith("-") or re.match(r"^\d+[smh]?$", tok[0])):
                tok = tok[1:]
        else:
            break
    return tok


def nav_paths(cmd, tok):
    """The paths a navigation segment names (its grep/find patterns and git revisions dropped)."""
    args = tok[1:]
    if cmd == "git":
        sub = [a for a in args if not a.startswith("-")]
        args = args[args.index(sub[0]) + 1:] if sub else []
        cmd = "git-" + (sub[0] if sub else "")
        if cmd in ("git-log", "git-show"):
            # only explicit pathspecs (after --) and rev:path blobs; revisions are not paths
            after = args[args.index("--") + 1:] if "--" in args else []
            blobs = [a.split(":", 1)[1] for a in args if ":" in a and not a.startswith(":") and "--" not in a[:2]]
            return [a for a in after + blobs if a and not a.startswith(":")]
    vflags = VALUE_FLAGS.get(cmd, set())
    pos, explicit_pat, i = [], False, 0
    while i < len(args):
        a = args[i]
        if cmd == "find" and a in ("-name", "-iname", "-path", "-ipath", "-wholename", "-regex", "-iregex"):
            i += 2
            continue
        if a in ("-e", "--regexp") and cmd in GREPS:
            explicit_pat = True
            i += 2
            continue
        if a in vflags:
            i += 2
            continue
        if a.startswith(("-", ">", "2>")) or a == "<" or re.match(r"^\d+$", a):
            i += 1
            continue
        pos.append(a)
        i += 1
    if cmd == "find":
        pos = [p for p in pos if not p.startswith("(") and p not in ("{}", ";", "+")][:1]
    if (cmd in GREPS and not explicit_pat) or cmd == "sed":
        pos = pos[1:]  # the pattern or the sed script
    return [p for p in pos if not REV_RE.match(p)]


def classify_bash(command, cwd):
    """-> (is_nav, [(raw, rel)], read_rels, effective cwd). Precedence: build/test > navigation > anything else;
    a grep/head/tail that filters another command's pipe output is not navigation."""
    has_build = has_nav = False
    paths, reads, ecwd = [], [], cwd
    for seg, piped in split_segments(strip_heredocs(command or "")):
        tok = strip_prefix(tokens(seg))
        if not tok:
            continue
        c = os.path.basename(tok[0])
        if c == "cd" and len(tok) > 1:
            t = tok[1].replace("~", HOME, 1)
            ecwd = None if "$" in t else (t if t.startswith("/") else os.path.join(ecwd or "/", t))
            continue
        if c == "git" and "-C" in tok:
            k = tok.index("-C")
            if k + 1 < len(tok):
                t = tok[k + 1].replace("~", HOME, 1)
                ecwd = None if "$" in t else (t if t.startswith("/") else os.path.join(ecwd or "/", t))
                tok = tok[:k] + tok[k + 2:]
        if BUILD_RE.match(" ".join(tok)):
            has_build = True
            continue
        # `cat > file`, `tee file`: a write, not a read
        if c in ("cat", "tee", "printf", "echo") and (c == "tee" or re.search(r"(?<![0-9&])>>?\s*\S", seg)):
            continue
        if c in NAV_CMDS or (c == "sed" and "-n" in tok[1:3]):
            nav = True
        elif c == "git":
            sub = [a for a in tok[1:] if not a.startswith("-")]
            nav = bool(sub) and sub[0] in ("grep", "log", "show")
        else:
            nav = False
        if not nav or piped:
            continue
        has_nav = True
        for p in nav_paths(c, tok):
            rel = repo_rel(p, ecwd)
            paths.append((p, rel))
            if c in READS and rel and rel != ".":
                reads.append(rel)
    return (has_nav and not has_build), paths, reads, ecwd


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
    return ""


def is_miss(name, text, is_error):
    t = text.strip()
    if is_error:
        return True
    if name == "Read":
        return "File does not exist" in t or "No such file" in t
    if name in ("Grep", "Glob"):
        return t in ("", "No matches found", "No files found") or t.startswith(("No files found", "No matches found"))
    return t in ("", "(Bash completed with no output)") or "No such file or directory" in t


def is_prompt(rec):
    """A prompt from the owner or a peer session starts a stretch; task notifications, scheduled check-ins,
    compaction summaries and tool results do not."""
    if rec.get("type") != "user":
        return False
    c = (rec.get("message") or {}).get("content") if isinstance(rec.get("message"), dict) else None
    if isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
        return False
    o = rec.get("origin")
    return isinstance(o, dict) and o.get("kind") in ("human", "peer")


def stamp(rec):
    try:
        return datetime.fromisoformat(str(rec["timestamp"]).replace("Z", "+00:00")).timestamp()
    except (KeyError, ValueError):
        return None


def tool_call(name, inp, cwd):
    """A tool_use as {nav, repo, paths, reads, change, repo_change}; None for a call that is neither."""
    if not isinstance(inp, dict):
        inp = {}
    if name == "Read":
        rel = repo_rel(inp.get("file_path"), cwd)
        return {"nav": True, "repo": rel is not None, "paths": [rel], "reads": [rel] if rel and rel != "." else []}
    if name in ("Grep", "Glob"):
        rel = repo_rel(inp.get("path") or cwd, cwd)
        return {"nav": True, "repo": rel is not None, "paths": [rel], "reads": []}
    if name in CHANGE_TOOLS:
        return {"nav": False, "change": True, "repo_change": repo_rel(inp.get("file_path") or inp.get("notebook_path"), cwd) is not None}
    if name == "Bash":
        nav, paths, reads, ecwd = classify_bash(inp.get("command", ""), cwd)
        if not nav:
            return None
        repo = any(rel for _, rel in paths) or (not paths and repo_rel(ecwd) is not None)
        return {"nav": True, "repo": repo, "paths": [rel for _, rel in paths], "reads": reads}
    return None


def tally():
    """One role's running counts over the day: per repo stretch the nav calls and top-level directories before its
    first change, and the repo nav calls judged (their result seen) and missed, repo file reads and repeats."""
    return {"before": [], "dirs": [], "judged": 0, "missed": 0, "reads": 0, "repeats": 0}


def scan_file(path, since, t, line_max=-1, byte_max=None):
    """One main-session transcript (a path, or a binary file it closes), line by line, into its role's tally
    `t[role]`. Nothing per call outlives the call: a stretch keeps its counters and the directories it saw, a nav call
    waits only for its result, and the session keeps the set of repo files it read (for repeats). A line longer than
    line_max is skipped in line_max pieces, and reading stops after byte_max. Returns the session's role."""
    role, pending, reads_seen = "worker", {}, set()
    stretch = None  # [nav calls, repo nav calls, top dirs, saw a change, saw a repo change]; None before a prompt
    done = []  # finished stretches as (nav calls, top dirs), counted once the role is known at the end

    def close():
        if stretch is not None and (stretch[1] or stretch[4]):
            done.append((stretch[0], len(stretch[2])))

    judged = missed = reads = repeats = 0
    with open(path, "rb") if isinstance(path, (str, os.PathLike)) else path as fh:
        fd, read, dropped, overlong = fh.fileno(), 0, 0, False
        while raw := fh.readline(line_max):
            if time.monotonic() > DEADLINE:
                raise TimeoutError("run deadline reached")
            read += len(raw)
            if read - dropped >= DROP_EVERY:
                os.posix_fadvise(fd, 0, read, os.POSIX_FADV_DONTNEED)
                dropped = read
            if byte_max is not None and read > byte_max:
                break
            if overlong or (len(raw) == line_max and not raw.endswith(b"\n")):
                overlong = not raw.endswith(b"\n")
                continue
            line = raw.decode("utf-8", errors="replace")
            if not any(k in line for k in WANTED):
                continue
            try:
                rec = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if not isinstance(rec, dict):
                continue
            # the session's name as `claude --name` or /rename set it; the retro's coordinator was the one so named
            if isinstance(rec.get("agentName"), str):
                role = "coordinator" if "coordinator" in rec["agentName"] else "worker"
            if rec.get("isSidechain"):
                continue
            ts_ = stamp(rec)
            if ts_ is None or ts_ < since:
                continue
            if is_prompt(rec):
                close()
                stretch = [0, 0, set(), False, False]
                continue
            m = rec.get("message")
            if not isinstance(m, dict) or not isinstance(m.get("content"), list):
                continue
            for x in m["content"]:
                if not isinstance(x, dict):
                    continue
                if x.get("type") == "tool_use" and rec.get("type") == "assistant":
                    c = tool_call(x.get("name"), x.get("input"), rec.get("cwd"))
                    if c is None:
                        continue
                    if c["nav"]:
                        pending[x.get("id")] = (x.get("name"), c["repo"])
                        for r in c["reads"]:
                            reads += 1
                            repeats += r in reads_seen
                            reads_seen.add(r)
                    if stretch is not None:
                        if c.get("change"):
                            stretch[3] = True
                            stretch[4] = stretch[4] or c["repo_change"]
                        elif not stretch[3]:
                            stretch[0] += 1
                            stretch[1] += c["repo"]
                            stretch[2] |= {d for d in map(topdir, c["paths"] + c["reads"]) if d}
                elif x.get("type") == "tool_result":
                    hit = pending.pop(x.get("tool_use_id"), None)
                    if hit is not None and hit[1]:
                        judged += 1
                        missed += is_miss(hit[0], result_text(x.get("content")), bool(x.get("is_error")))
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    close()
    r = t[role]
    r["before"] += [n for n, _ in done]
    r["dirs"] += [d for _, d in done]
    r["judged"] += judged
    r["missed"] += missed
    r["reads"] += reads
    r["repeats"] += repeats
    return role


def transcripts(projects, since):
    """Main-session transcripts written to in the window (subagents' sit one level deeper and are not read)."""
    try:
        dirs = sorted(os.listdir(projects))
    except OSError:
        return []
    found = []
    for d in dirs:
        try:
            names = sorted(os.listdir(os.path.join(projects, d)))
        except OSError:
            continue
        for n in names:
            p = os.path.join(projects, d, n)
            try:
                if n.endswith(".jsonl") and os.path.isfile(p) and os.path.getmtime(p) >= since:
                    found.append(p)
            except OSError:
                continue
    return found


def guest_transcripts(state_dir, name, since, skipped):
    """A guest's main-session transcripts written to in the window, as binary files opened one at a time, never through
    a link: each directory from its parent's fd with O_NOFOLLOW, each transcript O_NONBLOCK (a FIFO cannot hold the
    open) and kept only if fstat says a regular file. Anything else on the path is refused and counted in `skipped`,
    as are files over FILE_MAX and past FILES_MAX; a missing directory is a home without transcripts."""
    dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fds = []
    try:
        try:
            fds.append(os.open(state_dir, dir_flags))
            for part in (name, "home", ".claude", "projects"):
                fds.append(os.open(part, dir_flags, dir_fd=fds[-1]))
        except FileNotFoundError:
            return
        except OSError:
            skipped["refused"] += 1
            return
        n = 0
        # directory order, unsorted: a guest's million entries cost time (its deadline share), not memory
        with os.scandir(fds[-1]) as projects:
            for d in projects:
                if time.monotonic() > DEADLINE:
                    raise TimeoutError("run deadline reached")
                if not d.is_dir(follow_symlinks=False):
                    skipped["refused"] += not d.is_file(follow_symlinks=False)
                    continue
                try:
                    pfd = os.open(d.name, dir_flags, dir_fd=fds[-1])
                except FileNotFoundError:
                    continue
                except OSError:
                    skipped["refused"] += 1
                    continue
                try:
                    with os.scandir(pfd) as files:
                        for e in files:
                            if time.monotonic() > DEADLINE:
                                raise TimeoutError("run deadline reached")
                            if not e.name.endswith(".jsonl"):
                                continue
                            if not e.is_file(follow_symlinks=False):
                                skipped["refused"] += 1
                                continue
                            try:
                                f = os.open(e.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=pfd)
                            except FileNotFoundError:
                                continue
                            except OSError:
                                skipped["refused"] += 1
                                continue
                            st = os.fstat(f)
                            if not stat.S_ISREG(st.st_mode):
                                why = "refused"
                            elif st.st_mtime < since:
                                why = "old"
                            elif st.st_size > FILE_MAX:
                                why = "too_large"
                            elif n >= FILES_MAX:
                                why = "too_many"
                            else:
                                n += 1
                                yield os.fdopen(f, "rb")
                                continue
                            os.close(f)
                            if why != "old":
                                skipped[why] += 1
                except TimeoutError:
                    raise
                except OSError:
                    skipped["refused"] += 1
                finally:
                    os.close(pfd)
    finally:
        for fd in fds:
            os.close(fd)


def scan(projects, since, files=None, **caps):
    """Every transcript's counts, by role: those under `projects`, or the open `files`. A file that vanishes or
    cannot be read is skipped."""
    t = {r: tally() for r in ROLES}
    for p in transcripts(projects, since) if files is None else files:
        try:
            scan_file(p, since, t, **caps)
        except TimeoutError:  # an OSError too, but the run's, not the file's
            raise
        except OSError as e:
            print(f"nav-metrics: a transcript was unreadable, skipped: {e.strerror}", file=sys.stderr)
            continue
    return t


def stretches(out, t, enough):
    for role, r in t.items():
        if not enough[role]:
            continue
        out.add("agent_nav_stretches", len(r["before"]), role=role)
        for q in (0.5, 0.9):
            if r["before"]:
                out.add("agent_nav_calls_before_first_edit", quantile(r["before"], q), role=role, quantile=str(q))
                out.add("agent_nav_topdirs_before_first_edit", quantile(r["dirs"], q), role=role, quantile=str(q))


def misses(out, t, enough):
    for role, r in t.items():
        if enough[role]:
            out.add("agent_nav_repo_miss_ratio", r["missed"] / r["judged"], role=role)


def rereads(out, t, enough):
    for role, r in t.items():
        if not enough[role]:
            continue
        out.add("agent_nav_repo_reads", r["reads"], role=role)
        if r["reads"]:
            out.add("agent_nav_repeat_read_ratio", r["repeats"] / r["reads"], role=role)


def previous_success(path):
    """The success timestamps of the last file, by (section, worker); the owner's have worker ""."""
    try:
        text = open(path).read()
    except OSError:
        return {}
    found = {}
    for m in re.finditer(r"^agent_nav_collector_success_timestamp_seconds\{([^}]*)\} (\S+)$", text, re.M):
        labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        if "section" in labels:
            found[labels["section"], labels.get("worker", "")] = float(m.group(2))
    return found


def collect(out, stamps, scan_fn, **labels):
    """The sections over one set of transcripts (scan_fn() -> tallies by role) into `out`, every series with `labels`;
    `stamps` holds the set's previous success timestamps by section and gets the new ones."""
    failed = {}

    # each section writes to its own Out, merged only when the whole section succeeded: no partial family
    def section(name, fn):
        part = Out(**labels)
        try:
            r = fn(part)
            stamps[name] = time.time()
            failed[name] = 0
            for k, rows in part.lines.items():
                out.lines.setdefault(k, []).extend(rows)
            return r
        # any error, an unexpected transcript shape included, costs this section alone its update
        except Exception as e:
            print(f"nav-metrics: {name} failed, its series are left out: {type(e).__name__}", file=sys.stderr)
            return None

    def sample(o):
        by_role = scan_fn()
        for role in ROLES:
            o.add("agent_nav_repo_nav_calls", by_role[role]["judged"], role=role)
        return by_role

    by_role = section("scan", sample)
    if by_role is not None:
        enough = {r: by_role[r]["judged"] >= MIN_SAMPLE for r in ROLES}
        section("stretches", lambda o: stretches(o, by_role, enough))
        section("misses", lambda o: misses(o, by_role, enough))
        section("rereads", lambda o: rereads(o, by_role, enough))
    for name in SECTIONS:
        # a section that did not run (scan failed) failed
        out.add("agent_nav_collector_section_failed", failed.get(name, 1), section=name, **labels)
        if name in stamps:
            out.add("agent_nav_collector_success_timestamp_seconds", stamps[name], section=name, **labels)


def worker_name(s):
    if not WORKER_RE.fullmatch(s):
        raise argparse.ArgumentTypeError(f"{s!r} is not an instance name ([a-z][a-z0-9-]{{0,10}})")
    return s


def main(argv=None):
    global DEADLINE, HOME, REPO_RE
    p = argparse.ArgumentParser()
    p.add_argument("--list", action="store_true")
    p.add_argument("--out")
    p.add_argument("--projects", default=os.path.join(HOME, ".claude", "projects"))
    p.add_argument("--hours", type=float, default=24)
    p.add_argument("--state-dir", help="the dev environments' state dir: <state-dir>/<worker>/home is a guest's home")
    p.add_argument("--home", help="the guests' home as they see it, which their transcripts' paths name")
    p.add_argument("--worker", type=worker_name, action="append", default=[], help="a declared instance; repeatable")
    a = p.parse_args(argv)
    if a.list:
        print("\n".join(METRICS))
        return 0
    since = time.time() - a.hours * 3600
    out = Out()
    previous = previous_success(a.out)
    if not a.worker:
        collect(out, {s: v for (s, w), v in previous.items() if not w}, lambda: scan(a.projects, since))
    else:
        if not (a.state_dir and a.home and os.path.isabs(a.home)):
            p.error("--worker needs --state-dir and an absolute --home")
        HOME, REPO_RE = a.home.rstrip("/") or "/", repo_re(a.home.rstrip("/") or "/")
        end = DEADLINE
        workers = sorted(set(a.worker))
        for i, w in enumerate(workers):
            # an equal share of what is left: a guest that spends its own share costs the others nothing
            DEADLINE = min(end, time.monotonic() + (end - time.monotonic()) / (len(workers) - i))
            skipped = dict.fromkeys(SKIPS, 0)
            files = guest_transcripts(a.state_dir, w, since, skipped)
            caps = {"line_max": LINE_MAX, "byte_max": FILE_MAX}
            collect(out, {s: v for (s, ww), v in previous.items() if ww == w},
                    lambda: scan(None, since, files, **caps), worker=w)
            files.close()
            for r in SKIPS:
                out.add("agent_nav_collector_skipped", skipped[r], reason=r, worker=w)
        DEADLINE = end
    tmp = f"{a.out}.tmp"
    with open(tmp, "w") as f:
        f.write(out.text())
    os.replace(tmp, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
