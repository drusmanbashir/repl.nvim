#!/usr/bin/env bash
# Pins lua/repl/paths.lua and bin/dl_repl_paths.py to each other, and
# pins the Linux branch to the exact strings the pre-resolver code produced
# (the Sinclair byte-identity guard -- if these change, Sinclair breaks).

set -euo pipefail

plugin_root="${REPL_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
nvim_bin="${NVIM_BIN:-nvim}"
command -v "$nvim_bin" >/dev/null || nvim_bin="/home/ub/scripts/bin/nvim-codex"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
runtime="$tmp/runtime"
mkdir -p "$runtime"

lua_dump() {
  "$nvim_bin" --headless -u NONE \
    +"lua package.path='$plugin_root/lua/?.lua;$plugin_root/lua/?/init.lua;' .. package.path; local d = require('repl.paths').dump(); local f = assert(io.open('$tmp/lua.json','w')); f:write(vim.json.encode(d)); f:close()" \
    +qall >/dev/null 2>&1
}

py_dump() {
  python3 "$plugin_root/bin/dl_repl_paths.py" --json > "$tmp/py.json"
}

compare() {
  local label="$1"
  python3 - "$tmp/lua.json" "$tmp/py.json" "$label" <<'PY'
import json, sys
lua_path, py_path, label = sys.argv[1:4]
with open(lua_path) as fh:
    lua = json.load(fh)
with open(py_path) as fh:
    py = json.load(fh)
if lua != py:
    print(f"parity mismatch [{label}]", file=sys.stderr)
    for key in sorted(set(lua) | set(py)):
        if lua.get(key) != py.get(key):
            print(f"  {key}: lua={lua.get(key)!r} py={py.get(key)!r}", file=sys.stderr)
    raise SystemExit(1)
PY
}

# Every variable either implementation reads. Cleared before each case so the
# ambient environment (Sinclair really has XDG_RUNTIME_DIR set; Mac really has
# TMPDIR set) cannot leak into a case and make it pass for the wrong reason.
CONTROLLED=(
  DL_REPL_PATHS_SYSNAME DL_REPL_PATHS_UID
  DL_RUNTIME_DIR XDG_RUNTIME_DIR TMPDIR
  DL_SESSION_NAMESPACE
  DL_REPL_SOCKET DL_R_REPL_SOCKET DL_LUA_REPL_SOCKET DL_EDIT_SOCKET
  DL_REPL_SOCKET_OVERRIDE DL_R_REPL_SOCKET_OVERRIDE DL_LUA_REPL_SOCKET_OVERRIDE
  DL_EDIT_SOCKET_OVERRIDE
  DL_FOCUS_SLIME_STATE_FILE DL_FOCUS_SLIME_REGISTRY_FILE DL_FOCUS_SLIME_PAIR_FILE
  NVIM_SLIME_TMUX_REPL_TARGET
)

# Each case: a label plus the env that both implementations see.
run_case() {
  local label="$1"; shift
  (
    unset "${CONTROLLED[@]}"
    for assignment in "$@"; do
      export "$assignment"
    done
    lua_dump
    py_dump
  )
  compare "$label"
}

assert_json() {
  local file="$1" expr="$2" want="$3" label="$4"
  local got
  got="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {"d": d}))' "$file" "$expr")"
  if [ "$got" != "$want" ]; then
    echo "golden mismatch [$label]: $expr = $got, want $want" >&2
    exit 1
  fi
}

# --- 1. Sinclair default -----------------------------------------------------
run_case "linux-default" \
  DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000 XDG_RUNTIME_DIR="$runtime"
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:$runtime/dl-repl-kitty.sock" linux-default
assert_json "$tmp/py.json" 'd["sockets"]["r"]' "unix:$runtime/dl-r-repl-kitty.sock" linux-default
assert_json "$tmp/py.json" 'd["sockets"]["lua"]' "unix:$runtime/dl-lua-repl-kitty.sock" linux-default
assert_json "$tmp/py.json" 'd["edit_socket"]' "unix:$runtime/dl-edit-kitty.sock" linux-default
assert_json "$tmp/py.json" 'd["state_file"]' "$runtime/kitty-focus-slime-target.json" linux-default
assert_json "$tmp/py.json" 'd["registry_file"]' "$runtime/kitty-focus-slime-pair.json" linux-default
assert_json "$tmp/py.json" 'd["tmux_target"]' "dlmain:1" linux-default

# --- 2. Sinclair with no XDG_RUNTIME_DIR ------------------------------------
run_case "linux-no-xdg" DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000
assert_json "$tmp/py.json" 'd["runtime_dir"]' "/tmp" linux-no-xdg
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:/tmp/dl-repl-kitty.sock" linux-no-xdg

# --- 3. Sinclair ignores namespaces (no dl-session-env on Linux) ------------
run_case "linux-namespace-ignored" \
  DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000 XDG_RUNTIME_DIR="$runtime" \
  DL_SESSION_NAMESPACE=dl2
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:$runtime/dl-repl-kitty.sock" linux-namespace-ignored
assert_json "$tmp/py.json" 'd["namespace"]' "" linux-namespace-ignored
assert_json "$tmp/py.json" 'd["tmux_target"]' "dlmain:1" linux-namespace-ignored

# --- 4. Mac default ---------------------------------------------------------
run_case "mac-default" DL_REPL_PATHS_SYSNAME=Darwin DL_REPL_PATHS_UID=501
assert_json "$tmp/py.json" 'd["runtime_dir"]' "/tmp" mac-default
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:/tmp/dl-repl-kitty-501.sock" mac-default
assert_json "$tmp/py.json" 'd["edit_socket"]' "unix:/tmp/dl-edit-kitty-501.sock" mac-default
assert_json "$tmp/py.json" 'd["state_file"]' "/tmp/kitty-focus-slime-target.json" mac-default

# --- 5. Mac named session ---------------------------------------------------
run_case "mac-namespace" DL_REPL_PATHS_SYSNAME=Darwin DL_REPL_PATHS_UID=501 DL_SESSION_NAMESPACE=dl2
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:/tmp/dl-repl-kitty-501-dl2.sock" mac-namespace
assert_json "$tmp/py.json" 'd["sockets"]["r"]' "unix:/tmp/dl-r-repl-kitty-501-dl2.sock" mac-namespace
assert_json "$tmp/py.json" 'd["edit_socket"]' "unix:/tmp/dl-edit-kitty-501-dl2.sock" mac-namespace
assert_json "$tmp/py.json" 'd["tmux_target"]' "dlmain-dl2:1" mac-namespace

# --- 6. Namespace sanitising matches dl-session-env's tr -cs ----------------
run_case "mac-namespace-unsafe" \
  DL_REPL_PATHS_SYSNAME=Darwin DL_REPL_PATHS_UID=501 DL_SESSION_NAMESPACE='a b/c!'
assert_json "$tmp/py.json" 'd["namespace"]' "a-b-c" mac-namespace-unsafe

# --- 7. Explicit user override beats everything ----------------------------
run_case "mac-override" \
  DL_REPL_PATHS_SYSNAME=Darwin DL_REPL_PATHS_UID=501 DL_SESSION_NAMESPACE=dl2 \
  DL_REPL_SOCKET=unix:/tmp/session.sock \
  DL_REPL_SOCKET_OVERRIDE=unix:/tmp/pinned.sock
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:/tmp/pinned.sock" mac-override
# r has no override set, so it still follows the namespace.
assert_json "$tmp/py.json" 'd["sockets"]["r"]' "unix:/tmp/dl-r-repl-kitty-501-dl2.sock" mac-override

# --- 8. dl-session-env's exported socket is honoured below the override -----
run_case "mac-session-socket" \
  DL_REPL_PATHS_SYSNAME=Darwin DL_REPL_PATHS_UID=501 DL_REPL_SOCKET=unix:/tmp/session.sock
assert_json "$tmp/py.json" 'd["sockets"]["python"]' "unix:/tmp/session.sock" mac-session-socket

# --- 9. DL_RUNTIME_DIR wins over XDG_RUNTIME_DIR ----------------------------
run_case "runtime-dir-override" \
  DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000 XDG_RUNTIME_DIR="$runtime" \
  DL_RUNTIME_DIR="$tmp/explicit"
assert_json "$tmp/py.json" 'd["runtime_dir"]' "$tmp/explicit" runtime-dir-override

# --- 10. TMPDIR must never leak into the resolution -------------------------
run_case "tmpdir-ignored" \
  DL_REPL_PATHS_SYSNAME=Darwin DL_REPL_PATHS_UID=501 TMPDIR="$tmp/should-be-ignored/"
assert_json "$tmp/py.json" 'd["runtime_dir"]' "/tmp" tmpdir-ignored

# --- 11. Focus-file overrides -----------------------------------------------
# Every case above only ever UNSETS these, so the override branch of
# state_file()/registry_file() was never compared between the two resolvers --
# and that branch is load-bearing: it is what lets a caller prime the focus paths
# through the environment instead of re-deriving them (the A1 contract the
# compiled <M-l> helper is built on, and what the Slime oracle uses to keep a run
# off the user's live focus state). A drift here sends editor and helper to
# different files while every other case stays green.
run_case "focus-file-overrides" \
  DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000 XDG_RUNTIME_DIR="$runtime" \
  DL_FOCUS_SLIME_STATE_FILE="$tmp/primed-state.json" \
  DL_FOCUS_SLIME_REGISTRY_FILE="$tmp/primed-registry.json"
assert_json "$tmp/py.json" 'd["state_file"]' "$tmp/primed-state.json" focus-file-overrides
assert_json "$tmp/py.json" 'd["registry_file"]' "$tmp/primed-registry.json" focus-file-overrides

# --- 12. Legacy DL_FOCUS_SLIME_PAIR_FILE sits below the registry override ----
run_case "focus-pair-file-fallback" \
  DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000 XDG_RUNTIME_DIR="$runtime" \
  DL_FOCUS_SLIME_PAIR_FILE="$tmp/legacy-pair.json"
assert_json "$tmp/py.json" 'd["registry_file"]' "$tmp/legacy-pair.json" focus-pair-file-fallback

run_case "focus-registry-beats-pair-file" \
  DL_REPL_PATHS_SYSNAME=Linux DL_REPL_PATHS_UID=1000 XDG_RUNTIME_DIR="$runtime" \
  DL_FOCUS_SLIME_PAIR_FILE="$tmp/legacy-pair.json" \
  DL_FOCUS_SLIME_REGISTRY_FILE="$tmp/primed-registry.json"
assert_json "$tmp/py.json" 'd["registry_file"]' "$tmp/primed-registry.json" focus-registry-beats-pair-file

printf 'repl paths parity smoke ok\n'
