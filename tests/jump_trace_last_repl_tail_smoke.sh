#!/usr/bin/env bash
# Headless: last_repl_tail_from_lines returns the last n lines from the bottom.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="/s/agent_rw/tmp/jump_trace_last_repl_tail_smoke.lua"
ok="/s/agent_rw/tmp/jump_trace_last_repl_tail_ok.txt"
fail="/s/agent_rw/tmp/jump_trace_last_repl_tail_fail.txt"
rm -f "$ok" "$fail"

cat >"$tmp" <<'LUA'
local ok_file = "/s/agent_rw/tmp/jump_trace_last_repl_tail_ok.txt"
local fail_file = "/s/agent_rw/tmp/jump_trace_last_repl_tail_fail.txt"

local function die(msg)
  vim.fn.writefile({ msg }, fail_file)
  error(msg, 0)
end

local function check(cond, msg)
  if not cond then
    die(msg)
  end
end

local jt = require("repl.jump_trace")

local scrollback = {
  "In [1]:",
  "1 + 1",
  "Out[1]: 2",
  "",
  "In [2]:",
  "print('hello')",
  "hello",
  "",
  "In [3]:",
}

local tail3, err3 = jt.last_repl_tail_from_lines(scrollback, 3)
check(err3 == nil, "unexpected err: " .. tostring(err3))
check(tail3 == "hello\n\nIn [3]:", "tail3 mismatch: " .. vim.inspect(tail3))

local padded = {}
for i = 1, 20 do
  padded[i] = ""
end
for i, line in ipairs(scrollback) do
  padded[20 + i] = line
end
local tail_padded, err_padded = jt.last_repl_tail_from_lines(padded, 3)
check(err_padded == nil, "unexpected padded err: " .. tostring(err_padded))
check(tail_padded == "hello\n\nIn [3]:", "padded tail mismatch: " .. vim.inspect(tail_padded))

local tail20, err20 = jt.last_repl_tail_from_lines(scrollback, 20)
check(err20 == nil, "unexpected err20: " .. tostring(err20))
check(tail20:find("In %[1%]:") ~= nil, "tail20 should include top")
check(tail20:find("In %[3%]:") ~= nil, "tail20 should include bottom")

local none_text, none_err = jt.last_repl_tail_from_lines({}, 5)
check(none_text == nil, "empty lines should fail")
check(none_err == "No REPL/output window found.", "got " .. tostring(none_err))

local bad_n, bad_err = jt.last_repl_tail_from_lines(scrollback, 0)
check(bad_n == nil, "zero count should fail")
check(bad_err == "Line count must be positive.", "got " .. tostring(bad_err))

vim.fn.writefile({
  "tail slice OK",
  "padded scrollback OK",
  "short scrollback OK",
  "empty scrollback OK",
  "zero count OK",
}, ok_file)
LUA

"${NVIM_BIN:-/home/ub/scripts/bin/nvim-codex}" --headless -n -i NONE -u NONE \
  -c "lua package.path = '$ROOT/lua/?.lua;' .. package.path" \
  "+luafile $tmp" "+qa!" 2>&1 | tail -20

if [ -f "$ok" ]; then
  echo "=== jump_trace last repl tail smoke PASS ==="
  cat "$ok"
  exit 0
fi

if [ -f "$fail" ]; then
  echo "=== jump_trace last repl tail smoke FAIL ===" >&2
  cat "$fail" >&2
  exit 1
fi

echo "smoke produced no result" >&2
exit 1
