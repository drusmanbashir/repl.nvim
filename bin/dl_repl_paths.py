#!/usr/bin/env python3
"""Shell-side port of nvim/lua/user/repl/paths.lua.

Same rules, same outputs. The two implementations are pinned together by
nvim/tests/repl_paths_parity_smoke.sh -- if you change one, change the other in
the same commit or that test fails.

Importable (``from dl_repl_paths import socket``) and runnable::

    dl_repl_paths.py --json
    dl_repl_paths.py --get socket:python
    dl_repl_paths.py --get state_file
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import sys

# Socket basename per family; mirrors FAMILY_BASE in repl/paths.lua.
FAMILY_BASE = {
    "python": "dl-repl",
    "r": "dl-r-repl",
    "lua": "dl-lua-repl",
}

# Per-family user override. Distinct from DL_REPL_SOCKET, which dl-session-env
# exports -- a variable the tooling writes cannot also mean "user pinned this".
FAMILY_OVERRIDE = {
    "python": "DL_REPL_SOCKET_OVERRIDE",
    "r": "DL_R_REPL_SOCKET_OVERRIDE",
    "lua": "DL_LUA_REPL_SOCKET_OVERRIDE",
}

# Session-scoped socket exported by mac/dl-session-env; consumed, never written.
FAMILY_SESSION = {
    "python": "DL_REPL_SOCKET",
    "r": "DL_R_REPL_SOCKET",
    "lua": "DL_LUA_REPL_SOCKET",
}

FAMILIES = ["python", "r", "lua"]

_NAMESPACE_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


def _env(name):
    value = os.environ.get(name)
    if value:
        return value
    return None


def sysname():
    # DL_REPL_PATHS_SYSNAME lets one host exercise the other's branch in tests.
    return _env("DL_REPL_PATHS_SYSNAME") or platform.system()


def is_darwin():
    return sysname() == "Darwin"


def runtime_dir():
    """Runtime directory for sockets and focus state.

    Deliberately does NOT consult TMPDIR: on macOS it is per-login-session, so
    launchd/cron/ssh contexts resolve a different directory than the GUI
    session and stop seeing its sockets.
    """
    return _env("DL_RUNTIME_DIR") or _env("XDG_RUNTIME_DIR") or "/tmp"


def uid():
    override = _env("DL_REPL_PATHS_UID")
    if override is not None:
        try:
            return int(override)
        except ValueError:
            return 0
    return os.getuid()


def namespace():
    """Sanitised session namespace, or None.

    Mirrors mac/dl-session-env (`tr -cs 'A-Za-z0-9._-' '-'`, then strip edges).
    Sinclair has no dl-session-env, so namespaces are Darwin-only.
    """
    raw = _env("DL_SESSION_NAMESPACE")
    if not raw or not is_darwin():
        return None
    safe = _NAMESPACE_UNSAFE.sub("-", raw).strip("-")
    return safe or None


def _socket_for(base, family):
    if family:
        override = _env(FAMILY_OVERRIDE.get(family, ""))
        if override:
            return override
        session = _env(FAMILY_SESSION.get(family, ""))
        if session:
            return session

    runtime = runtime_dir()
    if not is_darwin():
        # Byte-identical to the pre-resolver expression on Sinclair.
        return f"unix:{runtime}/{base}-kitty.sock"

    name = f"{base}-kitty-{uid()}"
    ns = namespace()
    if ns:
        name = f"{name}-{ns}"
    return f"unix:{runtime}/{name}.sock"


def socket(family):
    base = FAMILY_BASE.get(family)
    if not base:
        return None
    return _socket_for(base, family)


def edit_socket():
    override = _env("DL_EDIT_SOCKET_OVERRIDE")
    if override:
        return override
    session = _env("DL_EDIT_SOCKET")
    if session:
        return session
    return _socket_for("dl-edit", None)


def state_file():
    return _env("DL_FOCUS_SLIME_STATE_FILE") or (runtime_dir() + "/kitty-focus-slime-target.json")


def registry_file():
    return (
        _env("DL_FOCUS_SLIME_REGISTRY_FILE")
        or _env("DL_FOCUS_SLIME_PAIR_FILE")
        or (runtime_dir() + "/kitty-focus-slime-pair.json")
    )


# CCC gives every kitty OS window its own control socket (kitty.conf
# `listen_on unix:/tmp/kitty-focus.sock` -> `kitty-focus.sock-<pid>`; a normal
# Mac session has several). Probing those lets a REPL pair itself to an agent
# pane, so they are excluded by name.
#
# Excluded by name rather than by requiring a `dl-` prefix: focus resolution
# must still discover *non-canonical* kitty instances (a plain `regular-r-kitty.sock`
# holding an R session), which is how a focused non-dl REPL overrides stale
# family state.
SOCKET_EXCLUDES = ("kitty-focus.sock",)


def socket_globs():
    """Globs for "other kitty sockets worth probing"."""
    return ["/*kitty*.sock", "/*kitty*.sock-*"]


def socket_excluded(path):
    """True for sockets that must never be probed (see SOCKET_EXCLUDES)."""
    name = os.path.basename(path)
    return any(name.startswith(prefix) for prefix in SOCKET_EXCLUDES)


def discoverable_sockets(runtime=None):
    """Every probe-worthy kitty socket under `runtime`, CCC's excluded."""
    import glob as _glob

    base = runtime if runtime is not None else runtime_dir()
    found = set()
    for pattern in socket_globs():
        for path in _glob.glob(base + pattern):
            if not socket_excluded(path):
                found.add(path)
    return sorted(found)


def tmux_target():
    explicit = _env("NVIM_SLIME_TMUX_REPL_TARGET")
    if explicit:
        return explicit
    ns = namespace()
    if ns:
        return f"dlmain-{ns}:1"
    return "dlmain:1"


def dump():
    return {
        "sysname": sysname(),
        "runtime_dir": runtime_dir(),
        "namespace": namespace() or "",
        "sockets": {family: socket(family) for family in FAMILIES},
        "edit_socket": edit_socket(),
        "state_file": state_file(),
        "registry_file": registry_file(),
        "socket_globs": socket_globs(),
        "tmux_target": tmux_target(),
    }


def _get(path):
    data = dump()
    parts = path.split(":", 1)
    if parts[0] == "socket" and len(parts) == 2:
        return data["sockets"].get(parts[1]) or ""
    value = data.get(parts[0])
    if isinstance(value, list):
        return " ".join(value)
    return "" if value is None else str(value)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the full resolved table")
    parser.add_argument("--get", metavar="KEY", help="print one value (e.g. socket:python)")
    args = parser.parse_args(argv)

    if args.get:
        print(_get(args.get))
        return 0
    if args.json or True:
        json.dump(dump(), sys.stdout, sort_keys=True)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
