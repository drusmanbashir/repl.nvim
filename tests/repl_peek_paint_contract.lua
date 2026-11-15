-- Hh gate for the answer half of the `<M-v>` REPL peek
-- (lua/repl/peek.lua): what the module does with the file the REPL
-- writes. No REPL and no send -- the test writes that file itself -- so the
-- rows are about the poll, the silence contract and what gets painted.
--
-- Data-level, not a GUI claim: rows read the extmark and the float's own
-- buffer, not the screen.
--
-- nvim --headless -n -i NONE -u NONE -l tests/repl_peek_paint_contract.lua
-- exit 0 PASS, 1 FAIL.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local peek = require("repl.peek")

local failures = {}
local passes = 0

local function check(name, ok, detail)
  if ok then
    passes = passes + 1
    print("PASS " .. name)
  else
    failures[#failures + 1] = name
    print("FAIL " .. name .. ": " .. tostring(detail))
  end
end

local function buffer_with(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end

local function answer(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

--- The answer file lands while the poll is running, as it does in production.
local function peek_answer(buf, expr, text)
  local path = vim.fn.tempname() .. "-peek"
  peek._test.await(path, { buf = buf, row = 0, expr = expr })
  vim.defer_fn(function()
    if text then
      answer(path, text)
    end
  end, 40)
  vim.wait(1500, function()
    return peek._test.pending() == nil
  end, 10)
  return path
end

local function virt_text(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, peek._test.namespace, 0, -1, { details = true })
  if #marks == 0 then
    return nil
  end
  return marks[1][4].virt_text[1][1]
end

local function float_lines()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), win
    end
  end
  return nil
end

vim.g.ub_repl_peek_timeout_ms = 400

do
  vim.g.ub_repl_peek_style = "inline"
  local buf = buffer_with({ "x = 1", "y = 2" })
  peek_answer(buf, "x", "ok\n42")
  check("inline_paints_value_only", virt_text(buf) == "  42", vim.inspect(virt_text(buf)))

  -- Moving off the line takes the value with it.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  check("inline_clears_on_move", virt_text(buf) == nil, vim.inspect(virt_text(buf)))
end

do
  vim.g.ub_repl_peek_style = "inline"
  local buf = buffer_with({ "x = 1" })
  peek_answer(buf, "x", "err:NameError")
  check("undefined_name_paints_nothing", virt_text(buf) == nil, vim.inspect(virt_text(buf)))
end

do
  vim.g.ub_repl_peek_style = "inline"
  local buf = buffer_with({ "x = 1" })
  local path = peek_answer(buf, "x", nil)
  check("timeout_paints_nothing", virt_text(buf) == nil, vim.inspect(virt_text(buf)))
  check("timeout_stops_polling", peek._test.pending() == nil, "poll still armed")
  os.remove(path)
end

do
  vim.g.ub_repl_peek_style = "inline"
  local buf = buffer_with({ "x = 1" })
  peek_answer(buf, "x", "ok\nline one\nline two")
  check("inline_flattens_to_one_line", virt_text(buf) == "  line one ...", vim.inspect(virt_text(buf)))
end

do
  vim.g.ub_repl_peek_style = "popup"
  local buf = buffer_with({ "x = 1" })
  peek_answer(buf, "x", "ok\nline one\nline two")
  local lines, win = float_lines()
  check("popup_shows_every_line", vim.deep_equal(lines, { "line one", "line two" }), vim.inspect(lines))
  check("popup_titles_the_expression", win and vim.api.nvim_win_get_config(win).title[1][1] == " x ", win and vim.inspect(vim.api.nvim_win_get_config(win).title))
  check("popup_paints_no_extmark", virt_text(buf) == nil, vim.inspect(virt_text(buf)))

  vim.api.nvim_exec_autocmds("CursorMoved", {})
  check("popup_closes_on_move", float_lines() == nil, "float still open")
end

do
  vim.g.ub_repl_peek_style = "nonsense"
  check("unknown_style_falls_back_to_popup", peek.style() == "popup", peek.style())
  vim.g.ub_repl_peek_style = nil
  check("default_style_is_popup", peek.style() == "popup", peek.style())
  peek.toggle_style()
  check("toggle_switches_style", peek.style() == "inline", peek.style())
  peek.toggle_style()
  check("toggle_switches_back", peek.style() == "popup", peek.style())
end

print(string.format("%d passed, %d failed", passes, #failures))
os.exit(#failures == 0 and 0 or 1)
