#!/usr/bin/env python3
"""REPL send battery, judge half (REPL_ROUTING.md § `M-x` cell-send contract).

PURPOSE: reds when a code block the editor sends to IPython drops a source line,
raises SyntaxError/IndentationError (or any error the fixture does not expect),
fails to run, runs when it should be left waiting for the rest of an open block,
or waits when it should run.

For one case it reads what capture.lua recorded at the kitty transport, checks
each payload line by line against the fixture's source lines (an indentation
shift is allowed, a missing line is not), then writes the same bytes kitty
would write into a REAL IPython running in a pty (bracketed paste, then the
separate Enter), and judges what IPython reports through ipython_probe.py.

Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE. Prints one line starting with the verdict.
Cannot evidence: kitty's pty write itself, physical key delivery, rendering.
"""
import argparse
import difflib
import json
import os
import re
import shutil
import sys
import time

import pexpect

PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"
FENCE_KEY = b"\x1b[34~"  # F20, bound by ipython_probe.py
CPR_QUERY = b"\x1b[6n"
ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\x1b[=>]")


class Inconclusive(Exception):
    pass


def load_case(cases_path, case_id):
    with open(cases_path, encoding="utf-8") as fh:
        table = json.load(fh)
    for case in table["cases"]:
        if case["id"] == case_id:
            return table, case
    raise Inconclusive("no case %s in %s" % (case_id, cases_path))


# ---------------------------------------------------------------- payload ---
def split_paste(data):
    """Return (paste_text, trailer) for one step's bytes, or (None, data)."""
    start = data.find(PASTE_START)
    end = data.find(PASTE_END)
    if start != 0 or end < 0:
        return None, data
    return data[len(PASTE_START):end].decode("utf-8", "replace"), data[end + len(PASTE_END):]


def norm(line, verbatim):
    """Comparison key: a blank line is "", else the line (without its indent
    unless verbatim). A trailing CR is the paste's protocol, not text."""
    line = line[:-1] if line.endswith("\r") else line
    if line.strip() == "":
        return ""
    return line if verbatim else line.lstrip(" \t")


def check_payload(source_lines, first, paste_text, verbatim):
    """Every source line, in order; extra lines may only be blank/CR protocol.

    Inside a bracketed paste prompt_toolkit turns a CR into a newline, so a
    blank source line may arrive as a protocol CR line: IPython still gets it.
    Code and comment lines are aligned by longest common subsequence
    (difflib), so one stray line cannot make the report blame the wrong
    source lines; blank lines are then counted gap by gap between them.
    """
    src = [norm(line, verbatim) for line in source_lines]
    pay = [norm(line, verbatim) for line in paste_text.split("\n")]
    src_code = [i for i, line in enumerate(src) if line != ""]
    pay_code = [j for j, line in enumerate(pay) if line != ""]
    matcher = difflib.SequenceMatcher(None, [src[i] for i in src_code], [pay[j] for j in pay_code], autojunk=False)
    pairs = []
    for a, b, size in matcher.get_matching_blocks():
        pairs.extend((src_code[a + k], pay_code[b + k]) for k in range(size))
    matched_src = {i for i, _ in pairs}
    matched_pay = {j for _, j in pairs}
    missing = [i for i in src_code if i not in matched_src]
    foreign = [pay[j] for j in pay_code if j not in matched_pay]
    # Blank lines: between two matched lines the payload must carry at least
    # as many blank lines as the source has there (extra ones are protocol).
    bounds = [(-1, -1)] + pairs + [(len(src), len(pay))]
    for (s0, p0), (s1, p1) in zip(bounds, bounds[1:]):
        blanks = [i for i in range(s0 + 1, s1) if src[i] == ""]
        carried = sum(1 for j in range(p0 + 1, p1) if pay[j] == "")
        missing.extend(blanks[carried:])
    missing.sort()
    problems = []
    if verbatim:
        # A line present but re-indented is its own defect on a verbatim step.
        pool = [line.lstrip(" \t") for line in foreign]
        moved = [k for k in missing if source_lines[k].strip() and source_lines[k].lstrip(" \t") in pool]
        for k in moved:
            pool.remove(source_lines[k].lstrip(" \t"))
        if moved:
            problems.append("payload re-indents %d line(s) that must arrive unshifted (block continuing a held "
                            "header), e.g. line %d %r" % (len(moved), first + moved[0], source_lines[moved[0]][:60]))
            missing = [k for k in missing if k not in moved]
            foreign = pool
    if missing:
        shown = ", ".join(str(first + k) for k in missing[:12]) + (" ..." if len(missing) > 12 else "")
        code = [k for k in missing if source_lines[k].strip()]
        example = (" e.g. line %d %r" % (first + code[0], source_lines[code[0]].strip()[:60])) if code else " (blank)"
        problems.append("payload drops %d source line(s): %s%s" % (len(missing), shown, example))
    if foreign:
        problems.append("payload has %d line(s) not in the source%s, e.g. %r"
                        % (len(foreign), " (or re-indented: verbatim step)" if verbatim else "", foreign[0][:80]))
    return problems


# ---------------------------------------------------------------- ipython ---
class IPythonPty:
    """One private IPython in a pty, configured like the operator's REPL."""

    def __init__(self, python, work, case, stubs_root):
        self.events_path = os.path.join(work, "events.jsonl")
        ipdir = os.path.join(work, "ipython")
        os.makedirs(os.path.join(ipdir, "profile_default", "startup"), exist_ok=True)
        here = os.path.dirname(os.path.abspath(__file__))
        shutil.copy(os.path.join(here, "ipython_probe.py"),
                    os.path.join(ipdir, "profile_default", "startup", "00-battery.py"))
        env = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "TMUX", "MPLBACKEND"):
            env.pop(name, None)
        self.watch_path = os.path.join(work, "watch.json")
        self.watch([])
        seed = ""
        if case.get("seed"):
            with open(os.path.join(here, "seeds", case["seed"]), encoding="utf-8") as fh:
                seed = fh.read()
        env.update(
            IPYTHONDIR=ipdir,
            BATTERY_EVENTS=self.events_path,
            BATTERY_WATCH_FILE=self.watch_path,
            BATTERY_SEED=seed,
            TERM="xterm-256color",
            MPLBACKEND="Agg",
            PYTHONDONTWRITEBYTECODE="1",  # never write __pycache__ into the tree
        )
        env["PYTHONPATH"] = os.path.join(stubs_root, "stubs")  # seeds' stand-ins
        # Mirrors bin/slime-repl-restart start-ipython and the operator's
        # profile (editing_mode = "vi"); history lives in the private dir.
        argv = ["-m", "IPython", "--no-autoindent", "--TerminalInteractiveShell.term_title=False",
                "--TerminalInteractiveShell.editing_mode=vi", "--no-banner"]
        self.transcript = bytearray()
        self.child = pexpect.spawn(python, argv, env=env, cwd=work, dimensions=(50, 200))
        self.fences = 0
        self.wait_fence(timeout=90)

    def watch(self, expressions):
        with open(self.watch_path, "w", encoding="utf-8") as fh:
            json.dump(list(expressions), fh)

    def pump(self, timeout=0.05):
        try:
            data = self.child.read_nonblocking(65536, timeout=timeout)
        except pexpect.TIMEOUT:
            return
        except pexpect.EOF:
            raise Inconclusive("IPython exited: " + self.tail())
        self.transcript.extend(data)
        for _ in range(data.count(CPR_QUERY)):
            self.child.send(b"\x1b[20;1R")  # a terminal answers cursor-position requests

    def events(self):
        if not os.path.exists(self.events_path):
            return []
        with open(self.events_path, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def wait_fence(self, timeout=60):
        self.child.send(FENCE_KEY)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not self.child.isalive():
                raise Inconclusive("IPython died: " + self.tail())
            self.pump()
            fences = [e for e in self.events() if e["kind"] == "fence"]
            if len(fences) > self.fences:
                self.fences = len(fences)
                return fences[-1]
        raise Inconclusive("IPython never reached the fence within %ss: %s" % (timeout, self.tail()))

    def deliver(self, chunks):
        before = len([e for e in self.events() if e["kind"] == "run"])
        for chunk in chunks:
            self.child.send(chunk)
        fence = self.wait_fence()
        runs = [e for e in self.events() if e["kind"] == "run"][before:]
        return fence, runs

    def tail(self, n=800):
        return ANSI.sub(b"", bytes(self.transcript[-n:])).decode("utf-8", "replace")

    def close(self):
        if self.child.isalive():
            self.child.terminate(force=True)


# ------------------------------------------------------------------- judge ---
def judge_step(n, step, mstep, chunks, fixture_lines, ipy, evidence):
    problems = []
    data = b"".join(chunks)
    with open(os.path.join(evidence, "payload-step%d.txt" % n), "w", encoding="utf-8") as fh:
        fh.write(repr(data))
    source = step.get("source")
    if not chunks:
        problems.append("the route sent nothing")
    elif source:
        paste_text, trailer = split_paste(data)
        if paste_text is None:
            problems.append("payload is not one bracketed paste: %r" % data[:120])
        else:
            first, last = source
            problems += check_payload(fixture_lines[first - 1:last], first, paste_text, step.get("verbatim", False))
            trailers = (b"\n", b"\r")
            if step.get("expect", {}).get("state") == "waiting":
                trailers += (b"",)  # item 4: a held paste has no execution Enter
            if trailer not in trailers:
                problems.append("payload trailer after the paste is %r, expected %r" % (trailer, trailers))
    want_cursor = step.get("cursor_after")
    if want_cursor and mstep["cursor_after"][0] != want_cursor:
        problems.append("cursor landed on line %d, expected %d" % (mstep["cursor_after"][0], want_cursor))
    expect = step.get("expect", {})
    ipy.watch(expect.get("values", {}).keys())
    fence, runs = ipy.deliver(chunks)
    state = "waiting" if fence["buffer"].strip() else "idle"
    failed = [r for r in runs if not r["ok"]]
    want_errors = expect.get("errors", [])
    got_errors = [r["error"] for r in failed]
    if got_errors != want_errors:
        for r in failed:
            first = (r["message"] or "").splitlines()
            problems.append("IPython raised %s: %s" % (r["error"], first[0][:160] if first else ""))
        if want_errors and not failed:
            problems.append("IPython raised nothing, expected %s" % ", ".join(want_errors))
    if expect.get("state") and state != expect["state"]:
        detail = " (pending input %r)" % fence["buffer"][-80:] if state == "waiting" else ""
        problems.append("IPython is %s, expected %s%s" % (state, expect["state"], detail))
    for name in expect.get("names", []):
        if name not in fence["names"]:
            problems.append("name %s is not defined in IPython" % name)
    for name, want in expect.get("values", {}).items():
        got = fence["values"].get(name)
        if got != want:
            problems.append("%s = %s, expected %s" % (name, got, want))
    for name in expect.get("absent", []):
        if name in fence["names"]:
            problems.append("name %s should not exist (that code should not have run)" % name)
    return problems, {"state": state, "runs": runs, "buffer": fence["buffer"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--case", required=True)
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--capture", required=True)
    ap.add_argument("--python", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--evidence", required=True)
    args = ap.parse_args()
    os.makedirs(args.evidence, exist_ok=True)
    ipy = None
    try:
        _, case = load_case(args.cases, args.case)
        with open(os.path.join(args.capture, "manifest.json"), encoding="utf-8") as fh:
            manifest = json.load(fh)
        shutil.copy(os.path.join(args.capture, "manifest.json"), os.path.join(args.evidence, "manifest.json"))
        if manifest.get("error"):
            print("FAIL %s capture: the editor route raised: %s" % (case["id"], manifest["error"].splitlines()[0]))
            return 1
        with open(args.fixture, encoding="utf-8") as fh:
            fixture_lines = fh.read().split("\n")
        stubs_root = os.path.dirname(os.path.abspath(__file__))
        ipy = IPythonPty(args.python, args.work, case, stubs_root)
        verdicts = []
        all_problems = []
        for n, step in enumerate(case["steps"], 1):
            mstep = manifest["steps"][n - 1]
            chunks = []
            for name in mstep["sends"]:
                with open(os.path.join(args.capture, name), "rb") as fh:
                    chunks.append(fh.read())
            problems, observed = judge_step(n, step, mstep, chunks, fixture_lines, ipy, args.evidence)
            verdicts.append({"step": n, "problems": problems, "observed": observed, "manifest": mstep})
            all_problems += ["step%d: %s" % (n, p) for p in problems]
        with open(os.path.join(args.evidence, "verdict.json"), "w", encoding="utf-8") as fh:
            json.dump(verdicts, fh, indent=1)
        if all_problems:
            print("FAIL %s %s" % (case["id"], " | ".join(all_problems)))
            return 1
        print("PASS %s %s" % (case["id"], case["purpose"]))
        return 0
    except Inconclusive as exc:
        print("INCONCLUSIVE %s %s" % (args.case, exc))
        return 2
    finally:
        if ipy is not None:
            with open(os.path.join(args.evidence, "transcript.txt"), "wb") as fh:
                fh.write(ANSI.sub(b"", bytes(ipy.transcript)))
            if os.path.exists(ipy.events_path):
                shutil.copy(ipy.events_path, os.path.join(args.evidence, "events.jsonl"))
            ipy.close()


if __name__ == "__main__":
    sys.exit(main())
