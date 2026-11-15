#!/usr/bin/env bash
# Headless: 0-based \jj/\jN from bottom and \JJ/\JN from top.
# Covers same-file Cell frames and cross-file File frames; asserts buffer+line.
set -euo pipefail
tmp="/s/agent_rw/tmp/jump_trace_index_semantics_smoke.lua"
ok="/s/agent_rw/tmp/jump_trace_index_semantics_ok.txt"
fail="/s/agent_rw/tmp/jump_trace_index_semantics_fail.txt"
rm -f "$ok" "$fail"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JUMP_TRACE_LUA="${ROOT}/lua/repl/jump_trace.lua"

OUTER="/s/agent_rw/tmp/jump_trace_index_outer.py"
INNER="/s/agent_rw/tmp/jump_trace_index_inner.py"
cat >"$OUTER" <<'PY'
def outer():
    return 1

# marker_outer
x = outer()
PY
cat >"$INNER" <<'PY'
def inner():
    return 2

# marker_inner
y = inner()
PY

cat >"$tmp" <<'LUA'
local ok_file = "/s/agent_rw/tmp/jump_trace_index_semantics_ok.txt"
local fail_file = "/s/agent_rw/tmp/jump_trace_index_semantics_fail.txt"
local outer_path = "/s/agent_rw/tmp/jump_trace_index_outer.py"
local inner_path = "/s/agent_rw/tmp/jump_trace_index_inner.py"

local function die(msg)
  vim.fn.writefile({ tostring(msg) }, fail_file)
  error(msg, 0)
end

local function reset_wins()
  local keep = vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= keep then pcall(vim.api.nvim_win_close, w, true) end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:match("^iron://") then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
end

local function load_jt()
  package.loaded["repl.jump_trace"] = nil
  local modpath = assert(os.getenv("JUMP_TRACE_LUA"), "JUMP_TRACE_LUA unset")
  local jt = assert(loadfile(modpath))()
  package.loaded["repl.jump_trace"] = jt
  return jt
end

local function jump_keys(from_top, keys)
  vim.bo.filetype = "python"
  pcall(function() require("repl").set_current("iron", "python") end)
  local jt = load_jt()
  local i = 0
  local real = vim.fn.getcharstr
  local real0 = vim.fn.getchar
  vim.fn.getcharstr = function()
    i = i + 1
    return keys[i] or ""
  end
  vim.fn.getchar = function(mode)
    if mode == 0 then
      i = i + 1
      local ch = keys[i]
      if not ch then return 0 end
      return vim.fn.char2nr(ch)
    end
    return real0(mode)
  end
  if from_top then
    jt.jump_from_top_with_prompt()
  else
    jt.jump_from_bottom_with_prompt()
  end
  vim.fn.getcharstr = real
  vim.fn.getchar = real0
end

local function expect(label, want_path_pat, want_ln, want_pat)
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, cur - 1, cur, false)[1] or ""
  if not name:match(want_path_pat) or cur ~= want_ln or not line:match(want_pat) then
    die(("%s: buf=%s line=%d %q want path~%s ln=%d %s"):format(
      label, name, cur, line, want_path_pat, want_ln, want_pat))
  end
  return ("OK %s"):format(label)
end

local reports = {}

-- Cross-file File frames: outer then inner (deepest).
reset_wins()
local start = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(start, "/s/agent_rw/tmp/jump_trace_index_start.py")
vim.api.nvim_buf_set_lines(start, 0, -1, false, { "pass" })
vim.api.nvim_set_current_buf(start)
vim.bo.filetype = "python"
pcall(function() require("repl").set_current("iron", "python") end)
local iron = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(iron, "iron://python")
vim.api.nvim_buf_set_lines(iron, 0, -1, false, {
  "TypeError                                 Traceback (most recent call last)",
  ('File "%s", line 5, in <module>'):format(outer_path),
  ('File "%s", line 5, in <module>'):format(inner_path),
  "TypeError: boom",
})
vim.api.nvim_open_win(iron, false, { split = "below", win = 0 })
vim.api.nvim_set_current_buf(start)

jump_keys(false, { "j" })
reports[#reports + 1] = expect("file_jj", "index_inner%.py$", 5, "inner%(%)")
jump_keys(false, { "1" })
reports[#reports + 1] = expect("file_j1", "index_outer%.py$", 5, "outer%(%)")
jump_keys(true, { "J" })
reports[#reports + 1] = expect("file_JJ", "index_outer%.py$", 5, "outer%(%)")
jump_keys(true, { "1" })
reports[#reports + 1] = expect("file_J1", "index_inner%.py$", 5, "inner%(%)")

-- Same-file Cell frames: two cells in one traceback (top then deepest).
reset_wins()
local cell_src = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(cell_src, "/s/agent_rw/tmp/jump_trace_index_cell.py")
vim.api.nvim_buf_set_lines(cell_src, 0, -1, false, {
  "def top_fn():",
  "    return 1",
  "",
  "def deep_fn():",
  "    return 2",
  "",
  "# %%",
  "top_fn()",
  "deep_fn()",
})
vim.api.nvim_set_current_buf(cell_src)
vim.bo.filetype = "python"
vim.api.nvim_win_set_cursor(0, { 1, 0 })
iron = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(iron, "iron://python")
vim.api.nvim_buf_set_lines(iron, 0, -1, false, {
  "TypeError                                 Traceback (most recent call last)",
  "Cell In[4], line 1",
  "----> 1 top_fn()",
  "Cell In[4], line 2",
  "----> 2 deep_fn()",
  "TypeError: boom",
})
vim.api.nvim_open_win(iron, false, { split = "below", win = 0 })
vim.api.nvim_set_current_buf(cell_src)

jump_keys(false, { "j" })
reports[#reports + 1] = expect("cell_jj", "index_cell%.py$", 9, "^%s*deep_fn%(%)%s*$")
jump_keys(false, { "1" })
reports[#reports + 1] = expect("cell_j1", "index_cell%.py$", 8, "^%s*top_fn%(%)%s*$")
jump_keys(true, { "J" })
reports[#reports + 1] = expect("cell_JJ", "index_cell%.py$", 8, "^%s*top_fn%(%)%s*$")
jump_keys(true, { "1" })
reports[#reports + 1] = expect("cell_J1", "index_cell%.py$", 9, "^%s*deep_fn%(%)%s*$")

vim.fn.writefile(vim.list_extend({
  "index semantics OK",
  "mod=" .. assert(os.getenv("JUMP_TRACE_LUA")),
}, reports), ok_file)
LUA

"${NVIM_BIN:-/home/ub/scripts/bin/nvim-codex}" --headless -n -i NONE -u NONE \
  -c "lua package.path = '$ROOT/lua/?.lua;' .. package.path" \
  "+luafile $tmp" "+qa!" 2>&1 | tail -20

if [ -f "$ok" ]; then
  echo "=== jump_trace index semantics smoke PASS ==="
  cat "$ok"
  exit 0
fi

if [ -f "$fail" ]; then
  echo "=== jump_trace index semantics smoke FAIL ===" >&2
  cat "$fail" >&2
  exit 1
fi

echo "smoke produced no result" >&2
exit 1
