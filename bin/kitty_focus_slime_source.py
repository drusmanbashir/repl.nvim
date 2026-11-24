import json
import os
import platform
import socket
import subprocess
import sys
import time

registry_arg, kitty_bin, osascript_bin, xdotool_bin, root = sys.argv[1:6]
pressing_window_arg = sys.argv[6]
now = time.time()

sys.path.insert(0, os.path.join(root, "bin"))
import dl_repl_paths  # noqa: E402  (path set above)
import dl_kitty  # noqa: E402  (shared layer; see its docstring for what is NOT shared)
import dl_repl_gate  # noqa: E402  (the backend policy, single Python authority)

# Resolver-owned paths, resolved in-process; see mac/kitty-focus-slime-target for
# why TMPDIR is never consulted. An explicit registry arg wins over the default.
state_file = dl_repl_paths.state_file()
registry_file = registry_arg or dl_repl_paths.registry_file()

runtime = dl_repl_paths.runtime_dir()
MAX_STATE_BYTES = 1024 * 1024

FAMILY_BY_SOCKET = {
    dl_repl_paths.socket(family): family for family in dl_repl_paths.FAMILIES
}


# Shared layer. Bound to local names so every call site below is unchanged.
load_json = dl_kitty.load_json
process_text = dl_kitty.process_text
contains_word = dl_kitty.contains_word
is_python_process = dl_kitty.is_python_process
is_r_process = dl_kitty.is_r_process
is_lua_process = dl_kitty.is_lua_process
is_octave_process = dl_kitty.is_octave_process
active_window_in_os_window = dl_kitty.active_window_in_os_window


def try_kitty_ls(socket):
    return dl_kitty.try_kitty_ls(kitty_bin, socket)


def window_matches_family(window, family):
    if family == "python":
        matcher = is_python_process
    elif family == "r":
        matcher = is_r_process
    elif family == "lua":
        matcher = is_lua_process
    elif family == "octave":
        matcher = is_octave_process
    elif family == "sage":
        matcher = dl_kitty.is_sage_process
    else:
        return False
    if matcher(window):
        return True
    for process in window.get("foreground_processes", []):
        if matcher(process):
            return True
    return False


def sockets_from_registry(registry):
    candidates = set()
    for entry in registry.get("_pairs", {}).values():
        if not isinstance(entry, dict):
            continue
        for role in ("source", "target"):
            listen_on = ((entry.get(role) or {}).get("listen_on"))
            if listen_on:
                candidates.add(listen_on)
    for family, entry in registry.items():
        if family.startswith("_") or not isinstance(entry, dict):
            continue
        for role in ("source", "target"):
            listen_on = ((entry.get(role) or {}).get("listen_on"))
            if listen_on:
                candidates.add(listen_on)
    return candidates


def known_sockets(extra_sockets=None):
    candidates = set(FAMILY_BY_SOCKET)
    for socket in extra_sockets or ():
        if socket:
            candidates.add(socket)
    for path in dl_repl_paths.discoverable_sockets(runtime):
        candidates.add("unix:" + path)
    return sorted(socket for socket in candidates if socket and socket.startswith("unix:"))


# Platform layer -- mirrors bin/kitty-focus-slime-target. DL_FOCUS_PLATFORM
# overrides the uname probe so either branch is testable from either host.
PLATFORM = os.environ.get("DL_FOCUS_PLATFORM") or platform.system()
IS_DARWIN = PLATFORM == "Darwin"


def _input_focus_platform_window_id_linux():
    try:
        output = subprocess.check_output(
            [xdotool_bin, "getwindowfocus"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return int(output) if output.isdigit() else None


def raise_os_window(platform_window_id):
    """Front the OS window. On GNOME `kitty @ focus-window` alone does not
    raise across workspaces, so the xdotool step is load-bearing. Bounded so a
    wedged window manager or focus-steal prevention can never hang the keypress;
    a timeout counts as a failure."""
    if IS_DARWIN:
        subprocess.run(
            [osascript_bin, "-e", 'tell application "kitty" to activate'],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
        return
    if platform_window_id:
        subprocess.run(
            [xdotool_bin, "windowactivate", "--sync", str(platform_window_id)],
            check=True,
            timeout=2,
        )


def kitty_socket_path(listen_on):
    """Filesystem/abstract path for a `unix:` listen_on, mirroring socket_path()
    in lua/repl/focus.lua: a leading `@` after `unix:` is the Linux
    abstract namespace (leading NUL byte); anything else is a pathname socket."""
    path = listen_on[len("unix:"):] if listen_on.startswith("unix:") else listen_on
    if path[:1] == "@":
        return "\0" + path[1:]
    return path


def send_focus(connection, window_id):
    # Same escape the Neovim side uses (focus_kitty_child): no_response means
    # there is nothing to read back on the connection.
    command = "\033P@kitty-cmd" + json.dumps({
        "cmd": "focus-window",
        "no_response": True,
        "payload": {"match": f"id:{window_id}"},
        "version": [0, 14, 2],
    }) + "\033\\"
    connection.sendall(command.encode("utf-8"))


def focus_window(listen_on, window_id, platform_window_id=None):
    window_id = str(window_id)
    # Connect before we activate the OS window. If the source kitty is
    # unreachable we must fail while the REPL is still the active OS window --
    # otherwise the caller's fallback chain runs against an active-window state
    # we already changed and can resolve a different target than it would have.
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(kitty_socket_path(listen_on))
    try:
        # Keep today's select/activate/select. Collapsing it to one post-raise
        # selection is a separate, Oracle-gated change with no <M-l> coverage
        # yet; on the already-open connection each select costs about a ms.
        send_focus(connection, window_id)
        raise_os_window(platform_window_id)
        send_focus(connection, window_id)
    finally:
        connection.close()


def detect_active_target(extra_sockets=None, expected_window_id=None):
    if IS_DARWIN:
        # macOS has no _NET_ACTIVE_WINDOW; kitty's own os_window `is_focused`
        # is the platform-neutral equivalent.
        matches = lambda os_window: bool(os_window.get("is_focused"))  # noqa: E731
    else:
        active_platform_id = _input_focus_platform_window_id_linux()
        if not active_platform_id:
            return None
        matches = lambda os_window: (  # noqa: E731
            int(os_window.get("platform_window_id") or -1) == active_platform_id
        )

    for socket in known_sockets(extra_sockets):
        tree = try_kitty_ls(socket)
        if tree is None:
            continue
        for os_window in tree:
            if not matches(os_window):
                continue
            window = active_window_in_os_window(os_window)
            if not window:
                continue
            if expected_window_id and int(window.get("id") or -1) != expected_window_id:
                continue
            family = FAMILY_BY_SOCKET.get(socket)
            if window_matches_family(window, "sage"):
                family = "sage"
            elif window_matches_family(window, "octave"):
                family = "octave"
            elif family in ("octave", "sage"):
                family = None
            if not family:
                for candidate in ("python", "r", "lua"):
                    if window_matches_family(window, candidate):
                        family = candidate
                        break
            if not family:
                continue
            return {
                "family": family,
                "listen_on": socket,
                "window_id": int(window.get("id")),
                "platform_window_id": os_window.get("platform_window_id"),
            }
    return None


window_key = dl_kitty.window_key


def load_registry():
    return dl_kitty.load_registry(registry_file)


def read_state():
    if not os.path.exists(state_file):
        return {}, False
    try:
        if os.stat(state_file).st_size > MAX_STATE_BYTES:
            return {}, True
        state = load_json(state_file)
    except (OSError, ValueError, UnicodeDecodeError):
        return {}, True
    if not isinstance(state, dict):
        return {}, True
    return state, False


def route_for_target(platform_window_id, kitty_window_id):
    if not platform_window_id or not kitty_window_id:
        return None
    path = os.path.join(
        state_file + ".routes",
        f"{platform_window_id}.{kitty_window_id}.json",
    )
    try:
        route = load_json(path)
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(route, dict):
        return None
    source = route.get("source") or {}
    if not source.get("listen_on") or source.get("window_id") in (None, ""):
        return None
    return {"source": source}


def lab_route_for_focused_window():
    """alt+l from the JupyterLab browser window.

    A browser window has no kitty child behind it, so it cannot be keyed like a
    REPL child. Neovim's `<M-h>` raise records `lab.<x11-window-id>.json` in the
    same routes directory with the same `source` shape, so the entry goes to the
    same focus_entry() below -- one reader, one raiser, two key spaces.

    Costs nothing when nobody is using Lab: one listdir, and the xdotool call
    that asks which window has input focus is made only if a lab route exists at
    all.
    """
    routes_dir = state_file + ".routes"
    try:
        names = set(os.listdir(routes_dir))
    except OSError:
        return None
    if not any(n.startswith("lab.") and n.endswith(".json") for n in names):
        return None
    focused = _input_focus_platform_window_id_linux()
    if not focused or f"lab.{focused}.json" not in names:
        return None
    try:
        route = load_json(os.path.join(routes_dir, f"lab.{focused}.json"))
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(route, dict):
        return None
    source = route.get("source") or {}
    if not source.get("listen_on") or source.get("window_id") in (None, ""):
        return None
    return {"source": source}


def pair_for_target(registry, target_state):
    target_key = window_key(target_state)
    if not target_key:
        return None
    pair_key = registry["_by_target"].get(target_key)
    if not pair_key:
        return None
    entry = registry["_pairs"].get(pair_key)
    return entry if isinstance(entry, dict) else None


def backend_gate_denies():
    """Backend policy. The ladder itself lives in bin/dl_repl_gate.py so this
    helper and any other Python consumer cannot drift from it; the standalone
    bin/dl-repl-python-buffer-gate still carries its own copy and is pinned to
    this one by ml_reverse_regression.sh's differential group."""
    return dl_repl_gate.denies(state_file, now=now)


def _env_window_id(name):
    value = (os.environ.get(name) or "").strip()
    return int(value) if value.lstrip("-").isdigit() else None


def pair_by_identity(registry, platform_window_id, kitty_window_id):
    """Find the registry target matching one already-qualified window pair.

    Socket strings are not compared: Kitty can expose an abstract control
    socket while the registry stores the pathname socket. Platform-window plus
    child identity is exact on Linux; Mac reaches this only after socket-based
    active-target discovery."""
    if not platform_window_id or not kitty_window_id:
        return None
    for entry in registry["_pairs"].values():
        if not isinstance(entry, dict):
            continue
        target = entry.get("target") or {}
        entry_platform = target.get("platform_window_id")
        if entry_platform is None or int(entry_platform) != platform_window_id:
            continue
        entry_window = target.get("window_id")
        if entry_window is not None and int(entry_window) != kitty_window_id:
            continue
        return entry
    return None


def same_source(left, right):
    return (
        left.get("listen_on") == right.get("listen_on")
        and str(left.get("window_id")) == str(right.get("window_id"))
    )


def focus_entry(entry):
    source = (entry or {}).get("source") or {}
    listen_on = source.get("listen_on")
    window_id = source.get("window_id")
    if not listen_on or window_id in (None, ""):
        return False
    try:
        # Deliberate divergence: C keeps a successful Kitty selection when the
        # later OS raise fails; Python still propagates subprocess raise errors.
        focus_window(listen_on, window_id, source.get("platform_window_id"))
    except OSError:
        return False
    return True


# A raised JupyterLab window answers first. It is keyed by the browser window
# itself, so it depends on neither the singleton slime state nor the backend
# policy ladder below -- an iron-configured session still gets back out of the
# browser it was sent into. A miss here is free and falls straight through.
lab_entry = lab_route_for_focused_window()
if lab_entry and focus_entry(lab_entry):
    raise SystemExit(0)

# Validate the singleton state before any selector lookup. Missing is the one
# fail-open startup case; unreadable, malformed, non-object, and oversized state
# all miss without consulting the registry. Python deliberately has no C token
# cap, so a valid document larger than 8192 tokens is decided here normally.
state, state_invalid = read_state()
if state_invalid:
    raise SystemExit(3)
if backend_gate_denies():
    raise SystemExit(4)

registry = load_registry()
pressing = None
explicit_window_id = int(pressing_window_arg) if pressing_window_arg else None
if explicit_window_id and IS_DARWIN:
    extra_sockets = sockets_from_registry(registry)
    if state.get("listen_on"):
        extra_sockets.add(state.get("listen_on"))
    pressing = detect_active_target(extra_sockets, explicit_window_id)
    if not pressing:
        raise SystemExit(3)
    platform_window_id = pressing.get("platform_window_id")
    kitty_window_id = pressing.get("window_id")
elif explicit_window_id:
    platform_window_id = _input_focus_platform_window_id_linux()
    kitty_window_id = explicit_window_id
else:
    platform_window_id = _env_window_id("WINDOWID")
    kitty_window_id = _env_window_id("KITTY_WINDOW_ID")
    if not platform_window_id or not kitty_window_id:
        extra_sockets = sockets_from_registry(registry)
        if state.get("listen_on"):
            extra_sockets.add(state.get("listen_on"))
        pressing = detect_active_target(extra_sockets)
        if pressing:
            platform_window_id = pressing.get("platform_window_id")
            kitty_window_id = pressing.get("window_id")

route_entry = route_for_target(platform_window_id, kitty_window_id)
registry_entry = pair_by_identity(registry, platform_window_id, kitty_window_id)
if not explicit_window_id and route_entry is None and registry_entry is None and pressing is None:
    extra_sockets = sockets_from_registry(registry)
    if state.get("listen_on"):
        extra_sockets.add(state.get("listen_on"))
    pressing = detect_active_target(extra_sockets)
    if pressing:
        platform_window_id = pressing.get("platform_window_id")
        kitty_window_id = pressing.get("window_id")
        route_entry = route_for_target(platform_window_id, kitty_window_id)
        registry_entry = pair_by_identity(registry, platform_window_id, kitty_window_id)
if registry_entry is None and pressing:
    registry_entry = pair_for_target(registry, pressing)

if route_entry and focus_entry(route_entry):
    raise SystemExit(0)
if route_entry and registry_entry and same_source(
        route_entry["source"], registry_entry.get("source") or {}):
    raise SystemExit(3)
if registry_entry and focus_entry(registry_entry):
    raise SystemExit(0)
raise SystemExit(3)
