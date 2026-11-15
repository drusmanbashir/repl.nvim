#!/usr/bin/env bash
# Headless: last_traceback_from_lines slices latest Traceback..Error block only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="/s/agent_rw/tmp/jump_trace_last_traceback_smoke.lua"
ok="/s/agent_rw/tmp/jump_trace_last_traceback_ok.txt"
fail="/s/agent_rw/tmp/jump_trace_last_traceback_fail.txt"
rm -f "$ok" "$fail"

cat >"$tmp" <<'LUA'
local ok_file = "/s/agent_rw/tmp/jump_trace_last_traceback_ok.txt"
local fail_file = "/s/agent_rw/tmp/jump_trace_last_traceback_fail.txt"

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

local two = {
  "In [1]:",
  "NameError                                 Traceback (most recent call last)",
  "Cell In[1], line 1",
  "----> 1 missing_name",
  "NameError: name 'missing_name' is not defined",
  "",
  "In [2]:",
  "ModuleNotFoundError                       Traceback (most recent call last)",
  "Cell In[2], line 1",
  "----> 1 import gorbo",
  "ModuleNotFoundError: No module named 'gorbo'",
  "",
  "In [3]:",
}

local text, err = jt.last_traceback_from_lines(two)
check(err == nil, "unexpected err: " .. tostring(err))
check(text:find("ModuleNotFoundError: No module named 'gorbo'", 1, true) ~= nil, "missing second error: " .. tostring(text))
check(text:find("import gorbo", 1, true) ~= nil, "missing second body")
check(text:find("missing_name", 1, true) == nil, "first traceback leaked: " .. tostring(text))
check(text:find("In %[3%]:") == nil, "prompt leaked")

-- Caret-form error (no Traceback header) below an older traceback is newest.
local caret = {
  "[ins] In [16]: app.invoke({'message': msg})",
  "ValidationError                           Traceback (most recent call last)",
  "Cell In[16], line 1",
  "----> 1 app.invoke({'message': msg})",
  "ValidationError: 4 validation errors for TriageStateP",
  "email",
  "  Field required [type=missing, input_value={}, input_type=dict]",
  "",
  "[ins] In [18]: def add_m(msgs_old, msg_new):",
  "          ...: class TriageState(TypedDict):",
  "  Cell In[18], line 4",
  "    class TriageState(TypedDict):",
  "    ^",
  "IndentationError: expected an indented block after function definition on line 3",
  "",
  "[ins] In [19]: ",
}
local ctext, cerr = jt.last_traceback_from_lines(caret)
check(cerr == nil, "caret: unexpected err: " .. tostring(cerr))
check(ctext:find("IndentationError: expected an indented block", 1, true) ~= nil, "caret: newest error missing: " .. tostring(ctext))
check(ctext:find("Cell In[18], line 4", 1, true) ~= nil, "caret: frame missing")
check(ctext:find("ValidationError", 1, true) == nil, "caret: older traceback leaked: " .. tostring(ctext))
check(ctext:find("...:", 1, true) == nil, "caret: cell echo leaked: " .. tostring(ctext))
check(ctext:find("In [19]", 1, true) == nil, "caret: prompt leaked")

local empty_text, empty_err = jt.last_traceback_from_lines({ "In [1]:", "1+1", "Out[1]: 2" })
check(empty_text == nil, "expected nil text")
check(empty_err == "No traceback in REPL.", "expected no-traceback err, got " .. tostring(empty_err))

local none_text, none_err = jt.last_traceback_from_lines({})
check(none_text == nil, "empty lines should fail")
check(none_err == "No REPL/output window found.", "got " .. tostring(none_err))

vim.fn.writefile({
  "slice latest only OK",
  "caret newest over older traceback OK",
  "empty scrollback OK",
  "no lines OK",
}, ok_file)
LUA

"${NVIM_BIN:-/home/ub/scripts/bin/nvim-codex}" --headless -n -i NONE -u NONE \
  -c "lua package.path = '$ROOT/lua/?.lua;' .. package.path" \
  "+luafile $tmp" "+qa!" 2>&1 | tail -20

if [ -f "$ok" ]; then
  echo "=== jump_trace last traceback smoke PASS ==="
  cat "$ok"
  exit 0
fi

if [ -f "$fail" ]; then
  echo "=== jump_trace last traceback smoke FAIL ===" >&2
  cat "$fail" >&2
  exit 1
fi

echo "smoke produced no result" >&2
exit 1
