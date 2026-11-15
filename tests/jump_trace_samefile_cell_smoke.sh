#!/usr/bin/env bash
# Headless same-file cell offset regressions for jump_trace.
# 1) call snippet must not offset-vote onto def (boom).
# 2) reverse relaxed substring must not vote onto short decoy (][-1] -> "1"
#    inside ifjj_case_001).
# 3) real IPython caret-form SyntaxError (no Traceback, no ---->) lands on
#    the offending source line.
# 4) that caret block wins over an older Traceback above it in scrollback.
# 5) a frameless newest error never falls back to an older error's frames.
set -euo pipefail
tmp="/s/agent_rw/tmp/jump_trace_samefile_cell_smoke.lua"
ok="/s/agent_rw/tmp/jump_trace_samefile_cell_ok.txt"
fail="/s/agent_rw/tmp/jump_trace_samefile_cell_fail.txt"
rm -f "$ok" "$fail"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JUMP_TRACE_LUA="${ROOT}/lua/repl/jump_trace.lua"

cat >"$tmp" <<'LUA'
local ok_file = "/s/agent_rw/tmp/jump_trace_samefile_cell_ok.txt"
local fail_file = "/s/agent_rw/tmp/jump_trace_samefile_cell_fail.txt"

local function die(msg)
  vim.fn.writefile({ tostring(msg) }, fail_file)
  error(msg, 0)
end

local function run_case(label, src, tb, want_ln, want_pat)
  -- Isolate from prior case: only one non-float window + one iron buffer.
  local keep = vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= keep then pcall(vim.api.nvim_win_close, w, true) end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:match("^iron://") then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end

  local src_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(src_buf, "/s/agent_rw/tmp/jump_trace_samefile_cell_" .. label .. ".py")
  vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, src)
  vim.api.nvim_set_current_buf(src_buf)
  vim.bo.filetype = "python"
  -- Cursor on line 1: distance tie-break previously preferred false early matches.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local iron = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(iron, "iron://python")
  vim.api.nvim_buf_set_lines(iron, 0, -1, false, tb)
  vim.api.nvim_open_win(iron, false, { split = "below", win = 0 })
  vim.api.nvim_set_current_buf(src_buf)
  pcall(function()
    require("repl").set_current("iron", "python")
  end)

  local modpath = assert(os.getenv("JUMP_TRACE_LUA"), "JUMP_TRACE_LUA unset")
  package.loaded["repl.jump_trace"] = nil
  local jt = assert(loadfile(modpath))()
  package.loaded["repl.jump_trace"] = jt
  local real = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return "j"
  end
  jt.jump_from_bottom_with_prompt()
  vim.fn.getcharstr = real

  if vim.api.nvim_get_current_buf() ~= src_buf then
    die(("%s: left the source buffer for %s"):format(label, vim.api.nvim_buf_get_name(0)))
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(src_buf, cur - 1, cur, false)[1] or ""
  if cur ~= want_ln or not line:match(want_pat) then
    die(("%s: landed %d %q want %d %s mod=%s"):format(
      label, cur, line, want_ln, want_pat, modpath))
  end
  return ("OK %s line=%d"):format(label, cur)
end

local reports = {}

reports[#reports + 1] = run_case(
  "boom_def",
  {
    "def boom():",
    "    return 1",
    "",
    "x = 1",
    "y = 2",
    "z = 3",
    "# %%",
    "boom()",
  },
  {
    "TypeError                                 Traceback (most recent call last)",
    "Cell In[2], line 1",
    "----> 1 boom()",
    "TypeError: boom() missing args",
  },
  8,
  "^%s*boom%(%s*%)%s*$"
)

-- Decoy "][-1]" normalizes to "1"; reverse substring matched inside ifjj_case_001.
reports[#reports + 1] = run_case(
  "short_decoy",
  {
    "def helper():",
    "    return 1",
    "",
    "    ][-1]",
    "x = 1",
    "y = 2",
    "# %%",
    "if jj_case_001:",
    "    pass",
  },
  {
    "NameError                                 Traceback (most recent call last)",
    "Cell In[3], line 1",
    "----> 1 if jj_case_001:",
    "NameError: name 'jj_case_001' is not defined",
  },
  8,
  "^%s*if jj_case_001:%s*$"
)

-- Real IPython caret-form SyntaxError: no Traceback, no ----> arrow.
reports[#reports + 1] = run_case(
  "caret_syntax",
  {
    "def helper():",
    "    return 1",
    "",
    "x = 1",
    "# %%",
    "if jj_case_001",
    "    pass",
  },
  {
    "Cell In[1], line 1",
    "    if jj_case_001",
    "                  ^",
    "SyntaxError: expected ':'",
  },
  6,
  "^%s*if jj_case_001%s*$"
)

-- Cursor-independent resolution: a broad decoy above the exact offending call
-- must not win merely because the cursor starts above the code block.
reports[#reports + 1] = run_case(
  "cursor_above_broad_decoy",
  {
    "def helper():",
    "    return 1",
    "wrapped = target_call() + 1",
    "noise = 2",
    "# %%",
    "target_call()",
  },
  {
    "RuntimeError                                 Traceback (most recent call last)",
    "Cell In[5], line 1",
    "----> 1 target_call()",
    "RuntimeError: deliberate failure",
  },
  6,
  "^%s*target_call%(%s*%)%s*$"
)

-- Caret-form IndentationError below an older Traceback still in scrollback:
-- the newest error wins, not the stale traceback's deepest library frame.
local stale_lib = "/s/agent_rw/tmp/jump_trace_samefile_cell_stale_lib.py"
vim.fn.writefile({ "x = 1" }, stale_lib)
reports[#reports + 1] = run_case(
  "caret_below_stale_traceback",
  {
    "from typing import TypedDict",
    "",
    "def add_m(msgs_old, msg_new):",
    "",
    "",
    "class TriageState(TypedDict):",
    "    email: dict",
  },
  {
    "ValidationError                           Traceback (most recent call last)",
    "Cell In[16], line 1",
    "----> 1 app.invoke({\"message\": msg})",
    "",
    "File " .. stale_lib .. ":1, in BaseModel.__init__(self, **data)",
    "ValidationError: 4 validation errors for TriageStateP",
    "",
    "[ins] In [18]: def add_m(msgs_old, msg_new):",
    "          ...: class TriageState(TypedDict):",
    "  Cell In[18], line 4",
    "    class TriageState(TypedDict):",
    "    ^",
    "IndentationError: expected an indented block after function definition on line 3",
  },
  6,
  "^class TriageState%(TypedDict%):$"
)

-- Newest error has no frame (IPython UsageError): stay put, never fall back to
-- an older traceback's frames.
reports[#reports + 1] = run_case(
  "frameless_newest_error",
  {
    "from typing import TypedDict",
    "x = 1",
  },
  {
    "ValidationError                           Traceback (most recent call last)",
    "Cell In[16], line 1",
    "----> 1 app.invoke({\"message\": msg})",
    "",
    "File " .. stale_lib .. ":1, in BaseModel.__init__(self, **data)",
    "ValidationError: 4 validation errors for TriageStateP",
    "",
    "[ins] In [19]: %foo",
    "UsageError: Line magic function `%foo` not found.",
  },
  1,
  "^from typing import TypedDict$"
)

vim.fn.writefile(vim.list_extend({
  "same-file cell call site OK",
  "mod=" .. assert(os.getenv("JUMP_TRACE_LUA")),
}, reports), ok_file)
LUA

"${NVIM_BIN:-/home/ub/scripts/bin/nvim-codex}" --headless -n -i NONE -u NONE \
  -c "lua package.path = '$ROOT/lua/?.lua;' .. package.path" \
  "+luafile $tmp" "+qa!" 2>&1 | tail -20

if [ -f "$ok" ]; then
  echo "=== jump_trace samefile cell smoke PASS ==="
  cat "$ok"
  exit 0
fi

if [ -f "$fail" ]; then
  echo "=== jump_trace samefile cell smoke FAIL ===" >&2
  cat "$fail" >&2
  exit 1
fi

echo "smoke produced no result" >&2
exit 1
