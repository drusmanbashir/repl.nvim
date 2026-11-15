#!/usr/bin/env python3
"""Transport stop for the REPL send battery: stands in for the `kitty` CLI.

REPL_ROUTING.md § `M-x` cell-send contract. The product route ends in
`kitty @ --to <sock> send-text --match id:<N> --stdin` (vim-slime's kitty
target). Real kitty writes those stdin bytes verbatim to the window's pty
(`--stdin`: "the text is sent as is"; `--bracketed-paste` defaults to disable,
so the ESC[200~ wrapping is vim-slime's own). This stand-in records the same
bytes, one file per send-text call, and never touches a real kitty.

  @ ... ls          -> prints the tree in $BATTERY_FAKE_TREE (the bound REPL window)
  @ ... send-text   -> stdin bytes to $BATTERY_CAPTURE_DIR/send-NNN.bin
  anything else     -> logged to argv.log, exit 0 (no window is ever touched)

Cannot evidence: kitty's own pty write, key delivery, window focus.
"""
import json
import os
import sys


def capture_dir():
    path = os.environ["BATTERY_CAPTURE_DIR"]
    os.makedirs(path, exist_ok=True)
    return path


def log(argv):
    with open(os.path.join(capture_dir(), "argv.log"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(argv) + "\n")


def next_send_path():
    base = capture_dir()
    n = len([name for name in os.listdir(base) if name.startswith("send-")])
    return os.path.join(base, "send-%03d.bin" % (n + 1))


def main(argv):
    log(argv)
    if "ls" in argv:
        with open(os.environ["BATTERY_FAKE_TREE"], encoding="utf-8") as fh:
            sys.stdout.write(fh.read())
        return 0
    if "send-text" in argv:
        if "--stdin" not in argv:
            sys.stderr.write("fake kitty: send-text without --stdin is not modelled\n")
            return 3
        data = sys.stdin.buffer.read()
        with open(next_send_path(), "wb") as fh:
            fh.write(data)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
