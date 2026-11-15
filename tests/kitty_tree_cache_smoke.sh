#!/usr/bin/env bash
# Pins the caching contract of lua/repl/kitty_tree.lua.
#
# The cache exists because one send_cell asked `kitty @ ls` twice at 50ms each.
# The rows below pin the four behaviours that make it safe to cache at all:
# repeated reads hit once, a window absent from a stale tree forces exactly one
# refresh (or <leader>in would launch a REPL the next lookup denies exists),
# invalidate() drops the entry, and fresh() never reads the cache.
#
# Hermetic: a fake kitty speaks the DCS remote-control protocol over a unix
# socket and counts requests, so no real kitty or REPL is involved.

set -euo pipefail

plugin_root="${REPL_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
nvim_bin="${NVIM_BIN:-nvim}"
command -v "$nvim_bin" >/dev/null || nvim_bin="/home/ub/scripts/bin/nvim-codex"

tmp="$(mktemp -d)"
sock="$tmp/fake-kitty.sock"
count="$tmp/requests"
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

python3 - "$sock" "$count" <<'PY' &
import json, os, socket, sys
sock_path, count_path = sys.argv[1], sys.argv[2]
TREE = [{"id": 1, "platform_window_id": 999, "tabs": [{"title": "t",
         "windows": [{"id": 2, "title": "dl-repl-1"},
                     {"id": 3, "title": "agent-repl-1"}]}]}]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path); srv.listen(16)
open(count_path, "w").write("0")
while True:
    conn, _ = srv.accept()
    buf = b""
    while b"\x1b\\" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            break
        buf += chunk
    n = int(open(count_path).read() or 0) + 1
    open(count_path, "w").write(str(n))
    body = json.dumps({"ok": True, "data": json.dumps(TREE)}).encode()
    conn.sendall(b"\x1bP@kitty-cmd" + body + b"\x1b\\")
    conn.close()
PY
server_pid=$!

for _ in $(seq 50); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { echo "FAIL fake kitty never bound $sock"; exit 1; }

KITTY_TREE_TEST_SOCKET="$sock" "$nvim_bin" --headless -u NONE \
  +"lua package.path='$plugin_root/lua/?.lua;$plugin_root/lua/?/init.lua;' .. package.path" \
  +"luafile $plugin_root/tests/kitty_tree_cache_smoke.lua" \
  +qall 2>&1 | tee "$tmp/out"

echo "fake kitty served $(cat "$count") request(s)"
grep -q '^FAIL' "$tmp/out" && exit 1
grep -q '^OK all' "$tmp/out" || { echo "FAIL: assertions did not run"; exit 1; }
exit 0
