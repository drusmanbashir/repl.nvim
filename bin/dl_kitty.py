"""Shared kitty/JSON/process layer for the dl focus helpers.

`bin/kitty-focus-slime-source` (the `<M-l>` reverse jump) and
`bin/kitty-focus-slime-target` (the forward bind/focus) each carried their own copy
of this layer -- about 120 lines, function for function. Copies do not stay
equal: by the time this module was extracted the two had already drifted in ways
that were live bugs, which is the whole argument for having one copy.

WHAT IS HERE: only the functions that were byte-for-byte identical in both
scripts, so importing this changes no behaviour anywhere.

WHAT IS DELIBERATELY NOT HERE, and must not be quietly merged in later without
its own Oracle coverage -- these are real differences, not oversights:

  - `raise_os_window`   source bounds the xdotool/osascript call (`timeout=2`)
                        and guards a missing platform id; target still uses an
                        unbounded `check_call`.
  - `window_matches_family`
                        target additionally accepts an R window by title
                        (`is_r_window`); source matches on process text only.
  - `focus_window`      source writes the kitty command over one already-open
                        AF_UNIX connection (the change that took `<M-l>` from
                        ~430ms to ~95ms); target still spawns `kitty @`.
  - `known_sockets`     genuinely different inputs on each side.

Import from a script that has already put `<root>/bin` on `sys.path`:

    import dl_kitty
"""

from __future__ import annotations

import json
import os
import re
import subprocess

# ---------------------------------------------------------------------------
# JSON / registry
# ---------------------------------------------------------------------------


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def window_key(payload):
    """Stable `listen_on::window_id` identity for one kitty window."""
    if not isinstance(payload, dict):
        return None
    listen_on = payload.get("listen_on")
    window_id = payload.get("window_id")
    if not listen_on or window_id in (None, ""):
        return None
    return f"{listen_on}::{int(window_id)}"



def load_registry(registry_file):
    """The pair registry with its three index dicts guaranteed present.

    A missing or non-dict file yields an empty registry rather than raising --
    callers treat "no pairs" as a miss, never as an error.
    """
    registry = {}
    if os.path.exists(registry_file):
        loaded = load_json(registry_file)
        if isinstance(loaded, dict):
            registry = loaded
    pairs = registry.get("_pairs")
    by_source = registry.get("_by_source")
    by_target = registry.get("_by_target")
    registry["_pairs"] = pairs if isinstance(pairs, dict) else {}
    registry["_by_source"] = by_source if isinstance(by_source, dict) else {}
    registry["_by_target"] = by_target if isinstance(by_target, dict) else {}
    return registry


# ---------------------------------------------------------------------------
# kitty remote control
# ---------------------------------------------------------------------------


def kitty_ls(kitty_bin, socket):
    raw = subprocess.check_output(
        [kitty_bin, "@", "--to", socket, "ls"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    return json.loads(raw)


def try_kitty_ls(kitty_bin, socket):
    """`kitty_ls` or None. A dead socket is an ordinary outcome here: both
    helpers probe several sockets and expect most of them not to answer."""
    try:
        return kitty_ls(kitty_bin, socket)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Process identification
# ---------------------------------------------------------------------------


def process_text(process):
    """Flatten whatever argv-ish keys kitty reported into one searchable string."""
    if not isinstance(process, dict):
        return str(process or "")
    parts = []
    for key in ("cmdline", "argv", "command", "cmd", "exe"):
        if key not in process:
            continue
        value = process[key]
        if isinstance(value, list):
            parts.append(" ".join(str(item) for item in value))
        else:
            parts.append(str(value))
    return " ".join(parts)


def contains_word(text, word):
    """Whole-word match. `R` must not match `Rscript`, `PATH` or `/usr/R6/bin`."""
    return re.search(r"(^|[^A-Za-z0-9_])" + re.escape(word) + r"($|[^A-Za-z0-9_])", text) is not None


def is_python_process(process):
    return "ipython" in process_text(process)


def is_r_process(process):
    text = process_text(process)
    return contains_word(text, "R") or contains_word(text, "arf") or contains_word(text, "radian")


def is_lua_process(process):
    text = process_text(process)
    return contains_word(text, "lua") or contains_word(text, "luajit")


# ---------------------------------------------------------------------------
# Window resolution
# ---------------------------------------------------------------------------


def active_window_in_os_window(os_window):
    """The kitty window a user would call "current" inside one OS window.

    kitty omits `is_active` in more situations than is obvious -- a tab that has
    never been rendered, a window restored from a session file -- so the
    `*_history` lists are the fallback, and the first window is the last resort.
    The Mac fork once carried a thinner copy that scanned `is_active` only and
    silently resolved nothing in those cases.
    """
    tabs = os_window.get("tabs", [])
    tab = next((candidate for candidate in tabs if candidate.get("is_active")), None)
    if tab is None:
        active_tab_id = None
        history = os_window.get("active_tab_history") or []
        if history:
            active_tab_id = history[0]
        for candidate in tabs:
            if active_tab_id is not None and candidate.get("id") == active_tab_id:
                tab = candidate
                break
    if tab is None and tabs:
        tab = tabs[0]
    if tab is None:
        return None

    windows = tab.get("windows", [])
    for window in windows:
        if window.get("is_active"):
            return window

    active_window_id = None
    history = tab.get("active_window_history") or []
    if history:
        active_window_id = history[0]
    for window in windows:
        if active_window_id is not None and window.get("id") == active_window_id:
            return window
    return windows[0] if windows else None


def active_platform_window_id_linux(xdotool_bin):
    """X11 EWMH active window id, or None.

    Note for readers chasing a focus bug: on the GNOME session this repo targets
    `_NET_ACTIVE_WINDOW` is frequently NOT maintained, so this returns None even
    while a window plainly has the keyboard. Callers must treat None as "could
    not tell" and fall through to another route, never as "nothing is focused".
    """
    try:
        output = subprocess.check_output([xdotool_bin, "getactivewindow"], text=True).strip()
    except Exception:
        return None
    return int(output) if output.isdigit() else None
