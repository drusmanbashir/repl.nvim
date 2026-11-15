-- paste_lines_unit.lua -- direct rows for the hold rule (REPL_ROUTING.md § `M-x`
-- cell-send contract items 4, 5 and 7), run by repl_send_battery.sh before the cases.
--
-- PURPOSE: reds when a cell whose next cell starts deeper is not held open (or
-- one whose next cell does not is held), when the payload that continues a held
-- block is not shifted like the payload that opened it, when a held block leaks
-- to another REPL target, or when an indented `# %%` is not a cell boundary.
-- The real-file cases prove these end to end; these rows pin the edges no
-- sampled file has (comment-only gap, last cell, other REPL, one-line payload).
--
-- Run: nvim --headless -n -i NONE -u NONE -c "lua package.path='lua/?.lua;'..package.path"
--      -c "luafile tests/repl_send_battery/paste_lines_unit.lua". Exit 0 PASS, 1 FAIL.
local f = require("repl.python.slime_format")
local repl_cell = require("repl.cell")
local cr = "\13"
local failures, rows = 0, 0

local function check(name, cond, detail)
  rows = rows + 1
  if not cond then
    failures = failures + 1
    print("FAIL paste_lines " .. name .. ": " .. detail)
  end
end

-- paste_lines -------------------------------------------------------------
f.forget()
local p = f.paste_lines({ "    x = 1", "    y = 2" }, "t", false)
check("complete block dedents and executes", p[1] == "x = 1" and p[3] == cr, vim.inspect(p))
p = f.paste_lines({ "    En.debug = True" }, "t", false)
check("one line keeps its indent", p[1] == "    En.debug = True" and p[2] == cr, vim.inspect(p))

f.forget()
p = f.paste_lines({ "    for x in xs:", "        y = x" }, "t", true)
check("continued block is held (no execution CR)", p[#p] == "", vim.inspect(p))
p = f.paste_lines({ "        z = x", "    w = 1" }, "t", false)
check("continuation keeps the held shift, then executes",
  p[1] == "    z = x" and p[2] == "w = 1" and p[3] == cr, vim.inspect(p))
p = f.paste_lines({ "    v = 2", "    u = 3" }, "t", false)
check("block closed after the continuation ran", p[1] == "v = 2", vim.inspect(p))

f.forget()
f.paste_lines({ "if ready:" }, "t", true)
p = f.paste_lines({ "    v = 1", "    u = 2" }, "other-repl", false)
check("a held block belongs to one REPL target", p[1] == "v = 1", vim.inspect(p))
f.forget()

-- next_cell_continues ------------------------------------------------------
local function continues(lines, cursor)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { cursor, 0 })
  local got = repl_cell.next_cell_continues(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  return got
end

check("next cell deeper -> continues",
  continues({ "# %%", "    for cc in xs:", "        print(cc)", "# %%", "        key = cc" }, 2) == true, "false")
check("next cell at the same indent -> does not",
  continues({ "# %%", "    a = 1", "# %%", "    b = 2" }, 2) == false, "true")
check("leading comments in the next cell are skipped",
  continues({ "# %%", 'if __name__ == "__main__":', "# %%", "# SECTION: setup", "    a = 1" }, 2) == true, "false")
check("last cell -> does not", continues({ "# %%", "    for x in xs:", "        y = x" }, 2) == false, "true")
check("indented `# %%` bounds the cell",
  continues({ "if g:", "    a = 1", "    # %%", "    for x in xs:", "        y = x", "    # %%", "        z = 1" }, 4) == true,
  "false")

-- delimiter ----------------------------------------------------------------
local delim = vim.regex(repl_cell.delimiter_pattern())
check("`    # %%` is a boundary", delim:match_str("    # %%") ~= nil, "no match")
check("`#%%` is a boundary", delim:match_str("#%%") ~= nil, "no match")
check("`# x %%` is not a boundary", delim:match_str("# x %%") == nil, "matched")

if failures == 0 then
  print("PASS paste_lines unit rows (" .. rows .. ")")
end
vim.cmd(failures == 0 and "qall!" or "cquit 1")
